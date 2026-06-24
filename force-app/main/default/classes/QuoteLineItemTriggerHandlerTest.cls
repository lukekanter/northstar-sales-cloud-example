/**
 * QuoteLineItemTriggerHandlerTest — proves that editing a QuoteLineItem rolls
 * up to the parent Quote's trigger-maintained approval state, so the
 * Finance_Approval_Status__c discriminator stays fresh when a Services line is
 * discounted past the floor without re-saving the parent.
 */
@IsTest
private class QuoteLineItemTriggerHandlerTest {
  @IsTest
  static void insertingBelowFloorServicesLineEscalatesFinanceOnParent() {
    Quote q = seedQuote();
    PricebookEntry pbe = seedPricebookEntry();

    Test.startTest();
    insert new QuoteLineItem(
      QuoteId = q.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Discount = 25, // > 20 services floor
      Revenue_Type__c = 'Services'
    );
    Test.stopTest();

    Quote got = [
      SELECT Finance_Approval_Status__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals(
      'Pending',
      got.Finance_Approval_Status__c,
      'Inserting a below-floor Services QLI must roll up to the parent ' +
      'Quote and escalate Finance approval, even without re-saving the Quote.'
    );
  }

  @IsTest
  static void correctingThenDeletingServicesLineClearsFinanceOnParent() {
    Quote q = seedQuote();
    PricebookEntry pbe = seedPricebookEntry();
    QuoteLineItem qli = new QuoteLineItem(
      QuoteId = q.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Discount = 25,
      Revenue_Type__c = 'Services'
    );
    insert qli;
    System.assertEquals(
      'Pending',
      [SELECT Finance_Approval_Status__c FROM Quote WHERE Id = :q.Id]
      .Finance_Approval_Status__c,
      'Precondition: below-floor line escalates Finance.'
    );

    // Correct the pricing below the floor via QLI update — the parent must
    // recompute and clear without a separate Quote save.
    update new QuoteLineItem(Id = qli.Id, Discount = 5);
    System.assertEquals(
      'Not Required',
      [SELECT Finance_Approval_Status__c FROM Quote WHERE Id = :q.Id]
      .Finance_Approval_Status__c,
      'Correcting the Services discount via QLI update must clear Finance.'
    );

    // Re-introduce the requirement, then delete the line — afterDelete must
    // also roll up.
    update new QuoteLineItem(Id = qli.Id, Discount = 30);
    System.assertEquals(
      'Pending',
      [SELECT Finance_Approval_Status__c FROM Quote WHERE Id = :q.Id]
      .Finance_Approval_Status__c,
      'Raising the discount again must re-escalate.'
    );
    delete qli;
    System.assertEquals(
      'Not Required',
      [SELECT Finance_Approval_Status__c FROM Quote WHERE Id = :q.Id]
      .Finance_Approval_Status__c,
      'Deleting the below-floor line must clear Finance on the parent.'
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private static Quote seedQuote() {
    update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
    Account a = new Account(
      Name = 'NS QLI Test Acct',
      Region__c = 'NA East',
      Customer_Segment__c = 'Commercial'
    );
    insert a;
    Opportunity o = TestDataFactory.buildOpportunities(1)[0];
    o.AccountId = a.Id;
    o.StageName = 'Qualify';
    o.Pricebook2Id = Test.getStandardPricebookId();
    insert o;
    Quote q = TestDataFactory.buildQuotes(1)[0];
    q.OpportunityId = o.Id;
    q.Pricebook2Id = Test.getStandardPricebookId();
    insert q;
    return q;
  }

  private static PricebookEntry seedPricebookEntry() {
    Product2 p = new Product2(
      Name = 'QLI Trigger Test Product',
      Family = 'Core Platform',
      IsActive = true
    );
    insert p;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = Test.getStandardPricebookId(),
      Product2Id = p.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert pbe;
    return pbe;
  }
}
