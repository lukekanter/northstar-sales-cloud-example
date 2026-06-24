/**
 * TestDataFactoryTest — proves every TestDataFactory builder produces a record
 * that passes required-field validation (i.e. inserts cleanly) against an
 * empty org, and exercises the insertAll grouping and the trigger-bypass
 * wrappers.
 */
@IsTest
private class TestDataFactoryTest {
  /**
   * Inserts one record from every builder, walking the full
   * Account → Product/Pricebook → Opportunity → Quote → Order → Contract graph
   * so that line items get valid parent + PricebookEntry references.
   */
  @IsTest
  static void everyBuilderProducesInsertableRecord() {
    Test.startTest();

    // Roots with no parent requirements.
    Account account = TestDataFactory.buildAccounts(1)[0];
    insert account;
    System.assertNotEquals(null, account.Id, 'Account should insert');

    Contact contact = TestDataFactory.buildContacts(
      1,
      new Map<String, Object>{ 'AccountId' => account.Id }
    )[0];
    insert contact;
    System.assertNotEquals(null, contact.Id, 'Contact should insert');

    Lead lead = TestDataFactory.buildLeads(1)[0];
    insert lead;
    System.assertNotEquals(null, lead.Id, 'Lead should insert');

    Case caseRecord = TestDataFactory.buildCases(1)[0];
    insert caseRecord;
    System.assertNotEquals(null, caseRecord.Id, 'Case should insert');

    // Product + pricebook scaffolding. A standard-pricebook entry must exist
    // before a custom-pricebook entry can be created for the same product.
    Product2 product = TestDataFactory.buildProducts(1)[0];
    insert product;
    System.assertNotEquals(null, product.Id, 'Product2 should insert');

    PricebookEntry standardEntry = TestDataFactory.buildPricebookEntries(
      1,
      new Map<String, Object>{
        'Pricebook2Id' => Test.getStandardPricebookId(),
        'Product2Id' => product.Id
      }
    )[0];
    insert standardEntry;
    System.assertNotEquals(
      null,
      standardEntry.Id,
      'Standard PricebookEntry should insert'
    );

    Pricebook2 pricebook = TestDataFactory.buildPricebooks(1)[0];
    insert pricebook;
    System.assertNotEquals(null, pricebook.Id, 'Pricebook2 should insert');

    PricebookEntry entry = TestDataFactory.buildPricebookEntries(
      1,
      new Map<String, Object>{
        'Pricebook2Id' => pricebook.Id,
        'Product2Id' => product.Id
      }
    )[0];
    insert entry;
    System.assertNotEquals(
      null,
      entry.Id,
      'Custom PricebookEntry should insert'
    );

    // Opportunity uses the custom pricebook so its line item can reference the
    // custom PricebookEntry.
    Opportunity opportunity = TestDataFactory.buildOpportunities(
      1,
      new Map<String, Object>{ 'Pricebook2Id' => pricebook.Id }
    )[0];
    insert opportunity;
    System.assertNotEquals(null, opportunity.Id, 'Opportunity should insert');

    OpportunityLineItem oli = TestDataFactory.buildOpportunityLineItems(
      1,
      new Map<String, Object>{
        'OpportunityId' => opportunity.Id,
        'PricebookEntryId' => entry.Id
      }
    )[0];
    insert oli;
    System.assertNotEquals(null, oli.Id, 'OpportunityLineItem should insert');

    Quote quote = TestDataFactory.buildQuotes(
      1,
      new Map<String, Object>{
        'OpportunityId' => opportunity.Id,
        'Pricebook2Id' => pricebook.Id
      }
    )[0];
    insert quote;
    System.assertNotEquals(null, quote.Id, 'Quote should insert');

    QuoteLineItem qli = TestDataFactory.buildQuoteLineItems(
      1,
      new Map<String, Object>{
        'QuoteId' => quote.Id,
        'PricebookEntryId' => entry.Id
      }
    )[0];
    insert qli;
    System.assertNotEquals(null, qli.Id, 'QuoteLineItem should insert');

    Order order = TestDataFactory.buildOrders(
      1,
      new Map<String, Object>{
        'AccountId' => account.Id,
        'Pricebook2Id' => pricebook.Id
      }
    )[0];
    insert order;
    System.assertNotEquals(null, order.Id, 'Order should insert');

    OrderItem orderItem = TestDataFactory.buildOrderItems(
      1,
      new Map<String, Object>{
        'OrderId' => order.Id,
        'PricebookEntryId' => entry.Id
      }
    )[0];
    insert orderItem;
    System.assertNotEquals(null, orderItem.Id, 'OrderItem should insert');

    Contract contract = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{ 'AccountId' => account.Id }
    )[0];
    insert contract;
    System.assertNotEquals(null, contract.Id, 'Contract should insert');

    Test.stopTest();
  }

  @IsTest
  static void buildHonorsCountAndOverrides() {
    List<Account> accounts = TestDataFactory.buildAccounts(
      3,
      new Map<String, Object>{ 'Rating' => 'Hot' }
    );
    System.assertEquals(3, accounts.size(), 'count should drive list size');
    Set<String> names = new Set<String>();
    for (Account a : accounts) {
      System.assertEquals('Hot', a.Rating, 'override should be applied');
      names.add(a.Name);
    }
    System.assertEquals(
      3,
      names.size(),
      'each record should get a unique name'
    );
  }

  @IsTest
  static void insertAllGroupsBySObjectType() {
    List<SObject> records = new List<SObject>();
    records.addAll((List<SObject>) TestDataFactory.buildAccounts(2));
    records.addAll((List<SObject>) TestDataFactory.buildLeads(2));

    Test.startTest();
    TestDataFactory.insertAll(records);
    Test.stopTest();

    System.assertEquals(
      2,
      [SELECT COUNT() FROM Account],
      'both accounts inserted'
    );
    System.assertEquals(2, [SELECT COUNT() FROM Lead], 'both leads inserted');
  }

  @IsTest
  static void insertAllToleratesEmptyAndNull() {
    TestDataFactory.insertAll(null);
    TestDataFactory.insertAll(new List<SObject>());
    System.assertEquals(0, [SELECT COUNT() FROM Account], 'nothing inserted');
  }

  @IsTest
  static void bypassAndRestoreTriggersDelegateToFramework() {
    TestDataFactory.bypassTriggers('AccountTriggerHandler');
    System.assertEquals(
      true,
      TriggerHandler.isBypassed('AccountTriggerHandler'),
      'single bypass should register'
    );

    TestDataFactory.bypassTriggers(
      new List<String>{ 'ContactTriggerHandler', 'LeadTriggerHandler' }
    );
    System.assertEquals(
      true,
      TriggerHandler.isBypassed('ContactTriggerHandler'),
      'list bypass'
    );
    System.assertEquals(
      true,
      TriggerHandler.isBypassed('LeadTriggerHandler'),
      'list bypass'
    );

    TestDataFactory.bypassTriggers((List<String>) null); // no-op guard

    TestDataFactory.restoreTriggers();
    System.assertEquals(
      false,
      TriggerHandler.isBypassed('AccountTriggerHandler'),
      'restore should clear all bypasses'
    );
    System.assertEquals(
      false,
      TriggerHandler.isBypassed('ContactTriggerHandler'),
      'restore clears'
    );
  }
}
