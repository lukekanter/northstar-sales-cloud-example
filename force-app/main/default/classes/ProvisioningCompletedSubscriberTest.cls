/**
 * ProvisioningCompletedSubscriberTest — covers the Success / Failure / Partial
 * tokens and the missing/deleted-order branches via direct handle() calls
 * (asserted by SOQL on committed side effects), plus one EventBus.publish path
 * that proves the ProvisioningCompletedTrigger wiring.
 */
@IsTest
private class ProvisioningCompletedSubscriberTest {
  private static Id seedOrder() {
    Account a = TestDataFactory.buildAccounts(1)[0];
    insert a;
    Order o = TestDataFactory.buildOrders(
      1,
      new Map<String, Object>{
        'AccountId' => a.Id,
        'Provisioning_Status__c' => 'Pending'
      }
    )[0];
    insert o;
    return o.Id;
  }

  @IsTest
  static void successEventStampsOrderCompleted() {
    Id orderId = seedOrder();

    Test.startTest();
    ProvisioningCompletedSubscriber.handle(
      new List<Provisioning_Completed__e>{
        new Provisioning_Completed__e(
          Order_Id__c = orderId,
          Status__c = 'Success'
        )
      }
    );
    Test.stopTest();

    Order got = [
      SELECT Provisioning_Status__c, Provisioning_Completed_At__c
      FROM Order
      WHERE Id = :orderId
    ];
    System.assertEquals('Completed', got.Provisioning_Status__c);
    System.assertNotEquals(
      null,
      got.Provisioning_Completed_At__c,
      'Completion timestamp must be stamped.'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Case WHERE Related_Order__c = :orderId],
      'A clean success creates no exception Case.'
    );
  }

  @IsTest
  static void failureEventStampsOrderFailedAndCreatesCase() {
    Id orderId = seedOrder();

    Test.startTest();
    ProvisioningCompletedSubscriber.handle(
      new List<Provisioning_Completed__e>{
        new Provisioning_Completed__e(
          Order_Id__c = orderId,
          Status__c = 'Failure',
          Failure_Reason__c = 'Downstream API timeout'
        )
      }
    );
    Test.stopTest();

    Order got = [
      SELECT Provisioning_Status__c, Provisioning_Completed_At__c
      FROM Order
      WHERE Id = :orderId
    ];
    System.assertEquals(
      'Failed',
      got.Provisioning_Status__c,
      'A failed callback must mark the Order Failed, not leave it Pending.'
    );
    System.assertNotEquals(null, got.Provisioning_Completed_At__c);

    List<Case> cases = [
      SELECT
        Case_Category__c,
        Provisioning_Failure_Reason__c,
        RecordType.DeveloperName
      FROM Case
      WHERE Related_Order__c = :orderId
    ];
    System.assertEquals(1, cases.size(), 'One exception Case expected.');
    System.assertEquals('Provisioning', cases[0].Case_Category__c);
    System.assertEquals(
      'Downstream API timeout',
      cases[0].Provisioning_Failure_Reason__c
    );
  }

  @IsTest
  static void partialEventIsTreatedAsFailure() {
    Id orderId = seedOrder();

    Test.startTest();
    ProvisioningCompletedSubscriber.handle(
      new List<Provisioning_Completed__e>{
        new Provisioning_Completed__e(
          Order_Id__c = orderId,
          Status__c = 'Partial'
        )
      }
    );
    Test.stopTest();

    System.assertEquals(
      'Failed',
      [SELECT Provisioning_Status__c FROM Order WHERE Id = :orderId]
      .Provisioning_Status__c,
      'A Partial outcome is surfaced as Failed for triage.'
    );
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Case WHERE Related_Order__c = :orderId],
      'Partial provisioning raises an exception Case.'
    );
  }

  @IsTest
  static void missingOrderIdCreatesUnlinkedCase() {
    Test.startTest();
    ProvisioningCompletedSubscriber.handle(
      new List<Provisioning_Completed__e>{
        new Provisioning_Completed__e(Status__c = 'Success')
      }
    );
    Test.stopTest();

    List<Case> cases = [
      SELECT Related_Order__c, Provisioning_Failure_Reason__c, Case_Category__c
      FROM Case
    ];
    System.assertEquals(
      1,
      cases.size(),
      'Missing Order Id should raise a Case.'
    );
    System.assertEquals(null, cases[0].Related_Order__c);
    System.assertEquals('Provisioning', cases[0].Case_Category__c);
    System.assert(
      cases[0].Provisioning_Failure_Reason__c.contains('without an Order Id'),
      'Reason should explain the missing Order Id.'
    );
  }

  @IsTest
  static void successForDeletedOrderRaisesUnlinkedCase() {
    Id orderId = seedOrder();
    delete [SELECT Id FROM Order WHERE Id = :orderId];

    Test.startTest();
    ProvisioningCompletedSubscriber.handle(
      new List<Provisioning_Completed__e>{
        new Provisioning_Completed__e(
          Order_Id__c = orderId,
          Status__c = 'Success'
        )
      }
    );
    Test.stopTest();

    List<Case> cases = [
      SELECT Related_Order__c
      FROM Case
      WHERE Case_Category__c = 'Provisioning'
    ];
    System.assertEquals(
      1,
      cases.size(),
      'A success naming a non-existent Order is a data gap → Case.'
    );
    System.assertEquals(
      null,
      cases[0].Related_Order__c,
      'The Case must not link a deleted Order.'
    );
  }

  @IsTest
  static void publishedEventFiresTriggerAndStampsOrder() {
    Id orderId = seedOrder();

    Test.startTest();
    EventBus.publish(
      new Provisioning_Completed__e(
        Order_Id__c = orderId,
        Status__c = 'Success'
      )
    );
    Test.stopTest();

    Order got = [SELECT Provisioning_Status__c FROM Order WHERE Id = :orderId];
    System.assertEquals(
      'Completed',
      got.Provisioning_Status__c,
      'The platform-event trigger should drive the subscriber end to end.'
    );
  }

  private static Map<String, Id> seedOrderWithOpportunity() {
    Account a = TestDataFactory.buildAccounts(1)[0];
    insert a;
    Opportunity opp = TestDataFactory.buildOpportunities(
      1,
      new Map<String, Object>{
        'AccountId' => a.Id,
        'Provisioning_Status__c' => 'Pending'
      }
    )[0];
    insert opp;
    Order o = TestDataFactory.buildOrders(
      1,
      new Map<String, Object>{
        'AccountId' => a.Id,
        'Provisioning_Status__c' => 'Pending',
        'Source_Opportunity__c' => opp.Id
      }
    )[0];
    insert o;
    // The shared roll-up is Status-aware: only an Activated Order's
    // provisioning status counts; a Draft Order is treated as in-flight. A
    // completion event only ever fires for an activated Order, so activate it.
    activate(o.Id, a.Id, 'Pending');
    return new Map<String, Id>{ 'order' => o.Id, 'opp' => opp.Id };
  }

  /**
   * Activate the given Order at the given provisioning status. Activation
   * requires an Account, a Contract, AND at least one product (org rules), and
   * the Order trigger is bypassed so activation doesn't auto-dispatch.
   */
  private static void activate(Id orderId, Id accountId, String provStatus) {
    Contract con = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{ 'AccountId' => accountId }
    )[0];
    insert con;
    TriggerHandler.bypass('ContractTriggerHandler');
    try {
      update new Contract(Id = con.Id, Status = 'Activated');
    } finally {
      TriggerHandler.clearBypass('ContractTriggerHandler');
    }
    Id pbId = Test.getStandardPricebookId();
    update new Pricebook2(Id = pbId, IsActive = true);
    Product2 p = new Product2(
      Name = 'NS Prov Product',
      Family = 'Core Platform',
      IsActive = true
    );
    insert p;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = pbId,
      Product2Id = p.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert pbe;
    update new Order(Id = orderId, Pricebook2Id = pbId);
    insert new OrderItem(
      OrderId = orderId,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100
    );
    TriggerHandler.bypass('OrderTriggerHandler');
    try {
      update new Order(
        Id = orderId,
        ContractId = con.Id,
        Status = 'Activated',
        Provisioning_Status__c = provStatus
      );
    } finally {
      TriggerHandler.clearBypass('OrderTriggerHandler');
    }
  }

  @IsTest
  static void successRollsUpCompletedToSourceOpportunity() {
    Map<String, Id> ids = seedOrderWithOpportunity();

    Test.startTest();
    ProvisioningCompletedSubscriber.handle(
      new List<Provisioning_Completed__e>{
        new Provisioning_Completed__e(
          Order_Id__c = ids.get('order'),
          Status__c = 'Success'
        )
      }
    );
    Test.stopTest();

    System.assertEquals(
      'Completed',
      [
        SELECT Provisioning_Status__c
        FROM Opportunity
        WHERE Id = :ids.get('opp')
      ]
      .Provisioning_Status__c,
      'Order completion must roll up to the source Opportunity so it stops reading Pending.'
    );
  }

  @IsTest
  static void failureRollsUpFailedToSourceOpportunity() {
    Map<String, Id> ids = seedOrderWithOpportunity();

    Test.startTest();
    ProvisioningCompletedSubscriber.handle(
      new List<Provisioning_Completed__e>{
        new Provisioning_Completed__e(
          Order_Id__c = ids.get('order'),
          Status__c = 'Failure',
          Failure_Reason__c = 'Downstream API timeout'
        )
      }
    );
    Test.stopTest();

    System.assertEquals(
      'Failed',
      [
        SELECT Provisioning_Status__c
        FROM Opportunity
        WHERE Id = :ids.get('opp')
      ]
      .Provisioning_Status__c,
      'A failed provisioning callback must roll Failed up to the source Opportunity.'
    );
  }

  @IsTest
  static void completedOrderLeavesOppPendingWhileSiblingProvisioning() {
    Account a = TestDataFactory.buildAccounts(1)[0];
    insert a;
    Opportunity opp = TestDataFactory.buildOpportunities(
      1,
      new Map<String, Object>{
        'AccountId' => a.Id,
        'Provisioning_Status__c' => 'Pending'
      }
    )[0];
    insert opp;
    List<Order> orders = TestDataFactory.buildOrders(
      2,
      new Map<String, Object>{
        'AccountId' => a.Id,
        'Provisioning_Status__c' => 'Pending',
        'Source_Opportunity__c' => opp.Id
      }
    );
    insert orders;
    // Both activated: orders[0] completes via the event; orders[1] is still
    // provisioning (Activated + Pending).
    activate(orders[0].Id, a.Id, 'Pending');
    activate(orders[1].Id, a.Id, 'Pending');

    Test.startTest();
    ProvisioningCompletedSubscriber.handle(
      new List<Provisioning_Completed__e>{
        new Provisioning_Completed__e(
          Order_Id__c = orders[0].Id,
          Status__c = 'Success'
        )
      }
    );
    Test.stopTest();

    System.assertEquals(
      'Pending',
      [SELECT Provisioning_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Provisioning_Status__c,
      'Opportunity must stay Pending while a sibling Order is still provisioning.'
    );
  }

  @IsTest
  static void failedSiblingKeepsOppFailedWhenLaterOrderSucceeds() {
    Account a = TestDataFactory.buildAccounts(1)[0];
    insert a;
    Opportunity opp = TestDataFactory.buildOpportunities(
      1,
      new Map<String, Object>{
        'AccountId' => a.Id,
        'Provisioning_Status__c' => 'Pending'
      }
    )[0];
    insert opp;
    List<Order> orders = TestDataFactory.buildOrders(
      2,
      new Map<String, Object>{
        'AccountId' => a.Id,
        'Source_Opportunity__c' => opp.Id
      }
    );
    insert orders;
    // Both activated. orders[0] already Failed from an earlier (separate-batch)
    // callback; orders[1] succeeds via this event.
    activate(orders[0].Id, a.Id, 'Failed');
    activate(orders[1].Id, a.Id, 'Pending');

    Test.startTest();
    ProvisioningCompletedSubscriber.handle(
      new List<Provisioning_Completed__e>{
        new Provisioning_Completed__e(
          Order_Id__c = orders[1].Id,
          Status__c = 'Success'
        )
      }
    );
    Test.stopTest();

    System.assertEquals(
      'Failed',
      [SELECT Provisioning_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Provisioning_Status__c,
      'Failure on one Order must win even when a later Order for the deal succeeds.'
    );
  }

  @IsTest
  static void emptyAndNullInputAreNoOps() {
    Test.startTest();
    ProvisioningCompletedSubscriber.handle(null);
    ProvisioningCompletedSubscriber.handle(
      new List<Provisioning_Completed__e>()
    );
    Test.stopTest();
    System.assertEquals(0, [SELECT COUNT() FROM Case]);
  }
}
