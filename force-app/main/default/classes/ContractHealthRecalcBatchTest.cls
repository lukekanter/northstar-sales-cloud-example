/**
 * ContractHealthRecalcBatchTest — the weekly batch scores each Activated
 * contract from its Account's open-case load: 100 − (25 per High/Critical open
 * case + 10 per other open case), clamped to [0, 100].
 */
@IsTest
private class ContractHealthRecalcBatchTest {
  private static Account seedAccount() {
    Account a = TestDataFactory.buildAccounts(1)[0];
    insert a;
    return a;
  }

  private static Contract seedActivatedContract(Id accountId) {
    Contract c = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{
        'AccountId' => accountId,
        'Health_Score__c' => 80
      }
    )[0];
    insert c; // factory default Status = 'Draft'
    // Draft -> Activated is the supported activation transition; a Contract
    // cannot be inserted directly in Activated status (FAILED_ACTIVATION).
    c.Status = 'Activated';
    update c;
    return c;
  }

  private static void seedCases(
    Id accountId,
    Integer highRisk,
    Integer standard
  ) {
    List<Case> cases = new List<Case>();
    for (Integer i = 0; i < highRisk; i++) {
      cases.addAll(
        TestDataFactory.buildCases(
          1,
          new Map<String, Object>{
            'AccountId' => accountId,
            'Case_Category__c' => 'Renewal Risk',
            'Renewal_Risk_Level__c' => 'High',
            'Status' => 'New'
          }
        )
      );
    }
    for (Integer i = 0; i < standard; i++) {
      cases.addAll(
        TestDataFactory.buildCases(
          1,
          new Map<String, Object>{
            'AccountId' => accountId,
            'Case_Category__c' => 'Customer Support',
            'Status' => 'New'
          }
        )
      );
    }
    insert cases;
  }

  @IsTest
  static void scoresReflectOpenCaseLoad() {
    TestDataFactory.bypassTriggers(
      new List<String>{ 'ContractTriggerHandler', 'CaseTriggerHandler' }
    );
    Account withCases = seedAccount();
    Account clean = seedAccount();
    Contract conWith = seedActivatedContract(withCases.Id);
    Contract conClean = seedActivatedContract(clean.Id);
    // 1 High-risk (25) + 1 standard (10) = 35 penalty → 65.
    seedCases(withCases.Id, 1, 1);
    TestDataFactory.restoreTriggers();

    Test.startTest();
    new ContractHealthRecalcBatch().execute((SchedulableContext) null);
    Test.stopTest();

    Map<Id, Contract> got = new Map<Id, Contract>(
      [SELECT Id, Health_Score__c FROM Contract]
    );
    System.assertEquals(
      65,
      got.get(conWith.Id).Health_Score__c,
      'Account with one High-risk + one standard open case → 100-35=65.'
    );
    System.assertEquals(
      100,
      got.get(conClean.Id).Health_Score__c,
      'Account with no open cases → baseline 100.'
    );
  }

  @IsTest
  static void scoreFloorsAtZero() {
    TestDataFactory.bypassTriggers(
      new List<String>{ 'ContractTriggerHandler', 'CaseTriggerHandler' }
    );
    Account acct = seedAccount();
    Contract con = seedActivatedContract(acct.Id);
    // 5 High-risk open cases = 125 penalty → clamps to 0.
    seedCases(acct.Id, 5, 0);
    TestDataFactory.restoreTriggers();

    Test.startTest();
    Database.executeBatch(new ContractHealthRecalcBatch(), 200);
    Test.stopTest();

    System.assertEquals(
      0,
      [SELECT Health_Score__c FROM Contract WHERE Id = :con.Id].Health_Score__c,
      'Penalty beyond 100 must clamp the score to 0, not go negative.'
    );
  }
}
