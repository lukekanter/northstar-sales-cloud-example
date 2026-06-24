/**
 * RenewalCreationSchedulerTest — the daily batch hands Activated, not-yet-
 * renewed contracts to RenewalService, which creates renewals for those in
 * the window. Contract/Opportunity handlers are bypassed during setup so the
 * renewal isn't created by the activation trigger before the batch runs.
 */
@IsTest
private class RenewalCreationSchedulerTest {
  private static final String TIER_STANDARD = 'Standard';

  private static Map<String, Renewal_Creation_Rule__mdt> ruleMap(
    String tier,
    Integer daysBefore
  ) {
    return new Map<String, Renewal_Creation_Rule__mdt>{
      tier => new Renewal_Creation_Rule__mdt(
        Support_Tier__c = tier,
        Days_Before_Renewal__c = daysBefore,
        Sales_Motion__c = 'Renewal'
      )
    };
  }

  private static Account seedAccount() {
    Account a = TestDataFactory.buildAccounts(1)[0];
    insert a;
    return a;
  }

  private static Contract seedActivatedContract(Id accountId, Date endDate) {
    Contract c = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{
        'AccountId' => accountId,
        'Support_Tier__c' => TIER_STANDARD,
        'Subscription_End_Date__c' => endDate,
        'Renewal_Created__c' => false
      }
    )[0];
    insert c; // factory default Status = 'Draft'
    // Draft -> Activated is the supported activation transition; a Contract
    // cannot be inserted directly in Activated status (FAILED_ACTIVATION).
    c.Status = 'Activated';
    update c;
    return c;
  }

  @IsTest
  static void inWindowContractGetsRenewalViaSchedule() {
    TestDataFactory.bypassTriggers(
      new List<String>{ 'ContractTriggerHandler', 'OpportunityTriggerHandler' }
    );
    Account acct = seedAccount();
    // End date 30 days out; Standard rule renews 60 days out → in window.
    Contract con = seedActivatedContract(acct.Id, Date.today().addDays(30));
    TestDataFactory.restoreTriggers();

    RenewalService.rulesOverrideForTest = ruleMap(TIER_STANDARD, 60);

    Test.startTest();
    // Drive the Schedulable entry point, which kicks off the batch.
    new RenewalCreationScheduler().execute((SchedulableContext) null);
    Test.stopTest();

    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c = :con.Id
      ],
      'The scheduler should create the in-window renewal Opportunity.'
    );
  }

  /**
   * Activated contract whose custom mirror Subscription_End_Date__c is blank
   * but whose standard EndDate (StartDate + ContractTerm) lands in window.
   * RenewalService coalesces to EndDate, so the batch query must surface this
   * record too — otherwise the daily fallback would never revisit it once it
   * crossed the window.
   */
  @IsTest
  static void endDateFallbackContractGetsRenewal() {
    TestDataFactory.bypassTriggers(
      new List<String>{ 'ContractTriggerHandler', 'OpportunityTriggerHandler' }
    );
    Account acct = seedAccount();
    // Mirror field null; 1-month term from today → EndDate ~30 days out, well
    // inside the 60-day Standard window.
    Contract c = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{
        'AccountId' => acct.Id,
        'Support_Tier__c' => TIER_STANDARD,
        'StartDate' => Date.today(),
        'ContractTerm' => 1,
        'Subscription_End_Date__c' => null,
        'Renewal_Created__c' => false
      }
    )[0];
    insert c; // factory default Status = 'Draft'
    c.Status = 'Activated';
    update c;
    TestDataFactory.restoreTriggers();

    RenewalService.rulesOverrideForTest = ruleMap(TIER_STANDARD, 60);

    Test.startTest();
    Database.executeBatch(new RenewalCreationScheduler(), 200);
    Test.stopTest();

    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c = :c.Id
      ],
      'A contract carrying only the standard EndDate must still be renewed.'
    );
  }

  @IsTest
  static void notInWindowContractIsNotRenewedYet() {
    TestDataFactory.bypassTriggers(
      new List<String>{ 'ContractTriggerHandler', 'OpportunityTriggerHandler' }
    );
    Account acct = seedAccount();
    // Far from the 60-day window → batch passes it through, RenewalService defers.
    Contract con = seedActivatedContract(acct.Id, Date.today().addDays(300));
    TestDataFactory.restoreTriggers();

    RenewalService.rulesOverrideForTest = ruleMap(TIER_STANDARD, 60);

    Test.startTest();
    Database.executeBatch(new RenewalCreationScheduler(), 200);
    Test.stopTest();

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c = :con.Id
      ],
      'A contract still outside its window must not be renewed yet.'
    );
  }
}
