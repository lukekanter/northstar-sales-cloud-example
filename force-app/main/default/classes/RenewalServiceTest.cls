/**
 * RenewalServiceTest — covers every branch in RenewalService.
 *
 * The Opportunity trigger is bypassed throughout (per the issue note) so the
 * renewal-Opp creation isn't coupled to revenue/territory logic.
 * The Contract trigger stays active so the link-back update exercises the
 * bookkeeping stamp. Rules are injected via the @TestVisible override; one
 * test omits it to exercise the real getAll() path against the seeds.
 */
@IsTest
private class RenewalServiceTest {
  private static final String TIER_STANDARD = 'Standard';
  private static final String TIER_24X7 = '24x7';
  private static final String SOURCE_TERM = '24 Months';

  // -------------------------------------------------------------------------
  // Synchronous creation (contract already inside the renewal window)
  // -------------------------------------------------------------------------

  @IsTest
  static void inWindowCreatesRenewalOpportunity() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Account acct = seedAccount();
    Id srcOpp = seedSourceOpp(acct.Id);
    // End date 30 days out; Standard rule renews 60 days out → due now.
    Contract con = seedContract(
      acct.Id,
      TIER_STANDARD,
      Date.today().addDays(30),
      srcOpp
    );
    RenewalService.rulesOverrideForTest = ruleMap(TIER_STANDARD, 60);

    Test.startTest();
    RenewalService.createRenewalOpportunity(new Set<Id>{ con.Id });
    Test.stopTest();

    System.assertEquals(1, RenewalService.lastRenewalsCreated.size());
    Opportunity opp = [
      SELECT
        Name,
        AccountId,
        StageName,
        CloseDate,
        Sales_Motion__c,
        Subscription_Term_Months__c,
        Renewal_Source_Contract__c,
        RecordType.DeveloperName
      FROM Opportunity
      WHERE Renewal_Source_Contract__c = :con.Id
    ];
    System.assertEquals(acct.Id, opp.AccountId);
    System.assertEquals('Qualify', opp.StageName);
    System.assertEquals('Renewal', opp.Sales_Motion__c);
    System.assertEquals('Renewal', opp.RecordType.DeveloperName);
    System.assertEquals(
      SOURCE_TERM,
      opp.Subscription_Term_Months__c,
      'Term should be copied from the source Opportunity.'
    );
    System.assertEquals(Date.today().addDays(30), opp.CloseDate);

    Contract got = [
      SELECT Renewal_Opportunity__c, Renewal_Created__c, Renewal_Created_Date__c
      FROM Contract
      WHERE Id = :con.Id
    ];
    System.assertEquals(opp.Id, got.Renewal_Opportunity__c);
    System.assertEquals(true, got.Renewal_Created__c);
    System.assertEquals(Date.today(), got.Renewal_Created_Date__c);
  }

  // -------------------------------------------------------------------------
  // Flow-callable @InvocableMethod
  // -------------------------------------------------------------------------

  @IsTest
  static void invocableCreatesRenewalAndIsIdempotent() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Account acct = seedAccount();
    Id srcOpp = seedSourceOpp(acct.Id);
    Contract con = seedContract(
      acct.Id,
      TIER_STANDARD,
      Date.today().addDays(30),
      srcOpp
    );
    RenewalService.rulesOverrideForTest = ruleMap(TIER_STANDARD, 60);

    Test.startTest();
    // Flow entry point: List<Id> in, delegates to createRenewalOpportunity.
    RenewalService.createRenewalsFromFlow(new List<Id>{ con.Id });
    // Re-run must not double-create (idempotent on Renewal_Created__c).
    RenewalService.createRenewalsFromFlow(new List<Id>{ con.Id });
    Test.stopTest();

    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c = :con.Id
      ],
      'Invocable should create exactly one renewal and be idempotent on re-run.'
    );
  }

  @IsTest
  static void invocableEmptyAndNullAreNoOp() {
    Test.startTest();
    RenewalService.createRenewalsFromFlow(new List<Id>());
    RenewalService.createRenewalsFromFlow(null);
    Test.stopTest();

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c != NULL
      ],
      'Empty/null input must be a no-op.'
    );
  }

  // -------------------------------------------------------------------------
  // Deferred (window still in the future)
  // -------------------------------------------------------------------------

  @IsTest
  static void notInWindowDefersRenewal() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Account acct = seedAccount();
    Contract con = seedContract(
      acct.Id,
      TIER_STANDARD,
      Date.today().addDays(300), // far from the 60-day window
      null
    );
    RenewalService.rulesOverrideForTest = ruleMap(TIER_STANDARD, 60);

    Test.startTest();
    RenewalService.createRenewalOpportunity(new Set<Id>{ con.Id });
    Test.stopTest();

    System.assertEquals(
      null,
      RenewalService.lastRenewalsCreated,
      'Nothing should be created synchronously yet.'
    );
    System.assertEquals(
      new List<Id>{ con.Id },
      RenewalService.lastDeferredContractIds,
      'The contract should be queued for the deferred scheduler (0027).'
    );
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c = :con.Id
      ]
    );
    System.assertEquals(
      false,
      [SELECT Renewal_Created__c FROM Contract WHERE Id = :con.Id]
      .Renewal_Created__c
    );
  }

  // -------------------------------------------------------------------------
  // No rule for the contract's tier — skipped entirely
  // -------------------------------------------------------------------------

  @IsTest
  static void noRuleForTierSkips() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Account acct = seedAccount();
    Contract con = seedContract(
      acct.Id,
      TIER_24X7,
      Date.today().addDays(30),
      null
    );
    // Override only has a Standard rule; the 24x7 contract matches none.
    RenewalService.rulesOverrideForTest = ruleMap(TIER_STANDARD, 60);

    Test.startTest();
    RenewalService.createRenewalOpportunity(new Set<Id>{ con.Id });
    Test.stopTest();

    System.assertEquals(null, RenewalService.lastRenewalsCreated);
    System.assertEquals(null, RenewalService.lastDeferredContractIds);
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c = :con.Id
      ]
    );
  }

  // -------------------------------------------------------------------------
  // Idempotency — already-renewed contract is never re-created
  // -------------------------------------------------------------------------

  @IsTest
  static void alreadyRenewedIsSkipped() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Account acct = seedAccount();
    Contract con = seedContract(
      acct.Id,
      TIER_STANDARD,
      Date.today().addDays(30),
      null
    );
    // Mark it already renewed (insert-time, so the contract trigger's
    // update path isn't involved).
    con.Renewal_Created__c = true;
    update con;
    RenewalService.rulesOverrideForTest = ruleMap(TIER_STANDARD, 60);

    Test.startTest();
    RenewalService.createRenewalOpportunity(new Set<Id>{ con.Id });
    Test.stopTest();

    System.assertEquals(null, RenewalService.lastRenewalsCreated);
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c = :con.Id
      ]
    );
  }

  // -------------------------------------------------------------------------
  // Auto-renewal opt-out — in-window contract with the flag unchecked is skipped
  // -------------------------------------------------------------------------

  @IsTest
  static void optedOutContractIsSkipped() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Account acct = seedAccount();
    // In-window (would otherwise create now), but auto-renewal opted out.
    Contract con = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{
        'AccountId' => acct.Id,
        'Support_Tier__c' => TIER_STANDARD,
        'Subscription_End_Date__c' => Date.today().addDays(30),
        'Auto_Renewal_Enabled__c' => false
      }
    )[0];
    insert con;
    RenewalService.rulesOverrideForTest = ruleMap(TIER_STANDARD, 60);

    Test.startTest();
    RenewalService.createRenewalOpportunity(new Set<Id>{ con.Id });
    Test.stopTest();

    System.assertEquals(
      null,
      RenewalService.lastRenewalsCreated,
      'An opted-out contract must not create a renewal synchronously.'
    );
    System.assertEquals(
      null,
      RenewalService.lastDeferredContractIds,
      'An opted-out contract must not be deferred either.'
    );
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c = :con.Id
      ]
    );
  }

  // -------------------------------------------------------------------------
  // Real getAll() path against the deployed seeds
  // -------------------------------------------------------------------------

  @IsTest
  static void seededRuleResolvesViaGetAll() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Account acct = seedAccount();
    Contract con = seedContract(
      acct.Id,
      TIER_STANDARD,
      Date.today().addDays(30),
      null
    );
    RenewalService.rulesOverrideForTest = null; // exercise getAll()

    Test.startTest();
    RenewalService.createRenewalOpportunity(new Set<Id>{ con.Id });
    Test.stopTest();

    System.assertEquals(
      1,
      [
        SELECT COUNT()
        FROM Opportunity
        WHERE Renewal_Source_Contract__c = :con.Id
      ],
      'The seeded Standard rule should drive a synchronous renewal.'
    );
  }

  // -------------------------------------------------------------------------
  // Bulk
  // -------------------------------------------------------------------------

  @IsTest
  static void bulkGovernorSafe() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    Account acct = seedAccount();
    List<Contract> contracts = TestDataFactory.buildContracts(200);
    for (Contract c : contracts) {
      c.AccountId = acct.Id;
      c.Support_Tier__c = TIER_STANDARD;
      c.Subscription_End_Date__c = Date.today().addDays(30);
    }
    insert contracts;
    Set<Id> ids = new Map<Id, Contract>(contracts).keySet();
    RenewalService.rulesOverrideForTest = ruleMap(TIER_STANDARD, 60);

    Test.startTest();
    RenewalService.createRenewalOpportunity(ids);
    Test.stopTest();

    System.assertEquals(
      200,
      [SELECT COUNT() FROM Opportunity WHERE Renewal_Source_Contract__c IN :ids]
    );
    System.assertEquals(
      200,
      [
        SELECT COUNT()
        FROM Contract
        WHERE Id IN :ids AND Renewal_Created__c = TRUE
      ]
    );
  }

  @IsTest
  static void emptyInputIsNoOp() {
    Test.startTest();
    RenewalService.createRenewalOpportunity(new Set<Id>());
    RenewalService.createRenewalOpportunity(null);
    Test.stopTest();
    System.assertEquals(null, RenewalService.lastRenewalsCreated);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

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
    Account a = new Account(
      Name = 'NS Renewal Acct',
      Region__c = 'NA East',
      Customer_Segment__c = 'Commercial'
    );
    insert a;
    return a;
  }

  private static Id seedSourceOpp(Id accountId) {
    Opportunity o = TestDataFactory.buildOpportunities(1)[0];
    o.AccountId = accountId;
    o.StageName = 'Qualify';
    o.Subscription_Term_Months__c = SOURCE_TERM;
    insert o;
    return o.Id;
  }

  private static Contract seedContract(
    Id accountId,
    String tier,
    Date endDate,
    Id sourceOppId
  ) {
    Contract c = TestDataFactory.buildContracts(1)[0];
    c.AccountId = accountId;
    c.Support_Tier__c = tier;
    c.Subscription_End_Date__c = endDate;
    if (sourceOppId != null) {
      c.Source_Opportunity__c = sourceOppId;
    }
    insert c;
    return c;
  }
}
