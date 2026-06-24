/**
 * RenewalService — spawns Renewal Opportunities from activated Contracts per
 * (Contract).
 *
 * `createRenewalOpportunity(contractIds)` (called from ContractTriggerHandler
 * on activation):
 *   1. Loads the contracts and matches a Renewal_Creation_Rule__mdt by
 *      Support_Tier__c (Standard → 60 days out, Premium Enterprise → 90).
 *   2. Computes the renewal window: Subscription_End_Date − Days_Before_Renewal.
 *      A contract already inside (or past) that window gets its Renewal
 *      Opportunity created synchronously now; a contract whose window is
 *      still in the future is handed to the deferred scheduling seam
 * (RenewalScheduler — not built yet).
 *   3. The synchronous renewal Opp uses record type Renewal, copies the term
 *      from the contract's source Opportunity, sets Sales_Motion__c and
 *      Renewal_Source_Contract__c, then links itself back onto the Contract
 *      (Renewal_Opportunity__c) — which fires the ContractTriggerHandler
 *      bookkeeping stamp.
 *
 * Idempotent: a contract that already has Renewal_Created__c or a linked
 * Renewal_Opportunity__c is skipped, so re-activation never double-creates.
 *
 * Design notes:
 *   - Subscription_Term_Months__c is copied from the contract's
 *     Source_Opportunity__c — Contract has no term-months field, and the
 *     source Opp's value is a guaranteed-valid GVS member.
 *   - A contract whose Support_Tier__c has no rule is skipped (only Standard
 *     and Premium Enterprise are seeded).
 *   - Owner_Role__c is not applied as the Opp owner (a role isn't a valid
 *     OwnerId); it's an attribute for later CS assignment.
 */
public with sharing class RenewalService {
  @TestVisible
  private static final String RECORD_TYPE_RENEWAL = 'Renewal';
  @TestVisible
  private static final String RENEWAL_STAGE = 'Qualify';

  // Test seam: overrides the Renewal_Creation_Rule__mdt.getAll() lookup.
  // Custom metadata can't be inserted in tests, so this keeps the suite
  // hermetic; one test omits it to exercise the real getAll() path.
  @TestVisible
  private static Map<String, Renewal_Creation_Rule__mdt> rulesOverrideForTest;

  // Captures for assertions.
  @TestVisible
  private static List<Opportunity> lastRenewalsCreated;
  @TestVisible
  private static List<Id> lastDeferredContractIds;

  /**
   * Flow-callable entry point for renewal creation. A
   * record-triggered or scheduled-path Flow on Contract passes
   * the Contract id(s); this bulkifies them into a single Set and delegates to
   * createRenewalOpportunity. No business logic lives here — the metadata-driven
   * tier rules, auto-renewal opt-out, and renewal record type all stay in
   * createRenewalOpportunity, so Flow reuses the vetted Apex rather than
   * re-deriving renewal fields.
   *
   * @param contractIds Contract record ids to evaluate for renewal creation.
   */
  @InvocableMethod(
    label='Create Renewal Opportunities'
    description='Creates renewal Opportunities for the given Contracts per Renewal_Creation_Rule__mdt (tier rules, auto-renewal opt-out, renewal record type). Idempotent — never double-creates.'
    category='Northstar Renewals'
  )
  public static void createRenewalsFromFlow(List<Id> contractIds) {
    if (contractIds == null || contractIds.isEmpty()) {
      return;
    }
    createRenewalOpportunity(new Set<Id>(contractIds));
  }

  public static void createRenewalOpportunity(Set<Id> contractIds) {
    if (contractIds == null || contractIds.isEmpty()) {
      return;
    }

    List<Contract> contracts = [
      SELECT
        Id,
        AccountId,
        Name,
        Support_Tier__c,
        Subscription_End_Date__c,
        EndDate,
        Renewal_Created__c,
        Renewal_Opportunity__c,
        Auto_Renewal_Enabled__c,
        Source_Opportunity__c,
        Source_Opportunity__r.Subscription_Term_Months__c
      FROM Contract
      WHERE Id IN :contractIds
    ];

    Map<String, Renewal_Creation_Rule__mdt> rulesByTier = rulesByTier();
    List<Contract> dueNow = new List<Contract>();
    List<Contract> deferred = new List<Contract>();

    for (Contract con : contracts) {
      // Idempotent — never double-create a renewal for a contract.
      if (
        con.Renewal_Created__c == true ||
        con.Renewal_Opportunity__c != null
      ) {
        continue;
      }
      // Honor the customer's auto-renewal opt-out: an unchecked
      // Auto_Renewal_Enabled__c suppresses renewal creation entirely, per the
      // field's semantics. Skip before tier/window logic so
      // an opted-out contract is neither created-now nor deferred.
      if (con.Auto_Renewal_Enabled__c == false) {
        continue;
      }
      Renewal_Creation_Rule__mdt rule = rulesByTier.get(con.Support_Tier__c);
      if (rule == null) {
        continue; // no renewal policy for this support tier
      }
      Date endDate = con.Subscription_End_Date__c != null
        ? con.Subscription_End_Date__c
        : con.EndDate;
      if (endDate == null) {
        continue; // can't compute a window without an end date
      }
      Integer daysBefore = rule.Days_Before_Renewal__c == null
        ? 0
        : rule.Days_Before_Renewal__c.intValue();
      if (Date.today() >= endDate.addDays(-daysBefore)) {
        dueNow.add(con);
      } else {
        deferred.add(con);
      }
    }

    createNow(dueNow, rulesByTier);
    enqueueDeferredRenewals(deferred);
  }

  private static void createNow(
    List<Contract> contracts,
    Map<String, Renewal_Creation_Rule__mdt> rulesByTier
  ) {
    if (contracts.isEmpty()) {
      lastRenewalsCreated = null;
      return;
    }
    Id renewalRecordTypeId = renewalRecordTypeId();
    List<Opportunity> renewals = new List<Opportunity>();
    for (Contract con : contracts) {
      Renewal_Creation_Rule__mdt rule = rulesByTier.get(con.Support_Tier__c);
      Date closeDate = con.Subscription_End_Date__c != null
        ? con.Subscription_End_Date__c
        : con.EndDate;
      Opportunity opp = new Opportunity(
        Name = 'Renewal - ' + con.Name,
        AccountId = con.AccountId,
        StageName = RENEWAL_STAGE,
        CloseDate = closeDate,
        Sales_Motion__c = rule == null ? null : rule.Sales_Motion__c,
        Renewal_Source_Contract__c = con.Id,
        Subscription_Term_Months__c = con.Source_Opportunity__c == null
          ? null
          : con.Source_Opportunity__r.Subscription_Term_Months__c
      );
      if (renewalRecordTypeId != null) {
        opp.RecordTypeId = renewalRecordTypeId;
      }
      renewals.add(opp);
    }
    insert renewals;
    lastRenewalsCreated = renewals;

    // Link each renewal Opp back onto its source Contract. The Contract
    // beforeUpdate stamps Renewal_Created__c / Renewal_Created_Date__c on
    // this same save.
    List<Contract> links = new List<Contract>();
    for (Integer i = 0; i < contracts.size(); i++) {
      links.add(
        new Contract(
          Id = contracts[i].Id,
          Renewal_Opportunity__c = renewals[i].Id
        )
      );
    }
    update links;
  }

  /**
   * Deferred (not-yet-in-window) renewals. The scheduled Apex job that
   * creates these closer to the contract end lives
   * (RenewalScheduler), which is not built yet. When it lands, this is the
   * call site to enqueue from. Until then it is a no-op that records the
   * deferred ids for visibility.
   */
  @TestVisible
  private static void enqueueDeferredRenewals(List<Contract> contracts) {
    if (contracts == null || contracts.isEmpty()) {
      lastDeferredContractIds = null;
      return;
    }
    List<Id> ids = new List<Id>();
    for (Contract con : contracts) {
      ids.add(con.Id);
    }
    lastDeferredContractIds = ids;
    System.debug(
      LoggingLevel.INFO,
      'Deferred renewal scheduling for contracts (awaiting ' +
        'RenewalScheduler): ' +
        ids
    );
  }

  private static Map<String, Renewal_Creation_Rule__mdt> rulesByTier() {
    if (rulesOverrideForTest != null) {
      return rulesOverrideForTest;
    }
    Map<String, Renewal_Creation_Rule__mdt> out = new Map<String, Renewal_Creation_Rule__mdt>();
    for (
      Renewal_Creation_Rule__mdt rule : Renewal_Creation_Rule__mdt.getAll()
        .values()
    ) {
      if (String.isNotBlank(rule.Support_Tier__c)) {
        out.put(rule.Support_Tier__c, rule);
      }
    }
    return out;
  }

  private static Id renewalRecordTypeId() {
    Schema.RecordTypeInfo info = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName()
      .get(RECORD_TYPE_RENEWAL);
    return (info != null && info.isActive()) ? info.getRecordTypeId() : null;
  }
}
