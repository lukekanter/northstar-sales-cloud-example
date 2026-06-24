/**
 * ContractHealthRecalcBatch — weekly recalculation of Contract.Health_Score__c
 * from each Account's open support load.
 *
 * Heuristic (— the spec is non-prescriptive, so this is a documented,
 * deterministic model): start every Activated contract at 100 and subtract a
 * penalty for each OPEN Case on the contract's Account —
 *   - 25 per open Case whose Renewal_Risk_Level__c is High or Critical,
 *   - 10 per other open Case,
 * then clamp to [0, 100]. Contracts on an Account with no open cases settle at
 * 100. Health_Score__c is a plain Number(3,0), updated in batches for
 * governor safety.
 *
 * Runs as Schedulable (weekly cron entry point) + Database.Batchable. Not
 * auto-scheduled — see config/developer-org-setup-checklist.md.
 */
public with sharing class ContractHealthRecalcBatch implements Schedulable, Database.Batchable<SObject> {
  @TestVisible
  private static final String CONTRACT_STATUS_ACTIVATED = 'Activated';
  @TestVisible
  private static final Integer BASELINE = 100;
  @TestVisible
  private static final Integer PENALTY_HIGH_RISK = 25;
  @TestVisible
  private static final Integer PENALTY_STANDARD = 10;

  private static final Set<String> HIGH_RISK_LEVELS = new Set<String>{
    'High',
    'Critical'
  };

  @TestVisible
  private static Integer lastContractsUpdated = 0;

  public void execute(SchedulableContext sc) {
    Database.executeBatch(this, 200);
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    return Database.getQueryLocator(
      [
        SELECT Id, AccountId, Health_Score__c
        FROM Contract
        WHERE Status = :CONTRACT_STATUS_ACTIVATED AND AccountId != NULL
      ]
    );
  }

  public void execute(Database.BatchableContext bc, List<Contract> scope) {
    Set<Id> accountIds = new Set<Id>();
    for (Contract con : scope) {
      accountIds.add(con.AccountId);
    }

    Map<Id, Integer> penaltyByAccount = penaltyByAccount(accountIds);

    List<Contract> updates = new List<Contract>();
    for (Contract con : scope) {
      Integer penalty = penaltyByAccount.containsKey(con.AccountId)
        ? penaltyByAccount.get(con.AccountId)
        : 0;
      Integer score = Math.max(0, Math.min(BASELINE, BASELINE - penalty));
      if (
        con.Health_Score__c == null ||
        con.Health_Score__c.intValue() != score
      ) {
        updates.add(new Contract(Id = con.Id, Health_Score__c = score));
      }
    }
    if (!updates.isEmpty()) {
      update updates;
      lastContractsUpdated += updates.size();
    }
  }

  public void finish(Database.BatchableContext bc) {
    System.debug(
      LoggingLevel.INFO,
      'ContractHealthRecalcBatch updated ' +
        lastContractsUpdated +
        ' contract health score(s).'
    );
  }

  /** Sum the open-Case penalty per Account. */
  private static Map<Id, Integer> penaltyByAccount(Set<Id> accountIds) {
    Map<Id, Integer> out = new Map<Id, Integer>();
    for (Case c : [
      SELECT AccountId, Renewal_Risk_Level__c
      FROM Case
      WHERE AccountId IN :accountIds AND IsClosed = FALSE
    ]) {
      Integer add = HIGH_RISK_LEVELS.contains(c.Renewal_Risk_Level__c)
        ? PENALTY_HIGH_RISK
        : PENALTY_STANDARD;
      Integer running = out.containsKey(c.AccountId) ? out.get(c.AccountId) : 0;
      out.put(c.AccountId, running + add);
    }
    return out;
  }
}
