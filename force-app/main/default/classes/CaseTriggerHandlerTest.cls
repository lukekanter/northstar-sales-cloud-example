/**
 * CaseTriggerHandlerTest — covers every branch in CaseTriggerHandler:
 *   - Provisioning-exception integrity (afterInsert): missing-order note,
 *     append-to-existing-description, linked-order skip, category guard.
 *   - Renewal-risk escalation (afterUpdate): enters High, enters Critical,
 *     already-escalated no-op, sub-threshold no-op, event field mapping,
 *     and a 200-case bulk transition.
 *
 * Platform-event publishing is asserted via CaseTriggerHandler.lastEvents /
 * lastPublishResults (the same capture pattern ProvisioningService uses), so
 * no subscriber is required.
 */
@IsTest
private class CaseTriggerHandlerTest {
  private static final String CAT_PROVISIONING = 'Provisioning';
  private static final String CAT_RENEWAL = 'Renewal Risk';
  private static final String CAT_SUPPORT = 'Customer Support';

  // ---------------------------------------------------------------------------
  // Behavior 1 — Provisioning-exception integrity (afterInsert)
  // ---------------------------------------------------------------------------

  @IsTest
  static void provisioningCaseMissingOrderGetsNote() {
    Test.startTest();
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_PROVISIONING,
        // Provisioning_Case_Requires_Related_Order VR permits an
        // unlinked Provisioning case only when it documents a failure reason
        // (the provisioning-exception path produces). The soft note still
        // fires because Related_Order__c is null.
        'Provisioning_Failure_Reason__c' => 'Order link pending triage'
      }
    );
    Test.stopTest();

    Case got = reload(c.Id);
    System.assertNotEquals(null, got.Description, 'Note should be stamped.');
    System.assert(
      got.Description.contains(CaseTriggerHandler.MISSING_ORDER_NOTE),
      'Provisioning case without an Order should carry the soft-error note.'
    );
  }

  @IsTest
  static void provisioningCaseMissingOrderAppendsToExistingDescription() {
    Test.startTest();
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_PROVISIONING,
        'Description' => 'Original triage notes.',
        // Documented exception so the VR permits the unlinked case.
        'Provisioning_Failure_Reason__c' => 'Order link pending triage'
      }
    );
    Test.stopTest();

    Case got = reload(c.Id);
    System.assert(
      got.Description.contains('Original triage notes.'),
      'Existing description must be preserved.'
    );
    System.assert(
      got.Description.contains(CaseTriggerHandler.MISSING_ORDER_NOTE),
      'Note must be appended after existing content.'
    );
  }

  @IsTest
  static void nearLimitDescriptionDoesNotOverflowOrRollBack() {
    Integer maxLen = Case.Description.getDescribe().getLength();
    // Description nearly at the field limit; appending the note naively would
    // exceed it and the second-pass update would roll back the insert.
    String huge = 'x'.rightPad(maxLen - 10, 'x');

    Test.startTest();
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_PROVISIONING,
        'Description' => huge,
        // Documented exception so the VR permits the unlinked case.
        'Provisioning_Failure_Reason__c' => 'Order link pending triage'
      }
    );
    Test.stopTest();

    Case got = reload(c.Id);
    System.assertNotEquals(
      null,
      got.Id,
      'The Case insert must survive (no STRING_TOO_LONG rollback).'
    );
    System.assert(
      got.Description.length() <= maxLen,
      'Description must stay within the field length, got ' +
      got.Description.length()
    );
    System.assert(
      got.Description.contains(CaseTriggerHandler.MISSING_ORDER_NOTE),
      'The note must be preserved even when the prior text is truncated.'
    );
  }

  @IsTest
  static void provisioningCaseWithOrderGetsNoNote() {
    Id orderId = insertOrder();

    Test.startTest();
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_PROVISIONING,
        'Related_Order__c' => orderId,
        'Description' => 'Linked.'
      }
    );
    Test.stopTest();

    Case got = reload(c.Id);
    System.assertEquals(
      'Linked.',
      got.Description,
      'A linked provisioning case must not be annotated.'
    );
  }

  @IsTest
  static void nonProvisioningCaseMissingOrderGetsNoNote() {
    Test.startTest();
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_SUPPORT,
        'Description' => 'Support request.'
      }
    );
    Test.stopTest();

    Case got = reload(c.Id);
    System.assertEquals(
      'Support request.',
      got.Description,
      'Non-provisioning cases are out of scope for the order-link check.'
    );
  }

  // ---------------------------------------------------------------------------
  // Behavior 2 — Renewal-risk escalation (afterUpdate)
  // ---------------------------------------------------------------------------

  @IsTest
  static void entersHighEscalatesAndPublishes() {
    Account acct = insertAccount();
    Contract con = insertContract(acct.Id);
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_RENEWAL,
        'AccountId' => acct.Id,
        'Related_Contract__c' => con.Id,
        'Renewal_Risk_Level__c' => 'Low'
      }
    );

    Test.startTest();
    update new Case(Id = c.Id, Renewal_Risk_Level__c = 'High');
    Test.stopTest();

    Case got = reload(c.Id);
    System.assertEquals(
      true,
      got.Escalated_To_Renewal_Queue__c,
      'Entering High must escalate.'
    );
    System.assertNotEquals(
      null,
      got.Escalated_At__c,
      'Escalation timestamp must be stamped.'
    );

    List<Renewal_Risk_Raised__e> events = CaseTriggerHandler.lastEvents;
    System.assertEquals(1, events.size(), 'One risk event expected.');
    System.assertEquals('High', events[0].Risk_Level__c);
    System.assertEquals(acct.Id, events[0].Account_Id__c);
    System.assertEquals(con.Id, events[0].Contract_Id__c);
    System.assert(
      CaseTriggerHandler.lastPublishResults[0].isSuccess(),
      'Publish should succeed.'
    );

    // The escalation Task moved from the flow into the handler.
    List<Task> tasks = [
      SELECT Id, Subject, Priority, Status, WhatId, OwnerId
      FROM Task
      WHERE WhatId = :c.Id
    ];
    System.assertEquals(
      1,
      tasks.size(),
      'Entering High must create exactly one escalation Task on the Case.'
    );
    System.assertEquals(
      'Renewal risk escalated (High) - review account',
      tasks[0].Subject,
      'Escalation Task subject must name the risk level.'
    );
    System.assertEquals('High', tasks[0].Priority);
    System.assertEquals(
      UserInfo.getUserId(),
      tasks[0].OwnerId,
      'A queue-owned Case escalation Task falls back to the running user.'
    );
  }

  @IsTest
  static void entersCriticalEscalates() {
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_RENEWAL,
        'Renewal_Risk_Level__c' => 'Medium'
      }
    );

    Test.startTest();
    update new Case(Id = c.Id, Renewal_Risk_Level__c = 'Critical');
    Test.stopTest();

    Case got = reload(c.Id);
    System.assertEquals(
      true,
      got.Escalated_To_Renewal_Queue__c,
      'Entering Critical must escalate.'
    );
    System.assertEquals(1, CaseTriggerHandler.lastEvents.size());
    System.assertEquals(
      'Critical',
      CaseTriggerHandler.lastEvents[0].Risk_Level__c
    );
  }

  @IsTest
  static void alreadyEscalatedDoesNotRepublish() {
    CaseTriggerHandler.lastEvents = null;
    // Insert already escalated + already High (insert does not escalate).
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_RENEWAL,
        'Renewal_Risk_Level__c' => 'High',
        'Escalated_To_Renewal_Queue__c' => true
      }
    );

    Test.startTest();
    // A subsequent edit that keeps it High must not re-escalate.
    update new Case(Id = c.Id, Subject = 'Re-saved');
    Test.stopTest();

    System.assertEquals(
      null,
      CaseTriggerHandler.lastEvents,
      'An already-escalated case must not publish again.'
    );
  }

  @IsTest
  static void subThresholdTransitionIsNoOp() {
    CaseTriggerHandler.lastEvents = null;
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_RENEWAL,
        'Renewal_Risk_Level__c' => 'Low'
      }
    );

    Test.startTest();
    update new Case(Id = c.Id, Renewal_Risk_Level__c = 'Medium');
    Test.stopTest();

    Case got = reload(c.Id);
    System.assertEquals(
      false,
      got.Escalated_To_Renewal_Queue__c,
      'Low -> Medium is below threshold; no escalation.'
    );
    System.assertEquals(
      null,
      CaseTriggerHandler.lastEvents,
      'No event for a sub-threshold transition.'
    );
  }

  @IsTest
  static void nonRenewalCategoryWithHighRiskIsNotEscalated() {
    CaseTriggerHandler.lastEvents = null;
    // Renewal_Risk_Level__c can be set on any category, but only Renewal Risk
    // cases should escalate to the renewal queue.
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_SUPPORT,
        'Renewal_Risk_Level__c' => 'Low'
      }
    );

    Test.startTest();
    update new Case(Id = c.Id, Renewal_Risk_Level__c = 'Critical');
    Test.stopTest();

    Case got = reload(c.Id);
    System.assertEquals(
      false,
      got.Escalated_To_Renewal_Queue__c,
      'A non-Renewal-Risk case must not be escalated even at Critical risk.'
    );
    System.assertEquals(
      null,
      CaseTriggerHandler.lastEvents,
      'No renewal event for a non-Renewal-Risk case.'
    );
  }

  @IsTest
  static void reclassifyIntoRenewalRiskAtHighEscalates() {
    CaseTriggerHandler.lastEvents = null;
    // Existing non-Renewal case that is already High risk (insert does not
    // escalate). Reclassifying it INTO Renewal Risk is the escalation edge,
    // even though the risk value itself did not change.
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_SUPPORT,
        'Renewal_Risk_Level__c' => 'High'
      }
    );

    Test.startTest();
    update new Case(Id = c.Id, Case_Category__c = CAT_RENEWAL);
    Test.stopTest();

    Case got = reload(c.Id);
    System.assertEquals(
      true,
      got.Escalated_To_Renewal_Queue__c,
      'Reclassifying an already-High case into Renewal Risk must escalate.'
    );
    System.assertEquals(
      1,
      CaseTriggerHandler.lastEvents.size(),
      'One renewal event expected on the category-flip edge.'
    );
  }

  @IsTest
  static void bulkTransitionEscalatesAll() {
    Integer n = 200;
    List<Case> cases = TestDataFactory.buildCases(
      n,
      new Map<String, Object>{
        'Case_Category__c' => CAT_RENEWAL,
        'Renewal_Risk_Level__c' => 'Low'
      }
    );
    insert cases;

    List<Case> updates = new List<Case>();
    for (Case c : cases) {
      updates.add(new Case(Id = c.Id, Renewal_Risk_Level__c = 'High'));
    }

    Test.startTest();
    update updates;
    Test.stopTest();

    Integer escalated = [
      SELECT COUNT()
      FROM Case
      WHERE Id IN :cases AND Escalated_To_Renewal_Queue__c = TRUE
    ];
    System.assertEquals(n, escalated, 'All cases should escalate.');
    System.assertEquals(
      n,
      CaseTriggerHandler.lastEvents.size(),
      'One event per escalated case.'
    );
  }

  // ---------------------------------------------------------------------------
  // Behavior 3 — Routing_Reason__c audit stamp
  // ---------------------------------------------------------------------------

  @IsTest
  static void queueOwnedCaseGetsRoutingReasonFromMdt() {
    // Inject a deterministic MDT cache so the assertion does not depend on the
    // deployed Case_Routing_Reason__mdt rows (mirrors the Lead test mechanic).
    Id queueId = queueId('Provisioning_Exceptions_Queue');
    CaseTriggerHandler.setReasonCache(
      new Map<String, Case_Routing_Reason__mdt>{
        'Provisioning_Exceptions_Queue' => new Case_Routing_Reason__mdt(
          Queue_Developer_Name__c = 'Provisioning_Exceptions_Queue',
          Reason__c = 'Injected provisioning reason'
        )
      }
    );

    Test.startTest();
    // OwnerId pre-set to the queue isolates the stamp from AssignmentRule
    // firing (Apex DML does not fire AR without DmlOptions). Category is
    // Customer Support so the provisioning-note behavior stays out of the way.
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_SUPPORT,
        'OwnerId' => queueId
      }
    );
    Test.stopTest();

    System.assertEquals(
      'Injected provisioning reason',
      reloadRouting(c.Id).Routing_Reason__c,
      'A queue-owned Case must be stamped from its Case_Routing_Reason__mdt row.'
    );
  }

  @IsTest
  static void billingCaseResolvesDeployedFinanceSupportRow() {
    // No cache injection — exercises the real deployed Finance_Support_Queue
    // Group + Case_Routing_Reason.Finance_Support record end to end.
    Id queueId = queueId('Finance_Support_Queue');

    Test.startTest();
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => 'Billing',
        'OwnerId' => queueId
      }
    );
    Test.stopTest();

    System.assertEquals(
      'Billing category — routed to Finance Support Queue by Case.assignmentRules.',
      reloadRouting(c.Id).Routing_Reason__c,
      'The deployed Finance_Support MDT row must resolve for a Billing case.'
    );
  }

  @IsTest
  static void unmappedQueueGetsVisibleSentinel() {
    // Empty cache → the queue has no MDT row → the sentinel surfaces the gap.
    Id queueId = queueId('Provisioning_Exceptions_Queue');
    CaseTriggerHandler.setReasonCache(
      new Map<String, Case_Routing_Reason__mdt>()
    );

    Test.startTest();
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_SUPPORT,
        'OwnerId' => queueId
      }
    );
    Test.stopTest();

    String stamped = reloadRouting(c.Id).Routing_Reason__c;
    System.assert(
      stamped != null &&
      stamped.contains('Provisioning_Exceptions_Queue') &&
      stamped.contains('no Case_Routing_Reason__mdt row'),
      'An unmapped queue must stamp the visible sentinel, got: ' + stamped
    );
  }

  @IsTest
  static void userOwnedCaseIsNotStamped() {
    Test.startTest();
    // Default owner is the running user (a 005 Id), not a queue.
    Case c = insertCase(
      new Map<String, Object>{ 'Case_Category__c' => CAT_SUPPORT }
    );
    Test.stopTest();

    System.assertEquals(
      null,
      reloadRouting(c.Id).Routing_Reason__c,
      'A user-owned Case must not be stamped — no queue routing happened.'
    );
  }

  @IsTest
  static void reassignToQueueOnUpdateStampsReason() {
    CaseTriggerHandler.setReasonCache(
      new Map<String, Case_Routing_Reason__mdt>{
        'Renewal_Risk_Queue' => new Case_Routing_Reason__mdt(
          Queue_Developer_Name__c = 'Renewal_Risk_Queue',
          Reason__c = 'Injected renewal reason'
        )
      }
    );
    // Insert user-owned (no stamp), then reassign to a queue on update.
    Case c = insertCase(
      new Map<String, Object>{ 'Case_Category__c' => CAT_SUPPORT }
    );
    System.assertEquals(
      null,
      reloadRouting(c.Id).Routing_Reason__c,
      'Precondition: user-owned case starts unstamped.'
    );

    Test.startTest();
    update new Case(Id = c.Id, OwnerId = queueId('Renewal_Risk_Queue'));
    Test.stopTest();

    System.assertEquals(
      'Injected renewal reason',
      reloadRouting(c.Id).Routing_Reason__c,
      'Reassigning a Case to a queue on update must (re)stamp Routing_Reason__c.'
    );
  }

  @IsTest
  static void editOnAlreadyRoutedCaseDoesNotRestamp() {
    Id queueId = queueId('Provisioning_Exceptions_Queue');
    CaseTriggerHandler.setReasonCache(
      new Map<String, Case_Routing_Reason__mdt>{
        'Provisioning_Exceptions_Queue' => new Case_Routing_Reason__mdt(
          Queue_Developer_Name__c = 'Provisioning_Exceptions_Queue',
          Reason__c = 'Original reason'
        )
      }
    );
    Case c = insertCase(
      new Map<String, Object>{
        'Case_Category__c' => CAT_SUPPORT,
        'OwnerId' => queueId
      }
    );

    Test.startTest();
    // An edit that does NOT change OwnerId must not re-run the stamp, even if
    // the MDT text has since changed — the stamp only fires on a routing edge.
    CaseTriggerHandler.setReasonCache(
      new Map<String, Case_Routing_Reason__mdt>{
        'Provisioning_Exceptions_Queue' => new Case_Routing_Reason__mdt(
          Queue_Developer_Name__c = 'Provisioning_Exceptions_Queue',
          Reason__c = 'Changed reason'
        )
      }
    );
    update new Case(Id = c.Id, Subject = 'Edited subject');
    Test.stopTest();

    System.assertEquals(
      'Original reason',
      reloadRouting(c.Id).Routing_Reason__c,
      'A non-owner edit must not re-stamp an already-routed Case.'
    );
  }

  @IsTest
  static void bulkQueueOwnedInsertStampsAll() {
    Integer n = 200;
    Id queueId = queueId('Provisioning_Exceptions_Queue');
    CaseTriggerHandler.setReasonCache(
      new Map<String, Case_Routing_Reason__mdt>{
        'Provisioning_Exceptions_Queue' => new Case_Routing_Reason__mdt(
          Queue_Developer_Name__c = 'Provisioning_Exceptions_Queue',
          Reason__c = 'Bulk reason'
        )
      }
    );
    List<Case> cases = TestDataFactory.buildCases(
      n,
      new Map<String, Object>{
        'Case_Category__c' => CAT_SUPPORT,
        'OwnerId' => queueId
      }
    );

    Test.startTest();
    insert cases;
    Test.stopTest();

    Integer stamped = [
      SELECT COUNT()
      FROM Case
      WHERE Id IN :cases AND Routing_Reason__c = 'Bulk reason'
    ];
    System.assertEquals(n, stamped, 'Every queue-owned case must be stamped.');
  }

  @IsTest
  static void nativeAssignmentRuleRoutedCaseGetsStamped() {
    // Regression guard for the on: a Case routed by the NATIVE
    // assignment rule (not a pre-set OwnerId) must still be stamped. Uses
    // DMLOptions.useDefaultRule so the active Case rule fires during insert.
    // The real UI/REST production path was ALSO verified out-of-band against
    // northstar-dev (a Sforce-Auto-Assign REST insert produced
    // OwnerId=Finance Support Queue + the stamped reason) — see the
    // thread; this test locks the behavior into CI.
    Case c = TestDataFactory.buildCases(
      1,
      new Map<String, Object>{ 'Case_Category__c' => 'Billing' }
    )[0];
    Database.DMLOptions dmo = new Database.DMLOptions();
    dmo.assignmentRuleHeader.useDefaultRule = true;
    c.setOptions(dmo);

    Test.startTest();
    insert c;
    Test.stopTest();

    Case got = reloadRouting(c.Id);
    System.assert(
      String.valueOf(got.OwnerId).startsWith('00G'),
      'The native assignment rule should route the Billing case to a queue, ' +
      'owner=' + got.OwnerId
    );
    System.assertEquals(
      'Billing category — routed to Finance Support Queue by Case.assignmentRules.',
      got.Routing_Reason__c,
      'A natively-routed Billing case must be stamped from its MDT row.'
    );
  }

  // ---------------------------------------------------------------------------
  // logPublishFailures guard
  // ---------------------------------------------------------------------------

  @IsTest
  static void logPublishFailuresToleratesNull() {
    Test.startTest();
    CaseTriggerHandler.logPublishFailures(null);
    Test.stopTest();
    System.assert(true, 'Null results must not throw.');
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private static Case insertCase(Map<String, Object> overrides) {
    Case c = TestDataFactory.buildCases(1, overrides)[0];
    insert c;
    return c;
  }

  private static Account insertAccount() {
    Account a = TestDataFactory.buildAccounts(1)[0];
    insert a;
    return a;
  }

  private static Contract insertContract(Id accountId) {
    Contract con = TestDataFactory.buildContracts(
      1,
      new Map<String, Object>{ 'AccountId' => accountId }
    )[0];
    insert con;
    return con;
  }

  private static Id insertOrder() {
    Account a = insertAccount();
    Order o = TestDataFactory.buildOrders(
      1,
      new Map<String, Object>{ 'AccountId' => a.Id }
    )[0];
    insert o;
    return o.Id;
  }

  private static Case reload(Id caseId) {
    return [
      SELECT
        Description,
        Escalated_To_Renewal_Queue__c,
        Escalated_At__c,
        Renewal_Risk_Level__c
      FROM Case
      WHERE Id = :caseId
    ];
  }

  private static Case reloadRouting(Id caseId) {
    return [SELECT OwnerId, Routing_Reason__c FROM Case WHERE Id = :caseId];
  }

  /** Resolve a Queue's Group Id by DeveloperName (queues are Type='Queue'). */
  private static Id queueId(String developerName) {
    return [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = :developerName
      LIMIT 1
    ]
    .Id;
  }
}
