/**
 * RevenueCalculationServiceTest — pure-function service, no DML / SOQL
 * needed. Tests run in-memory.
 *
 * Service now takes a `Map<Id, List<OpportunityLineItem>>` second argument
 * for the recurring-vs-one-time split. The single-argument overload
 * (Amount fallback) is preserved for callers that don't have OLIs (e.g.
 * beforeInsert).
 */
@IsTest
private class RevenueCalculationServiceTest {
  // -------------------------------------------------------------------------
  // Amount fallback path (no OLIs map)
  // -------------------------------------------------------------------------

  @IsTest
  static void amountFallbackStampsArrAndAcvForOneYear() {
    Opportunity opp = buildOpp(12000, '12 Months');
    RevenueCalculationService.recalculate(new List<Opportunity>{ opp });

    System.assertEquals(12000, opp.ARR__c);
    System.assertEquals(12000, opp.ACV__c);
  }

  @IsTest
  static void amountFallbackProratesMultiYearToTwelveMonthBase() {
    Opportunity twoYr = buildOpp(24000, '24 Months');
    Opportunity threeYr = buildOpp(36000, '36 Months');
    RevenueCalculationService.recalculate(
      new List<Opportunity>{ twoYr, threeYr }
    );

    System.assertEquals(12000, twoYr.ARR__c);
    System.assertEquals(12000, threeYr.ARR__c);
  }

  @IsTest
  static void amountFallbackLeavesFieldsNullWhenAmountMissing() {
    Opportunity opp = buildOpp(null, '12 Months');
    RevenueCalculationService.recalculate(new List<Opportunity>{ opp });

    System.assertEquals(null, opp.ARR__c);
    System.assertEquals(null, opp.ACV__c);
  }

  @IsTest
  static void amountFallbackLeavesFieldsNullWhenTermMissing() {
    Opportunity opp = buildOpp(10000, null);
    RevenueCalculationService.recalculate(new List<Opportunity>{ opp });

    System.assertEquals(null, opp.ARR__c);
    System.assertEquals(null, opp.ACV__c);
  }

  @IsTest
  static void recalculateHandlesNullAndEmptyLists() {
    RevenueCalculationService.recalculate(null);
    RevenueCalculationService.recalculate(new List<Opportunity>{});
    RevenueCalculationService.recalculate(
      null,
      new Map<Id, List<OpportunityLineItem>>()
    );
  }

  // -------------------------------------------------------------------------
  // OLI-based path — the canonical contract per field descriptions
  // -------------------------------------------------------------------------

  @IsTest
  static void oliPathSumsRecurringOnly() {
    // Opp has $100 recurring (subscription) + $50 one-time (services).
    // Term is 12 months → ARR = 100 (the recurring annualised),
    // ACV = ARR + (50 prorated to 12 months from 12 months) = 100 + 50 = 150.
    Id fakeOppId = fakeId(Opportunity.SObjectType, 1);
    Opportunity opp = buildOpp(fakeOppId, 999, '12 Months');

    Map<Id, List<OpportunityLineItem>> olisByOpp = new Map<Id, List<OpportunityLineItem>>{
      fakeOppId => new List<OpportunityLineItem>{
        oli('Subscription', 100),
        oli('Services', 50)
      }
    };
    RevenueCalculationService.recalculate(
      new List<Opportunity>{ opp },
      olisByOpp
    );

    System.assertEquals(
      100,
      opp.ARR__c,
      'ARR should sum recurring OLIs only, not Amount=999.'
    );
    System.assertEquals(
      150,
      opp.ACV__c,
      'ACV should be ARR + prorated one-time.'
    );
  }

  @IsTest
  static void oliPathSumsUsageAsRecurring() {
    Id fakeOppId = fakeId(Opportunity.SObjectType, 2);
    Opportunity opp = buildOpp(fakeOppId, null, '12 Months');

    Map<Id, List<OpportunityLineItem>> olisByOpp = new Map<Id, List<OpportunityLineItem>>{
      fakeOppId => new List<OpportunityLineItem>{
        oli('Subscription', 200),
        oli('Usage', 100)
      }
    };
    RevenueCalculationService.recalculate(
      new List<Opportunity>{ opp },
      olisByOpp
    );

    System.assertEquals(300, opp.ARR__c);
    System.assertEquals(300, opp.ACV__c);
  }

  @IsTest
  static void oliPathProratesOneTimeOverMultiYearTerm() {
    // 36-month deal with $600 recurring sub + $300 one-time.
    // ARR = 600 × 12 / 36 = 200.
    // ACV one-time component = 300 × 12 / 36 = 100.
    // ACV = ARR + 100 = 300.
    Id fakeOppId = fakeId(Opportunity.SObjectType, 3);
    Opportunity opp = buildOpp(fakeOppId, null, '36 Months');

    Map<Id, List<OpportunityLineItem>> olisByOpp = new Map<Id, List<OpportunityLineItem>>{
      fakeOppId => new List<OpportunityLineItem>{
        oli('Subscription', 600),
        oli('One-Time', 300)
      }
    };
    RevenueCalculationService.recalculate(
      new List<Opportunity>{ opp },
      olisByOpp
    );

    System.assertEquals(200, opp.ARR__c);
    System.assertEquals(300, opp.ACV__c);
  }

  @IsTest
  static void oliPathIgnoresOLIsWithUnknownRevenueType() {
    // Defensively: a Revenue_Type__c value outside the recurring/one-time
    // classification is dropped rather than miscategorised.
    Id fakeOppId = fakeId(Opportunity.SObjectType, 4);
    Opportunity opp = buildOpp(fakeOppId, null, '12 Months');

    Map<Id, List<OpportunityLineItem>> olisByOpp = new Map<Id, List<OpportunityLineItem>>{
      fakeOppId => new List<OpportunityLineItem>{
        oli('Subscription', 100),
        oli('SomeFutureType', 999)
      }
    };
    RevenueCalculationService.recalculate(
      new List<Opportunity>{ opp },
      olisByOpp
    );

    System.assertEquals(100, opp.ARR__c);
    System.assertEquals(100, opp.ACV__c);
  }

  @IsTest
  static void oliMapMissingOppFallsBackToAmount() {
    // The olisByOppId map is provided but contains no entry for this opp
    // (e.g. a brand-new opportunity with no products yet). Fall back to
    // Amount-based — same path as a null map.
    Id fakeOppId = fakeId(Opportunity.SObjectType, 5);
    Opportunity opp = buildOpp(fakeOppId, 12000, '12 Months');

    RevenueCalculationService.recalculate(
      new List<Opportunity>{ opp },
      new Map<Id, List<OpportunityLineItem>>()
    );

    System.assertEquals(12000, opp.ARR__c);
    System.assertEquals(12000, opp.ACV__c);
  }

  @IsTest
  static void recalculateIsBulkSafe() {
    Map<Id, List<OpportunityLineItem>> olisByOpp = new Map<Id, List<OpportunityLineItem>>();
    List<Opportunity> opps = new List<Opportunity>();
    for (Integer i = 0; i < 200; i++) {
      Id fakeOppId = fakeId(Opportunity.SObjectType, i + 100);
      opps.add(buildOpp(fakeOppId, null, '12 Months'));
      olisByOpp.put(
        fakeOppId,
        new List<OpportunityLineItem>{
          oli('Subscription', 100 + i),
          oli('One-Time', 10)
        }
      );
    }

    Test.startTest();
    RevenueCalculationService.recalculate(opps, olisByOpp);
    Test.stopTest();

    for (Integer i = 0; i < 200; i++) {
      System.assertEquals(100 + i, opps[i].ARR__c);
      System.assertEquals(100 + i + 10, opps[i].ACV__c);
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private static Opportunity buildOpp(Decimal amount, String term) {
    return new Opportunity(
      Name = 'test-opp',
      StageName = 'Qualify',
      CloseDate = Date.today(),
      Amount = amount,
      Subscription_Term_Months__c = term
    );
  }

  private static Opportunity buildOpp(Id id, Decimal amount, String term) {
    Opportunity o = buildOpp(amount, term);
    o.Id = id;
    return o;
  }

  private static OpportunityLineItem oli(String revenueType, Decimal total) {
    // Build an OLI with TotalPrice set directly. In real persisted records
    // TotalPrice is calculated from UnitPrice × Quantity, but for in-memory
    // unit tests we can set it explicitly.
    return new OpportunityLineItem(
      Revenue_Type__c = revenueType,
      Quantity = 1,
      UnitPrice = total,
      TotalPrice = total
    );
  }

  /**
   * Generate a deterministic fake SObject Id for unit-test purposes — no
   * DML, no Database.insert. Pattern stolen from
   * https://salesforce.stackexchange.com/q/21137 — adjusted slightly.
   */
  private static Id fakeId(Schema.SObjectType t, Integer counter) {
    String prefix = t.getDescribe().getKeyPrefix();
    String pad = String.valueOf(counter).leftPad(12, '0');
    return (Id) (prefix + pad);
  }
}
