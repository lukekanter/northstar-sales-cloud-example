/**
 * RevenueCalculationService — pure-function ARR/ACV math for Opportunity.
 *
 * Stateless. No SOQL. No DML. Accepts a list of Opportunity records plus a
 * pre-fetched map of their OpportunityLineItems (by parent OppId) and
 * mutates the opps in place per the field contract documented in
 * Opportunity/fields/ARR__c.field-meta.xml and ACV__c.field-meta.xml:
 *
 *   ARR__c = sum(recurring OLI.TotalPrice) × 12 / Subscription_Term_Months
 *            where Revenue_Type__c IN ('Subscription', 'Usage')
 *
 *   ACV__c = ARR__c + (sum(one-time OLI.TotalPrice) × 12 / term_months)
 *            where Revenue_Type__c IN ('Services', 'One-Time')
 *            (prorated one-time component, per the ACV field description)
 *
 * Fallback: when an opp has no OLIs fetched (`olisByOppId == null` or the
 * map has no entry for the opp's Id — e.g. beforeInsert where the parent
 * Opp doesn't have an Id yet), the service falls back to
 *
 *   ARR__c = Amount × 12 / Subscription_Term_Months
 *   ACV__c = ARR
 *
 * which matches the pre-OLI heuristic. Missing inputs (no term, no
 * Amount, no recognised term label) leave both fields null — a visible
 * data-quality signal downstream (consistent
 * BlankAsBlank choice on TCV).
 *
 * Subscription_Term_Months__c is a picklist of "12 Months" / "24 Months" /
 * "36 Months". The service maps that text to a numeric month count.
 *
 * Billing_Frequency__c is accepted as an input today but not used in the
 * computation — preserved on the API so future enhancements (deferred
 * revenue, cash-basis ACV) can layer in without changing callers.
 */
public with sharing class RevenueCalculationService {
  private static final Map<String, Integer> TERM_MONTHS_BY_LABEL = new Map<String, Integer>{
    '12 Months' => 12,
    '24 Months' => 24,
    '36 Months' => 36
  };

  // Recurring vs one-time OLI classification. Sourced from the
  // Northstar Revenue_Type picklist on OpportunityLineItem.
  @TestVisible
  private static final Set<String> RECURRING_REVENUE_TYPES = new Set<String>{
    'Subscription',
    'Usage'
  };
  @TestVisible
  private static final Set<String> ONE_TIME_REVENUE_TYPES = new Set<String>{
    'Services',
    'One-Time'
  };

  /**
   * Populates ARR__c / ACV__c on each Opportunity from its OLIs. Bulk-safe;
   * intended to be called from a trigger's before-context where Trigger.new
   * is a mutable list.
   *
   * `olisByOppId` may be null on inserts (no Id yet, no OLIs fetchable).
   * The service then falls back to Opportunity.Amount.
   */
  public static void recalculate(
    List<Opportunity> opps,
    Map<Id, List<OpportunityLineItem>> olisByOppId
  ) {
    if (opps == null || opps.isEmpty()) {
      return;
    }
    for (Opportunity opp : opps) {
      Integer months = parseTermMonths(opp.Subscription_Term_Months__c);
      if (months == null || months <= 0) {
        opp.ARR__c = null;
        opp.ACV__c = null;
        continue;
      }

      List<OpportunityLineItem> olis = olisByOppId == null
        ? null
        : olisByOppId.get(opp.Id);

      if (olis == null || olis.isEmpty()) {
        // No OLIs available — fall back to Amount-based computation.
        // beforeInsert always lands here (Opp has no Id, no OLIs exist).
        // beforeUpdate lands here for opps that have not yet had any
        // products added (e.g. brand-new pipeline records).
        Decimal arr = fromAmount(opp.Amount, months);
        opp.ARR__c = arr;
        opp.ACV__c = arr;
        continue;
      }

      Decimal recurringTotal = 0;
      Decimal oneTimeTotal = 0;
      for (OpportunityLineItem oli : olis) {
        Decimal lineTotal = lineTotalPrice(oli);
        if (RECURRING_REVENUE_TYPES.contains(oli.Revenue_Type__c)) {
          recurringTotal += lineTotal;
        } else if (ONE_TIME_REVENUE_TYPES.contains(oli.Revenue_Type__c)) {
          oneTimeTotal += lineTotal;
        }
        // Other Revenue_Type__c values (or null) are ignored — they're not
        // currently in the field's value set, but defensively skipping
        // them avoids miscategorising future additions until the values
        // are explicitly classified above.
      }

      Decimal arr = (recurringTotal * 12).divide(months, 2);
      Decimal acvOneTime = (oneTimeTotal * 12).divide(months, 2);
      opp.ARR__c = arr;
      opp.ACV__c = arr + acvOneTime;
    }
  }

  /**
   * Convenience overload preserved for the (rare) caller that only has
   * opps and wants the Amount-based fallback path. Equivalent to passing
   * null for olisByOppId.
   */
  public static void recalculate(List<Opportunity> opps) {
    recalculate(opps, null);
  }

  /**
   * Compute annualised recurring revenue from total Amount. Returns null
   * if the inputs are insufficient.
   */
  @TestVisible
  private static Decimal fromAmount(Decimal amount, Integer termMonths) {
    if (amount == null || termMonths == null || termMonths <= 0) {
      return null;
    }
    return (amount * 12).divide(termMonths, 2);
  }

  /**
   * Compute total price for an OLI. TotalPrice is normally
   * `UnitPrice * Quantity` and Salesforce maintains it on insert, but in
   * pre-insert / unit-test contexts it may not be populated yet —
   * fall back to multiplying.
   */
  @TestVisible
  private static Decimal lineTotalPrice(OpportunityLineItem oli) {
    if (oli.TotalPrice != null) {
      return oli.TotalPrice;
    }
    Decimal qty = oli.Quantity == null ? 0 : oli.Quantity;
    Decimal price = oli.UnitPrice == null ? 0 : oli.UnitPrice;
    return qty * price;
  }

  @TestVisible
  private static Integer parseTermMonths(String label) {
    if (String.isBlank(label)) {
      return null;
    }
    return TERM_MONTHS_BY_LABEL.get(label);
  }
}
