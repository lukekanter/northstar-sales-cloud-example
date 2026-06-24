/**
 * OpportunityTriggerHandlerTest — covers every branch in
 * OpportunityTriggerHandler.
 *
 * Test scaffolding:
 *   - `seedAccount()` returns a persisted Account with Region__c +
 *     Customer_Segment__c populated so Territory_Segment__c has something
 *     to stamp.
 *   - `buildOpp()` returns a TestDataFactory opp pre-linked to that
 *     Account. Stage defaults to 'Qualify' (a non-terminal Northstar
 *     stage) so tests can drive transitions deliberately.
 *   - OpportunityLineItem tests need a Pricebook + PricebookEntry; we
 *     read the standard one via Test.getStandardPricebookId() and create
 *     a single test PricebookEntry against a throwaway Product2.
 */
@IsTest
private class OpportunityTriggerHandlerTest {
  // -------------------------------------------------------------------------
  // Behavior 1 — revenue recalculation via trigger path
  // -------------------------------------------------------------------------

  @IsTest
  static void insertStampsArrAndAcv() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 36000;
    opp.Subscription_Term_Months__c = '36 Months';
    insert opp;

    Opportunity got = [
      SELECT ARR__c, ACV__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(12000, got.ARR__c);
    System.assertEquals(12000, got.ACV__c);
  }

  @IsTest
  static void updateRecalculatesWhenAmountChanges() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 12000;
    opp.Subscription_Term_Months__c = '12 Months';
    insert opp;

    opp.Amount = 24000;
    update opp;

    Opportunity got = [SELECT ARR__c FROM Opportunity WHERE Id = :opp.Id];
    System.assertEquals(24000, got.ARR__c);
  }

  // -------------------------------------------------------------------------
  // Behavior 1b — ARR_Band__c stamping
  // -------------------------------------------------------------------------

  @IsTest
  static void arrBandStampsFromRecalculatedArrNotRawAmount() {
    // The crux of the fix: a 36-month $90k deal annualizes
    // ARR = 90000 * 12 / 36 = 30000, which is the "Under 50K" band — even
    // though the raw Amount (90k) would bucket as "50K to 250K". Stamping in
    // before-save Apex (after the recalc) must use the ARR, not the Amount.
    // (Amount kept < 100k so the high-value Discount-Reason VR stays out of it.)
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 90000;
    opp.Subscription_Term_Months__c = '36 Months';
    insert opp;

    Opportunity got = [
      SELECT ARR__c, ARR_Band__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(30000, got.ARR__c, 'ARR should be annualized');
    System.assertEquals(
      'Under 50K',
      got.ARR_Band__c,
      'band must bucket the recalculated ARR (30k), not the raw Amount (90k)'
    );
  }

  @IsTest
  static void arrBandCoversBucketsAndClears() {
    // buildOpp defaults the term to 12 Months, so ARR == Amount here.
    // Opps >= $100k carry a Discount_Reason__c so the high-value VR passes.
    Account acct = seedAccount();
    Opportunity under = buildOpp(acct.Id);
    under.Amount = 40000;
    Opportunity mid = buildOpp(acct.Id);
    mid.Amount = 60000; // 50K–250K, kept < 100k to avoid the discount VR
    Opportunity high = buildOpp(acct.Id);
    high.Amount = 500000;
    high.Discount_Reason__c = 'Volume Commit';
    Opportunity top = buildOpp(acct.Id);
    top.Amount = 2000000;
    top.Discount_Reason__c = 'Volume Commit';
    Opportunity blank = buildOpp(acct.Id);
    blank.Amount = null;
    List<Opportunity> opps = new List<Opportunity>{
      under,
      mid,
      high,
      top,
      blank
    };
    insert opps;

    Map<Id, Opportunity> got = new Map<Id, Opportunity>(
      [SELECT ARR_Band__c FROM Opportunity WHERE Id IN :opps]
    );
    System.assertEquals('Under 50K', got.get(under.Id).ARR_Band__c);
    System.assertEquals('50K to 250K', got.get(mid.Id).ARR_Band__c);
    System.assertEquals('250K to 1M', got.get(high.Id).ARR_Band__c);
    System.assertEquals('1M plus', got.get(top.Id).ARR_Band__c);
    System.assertEquals(
      null,
      got.get(blank.Id).ARR_Band__c,
      'blank ARR/Amount clears the band'
    );
  }

  @IsTest
  static void arrBandRestampsWhenAmountChanges() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 40000; // term 12 → ARR 40000 → Under 50K
    insert opp;
    System.assertEquals(
      'Under 50K',
      [SELECT ARR_Band__c FROM Opportunity WHERE Id = :opp.Id].ARR_Band__c
    );

    opp.Amount = 600000; // → ARR 600000 → 250K to 1M
    opp.Discount_Reason__c = 'Volume Commit'; // >= 100k → high-value VR needs a reason
    update opp;
    System.assertEquals(
      '250K to 1M',
      [SELECT ARR_Band__c FROM Opportunity WHERE Id = :opp.Id].ARR_Band__c
    );
  }

  @IsTest
  static void bandForArrCoversBoundaries() {
    System.assertEquals(null, OpportunityTriggerHandler.bandForArr(null));
    System.assertEquals('Under 50K', OpportunityTriggerHandler.bandForArr(0));
    System.assertEquals(
      'Under 50K',
      OpportunityTriggerHandler.bandForArr(49999.99)
    );
    System.assertEquals(
      '50K to 250K',
      OpportunityTriggerHandler.bandForArr(50000)
    );
    System.assertEquals(
      '50K to 250K',
      OpportunityTriggerHandler.bandForArr(249999.99)
    );
    System.assertEquals(
      '250K to 1M',
      OpportunityTriggerHandler.bandForArr(250000)
    );
    System.assertEquals(
      '250K to 1M',
      OpportunityTriggerHandler.bandForArr(999999.99)
    );
    System.assertEquals(
      '1M plus',
      OpportunityTriggerHandler.bandForArr(1000000)
    );
    System.assertEquals(
      '1M plus',
      OpportunityTriggerHandler.bandForArr(5000000)
    );
  }

  // -------------------------------------------------------------------------
  // Behavior 2 — Territory_Segment__c stamping
  // -------------------------------------------------------------------------

  @IsTest
  static void insertStampsTerritorySegmentFromAccount() {
    Account acct = seedAccount(); // Region='NA East', Segment='Commercial'
    Opportunity opp = buildOpp(acct.Id);
    insert opp;

    Opportunity got = [
      SELECT Territory_Segment__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals('NA East - Commercial', got.Territory_Segment__c);
  }

  @IsTest
  static void updateClearsTerritorySegmentWhenAccountNulled() {
    // regression — when AccountId goes from set to null on an
    // update, the stale Territory_Segment__c must be cleared. Otherwise
    // reporting still sees an account-derived segment that no longer
    // applies.
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    insert opp;
    System.assertEquals(
      'NA East - Commercial',
      [SELECT Territory_Segment__c FROM Opportunity WHERE Id = :opp.Id]
      .Territory_Segment__c
    );

    opp.AccountId = null;
    update opp;

    Opportunity got = [
      SELECT Territory_Segment__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(
      null,
      got.Territory_Segment__c,
      'Territory_Segment__c must be cleared when AccountId is nulled.'
    );
  }

  @IsTest
  static void updateRestampsTerritorySegmentWhenAccountChanges() {
    Account commercial = seedAccount();
    Account enterprise = new Account(
      Name = 'enterprise acct',
      Region__c = 'NA West',
      Customer_Segment__c = 'Enterprise'
    );
    insert enterprise;

    Opportunity opp = buildOpp(commercial.Id);
    insert opp;
    System.assertEquals(
      'NA East - Commercial',
      [SELECT Territory_Segment__c FROM Opportunity WHERE Id = :opp.Id]
      .Territory_Segment__c
    );

    opp.AccountId = enterprise.Id;
    update opp;

    Opportunity got = [
      SELECT Territory_Segment__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals('NA West - Enterprise', got.Territory_Segment__c);
  }

  @IsTest
  static void formatTerritorySegmentExercisesEdgeCases() {
    // Direct unit calls cover the helper's branches without needing DML.
    System.assertEquals(
      'NA East - Commercial',
      OpportunityTriggerHandler.formatTerritorySegment('NA East', 'Commercial')
    );
    System.assertEquals(
      '? - Commercial',
      OpportunityTriggerHandler.formatTerritorySegment(null, 'Commercial')
    );
    System.assertEquals(
      'NA East - ?',
      OpportunityTriggerHandler.formatTerritorySegment('NA East', null)
    );
    System.assertEquals(
      null,
      OpportunityTriggerHandler.formatTerritorySegment(null, null)
    );
  }

  // -------------------------------------------------------------------------
  // Behavior 3 — Proposal-requires-OLIs soft validation
  // -------------------------------------------------------------------------

  @IsTest
  static void cannotMoveToProposalWithoutOLIs() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    insert opp;

    opp.StageName = OpportunityTriggerHandler.PROPOSAL_STAGE;

    DmlException caught;
    try {
      update opp;
    } catch (DmlException e) {
      caught = e;
    }
    System.assertNotEquals(null, caught, 'Expected addError to block update.');
    System.assert(
      caught.getMessage().contains('Proposal/Price Quote'),
      'Expected the actionable error message, got: ' + caught.getMessage()
    );
  }

  @IsTest
  static void canMoveToProposalWithAtLeastOneOLI() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    insert opp;

    PricebookEntry pbe = seedPricebookEntry();
    insert new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100
    );

    opp.StageName = OpportunityTriggerHandler.PROPOSAL_STAGE;
    update opp;

    Opportunity got = [
      SELECT StageName
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(
      OpportunityTriggerHandler.PROPOSAL_STAGE,
      got.StageName
    );
  }

  // -------------------------------------------------------------------------
  // Behavior 4 — Closed Won transition
  // -------------------------------------------------------------------------

  @IsTest
  static void closedWonStampsProvisioningStatusPending() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    insert opp;

    Test.startTest();
    opp.StageName = OpportunityTriggerHandler.CLOSED_WON;
    update opp;
    Test.stopTest();

    Opportunity got = [
      SELECT Provisioning_Status__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals('Pending', got.Provisioning_Status__c);
  }

  @IsTest
  static void closedWonInsertsFollowupTaskOwnedByAE() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    insert opp;

    Test.startTest();
    opp.StageName = OpportunityTriggerHandler.CLOSED_WON;
    update opp;
    Test.stopTest();

    List<Task> tasks = [
      SELECT OwnerId, Subject, Action_Plan_Source__c
      FROM Task
      WHERE WhatId = :opp.Id
    ];
    System.assertEquals(1, tasks.size());
    System.assertEquals(
      OpportunityTriggerHandler.CLOSED_WON_TASK_SOURCE,
      tasks[0].Action_Plan_Source__c
    );
    // OwnerId mirrors the opp's owner — the test user that inserted it.
    Opportunity got = [SELECT OwnerId FROM Opportunity WHERE Id = :opp.Id];
    System.assertEquals(got.OwnerId, tasks[0].OwnerId);
  }

  @IsTest
  static void closedWonPublishesDealClosedEvent() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 12000;
    opp.Subscription_Term_Months__c = '12 Months';
    opp.Sales_Motion__c = 'New Logo';
    insert opp;

    DateTime beforeUpdate = DateTime.now();
    Test.startTest();
    opp.StageName = OpportunityTriggerHandler.CLOSED_WON;
    update opp;
    Test.stopTest();
    DateTime afterUpdate = DateTime.now();

    List<Database.SaveResult> results = OpportunityTriggerHandler.lastDealClosedPublishResults;
    System.assertNotEquals(null, results, 'Expected publish to have run.');
    System.assertEquals(1, results.size());
    System.assert(
      results[0].isSuccess(),
      'Deal_Closed__e publish should succeed.'
    );

    // regression — the event payload must:
    //   (a) carry the SEGMENT VALUE alone in Segment__c (not the combined
    //       "Region - Segment" string), and
    //   (b) carry the TRANSITION TIMESTAMP in Closed_Date__c (not the
    //       business CloseDate which can be backdated/future-dated).
    List<Deal_Closed__e> events = OpportunityTriggerHandler.lastDealClosedEvents;
    System.assertEquals(1, events.size());
    Deal_Closed__e e = events[0];

    System.assertEquals(
      'Commercial',
      e.Segment__c,
      'Segment__c should be the segment value alone, not the "Region - Segment" string.'
    );
    System.assertNotEquals(
      null,
      e.Closed_Date__c,
      'Closed_Date__c must be set.'
    );
    // Transition timestamp falls inside the update window — use ≤ to allow
    // sub-second clock resolution at the boundary.
    System.assert(
      e.Closed_Date__c >= beforeUpdate && e.Closed_Date__c <= afterUpdate,
      'Closed_Date__c must be the transition timestamp, got: ' +
        e.Closed_Date__c +
        ' (window: ' +
        beforeUpdate +
        ' to ' +
        afterUpdate +
        ')'
    );
    System.assertEquals(opp.Id, e.Opportunity_Id__c);
    System.assertEquals(acct.Id, e.Account_Id__c);
  }

  @IsTest
  static void updateWithOLIsRecalculatesArrFromRecurringSum() {
    // regression — ARR should sum recurring OLIs (Subscription
    // Usage), not be derived from opp.Amount. With $200 subscription +
    // $50 services over 12 months, ARR is 200 (not 250).
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 250; // Total deliberately inflated by the services line.
    opp.Subscription_Term_Months__c = '12 Months';
    insert opp;

    PricebookEntry pbe = seedPricebookEntry();
    insert new List<OpportunityLineItem>{
      new OpportunityLineItem(
        OpportunityId = opp.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 200,
        Revenue_Type__c = 'Subscription'
      ),
      new OpportunityLineItem(
        OpportunityId = opp.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 50,
        Revenue_Type__c = 'Services'
      )
    };

    // Any opp update triggers recalc — flip a touched field.
    opp.Description = 'recalc trigger';
    update opp;

    Opportunity got = [
      SELECT ARR__c, ACV__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(
      200,
      got.ARR__c,
      'ARR must reflect recurring OLIs only, not Amount.'
    );
    // ACV adds the prorated services line: 200 + (50 × 12 / 12) = 250.
    System.assertEquals(
      250,
      got.ACV__c,
      'ACV must be ARR + prorated one-time component.'
    );
  }

  @IsTest
  static void revenueRecalcOverflowRollsBackUpdate() {
    // regression — when the OLI fetch would have to return more
    // than OLI_ROW_CAP rows, the handler must fail fast (addError) rather
    // than recalculate on partial data. We lower the cap via @TestVisible
    // so the test can reach the overflow with a tractable number of OLIs.
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 100;
    opp.Subscription_Term_Months__c = '12 Months';
    insert opp;

    // Insert 3 OLIs — more than enough once we shrink the cap to 2.
    PricebookEntry pbe = seedPricebookEntry();
    insert new List<OpportunityLineItem>{
      new OpportunityLineItem(
        OpportunityId = opp.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 50,
        Revenue_Type__c = 'Subscription'
      ),
      new OpportunityLineItem(
        OpportunityId = opp.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 50,
        Revenue_Type__c = 'Subscription'
      ),
      new OpportunityLineItem(
        OpportunityId = opp.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 50,
        Revenue_Type__c = 'Subscription'
      )
    };

    OpportunityTriggerHandler.OLI_ROW_CAP = 2;
    Exception caught;
    try {
      // Subscription_Term_Months__c is the revenue-relevant change that
      // forces recalc. Note: Opp.Amount is a platform-rolled-up sum of
      // OLI.TotalPrice when any OLIs exist — setting it manually is
      // ignored, so we change the term instead.
      opp.Subscription_Term_Months__c = '24 Months';
      update opp;
    } catch (Exception e) {
      caught = e;
    } finally {
      OpportunityTriggerHandler.OLI_ROW_CAP = 45000;
    }

    System.assertNotEquals(
      null,
      caught,
      'Overflow must surface as exception via addError.'
    );
    System.assert(
      caught.getMessage().contains('Split this update into smaller batches'),
      'Error message should be actionable: ' + caught.getMessage()
    );

    Opportunity got = [
      SELECT Subscription_Term_Months__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(
      '12 Months',
      got.Subscription_Term_Months__c,
      'Term update must have rolled back (not committed).'
    );
  }

  @IsTest
  static void mixedBatchOnlyRecalcsRevenueAffectedOpps() {
    // regression — in a mixed batch where 1 opp changes term
    // the others change unrelated fields (e.g. Description), the OLI
    // fetch should only cover the revenue-changing opp's OLIs. We prove
    // it by setting the cap to a value that would overflow if all opps'
    // OLIs were fetched, but not if only the affected opp's are.
    Account acct = seedAccount();

    // Opp A: will change term — has 1 OLI.
    Opportunity oppA = buildOpp(acct.Id);
    oppA.Subscription_Term_Months__c = '12 Months';
    insert oppA;

    // Opps B + C: NOT changing revenue — each has 3 OLIs. Combined with
    // oppA's 1 OLI that would be 7 rows. With cap=4, fetching all three
    // opps' OLIs overflows; fetching only oppA's OLI (1 row) does not.
    Opportunity oppB = buildOpp(acct.Id);
    insert oppB;
    Opportunity oppC = buildOpp(acct.Id);
    insert oppC;

    PricebookEntry pbe = seedPricebookEntry();
    List<OpportunityLineItem> olis = new List<OpportunityLineItem>();
    olis.add(
      new OpportunityLineItem(
        OpportunityId = oppA.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Revenue_Type__c = 'Subscription'
      )
    );
    for (Integer i = 0; i < 3; i++) {
      olis.add(
        new OpportunityLineItem(
          OpportunityId = oppB.Id,
          PricebookEntryId = pbe.Id,
          Quantity = 1,
          UnitPrice = 100,
          Revenue_Type__c = 'Subscription'
        )
      );
      olis.add(
        new OpportunityLineItem(
          OpportunityId = oppC.Id,
          PricebookEntryId = pbe.Id,
          Quantity = 1,
          UnitPrice = 100,
          Revenue_Type__c = 'Subscription'
        )
      );
    }
    insert olis;

    OpportunityTriggerHandler.OLI_ROW_CAP = 4;
    try {
      oppA.Subscription_Term_Months__c = '24 Months'; // revenue-relevant
      oppB.Description = 'unrelated edit B';
      oppC.Description = 'unrelated edit C';

      // The bulk update must succeed — only oppA's OLIs go through the
      // recalc fetch (1 row, under cap=4). If the old code path were
      // still in place it would fetch all 7 OLIs and overflow.
      update new List<Opportunity>{ oppA, oppB, oppC };
    } finally {
      OpportunityTriggerHandler.OLI_ROW_CAP = 45000;
    }

    // oppA's term update committed; oppB / oppC's unrelated edits
    // committed; nothing rolled back.
    Map<Id, Opportunity> got = new Map<Id, Opportunity>(
      [
        SELECT Id, Subscription_Term_Months__c, Description
        FROM Opportunity
        WHERE Id IN :new List<Id>{ oppA.Id, oppB.Id, oppC.Id }
      ]
    );
    System.assertEquals(
      '24 Months',
      got.get(oppA.Id).Subscription_Term_Months__c
    );
    System.assertEquals('unrelated edit B', got.get(oppB.Id).Description);
    System.assertEquals('unrelated edit C', got.get(oppC.Id).Description);
  }

  @IsTest
  static void closedWonPublishFailureRollsBackTransaction() {
    // regression — when EventBus.publish fails to enqueue, the
    // Closed Won transition (and follow-up Task) must roll back so the
    // org never ends up with a Closed Won deal that didn't notify the
    // downstream provisioning subscriber.
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    insert opp;

    OpportunityTriggerHandler.simulatePublishFailureForTest = true;
    DmlException caught;
    try {
      opp.StageName = OpportunityTriggerHandler.CLOSED_WON;
      update opp;
    } catch (DmlException e) {
      caught = e;
    } finally {
      OpportunityTriggerHandler.simulatePublishFailureForTest = false;
    }

    System.assertNotEquals(
      null,
      caught,
      'Publish failure must surface as DmlException via addError.'
    );
    System.assert(
      caught.getMessage().contains('Deal_Closed__e'),
      'Error message should name the failed event: ' + caught.getMessage()
    );

    Opportunity got = [SELECT StageName FROM Opportunity WHERE Id = :opp.Id];
    System.assertNotEquals(
      OpportunityTriggerHandler.CLOSED_WON,
      got.StageName,
      'Closed Won transition should have rolled back.'
    );
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id],
      'Follow-up Task should have rolled back too.'
    );
  }

  @IsTest
  static void closedWonAlreadyClosedDoesNotRefire() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.StageName = OpportunityTriggerHandler.CLOSED_WON;
    insert opp;

    // The insert at Closed Won should NOT fire the transition path —
    // afterUpdate is where the side effects live, not afterInsert.
    System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id]);

    // An unrelated update on an already-Closed-Won opp must also not fire.
    opp.Description = 'touched';
    update opp;

    System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id]);
  }

  // -------------------------------------------------------------------------
  // Framework integration — bypass + bulk
  // -------------------------------------------------------------------------

  @IsTest
  static void bypassedHandlerSkipsAllBehaviors() {
    TriggerHandler.bypass('OpportunityTriggerHandler');
    try {
      Account acct = seedAccount();
      Opportunity opp = buildOpp(acct.Id);
      opp.Amount = 12000;
      opp.Subscription_Term_Months__c = '12 Months';
      insert opp;

      Opportunity got = [
        SELECT ARR__c, Territory_Segment__c
        FROM Opportunity
        WHERE Id = :opp.Id
      ];
      System.assertEquals(null, got.ARR__c);
      System.assertEquals(null, got.Territory_Segment__c);
    } finally {
      TriggerHandler.clearBypass('OpportunityTriggerHandler');
    }
  }

  @IsTest
  static void bulkClosedWonStaysGovernorSafe() {
    Account acct = seedAccount();
    List<Opportunity> opps = TestDataFactory.buildOpportunities(200);
    for (Opportunity o : opps) {
      o.AccountId = acct.Id;
      o.Amount = 12000;
      // Close_Won_Requires_Accepted_Quote — these close-won below.
      o.Primary_Quote_Accepted__c = true;
    }
    insert opps;

    Test.startTest();
    for (Opportunity o : opps) {
      o.StageName = OpportunityTriggerHandler.CLOSED_WON;
    }
    update opps;
    Test.stopTest();

    System.assertEquals(200, [SELECT COUNT() FROM Task]);
    Integer pendingCount = [
      SELECT COUNT()
      FROM Opportunity
      WHERE Id IN :opps AND Provisioning_Status__c = 'Pending'
    ];
    System.assertEquals(200, pendingCount);
    // One publish call for the batch should have produced 200 SaveResults.
    System.assertEquals(
      200,
      OpportunityTriggerHandler.lastDealClosedPublishResults.size()
    );
  }

  @IsTest
  static void closedWonDoesNotClobberTerminalProvisioning() {
    // A genuinely pre-provisioned deal: an Order generated, ACTIVATED, and
    // COMPLETED before the Opportunity is closed won. The Closed Won save must
    // reflect the Order's real terminal status, not re-pend it.
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 12000;
    insert opp;
    activatedSourceOrder(acct.Id, opp.Id, 'Completed');

    Test.startTest();
    opp.StageName = OpportunityTriggerHandler.CLOSED_WON;
    update opp;
    Test.stopTest();

    System.assertEquals(
      'Completed',
      [SELECT Provisioning_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Provisioning_Status__c,
      'Closed Won must preserve a terminal status backed by an activated, completed Order.'
    );
  }

  @IsTest
  static void closedWonWithPreGeneratedDraftOrderStaysPending() {
    // a merely pre-generated DRAFT Order has not been activated,
    // so its provisioning is undetermined — the deal must NOT look resolved.
    // A Draft Order ('Not Required' default) plus a stale 'Completed' Opp must
    // end 'Pending' (rolled up as in-flight), not frozen Completed nor cleared to
    // Not Required.
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 12000;
    opp.Provisioning_Status__c = 'Completed'; // stale / bad data
    insert opp;

    insert TestDataFactory.buildOrders(
      1,
      new Map<String, Object>{
        'AccountId' => acct.Id,
        'Source_Opportunity__c' => opp.Id // Draft, never activated
      }
    );

    Test.startTest();
    opp.StageName = OpportunityTriggerHandler.CLOSED_WON;
    update opp;
    Test.stopTest();

    System.assertEquals(
      'Pending',
      [SELECT Provisioning_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Provisioning_Status__c,
      'A pre-generated Draft Order is undetermined, so the deal must read Pending.'
    );
  }

  @IsTest
  static void closedWonWithActivatedNoProvOrderRollsToNotRequired() {
    // a pre-existing Order already ACTIVATED and determined
    // need no provisioning (Opp rolled to Not Required by dispatch) must NOT be
    // re-pended by the after-save flow — a no-provisioning Order emits no later
    // event, so Pending would stick forever.
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 12000;
    opp.Provisioning_Status__c = 'Completed'; // stale / bad data
    insert opp;
    activatedSourceOrder(acct.Id, opp.Id, 'Not Required');

    Test.startTest();
    opp.StageName = OpportunityTriggerHandler.CLOSED_WON;
    update opp;
    Test.stopTest();

    System.assertEquals(
      'Not Required',
      [SELECT Provisioning_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Provisioning_Status__c,
      'An activated no-provisioning Order must roll the Opp to Not Required, not be re-pended.'
    );
  }

  /**
   * Insert an Order linked to oppId, with a product, ACTIVATED, at the given
   * provisioning status — with OrderTriggerHandler bypassed so activation does
   * not auto-dispatch (these tests assert the close-won rollup, not dispatch).
   */
  private static void activatedSourceOrder(
    Id acctId,
    Id oppId,
    String provStatus
  ) {
    Id pbId = Test.getStandardPricebookId();
    update new Pricebook2(Id = pbId, IsActive = true);
    // An Order can't be Activated without an Account AND a Contract (org VR).
    Contract con = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{ 'AccountId' => acctId }
    )[0];
    insert con;
    TriggerHandler.bypass('ContractTriggerHandler');
    try {
      update new Contract(Id = con.Id, Status = 'Activated');
    } finally {
      TriggerHandler.clearBypass('ContractTriggerHandler');
    }
    Product2 p = new Product2(
      Name = 'NS Prov P ' + System.now().getTime(),
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
    Order o = TestDataFactory.buildOrders(
      1,
      new Map<String, Object>{
        'AccountId' => acctId,
        'Pricebook2Id' => pbId,
        'ContractId' => con.Id,
        'Source_Opportunity__c' => oppId
      }
    )[0];
    insert o;
    insert new OrderItem(
      OrderId = o.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100
    );
    TriggerHandler.bypass('OrderTriggerHandler');
    try {
      update new Order(
        Id = o.Id,
        Status = 'Activated',
        Provisioning_Status__c = provStatus
      );
    } finally {
      TriggerHandler.clearBypass('OrderTriggerHandler');
    }
  }

  @IsTest
  static void freshOrderOnCloseWonStampsPendingOverStaleTerminal() {
    // the guard must apply ONLY to the
    // pre-existing-order path. If an Opportunity carries a stale terminal status
    // (bad data / API edit) and Closed Won generates a FRESH Order, that Order
    // has not provisioned yet, so the deal must read Pending.
    Id stdPb = Test.getStandardPricebookId();
    Account acct = seedAccount();

    Contract con = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{ 'AccountId' => acct.Id }
    )[0];
    insert con;
    TriggerHandler.bypass('ContractTriggerHandler');
    try {
      update new Contract(Id = con.Id, Status = 'Activated');
    } finally {
      TriggerHandler.clearBypass('ContractTriggerHandler');
    }

    Product2 prod = new Product2(
      Name = 'NS Prov Product',
      Family = 'Core Platform',
      IsActive = true
    );
    insert prod;
    PricebookEntry pbe = new PricebookEntry(
      Pricebook2Id = stdPb,
      Product2Id = prod.Id,
      UnitPrice = 100,
      IsActive = true
    );
    insert pbe;

    Opportunity opp = buildOpp(acct.Id);
    opp.Pricebook2Id = stdPb;
    opp.ContractId = con.Id;
    opp.Amount = 12000;
    opp.Billing_Frequency__c = 'Annual';
    // Stale terminal status with NO provisioned Order yet.
    opp.Provisioning_Status__c = 'Completed';
    insert opp;
    insert new OpportunityLineItem(
      OpportunityId = opp.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Revenue_Type__c = 'Subscription',
      Usage_Band__c = 'Mid'
    );

    Test.startTest();
    opp.StageName = OpportunityTriggerHandler.CLOSED_WON;
    update opp;
    Test.stopTest();

    System.assertEquals(
      'Pending',
      [SELECT Provisioning_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Provisioning_Status__c,
      'A fresh Order generated at Closed Won must stamp Pending even over a stale terminal status.'
    );
  }

  // -------------------------------------------------------------------------
  // Discount approval gate (Opportunity side)
  // -------------------------------------------------------------------------

  @IsTest
  static void isDiscountApprovalRequiredCoversBranches() {
    System.assertEquals(
      true,
      OpportunityTriggerHandler.isDiscountApprovalRequired(
        new Opportunity(Discount_Reason__c = 'Strategic Logo')
      ),
      'Strategic Logo always requires approval.'
    );
    System.assertEquals(
      true,
      OpportunityTriggerHandler.isDiscountApprovalRequired(
        new Opportunity(Discount_Reason__c = 'Volume Commit', Amount = 150000)
      ),
      'A discount reason on a >=100k deal requires approval.'
    );
    System.assertEquals(
      false,
      OpportunityTriggerHandler.isDiscountApprovalRequired(
        new Opportunity(Discount_Reason__c = 'Volume Commit', Amount = 50000)
      ),
      'A discount reason under 100k does not require approval.'
    );
    System.assertEquals(
      false,
      OpportunityTriggerHandler.isDiscountApprovalRequired(new Opportunity()),
      'No discount reason → no approval required.'
    );
  }

  @IsTest
  static void discountApprovalGatesCloseWon() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id); // Primary_Quote_Accepted__c = true
    opp.Discount_Reason__c = 'Strategic Logo';
    insert opp;

    System.assertEquals(
      'Pending',
      [SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Discount_Approval_Status__c,
      'A Strategic Logo discount must escalate Opp discount approval to Pending.'
    );

    // Close Won is blocked while discount approval is Pending.
    Boolean blocked = false;
    try {
      opp.StageName = OpportunityTriggerHandler.CLOSED_WON;
      update opp;
    } catch (DmlException e) {
      blocked = true;
      System.assert(
        e.getMessage().toLowerCase().contains('discount'),
        'Expected the discount-approval close gate; got: ' + e.getMessage()
      );
    }
    System.assert(
      blocked,
      'A discounted Opp must not close won without Deal Desk approval.'
    );

    // Record the approval (the approval process does this via field update),
    // then Close Won succeeds.
    Opportunity fresh = [
      SELECT Id, Discount_Reason__c, StageName
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    fresh.Discount_Approval_Status__c = 'Approved';
    update fresh;
    fresh.StageName = OpportunityTriggerHandler.CLOSED_WON;
    update fresh;

    System.assertEquals(
      OpportunityTriggerHandler.CLOSED_WON,
      [SELECT StageName FROM Opportunity WHERE Id = :opp.Id].StageName,
      'An approved discounted Opp must close won.'
    );
  }

  @IsTest
  static void approvedDiscountReopensWhenInputsChange() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Discount_Reason__c = 'Volume Commit';
    opp.Amount = 150000; // reason + >=100k → approval required
    insert opp;

    // Record an approval (the approval process does this via field update).
    Opportunity toApprove = [SELECT Id FROM Opportunity WHERE Id = :opp.Id];
    toApprove.Discount_Approval_Status__c = 'Approved';
    update toApprove;
    System.assertEquals(
      'Approved',
      [SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Discount_Approval_Status__c
    );

    // Re-papering the discount reason must void the stale approval.
    Opportunity changeReason = [SELECT Id FROM Opportunity WHERE Id = :opp.Id];
    changeReason.Discount_Reason__c = 'Strategic Logo';
    update changeReason;
    System.assertEquals(
      'Pending',
      [SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id = :opp.Id]
      .Discount_Approval_Status__c,
      'Changing the discount reason must re-open an approved Opp discount.'
    );
  }

  @IsTest
  static void discountInputsWorsenedCoversBranches() {
    System.assertEquals(
      false,
      OpportunityTriggerHandler.discountInputsWorsened(new Opportunity(), null),
      'No prior → never worsened.'
    );
    System.assertEquals(
      true,
      OpportunityTriggerHandler.discountInputsWorsened(
        new Opportunity(Discount_Reason__c = 'Strategic Logo'),
        new Opportunity(Discount_Reason__c = 'Volume Commit')
      ),
      'A changed discount reason is material.'
    );
    System.assertEquals(
      true,
      OpportunityTriggerHandler.discountInputsWorsened(
        new Opportunity(Discount_Reason__c = 'Volume Commit', Amount = 200000),
        new Opportunity(Discount_Reason__c = 'Volume Commit', Amount = 150000)
      ),
      'A higher Amount is material.'
    );
    System.assertEquals(
      true,
      OpportunityTriggerHandler.discountInputsWorsened(
        new Opportunity(Discount_Reason__c = 'Strategic Logo', Amount = 80000),
        new Opportunity(Discount_Reason__c = 'Strategic Logo', Amount = null)
      ),
      'A blank → real Amount is material (the exposure became known).'
    );
    System.assertEquals(
      false,
      OpportunityTriggerHandler.discountInputsWorsened(
        new Opportunity(Discount_Reason__c = 'Volume Commit', Amount = 120000),
        new Opportunity(Discount_Reason__c = 'Volume Commit', Amount = 150000)
      ),
      'A lower Amount with the same reason does not force re-review.'
    );
  }

  @IsTest
  static void blankApproverFallsBackToOwnerManager() {
    // A discount-approval-required Opp with a blank Deal_Desk_Approver__c falls
    // back to the owner's manager so the approval step resolves.
    User owner = createOwnerWithManager();
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id); // Primary_Quote_Accepted__c = true
    opp.OwnerId = owner.Id;
    opp.Discount_Reason__c = 'Strategic Logo'; // needs discount approval
    opp.Deal_Desk_Approver__c = null;
    insert opp;

    Opportunity got = [
      SELECT Discount_Approval_Status__c, Deal_Desk_Approver__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals('Pending', got.Discount_Approval_Status__c);
    System.assertEquals(
      owner.ManagerId,
      got.Deal_Desk_Approver__c,
      'A blank approver on a discount-approval-required Opp must fall back to ' +
      'the owner manager.'
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /**
   * Returns a persisted owner User whose ManagerId is set, with the User DML
   * isolated inside System.runAs so it doesn't trip MIXED_DML against the
   * non-setup DML afterward. Uses the running user's profile for access.
   */
  private static User createOwnerWithManager() {
    String uniq =
      '' +
      DateTime.now().getTime() +
      Math.abs(Crypto.getRandomInteger());
    Id profileId = UserInfo.getProfileId();
    User manager = new User(
      FirstName = 'NS',
      LastName = 'Manager',
      Alias = 'nsmgr',
      Email = 'ns.mgr@example.com.invalid',
      Username = 'ns.omgr.' + uniq + '@example.com.invalid',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      TimeZoneSidKey = 'America/Los_Angeles',
      ProfileId = profileId
    );
    User owner = new User(
      FirstName = 'NS',
      LastName = 'Owner',
      Alias = 'nsownr',
      Email = 'ns.owner@example.com.invalid',
      Username = 'ns.oownr.' + uniq + '@example.com.invalid',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      TimeZoneSidKey = 'America/Los_Angeles',
      ProfileId = profileId
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert manager;
      owner.ManagerId = manager.Id;
      insert owner;
    }
    return owner;
  }

  /**
   * Self-sufficient Account builder. We deliberately set Region__c and
   * Customer_Segment__c explicitly rather than relying on TestDataFactory's
   * defaults — the org's deployed TestDataFactory.cls may predate the
   * field-default updates from (validate-only deploys never write the
   * Apex back to the org), in which case its `buildAccounts` returns an
   * Account with the custom fields blank. The trigger we're testing needs
   * those values populated to do anything useful.
   */
  private static Account seedAccount() {
    Account a = new Account(
      Name = 'NS Opp Test Acct',
      Region__c = 'NA East',
      Customer_Segment__c = 'Commercial'
    );
    insert a;
    return a;
  }

  private static Opportunity buildOpp(Id accountId) {
    Opportunity o = TestDataFactory.buildOpportunities(1)[0];
    o.AccountId = accountId;
    // Override the factory's 'Prospecting' default — Prospecting isn't in
    // the Northstar BP, so the platform may reject it on RT-bound record
    // types. 'Qualify' is the first Northstar stage. Defensive in case
    // the org's factory build returns this default.
    o.StageName = 'Qualify';
    // adds Cannot_Close_Won_Without_Accepted_Quote_Or_Override; the
    // Closed Won transition tests below close-won this opp, so pre-stamp the
    // accepted-quote flag the rule checks (these tests predate the quote-sync
    // that would otherwise set it).
    o.Primary_Quote_Accepted__c = true;
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

  // -------------------------------------------------------------------------
  // Behavior — Has_Primary_Contact_Role__c stamp + Negotiation gate
  // -------------------------------------------------------------------------

  @IsTest
  static void cannotMoveToNegotiationWithoutPrimaryContactRole() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 10000;
    insert opp;

    DmlException caught;
    Test.startTest();
    try {
      opp.StageName = 'Negotiation';
      update opp;
    } catch (DmlException e) {
      caught = e;
    }
    Test.stopTest();

    System.assertNotEquals(
      null,
      caught,
      'Moving to Negotiation without a primary contact role should be blocked'
    );
    System.assert(
      caught.getMessage().contains('primary contact role'),
      'Expected the primary-contact-role VR message, got: ' +
      caught.getMessage()
    );
  }

  @IsTest
  static void cannotInsertDirectlyAtNegotiation() {
    // Creation-time bypass guard: a primary OCR cannot exist before
    // the Opp has an Id, so inserting straight at Negotiation can never satisfy
    // the rule — the ISNEW() disjunct must block it.
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 10000;
    opp.StageName = 'Negotiation';

    DmlException caught;
    try {
      insert opp;
    } catch (DmlException e) {
      caught = e;
    }

    System.assertNotEquals(
      null,
      caught,
      'Inserting an Opportunity directly at Negotiation should be blocked'
    );
    System.assert(
      caught.getMessage().contains('primary contact role'),
      'Expected the primary-contact-role VR message, got: ' +
      caught.getMessage()
    );
  }

  @IsTest
  static void canMoveToNegotiationWithPrimaryContactRole() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 10000;
    insert opp;
    addPrimaryContactRole(opp.Id, acct.Id);

    Test.startTest();
    opp.StageName = 'Negotiation';
    update opp;
    Test.stopTest();

    Opportunity got = [
      SELECT StageName, Has_Primary_Contact_Role__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals('Negotiation', got.StageName);
    System.assertEquals(
      true,
      got.Has_Primary_Contact_Role__c,
      'Stamp should be true once a primary OCR exists'
    );
  }

  @IsTest
  static void stampStaysFalseWithOnlyNonPrimaryContactRole() {
    Account acct = seedAccount();
    Opportunity opp = buildOpp(acct.Id);
    opp.Amount = 10000;
    insert opp;
    // A contact role that is NOT primary must not satisfy the gate.
    Contact c = new Contact(LastName = 'NS NonPrimary', AccountId = acct.Id);
    insert c;
    insert new OpportunityContactRole(
      OpportunityId = opp.Id,
      ContactId = c.Id,
      IsPrimary = false
    );

    // Any update re-stamps; the boolean must remain false.
    opp.Description = 'touch';
    update opp;

    Opportunity got = [
      SELECT Has_Primary_Contact_Role__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(
      false,
      got.Has_Primary_Contact_Role__c,
      'A non-primary contact role must not set the stamp'
    );

    // The Negotiation transition is still blocked.
    DmlException caught;
    try {
      opp.StageName = 'Negotiation';
      update opp;
    } catch (DmlException e) {
      caught = e;
    }
    System.assertNotEquals(
      null,
      caught,
      'A non-primary contact role should not unlock Negotiation'
    );
  }

  private static void addPrimaryContactRole(Id oppId, Id accountId) {
    Contact c = new Contact(LastName = 'NS Primary', AccountId = accountId);
    insert c;
    insert new OpportunityContactRole(
      OpportunityId = oppId,
      ContactId = c.Id,
      IsPrimary = true
    );
  }
}
