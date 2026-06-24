/**
 * OpportunityTriggerHandler — Northstar Opportunity behaviors for the
 * Opportunity lifecycle, including Deal_Closed__e publication.
 *
 * Four behaviors:
 *   1. Revenue recalculation (beforeInsert / beforeUpdate) — delegates to
 *      RevenueCalculationService to populate ARR__c / ACV__c.
 *   2. Territory_Segment__c stamping — denormalised "Region - Segment"
 *      string sourced from the related Account, refreshed when AccountId
 *      changes. One SOQL per batch.
 *   3. Stage-consistency validation (beforeUpdate) — `addError` if a deal
 *      moves to "Proposal/Price Quote" without any OpportunityLineItems.
 * Soft gate; the hard validation rule lives.
 *   4. Closed Won handling:
 *        - beforeUpdate: stamp Provisioning_Status__c = 'Pending' on the
 *          transition. Doing it in before-context avoids a second-pass
 *          DML that would be required from afterUpdate. This is an
 *          implementation refinement of the issue's "afterUpdate" wording
 *          — the side effect happens at the same save, just earlier in
 *          the trigger order.
 *        - afterUpdate: insert a placeholder Task for the AE and publish
 *          Deal_Closed__e for the Provisioning/Renewal subscribers
 *
 *
 * Order/Contract creation is intentionally NOT done here. The Closed Won
 * orchestration flow consumes the platform event and calls
 * the Generate-Order invocable. The trigger only stages.
 *
 * Recursion: idempotent via Trigger.oldMap comparison. The Closed-Won
 * transition fires only when `prior.StageName != 'Closed Won'` AND
 * `lead.StageName == 'Closed Won'`, so a re-entry update on an already-
 * Closed-Won opp does nothing. setMaxLoopCount is intentionally NOT used
 * (caps across the whole transaction, blocking legitimate side effects
 * from two separate user-initiated updates — same rationale as
 * LeadTriggerHandler).
 */
public with sharing class OpportunityTriggerHandler extends TriggerHandler {
  // Stages that gate the Proposal-requires-OLIs soft validation.
  @TestVisible
  private static final String PROPOSAL_STAGE = 'Proposal/Price Quote';
  @TestVisible
  private static final String CLOSED_WON = 'Closed Won';

  // Provisioning lifecycle states (subset; full list on the Opp field's
  // inline value set).
  private static final String PROV_STATUS_PENDING = 'Pending';

  // Discount-approval lifecycle (Opportunity side — parallels the Quote
  // per-dimension model in QuoteTriggerHandler).
  @TestVisible
  private static final String APPROVAL_NOT_REQUIRED = 'Not Required';
  @TestVisible
  private static final String APPROVAL_PENDING = 'Pending';
  @TestVisible
  private static final String APPROVAL_APPROVED = 'Approved';
  // Amount at/above which a discounted Opp needs Deal Desk approval (mirrors
  // the Discount_Reason_Required_High_Value VR and the approval-process entry).
  @TestVisible
  private static final Decimal DISCOUNT_HIGH_VALUE_AMOUNT = 100000;

  // Task tagging — downstream subscribers can filter on this string the
  // same way 'Lead Qualified Signal' is named for Lead.
  @TestVisible
  private static final String CLOSED_WON_TASK_SOURCE = 'Closed Won AE Followup';

  // Captures the last EventBus.publish() result for tests. @TestVisible
  // so tests can assert the publish succeeded without standing up a
  // subscriber.
  @TestVisible
  private static List<Database.SaveResult> lastDealClosedPublishResults;

  // Captures the event payloads themselves so tests can assert specific
  // field values (Segment__c, Closed_Date__c, ARR__c) before publish.
  @TestVisible
  private static List<Deal_Closed__e> lastDealClosedEvents;

  // Test-only flag — when true the handler skips the real EventBus.publish
  // and synthesises a publish failure so the addError rollback path can
  // be exercised. `EventBus.publish` doesn't expose a way to force-fail
  // in Apex tests, so this hook is the practical alternative.
  @TestVisible
  private static Boolean simulatePublishFailureForTest = false;

  // Conservative cap below the 50,000-row query governor. @TestVisible so
  // a test can lower it to a reachable size and exercise the overflow /
  // addError rollback path.
  @TestVisible
  private static Integer OLI_ROW_CAP = 45000;

  // ARR_Band__c bucket API values — MUST match the Northstar_ARR_Band global
  // value set exactly. Bucketed off ARR__c (dollars).
  @TestVisible
  private static final String ARR_BAND_UNDER_50K = 'Under 50K';
  @TestVisible
  private static final String ARR_BAND_50K_TO_250K = '50K to 250K';
  @TestVisible
  private static final String ARR_BAND_250K_TO_1M = '250K to 1M';
  @TestVisible
  private static final String ARR_BAND_1M_PLUS = '1M plus';

  // -------------------------------------------------------------------------
  // Context overrides
  // -------------------------------------------------------------------------

  public override void beforeInsert() {
    List<Opportunity> incoming = (List<Opportunity>) Trigger.new;
    // beforeInsert: opps don't have Ids yet, so OLIs aren't fetchable.
    // recalculate(opps, null) falls back to Amount-based ARR/ACV.
    RevenueCalculationService.recalculate(incoming, null);
    stampArrBand(incoming);
    stampTerritorySegment(incoming, null);
    stampDiscountApproval(incoming, null);
  }

  public override void beforeUpdate() {
    List<Opportunity> incoming = (List<Opportunity>) Trigger.new;
    Map<Id, Opportunity> priors = (Map<Id, Opportunity>) Trigger.oldMap;
    // Recalc only the opps that actually changed a revenue-driving field
    // (Amount, term, or Closed Won transition). Restricting the OLI fetch
    // to this subset means a single revenue-touched opp in a 200-record
    // mixed batch only pulls its own OLIs into the query — the 199
    // unrelated edits don't drag their products into the row cap. Review
    // flagged the previous "fetch incoming.size()'s worth of OLIs once
    // any opp needs recalc" pattern as a risk for exactly this reason.
    //
    // OLI-only changes are covered by OpportunityLineItemTrigger, so we
    // don't need to refresh on every parent save.
    List<Opportunity> needingRecalc = oppsNeedingRevenueRecalc(
      incoming,
      priors
    );
    if (!needingRecalc.isEmpty()) {
      Map<Id, List<OpportunityLineItem>> olis = fetchOLIsByOpp(needingRecalc);
      if (olis == null) {
        // Overflow — fail-fast on the affected opps rather than silently
        // truncating and persisting incorrect ARR/ACV.
        failRevenueRecalcOnOverflow(needingRecalc);
        return;
      }
      RevenueCalculationService.recalculate(needingRecalc, olis);
    }
    stampArrBand(incoming);
    stampTerritorySegment(incoming, priors);
    enforceProposalStageHasOLIs(incoming, priors);
    stageClosedWonInBefore(incoming, priors);
    stampDiscountApproval(incoming, priors);
    stampHasPrimaryContactRole(incoming);
  }

  // -------------------------------------------------------------------------
  // Has_Primary_Contact_Role__c stamping
  // -------------------------------------------------------------------------

  /**
   * Stamp Has_Primary_Contact_Role__c = true when the Opportunity has at
   * least one OpportunityContactRole with IsPrimary = true, else false.
   *
   * The Negotiation_Requires_Primary_Contact validation rule
   * reads this boolean because a validation rule cannot traverse to child
   * OpportunityContactRole records. Stamping in before-update is sufficient
   * for that gate: Salesforce's save order runs before-triggers BEFORE
   * validation rules, so the value the VR evaluates is the one we just wrote
   * — fresh as of this same save, which is the save that performs the
   * StageName → Negotiation transition the rule guards.
   *
   * Only stamped on update. On insert the Opportunity has no Id yet, so no
   * OpportunityContactRole can reference it; the field's `false` default is
   * already correct. The VR gates on `(ISNEW() || ISCHANGED(StageName))`, so an
   * insert directly at Negotiation IS gated — and because a primary OCR can't
   * exist at insert, that creation path can never satisfy the rule, which is
   * the intended enforcement (same pattern as Cannot_Move_To_Proposal_Without_
   * Products). OCR-only edits do not retrigger the Opportunity, so the stamp
   * can lag a pure contact-role change until the next Opportunity save — that
   * is acceptable because the field exists for the transition gate, not for
   * real-time display. One SOQL per batch.
   */
  private static void stampHasPrimaryContactRole(List<Opportunity> incoming) {
    Set<Id> oppIds = new Set<Id>();
    for (Opportunity opp : incoming) {
      if (opp.Id != null) {
        oppIds.add(opp.Id);
      }
    }
    if (oppIds.isEmpty()) {
      return;
    }
    Set<Id> oppIdsWithPrimary = new Set<Id>();
    for (AggregateResult ar : [
      SELECT OpportunityId
      FROM OpportunityContactRole
      WHERE OpportunityId IN :oppIds AND IsPrimary = TRUE
      GROUP BY OpportunityId
    ]) {
      oppIdsWithPrimary.add((Id) ar.get('OpportunityId'));
    }
    for (Opportunity opp : incoming) {
      Boolean hasPrimary = oppIdsWithPrimary.contains(opp.Id);
      if (opp.Has_Primary_Contact_Role__c != hasPrimary) {
        opp.Has_Primary_Contact_Role__c = hasPrimary;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Discount approval escalation (Opportunity side)
  // -------------------------------------------------------------------------

  /**
   * Keeps Discount_Approval_Status__c in sync with the Opp discount-approval
   * criteria (Strategic Logo reason, OR any discount reason with Amount >=
   * 100k — mirroring the Northstar Discount Approval process entry). Escalates
   * 'Not Required'/null → 'Pending'; when the criteria no longer hold the
   * dimension returns to 'Not Required' regardless of prior value, so a stale
   * 'Approved'/'Rejected' can't ride a later re-trigger; and **re-opens an
   * already-Approved deal to 'Pending' when the approval-driving inputs
   * materially change** (the discount reason changes, or the Amount rises) so a
   * re-papered discount can't close won on a stale approval.
   * Parallels the Quote per-dimension model. The
   * Discount_Approval_Required_For_Close validation rule turns this into a hard
   * close-won gate.
   */
  private static void stampDiscountApproval(
    List<Opportunity> incoming,
    Map<Id, Opportunity> priors
  ) {
    for (Opportunity o : incoming) {
      if (!isDiscountApprovalRequired(o)) {
        o.Discount_Approval_Status__c = APPROVAL_NOT_REQUIRED;
        continue;
      }
      Opportunity prior = (priors == null) ? null : priors.get(o.Id);
      if (
        o.Discount_Approval_Status__c == null ||
        o.Discount_Approval_Status__c == APPROVAL_NOT_REQUIRED ||
        (o.Discount_Approval_Status__c == APPROVAL_APPROVED &&
        discountInputsWorsened(o, prior))
      ) {
        o.Discount_Approval_Status__c = APPROVAL_PENDING;
      }
      // else: a Pending/Rejected, or an Approved whose inputs are unchanged,
      // is preserved.
    }
    ensureApproverFallback(incoming);
  }

  /**
   * an Opportunity that needs discount approval but has a
   * blank `Deal_Desk_Approver__c` falls back to the owner's manager, so the
   * related-user approver on the Discount Approval step always resolves.
   * Mirrors the Quote fallback; the routing flow sets the
   * segment-specific approver as the primary, this only fills a blank.
   */
  private static void ensureApproverFallback(List<Opportunity> incoming) {
    Set<Id> ownerIds = new Set<Id>();
    for (Opportunity o : incoming) {
      if (
        o.Discount_Approval_Status__c == APPROVAL_PENDING &&
        o.Deal_Desk_Approver__c == null &&
        o.OwnerId != null
      ) {
        ownerIds.add(o.OwnerId);
      }
    }
    if (ownerIds.isEmpty()) {
      return;
    }
    Map<Id, User> ownersById = new Map<Id, User>(
      [SELECT Id, ManagerId FROM User WHERE Id IN :ownerIds]
    );
    for (Opportunity o : incoming) {
      if (
        o.Discount_Approval_Status__c == APPROVAL_PENDING &&
        o.Deal_Desk_Approver__c == null &&
        o.OwnerId != null
      ) {
        User owner = ownersById.get(o.OwnerId);
        if (owner != null && owner.ManagerId != null) {
          o.Deal_Desk_Approver__c = owner.ManagerId;
        }
      }
    }
  }

  /**
   * True when the approval-driving inputs changed in a way that should void a
   * recorded approval: the discount reason changed (different justification),
   * or the Amount increased (bigger exposure). A lower Amount or unchanged
   * inputs don't force a re-review.
   */
  @TestVisible
  private static Boolean discountInputsWorsened(
    Opportunity o,
    Opportunity prior
  ) {
    if (prior == null) {
      return false;
    }
    Boolean reasonChanged = o.Discount_Reason__c != prior.Discount_Reason__c;
    // A blank → real amount is a worsening too: the approved exposure went from
    // unknown to a concrete figure.
    Boolean amountRose =
      o.Amount != null && (prior.Amount == null || o.Amount > prior.Amount);
    return reasonChanged || amountRose;
  }

  @TestVisible
  private static Boolean isDiscountApprovalRequired(Opportunity o) {
    String reason = o.Discount_Reason__c;
    Boolean hasReason = reason != null && reason != '';
    Boolean strategicLogo = reason == 'Strategic Logo';
    Boolean highValue =
      o.Amount != null &&
      o.Amount >= DISCOUNT_HIGH_VALUE_AMOUNT;
    return strategicLogo || (hasReason && highValue);
  }

  /**
   * Calls addError on every opp in the (already revenue-filtered) batch
   * so the transaction rolls back with a clear, actionable message instead
   * of committing partially-correct ARR/ACV numbers.
   */
  private static void failRevenueRecalcOnOverflow(List<Opportunity> affected) {
    String err =
      'Opportunity revenue recalculation requires fetching more line items ' +
      'than is safe to query in one transaction (over ' +
      OLI_ROW_CAP +
      ' OLIs). Split this update into smaller batches and try again.';
    for (Opportunity opp : affected) {
      opp.addError(err);
    }
  }

  // -------------------------------------------------------------------------
  // ARR_Band__c stamping
  // -------------------------------------------------------------------------

  /**
   * Stamp ARR_Band__c by bucketing the finalized ARR__c (falling back to
   * Amount when ARR__c is null), so the band always agrees with the ARR__c
   * persisted in the same save.
   *
   * This runs in before-save Apex AFTER RevenueCalculationService has set
   * ARR__c. The first cut stamped the band from a before-save
   * record-triggered FLOW, but Salesforce runs before-save flows BEFORE
   * before-save Apex triggers — so the flow bucketed a stale/blank ARR__c
   * (falling back to the un-annualized Amount) and the trigger then
   * overwrote ARR__c, leaving the band a save behind (e.g. Amount 120k on a
   * 36-month term → flow stamped "50K to 250K" but ARR__c became 40k →
   * should be "Under 50K"). Computing it here, right after the recalc, fixes
   * that ordering gap (revised). A blank source clears
   * the band. Pure in-memory — no SOQL/DML.
   */
  private static void stampArrBand(List<Opportunity> incoming) {
    for (Opportunity opp : incoming) {
      Decimal source = (opp.ARR__c != null) ? opp.ARR__c : opp.Amount;
      String band = bandForArr(source);
      if (opp.ARR_Band__c != band) {
        opp.ARR_Band__c = band;
      }
    }
  }

  /**
   * Buckets an ARR/Amount figure into a Northstar_ARR_Band API value, or
   * null when the source is blank. Boundaries are lower-inclusive:
   * [0,50k)=Under 50K, [50k,250k)=50K to 250K, [250k,1M)=250K to 1M,
   * [1M,∞)=1M plus.
   */
  @TestVisible
  private static String bandForArr(Decimal source) {
    if (source == null) {
      return null;
    }
    if (source < 50000) {
      return ARR_BAND_UNDER_50K;
    }
    if (source < 250000) {
      return ARR_BAND_50K_TO_250K;
    }
    if (source < 1000000) {
      return ARR_BAND_250K_TO_1M;
    }
    return ARR_BAND_1M_PLUS;
  }

  /**
   * Returns only the opps in `incoming` whose revenue-driving inputs
   * changed — Amount, Subscription_Term_Months__c, or a Stage transition
   * into Closed Won. Used as the input set for the OLI fetch + recalc so
   * mixed bulk updates don't drag unaffected opps' products into the
   * row-cap budget.
   */
  private static List<Opportunity> oppsNeedingRevenueRecalc(
    List<Opportunity> incoming,
    Map<Id, Opportunity> priors
  ) {
    List<Opportunity> out = new List<Opportunity>();
    for (Opportunity opp : incoming) {
      Opportunity prior = priors.get(opp.Id);
      if (prior == null) {
        continue;
      }
      if (
        opp.Amount != prior.Amount ||
        opp.Subscription_Term_Months__c != prior.Subscription_Term_Months__c ||
        isClosedWonTransition(opp, prior)
      ) {
        out.add(opp);
      }
    }
    return out;
  }

  /**
   * One SOQL per batch to fetch every Opp's line items, indexed by parent
   * Opportunity Id. Uses LIMIT 45001 so we can detect overflow without
   * crossing the 50,000-row governor.
   *
   * Returns null on overflow (>45,000 OLIs across the batch's parents).
   * The caller MUST handle the null case — silently truncating and then
   * recalculating on partial data would persist understated ARR/ACV
   * across affected parents. An empty map is a valid result
   * meaning "no OLIs found, but no overflow either."
   */
  private static Map<Id, List<OpportunityLineItem>> fetchOLIsByOpp(
    List<Opportunity> opps
  ) {
    Set<Id> oppIds = new Set<Id>();
    for (Opportunity opp : opps) {
      if (opp.Id != null) {
        oppIds.add(opp.Id);
      }
    }
    Map<Id, List<OpportunityLineItem>> out = new Map<Id, List<OpportunityLineItem>>();
    if (oppIds.isEmpty()) {
      return out;
    }
    Integer queryLimit = OLI_ROW_CAP + 1;
    List<OpportunityLineItem> rows = [
      SELECT OpportunityId, TotalPrice, Quantity, UnitPrice, Revenue_Type__c
      FROM OpportunityLineItem
      WHERE OpportunityId IN :oppIds
      LIMIT :queryLimit
    ];
    if (rows.size() > OLI_ROW_CAP) {
      return null;
    }
    for (OpportunityLineItem oli : rows) {
      if (!out.containsKey(oli.OpportunityId)) {
        out.put(oli.OpportunityId, new List<OpportunityLineItem>());
      }
      out.get(oli.OpportunityId).add(oli);
    }
    return out;
  }

  public override void afterUpdate() {
    handleClosedWonAfter(
      (List<Opportunity>) Trigger.new,
      (Map<Id, Opportunity>) Trigger.oldMap
    );
  }

  // -------------------------------------------------------------------------
  // Behavior 2 — Territory_Segment__c stamping
  // -------------------------------------------------------------------------

  /**
   * Build "Region - Segment" string from the related Account and stamp it
   * onto Opportunity.Territory_Segment__c. Four cases:
   *
   *   - Insert with AccountId set → fetch, stamp.
   *   - Insert without AccountId → no stamp (field stays null).
   *   - Update with AccountId changed → fetch new Account, re-stamp.
   *   - Update with AccountId now nulled → CLEAR the stale stamp value,
   *     because Territory_Segment__c still implies an account-derived
   *     segment that no longer applies.
   *   - Update with AccountId unchanged → no fetch, no re-stamp.
   */
  private void stampTerritorySegment(
    List<Opportunity> incoming,
    Map<Id, Opportunity> priors
  ) {
    Set<Id> accountIdsToFetch = new Set<Id>();
    for (Opportunity opp : incoming) {
      if (opp.AccountId == null) {
        continue;
      }
      if (priors == null) {
        accountIdsToFetch.add(opp.AccountId);
        continue;
      }
      Opportunity prior = priors.get(opp.Id);
      if (prior == null || prior.AccountId != opp.AccountId) {
        accountIdsToFetch.add(opp.AccountId);
      }
    }

    Map<Id, Account> accounts = accountIdsToFetch.isEmpty()
      ? new Map<Id, Account>()
      : new Map<Id, Account>(
          [
            SELECT Id, Region__c, Customer_Segment__c
            FROM Account
            WHERE Id IN :accountIdsToFetch
          ]
        );

    for (Opportunity opp : incoming) {
      // Case: AccountId was nulled in this update — clear stale stamp.
      if (opp.AccountId == null) {
        if (priors != null) {
          Opportunity prior = priors.get(opp.Id);
          if (prior != null && prior.AccountId != null) {
            opp.Territory_Segment__c = null;
          }
        }
        continue;
      }
      // Case: AccountId unchanged on update — skip re-stamp.
      if (!accountIdsToFetch.contains(opp.AccountId)) {
        continue;
      }
      // Case: AccountId set or changed — fetch and stamp.
      Account acct = accounts.get(opp.AccountId);
      if (acct == null) {
        continue;
      }
      opp.Territory_Segment__c = formatTerritorySegment(
        acct.Region__c,
        acct.Customer_Segment__c
      );
    }
  }

  @TestVisible
  private static String formatTerritorySegment(String region, String segment) {
    if (String.isBlank(region) && String.isBlank(segment)) {
      return null;
    }
    String r = String.isBlank(region) ? '?' : region;
    String s = String.isBlank(segment) ? '?' : segment;
    return r + ' - ' + s;
  }

  // -------------------------------------------------------------------------
  // Behavior 3 — Proposal-requires-OLIs soft validation
  // -------------------------------------------------------------------------

  /**
   * `addError` if a record transitions INTO "Proposal/Price Quote" without
   * any OpportunityLineItems. Soft gate — users see an actionable message
   * before the validation rule in hits them with the platform error.
   *
   * Only checks transitions, not steady-state. A record that was already in
   * Proposal/Price Quote and is updated for some other reason doesn't get
   * re-checked (we assume it had OLIs when it first arrived).
   */
  private void enforceProposalStageHasOLIs(
    List<Opportunity> incoming,
    Map<Id, Opportunity> priors
  ) {
    Set<Id> transitioningIds = new Set<Id>();
    for (Opportunity opp : incoming) {
      Opportunity prior = priors.get(opp.Id);
      if (
        opp.StageName == PROPOSAL_STAGE &&
        prior != null &&
        prior.StageName != PROPOSAL_STAGE
      ) {
        transitioningIds.add(opp.Id);
      }
    }
    if (transitioningIds.isEmpty()) {
      return;
    }
    Set<Id> oppIdsWithOLIs = new Set<Id>();
    for (AggregateResult ar : [
      SELECT OpportunityId
      FROM OpportunityLineItem
      WHERE OpportunityId IN :transitioningIds
      GROUP BY OpportunityId
    ]) {
      oppIdsWithOLIs.add((Id) ar.get('OpportunityId'));
    }
    for (Opportunity opp : incoming) {
      if (
        transitioningIds.contains(opp.Id) && !oppIdsWithOLIs.contains(opp.Id)
      ) {
        opp.addError(
          'Cannot move to Proposal/Price Quote without at least one ' +
            'OpportunityLineItem. Add the product the customer is buying ' +
            'before advancing the stage.'
        );
      }
    }
  }

  // -------------------------------------------------------------------------
  // Behavior 4a — beforeUpdate Closed Won staging
  // -------------------------------------------------------------------------

  /**
   * On Stage transition INTO Closed Won, set Provisioning_Status__c to the
   * rollup of the Opportunity's existing Orders, defaulting
   * 'Pending' (the handoff) when there are no Orders yet — the normal path,
   * where the Order is generated by the after-save orchestration flow. Done in
   * beforeUpdate so the save persists the status in the same DML.
   *
   * Sourcing the value from the actual Orders (not the incoming stamp) is what
   * makes this non-clobbering AND correct: an Order generated and provisioned
   * BEFORE close (the ORDER_ALREADY_EXISTS path) keeps its terminal
   * 'Completed'/'Failed'; a merely pre-generated Draft order (still
   * 'Not Required') does NOT get frozen as a stale terminal status — it rolls
   * to 'Not Required' here and the after-save flow then stamps 'Pending'
   * (refined later). Recompute on the
   * after-save side / activation keeps it current thereafter.
   */
  private void stageClosedWonInBefore(
    List<Opportunity> incoming,
    Map<Id, Opportunity> priors
  ) {
    Set<Id> transitioning = new Set<Id>();
    for (Opportunity opp : incoming) {
      if (isClosedWonTransition(opp, priors.get(opp.Id))) {
        transitioning.add(opp.Id);
      }
    }
    if (transitioning.isEmpty()) {
      return;
    }
    Map<Id, String> rolledUp = ProvisioningService.provisioningStatusByOpportunity(
      transitioning
    );
    for (Opportunity opp : incoming) {
      if (!transitioning.contains(opp.Id)) {
        continue;
      }
      // Orders present → reflect their aggregate; none yet → Pending handoff.
      opp.Provisioning_Status__c = rolledUp.containsKey(opp.Id)
        ? rolledUp.get(opp.Id)
        : PROV_STATUS_PENDING;
    }
  }

  // -------------------------------------------------------------------------
  // Behavior 4b — afterUpdate Closed Won fan-out
  // -------------------------------------------------------------------------

  /**
   * On Stage transition INTO Closed Won:
   *   - insert one placeholder Task per opp, owned by the opp owner (the AE)
   *   - publish one Deal_Closed__e event per opp
   *
   * Task insertion and event publication are bulk-safe single DML/publish
   * calls regardless of batch size.
   */
  private void handleClosedWonAfter(
    List<Opportunity> incoming,
    Map<Id, Opportunity> priors
  ) {
    List<Opportunity> transitioned = new List<Opportunity>();
    Set<Id> accountIds = new Set<Id>();
    for (Opportunity opp : incoming) {
      if (isClosedWonTransition(opp, priors.get(opp.Id))) {
        transitioned.add(opp);
        if (opp.AccountId != null) {
          accountIds.add(opp.AccountId);
        }
      }
    }
    if (transitioned.isEmpty()) {
      return;
    }
    // Pull Account.Customer_Segment__c so Deal_Closed__e.Segment__c can
    // carry the segment value alone (e.g. "Commercial"), not the combined
    // Territory_Segment__c string. Subscribers route on the segment token,
    // not the "Region - Segment" denormalisation.
    Map<Id, Account> accountsById = accountIds.isEmpty()
      ? new Map<Id, Account>()
      : new Map<Id, Account>(
          [
            SELECT Id, Customer_Segment__c
            FROM Account
            WHERE Id IN :accountIds
          ]
        );
    insertFollowupTasks(transitioned);
    publishDealClosed(transitioned, accountsById);
  }

  private static Boolean isClosedWonTransition(
    Opportunity current,
    Opportunity prior
  ) {
    if (current.StageName != CLOSED_WON) {
      return false;
    }
    if (prior == null) {
      // afterUpdate never sees prior == null, but the check keeps the
      // helper safely callable from beforeInsert paths if added later.
      return false;
    }
    return prior.StageName != CLOSED_WON;
  }

  private static void insertFollowupTasks(List<Opportunity> opps) {
    List<Task> toInsert = new List<Task>();
    for (Opportunity opp : opps) {
      Task t = new Task(
        WhatId = opp.Id,
        Subject = 'Closed Won — kick off onboarding for ' + opp.Name,
        Status = 'Not Started',
        Priority = 'High',
        ActivityDate = Date.today().addDays(1),
        Action_Plan_Source__c = CLOSED_WON_TASK_SOURCE,
        Routing_Reason__c = 'Closed Won transition — AE follow-up'
      );
      if (opp.OwnerId != null) {
        // Opportunity.OwnerId is always a User (Opps aren't queue-enabled),
        // so we can always assign the Task owner without the queue guard
        // that LeadTriggerHandler needs.
        t.OwnerId = opp.OwnerId;
      }
      toInsert.add(t);
    }
    if (!toInsert.isEmpty()) {
      insert toInsert;
    }
  }

  private static void publishDealClosed(
    List<Opportunity> opps,
    Map<Id, Account> accountsById
  ) {
    // Snapshot the transition moment ONCE for the whole batch so every
    // event in the publish carries the same Closed_Date__c.
    // Deal_Closed__e is PublishAfterCommit, so this stamp is also the
    // commit moment from the subscriber's perspective.
    DateTime closedAt = DateTime.now();
    List<Deal_Closed__e> events = new List<Deal_Closed__e>();
    for (Opportunity opp : opps) {
      Account acct = opp.AccountId == null
        ? null
        : accountsById.get(opp.AccountId);
      events.add(
        new Deal_Closed__e(
          Opportunity_Id__c = opp.Id,
          Account_Id__c = opp.AccountId,
          ARR__c = opp.ARR__c,
          // Transition timestamp — NOT opp.CloseDate, which is the
          // business close-of-deal date and can be backdated/future-dated.
          // The event is about the moment the Stage flipped to Closed Won.
          Closed_Date__c = closedAt,
          Sales_Motion__c = opp.Sales_Motion__c,
          // Segment value only (e.g. "Commercial"), not the combined
          // "Region - Segment" string from Territory_Segment__c.
          // Subscribers route on segment tokens.
          Segment__c = acct == null ? null : acct.Customer_Segment__c
        )
      );
    }
    lastDealClosedEvents = events;
    lastDealClosedPublishResults = simulatePublishFailureForTest
      ? null
      : EventBus.publish(events);

    surfacePublishFailures(opps, lastDealClosedPublishResults);

    // Test hook: when the simulate flag is set we synthesise an addError
    // on each opp so the test can assert the rollback path without
    // needing to actually fail an EventBus enqueue (which is hard to
    // force in Apex tests).
    if (simulatePublishFailureForTest) {
      for (Opportunity opp : opps) {
        opp.addError(
          'Failed to publish Deal_Closed__e: simulated test failure'
        );
      }
    }
  }

  /**
   * If any Deal_Closed__e publish failed to enqueue, surface the error on
   * the corresponding Opportunity. addError in afterUpdate context rolls
   * back the whole transaction — Closed Won + Task + provisioning signal
   * are atomic from the subscriber's perspective.: previously
   * the SaveResults were captured but never checked, so a failed publish
   * silently let the transaction commit with no downstream signal.
   */
  private static void surfacePublishFailures(
    List<Opportunity> opps,
    List<Database.SaveResult> results
  ) {
    if (results == null) {
      return;
    }
    for (Integer i = 0; i < results.size() && i < opps.size(); i++) {
      Database.SaveResult sr = results[i];
      if (sr.isSuccess()) {
        continue;
      }
      String msg = sr.getErrors().isEmpty()
        ? 'unknown EventBus failure'
        : sr.getErrors()[0].getMessage();
      opps[i].addError('Failed to publish Deal_Closed__e: ' + msg);
    }
  }
}
