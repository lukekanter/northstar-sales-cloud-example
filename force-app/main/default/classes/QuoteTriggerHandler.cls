/**
 * QuoteTriggerHandler — Northstar Quote behaviors
 * Phase 5 (Quote).
 *
 * Three behaviors:
 *   1. Discount roll-up (beforeInsert / beforeUpdate) — compute
 *      Total_Discount_Percent__c as the QLI-weighted blended discount per
 *      the field's own description: the per-QLI standard Discount values
 *      weighted by (UnitPrice x Quantity). One SOQL per batch with a row
 *      cap + fail-fast on overflow (mirrors the OLI fetch in
 * OpportunityTriggerHandler —: never recalc on truncated
 *      line items). On insert the Quote has no Id yet, so there are no
 *      line items to query and the field stays as supplied.
 *   2. Approval escalation (beforeInsert / beforeUpdate) — stamp
 *      Approval_Status__c = 'Pending' when the blended discount crosses the
 *      threshold, Legal_Terms_Required__c is checked, OR a Services line is
 *      discounted past the margin floor (DealDeskService.requiresFinanceReview
 *      — the per-line check the blended rollup misses), and releases a
 *      trigger-set 'Pending' back to 'Not Required' once those criteria
 *      clear. It only ever moves between 'Not Required' and 'Pending' — an
 *      'Approved'/'Rejected' decision already recorded by the approval
 * process is never overridden in either direction.
 *   3. Accepted-quote sync (afterUpdate) — when a Quote becomes the
 *      Accepted + syncing quote, stamp Opportunity.Primary_Quote_Accepted__c
 *      and propagate the four commercial fields to the parent Opportunity;
 *      when it leaves that state, clear Primary_Quote_Accepted__c so a
 *      withdrawn/unsynced acceptance can't keep the Opportunity close-won
 * eligible.
 *
 * Cross-object field map: Quote.Premium_Support_Tier__c maps
 * Opportunity.Support_Tier__c. Both are backed by the Northstar_Support_Tier
 * GVS; the Premium_ prefix is the deliberate Quote-only naming per SPEC
 * not a different value domain.
 *
 * Recursion: the sync fires only on the transition INTO the
 * "Accepted + IsSyncing" state, so re-saving an already-accepted quote is a
 * no-op. Updating the Opportunity fires OpportunityTriggerHandler, but that
 * handler never writes back to Quote, so no Quote -> Opp -> Quote loop
 * exists. setMaxLoopCount is intentionally NOT used — it caps across the
 * whole transaction and would suppress the legitimate Opportunity revenue
 * recalculation that the propagated Subscription_Term_Months__c change must
 * trigger (same rationale as OpportunityTriggerHandler / LeadTriggerHandler).
 */
public with sharing class QuoteTriggerHandler extends TriggerHandler {
  @TestVisible
  private static final String STATUS_ACCEPTED = 'Accepted';
  @TestVisible
  private static final String APPROVAL_NOT_REQUIRED = 'Not Required';
  @TestVisible
  private static final String APPROVAL_PENDING = 'Pending';
  @TestVisible
  private static final String APPROVAL_APPROVED = 'Approved';
  @TestVisible
  private static final String APPROVAL_REJECTED = 'Rejected';

  // The blended-discount threshold that requires Deal Desk approval is
  // SEGMENT-AWARE, sourced from DealDeskService.requiresDiscountApproval (the
  // shared deal-desk policy) rather than a flat constant here — so an
  // SMB quote at 12% escalates even though it's under the Commercial/default
  // 15%. The segment comes from the Quote's
  // Opportunity → Account.Customer_Segment__c.

  // Conservative cap below the 50,000-row query governor for the QLI fetch.
  // @TestVisible so a test can lower it and exercise the overflow / addError
  // rollback path. Mirrors OpportunityTriggerHandler.OLI_ROW_CAP.
  @TestVisible
  private static Integer QLI_ROW_CAP = 45000;

  // -------------------------------------------------------------------------
  // Context overrides
  // -------------------------------------------------------------------------

  public override void beforeInsert() {
    applyDiscountAndApproval((List<Quote>) Trigger.new);
  }

  public override void beforeUpdate() {
    applyDiscountAndApproval((List<Quote>) Trigger.new);
  }

  public override void afterUpdate() {
    syncAcceptedQuotesToOpportunity(
      (List<Quote>) Trigger.new,
      (Map<Id, Quote>) Trigger.oldMap
    );
  }

  // -------------------------------------------------------------------------
  // Behavior 1 + 2 — discount roll-up and approval escalation
  // -------------------------------------------------------------------------

  private void applyDiscountAndApproval(List<Quote> incoming) {
    Map<Id, List<QuoteLineItem>> linesByQuoteId = new Map<Id, List<QuoteLineItem>>();
    Map<Id, Decimal> blendedByQuoteId = computeBlendedDiscounts(
      incoming,
      linesByQuoteId
    );
    if (blendedByQuoteId == null) {
      // Overflow — fail fast rather than stamping a discount derived from a
      // truncated line-item set (shared with the OLI pattern).
      failDiscountCalcOnOverflow(incoming);
      return;
    }
    // The persisted blend from before this save lets us detect a worsening
    // discount and re-open an already-Approved dimension.
    Map<Id, Quote> priors = Trigger.isUpdate
      ? (Map<Id, Quote>) Trigger.oldMap
      : null;
    // Customer segment per quote (via Opportunity → Account) drives the
    // segment-aware discount threshold. One SOQL per batch.
    Map<Id, String> segmentByOppId = fetchSegmentByOpportunity(incoming);
    for (Quote q : incoming) {
      if (q.Id == null) {
        // A brand-new Quote can't have line items yet (QuoteLineItems need a
        // QuoteId that only exists post-insert), so the blended discount is
        // definitionally null. Clear any caller-supplied value rather than
        // trusting manual input — this is a trigger-maintained rollup and a
        // stale/manual value would otherwise drive approval escalation in
        // this same pass.
        q.Total_Discount_Percent__c = null;
      } else if (blendedByQuoteId.containsKey(q.Id)) {
        // Update context: stamp the computed blend — null when the quote has
        // no line items, which clears any stale value.
        q.Total_Discount_Percent__c = blendedByQuoteId.get(q.Id);
      }
      // Services-margin review: a Services line discounted past the floor needs
      // Finance sign-off even when the blended discount stays under threshold
      // (— the per-line check the blended rollup misses). Reuses the
      // DealDeskService policy so the floor lives in one place.
      Boolean servicesBelowFloor =
        q.Id != null &&
        DealDeskService.requiresFinanceReview(q, linesByQuoteId.get(q.Id));
      // Persist the worst Services-line discount so the NEXT save can tell when
      // the services pricing deepened and re-open a recorded Finance approval
      // (— the finance analogue of the blended-discount re-open).
      q.Worst_Services_Line_Discount__c = worstServicesDiscount(
        linesByQuoteId.get(q.Id)
      );
      Quote prior = (priors != null && q.Id != null) ? priors.get(q.Id) : null;
      String segment = q.OpportunityId == null
        ? null
        : segmentByOppId.get(q.OpportunityId);
      escalateApproval(q, segment, prior, servicesBelowFloor);
    }
    ensureApproverFallback(incoming);
  }

  /**
   * a Quote that needs approval but has a blank
   * `Deal_Desk_Approver__c` falls back to the submitter's (owner's) manager, so
   * the related-user approver on the approval steps always resolves and
   * submission doesn't error out. The routing flow
   * sets the segment-specific approver as the PRIMARY; this only fills a blank,
   * so the two compose. If the owner has no manager the field stays blank (a
   * data-setup gap, surfaced as the same submission error).
   */
  private static void ensureApproverFallback(List<Quote> incoming) {
    Set<Id> ownerIds = new Set<Id>();
    for (Quote q : incoming) {
      if (
        needsApprover(q) &&
        q.Deal_Desk_Approver__c == null &&
        q.OwnerId != null
      ) {
        ownerIds.add(q.OwnerId);
      }
    }
    if (ownerIds.isEmpty()) {
      return;
    }
    Map<Id, User> ownersById = new Map<Id, User>(
      [SELECT Id, ManagerId FROM User WHERE Id IN :ownerIds]
    );
    for (Quote q : incoming) {
      if (
        needsApprover(q) &&
        q.Deal_Desk_Approver__c == null &&
        q.OwnerId != null
      ) {
        User owner = ownersById.get(q.OwnerId);
        if (owner != null && owner.ManagerId != null) {
          q.Deal_Desk_Approver__c = owner.ManagerId;
        }
      }
    }
  }

  /**
   * A Quote needs an approver when any approval dimension is in-flight — the
   * rollup is Pending or Rejected (Approved / Not Required need no approver).
   */
  @TestVisible
  private static Boolean needsApprover(Quote q) {
    return q.Approval_Status__c == APPROVAL_PENDING ||
      q.Approval_Status__c == APPROVAL_REJECTED;
  }

  /**
   * Maps each incoming Quote's Opportunity to its Account's customer segment,
   * so the discount threshold can be segment-aware. One SOQL per batch; quotes
   * with no Opportunity (or no Account segment) fall back to null → the
   * DealDeskService default threshold.
   */
  private static Map<Id, String> fetchSegmentByOpportunity(
    List<Quote> incoming
  ) {
    Set<Id> oppIds = new Set<Id>();
    for (Quote q : incoming) {
      if (q.OpportunityId != null) {
        oppIds.add(q.OpportunityId);
      }
    }
    Map<Id, String> out = new Map<Id, String>();
    if (oppIds.isEmpty()) {
      return out;
    }
    for (Opportunity o : [
      SELECT Id, Account.Customer_Segment__c
      FROM Opportunity
      WHERE Id IN :oppIds
    ]) {
      out.put(o.Id, o.Account == null ? null : o.Account.Customer_Segment__c);
    }
    return out;
  }

  /**
   * The deepest discount among the quote's Services lines (0 when there are
   * none), used to detect a worsening services-margin position across saves.
   */
  @TestVisible
  private static Decimal worstServicesDiscount(List<QuoteLineItem> lines) {
    if (lines == null || lines.isEmpty()) {
      return 0;
    }
    Decimal worst = 0;
    for (QuoteLineItem line : lines) {
      if (
        line.Revenue_Type__c == 'Services' &&
        line.Discount != null &&
        line.Discount > worst
      ) {
        worst = line.Discount;
      }
    }
    return worst;
  }

  /**
   * Blended discount per Quote = SUM(Discount x listAmount) / SUM(listAmount)
   * across the quote's line items, where listAmount = UnitPrice x Quantity.
   * Lines with no positive list amount don't contribute (they carry no
   * weight). Returns a map keyed by every update-context Quote Id, with a
   * null value where the quote has no weighted lines (so the caller clears
   * the stale field). Returns null on overflow.
   */
  private Map<Id, Decimal> computeBlendedDiscounts(
    List<Quote> incoming,
    Map<Id, List<QuoteLineItem>> linesByQuoteOut
  ) {
    Set<Id> quoteIds = new Set<Id>();
    for (Quote q : incoming) {
      if (q.Id != null) {
        quoteIds.add(q.Id);
      }
    }
    Map<Id, Decimal> out = new Map<Id, Decimal>();
    if (quoteIds.isEmpty()) {
      return out;
    }
    // Seed each update-context quote with null so a quote whose lines were
    // all removed gets its stale Total_Discount_Percent__c cleared.
    for (Id quoteId : quoteIds) {
      out.put(quoteId, null);
    }
    Integer queryLimit = QLI_ROW_CAP + 1;
    // Revenue_Type__c is fetched alongside the discount inputs so the same row
    // set feeds the per-line services-floor check (DealDeskService) without a
    // second query.
    List<QuoteLineItem> rows = [
      SELECT QuoteId, Discount, UnitPrice, Quantity, Revenue_Type__c
      FROM QuoteLineItem
      WHERE QuoteId IN :quoteIds
      LIMIT :queryLimit
    ];
    if (rows.size() > QLI_ROW_CAP) {
      return null;
    }
    Map<Id, Decimal> weightedDiscount = new Map<Id, Decimal>();
    Map<Id, Decimal> totalWeight = new Map<Id, Decimal>();
    for (QuoteLineItem qli : rows) {
      if (!linesByQuoteOut.containsKey(qli.QuoteId)) {
        linesByQuoteOut.put(qli.QuoteId, new List<QuoteLineItem>());
      }
      linesByQuoteOut.get(qli.QuoteId).add(qli);
      Decimal listAmount = lineListAmount(qli);
      if (listAmount == null || listAmount <= 0) {
        continue;
      }
      Decimal discount = qli.Discount == null ? 0 : qli.Discount;
      Decimal wd = weightedDiscount.containsKey(qli.QuoteId)
        ? weightedDiscount.get(qli.QuoteId)
        : 0;
      Decimal w = totalWeight.containsKey(qli.QuoteId)
        ? totalWeight.get(qli.QuoteId)
        : 0;
      weightedDiscount.put(qli.QuoteId, wd + (discount * listAmount));
      totalWeight.put(qli.QuoteId, w + listAmount);
    }
    for (Id quoteId : totalWeight.keySet()) {
      Decimal w = totalWeight.get(quoteId);
      if (w != null && w > 0) {
        // Round to the Number(5,2) field's scale to avoid an
        // overflow/precision error when the division has a long tail.
        out.put(quoteId, (weightedDiscount.get(quoteId) / w).setScale(2));
      }
    }
    return out;
  }

  @TestVisible
  private static Decimal lineListAmount(QuoteLineItem qli) {
    if (qli.UnitPrice == null || qli.Quantity == null) {
      return null;
    }
    return qli.UnitPrice * qli.Quantity;
  }

  private static void failDiscountCalcOnOverflow(List<Quote> affected) {
    String err =
      'Quote discount recalculation requires fetching more line items than ' +
      'is safe to query in one transaction (over ' +
      QLI_ROW_CAP +
      ' QLIs). Split this change into smaller batches and try again.';
    for (Quote q : affected) {
      q.addError(err);
    }
  }

  /**
   * Keep the trigger-owned approval state in sync with the criteria, across
   * THREE INDEPENDENT dimensions so approving one requirement can't
   * satisfy another:
   *   - discount: blended discount over threshold → Discount_Approval_Status__c
   *   - legal:    Legal_Terms_Required__c          → Legal_Approval_Status__c
   *   - finance:  Services line below margin floor → Finance_Approval_Status__c
   * Each dimension's own approval process records the Approved/Rejected
   * decision; the trigger escalates 'Not Required'/null → 'Pending', releases a
   * trigger-set 'Pending'/'Rejected' back to 'Not Required' when the criterion
   * clears (a corrected quote no longer stays stuck),
   * **re-opens an already-Approved discount to 'Pending' when the blended
   * discount worsens** so materially worse pricing can't bypass re-approval. Approval_Status__c is a read-only ROLLUP of the three
   * dimensions (Rejected > Pending > Approved > Not Required) kept for
   * display/reporting continuity.
   */
  @TestVisible
  private static void escalateApproval(Quote q) {
    escalateApproval(q, null, null, false);
  }

  @TestVisible
  private static void escalateApproval(
    Quote q,
    String segment,
    Quote prior,
    Boolean servicesBelowFloor
  ) {
    // Segment-aware discount threshold via the shared deal-desk policy. The
    // non-standard-reason branch of requiresDiscountApproval is intentionally
    // NOT used here (reason='null'): non-standard reasons drive the LEGAL
    // dimension instead (below), so a reason can't double-escalate.
    Boolean discountOverThreshold = DealDeskService.requiresDiscountApproval(
      q.Total_Discount_Percent__c,
      segment,
      null
    );
    // Legal review is required for flagged terms OR a non-standard discount
    // reason — the same predicate the rest of the deal desk uses, so a
    // Competitive Replacement / custom-terms quote can't slip past Legal just
    // because Legal_Terms_Required__c is unchecked.
    Boolean legalRequired = DealDeskService.requiresLegalReview(q);

    // Each dimension re-opens a recorded Approval when its OWN inputs worsen
    // vs the prior save, so a re-papered deal can't ride a stale approval
    // blended discount rises / a Services discount deepens / the
    // legal inputs (terms flag or discount reason) change.
    Boolean discountWorsened =
      prior != null &&
      prior.Total_Discount_Percent__c != null &&
      q.Total_Discount_Percent__c != null &&
      q.Total_Discount_Percent__c > prior.Total_Discount_Percent__c;
    // A null prior baseline counts as worsening (like a blank→real Amount on
    // the Opp): quotes finance-approved BEFORE this field deployed have no
    // baseline, so the first below-floor edit would otherwise ride the stale
    // approval forever. New quotes stamp the field at
    // insert, so they never hit this path.
    Boolean financeWorsened =
      prior != null &&
      q.Worst_Services_Line_Discount__c != null &&
      (prior.Worst_Services_Line_Discount__c == null ||
      q.Worst_Services_Line_Discount__c >
      prior.Worst_Services_Line_Discount__c);
    Boolean legalWorsened =
      prior != null &&
      (q.Legal_Terms_Required__c != prior.Legal_Terms_Required__c ||
      q.Discount_Reason__c != prior.Discount_Reason__c);

    q.Discount_Approval_Status__c = stampDimension(
      reopenIfWorsened(
        q.Discount_Approval_Status__c,
        discountOverThreshold && discountWorsened
      ),
      discountOverThreshold
    );
    q.Legal_Approval_Status__c = stampDimension(
      reopenIfWorsened(
        q.Legal_Approval_Status__c,
        legalRequired && legalWorsened
      ),
      legalRequired
    );
    q.Finance_Approval_Status__c = stampDimension(
      reopenIfWorsened(
        q.Finance_Approval_Status__c,
        (servicesBelowFloor == true) && financeWorsened
      ),
      servicesBelowFloor == true
    );

    q.Approval_Status__c = rollupApproval(
      q.Discount_Approval_Status__c,
      q.Legal_Approval_Status__c,
      q.Finance_Approval_Status__c
    );
  }

  /**
   * Forces a recorded 'Approved' decision back to 'Pending' when the underlying
   * terms have materially worsened, so re-approval is required (— the
   * blended discount increased, or the worst Services-line discount deepened).
   * Only an Approved decision is re-opened — a Rejected one already blocks.
   */
  @TestVisible
  private static String reopenIfWorsened(String current, Boolean worsened) {
    if (worsened && current == APPROVAL_APPROVED) {
      return APPROVAL_PENDING;
    }
    return current;
  }

  /**
   * Returns the next value of a single approval dimension given whether that
   * dimension is currently required. Escalates an unstarted dimension to
   * 'Pending'; when the criterion NO LONGER holds the dimension returns to 'Not
   * Required' regardless of prior value — this clears a stuck 'Rejected' AND a stale 'Approved' so a once-approved requirement that is removed
   * and later re-added must be reviewed afresh rather than riding the old
   * approval. A decision is preserved only while the criterion
   * still holds.
   */
  @TestVisible
  private static String stampDimension(String current, Boolean required) {
    if (required) {
      if (current == null || current == APPROVAL_NOT_REQUIRED) {
        return APPROVAL_PENDING;
      }
      return current;
    }
    return APPROVAL_NOT_REQUIRED;
  }

  /**
   * Rolls the three dimensions into the display-only Approval_Status__c.
   * Precedence: any Rejected → Rejected; else any Pending → Pending; else any
   * Approved → Approved; else Not Required.
   */
  @TestVisible
  private static String rollupApproval(
    String discount,
    String legal,
    String finance
  ) {
    List<String> dims = new List<String>{ discount, legal, finance };
    if (dims.contains(APPROVAL_REJECTED)) {
      return APPROVAL_REJECTED;
    }
    if (dims.contains(APPROVAL_PENDING)) {
      return APPROVAL_PENDING;
    }
    if (dims.contains(APPROVAL_APPROVED)) {
      return APPROVAL_APPROVED;
    }
    return APPROVAL_NOT_REQUIRED;
  }

  // -------------------------------------------------------------------------
  // Behavior 3 — Accepted-quote sync back to Opportunity
  // -------------------------------------------------------------------------

  private void syncAcceptedQuotesToOpportunity(
    List<Quote> incoming,
    Map<Id, Quote> priors
  ) {
    // One Opportunity update per parent. If two syncing quotes on the same
    // Opportunity accept in the same batch, last-writer-wins on the field
    // values; Primary_Quote_Accepted__c is true either way.
    Map<Id, Opportunity> oppUpdates = new Map<Id, Opportunity>();
    for (Quote q : incoming) {
      if (q.OpportunityId == null) {
        continue;
      }
      Boolean nowAcceptedSyncing = isAcceptedSyncing(q);
      Boolean wasAcceptedSyncing = isAcceptedSyncing(priors.get(q.Id));
      if (nowAcceptedSyncing && !wasAcceptedSyncing) {
        // Transition INTO "Accepted + IsSyncing" — stamp the flag and
        // propagate the four commercial fields to the parent Opportunity.
        oppUpdates.put(
          q.OpportunityId,
          new Opportunity(
            Id = q.OpportunityId,
            Primary_Quote_Accepted__c = true,
            Implementation_Package__c = q.Implementation_Package__c,
            Billing_Frequency__c = q.Billing_Frequency__c,
            Subscription_Term_Months__c = q.Subscription_Term_Months__c,
            // Quote.Premium_Support_Tier__c -> Opportunity.Support_Tier__c
            // (same GVS; Premium_ prefix is Quote-only naming).
            Support_Tier__c = q.Premium_Support_Tier__c
          )
        );
      } else if (wasAcceptedSyncing && !nowAcceptedSyncing) {
        // Transition OUT of "Accepted + IsSyncing" — the previously accepted
        // primary quote was withdrawn (Status left Accepted) or unsynced.
        // Clear the sticky acceptance flag so Close-Won can't rely on a stale
        // acceptance. An Opp has at most one syncing quote, so this
        // can't fight a concurrent accept; if one does occur in the same batch
        // the accept branch's unconditional put wins.
        if (!oppUpdates.containsKey(q.OpportunityId)) {
          oppUpdates.put(
            q.OpportunityId,
            new Opportunity(
              Id = q.OpportunityId,
              Primary_Quote_Accepted__c = false
            )
          );
        }
      }
    }
    if (!oppUpdates.isEmpty()) {
      update oppUpdates.values();
    }
  }

  /**
   * A Quote is the "accepted, syncing" quote when IsSyncing is true and its
   * Status is 'Accepted'. Null-safe so it can be called on the oldMap prior.
   */
  @TestVisible
  private static Boolean isAcceptedSyncing(Quote q) {
    return q != null && q.IsSyncing == true && q.Status == STATUS_ACCEPTED;
  }
}
