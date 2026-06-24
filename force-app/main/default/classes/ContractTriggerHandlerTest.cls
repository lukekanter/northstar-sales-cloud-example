/**
 * ContractTriggerHandlerTest — covers the activation gate and the renewal
 * bookkeeping stamp (the renewal fan-out itself is covered by
 * RenewalServiceTest). The Opportunity trigger is bypassed so the renewal Opp
 * created on activation isn't coupled.
 */
@IsTest
private class ContractTriggerHandlerTest {
  private static final String TIER_STANDARD = 'Standard';

  @IsTest
  static void activationCreatesRenewalAndStamps() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Contract con = seedDraftContract(Date.today().addDays(30));
    RenewalService.rulesOverrideForTest = standardRule();

    Test.startTest();
    con.Status = 'Activated';
    update con;
    Test.stopTest();

    System.assertNotEquals(
      null,
      RenewalService.lastRenewalsCreated,
      'Activation should have created a renewal.'
    );
    Contract got = [
      SELECT Renewal_Opportunity__c, Renewal_Created__c, Renewal_Created_Date__c
      FROM Contract
      WHERE Id = :con.Id
    ];
    System.assertNotEquals(null, got.Renewal_Opportunity__c);
    System.assertEquals(true, got.Renewal_Created__c);
    System.assertEquals(Date.today(), got.Renewal_Created_Date__c);
    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c = :con.Id
      ]
    );
  }

  @IsTest
  static void nonActivationUpdateDoesNotCreate() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Contract con = seedDraftContract(Date.today().addDays(30));
    RenewalService.rulesOverrideForTest = standardRule();

    Test.startTest();
    con.Description = 'touched but still Draft';
    update con;
    Test.stopTest();

    System.assertEquals(
      null,
      RenewalService.lastRenewalsCreated,
      'A non-activation update must not create a renewal.'
    );
  }

  @IsTest
  static void beforeUpdateStampsWhenRenewalOppLinked() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Contract con = seedDraftContract(Date.today().addDays(30));

    Opportunity opp = new Opportunity(
      Name = 'Manual renewal',
      StageName = 'Qualify',
      CloseDate = Date.today().addDays(30)
    );
    insert opp;

    // Link the renewal Opp manually — the beforeUpdate stamp should fire.
    con.Renewal_Opportunity__c = opp.Id;
    update con;

    Contract got = [
      SELECT Renewal_Created__c, Renewal_Created_Date__c
      FROM Contract
      WHERE Id = :con.Id
    ];
    System.assertEquals(true, got.Renewal_Created__c);
    System.assertEquals(Date.today(), got.Renewal_Created_Date__c);
  }

  @IsTest
  static void bypassedHandlerSkipsRenewal() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Contract con = seedDraftContract(Date.today().addDays(30));
    RenewalService.rulesOverrideForTest = standardRule();

    TriggerHandler.bypass('ContractTriggerHandler');
    try {
      Test.startTest();
      con.Status = 'Activated';
      update con;
      Test.stopTest();
    } finally {
      TriggerHandler.clearBypass('ContractTriggerHandler');
    }

    System.assertEquals(
      null,
      RenewalService.lastRenewalsCreated,
      'A bypassed handler must not create a renewal.'
    );
    System.assertEquals(
      false,
      [SELECT Renewal_Created__c FROM Contract WHERE Id = :con.Id]
      .Renewal_Created__c
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private static Map<String, Renewal_Creation_Rule__mdt> standardRule() {
    return new Map<String, Renewal_Creation_Rule__mdt>{
      TIER_STANDARD => new Renewal_Creation_Rule__mdt(
        Support_Tier__c = TIER_STANDARD,
        Days_Before_Renewal__c = 60,
        Sales_Motion__c = 'Renewal'
      )
    };
  }

  private static Contract seedDraftContract(Date endDate) {
    Account a = new Account(
      Name = 'NS Contract Acct',
      Region__c = 'NA East',
      Customer_Segment__c = 'Commercial'
    );
    insert a;
    Contract c = TestDataFactory.buildContracts(1)[0];
    c.AccountId = a.Id;
    c.Support_Tier__c = TIER_STANDARD;
    c.Subscription_End_Date__c = endDate;
    insert c;
    return c;
  }
}
