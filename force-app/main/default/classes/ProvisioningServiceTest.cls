/**
 * ProvisioningServiceTest — covers every branch in ProvisioningService.
 *
 * Tests drive the service directly (dispatch on draft orders) so they don't
 * depend on Order activation mechanics — OrderTriggerHandlerTest covers the
 * activation gate. Rules are injected via the @TestVisible override so the
 * suite is independent of which Product_Provisioning_Rule__mdt records are
 * seeded; one test deliberately omits the override to exercise the real
 * getAll() path against the deployed seed.
 */
@IsTest
private class ProvisioningServiceTest {
  private static final String FAM_AI_DISPATCH = 'AI Dispatch Add-On';
  private static final String FAM_CORE = 'Core Platform';
  private static final String FAM_TRAINING = 'Training';

  // -------------------------------------------------------------------------
  // AI Dispatch — event + Case + Order stamp
  // -------------------------------------------------------------------------

  @IsTest
  static void aiDispatchOrderPublishesEventCaseAndStamp() {
    Order ord = seedOrderWithFamily(FAM_AI_DISPATCH);
    ProvisioningService.rulesOverrideForTest = ruleMap(
      FAM_AI_DISPATCH,
      true,
      true
    );

    Test.startTest();
    ProvisioningService.dispatch(new Set<Id>{ ord.Id });
    Test.stopTest();

    List<Provisioning_Requested__e> events = ProvisioningService.lastEvents;
    System.assertEquals(1, events.size(), 'One provisioning event expected.');
    Provisioning_Requested__e e = events[0];
    System.assertEquals(ord.Id, e.Order_Id__c);
    System.assertEquals(ord.AccountId, e.Account_Id__c);
    System.assertEquals(FAM_AI_DISPATCH, e.Product_Family__c);
    System.assertEquals(true, e.Requires_AI_Dispatch__c);
    System.assert(
      ProvisioningService.lastPublishResults[0].isSuccess(),
      'Publish should succeed.'
    );

    Order got = [
      SELECT
        Provisioning_Status__c,
        Requires_AI_Dispatch_Setup__c,
        Provisioning_Started_At__c
      FROM Order
      WHERE Id = :ord.Id
    ];
    System.assertEquals('Pending', got.Provisioning_Status__c);
    System.assertEquals(true, got.Requires_AI_Dispatch_Setup__c);
    System.assertNotEquals(
      null,
      got.Provisioning_Started_At__c,
      'Provisioning start time should be stamped.'
    );

    List<Case> cases = [
      SELECT
        Case_Category__c,
        Related_Order__c,
        OwnerId,
        Origin,
        RecordType.DeveloperName
      FROM Case
      WHERE Related_Order__c = :ord.Id
    ];
    System.assertEquals(1, cases.size(), 'One provisioning Case expected.');
    System.assertEquals('Provisioning', cases[0].Case_Category__c);
    System.assertEquals(
      'Provisioning',
      cases[0].RecordType.DeveloperName,
      'Provisioning Case should carry the Provisioning record type.'
    );
    System.assertEquals(
      null,
      cases[0].Origin,
      'Origin is left unset (CaseOrigin SVS has no Provisioning value).'
    );
    System.assert(
      String.valueOf(cases[0].OwnerId).startsWith('00G'),
      'Case should be owned by the Provisioning Exceptions queue (Group), got: ' +
      cases[0].OwnerId
    );
  }

  // -------------------------------------------------------------------------
  // Provisioning family WITHOUT AI dispatch — event + stamp, no Case
  // -------------------------------------------------------------------------

  @IsTest
  static void provisioningWithoutAIDispatchPublishesEventNoCase() {
    Order ord = seedOrderWithFamily(FAM_CORE);
    ProvisioningService.rulesOverrideForTest = ruleMap(FAM_CORE, true, false);

    Test.startTest();
    ProvisioningService.dispatch(new Set<Id>{ ord.Id });
    Test.stopTest();

    System.assertEquals(1, ProvisioningService.lastEvents.size());
    System.assertEquals(
      false,
      ProvisioningService.lastEvents[0].Requires_AI_Dispatch__c
    );

    Order got = [
      SELECT
        Provisioning_Status__c,
        Requires_AI_Dispatch_Setup__c,
        Provisioning_Started_At__c
      FROM Order
      WHERE Id = :ord.Id
    ];
    System.assertEquals('Pending', got.Provisioning_Status__c);
    System.assertEquals(false, got.Requires_AI_Dispatch_Setup__c);
    System.assertNotEquals(
      null,
      got.Provisioning_Started_At__c,
      'A provisioning order still gets its start time stamped.'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Case WHERE Related_Order__c = :ord.Id],
      'No Case when the rule does not require AI dispatch.'
    );
  }

  // -------------------------------------------------------------------------
  // No matching rule — nothing happens
  // -------------------------------------------------------------------------

  @IsTest
  static void familyWithNoRulePublishesNothing() {
    Order ord = seedOrderWithFamily(FAM_TRAINING);
    // Override has only an AI-dispatch rule; the Training line matches none.
    ProvisioningService.rulesOverrideForTest = ruleMap(
      FAM_AI_DISPATCH,
      true,
      true
    );

    Test.startTest();
    ProvisioningService.dispatch(new Set<Id>{ ord.Id });
    Test.stopTest();

    System.assertEquals(
      null,
      ProvisioningService.lastEvents,
      'No event should publish for a non-provisioning family.'
    );
    Order got = [
      SELECT Provisioning_Status__c, Provisioning_Started_At__c
      FROM Order
      WHERE Id = :ord.Id
    ];
    System.assertEquals(
      'Not Required',
      got.Provisioning_Status__c,
      'A non-provisioning order keeps its default status.'
    );
    System.assertEquals(
      null,
      got.Provisioning_Started_At__c,
      'A non-provisioning order is never stamped.'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Case WHERE Related_Order__c = :ord.Id]
    );
  }

  // -------------------------------------------------------------------------
  // Opportunity provisioning roll-up
  // -------------------------------------------------------------------------

  @IsTest
  static void noProvisioningOrderClearsOpportunityPending() {
    // 0067: a Closed Won deal whose Order needs no provisioning. The Opp was
    // stamped 'Pending' at close; dispatch must roll the Order's 'Not Required'
    // up so the Opp no longer reads Pending forever.
    Order ord = seedOrderWithFamily(FAM_TRAINING);
    Opportunity opp = linkSourceOpportunity(ord, 'Pending');
    ProvisioningService.rulesOverrideForTest = ruleMap(
      FAM_AI_DISPATCH,
      true,
      true
    );

    Test.startTest();
    ProvisioningService.dispatch(new Set<Id>{ ord.Id });
    Test.stopTest();

    System.assertEquals(
      'Not Required',
      [SELECT Provisioning_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Provisioning_Status__c,
      'A no-provisioning Order must roll Not Required up to its source Opportunity.'
    );
  }

  @IsTest
  static void provisioningOrderRollsPendingUpToOpportunity() {
    Order ord = seedOrderWithFamily(FAM_AI_DISPATCH);
    Opportunity opp = linkSourceOpportunity(ord, 'Not Required');
    ProvisioningService.rulesOverrideForTest = ruleMap(
      FAM_AI_DISPATCH,
      true,
      false
    );

    Test.startTest();
    ProvisioningService.dispatch(new Set<Id>{ ord.Id });
    Test.stopTest();

    System.assertEquals(
      'Pending',
      [SELECT Provisioning_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Provisioning_Status__c,
      'A provisioning Order must roll Pending up to its source Opportunity.'
    );
  }

  /**
   * Create a source Opportunity at the given provisioning status, link it to the
   * Order, and ACTIVATE the Order — dispatch only ever runs on activated Orders,
   * and the roll-up treats non-activated Orders as in-flight, so the test must
   * reflect that. OrderTriggerHandler is bypassed so activation doesn't
   * auto-dispatch (the test calls dispatch explicitly).
   */
  private static Opportunity linkSourceOpportunity(Order ord, String oppStatus) {
    Opportunity opp = TestDataFactory.buildOpportunities(
      1,
      new Map<String, Object>{
        'AccountId' => ord.AccountId,
        'StageName' => 'Qualify',
        'Provisioning_Status__c' => oppStatus
      }
    )[0];
    insert opp;
    // An Order can't be Activated without an Account AND a Contract (org VR).
    Contract con = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{ 'AccountId' => ord.AccountId }
    )[0];
    insert con;
    TriggerHandler.bypass('ContractTriggerHandler');
    try {
      update new Contract(Id = con.Id, Status = 'Activated');
    } finally {
      TriggerHandler.clearBypass('ContractTriggerHandler');
    }
    TriggerHandler.bypass('OrderTriggerHandler');
    try {
      update new Order(
        Id = ord.Id,
        Source_Opportunity__c = opp.Id,
        ContractId = con.Id,
        Status = 'Activated'
      );
    } finally {
      TriggerHandler.clearBypass('OrderTriggerHandler');
    }
    return opp;
  }

  // -------------------------------------------------------------------------
  // Real getAll() path against the deployed seed (AI_Dispatch_AddOn)
  // -------------------------------------------------------------------------

  @IsTest
  static void seededRuleResolvesViaGetAll() {
    Order ord = seedOrderWithFamily(FAM_AI_DISPATCH);
    // No override — exercises Product_Provisioning_Rule__mdt.getAll() and the
    // seeded AI_Dispatch_AddOn rule (Requires_Provisioning + AI dispatch).
    ProvisioningService.rulesOverrideForTest = null;

    Test.startTest();
    ProvisioningService.dispatch(new Set<Id>{ ord.Id });
    Test.stopTest();

    System.assertEquals(
      1,
      ProvisioningService.lastEvents.size(),
      'The deployed AI Dispatch rule should drive a provisioning event.'
    );
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Case WHERE Related_Order__c = :ord.Id]
    );
  }

  // -------------------------------------------------------------------------
  // Bulk
  // -------------------------------------------------------------------------

  @IsTest
  static void bulkActivationGovernorSafe() {
    update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
    Account acct = new Account(Name = 'NS Prov Bulk Acct');
    insert acct;
    Product2 p = new Product2(
      Name = 'NS Prov Bulk',
      Family = FAM_AI_DISPATCH,
      IsActive = true
    );
    insert p;
    insert new PricebookEntry(
      Pricebook2Id = Test.getStandardPricebookId(),
      Product2Id = p.Id,
      UnitPrice = 100,
      IsActive = true
    );
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :p.Id
      LIMIT 1
    ];

    List<Order> orders = TestDataFactory.buildOrders(200);
    for (Order o : orders) {
      o.AccountId = acct.Id;
      o.Pricebook2Id = Test.getStandardPricebookId();
    }
    insert orders;

    List<OrderItem> items = new List<OrderItem>();
    Set<Id> orderIds = new Set<Id>();
    for (Order o : orders) {
      orderIds.add(o.Id);
      items.add(
        new OrderItem(
          OrderId = o.Id,
          PricebookEntryId = pbe.Id,
          Quantity = 1,
          UnitPrice = 100
        )
      );
    }
    insert items;

    ProvisioningService.rulesOverrideForTest = ruleMap(
      FAM_AI_DISPATCH,
      true,
      true
    );

    Test.startTest();
    ProvisioningService.dispatch(orderIds);
    Test.stopTest();

    System.assertEquals(200, ProvisioningService.lastEvents.size());
    System.assertEquals(
      200,
      [SELECT COUNT() FROM Case WHERE Related_Order__c IN :orderIds]
    );
    System.assertEquals(
      200,
      [
        SELECT COUNT()
        FROM Order
        WHERE Id IN :orderIds AND Provisioning_Status__c = 'Pending'
      ]
    );
  }

  // -------------------------------------------------------------------------
  // Edge / unit
  // -------------------------------------------------------------------------

  @IsTest
  static void emptyInputIsNoOp() {
    Test.startTest();
    ProvisioningService.dispatch(new Set<Id>());
    ProvisioningService.dispatch(null);
    Test.stopTest();
    System.assertEquals(null, ProvisioningService.lastEvents);
  }

  @IsTest
  static void logPublishFailuresHandlesFailuresAndNull() {
    ProvisioningService.logPublishFailures(null); // no-op branch
    Database.SaveResult failed = (Database.SaveResult) JSON.deserialize(
      '{"success":false,"errors":[{"message":"simulated enqueue failure",' +
      '"statusCode":"FIELD_CUSTOM_VALIDATION_EXCEPTION","fields":[]}]}',
      Database.SaveResult.class
    );
    // Should iterate the failure and log it without throwing.
    ProvisioningService.logPublishFailures(
      new List<Database.SaveResult>{ failed }
    );
    System.assertEquals(
      false,
      failed.isSuccess(),
      'Synthesised result should be a failure.'
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private static Map<String, Product_Provisioning_Rule__mdt> ruleMap(
    String family,
    Boolean requiresProvisioning,
    Boolean requiresAIDispatch
  ) {
    return new Map<String, Product_Provisioning_Rule__mdt>{
      family => new Product_Provisioning_Rule__mdt(
        Product_Family__c = family,
        Requires_Provisioning__c = requiresProvisioning,
        Requires_AI_Dispatch_Setup__c = requiresAIDispatch
      )
    };
  }

  private static Order seedOrderWithFamily(String family) {
    update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
    Account a = new Account(
      Name = 'NS Prov Acct',
      Region__c = 'NA East',
      Customer_Segment__c = 'Commercial'
    );
    insert a;
    Product2 p = new Product2(
      Name = 'NS Prov Product ' + family,
      Family = family,
      IsActive = true
    );
    insert p;
    insert new PricebookEntry(
      Pricebook2Id = Test.getStandardPricebookId(),
      Product2Id = p.Id,
      UnitPrice = 100,
      IsActive = true
    );
    PricebookEntry pbe = [
      SELECT Id
      FROM PricebookEntry
      WHERE Product2Id = :p.Id
      LIMIT 1
    ];
    Order o = TestDataFactory.buildOrders(1)[0];
    o.AccountId = a.Id;
    o.Pricebook2Id = Test.getStandardPricebookId();
    insert o;
    insert new OrderItem(
      OrderId = o.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100
    );
    return o;
  }
}
