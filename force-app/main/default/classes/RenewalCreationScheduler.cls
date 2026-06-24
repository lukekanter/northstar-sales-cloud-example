/**
 * RenewalCreationScheduler — the daily renewal-creation fallback
 * (the deferred renewal-scheduling seam).
 *
 * Runs as both a Schedulable (cron entry point) and a Database.Batchable so a
 * large book of contracts is processed in governor-safe chunks. Each batch
 * hands its scope of Activated, not-yet-renewed contracts to
 * RenewalService.createRenewalOpportunity, which already applies the per-tier
 * renewal window (Days_To_Renewal__c <= rule.Days_Before_Renewal__c) and the
 * idempotency guards. Re-running daily is exactly how a contract that was
 * "not yet in window" yesterday gets its renewal Opp once it crosses the
 * threshold — so this class deliberately does NOT duplicate the window/rule
 * logic that lives in RenewalService.
 *
 * Not auto-scheduled — see config/developer-org-setup-checklist.md for the
 * System.schedule(...) command (non-goal: no CRON metadata).
 */
public with sharing class RenewalCreationScheduler implements Schedulable, Database.Batchable<SObject> {
  @TestVisible
  private static final String CONTRACT_STATUS_ACTIVATED = 'Activated';

  // Capture for assertions.
  @TestVisible
  private static Integer lastContractsProcessed = 0;

  /** Schedulable entry point — kick off the batch. */
  public void execute(SchedulableContext sc) {
    Database.executeBatch(this, 200);
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    // Only scan contracts whose effective end date is within the widest
    // renewal window any rule defines (Days_To_Renewal__c <= max
    // Days_Before_Renewal__c, expressed on the indexable raw date field rather
    // than the TODAY()-based formula). This keeps the daily batch off the
    // far-future renewal population, which RenewalService would only defer
    // anyway. Opted-out contracts are excluded here too —
    // RenewalService skips them.
    //
    // The window must be evaluated on the SAME effective end date
    // RenewalService uses: Subscription_End_Date__c when populated, else the
    // standard EndDate fallback (RenewalService.cls coalesce). Filtering on the
    // mirror field alone would silently drop activated contracts that carry
    // only EndDate, so the daily fallback would never revisit them once they
    // enter the window. A null-safe `<=` in SOQL already
    // excludes records whose compared field is null, so the OR branch covers
    // exactly the "mirror blank, EndDate present" population.
    Date cutoff = Date.today().addDays(maxDaysBeforeRenewal());
    return Database.getQueryLocator(
      [
        SELECT Id
        FROM Contract
        WHERE
          Status = :CONTRACT_STATUS_ACTIVATED
          AND Renewal_Created__c = FALSE
          AND Renewal_Opportunity__c = NULL
          AND Auto_Renewal_Enabled__c = TRUE
          AND (Subscription_End_Date__c <= :cutoff
          OR (Subscription_End_Date__c = NULL
          AND EndDate <= :cutoff))
      ]
    );
  }

  /**
   * Widest renewal lead time across the seeded Renewal_Creation_Rule__mdt rows
   * (Standard 60 / Premium Enterprise 90 today). RenewalService still applies
   * the exact per-tier window per contract; this is just the coarse query
   * bound. Falls back to 0 (only at/past end date) if no rules are seeded.
   */
  private static Integer maxDaysBeforeRenewal() {
    Integer maxDays = 0;
    for (
      Renewal_Creation_Rule__mdt rule : Renewal_Creation_Rule__mdt.getAll()
        .values()
    ) {
      if (
        rule.Days_Before_Renewal__c != null &&
        rule.Days_Before_Renewal__c.intValue() > maxDays
      ) {
        maxDays = rule.Days_Before_Renewal__c.intValue();
      }
    }
    return maxDays;
  }

  public void execute(Database.BatchableContext bc, List<Contract> scope) {
    Set<Id> contractIds = new Map<Id, Contract>(scope).keySet();
    RenewalService.createRenewalOpportunity(contractIds);
    lastContractsProcessed += scope.size();
  }

  public void finish(Database.BatchableContext bc) {
    System.debug(
      LoggingLevel.INFO,
      'RenewalCreationScheduler processed ' +
        lastContractsProcessed +
        ' candidate contract(s).'
    );
  }
}
