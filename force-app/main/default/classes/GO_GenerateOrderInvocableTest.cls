/**
 * GO_GenerateOrderInvocableTest — covers the adapted Generate Order accelerator
 * the happy paths (primary accepted Quote and the
 * Opportunity-Products fallback), all five failure paths, the @AuraEnabled
 * quick-action wrapper, bulk processing, and the empty/null no-op.
 */
@IsTest
private class GO_GenerateOrderInvocableTest {
  private static Id stdPb {
    get {
      return Test.getStandardPricebookId();
    }
  }

  @TestSetup
  static void activateStandardPricebook() {
    update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
  }

  // ---------------------------------------------------------------------------
  // Happy paths
  // ---------------------------------------------------------------------------

  @IsTest
  static void acceptedQuotePathCreatesOrderFromQuoteLines() {
    Account a = makeAccount();
    Contract c = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();
    Opportunity o = makeOpportunity(a.Id, c.Id, 'Annual');
    // Opportunity Products exist too — the accepted Quote must win.
    insertOppLine(o.Id, pbe.Id);
    Quote q = makeAcceptedQuote(o.Id);
    insertQuoteLine(q.Id, pbe.Id);
    insertQuoteLine(q.Id, pbe.Id);

    GO_GenerateOrderInvocable.Result res;
    Test.startTest();
    res = runOne(o.Id, false);
    Test.stopTest();

    System.assertEquals(
      true,
      res.success,
      'Expected success: ' + res.errorMessage
    );
    System.assertNotEquals(
      null,
      res.orderId,
      'An Order should have been created.'
    );
    Order ord = [
      SELECT
        Source_Quote__c,
        Source_Opportunity__c,
        Billing_Frequency__c,
        Implementation_Package__c,
        Support_Tier__c,
        Sales_Motion__c,
        Status,
        ContractId
      FROM Order
      WHERE Id = :res.orderId
    ];
    System.assertEquals(
      q.Id,
      ord.Source_Quote__c,
      'Order should trace to the Quote.'
    );
    System.assertEquals(o.Id, ord.Source_Opportunity__c);
    System.assertEquals('Draft', ord.Status);
    System.assertEquals(c.Id, ord.ContractId);
    System.assertEquals(
      'Enterprise',
      ord.Implementation_Package__c,
      'Implementation package should come from the Quote on the quote path.'
    );
    System.assertEquals(
      '24x7',
      ord.Support_Tier__c,
      'Support tier should mirror the Quote Premium_Support_Tier__c.'
    );
    System.assertEquals(
      'New Logo',
      ord.Sales_Motion__c,
      'Sales motion should come from the Opportunity.'
    );
    List<OrderItem> items = [
      SELECT Source_QuoteLineItem__c, Usage_Band__c
      FROM OrderItem
      WHERE OrderId = :res.orderId
    ];
    System.assertEquals(
      2,
      items.size(),
      'Two QLIs should become two Order Products.'
    );
    System.assertNotEquals(null, items[0].Source_QuoteLineItem__c);
    System.assertEquals(
      'Mid',
      items[0].Usage_Band__c,
      'Usage band should mirror from the Quote Line Item.'
    );
  }

  @IsTest
  static void fallsBackToOpportunityProductsWhenNoAcceptedQuote() {
    Account a = makeAccount();
    Contract c = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();
    Opportunity o = makeOpportunity(a.Id, c.Id, 'Annual');
    insertOppLine(o.Id, pbe.Id);
    insertOppLine(o.Id, pbe.Id);

    GO_GenerateOrderInvocable.Result res;
    Test.startTest();
    res = runOne(o.Id, false);
    Test.stopTest();

    System.assertEquals(
      true,
      res.success,
      'Expected success: ' + res.errorMessage
    );
    Order ord = [
      SELECT
        Source_Quote__c,
        Source_Opportunity__c,
        Implementation_Package__c,
        Support_Tier__c,
        Sales_Motion__c
      FROM Order
      WHERE Id = :res.orderId
    ];
    System.assertEquals(null, ord.Source_Quote__c, 'No Quote was accepted.');
    System.assertEquals(o.Id, ord.Source_Opportunity__c);
    System.assertEquals(
      'Quickstart',
      ord.Implementation_Package__c,
      'Implementation package should come from the Opportunity on the fallback path.'
    );
    System.assertEquals(
      'Standard',
      ord.Support_Tier__c,
      'Support tier should come from the Opportunity on the fallback path.'
    );
    System.assertEquals('New Logo', ord.Sales_Motion__c);
    List<OrderItem> items = [
      SELECT Source_OpportunityLineItem__c, Usage_Band__c
      FROM OrderItem
      WHERE OrderId = :res.orderId
    ];
    System.assertEquals(2, items.size());
    System.assertNotEquals(null, items[0].Source_OpportunityLineItem__c);
    System.assertEquals(
      'Mid',
      items[0].Usage_Band__c,
      'Usage band should mirror from the Opportunity Line Item.'
    );
  }

  @IsTest
  static void truncatesLongOpportunityNameToOrderLimit() {
    Account a = makeAccount();
    Contract c = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();
    String longName = '';
    for (Integer i = 0; i < 100; i++) {
      longName += 'A';
    }
    Opportunity o = TestDataFactory.buildOpportunities(
      1,
      new Map<String, Object>{
        'AccountId' => a.Id,
        'Pricebook2Id' => stdPb,
        'StageName' => 'Qualify',
        'Billing_Frequency__c' => 'Annual',
        'Name' => longName
      }
    )[0];
    o.ContractId = c.Id;
    insert o;
    insertOppLine(o.Id, pbe.Id);

    GO_GenerateOrderInvocable.Result res;
    Test.startTest();
    res = runOne(o.Id, false);
    Test.stopTest();

    System.assertEquals(
      true,
      res.success,
      'A 100-char Opportunity name must still generate: ' + res.errorMessage
    );
    Order ord = [SELECT Name FROM Order WHERE Id = :res.orderId];
    System.assertEquals(
      80,
      ord.Name.length(),
      'Order name must be truncated to the 80-char Order.Name limit.'
    );
    System.assertEquals(longName.substring(0, 80), ord.Name);
  }

  // ---------------------------------------------------------------------------
  // Failure paths
  // ---------------------------------------------------------------------------

  @IsTest
  static void invalidBillToAccountFails() {
    Opportunity o = TestDataFactory.buildOpportunities(
      1,
      new Map<String, Object>{ 'StageName' => 'Qualify' }
    )[0];
    TriggerHandler.bypass('OpportunityTriggerHandler');
    try {
      insert o; // no AccountId
    } finally {
      TriggerHandler.clearBypass('OpportunityTriggerHandler');
    }

    GO_GenerateOrderInvocable.Result res = runOne(o.Id, false);

    assertFailure(res, GO_GenerateOrderInvocable.ERR_INVALID_BILL_TO);
    System.assertEquals(0, [SELECT COUNT() FROM Order], 'No Order on failure.');
  }

  @IsTest
  static void noActiveContractStartDateFails() {
    Account a = makeAccount();
    PricebookEntry pbe = makePricebookEntry();
    Opportunity o = makeOpportunity(a.Id, null, 'Annual'); // no Contract
    insertOppLine(o.Id, pbe.Id);

    GO_GenerateOrderInvocable.Result res = runOne(o.Id, false);

    assertFailure(res, GO_GenerateOrderInvocable.ERR_NO_CONTRACT_START);
  }

  @IsTest
  static void missingPrimaryQuoteFailsWhenRequired() {
    Account a = makeAccount();
    Contract c = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();
    Opportunity o = makeOpportunity(a.Id, c.Id, 'Annual');
    insertOppLine(o.Id, pbe.Id); // products exist, but a quote is required

    GO_GenerateOrderInvocable.Result res = runOne(o.Id, true);

    assertFailure(res, GO_GenerateOrderInvocable.ERR_MISSING_QUOTE);
    System.assertEquals(0, [SELECT COUNT() FROM Order]);
  }

  @IsTest
  static void unsupportedBillingFrequencyFails() {
    Account a = makeAccount();
    Contract c = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();
    Opportunity o = makeOpportunity(a.Id, c.Id, 'Multi-Year Upfront');
    insertOppLine(o.Id, pbe.Id);

    GO_GenerateOrderInvocable.Result res = runOne(o.Id, false);

    assertFailure(res, GO_GenerateOrderInvocable.ERR_UNSUPPORTED_FREQ);
  }

  @IsTest
  static void noProductsFails() {
    Account a = makeAccount();
    Contract c = activatedContract(a.Id);
    Opportunity o = makeOpportunity(a.Id, c.Id, 'Annual'); // no lines at all

    GO_GenerateOrderInvocable.Result res = runOne(o.Id, false);

    assertFailure(res, GO_GenerateOrderInvocable.ERR_NO_PRODUCTS);
  }

  // ---------------------------------------------------------------------------
  // Quick-action wrapper, bulk, and no-op
  // ---------------------------------------------------------------------------

  @IsTest
  static void auraWrapperReturnsResult() {
    Account a = makeAccount();
    Contract c = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();
    Opportunity o = makeOpportunity(a.Id, c.Id, 'Annual');
    insertOppLine(o.Id, pbe.Id);

    GO_GenerateOrderInvocable.Result res;
    Test.startTest();
    res = GO_GenerateOrderInvocable.generateOrderForOpportunity(o.Id);
    Test.stopTest();

    System.assertEquals(
      true,
      res.success,
      'Expected success: ' + res.errorMessage
    );
    System.assertNotEquals(null, res.orderId);
  }

  // ---------------------------------------------------------------------------
  // Order-context re-generate entry point
  // ---------------------------------------------------------------------------

  @IsTest
  static void orderContextReturnsExistingOrderViaIdempotencyGuard() {
    Account a = makeAccount();
    Contract c = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();
    Opportunity o = makeOpportunity(a.Id, c.Id, 'Annual');
    insertOppLine(o.Id, pbe.Id);

    // Generate the Order from the Opportunity first.
    GO_GenerateOrderInvocable.Result created = GO_GenerateOrderInvocable.generateOrderForOpportunity(
      o.Id
    );
    System.assertEquals(
      true,
      created.success,
      'Setup Generate Order should succeed: ' + created.errorMessage
    );

    // Re-generating from the Order surfaces that same Order (guard),
    // never a duplicate.
    GO_GenerateOrderInvocable.Result res;
    Test.startTest();
    res = GO_GenerateOrderInvocable.generateOrderForOrder(created.orderId);
    Test.stopTest();

    System.assertEquals(
      false,
      res.success,
      'Re-generate from an Order must not report a new Order created.'
    );
    System.assertEquals(
      GO_GenerateOrderInvocable.ERR_ORDER_EXISTS,
      res.errorCode,
      'Order context should surface ORDER_ALREADY_EXISTS.'
    );
    System.assertEquals(
      created.orderId,
      res.orderId,
      'The existing Order should be surfaced so the LWC can open it.'
    );
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Order],
      'Re-generate must not create a duplicate Order.'
    );
  }

  @IsTest
  static void orderContextWithNoSourceOpportunityFails() {
    Account a = makeAccount();
    Order ord = new Order(
      AccountId = a.Id,
      Status = 'Draft',
      EffectiveDate = Date.today()
    );
    TriggerHandler.bypass('OrderTriggerHandler');
    try {
      insert ord;
    } finally {
      TriggerHandler.clearBypass('OrderTriggerHandler');
    }

    GO_GenerateOrderInvocable.Result res;
    Test.startTest();
    res = GO_GenerateOrderInvocable.generateOrderForOrder(ord.Id);
    Test.stopTest();

    assertFailure(res, GO_GenerateOrderInvocable.ERR_NO_SOURCE_OPP);
  }

  @IsTest
  static void orderContextWithNullIdFails() {
    GO_GenerateOrderInvocable.Result res;
    Test.startTest();
    res = GO_GenerateOrderInvocable.generateOrderForOrder(null);
    Test.stopTest();

    assertFailure(res, GO_GenerateOrderInvocable.ERR_NO_SOURCE_OPP);
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Order],
      'A null Order id must not touch the database.'
    );
  }

  @IsTest
  static void bulkProcessesMixedRequestsInOrder() {
    Account a = makeAccount();
    Contract c1 = activatedContract(a.Id);
    Contract c2 = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();

    // Row 0: quote path. Row 1: OLI fallback.
    Opportunity oQuote = makeOpportunity(a.Id, c1.Id, 'Annual');
    Quote q = makeAcceptedQuote(oQuote.Id);
    insertQuoteLine(q.Id, pbe.Id);

    Opportunity oOli = makeOpportunity(a.Id, c2.Id, 'Annual');
    insertOppLine(oOli.Id, pbe.Id);

    List<GO_GenerateOrderInvocable.Request> reqs = new List<GO_GenerateOrderInvocable.Request>{
      buildRequest(oQuote.Id, false),
      buildRequest(oOli.Id, false)
    };

    List<GO_GenerateOrderInvocable.Result> results;
    Test.startTest();
    results = GO_GenerateOrderInvocable.generate(reqs);
    Test.stopTest();

    System.assertEquals(
      2,
      results.size(),
      'Result count must match request count.'
    );
    System.assertEquals(true, results[0].success);
    System.assertEquals(true, results[1].success);
    System.assertEquals(2, [SELECT COUNT() FROM Order]);
    Order quoteOrder = [
      SELECT Source_Quote__c
      FROM Order
      WHERE Id = :results[0].orderId
    ];
    System.assertEquals(
      q.Id,
      quoteOrder.Source_Quote__c,
      'Row 0 should be the quote-sourced Order.'
    );
  }

  // ---------------------------------------------------------------------------
  // Idempotency
  // ---------------------------------------------------------------------------

  @IsTest
  static void repeatInvocationReturnsExistingOrderInsteadOfDuplicate() {
    Account a = makeAccount();
    Contract c = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();
    Opportunity o = makeOpportunity(a.Id, c.Id, 'Annual');
    insertOppLine(o.Id, pbe.Id);

    // First click creates the Order.
    GO_GenerateOrderInvocable.Result first = runOne(o.Id, false);
    System.assertEquals(
      true,
      first.success,
      'First Generate Order should succeed: ' + first.errorMessage
    );
    Order created = [
      SELECT Id, OrderNumber
      FROM Order
      WHERE Id = :first.orderId
    ];

    // Second click must NOT create a duplicate.
    GO_GenerateOrderInvocable.Result second;
    Test.startTest();
    second = runOne(o.Id, false);
    Test.stopTest();

    System.assertEquals(
      false,
      second.success,
      'A repeat invocation must not report a new Order created.'
    );
    System.assertEquals(
      GO_GenerateOrderInvocable.ERR_ORDER_EXISTS,
      second.errorCode,
      'Repeat invocation should surface the ORDER_ALREADY_EXISTS code.'
    );
    System.assertEquals(
      created.Id,
      second.orderId,
      'The existing Order should be surfaced on the result.'
    );
    System.assertNotEquals(
      null,
      second.errorMessage,
      'A custom-label error message should be set.'
    );
    System.assert(
      second.errorMessage.contains(created.OrderNumber),
      'The message should name the existing Order number: ' +
      second.errorMessage
    );
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Order],
      'No duplicate Order should have been created.'
    );
  }

  @IsTest
  static void bulkMixesFreshAndAlreadyOrderedOpportunities() {
    Account a = makeAccount();
    Contract c1 = activatedContract(a.Id);
    Contract c2 = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();

    // oExisting already has an Order; oFresh does not.
    Opportunity oExisting = makeOpportunity(a.Id, c1.Id, 'Annual');
    insertOppLine(oExisting.Id, pbe.Id);
    Id existingOrderId = runOne(oExisting.Id, false).orderId;
    System.assertNotEquals(
      null,
      existingOrderId,
      'Setup: oExisting should already have an Order.'
    );

    Opportunity oFresh = makeOpportunity(a.Id, c2.Id, 'Annual');
    insertOppLine(oFresh.Id, pbe.Id);

    List<GO_GenerateOrderInvocable.Request> reqs = new List<GO_GenerateOrderInvocable.Request>{
      buildRequest(oExisting.Id, false),
      buildRequest(oFresh.Id, false)
    };

    List<GO_GenerateOrderInvocable.Result> results;
    Test.startTest();
    results = GO_GenerateOrderInvocable.generate(reqs);
    Test.stopTest();

    // Row 0: already-ordered — coded result, existing Order surfaced, no insert.
    System.assertEquals(false, results[0].success, 'Row 0 must not duplicate.');
    System.assertEquals(
      GO_GenerateOrderInvocable.ERR_ORDER_EXISTS,
      results[0].errorCode
    );
    System.assertEquals(existingOrderId, results[0].orderId);
    // Row 1: fresh — a new Order is created.
    System.assertEquals(
      true,
      results[1].success,
      'Row 1 should create an Order.'
    );
    System.assertNotEquals(existingOrderId, results[1].orderId);
    System.assertEquals(
      2,
      [SELECT COUNT() FROM Order],
      'Exactly two Orders: oExisting (original) + oFresh (new), no duplicate.'
    );
  }

  @IsTest
  static void duplicateRequestRowsInOneBulkCallCreateOneOrder() {
    // The same Opportunity twice in one invocation: no committed Order exists
    // for either row, so the query-based guard alone would let both insert.
    // Guard 0b must reserve the first row and resolve the second against it.
    Account a = makeAccount();
    Contract c = activatedContract(a.Id);
    PricebookEntry pbe = makePricebookEntry();
    Opportunity o = makeOpportunity(a.Id, c.Id, 'Annual');
    insertOppLine(o.Id, pbe.Id);

    List<GO_GenerateOrderInvocable.Request> reqs = new List<GO_GenerateOrderInvocable.Request>{
      buildRequest(o.Id, false),
      buildRequest(o.Id, false)
    };

    List<GO_GenerateOrderInvocable.Result> results;
    Test.startTest();
    results = GO_GenerateOrderInvocable.generate(reqs);
    Test.stopTest();

    System.assertEquals(2, results.size(), 'One result per request row.');
    // Row 0 creates the Order; row 1 is the in-batch duplicate.
    System.assertEquals(
      true,
      results[0].success,
      'First row should create the Order: ' + results[0].errorMessage
    );
    System.assertNotEquals(null, results[0].orderId);
    System.assertEquals(
      false,
      results[1].success,
      'The duplicate row must not create a second Order.'
    );
    System.assertEquals(
      GO_GenerateOrderInvocable.ERR_ORDER_EXISTS,
      results[1].errorCode,
      'The duplicate row should report ORDER_ALREADY_EXISTS.'
    );
    System.assertEquals(
      results[0].orderId,
      results[1].orderId,
      'The duplicate row should surface the same Order the first row created.'
    );
    Order created = [
      SELECT OrderNumber
      FROM Order
      WHERE Id = :results[0].orderId
    ];
    System.assert(
      results[1].errorMessage != null &&
      results[1].errorMessage.contains(created.OrderNumber),
      'The duplicate row message should name the reserved Order number: ' +
      results[1].errorMessage
    );
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Order],
      'Only one Order for the repeated Opportunity, no duplicate.'
    );
  }

  @IsTest
  static void emptyAndNullRequestsAreNoOp() {
    List<GO_GenerateOrderInvocable.Request> empty = new List<GO_GenerateOrderInvocable.Request>();
    Test.startTest();
    List<GO_GenerateOrderInvocable.Result> fromNull = GO_GenerateOrderInvocable.generate(
      null
    );
    List<GO_GenerateOrderInvocable.Result> fromEmpty = GO_GenerateOrderInvocable.generate(
      empty
    );
    Test.stopTest();
    System.assertEquals(0, fromNull.size(), 'Null input is a no-op.');
    System.assertEquals(0, fromEmpty.size(), 'Empty input is a no-op.');
    System.assertEquals(0, [SELECT COUNT() FROM Order]);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private static GO_GenerateOrderInvocable.Request buildRequest(
    Id oppId,
    Boolean requireQuote
  ) {
    GO_GenerateOrderInvocable.Request req = new GO_GenerateOrderInvocable.Request();
    req.opportunityId = oppId;
    req.requireAcceptedQuote = requireQuote;
    return req;
  }

  private static GO_GenerateOrderInvocable.Result runOne(
    Id oppId,
    Boolean requireQuote
  ) {
    return GO_GenerateOrderInvocable.generate(
      new List<GO_GenerateOrderInvocable.Request>{
        buildRequest(oppId, requireQuote)
      }
    )[0];
  }

  private static void assertFailure(
    GO_GenerateOrderInvocable.Result res,
    String expectedCode
  ) {
    System.assertEquals(false, res.success, 'Expected failure.');
    System.assertEquals(expectedCode, res.errorCode, 'Wrong error code.');
    System.assertNotEquals(
      null,
      res.errorMessage,
      'A custom-label error message should be set.'
    );
    System.assertEquals(null, res.orderId, 'No Order id on failure.');
  }

  private static Account makeAccount() {
    Account a = new Account(
      Name = 'NS GO Acct',
      Region__c = 'NA East',
      Customer_Segment__c = 'Commercial'
    );
    insert a;
    return a;
  }

  private static Contract activatedContract(Id accountId) {
    Contract c = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{ 'AccountId' => accountId }
    )[0];
    insert c;
    TriggerHandler.bypass('ContractTriggerHandler');
    try {
      update new Contract(Id = c.Id, Status = 'Activated');
    } finally {
      TriggerHandler.clearBypass('ContractTriggerHandler');
    }
    return c;
  }

  private static PricebookEntry makePricebookEntry() {
    Product2 p = new Product2(
      Name = 'NS GO Product ' + System.now().getTime(),
      Family = 'Core Platform',
      IsActive = true
    );
    insert p;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = stdPb,
      Product2Id = p.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert pbe;
    return pbe;
  }

  private static Opportunity makeOpportunity(
    Id accountId,
    Id contractId,
    String billingFreq
  ) {
    Opportunity o = TestDataFactory.buildOpportunities(
      1,
      new Map<String, Object>{
        'AccountId' => accountId,
        'Pricebook2Id' => stdPb,
        'StageName' => 'Qualify',
        'Billing_Frequency__c' => billingFreq
      }
    )[0];
    if (contractId != null) {
      o.ContractId = contractId;
    }
    insert o;
    return o;
  }

  private static Quote makeAcceptedQuote(Id oppId) {
    Quote q = TestDataFactory.buildQuotes(
      1,
      new Map<String, Object>{
        'OpportunityId' => oppId,
        'Pricebook2Id' => stdPb,
        'Status' => 'Accepted',
        'Billing_Frequency__c' => 'Annual',
        // Distinct from the Opportunity defaults so the quote path's
        // Implementation_Package__c / Support_Tier__c sourcing is observable.
        'Implementation_Package__c' => 'Enterprise',
        'Premium_Support_Tier__c' => '24x7'
      }
    )[0];
    TriggerHandler.bypass('QuoteTriggerHandler');
    try {
      insert q;
    } finally {
      TriggerHandler.clearBypass('QuoteTriggerHandler');
    }
    return q;
  }

  private static void insertOppLine(Id oppId, Id pbeId) {
    insert new OpportunityLineItem(
      OpportunityId = oppId,
      PricebookEntryId = pbeId,
      Quantity = 1,
      UnitPrice = 100,
      Revenue_Type__c = 'Subscription',
      Usage_Band__c = 'Mid'
    );
  }

  private static void insertQuoteLine(Id quoteId, Id pbeId) {
    TriggerHandler.bypass('QuoteLineItemTriggerHandler');
    try {
      insert new QuoteLineItem(
        QuoteId = quoteId,
        PricebookEntryId = pbeId,
        Quantity = 1,
        UnitPrice = 100,
        Revenue_Type__c = 'Subscription',
        Usage_Band__c = 'Mid'
      );
    } finally {
      TriggerHandler.clearBypass('QuoteLineItemTriggerHandler');
    }
  }
}
