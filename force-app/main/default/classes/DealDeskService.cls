/**
 * DealDeskService — threshold/decision helpers for discount approval, legal
 * review, and finance (services-margin) review, so quotes/flows/triggers
 * share one rule set.
 *
 * specifies the *shape* of these gates but not the numbers;
 * deferred the concrete thresholds to this service. The constants
 * below are that decision and are `@TestVisible` so they're easy
 * to find and revise.
 */
public with sharing class DealDeskService {
  // Discount % above which the deal needs approval, by Customer Segment.
  // Strategic/Enterprise get more latitude; SMB the least. Commercial keeps
  // flat 15.
  @TestVisible
  private static final Map<String, Decimal> DISCOUNT_THRESHOLD_BY_SEGMENT = new Map<String, Decimal>{
    'Strategic' => 25,
    'Enterprise' => 20,
    'Partner Managed' => 20,
    'Commercial' => 15,
    'SMB' => 10
  };
  @TestVisible
  private static final Decimal DEFAULT_DISCOUNT_THRESHOLD = 15;

  // Discount reasons that signal non-standard / margin-critical terms — they
  // require approval regardless of size and drive legal review.
  @TestVisible
  private static final Set<String> NON_STANDARD_DISCOUNT_REASONS = new Set<String>{
    'Competitive Replacement',
    'RFP Floor',
    'Customer Save',
    'Strategic Logo'
  };

  @TestVisible
  private static final String SERVICES_REVENUE_TYPE = 'Services';
  // A Services line discounted more than this % is treated as below the
  // margin floor (no cost field exists, so discount depth is the proxy).
  @TestVisible
  private static Decimal SERVICES_DISCOUNT_FLOOR_PERCENT = 20;

  // -------------------------------------------------------------------------
  // Static API
  // -------------------------------------------------------------------------

  /**
   * True when the discount needs Deal Desk approval: a non-standard reason
   * always escalates; otherwise the discount must exceed the segment
   * threshold. A zero/absent discount never needs approval.
   */
  public static Boolean requiresDiscountApproval(
    Decimal discountPercent,
    String segment,
    String discountReason
  ) {
    if (discountPercent == null || discountPercent <= 0) {
      return false;
    }
    if (NON_STANDARD_DISCOUNT_REASONS.contains(discountReason)) {
      return true;
    }
    return discountPercent > thresholdForSegment(segment);
  }

  /**
   * True when the quote needs Legal review — its terms are flagged
   * non-standard (`Legal_Terms_Required__c`) or its discount reason is one of
   * the non-standard / custom-terms reasons.
   */
  public static Boolean requiresLegalReview(Quote q) {
    if (q == null) {
      return false;
    }
    return q.Legal_Terms_Required__c == true ||
      NON_STANDARD_DISCOUNT_REASONS.contains(q.Discount_Reason__c);
  }

  /**
   * True when any implementation (`Services`) line is discounted past the
   * margin floor, so Finance signs off on the services margin. Lines are
   * passed in (no SOQL) so callers stay bulk-safe.
   */
  public static Boolean requiresFinanceReview(
    Quote q,
    List<QuoteLineItem> lines
  ) {
    if (lines == null || lines.isEmpty()) {
      return false;
    }
    for (QuoteLineItem line : lines) {
      if (
        line.Revenue_Type__c == SERVICES_REVENUE_TYPE &&
        line.Discount != null &&
        line.Discount > SERVICES_DISCOUNT_FLOOR_PERCENT
      ) {
        return true;
      }
    }
    return false;
  }

  private static Decimal thresholdForSegment(String segment) {
    return DISCOUNT_THRESHOLD_BY_SEGMENT.containsKey(segment)
      ? DISCOUNT_THRESHOLD_BY_SEGMENT.get(segment)
      : DEFAULT_DISCOUNT_THRESHOLD;
  }

  // -------------------------------------------------------------------------
  // Flow API
  // -------------------------------------------------------------------------

  public class DealDeskRequest {
    @InvocableVariable(label='Discount Percent')
    public Decimal discountPercent;
    @InvocableVariable(label='Customer Segment')
    public String segment;
    @InvocableVariable(label='Discount Reason')
    public String discountReason;
    @InvocableVariable(label='Quote')
    public Quote quote;
    @InvocableVariable(label='Quote Line Items')
    public List<QuoteLineItem> quoteLines;
  }

  public class DealDeskResult {
    @InvocableVariable
    public Boolean discountApproval;
    @InvocableVariable
    public Boolean legalReview;
    @InvocableVariable
    public Boolean financeReview;
  }

  @InvocableMethod(
    label='Evaluate Deal Desk'
    description='Returns the discount-approval, legal-review, and finance-review flags for a quote.'
  )
  public static List<DealDeskResult> evaluateDealDesk(
    List<DealDeskRequest> requests
  ) {
    List<DealDeskResult> out = new List<DealDeskResult>();
    for (DealDeskRequest req : requests) {
      DealDeskResult result = new DealDeskResult();
      result.discountApproval = requiresDiscountApproval(
        req.discountPercent,
        req.segment,
        req.discountReason
      );
      result.legalReview = requiresLegalReview(req.quote);
      result.financeReview = requiresFinanceReview(req.quote, req.quoteLines);
      out.add(result);
    }
    return out;
  }
}
