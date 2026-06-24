/**
 * QuoteTriggerHandlerTest — covers every branch in QuoteTriggerHandler.
 *
 * Test scaffolding:
 *   - `seedAccount()` returns a persisted Account.
 *   - `seedOpp(acctId)` returns a persisted Opportunity on the standard
 *     pricebook (so a Quote can sync to it).
 *   - `buildQuote(oppId)` returns an UNSAVED Quote linked to that opp and
 *     the standard pricebook, with the four commercial fields set to values
 *     distinct from the opp's factory defaults so propagation is provable.
 *   - QLI tests create a single PricebookEntry against the standard
 *     pricebook via `seedPricebookEntry()`.
 *   - `IsSyncing` is system-controlled, so the sync tests start the sync the
 *     real way: set `Opportunity.SyncedQuoteId` and re-query the Quote.
 */
@IsTest
private class QuoteTriggerHandlerTest {
  // -------------------------------------------------------------------------
  // Behavior 1 + 2 — discount roll-up and approval escalation
  // -------------------------------------------------------------------------

  @IsTest
  static void updateComputesBlendedDiscountAndEscalatesApproval() {
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    insert q;

    PricebookEntry pbe = seedPricebookEntry();
    insert new List<QuoteLineItem>{
      // Weighted blend = (10*100 + 30*300) / (100 + 300) = 25.00
      new QuoteLineItem(
        QuoteId = q.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Discount = 10
      ),
      new QuoteLineItem(
        QuoteId = q.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 300,
        Discount = 30
      )
    };

    q.Validity_Period_Days__c = 45; // force an update
    update q;

    Quote got = [
      SELECT Total_Discount_Percent__c, Approval_Status__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals(
      25,
      got.Total_Discount_Percent__c,
      'Blended discount should be UnitPrice x Quantity weighted.'
    );
    System.assertEquals(
      'Pending',
      got.Approval_Status__c,
      'Discount over threshold must escalate approval to Pending.'
    );
  }

  @IsTest
  static void belowThresholdDoesNotEscalate() {
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    insert q;

    PricebookEntry pbe = seedPricebookEntry();
    insert new QuoteLineItem(
      QuoteId = q.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Discount = 5 // below the 15% threshold
    );

    q.Validity_Period_Days__c = 45;
    update q;

    Quote got = [
      SELECT Total_Discount_Percent__c, Approval_Status__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals(5, got.Total_Discount_Percent__c);
    System.assertEquals(
      'Not Required',
      got.Approval_Status__c,
      'A below-threshold discount must not escalate approval.'
    );
  }

  @IsTest
  static void servicesLineBelowFloorEscalatesEvenWhenBlendedIsLow() {
    // Blended discount stays well under the 15% threshold, but one Services
    // line is discounted past the 20% margin floor — Finance review is still
    // required (the per-line check the blended rollup misses).
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    insert q;

    PricebookEntry pbe = seedPricebookEntry();
    insert new List<QuoteLineItem>{
      // Services line: 25% discount (> 20 floor), small weight.
      new QuoteLineItem(
        QuoteId = q.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Discount = 25,
        Revenue_Type__c = 'Services'
      ),
      // Large undiscounted line keeps the blend low (2.5% << 15% threshold).
      new QuoteLineItem(
        QuoteId = q.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 900,
        Discount = 0
      )
    };

    q.Validity_Period_Days__c = 45; // force an update
    update q;

    Quote got = [
      SELECT
        Total_Discount_Percent__c,
        Approval_Status__c,
        Finance_Approval_Status__c,
        Discount_Approval_Status__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assert(
      got.Total_Discount_Percent__c < 15,
      'Blended discount should be under threshold; got ' +
      got.Total_Discount_Percent__c
    );
    System.assertEquals(
      'Pending',
      got.Finance_Approval_Status__c,
      'A Services line past the floor must escalate the finance dimension ' +
      'specifically.'
    );
    System.assertEquals(
      'Not Required',
      got.Discount_Approval_Status__c,
      'A low blended discount must NOT escalate the discount dimension — the ' +
      'finance escalation is independent.'
    );
    System.assertEquals(
      'Pending',
      got.Approval_Status__c,
      'The rollup reflects the pending finance dimension.'
    );

    // Correcting the services pricing below the floor must clear the finance
    // dimension (it is recomputed authoritatively each save), so a quote that
    // was blocked can proceed once fixed.
    QuoteLineItem servicesLine = [
      SELECT Id
      FROM QuoteLineItem
      WHERE QuoteId = :q.Id AND Revenue_Type__c = 'Services'
      LIMIT 1
    ];
    update new QuoteLineItem(Id = servicesLine.Id, Discount = 5);

    Quote fixedQuote = [
      SELECT Finance_Approval_Status__c, Approval_Status__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals(
      'Not Required',
      fixedQuote.Finance_Approval_Status__c,
      'Correcting the services discount below the floor must clear the ' +
      'finance dimension (rolled up via the QuoteLineItem trigger).'
    );
  }

  @IsTest
  static void quoteLeavingAcceptedClearsOpportunityFlag() {
    // Accept + sync a quote (stamps Primary_Quote_Accepted__c), then move it
    // out of Accepted — the sticky flag must be cleared so Close-Won can't
    // rely on a withdrawn acceptance.
    Account acct = seedAccount();
    Opportunity opp = seedOpp(acct.Id);
    Quote q = buildQuote(opp.Id);
    insert q;

    opp.SyncedQuoteId = q.Id;
    update opp;
    Quote synced = [SELECT Id, IsSyncing, Status FROM Quote WHERE Id = :q.Id];
    synced.Status = 'Accepted';
    update synced;
    System.assertEquals(
      true,
      [SELECT Primary_Quote_Accepted__c FROM Opportunity WHERE Id = :opp.Id]
      .Primary_Quote_Accepted__c,
      'Acceptance should stamp the Opportunity first.'
    );

    Test.startTest();
    synced.Status = 'Draft'; // withdraw the acceptance
    update synced;
    Test.stopTest();

    System.assertEquals(
      false,
      [SELECT Primary_Quote_Accepted__c FROM Opportunity WHERE Id = :opp.Id]
      .Primary_Quote_Accepted__c,
      'Leaving Accepted must clear the Opportunity acceptance flag.'
    );
  }

  @IsTest
  static void insertWithLegalTermsEscalatesApproval() {
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    q.Legal_Terms_Required__c = true; // drives escalation with no QLIs
    insert q;

    Quote got = [SELECT Approval_Status__c FROM Quote WHERE Id = :q.Id];
    System.assertEquals(
      'Pending',
      got.Approval_Status__c,
      'Legal terms required must escalate approval on insert.'
    );
  }

  @IsTest
  static void escalationDoesNotOverrideApprovedDecision() {
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    // A recorded decision lives on the per-dimension field now, not the rollup.
    q.Discount_Approval_Status__c = 'Approved';
    insert q;

    PricebookEntry pbe = seedPricebookEntry();
    insert new QuoteLineItem(
      QuoteId = q.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Discount = 50 // well over threshold — keeps the discount dimension active
    );

    q.Validity_Period_Days__c = 45;
    update q;

    Quote got = [
      SELECT Discount_Approval_Status__c, Approval_Status__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals(
      'Approved',
      got.Discount_Approval_Status__c,
      'Escalation must never clobber an Approved/Rejected dimension decision.'
    );
    System.assertEquals(
      'Approved',
      got.Approval_Status__c,
      'The rollup reflects the approved discount dimension.'
    );
  }

  @IsTest
  static void insertClearsCallerSuppliedDiscountRollup() {
    // Total_Discount_Percent__c is a trigger-maintained rollup. A brand-new
    // Quote can't have line items, so a caller-supplied value must be cleared
    // and must NOT drive approval escalation in the same pass.
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    q.Total_Discount_Percent__c = 50; // stale/manual input, over threshold
    q.Legal_Terms_Required__c = false;
    insert q;

    Quote got = [
      SELECT Total_Discount_Percent__c, Approval_Status__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals(
      null,
      got.Total_Discount_Percent__c,
      'A caller-supplied rollup must be cleared on insert.'
    );
    System.assertEquals(
      'Not Required',
      got.Approval_Status__c,
      'A stale supplied discount must not escalate a new quote.'
    );
  }

  @IsTest
  static void loweringDiscountResetsPendingApproval() {
    // A trigger-set Pending must reset to Not Required once the blended
    // discount drops back below the threshold.
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    insert q;

    PricebookEntry pbe = seedPricebookEntry();
    QuoteLineItem qli = new QuoteLineItem(
      QuoteId = q.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Discount = 50 // over threshold
    );
    insert qli;

    q.Validity_Period_Days__c = 45;
    update q;
    System.assertEquals(
      'Pending',
      [SELECT Approval_Status__c FROM Quote WHERE Id = :q.Id]
      .Approval_Status__c,
      'Quote should have escalated first.'
    );

    // Lower the line discount, then re-save the quote.
    qli.Discount = 5;
    update qli;
    q.Validity_Period_Days__c = 60;
    update q;

    Quote got = [
      SELECT Total_Discount_Percent__c, Approval_Status__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals(5, got.Total_Discount_Percent__c);
    System.assertEquals(
      'Not Required',
      got.Approval_Status__c,
      'Lowering the discount below threshold must release the Pending status.'
    );
  }

  // -------------------------------------------------------------------------
  // Behavior 3 — Accepted-quote sync back to Opportunity
  // -------------------------------------------------------------------------

  @IsTest
  static void acceptedSyncingQuotePropagatesToOpportunity() {
    Account acct = seedAccount();
    Opportunity opp = seedOpp(acct.Id);
    Quote q = buildQuote(opp.Id);
    insert q;

    // Start the sync the system-supported way.
    opp.SyncedQuoteId = q.Id;
    update opp;

    Quote synced = [
      SELECT Id, IsSyncing, Status
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals(true, synced.IsSyncing, 'Quote should be syncing.');

    Test.startTest();
    synced.Status = 'Accepted';
    update synced;
    Test.stopTest();

    Opportunity got = [
      SELECT
        Primary_Quote_Accepted__c,
        Implementation_Package__c,
        Billing_Frequency__c,
        Subscription_Term_Months__c,
        Support_Tier__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(true, got.Primary_Quote_Accepted__c);
    System.assertEquals('Enterprise', got.Implementation_Package__c);
    System.assertEquals('Monthly', got.Billing_Frequency__c);
    System.assertEquals('24 Months', got.Subscription_Term_Months__c);
    System.assertEquals(
      'Premium Enterprise',
      got.Support_Tier__c,
      'Quote.Premium_Support_Tier__c must map onto Opportunity.Support_Tier__c.'
    );
  }

  @IsTest
  static void acceptedNotSyncingDoesNotPropagate() {
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    insert q;

    // No sync started — IsSyncing stays false.
    q.Status = 'Accepted';
    update q;

    Opportunity got = [
      SELECT Primary_Quote_Accepted__c, Support_Tier__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(
      false,
      got.Primary_Quote_Accepted__c,
      'A non-syncing accepted quote must not stamp the Opportunity.'
    );
    System.assertEquals('Standard', got.Support_Tier__c);
  }

  @IsTest
  static void resaveOfAcceptedSyncingQuoteDoesNotRefire() {
    Account acct = seedAccount();
    Opportunity opp = seedOpp(acct.Id);
    Quote q = buildQuote(opp.Id);
    insert q;

    opp.SyncedQuoteId = q.Id;
    update opp;
    Quote synced = [SELECT Id, IsSyncing, Status FROM Quote WHERE Id = :q.Id];
    synced.Status = 'Accepted';
    update synced; // first acceptance — propagates

    // Manually clear the stamp, then re-save the already-accepted quote.
    Opportunity reset = new Opportunity(
      Id = opp.Id,
      Primary_Quote_Accepted__c = false
    );
    update reset;

    synced.Validity_Period_Days__c = 60; // an unrelated edit, still Accepted
    update synced;

    Opportunity got = [
      SELECT Primary_Quote_Accepted__c
      FROM Opportunity
      WHERE Id = :opp.Id
    ];
    System.assertEquals(
      false,
      got.Primary_Quote_Accepted__c,
      'Re-saving an already-accepted quote must not re-propagate.'
    );
  }

  // -------------------------------------------------------------------------
  // Framework integration — bulk, bypass, overflow
  // -------------------------------------------------------------------------

  @IsTest
  static void bulkInsertStaysGovernorSafe() {
    Opportunity opp = seedOpp(seedAccount().Id);
    List<Quote> quotes = TestDataFactory.buildQuotes(200);
    for (Quote q : quotes) {
      q.OpportunityId = opp.Id;
      q.Legal_Terms_Required__c = true; // every quote should escalate
    }

    Test.startTest();
    insert quotes;
    Test.stopTest();

    Integer pending = [
      SELECT COUNT()
      FROM Quote
      WHERE Id IN :quotes AND Approval_Status__c = 'Pending'
    ];
    System.assertEquals(200, pending, 'All 200 quotes should escalate.');
  }

  @IsTest
  static void bypassedHandlerSkipsAllBehaviors() {
    TriggerHandler.bypass('QuoteTriggerHandler');
    try {
      Opportunity opp = seedOpp(seedAccount().Id);
      Quote q = buildQuote(opp.Id);
      q.Legal_Terms_Required__c = true;
      insert q;

      Quote got = [SELECT Approval_Status__c FROM Quote WHERE Id = :q.Id];
      System.assertEquals(
        'Not Required',
        got.Approval_Status__c,
        'A bypassed handler must not escalate.'
      );
    } finally {
      TriggerHandler.clearBypass('QuoteTriggerHandler');
    }
  }

  @IsTest
  static void discountCalcOverflowRollsBackUpdate() {
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    insert q;

    PricebookEntry pbe = seedPricebookEntry();
    insert new List<QuoteLineItem>{
      new QuoteLineItem(
        QuoteId = q.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Discount = 10
      ),
      new QuoteLineItem(
        QuoteId = q.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Discount = 10
      ),
      new QuoteLineItem(
        QuoteId = q.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Discount = 10
      )
    };

    QuoteTriggerHandler.QLI_ROW_CAP = 2; // 3 QLIs now overflow
    Exception caught;
    try {
      q.Validity_Period_Days__c = 99;
      update q;
    } catch (Exception e) {
      caught = e;
    } finally {
      QuoteTriggerHandler.QLI_ROW_CAP = 45000;
    }

    System.assertNotEquals(
      null,
      caught,
      'Overflow must surface as an exception via addError.'
    );
    System.assert(
      caught.getMessage().contains('Split this change into smaller batches'),
      'Error message should be actionable: ' + caught.getMessage()
    );

    Quote got = [SELECT Validity_Period_Days__c FROM Quote WHERE Id = :q.Id];
    System.assertEquals(
      30,
      got.Validity_Period_Days__c,
      'The update must have rolled back (factory default 30 unchanged).'
    );
  }

  // -------------------------------------------------------------------------
  // Helper unit coverage (no DML)
  // -------------------------------------------------------------------------

  @IsTest
  static void lineListAmountHandlesNullsAndProduct() {
    System.assertEquals(
      200,
      QuoteTriggerHandler.lineListAmount(
        new QuoteLineItem(UnitPrice = 100, Quantity = 2)
      )
    );
    System.assertEquals(
      null,
      QuoteTriggerHandler.lineListAmount(new QuoteLineItem(Quantity = 2))
    );
    System.assertEquals(
      null,
      QuoteTriggerHandler.lineListAmount(new QuoteLineItem(UnitPrice = 100))
    );
  }

  @IsTest
  static void isAcceptedSyncingCoversBranches() {
    System.assertEquals(false, QuoteTriggerHandler.isAcceptedSyncing(null));
    // Quote.IsSyncing is system-controlled and not writeable via the
    // constructor, so synthesise the read-only field with JSON.deserialize.
    System.assertEquals(
      false,
      QuoteTriggerHandler.isAcceptedSyncing(quoteWith(false, 'Accepted'))
    );
    System.assertEquals(
      false,
      QuoteTriggerHandler.isAcceptedSyncing(quoteWith(true, 'Draft'))
    );
    System.assertEquals(
      true,
      QuoteTriggerHandler.isAcceptedSyncing(quoteWith(true, 'Accepted'))
    );
  }

  private static Quote quoteWith(Boolean isSyncing, String status) {
    return (Quote) JSON.deserialize(
      '{"IsSyncing":' + isSyncing + ',"Status":"' + status + '"}',
      Quote.class
    );
  }

  @IsTest
  static void escalateApprovalCoversBranches() {
    // No trigger — escalateApproval is a pure static. Each dimension is now
    // stamped independently and rolled up into Approval_Status__c.

    // Nothing required → every dimension Not Required, rollup Not Required.
    Quote noneRequired = new Quote(
      Total_Discount_Percent__c = 5,
      Legal_Terms_Required__c = false,
      Discount_Approval_Status__c = 'Not Required',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Not Required'
    );
    QuoteTriggerHandler.escalateApproval(noneRequired);
    System.assertEquals(
      'Not Required',
      noneRequired.Discount_Approval_Status__c
    );
    System.assertEquals('Not Required', noneRequired.Approval_Status__c);

    // Discount over threshold escalates ONLY the discount dimension.
    Quote overThreshold = new Quote(
      Total_Discount_Percent__c = 40,
      Legal_Terms_Required__c = false,
      Discount_Approval_Status__c = 'Not Required',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Not Required'
    );
    QuoteTriggerHandler.escalateApproval(overThreshold);
    System.assertEquals('Pending', overThreshold.Discount_Approval_Status__c);
    System.assertEquals('Not Required', overThreshold.Legal_Approval_Status__c);
    System.assertEquals('Pending', overThreshold.Approval_Status__c);

    // Legal required from a null dimension escalates the legal dimension.
    Quote nullLegal = new Quote(
      Legal_Terms_Required__c = true,
      Legal_Approval_Status__c = null
    );
    QuoteTriggerHandler.escalateApproval(nullLegal);
    System.assertEquals('Pending', nullLegal.Legal_Approval_Status__c);
    System.assertEquals('Pending', nullLegal.Approval_Status__c);

    // A recorded Rejected decision on one dimension is never clobbered, even
    // while that dimension is still required; the rollup reflects Rejected.
    Quote rejectedDiscount = new Quote(
      Total_Discount_Percent__c = 40,
      Legal_Terms_Required__c = true,
      Discount_Approval_Status__c = 'Rejected',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Not Required'
    );
    QuoteTriggerHandler.escalateApproval(rejectedDiscount);
    System.assertEquals(
      'Rejected',
      rejectedDiscount.Discount_Approval_Status__c
    );
    System.assertEquals('Pending', rejectedDiscount.Legal_Approval_Status__c);
    System.assertEquals('Rejected', rejectedDiscount.Approval_Status__c);

    // Criteria cleared: a trigger-set Pending releases to Not Required.
    Quote stalePending = new Quote(
      Total_Discount_Percent__c = 5,
      Legal_Terms_Required__c = false,
      Discount_Approval_Status__c = 'Pending',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Not Required'
    );
    QuoteTriggerHandler.escalateApproval(stalePending);
    System.assertEquals(
      'Not Required',
      stalePending.Discount_Approval_Status__c,
      'A trigger-set Pending must reset when its criterion clears.'
    );

    // A recorded Approved decision is CLEARED once its criterion no longer
    // holds, so re-adding the requirement later forces a fresh review.
    Quote approvedNoCriteria = new Quote(
      Total_Discount_Percent__c = 5,
      Legal_Terms_Required__c = false,
      Discount_Approval_Status__c = 'Approved',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Not Required'
    );
    QuoteTriggerHandler.escalateApproval(approvedNoCriteria);
    System.assertEquals(
      'Not Required',
      approvedNoCriteria.Discount_Approval_Status__c,
      'A stale Approved must clear once its criterion no longer holds.'
    );
    System.assertEquals('Not Required', approvedNoCriteria.Approval_Status__c);

    // rollupApproval precedence: Rejected > Pending > Approved > Not Required.
    System.assertEquals(
      'Rejected',
      QuoteTriggerHandler.rollupApproval('Approved', 'Pending', 'Rejected')
    );
    System.assertEquals(
      'Pending',
      QuoteTriggerHandler.rollupApproval('Approved', 'Pending', 'Not Required')
    );
    System.assertEquals(
      'Approved',
      QuoteTriggerHandler.rollupApproval('Approved', 'Not Required', null)
    );
  }

  @IsTest
  static void reopensWorsenedApprovalsAndClearsResolvedDimensions() {
    // Signature: escalateApproval(q, segment, prior, servicesBelowFloor).
    // Worsening is derived from q-vs-prior inside the method.

    // An Approved discount re-opens to Pending when the blend WORSENS.
    Quote worseDiscount = new Quote(
      Total_Discount_Percent__c = 50,
      Discount_Approval_Status__c = 'Approved',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Not Required'
    );
    Quote priorDiscount = new Quote(Total_Discount_Percent__c = 16);
    QuoteTriggerHandler.escalateApproval(
      worseDiscount,
      null,
      priorDiscount,
      false
    );
    System.assertEquals(
      'Pending',
      worseDiscount.Discount_Approval_Status__c,
      'A worsened blended discount must re-open an Approved discount.'
    );

    // An Approved finance dimension re-opens when the Services pricing deepens.
    Quote worseFinance = new Quote(
      Total_Discount_Percent__c = 5,
      Worst_Services_Line_Discount__c = 90,
      Discount_Approval_Status__c = 'Not Required',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Approved'
    );
    Quote priorFinance = new Quote(Worst_Services_Line_Discount__c = 25);
    QuoteTriggerHandler.escalateApproval(
      worseFinance,
      null,
      priorFinance,
      true
    );
    System.assertEquals(
      'Pending',
      worseFinance.Finance_Approval_Status__c,
      'A deepened Services discount must re-open an Approved finance review.'
    );

    // Migration window: a pre-existing finance-approved quote has a NULL
    // baseline, so the first below-floor edit must still re-open.
    Quote nullBaseline = new Quote(
      Total_Discount_Percent__c = 5,
      Worst_Services_Line_Discount__c = 90,
      Discount_Approval_Status__c = 'Not Required',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Approved'
    );
    Quote priorNullBaseline = new Quote(); // Worst_Services_Line_Discount__c null
    QuoteTriggerHandler.escalateApproval(
      nullBaseline,
      null,
      priorNullBaseline,
      true
    );
    System.assertEquals(
      'Pending',
      nullBaseline.Finance_Approval_Status__c,
      'A null prior baseline with a below-floor Services discount must re-open ' +
      'an Approved finance review (migration window).'
    );

    // An Approved legal dimension re-opens when the legal inputs change (here,
    // a new non-standard discount reason) while still required.
    Quote worseLegal = new Quote(
      Legal_Terms_Required__c = true,
      Discount_Reason__c = 'Competitive Replacement',
      Discount_Approval_Status__c = 'Not Required',
      Legal_Approval_Status__c = 'Approved',
      Finance_Approval_Status__c = 'Not Required'
    );
    Quote priorLegal = new Quote(
      Legal_Terms_Required__c = true,
      Discount_Reason__c = 'Volume Commit'
    );
    QuoteTriggerHandler.escalateApproval(worseLegal, null, priorLegal, false);
    System.assertEquals(
      'Pending',
      worseLegal.Legal_Approval_Status__c,
      'Changing the legal inputs must re-open an Approved legal review.'
    );

    // No worsening → recorded Approvals are preserved while still required.
    Quote steady = new Quote(
      Total_Discount_Percent__c = 16,
      Worst_Services_Line_Discount__c = 25,
      Discount_Approval_Status__c = 'Approved',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Approved'
    );
    Quote priorSteady = new Quote(
      Total_Discount_Percent__c = 16,
      Worst_Services_Line_Discount__c = 25
    );
    QuoteTriggerHandler.escalateApproval(steady, null, priorSteady, true);
    System.assertEquals('Approved', steady.Discount_Approval_Status__c);
    System.assertEquals('Approved', steady.Finance_Approval_Status__c);

    // A Rejected dimension whose criterion no longer holds clears to Not
    // Required, so a corrected quote isn't stuck blocked.
    Quote fixedReject = new Quote(
      Total_Discount_Percent__c = 5, // back below threshold
      Discount_Approval_Status__c = 'Rejected',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Not Required'
    );
    QuoteTriggerHandler.escalateApproval(fixedReject, null, null, false);
    System.assertEquals(
      'Not Required',
      fixedReject.Discount_Approval_Status__c,
      'A Rejected dimension must clear once its criterion no longer holds.'
    );

    // An APPROVED dimension whose criterion is removed also clears to Not
    // Required, so re-adding the requirement forces a fresh review.
    Quote staleApproved = new Quote(
      Total_Discount_Percent__c = 5,
      Discount_Approval_Status__c = 'Not Required',
      Legal_Approval_Status__c = 'Approved', // approved, but terms now off
      Legal_Terms_Required__c = false,
      Finance_Approval_Status__c = 'Not Required'
    );
    QuoteTriggerHandler.escalateApproval(staleApproved, null, null, false);
    System.assertEquals(
      'Not Required',
      staleApproved.Legal_Approval_Status__c,
      'A stale Approved must clear when its criterion is removed.'
    );

    // ...but a Rejected dimension that is STILL required stays Rejected.
    Quote stillRejected = new Quote(
      Total_Discount_Percent__c = 40,
      Discount_Approval_Status__c = 'Rejected',
      Legal_Approval_Status__c = 'Not Required',
      Finance_Approval_Status__c = 'Not Required'
    );
    QuoteTriggerHandler.escalateApproval(stillRejected, null, null, false);
    System.assertEquals(
      'Rejected',
      stillRejected.Discount_Approval_Status__c,
      'A still-required Rejected dimension must stay Rejected.'
    );
  }

  @IsTest
  static void lineEditAddingApprovalToAcceptedQuoteIsBlocked() {
    // after a clean Quote is Accepted, adding over-threshold pricing makes
    // the discount dimension Pending via the QuoteLineItem trigger, and the
    // (un-Status-guarded) VR blocks the line edit rather than leaving an
    // Accepted quote with un-approved pricing.
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    insert q; // no QLIs, no legal terms → all dimensions Not Required

    opp.SyncedQuoteId = q.Id;
    update opp;
    Quote synced = [SELECT Id, Status FROM Quote WHERE Id = :q.Id];
    synced.Status = 'Accepted';
    update synced; // clean quote accepts fine

    PricebookEntry pbe = seedPricebookEntry();
    Boolean blocked = false;
    try {
      insert new QuoteLineItem(
        QuoteId = q.Id,
        PricebookEntryId = pbe.Id,
        Quantity = 1,
        UnitPrice = 100,
        Discount = 50 // over threshold → discount approval required
      );
    } catch (DmlException e) {
      blocked = true;
      System.assert(
        e.getMessage().toLowerCase().contains('discount') ||
        e.getMessage().toLowerCase().contains('approv'),
        'Expected the discount approval rule to block; got: ' + e.getMessage()
      );
    }
    System.assert(
      blocked,
      'Adding approval-required pricing to an Accepted quote must be blocked.'
    );
  }

  @IsTest
  static void nonStandardDiscountReasonEscalatesLegal() {
    // Legal_Terms_Required is false, but a non-standard discount reason still
    // needs Legal review per DealDeskService.requiresLegalReview — the legal
    // dimension must escalate so the quote can't be Accepted without Legal
    // sign-off.
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    q.Legal_Terms_Required__c = false;
    q.Discount_Reason__c = 'Competitive Replacement'; // non-standard
    insert q;

    Quote got = [
      SELECT Legal_Approval_Status__c, Approval_Status__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals(
      'Pending',
      got.Legal_Approval_Status__c,
      'A non-standard discount reason must escalate the legal dimension even ' +
      'when Legal_Terms_Required__c is false.'
    );
  }

  @IsTest
  static void smbSegmentEscalatesDiscountBelowDefaultThreshold() {
    // SMB's discount threshold is 10% (vs the default 15%), sourced from the
    // Account segment via DealDeskService — so a 12% blended discount on an SMB
    // account escalates even though it's under the default.
    Account smb = new Account(
      Name = 'NS SMB Acct',
      Region__c = 'NA East',
      Customer_Segment__c = 'SMB'
    );
    insert smb;
    Opportunity opp = seedOpp(smb.Id);
    Quote q = buildQuote(opp.Id);
    insert q;

    PricebookEntry pbe = seedPricebookEntry();
    insert new QuoteLineItem(
      QuoteId = q.Id,
      PricebookEntryId = pbe.Id,
      Quantity = 1,
      UnitPrice = 100,
      Discount = 12 // > SMB 10%, < default 15%
    );

    Quote got = [
      SELECT Total_Discount_Percent__c, Discount_Approval_Status__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals(12, got.Total_Discount_Percent__c);
    System.assertEquals(
      'Pending',
      got.Discount_Approval_Status__c,
      'A 12% discount on an SMB account (threshold 10%) must escalate the ' +
      'discount dimension even though it is under the default 15%.'
    );
  }

  @IsTest
  static void blankApproverFallsBackToOwnerManager() {
    // A quote that needs approval with a blank Deal_Desk_Approver__c falls back
    // to the owner's manager so the approval steps can resolve.
    User owner = createOwnerWithManager();
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    q.OwnerId = owner.Id;
    q.Legal_Terms_Required__c = true; // needs legal approval, no QLIs needed
    q.Deal_Desk_Approver__c = null;
    insert q;

    Quote got = [
      SELECT Approval_Status__c, Deal_Desk_Approver__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals('Pending', got.Approval_Status__c);
    System.assertEquals(
      owner.ManagerId,
      got.Deal_Desk_Approver__c,
      'A blank approver on an approval-required quote must fall back to the ' +
      'owner manager.'
    );
  }

  @IsTest
  static void blankApproverNotFilledWhenNoApprovalNeeded() {
    // No approval required → the fallback must NOT stamp an approver.
    User owner = createOwnerWithManager();
    Opportunity opp = seedOpp(seedAccount().Id);
    Quote q = buildQuote(opp.Id);
    q.OwnerId = owner.Id;
    q.Legal_Terms_Required__c = false;
    q.Deal_Desk_Approver__c = null;
    insert q;

    Quote got = [
      SELECT Approval_Status__c, Deal_Desk_Approver__c
      FROM Quote
      WHERE Id = :q.Id
    ];
    System.assertEquals('Not Required', got.Approval_Status__c);
    System.assertEquals(
      null,
      got.Deal_Desk_Approver__c,
      'A quote needing no approval must not get a fallback approver.'
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /**
   * Returns a persisted owner User whose ManagerId is set, with the User DML
   * isolated inside System.runAs so it doesn't trip MIXED_DML against the
   * non-setup DML the tests do afterward. Uses the running user's profile so
   * the created users have the field/object access the trigger needs.
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
      Username = 'ns.mgr.' + uniq + '@example.com.invalid',
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
      Username = 'ns.owner.' + uniq + '@example.com.invalid',
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

  private static Account seedAccount() {
    Account a = new Account(
      Name = 'NS Quote Test Acct',
      Region__c = 'NA East',
      Customer_Segment__c = 'Commercial'
    );
    insert a;
    return a;
  }

  private static Opportunity seedOpp(Id accountId) {
    // The standard pricebook is inactive in test context; quote sync
    // requires an ACTIVE pricebook shared by the opp and quote, so
    // activate it before linking.
    update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
    Opportunity o = TestDataFactory.buildOpportunities(1)[0];
    o.AccountId = accountId;
    o.StageName = 'Qualify';
    // Standard pricebook so a Quote can sync to this opp.
    o.Pricebook2Id = Test.getStandardPricebookId();
    insert o;
    return o;
  }

  /**
   * Unsaved Quote on the standard pricebook, with the four propagated
   * commercial fields set to values distinct from the opp factory defaults
   * (Quickstart / Annual / Standard / 12 Months) so a propagation assertion
   * actually proves the copy happened.
   */
  private static Quote buildQuote(Id oppId) {
    Quote q = TestDataFactory.buildQuotes(1)[0];
    q.OpportunityId = oppId;
    q.Pricebook2Id = Test.getStandardPricebookId();
    q.Implementation_Package__c = 'Enterprise';
    q.Billing_Frequency__c = 'Monthly';
    q.Premium_Support_Tier__c = 'Premium Enterprise';
    q.Subscription_Term_Months__c = '24 Months';
    return q;
  }

  private static PricebookEntry seedPricebookEntry() {
    Product2 p = new Product2(
      Name = 'QLI Test Product',
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
