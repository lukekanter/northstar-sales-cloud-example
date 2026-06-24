/**
 * Tests for COPY_QuoteLineItemTriggerHandler.
 *
 * Exercises the three behaviours: copy-on-insert when the source-OLI link is
 * already present, copy-on-update when the link transitions blank -> populated
 * (the workflow path), and suppression via the framework bypass API. The
 * field-mapping config comes from the deployed Quote_Line_Item_Field_Mapping__mdt
 * rows (CMDT is visible to tests without inserting it). Billing_Start_Offset_Days__c
 * (a Number) is used as the probe field because it asserts unambiguously.
 */
@isTest
private class COPY_QuoteLineItemTriggerHandlerTest {
  private static final Decimal OLI_OFFSET = 15;
  private static final Decimal QLI_OFFSET_BEFORE = 0;

  private class Fixture {
    OpportunityLineItem oli;
    Quote quote;
    PricebookEntry pbe;
  }

  /**
   * Build a standard-pricebook product + entry, an Opportunity with one OLI
   * (Billing_Start_Offset_Days__c = OLI_OFFSET), and a Quote. Unrelated
   * handlers are bypassed for the setup DML; COPY_ is never triggered here
   * because no QuoteLineItem DML happens.
   */
  private static Fixture createFixture() {
    TestDataFactory.bypassTriggers(
      new List<String>{
        'OpportunityTriggerHandler',
        'OpportunityLineItemTriggerHandler',
        'QuoteTriggerHandler',
        'QuoteLineItemTriggerHandler'
      }
    );

    Id stdPbId = Test.getStandardPricebookId();

    Product2 product = TestDataFactory.buildProducts(1)[0];
    insert product;

    PricebookEntry pbe = TestDataFactory.buildPricebookEntries(
      1,
      new Map<String, Object>{
        'Pricebook2Id' => stdPbId,
        'Product2Id' => product.Id
      }
    )[0];
    insert pbe;

    Account acct = TestDataFactory.buildAccounts(1)[0];
    insert acct;

    Opportunity opp = TestDataFactory.buildOpportunities(
      1,
      new Map<String, Object>{
        'AccountId' => acct.Id,
        'Pricebook2Id' => stdPbId
      }
    )[0];
    insert opp;

    OpportunityLineItem oli = TestDataFactory.buildOpportunityLineItems(
      1,
      new Map<String, Object>{
        'OpportunityId' => opp.Id,
        'PricebookEntryId' => pbe.Id,
        'Billing_Start_Offset_Days__c' => OLI_OFFSET
      }
    )[0];
    insert oli;

    Quote quote = TestDataFactory.buildQuotes(
      1,
      new Map<String, Object>{
        'OpportunityId' => opp.Id,
        'Pricebook2Id' => stdPbId
      }
    )[0];
    insert quote;

    TestDataFactory.restoreTriggers();

    Fixture f = new Fixture();
    f.oli = oli;
    f.quote = quote;
    f.pbe = pbe;
    return f;
  }

  private static QuoteLineItem buildQli(
    Fixture f,
    Id sourceOliId,
    Decimal offset
  ) {
    return TestDataFactory.buildQuoteLineItems(
      1,
      new Map<String, Object>{
        'QuoteId' => f.quote.Id,
        'PricebookEntryId' => f.pbe.Id,
        'Opportunity_Line_Item_ID__c' => sourceOliId,
        'Billing_Start_Offset_Days__c' => offset
      }
    )[0];
  }

  @isTest
  static void copiesMappedFieldsOnInsertWhenLinkPresent() {
    Fixture f = createFixture();
    // Suppress the unrelated rollup handlers; leave COPY_ active.
    TestDataFactory.bypassTriggers(
      new List<String>{ 'QuoteTriggerHandler', 'QuoteLineItemTriggerHandler' }
    );

    QuoteLineItem qli = buildQli(f, f.oli.Id, QLI_OFFSET_BEFORE);

    Test.startTest();
    insert qli;
    Test.stopTest();

    QuoteLineItem reloaded = [
      SELECT Billing_Start_Offset_Days__c, Opportunity_Line_Item_ID__c
      FROM QuoteLineItem
      WHERE Id = :qli.Id
    ];
    System.assertEquals(
      OLI_OFFSET,
      reloaded.Billing_Start_Offset_Days__c,
      'OLI Billing_Start_Offset_Days__c should have been copied down onto the QLI'
    );
  }

  @isTest
  static void copiesOnUpdateWhenLinkTransitionsToPopulated() {
    Fixture f = createFixture();
    TestDataFactory.bypassTriggers(
      new List<String>{ 'QuoteTriggerHandler', 'QuoteLineItemTriggerHandler' }
    );

    // Insert with no source link -> COPY_ leaves the field at its own value.
    QuoteLineItem qli = buildQli(f, null, QLI_OFFSET_BEFORE);
    insert qli;

    QuoteLineItem afterInsert = [
      SELECT Billing_Start_Offset_Days__c
      FROM QuoteLineItem
      WHERE Id = :qli.Id
    ];
    System.assertEquals(
      QLI_OFFSET_BEFORE,
      afterInsert.Billing_Start_Offset_Days__c,
      'With no source link, nothing should be copied on insert'
    );

    // Stamp the link -> before-update copies the source value down.
    qli.Opportunity_Line_Item_ID__c = f.oli.Id;
    Test.startTest();
    update qli;
    Test.stopTest();

    QuoteLineItem afterUpdate = [
      SELECT Billing_Start_Offset_Days__c
      FROM QuoteLineItem
      WHERE Id = :qli.Id
    ];
    System.assertEquals(
      OLI_OFFSET,
      afterUpdate.Billing_Start_Offset_Days__c,
      'Stamping the source-OLI link should copy the mapped fields on update'
    );
  }

  @isTest
  static void bypassApiSuppressesTheCopy() {
    Fixture f = createFixture();
    TestDataFactory.bypassTriggers(
      new List<String>{
        'QuoteTriggerHandler',
        'QuoteLineItemTriggerHandler',
        'COPY_QuoteLineItemTriggerHandler'
      }
    );

    QuoteLineItem qli = buildQli(f, f.oli.Id, QLI_OFFSET_BEFORE);

    Test.startTest();
    insert qli;
    Test.stopTest();

    QuoteLineItem reloaded = [
      SELECT Billing_Start_Offset_Days__c
      FROM QuoteLineItem
      WHERE Id = :qli.Id
    ];
    System.assertEquals(
      QLI_OFFSET_BEFORE,
      reloaded.Billing_Start_Offset_Days__c,
      'When COPY_QuoteLineItemTriggerHandler is bypassed, no copy should occur'
    );
  }
}
