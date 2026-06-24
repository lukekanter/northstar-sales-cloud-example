/**
 * OrderTriggerHandlerTest — covers the activation gate in OrderTriggerHandler
 * (the provisioning fan-out itself is covered by ProvisioningServiceTest).
 * Rules are injected via the service's @TestVisible override so these tests
 * don't depend on the seeded metadata.
 */
@IsTest
private class OrderTriggerHandlerTest {
  private static final String FAM_AI_DISPATCH = 'AI Dispatch Add-On';

  @IsTest
  static void activationTransitionDispatchesProvisioning() {
    Order ord = seedDraftOrder();
    ProvisioningService.rulesOverrideForTest = aiDispatchRule();

    Test.startTest();
    ord.Status = 'Activated';
    update ord;
    Test.stopTest();

    System.assertNotEquals(
      null,
      ProvisioningService.lastEvents,
      'Activation should have dispatched provisioning.'
    );
    System.assertEquals(1, ProvisioningService.lastEvents.size());
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Case WHERE Related_Order__c = :ord.Id]
    );
  }

  @IsTest
  static void nonActivationUpdateDoesNotDispatch() {
    Order ord = seedDraftOrder();
    ProvisioningService.rulesOverrideForTest = aiDispatchRule();

    Test.startTest();
    ord.Description = 'touched but still Draft';
    update ord;
    Test.stopTest();

    System.assertEquals(
      null,
      ProvisioningService.lastEvents,
      'A non-activation update must not dispatch.'
    );
  }

  @IsTest
  static void alreadyActivatedResaveDoesNotRedispatch() {
    Order ord = seedDraftOrder();
    ProvisioningService.rulesOverrideForTest = aiDispatchRule();

    ord.Status = 'Activated';
    update ord; // first activation — dispatches
    System.assertNotEquals(null, ProvisioningService.lastEvents);

    // Reset the capture and re-save the already-activated order.
    ProvisioningService.lastEvents = null;
    Test.startTest();
    ord.Description = 'post-activation edit';
    update ord;
    Test.stopTest();

    System.assertEquals(
      null,
      ProvisioningService.lastEvents,
      'Re-saving an already-activated order must not re-dispatch.'
    );
  }

  @IsTest
  static void bypassedHandlerSkipsDispatch() {
    Order ord = seedDraftOrder();
    ProvisioningService.rulesOverrideForTest = aiDispatchRule();

    TriggerHandler.bypass('OrderTriggerHandler');
    try {
      Test.startTest();
      ord.Status = 'Activated';
      update ord;
      Test.stopTest();
    } finally {
      TriggerHandler.clearBypass('OrderTriggerHandler');
    }

    System.assertEquals(
      null,
      ProvisioningService.lastEvents,
      'A bypassed handler must not dispatch.'
    );
  }

  @IsTest
  static void activationWithoutOrderProductsIsBlocked() {
    // The "Order Products" half of is enforced by the
    // platform's native order-activation rule (a validation rule can't count
    // child OrderItems), which fires during system validation before any
    // trigger. This test documents that enforcement: an Account +
    // active Contract but no OrderItem must still be blocked from activating.
    Account a = new Account(Name = 'NS No-Product Acct');
    insert a;
    Contract con = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{ 'AccountId' => a.Id }
    )[0];
    insert con;
    TriggerHandler.bypass('ContractTriggerHandler');
    try {
      update new Contract(Id = con.Id, Status = 'Activated');
    } finally {
      TriggerHandler.clearBypass('ContractTriggerHandler');
    }
    Order o = TestDataFactory.buildOrders(1)[0];
    o.AccountId = a.Id;
    o.ContractId = con.Id;
    insert o; // no OrderItem added

    Test.startTest();
    Boolean blocked = false;
    try {
      update new Order(Id = o.Id, Status = 'Activated');
    } catch (DmlException e) {
      blocked = true;
      System.assert(
        e.getMessage().contains('at least one product'),
        'Expected the platform Order-Products activation block, got: ' +
        e.getMessage()
      );
    }
    Test.stopTest();

    System.assert(
      blocked,
      'Activation without Order Products must be blocked.'
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private static Map<String, Product_Provisioning_Rule__mdt> aiDispatchRule() {
    return new Map<String, Product_Provisioning_Rule__mdt>{
      FAM_AI_DISPATCH => new Product_Provisioning_Rule__mdt(
        Product_Family__c = FAM_AI_DISPATCH,
        Requires_Provisioning__c = true,
        Requires_AI_Dispatch_Setup__c = true
      )
    };
  }

  private static Order seedDraftOrder() {
    update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
    Account a = new Account(Name = 'NS Order Acct');
    insert a;
    Product2 p = new Product2(
      Name = 'NS Order Product',
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
    // adds Order_Cannot_Activate_Without_Account_Contract_Or_Order_Products,
    // so the activated Order needs a Contract — and Salesforce requires that
    // Contract to be Activated (FAILED_ACTIVATION otherwise). Insert Draft, then
    // activate it with the Contract handler bypassed so renewal automation does
    // not bleed into this Order test. Factory dates satisfy the new Contract
    // activation rule.
    Contract con = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{ 'AccountId' => a.Id }
    )[0];
    insert con;
    TriggerHandler.bypass('ContractTriggerHandler');
    try {
      update new Contract(Id = con.Id, Status = 'Activated');
    } finally {
      TriggerHandler.clearBypass('ContractTriggerHandler');
    }
    Order o = TestDataFactory.buildOrders(1)[0];
    o.AccountId = a.Id;
    o.ContractId = con.Id;
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
