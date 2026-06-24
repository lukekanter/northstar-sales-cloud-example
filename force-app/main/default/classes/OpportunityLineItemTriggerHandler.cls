/**
 * OpportunityLineItemTriggerHandler — rolls OLI changes up to the parent
 * Opportunity's ARR__c / ACV__c.
 *
 * Fires on after-insert / after-update / after-delete / after-undelete.
 * Collects the affected parent Opportunity Ids (both new and old parents
 * when OpportunityId reassigns), refetches them along with their full
 * OLI sets, runs the same RevenueCalculationService used by
 * OpportunityTriggerHandler, and updates the parents.
 *
 * Recursion: the parent-Opp update fires OpportunityTriggerHandler's
 * beforeUpdate, but that handler now only recalculates ARR/ACV when
 * revenue-relevant Opp fields actually changed (Amount, term, or Closed
 * Won transition). Since this DML changes only ARR__c / ACV__c, the
 * recursive recalc is skipped — the OLI-derived values stick.
 *
 * Bulk-safety: the OLI fetch uses LIMIT 45000 to stay under the per-
 * transaction query-row governor. A delta beyond that limit means recalc
 * will be partial; we log via System.debug and let the update proceed
 * with the best available data rather than failing the user's save.
 */
public with sharing class OpportunityLineItemTriggerHandler extends TriggerHandler {
  // Conservative cap below the 50,000 query-row governor limit so other
  // SOQL in the same transaction (the parent-opp fetch, downstream
  // automation) still has room. @TestVisible so a test can lower it to
  // an in-test-reachable size and exercise the overflow / addError path.
  @TestVisible
  private static Integer OLI_ROW_CAP = 45000;

  public override void afterInsert() {
    recalcParents(parentIdsFromInsert());
  }

  public override void afterUpdate() {
    recalcParents(parentIdsFromUpdate());
  }

  public override void afterDelete() {
    recalcParents(parentIdsFromDelete());
  }

  public override void afterUndelete() {
    recalcParents(parentIdsFromInsert());
  }

  // -------------------------------------------------------------------------
  // Parent-Id collection
  // -------------------------------------------------------------------------

  private Set<Id> parentIdsFromInsert() {
    Set<Id> ids = new Set<Id>();
    for (OpportunityLineItem oli : (List<OpportunityLineItem>) Trigger.new) {
      if (oli.OpportunityId != null) {
        ids.add(oli.OpportunityId);
      }
    }
    return ids;
  }

  /**
   * On update, only recalc when a revenue-relevant field actually changed.
   * Touching Description or some other non-pricing field shouldn't pay the
   * SOQL + DML cost.
   *
   * If OpportunityId itself reassigns (rare but possible), both the new
   * AND old parents need recalc.
   */
  private Set<Id> parentIdsFromUpdate() {
    Map<Id, OpportunityLineItem> priors = (Map<Id, OpportunityLineItem>) Trigger.oldMap;
    Set<Id> ids = new Set<Id>();
    for (OpportunityLineItem oli : (List<OpportunityLineItem>) Trigger.new) {
      OpportunityLineItem prior = priors.get(oli.Id);
      if (
        oli.Quantity != prior.Quantity ||
        oli.UnitPrice != prior.UnitPrice ||
        oli.TotalPrice != prior.TotalPrice ||
        oli.Revenue_Type__c != prior.Revenue_Type__c ||
        oli.Discount != prior.Discount ||
        oli.OpportunityId != prior.OpportunityId
      ) {
        if (oli.OpportunityId != null) {
          ids.add(oli.OpportunityId);
        }
        if (
          prior.OpportunityId != null &&
          prior.OpportunityId != oli.OpportunityId
        ) {
          ids.add(prior.OpportunityId);
        }
      }
    }
    return ids;
  }

  private Set<Id> parentIdsFromDelete() {
    Set<Id> ids = new Set<Id>();
    for (OpportunityLineItem oli : (List<OpportunityLineItem>) Trigger.old) {
      if (oli.OpportunityId != null) {
        ids.add(oli.OpportunityId);
      }
    }
    return ids;
  }

  // -------------------------------------------------------------------------
  // Recalc + DML
  // -------------------------------------------------------------------------

  private void recalcParents(Set<Id> parentOppIds) {
    if (parentOppIds.isEmpty()) {
      return;
    }
    Map<Id, Opportunity> parents = new Map<Id, Opportunity>(
      [
        SELECT
          Id,
          Amount,
          ARR__c,
          ACV__c,
          Is_Discounted__c,
          Subscription_Term_Months__c,
          Billing_Frequency__c
        FROM Opportunity
        WHERE Id IN :parentOppIds
      ]
    );
    if (parents.isEmpty()) {
      return;
    }

    Map<Id, List<OpportunityLineItem>> olisByOppId = fetchOLIsByParent(
      parents.keySet()
    );
    if (olisByOppId == null) {
      // Overflow — fail fast on the OLI changes that triggered this
      // handler rather than silently committing partial rollups.
      failBatchOnOverflow();
      return;
    }

    // Stash current ARR/ACV/Is_Discounted so we can compare and only update
    // when changed.
    Map<Id, Decimal> priorArr = new Map<Id, Decimal>();
    Map<Id, Decimal> priorAcv = new Map<Id, Decimal>();
    Map<Id, Boolean> priorDiscounted = new Map<Id, Boolean>();
    for (Opportunity p : parents.values()) {
      priorArr.put(p.Id, p.ARR__c);
      priorAcv.put(p.Id, p.ACV__c);
      priorDiscounted.put(p.Id, p.Is_Discounted__c);
    }

    RevenueCalculationService.recalculate(parents.values(), olisByOppId);

    // Roll the per-line Discount up to a header "is discounted" flag (issue
    ): true when any OLI carries a Discount >0. This is the
    // honest signal the Discount_Reason_Required_High_Value VR keys off,
    // replacing the Amount >= 100k proxy.
    for (Opportunity p : parents.values()) {
      p.Is_Discounted__c = anyLineDiscounted(olisByOppId.get(p.Id));
    }

    List<Opportunity> toUpdate = new List<Opportunity>();
    for (Opportunity p : parents.values()) {
      if (
        p.ARR__c != priorArr.get(p.Id) ||
        p.ACV__c != priorAcv.get(p.Id) ||
        p.Is_Discounted__c != priorDiscounted.get(p.Id)
      ) {
        toUpdate.add(p);
      }
    }
    if (!toUpdate.isEmpty()) {
      update toUpdate;
    }
  }

  /**
   * Calls addError on every OLI in the triggering batch (both Trigger.new
   * and Trigger.old where relevant) so the underlying OLI insert / update /
   * delete is rolled back rather than committed with a partial parent
   * rollup. Single addError on every row in the firing batch is enough —
   * the platform rolls back the whole transaction.
   */
  private static void failBatchOnOverflow() {
    String err =
      'OpportunityLineItem rollup requires fetching more line items than ' +
      'is safe to query in one transaction (over ' +
      OLI_ROW_CAP +
      ' rows). Parent Opportunity ARR/ACV would be partial. Split this ' +
      'product edit into smaller batches and try again.';
    // Trigger.new is populated for insert/update/undelete; Trigger.old is
    // populated for update/delete. Adding the error to either rolls back.
    if (Trigger.new != null) {
      for (SObject sob : Trigger.new) {
        sob.addError(err);
      }
      return;
    }
    if (Trigger.old != null) {
      for (SObject sob : Trigger.old) {
        sob.addError(err);
      }
    }
  }

  /**
   * Returns null on overflow (>OLI_ROW_CAP rows). The caller MUST handle
   * the null case and fail the transaction — recalculating on partial
   * data would persist understated ARR/ACV across affected parents.
   * Uses LIMIT OLI_ROW_CAP + 1 so a single row over the cap signals
   * overflow without crossing the 50,000-row platform governor.
   */
  private static Map<Id, List<OpportunityLineItem>> fetchOLIsByParent(
    Set<Id> parentOppIds
  ) {
    Map<Id, List<OpportunityLineItem>> out = new Map<Id, List<OpportunityLineItem>>();
    Integer queryLimit = OLI_ROW_CAP + 1;
    List<OpportunityLineItem> rows = [
      SELECT
        OpportunityId,
        TotalPrice,
        Quantity,
        UnitPrice,
        Discount,
        Revenue_Type__c
      FROM OpportunityLineItem
      WHERE OpportunityId IN :parentOppIds
      LIMIT :queryLimit
    ];
    if (rows.size() > OLI_ROW_CAP) {
      return null;
    }
    for (OpportunityLineItem oli : rows) {
      if (!out.containsKey(oli.OpportunityId)) {
        out.put(oli.OpportunityId, new List<OpportunityLineItem>());
      }
      out.get(oli.OpportunityId).add(oli);
    }
    return out;
  }

  /**
   * True when any line in the parent's OLI set carries a positive per-line
   * Discount. Null/empty list (no products) is not discounted.
   */
  private static Boolean anyLineDiscounted(List<OpportunityLineItem> olis) {
    if (olis == null) {
      return false;
    }
    for (OpportunityLineItem oli : olis) {
      if (oli.Discount != null && oli.Discount > 0) {
        return true;
      }
    }
    return false;
  }
}
