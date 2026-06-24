/**
 * CaseTriggerHandler — Northstar Case behaviors
 * (Case).
 *
 * Three behaviors:
 *   1. afterInsert — Provisioning-exception integrity. A Case with
 *      Case_Category__c = 'Provisioning' is meant to carry the Order whose
 *      provisioning produced it (Related_Order__c). If one is inserted
 *      without that link, we append a soft-error note to Description so the
 *      Provisioning Exceptions queue can see the gap, rather than blocking
 *      the insert (the queue owns triage). The note write is a second-pass
 *      self-update guarded by TriggerHandler.bypass so it does not re-enter.
 *   2. afterUpdate — Renewal-risk escalation. When a Case transitions INTO
 *      High/Critical Renewal_Risk_Level__c, stamp Escalated_To_Renewal_Queue__c
 *      + Escalated_At__c, publish Renewal_Risk_Raised__e, and create a
 *      high-priority escalation Task on the Case so the Renewal Risk Queue /
 * downstream automation (flow 9, Phase 12) can react.
 * Owner reassignment is NOT done here — assignment rules own
 * that; email alerts belong to the approval processes. The
 *      escalation Task used to be created by the Case_After_Save_Renewal_Risk_
 *      Escalation flow, but that flow's "just entered escalation" gate raced
 *      this handler's same-transaction flag stamp and the Task was silently
 * skipped. Ownership of the escalation now lives entirely
 *      this handler; the flow is deactivated.
 * 3. afterInsert / afterUpdate — Routing_Reason__c audit stamp.
 *      After the Case AssignmentRule fires, the Case's OwnerId
 *      reflects the queue it was routed to. We resolve OwnerId → Queue
 *      DeveloperName → Case_Routing_Reason__mdt row and stamp the reason text
 *      onto Routing_Reason__c via the same bypass-guarded second-pass update.
 * This is the Case mirror of the Lead pattern; was
 *      asked to build it but shipped without it, leaving the matching-rule
 * audit trail unbuilt until. The MDT is the single source of reason
 *      text; the AssignmentRule is the single source of routing CRITERIA.
 *
 * Recursion: control is transition
 * idempotency, NOT setMaxLoopCount. The escalation fires only on the edge
 * INTO High/Critical (Trigger.oldMap comparison) and is further guarded by
 * the idempotent Escalated_To_Renewal_Queue__c flag, so re-saving an
 * already-escalated Case is a no-op. Both second-pass self-updates wrap the
 * DML in TriggerHandler.bypass('CaseTriggerHandler') so the re-entrant
 * trigger run is short-circuited before it does any work — the issue's
 * suggested setMaxLoopCount(1) is deliberately not used because it caps
 * across the whole transaction (same rationale the sibling handlers and
 * record).
 */
public with sharing class CaseTriggerHandler extends TriggerHandler {
  @TestVisible
  private static final String HANDLER_NAME = 'CaseTriggerHandler';
  @TestVisible
  private static final String CATEGORY_PROVISIONING = 'Provisioning';
  @TestVisible
  private static final String CATEGORY_RENEWAL = 'Renewal Risk';
  @TestVisible
  private static final String RISK_HIGH = 'High';
  @TestVisible
  private static final String RISK_CRITICAL = 'Critical';
  @TestVisible
  private static final Set<String> ESCALATING_RISK_LEVELS = new Set<String>{
    RISK_HIGH,
    RISK_CRITICAL
  };

  // Escalation Task (moved from the Case_After_Save_Renewal_Risk_Escalation
  // flow). {0} = the risk level.
  @TestVisible
  private static final String ESCALATION_TASK_SUBJECT_FORMAT = 'Renewal risk escalated ({0}) - review account';
  @TestVisible
  private static final String TASK_PRIORITY_HIGH = 'High';
  @TestVisible
  private static final String TASK_STATUS_NOT_STARTED = 'Not Started';
  // User Ids start with 005; the Renewal Risk queue owns Cases but not Tasks,
  // so a queue-owned Case's escalation Task falls back to the running user
  // (mirrors the retired flow's EscalationOwnerId formula).
  @TestVisible
  private static final String USER_ID_PREFIX = '005';

  // Soft-error note stamped on a Provisioning Case that arrives unlinked.
  @TestVisible
  private static final String MISSING_ORDER_NOTE = '[Provisioning] Related Order is not set — the Provisioning Exceptions queue must link the source Order before triage.';

  // Captures the last publish for assertions without standing up a subscriber
  // (mirrors ProvisioningService).
  @TestVisible
  private static List<Renewal_Risk_Raised__e> lastEvents;
  @TestVisible
  private static List<Database.SaveResult> lastPublishResults;
  // Captures the last escalation Task insert for assertions.
  @TestVisible
  private static List<Task> lastEscalationTasks;

  // Routing_Reason__c audit stamp -----------------------------
  // Queues are Groups with Type='Queue'; their Ids start with 00G. A Case whose
  // OwnerId starts with 00G was routed to a queue (by the AssignmentRule or a
  // manual reassignment); a 005-prefixed OwnerId is a User and is left alone so
  // the historical routing reason survives.
  @TestVisible
  private static final String QUEUE_ID_PREFIX = '00G';

  // Visible-by-design fallback when a routed Case lands in a queue that has no
  // Case_Routing_Reason__mdt row — surfaces a deploy-time gap on the record
  // itself rather than leaving Routing_Reason__c silently empty.
  @TestVisible
  private static final String UNMAPPED_QUEUE_REASON_FORMAT = 'Routed to {0} (no Case_Routing_Reason__mdt row — add one)';

  // Lazy-loaded MDT cache, keyed by Queue_Developer_Name__c. Static so a single
  // trigger transaction pays for at most one query.
  private static Map<String, Case_Routing_Reason__mdt> reasonByQueueCache;

  // ---------------------------------------------------------------------------
  // Context entry points
  // ---------------------------------------------------------------------------

  public override void afterInsert() {
    flagProvisioningCasesMissingOrder((List<Case>) Trigger.new);
    stampRoutingReason((List<Case>) Trigger.new, null);
  }

  public override void afterUpdate() {
    escalateRenewalRisk(
      (List<Case>) Trigger.new,
      (Map<Id, Case>) Trigger.oldMap
    );
    stampRoutingReason(
      (List<Case>) Trigger.new,
      (Map<Id, Case>) Trigger.oldMap
    );
  }

  // ---------------------------------------------------------------------------
  // Behavior 1 — Provisioning-exception integrity
  // ---------------------------------------------------------------------------

  private static void flagProvisioningCasesMissingOrder(List<Case> inserted) {
    List<Case> toNote = new List<Case>();
    for (Case c : inserted) {
      if (
        c.Case_Category__c == CATEGORY_PROVISIONING &&
        c.Related_Order__c == null
      ) {
        toNote.add(
          new Case(Id = c.Id, Description = appendNote(c.Description))
        );
      }
    }
    selfUpdate(toNote);
  }

  /**
   * Append the soft-error note to existing Description content, if any,
   * keeping the result within the Description field length. If appending would
   * overflow, the prior description is truncated so the full note survives —
   * the note is the actionable triage signal. This matters because the note is
   * written by a second-pass all-or-none update from afterInsert: a
   * STRING_TOO_LONG failure there would roll back the original Case insert
   * turning a non-blocking annotation into lost data.
   */
  private static String appendNote(String existing) {
    if (String.isBlank(existing)) {
      return MISSING_ORDER_NOTE;
    }
    String combined = existing + '\n\n' + MISSING_ORDER_NOTE;
    Integer maxLen = Case.Description.getDescribe().getLength();
    if (combined.length() <= maxLen) {
      return combined;
    }
    Integer room = maxLen - MISSING_ORDER_NOTE.length() - 2; // 2 = '\n\n'
    return room <= 0
      ? MISSING_ORDER_NOTE.left(maxLen)
      : existing.left(room) + '\n\n' + MISSING_ORDER_NOTE;
  }

  // ---------------------------------------------------------------------------
  // Behavior 2 — Renewal-risk escalation
  // ---------------------------------------------------------------------------

  private static void escalateRenewalRisk(
    List<Case> incoming,
    Map<Id, Case> priors
  ) {
    List<Case> toEscalate = new List<Case>();
    List<Renewal_Risk_Raised__e> events = new List<Renewal_Risk_Raised__e>();
    List<Task> escalationTasks = new List<Task>();

    for (Case c : incoming) {
      Case prior = priors.get(c.Id);
      if (!justEnteredEscalation(c, prior)) {
        continue;
      }
      toEscalate.add(
        new Case(
          Id = c.Id,
          Escalated_To_Renewal_Queue__c = true,
          Escalated_At__c = System.now()
        )
      );
      events.add(
        new Renewal_Risk_Raised__e(
          Account_Id__c = c.AccountId,
          Contract_Id__c = c.Related_Contract__c,
          Risk_Level__c = c.Renewal_Risk_Level__c
        )
      );
      escalationTasks.add(buildEscalationTask(c));
    }

    selfUpdate(toEscalate);
    publishEvents(events);
    createEscalationTasks(escalationTasks);
  }

  /**
   * Build the high-priority escalation Task for a newly-escalating Case,
   * replicating the retired Case_After_Save_Renewal_Risk_Escalation flow: the
   * Task is related to the Case (WhatId) and owned by the Case owner when that
   * is a User, else by the running user (the Renewal Risk queue owns the Case,
   * not Tasks).
   */
  private static Task buildEscalationTask(Case c) {
    Boolean caseOwnedByUser =
      c.OwnerId != null && String.valueOf(c.OwnerId).startsWith(USER_ID_PREFIX);
    return new Task(
      WhatId = c.Id,
      OwnerId = caseOwnedByUser ? c.OwnerId : UserInfo.getUserId(),
      Subject = String.format(
        ESCALATION_TASK_SUBJECT_FORMAT,
        new List<String>{ c.Renewal_Risk_Level__c }
      ),
      Priority = TASK_PRIORITY_HIGH,
      Status = TASK_STATUS_NOT_STARTED,
      ActivityDate = Date.today()
    );
  }

  /**
   * Insert the escalation Tasks log-and-continue (Database.insert allOrNone
   * = false): the Case escalation has already committed via selfUpdate, so a
   * Task failure must not roll it back — same contract as publishEvents.
   */
  private static void createEscalationTasks(List<Task> tasks) {
    if (tasks.isEmpty()) {
      return;
    }
    lastEscalationTasks = tasks;
    List<Database.SaveResult> results = Database.insert(tasks, false);
    for (Database.SaveResult sr : results) {
      if (sr.isSuccess()) {
        continue;
      }
      for (Database.Error err : sr.getErrors()) {
        System.debug(
          LoggingLevel.ERROR,
          'Renewal-risk escalation Task insert failed: ' + err.getMessage()
        );
      }
    }
  }

  /**
   * True when a Case transitions INTO the "Renewal Risk case at an escalating
   * risk level" state and has not already been escalated. The combined
   * (category + risk) edge means escalation fires both when the risk rises to
   * High/Critical on an existing Renewal Risk case AND when an already-High
   * case is reclassified into Case_Category__c = 'Renewal Risk' — but never for
   * a non-Renewal case whose risk picklist happens to be populated, and never
   * twice for a steady-state escalating case. The flag guard additionally
   * covers a case re-raised to High after a manual reset.
   */
  private static Boolean justEnteredEscalation(Case current, Case prior) {
    if (current.Escalated_To_Renewal_Queue__c == true) {
      return false;
    }
    Boolean nowEscalating = isRenewalRiskAtEscalatingLevel(current);
    Boolean wasEscalating =
      prior != null && isRenewalRiskAtEscalatingLevel(prior);
    return nowEscalating && !wasEscalating;
  }

  /** A Renewal Risk Case currently sitting at a High/Critical risk level. */
  private static Boolean isRenewalRiskAtEscalatingLevel(Case c) {
    return c.Case_Category__c == CATEGORY_RENEWAL &&
      ESCALATING_RISK_LEVELS.contains(c.Renewal_Risk_Level__c);
  }

  // ---------------------------------------------------------------------------
  // Behavior 3 — Routing_Reason__c audit stamp via MDT lookup
  // ---------------------------------------------------------------------------

  /**
   * Stamp Routing_Reason__c from Case_Routing_Reason__mdt based on the Case's
   * current queue owner. Runs in the after-context for both insert and update:
   * the AssignmentRule fires before the after-trigger, so OwnerId here reflects
   * the queue the Case was routed to. The write is a bypass-guarded second-pass
   * update (selfUpdate), so it never re-enters this handler — no setMaxLoopCount
   * needed (same recursion model as the other two behaviors).
   *
   * `priors` is null on insert and Trigger.oldMap on update. On update we only
   * (re)stamp Cases whose OwnerId actually changed to a queue, so an ordinary
   * field edit on an already-routed Case does no work. A Case owned by a User
   * (manual reassignment away from a queue) is left untouched so the historical
   * routing reason survives.
   *
   * Bulk-safe: one SOQL resolves every queue Id in the batch to its
   * DeveloperName, then one cached MDT lookup per record, then a single update.
   */
  private void stampRoutingReason(List<Case> incoming, Map<Id, Case> priors) {
    Set<Id> queueIdsNeeded = new Set<Id>();
    for (Case c : incoming) {
      if (needsStamp(c, priors)) {
        queueIdsNeeded.add(c.OwnerId);
      }
    }
    if (queueIdsNeeded.isEmpty()) {
      return;
    }
    Map<Id, String> devNameByQueueId = queueDeveloperNames(queueIdsNeeded);

    List<Case> toUpdate = new List<Case>();
    for (Case c : incoming) {
      if (!needsStamp(c, priors)) {
        continue;
      }
      String expected = reasonForDevName(devNameByQueueId.get(c.OwnerId));
      if (expected != c.Routing_Reason__c) {
        toUpdate.add(new Case(Id = c.Id, Routing_Reason__c = expected));
      }
    }
    selfUpdate(toUpdate);
  }

  /**
   * A Case is eligible for a routing stamp when it is owned by a queue and —
   * on update — its OwnerId just changed (so we do not re-stamp on every edit).
   */
  private static Boolean needsStamp(Case c, Map<Id, Case> priors) {
    if (!isQueueOwner(c.OwnerId)) {
      return false;
    }
    if (priors != null && c.OwnerId == priors.get(c.Id).OwnerId) {
      return false;
    }
    return true;
  }

  private static Boolean isQueueOwner(Id ownerId) {
    return ownerId != null &&
      String.valueOf(ownerId).startsWith(QUEUE_ID_PREFIX);
  }

  /**
   * Resolve a queue DeveloperName to its reason text. Returns a visible
   * "unmapped" sentinel when no Case_Routing_Reason__mdt row exists for the
   * queue, so a missing row surfaces on the record rather than as a blank.
   */
  private static String reasonForDevName(String developerName) {
    if (developerName == null) {
      return null;
    }
    Case_Routing_Reason__mdt row = reasonByQueue().get(developerName);
    if (row != null) {
      return row.Reason__c;
    }
    return String.format(
      UNMAPPED_QUEUE_REASON_FORMAT,
      new List<String>{ developerName }
    );
  }

  /** One SOQL per batch to resolve a set of Queue Group Ids to DeveloperNames. */
  private static Map<Id, String> queueDeveloperNames(Set<Id> queueIds) {
    Map<Id, String> out = new Map<Id, String>();
    for (Group g : [
      SELECT Id, DeveloperName
      FROM Group
      WHERE Id IN :queueIds AND Type = 'Queue'
    ]) {
      out.put(g.Id, g.DeveloperName);
    }
    return out;
  }

  /**
   * Cached MDT lookup, keyed by Queue_Developer_Name__c. Tests can override the
   * cache via setReasonCache to exercise the unmapped-sentinel path without
   * deploying an extra row.
   */
  private static Map<String, Case_Routing_Reason__mdt> reasonByQueue() {
    if (reasonByQueueCache == null) {
      reasonByQueueCache = new Map<String, Case_Routing_Reason__mdt>();
      for (Case_Routing_Reason__mdt row : [
        SELECT Queue_Developer_Name__c, Reason__c
        FROM Case_Routing_Reason__mdt
      ]) {
        reasonByQueueCache.put(row.Queue_Developer_Name__c, row);
      }
    }
    return reasonByQueueCache;
  }

  @TestVisible
  private static void setReasonCache(
    Map<String, Case_Routing_Reason__mdt> replacement
  ) {
    reasonByQueueCache = replacement;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /**
   * Second-pass update on Case from within a Case trigger. Bypasses this
   * handler for the duration so the re-entrant run() short-circuits before
   * addToLoopCount — no recursion, no setMaxLoopCount needed.
   */
  private static void selfUpdate(List<Case> records) {
    if (records.isEmpty()) {
      return;
    }
    TriggerHandler.bypass(HANDLER_NAME);
    try {
      update records;
    } finally {
      TriggerHandler.clearBypass(HANDLER_NAME);
    }
  }

  private static void publishEvents(List<Renewal_Risk_Raised__e> events) {
    if (events.isEmpty()) {
      return;
    }
    lastEvents = events;
    lastPublishResults = EventBus.publish(events);
    logPublishFailures(lastPublishResults);
  }

  /**
   * Log any failed Renewal_Risk_Raised__e enqueue. Log-and-continue: the Case
   * update has already committed, so a failed publish must not roll it back.
   */
  @TestVisible
  private static void logPublishFailures(List<Database.SaveResult> results) {
    if (results == null) {
      return;
    }
    for (Database.SaveResult sr : results) {
      if (sr.isSuccess()) {
        continue;
      }
      for (Database.Error err : sr.getErrors()) {
        System.debug(
          LoggingLevel.ERROR,
          'Renewal_Risk_Raised__e publish failed: ' + err.getMessage()
        );
      }
    }
  }
}
