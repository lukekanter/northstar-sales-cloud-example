/**
 * OpportunityLineItemTriggerHandlerTest — exercises the OLI → parent Opp
 * recalc path that closes on (OLI edits no longer leave
 * ARR/ACV stale).
 */
@IsTest
private class OpportunityLineItemTriggerHandlerTest {
  @IsTest
  static void insertingOLIRecalcsParentArrFromRecurring() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = null;
    opp.Subscription_Term_Months__c = '12 Months';
    insert opp;

    // Without OLIs, recalc falls back to Amount which is null → ARR null.
    System.assertEquals(
      null,
      [SELECT ARR__c FROM Opportunity WHERE Id = :opp.Id].ARR__c
    );

    PricebookEntry pbe = seedPricebookEntry();
    insert new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 500,
      Revenue_Type__c = 'Subscription'
    );

    Opportunity got = [
      SELECT ARR__c, ACV__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(
      500,
      got.ARR__c,
      'OLI insert should have rolled up to parent ARR.'
    );
    System.assertEquals(500, got.ACV__c);
  }

  @IsTest
  static void updatingRevenueTypeRecalcsParent() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Subscription_Term_Months__c = '12 Months';
    insert opp;

    PricebookEntry pbe = seedPricebookEntry();
    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 300,
      Revenue_Type__c = 'Services' // one-time at first
    );
    insert oli;

    // Services-only opp: ARR = 0, ACV = 300 (full one-time prorated to 12).
    Opportunity afterInsert = [
      SELECT ARR__c, ACV__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(0, afterInsert.ARR__c);
    System.assertEquals(300, afterInsert.ACV__c);

    // Flip to Subscription — ARR should now reflect the line.
    oli.Revenue_Type__c = 'Subscription';
    update oli;

    Opportunity afterUpdate = [
      SELECT ARR__c, ACV__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(
      300,
      afterUpdate.ARR__c,
      'Flipping Revenue_Type__c to Subscription should push ARR up.'
    );
    System.assertEquals(300, afterUpdate.ACV__c);
  }

  @IsTest
  static void deletingOLIRecalcsParent() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Subscription_Term_Months__c = '12 Months';
    insert opp;

    PricebookEntry pbe = seedPricebookEntry();
    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 1000,
      Revenue_Type__c = 'Subscription'
    );
    insert oli;
    System.assertEquals(
      1000,
      [SELECT ARR__c FROM Opportunity WHERE Id = :opp.Id].ARR__c
    );

    delete oli;

    // Now no OLIs — service falls back to opp.Amount, which is whatever the
    // factory set. We just assert the recalc did fire (ARR changes off the
    // 1000 it was at).
    Opportunity got = [SELECT ARR__c FROM Opportunity WHERE Id = :opp.Id];
    System.assertNotEquals(
      1000,
      got.ARR__c,
      'Deleting the OLI should have re-rolled the parent ARR.'
    );
  }

  @IsTest
  static void updatingNonPricingFieldDoesNotRecalcParent() {
    // Touching only Description (or any non-revenue field) on an OLI must
    // not pay the recalc SOQL+DML cost. We assert by counting DML against
    // Opportunity before vs after the non-pricing edit.
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    insert opp;

    PricebookEntry pbe = seedPricebookEntry();
    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Revenue_Type__c = 'Subscription',
      Description = 'initial'
    );
    insert oli;

    Integer dmlBefore = Limits.getDmlStatements();
    oli.Description = 'updated description only';
    update oli;
    Integer dmlAfter = Limits.getDmlStatements();

    System.assertEquals(
      dmlBefore + 1,
      dmlAfter,
      'Only the OLI update DML should have fired — no parent recalc DML.'
    );
  }

  @IsTest
  static void oliFetchOverflowRollsBackEdit() {
    // regression — when the parent rollup query would have
    // return more than OLI_ROW_CAP rows, the handler must fail fast on
    // the OLI batch rather than silently committing partial ARR/ACV.
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Subscription_Term_Months__c = '12 Months';
    insert opp;

    PricebookEntry pbe = seedPricebookEntry();
    // Seed 2 OLIs first (under any cap).
    List<OpportunityLineItem> seed = new List<OpportunityLineItem>{
      new OpportunityLineItem(
        OpportunityId = opp.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Revenue_Type__c = 'Subscription'
      ),
      new OpportunityLineItem(
        OpportunityId = opp.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Revenue_Type__c = 'Subscription'
      )
    };
    insert seed;
    System.assertEquals(
      200,
      [SELECT ARR__c FROM Opportunity WHERE Id = :opp.Id].ARR__c
    );

    // Now lower the cap, attempt to insert a 3rd OLI — fetch returns 3 rows
    // which exceeds cap=2 → overflow → addError on the new OLI batch.
    OpportunityLineItemTriggerHandler.OLI_ROW_CAP = 2;
    DmlException caught;
    try {
      insert new OpportunityLineItem(
        OpportunityId = opp.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Revenue_Type__c = 'Subscription'
      );
    } catch (DmlException e) {
      caught = e;
    } finally {
      OpportunityLineItemTriggerHandler.OLI_ROW_CAP = 45000;
    }

    System.assertNotEquals(
      null,
      caught,
      'Overflow must surface as DmlException via addError on the OLI insert.'
    );
    System.assert(
      caught.getMessage().contains('smaller batches'),
      'Error should be actionable: ' + caught.getMessage()
    );

    // 3rd OLI did NOT persist (rolled back).
    Integer count = [
      SELECT COUNT()
      FROM OpportunityLineItem
      WHERE OpportunityId = :opp.Id
    ];
    System.assertEquals(
      2,
      count,
      'Failing OLI insert should have rolled back.'
    );
    // And parent ARR stays at the pre-overflow value.
    System.assertEquals(
      200,
      [SELECT ARR__c FROM Opportunity WHERE Id = :opp.Id].ARR__c,
      'Parent ARR should not be partially-updated from the rolled-back insert.'
    );
  }

  @IsTest
  static void bulkOLIInsertStaysGovernorSafe() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Subscription_Term_Months__c = '12 Months';
    insert opp;

    PricebookEntry pbe = seedPricebookEntry();
    List<OpportunityLineItem> olis = new List<OpportunityLineItem>();
    for (Integer i = 0; i < 100; i++) {
      olis.add(
        new OpportunityLineItem(
          OpportunityId = opp.Id,
          PricebookEntryId = pbe.Id,
          Quantity = 1,
          UnitPrice = 10,
          Revenue_Type__c = 'Subscription'
        )
      );
    }
    Test.startTest();
    insert olis;
    Test.stopTest();

    System.assertEquals(
      1000,
      [SELECT ARR__c FROM Opportunity WHERE Id = :opp.Id].ARR__c,
      '100 OLIs × $10 each = $1000 ARR.'
    );
  }

  // -------------------------------------------------------------------------
  // Is_Discounted__c roll-up
  // -------------------------------------------------------------------------

  @IsTest
  static void discountedLineStampsIsDiscountedFlag() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    // A reason up front so the high-value (now discount-keyed) VR is satisfied
    // once the discounted line flips Is_Discounted__c true.
    opp.Discount_Reason__c = 'Volume Commit';
    insert opp;
    System.assertEquals(
      false,
      [SELECT Is_Discounted__c FROM Opportunity WHERE Id = :opp.Id]
      .Is_Discounted__c,
      'A fresh opp with no lines is not discounted.'
    );

    PricebookEntry pbe = seedPricebookEntry();
    insert new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 2,
      UnitPrice = 100,
      Discount = 20,
      Revenue_Type__c = 'Subscription'
    );

    System.assertEquals(
      true,
      [SELECT Is_Discounted__c FROM Opportunity WHERE Id = :opp.Id]
      .Is_Discounted__c,
      'A line with Discount > 0 should flip the parent Is_Discounted__c true.'
    );
  }

  @IsTest
  static void nonDiscountedLineLeavesFlagFalse() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    insert opp;

    PricebookEntry pbe = seedPricebookEntry();
    insert new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Revenue_Type__c = 'Subscription'
    );

    System.assertEquals(
      false,
      [SELECT Is_Discounted__c FROM Opportunity WHERE Id = :opp.Id]
      .Is_Discounted__c,
      'A line with no discount must not flip Is_Discounted__c.'
    );
  }

  @IsTest
  static void removingLineDiscountClearsFlag() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Discount_Reason__c = 'Volume Commit';
    insert opp;

    PricebookEntry pbe = seedPricebookEntry();
    OpportunityLineItem oli = new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 2,
      UnitPrice = 100,
      Discount = 15,
      Revenue_Type__c = 'Subscription'
    );
    insert oli;
    System.assertEquals(
      true,
      [SELECT Is_Discounted__c FROM Opportunity WHERE Id = :opp.Id]
      .Is_Discounted__c
    );

    // Drop the discount — the flag must roll back to false.
    oli.Discount = 0;
    update oli;
    System.assertEquals(
      false,
      [SELECT Is_Discounted__c FROM Opportunity WHERE Id = :opp.Id]
      .Is_Discounted__c,
      'Clearing the only line discount must roll Is_Discounted__c back to false.'
    );
  }

  @IsTest
  static void discountedLineWithoutReasonIsBlockedByVR() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    // No Discount_Reason__c — adding a discounted line must be blocked once the
    // OLI roll-up flips Is_Discounted__c true (Discount_Reason_Required_High_Value).
    insert opp;

    PricebookEntry pbe = seedPricebookEntry();
    Boolean blocked = false;
    try {
      insert new OpportunityLineItem(
        OpportunityId = opp.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Discount = 10,
        Revenue_Type__c = 'Subscription'
      );
    } catch (DmlException e) {
      blocked = true;
      System.assert(
        e.getMessage().contains('Discount Reason'),
        'Expected the discount-reason gate; got: ' + e.getMessage()
      );
    }
    System.assert(
      blocked,
      'A discounted line on a reason-less opp must be blocked by the VR.'
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private static Account seedAccount() {
    Account a = new Account(
      Name = 'NS OLI Test Acct',
      Region__c = 'NA East',
      Customer_Segment__c = 'Commercial'
    );
    insert a;
    return a;
  }

  private static Opportunity buildOpp(Id accountId) {
    Opportunity o = TestDataFactory.buildOpportunities(1)[0];
    o.AccountId = accountId;
    o.StageName = 'Qualify';
    return o;
  }

  private static PricebookEntry seedPricebookEntry() {
    Product2 p = new Product2(
      Name = 'OLI Test Product',
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
