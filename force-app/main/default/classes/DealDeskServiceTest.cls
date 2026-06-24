/**
 * DealDeskServiceTest — covers each threshold/review branch and the
 * invocable. The methods are pure logic over in-memory Quote/QuoteLineItem
 * records, so no DML is needed.
 */
@IsTest
private class DealDeskServiceTest {
  // -------------------------------------------------------------------------
  // requiresDiscountApproval
  // -------------------------------------------------------------------------

  @IsTest
  static void discountApprovalHonoursSegmentThreshold() {
    // Commercial threshold = 15.
    System.assertEquals(
      true,
      DealDeskService.requiresDiscountApproval(
        20,
        'Commercial',
        'Volume Commit'
      )
    );
    System.assertEquals(
      false,
      DealDeskService.requiresDiscountApproval(
        10,
        'Commercial',
        'Volume Commit'
      )
    );
    // Enterprise threshold = 20 — 18 is under, 22 is over.
    System.assertEquals(
      false,
      DealDeskService.requiresDiscountApproval(
        18,
        'Enterprise',
        'Volume Commit'
      )
    );
    System.assertEquals(
      true,
      DealDeskService.requiresDiscountApproval(
        22,
        'Enterprise',
        'Volume Commit'
      )
    );
  }

  @IsTest
  static void unknownSegmentUsesDefaultThreshold() {
    // Default = 15.
    System.assertEquals(
      true,
      DealDeskService.requiresDiscountApproval(16, 'Mystery', 'Volume Commit')
    );
    System.assertEquals(
      false,
      DealDeskService.requiresDiscountApproval(14, 'Mystery', 'Volume Commit')
    );
  }

  @IsTest
  static void nonStandardReasonAlwaysEscalates() {
    // Below the Enterprise threshold, but RFP Floor forces approval.
    System.assertEquals(
      true,
      DealDeskService.requiresDiscountApproval(5, 'Enterprise', 'RFP Floor')
    );
  }

  @IsTest
  static void zeroOrNullDiscountNeverEscalates() {
    System.assertEquals(
      false,
      DealDeskService.requiresDiscountApproval(0, 'SMB', 'RFP Floor')
    );
    System.assertEquals(
      false,
      DealDeskService.requiresDiscountApproval(null, 'SMB', 'Volume Commit')
    );
  }

  // -------------------------------------------------------------------------
  // requiresLegalReview
  // -------------------------------------------------------------------------

  @IsTest
  static void legalReviewFromFlagOrReason() {
    System.assertEquals(
      true,
      DealDeskService.requiresLegalReview(
        new Quote(
          Legal_Terms_Required__c = true,
          Discount_Reason__c = 'Volume Commit'
        )
      ),
      'Legal_Terms_Required__c drives legal review.'
    );
    System.assertEquals(
      true,
      DealDeskService.requiresLegalReview(
        new Quote(
          Legal_Terms_Required__c = false,
          Discount_Reason__c = 'Competitive Replacement'
        )
      ),
      'A non-standard discount reason drives legal review.'
    );
    System.assertEquals(
      false,
      DealDeskService.requiresLegalReview(
        new Quote(
          Legal_Terms_Required__c = false,
          Discount_Reason__c = 'Volume Commit'
        )
      )
    );
    System.assertEquals(false, DealDeskService.requiresLegalReview(null));
  }

  // -------------------------------------------------------------------------
  // requiresFinanceReview
  // -------------------------------------------------------------------------

  @IsTest
  static void financeReviewWhenServicesBelowFloor() {
    // Services line discounted 30 (> 20 floor) → finance review.
    System.assertEquals(
      true,
      DealDeskService.requiresFinanceReview(
        new Quote(),
        new List<QuoteLineItem>{
          new QuoteLineItem(Revenue_Type__c = 'Services', Discount = 30)
        }
      )
    );
    // Services line discounted only 10 → within floor → no review.
    System.assertEquals(
      false,
      DealDeskService.requiresFinanceReview(
        new Quote(),
        new List<QuoteLineItem>{
          new QuoteLineItem(Revenue_Type__c = 'Services', Discount = 10)
        }
      )
    );
    // A deeply-discounted non-Services line does not trigger finance review.
    System.assertEquals(
      false,
      DealDeskService.requiresFinanceReview(
        new Quote(),
        new List<QuoteLineItem>{
          new QuoteLineItem(Revenue_Type__c = 'Subscription', Discount = 50)
        }
      )
    );
    System.assertEquals(
      false,
      DealDeskService.requiresFinanceReview(new Quote(), null)
    );
  }

  // -------------------------------------------------------------------------
  // Invocable
  // -------------------------------------------------------------------------

  @IsTest
  static void invocableEvaluatesAllThreeGates() {
    DealDeskService.DealDeskRequest req = new DealDeskService.DealDeskRequest();
    req.discountPercent = 25;
    req.segment = 'Commercial';
    req.discountReason = 'Volume Commit';
    req.quote = new Quote(
      Legal_Terms_Required__c = true,
      Discount_Reason__c = 'Volume Commit'
    );
    req.quoteLines = new List<QuoteLineItem>{
      new QuoteLineItem(Revenue_Type__c = 'Services', Discount = 40)
    };

    List<DealDeskService.DealDeskResult> results = DealDeskService.evaluateDealDesk(
      new List<DealDeskService.DealDeskRequest>{ req }
    );

    System.assertEquals(1, results.size());
    System.assertEquals(true, results[0].discountApproval);
    System.assertEquals(true, results[0].legalReview);
    System.assertEquals(true, results[0].financeReview);
  }
}
