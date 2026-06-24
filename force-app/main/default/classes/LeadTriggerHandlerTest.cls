/**
 * LeadTriggerHandlerTest — covers every branch in LeadTriggerHandler.
 *
 * Stamping tests pre-assign OwnerId to a Queue Group Id and override the
 * MDT cache via the @TestVisible setReasonCache hook. That isolates the
 * handler's stamp logic from (a) the AssignmentRule firing — AR doesn't
 * fire on Apex DML without DmlOptions opt-in — and (b) the actual deployed
 * Lead_Routing_Reason__mdt rows, so the test stays deterministic across
 * orgs where admins may have edited the MDT.
 */
@IsTest
private class LeadTriggerHandlerTest {
  // -------------------------------------------------------------------------
  // Behavior 3 — Routing_Reason__c stamp via Queue → MDT lookup
  // -------------------------------------------------------------------------

  @IsTest
  static void insertWithQueueOwnerStampsConfiguredReason() {
    seedReasonCache();
    Id partnerQueueId = queueId('Partner_Referral_Queue');

    Lead l = buildBase();
    l.OwnerId = partnerQueueId;
    insert l;

    Lead got = [SELECT Routing_Reason__c FROM Lead WHERE Id = :l.Id];
    System.assertEquals(
      'Partner referral → Partner Referral Queue',
      got.Routing_Reason__c
    );
  }

  @IsTest
  static void insertWithInboundQueueStampsCoarseReason() {
    seedReasonCache();
    Id inboundQueueId = queueId('Inbound_SDR_Queue');

    Lead l = buildBase();
    // Whatever criterion led the AR here — Enterprise, Commercial+NA-West,
    // or catch-all — the stamp text is by-queue, not by-criterion.
    l.Customer_Segment__c = 'Enterprise';
    l.OwnerId = inboundQueueId;
    insert l;

    Lead got = [SELECT Routing_Reason__c FROM Lead WHERE Id = :l.Id];
    System.assertEquals('Inbound SDR routing', got.Routing_Reason__c);
  }

  @IsTest
  static void insertWithUserOwnerDoesNotStamp() {
    seedReasonCache();

    Lead l = buildBase();
    // Default factory leaves OwnerId as the running user — i.e. a User Id.
    insert l;

    Lead got = [SELECT Routing_Reason__c FROM Lead WHERE Id = :l.Id];
    System.assertEquals(
      null,
      got.Routing_Reason__c,
      'User-owned lead must not be stamped — no auto-routing occurred.'
    );
  }

  @IsTest
  static void updateChangingOwnerToQueueRestamps() {
    seedReasonCache();

    Lead l = buildBase();
    insert l;
    System.assertEquals(
      null,
      [SELECT Routing_Reason__c FROM Lead WHERE Id = :l.Id].Routing_Reason__c
    );

    l.OwnerId = queueId('Partner_Referral_Queue');
    update l;

    Lead got = [SELECT Routing_Reason__c FROM Lead WHERE Id = :l.Id];
    System.assert(
      got.Routing_Reason__c.startsWith('Partner referral'),
      'Expected partner reason but got: ' + got.Routing_Reason__c
    );
  }

  @IsTest
  static void updateWithUnrelatedFieldChangeDoesNotRestamp() {
    seedReasonCache();
    Id inboundQueueId = queueId('Inbound_SDR_Queue');

    Lead l = buildBase();
    l.OwnerId = inboundQueueId;
    insert l;
    String originalReason = [
      SELECT Routing_Reason__c
      FROM Lead
      WHERE Id = :l.Id
    ]
    .Routing_Reason__c;

    // Manual edit of an unrelated field — OwnerId unchanged, reason
    // must be preserved.
    l.Description = 'touched';
    update l;

    Lead got = [SELECT Routing_Reason__c FROM Lead WHERE Id = :l.Id];
    System.assertEquals(originalReason, got.Routing_Reason__c);
  }

  @IsTest
  static void unmappedQueueStampsVisibleSentinel() {
    // Stand up a queue that has no Lead_Routing_Reason__mdt row. Group
    // and QueueSObject are "setup" objects; Lead is a "non-setup"
    // object. Inserting both in the same transaction triggers
    // MIXED_DML_OPERATION when this test is run via `sf apex run test`
    // (the deploy-time test framework relaxes the rule, but the async
    // runner does not). System.runAs isolates the setup DML so the
    // subsequent Lead insert is treated as a separate transaction.
    //
    // Group DeveloperName rules: alphanumeric + underscores, must start
    // with a letter, no double underscores, no trailing underscore.
    // Suffix from the timestamp digits satisfies uniqueness without
    // tripping those rules.
    String suffix = String.valueOf(DateTime.now().getTime());
    Group orphanQueue = new Group(
      Name = 'Orphan Test Queue',
      DeveloperName = 'Orphan_Test_Queue_' + suffix,
      Type = 'Queue'
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert orphanQueue;
      insert new QueueSObject(QueueId = orphanQueue.Id, SObjectType = 'Lead');
    }

    seedReasonCache();
    // Don't add a row for the orphan queue — we want the sentinel.

    Lead l = buildBase();
    l.OwnerId = orphanQueue.Id;
    insert l;

    Lead got = [SELECT Routing_Reason__c FROM Lead WHERE Id = :l.Id];
    System.assert(
      got.Routing_Reason__c.contains('no Lead_Routing_Reason__mdt row'),
      'Unmapped queue should stamp a visible sentinel, got: ' +
      got.Routing_Reason__c
    );
  }

  // -------------------------------------------------------------------------
  // Behavior 1 — Lead_Source_Detail__c normalization
  // -------------------------------------------------------------------------

  @IsTest
  static void normalizeFillsDetailFromStandardSource() {
    Lead l = buildBase();
    l.LeadSource = 'Partner Referral';
    l.Lead_Source_Detail__c = null;
    insert l;

    Lead got = [
      SELECT Lead_Source_Detail__c
      FROM Lead
      WHERE Id = :l.Id
    ];
    System.assertEquals('Partner Referral', got.Lead_Source_Detail__c);
  }

  @IsTest
  static void normalizeRespectsExistingDetail() {
    Lead l = buildBase();
    l.LeadSource = 'Partner Referral';
    l.Lead_Source_Detail__c = 'Inbound Form';
    insert l;

    Lead got = [
      SELECT Lead_Source_Detail__c
      FROM Lead
      WHERE Id = :l.Id
    ];
    System.assertEquals('Inbound Form', got.Lead_Source_Detail__c);
  }

  // -------------------------------------------------------------------------
  // Behavior 2 — Region__c derivation
  // -------------------------------------------------------------------------

  // Note: a "no location hint at all" trigger-path test isn't reachable in
  // this org. State/Country picklists are enabled, which auto-defaults
  // `CountryCode` on insert, so every DML-inserted lead has at least a
  // country and falls into the US → NA Central branch. The null/null
  // branch is covered by `inferRegionStateOnlyReturnsNullWithoutCountryGate`
  // directly.

  @IsTest
  static void derivationLeavesExistingRegion() {
    Lead l = buildBase();
    l.Region__c = 'APAC';
    insert l;

    Lead got = [SELECT Region__c FROM Lead WHERE Id = :l.Id];
    System.assertEquals('APAC', got.Region__c);
  }

  @IsTest
  static void inferRegionUSStateBucketsWithCountryGate() {
    // West / East / Central — all require an explicit US country signal.
    System.assertEquals('NA West', LeadTriggerHandler.inferRegion('CA', 'US'));
    System.assertEquals('NA East', LeadTriggerHandler.inferRegion('NY', 'US'));
    System.assertEquals(
      'NA Central',
      LeadTriggerHandler.inferRegion('MO', 'US')
    );
    System.assertEquals(
      'NA Central',
      LeadTriggerHandler.inferRegion(null, 'United States')
    );
  }

  @IsTest
  static void inferRegionNonUSCountriesIgnoreOverlappingStateCodes() {
    // regression — Australia's StateCode='WA' must NOT collide
    // with US Washington. Country gate forces APAC routing.
    System.assertEquals('APAC', LeadTriggerHandler.inferRegion('WA', 'AU'));
    System.assertEquals('EMEA', LeadTriggerHandler.inferRegion('GE', 'GB'));
  }

  @IsTest
  static void inferRegionTextFallbackUsesStateNames() {
    // regression — orgs without picklists send full state
    // names. The name → code map covers every state.
    System.assertEquals(
      'NA West',
      LeadTriggerHandler.inferRegion('California', 'United States')
    );
    System.assertEquals(
      'NA East',
      LeadTriggerHandler.inferRegion('New York', 'United States')
    );
    System.assertEquals(
      'NA Central',
      LeadTriggerHandler.inferRegion('Missouri', 'United States')
    );
  }

  @IsTest
  static void inferRegionIsCaseInsensitive() {
    // regression — `'us'`, `'france'`, lowercase codes must
    // resolve the same as their canonical form.
    System.assertEquals(
      'NA West',
      LeadTriggerHandler.inferRegion('california', 'us')
    );
    System.assertEquals('EMEA', LeadTriggerHandler.inferRegion(null, 'france'));
    System.assertEquals('APAC', LeadTriggerHandler.inferRegion(null, 'japan'));
  }

  @IsTest
  static void inferRegionNonNACountriesByName() {
    System.assertEquals('EMEA', LeadTriggerHandler.inferRegion(null, 'France'));
    System.assertEquals('APAC', LeadTriggerHandler.inferRegion(null, 'Japan'));
    System.assertEquals(
      'LATAM',
      LeadTriggerHandler.inferRegion(null, 'Brazil')
    );
  }

  @IsTest
  static void inferRegionStateOnlyReturnsNullWithoutCountryGate() {
    // Without an explicit country, a US-shaped state code is ambiguous
    // and must not auto-default. demands the country gate.
    System.assertEquals(null, LeadTriggerHandler.inferRegion('CA', null));
    System.assertEquals(null, LeadTriggerHandler.inferRegion('NY', null));
    System.assertEquals(null, LeadTriggerHandler.inferRegion(null, null));
  }

  // -------------------------------------------------------------------------
  // Behavior 4a — high-score inbound Task
  // -------------------------------------------------------------------------

  @IsTest
  static void highScoreInboundCreatesQualificationTaskOnInsert() {
    Lead l = buildBase();
    l.Lead_Score__c = 85;
    l.Lead_Source_Detail__c = 'Inbound Form';
    insert l;

    List<Task> tasks = [
      SELECT
        Subject,
        Lead_Score_At_Creation__c,
        Action_Plan_Source__c,
        Routing_Reason__c
      FROM Task
      WHERE WhoId = :l.Id
    ];
    System.assertEquals(1, tasks.size());
    System.assertEquals(85, tasks[0].Lead_Score_At_Creation__c);
    System.assertEquals(
      'High-Score Inbound Qualification',
      tasks[0].Action_Plan_Source__c
    );
  }

  @IsTest
  static void lowScoreInboundCreatesNoTask() {
    Lead l = buildBase();
    l.Lead_Score__c = 30;
    l.Lead_Source_Detail__c = 'Inbound Form';
    insert l;

    Integer taskCount = [SELECT COUNT() FROM Task WHERE WhoId = :l.Id];
    System.assertEquals(0, taskCount);
  }

  @IsTest
  static void highScoreOutboundCreatesNoTask() {
    Lead l = buildBase();
    l.Lead_Score__c = 99;
    l.Lead_Source_Detail__c = 'Outbound Cold';
    insert l;

    Integer taskCount = [SELECT COUNT() FROM Task WHERE WhoId = :l.Id];
    System.assertEquals(0, taskCount);
  }

  @IsTest
  static void scoreCrossingThresholdOnUpdateFiresTaskOnce() {
    Lead l = buildBase();
    l.Lead_Score__c = 50;
    l.Lead_Source_Detail__c = 'Inbound Form';
    insert l;

    l.Lead_Score__c = 80;
    update l;

    System.assertEquals(1, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id]);

    l.Lead_Score__c = 90;
    update l;

    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id],
      'Already-high lead must not spawn another Task on a further score bump.'
    );
  }

  // -------------------------------------------------------------------------
  // Behavior 4b — Qualified-transition signal Task
  // -------------------------------------------------------------------------

  @IsTest
  static void qualifiedTransitionCreatesSignalTask() {
    Lead l = buildBase();
    l.Lead_Score__c = 30;
    l.Lead_Source_Detail__c = 'Outbound Cold';
    insert l;

    l.Status = 'Qualified';
    update l;

    List<Task> tasks = [
      SELECT Subject, Action_Plan_Source__c
      FROM Task
      WHERE WhoId = :l.Id
    ];
    System.assertEquals(1, tasks.size());
    System.assertEquals(
      'Lead Qualified Signal',
      tasks[0].Action_Plan_Source__c
    );
  }

  @IsTest
  static void insertAtQualifiedDoesNotFireSignal() {
    // Inserting a historical/imported lead already at Status='Qualified'
    // is not a transition — must NOT fire the signal Task.
    Lead l = buildBase();
    l.Lead_Score__c = 30;
    l.Lead_Source_Detail__c = 'Outbound Cold';
    l.Status = 'Qualified';
    insert l;

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Task
        WHERE WhoId = :l.Id AND Action_Plan_Source__c = 'Lead Qualified Signal'
      ]
    );

    // A later unrelated update on the still-Qualified lead must also not fire.
    l.Description = 'touched';
    update l;

    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Task
        WHERE WhoId = :l.Id AND Action_Plan_Source__c = 'Lead Qualified Signal'
      ]
    );
  }

  // -------------------------------------------------------------------------
  // Behavior 4 regressions —
  // -------------------------------------------------------------------------

  @IsTest
  static void reopenedLeadFiresTaskAgain() {
    // Lead arrives high-score inbound but gets disqualified before the
    // task can do its job (closed/disqualified leads don't get the
    // qualification Task). Later, the SDR reopens the lead — the bar
    // is now met again, so the Task must fire. The original idempotency
    // check ignored prior.Status and dropped this.
    Lead l = buildBase();
    l.Lead_Score__c = 85;
    l.Lead_Source_Detail__c = 'Inbound Form';
    l.Status = 'Disqualified';
    insert l;

    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id],
      'Disqualified lead should not have spawned a Task.'
    );

    l.Status = 'Open - Not Contacted';
    update l;

    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id],
      'Reopen from Disqualified must fire the qualification Task.'
    );
  }

  @IsTest
  static void userOwnedLeadPropagatesOwnerToTask() {
    // Task ownership: when the lead is user-owned, the Task should be
    // owned by the same user, not the integration user that performed
    // the DML.
    Lead l = buildBase();
    l.Lead_Score__c = 85;
    l.Lead_Source_Detail__c = 'Inbound Form';
    // buildBase leaves OwnerId default — i.e. the running test user.
    insert l;

    Task t = [SELECT OwnerId FROM Task WHERE WhoId = :l.Id LIMIT 1];
    System.assertEquals(
      [SELECT OwnerId FROM Lead WHERE Id = :l.Id].OwnerId,
      t.OwnerId,
      'Task owner should match the lead owner.'
    );
  }

  @IsTest
  static void queueOwnedLeadDoesNotForceTaskOwner() {
    // Task queues are not enabled in this DE org (lists only
    // Lead and Case as queue-supporting objects). Setting Task.OwnerId
    // to a Queue Group Id would fail INVALID_OWNER. The handler must
    // leave Task.OwnerId default when the lead is queue-owned.
    seedReasonCache();
    Lead l = buildBase();
    l.Lead_Score__c = 85;
    l.Lead_Source_Detail__c = 'Inbound Form';
    l.OwnerId = queueId('Inbound_SDR_Queue');
    insert l;

    Task t = [SELECT OwnerId FROM Task WHERE WhoId = :l.Id LIMIT 1];
    System.assertEquals(
      UserInfo.getUserId(),
      t.OwnerId,
      'Queue-owned leads should not push the queue Id onto Task.OwnerId.'
    );
  }

  // -------------------------------------------------------------------------
  // Framework integration — bypass API + bulk safety
  // -------------------------------------------------------------------------

  @IsTest
  static void bypassedHandlerSkipsAllBehaviors() {
    TriggerHandler.bypass('LeadTriggerHandler');
    try {
      Lead l = buildBase();
      l.LeadSource = 'Partner Referral';
      l.Lead_Source_Detail__c = null;
      l.Lead_Score__c = 99;
      insert l;

      Lead got = [
        SELECT Routing_Reason__c, Lead_Source_Detail__c
        FROM Lead
        WHERE Id = :l.Id
      ];
      System.assertEquals(null, got.Routing_Reason__c);
      System.assertEquals(null, got.Lead_Source_Detail__c);
      System.assertEquals(0, [SELECT COUNT() FROM Task WHERE WhoId = :l.Id]);
    } finally {
      TriggerHandler.clearBypass('LeadTriggerHandler');
    }
  }

  @IsTest
  static void bulkInsertStaysGovernorSafe() {
    seedReasonCache();
    Id inboundQueueId = queueId('Inbound_SDR_Queue');

    List<Lead> leads = TestDataFactory.buildLeads(200);
    for (Lead l : leads) {
      l.Lead_Score__c = 80;
      l.Lead_Source_Detail__c = 'Inbound Form';
      l.OwnerId = inboundQueueId;
    }
    Test.startTest();
    insert leads;
    Test.stopTest();

    System.assertEquals(
      200,
      [SELECT COUNT() FROM Task],
      'Each high-score inbound lead should get exactly one qualification Task.'
    );
    System.assertEquals(
      200,
      [
        SELECT COUNT()
        FROM Lead
        WHERE Routing_Reason__c = 'Inbound SDR routing'
      ]
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private static Lead buildBase() {
    Lead l = TestDataFactory.buildLeads(1)[0];
    l.Region__c = 'NA East';
    l.Customer_Segment__c = 'Commercial';
    l.Lead_Source_Detail__c = 'Inbound Form';
    l.Lead_Score__c = 50;
    l.Status = 'Open - Not Contacted';
    return l;
  }

  /**
   * Pre-load a known MDT cache so the test asserts against fixed reason
   * text — independent of whatever a deploy may have changed in the real
   * customMetadata/*.md-meta.xml records.
   */
  private static void seedReasonCache() {
    Map<String, Lead_Routing_Reason__mdt> cache = new Map<String, Lead_Routing_Reason__mdt>();
    cache.put(
      'Partner_Referral_Queue',
      new Lead_Routing_Reason__mdt(
        Queue_Developer_Name__c = 'Partner_Referral_Queue',
        Reason__c = 'Partner referral → Partner Referral Queue'
      )
    );
    cache.put(
      'Inbound_SDR_Queue',
      new Lead_Routing_Reason__mdt(
        Queue_Developer_Name__c = 'Inbound_SDR_Queue',
        Reason__c = 'Inbound SDR routing'
      )
    );
    LeadTriggerHandler.setReasonCache(cache);
  }

  private static Id queueId(String developerName) {
    return [
      SELECT Id
      FROM Group
      WHERE DeveloperName = :developerName AND Type = 'Queue'
      LIMIT 1
    ]
    .Id;
  }
}
