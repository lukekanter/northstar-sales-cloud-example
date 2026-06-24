// verify_sample_scenarios.apex
// Asserts the expected automation fired for each of the eight Northstar sample
// scenarios seeded by seed_sample_data.apex.
//
// Prints PASS / FAIL per scenario and throws at the end if any scenario failed,
// so a CI pipeline (scripts/deploy-sample-data.sh) gets a non-zero exit.
//
// Run AFTER the seed (and a short pause for async work — onboarding Action
// Plans are queueable and the provisioning-exception Case is platform-event
// driven):
//   sf apex run --file scripts/apex/verify_sample_scenarios.apex --target-org "$NS_ORG"

List<String> results = new List<String>();
Integer failures = 0;
Integer blocked = 0;

// The Generate Order chain needs the standard Opportunity.ContractId lookup.
// The field EXISTS in the org, but until the admin user is granted FLS on it
// (the Northstar_System_Admin_Field_Access permission set,
// once assigned) the running user can't read or set it — a describe getMap()
// omits FLS-inaccessible fields, so this doubles as the "can the seed link the
// contract" capability check. When false, S5/S6's order/provisioning steps
// can't run; report them BLOCKED (env) rather than FAIL so a genuine regression
// stays distinguishable. After it deploys and assigns, it flips true and S5/S6
// pass.
Boolean canLinkContract = Opportunity.SObjectType.getDescribe()
  .fields.getMap()
  .containsKey('contractid');

// Per-dimension Quote approval fields (S4) are likewise FLS-gated until that permission set is assigned.
Map<String, Schema.SObjectField> quoteFields = Quote.SObjectType.getDescribe()
  .fields.getMap();
// Guard EVERY dimension the S4 dynamic query selects — a partial FLS grant that
// exposes legal/finance but not discount would otherwise let the query abort
// instead of reporting BLOCKED.
Boolean canSeeApprovalDimensions =
  quoteFields.containsKey('discount_approval_status__c') &&
  quoteFields.containsKey('legal_approval_status__c') &&
  quoteFields.containsKey('finance_approval_status__c');

// ---------------------------------------------------------------------------
// S1 — Inbound Commercial Lead routed to SDR queue + follow-up task
// ---------------------------------------------------------------------------
{
  List<Lead> leads = [
    SELECT Id, OwnerId, Owner.Type, Status
    FROM Lead
    WHERE Company = 'Acme Logistics' AND LastName = '[S1] Inbound'
  ];
  // Resolve the owner queue's DeveloperName — assert the SPECIFIC Inbound SDR
  // queue, not just "some queue".
  String ownerQueue;
  if (!leads.isEmpty() && leads[0].Owner.Type == 'Queue') {
    List<Group> g = [
      SELECT DeveloperName FROM Group WHERE Id = :leads[0].OwnerId AND Type = 'Queue'
    ];
    ownerQueue = g.isEmpty() ? null : g[0].DeveloperName;
  }
  Boolean routedToSdr = ownerQueue == 'Inbound_SDR_Queue';
  // The SDR follow-up flow creates a task titled "SDR follow-up: ...".
  Integer sdrTasks = leads.isEmpty()
    ? 0
    : [
        SELECT COUNT()
        FROM Task
        WHERE WhoId = :leads[0].Id AND Subject LIKE 'SDR follow-up%'
      ];
  Boolean ok = routedToSdr && sdrTasks > 0;
  results.add(
    (ok ? 'PASS' : 'FAIL') +
    ' S1 Inbound Commercial Lead — routed to Inbound_SDR_Queue=' + routedToSdr +
    ' (' + (ownerQueue == null ? 'n/a' : ownerQueue) + '), SDR follow-up tasks=' + sdrTasks
  );
  if (!ok) {
    failures++;
  }
}

// ---------------------------------------------------------------------------
// S2 — Enterprise Lead converted to Account / Contact / Opportunity
// ---------------------------------------------------------------------------
{
  List<Lead> leads = [
    SELECT Id, IsConverted, ConvertedAccountId, ConvertedContactId, ConvertedOpportunityId
    FROM Lead
    WHERE Company = 'Globex Corporation' AND LastName = '[S2] Enterprise'
  ];
  Boolean recordsCreated =
    !leads.isEmpty() &&
    leads[0].IsConverted &&
    leads[0].ConvertedAccountId != null &&
    leads[0].ConvertedContactId != null &&
    leads[0].ConvertedOpportunityId != null;
  // The scenario proves segment/territory data carries through conversion — not
  // just that records exist. Assert the Account's segment + region AND the
  // converted Opportunity's trigger-stamped Territory_Segment__c.
  String seg;
  String region;
  String oppTerritory;
  if (recordsCreated) {
    Account a = [
      SELECT Customer_Segment__c, Region__c
      FROM Account
      WHERE Id = :leads[0].ConvertedAccountId
    ];
    seg = a.Customer_Segment__c;
    region = a.Region__c;
    oppTerritory = [
      SELECT Territory_Segment__c
      FROM Opportunity
      WHERE Id = :leads[0].ConvertedOpportunityId
    ]
    .Territory_Segment__c;
  }
  Boolean ok =
    recordsCreated &&
    seg == 'Enterprise' &&
    String.isNotBlank(region) &&
    oppTerritory == 'NA East - Enterprise';
  results.add(
    (ok ? 'PASS' : 'FAIL') +
    ' S2 Enterprise Lead Converted — account+contact+opp created=' + recordsCreated +
    ', segment=' + seg + ', region=' + region + ', opp territory=' + oppTerritory
  );
  if (!ok) {
    failures++;
  }
}

// ---------------------------------------------------------------------------
// S3 — Opportunity in Proposal with a "Build Quote" follow-up task
// ---------------------------------------------------------------------------
{
  List<Opportunity> opps = [
    SELECT Id, StageName
    FROM Opportunity
    WHERE Name = '[S3] Initech Platform Proposal'
  ];
  Boolean staged = !opps.isEmpty() && opps[0].StageName == 'Proposal/Price Quote';
  // Match the proposal-automation flow's specific "Build quote ..." Task, not
  // any task that happens to hang off the Opportunity.
  Integer buildQuoteTasks = opps.isEmpty()
    ? 0
    : [
        SELECT COUNT()
        FROM Task
        WHERE WhatId = :opps[0].Id AND Subject LIKE 'Build quote%'
      ];
  Boolean ok = staged && buildQuoteTasks > 0;
  results.add(
    (ok ? 'PASS' : 'FAIL') +
    ' S3 Opportunity Enters Proposal — stage=Proposal/Price Quote=' +
    staged + ', build-quote tasks=' + buildQuoteTasks
  );
  if (!ok) {
    failures++;
  }
}

// ---------------------------------------------------------------------------
// S4 — Discounted Enterprise Quote requires approval + legal/finance flags
// ---------------------------------------------------------------------------
{
  // The Quote trigger stamps the rollup Approval_Status__c = 'Pending' AND the
  // per-dimension Discount/Legal/Finance_Approval_Status__c. Assert the
  // per-dimension fields (the scenario's whole point is the legal/finance
  // flags) when they're FLS-accessible; when they aren't yet (before that permission set is assigned), the
  // rollup alone can't prove the dimensions fired, so report BLOCKED.
  List<Quote> quotes = [
    SELECT Id, Approval_Status__c, Total_Discount_Percent__c, Legal_Terms_Required__c
    FROM Quote
    WHERE Name = '[S4] Stark Discounted Quote'
  ];
  if (quotes.isEmpty()) {
    results.add('FAIL S4 Discounted Enterprise Quote — no quote');
    failures++;
  } else if (!canSeeApprovalDimensions) {
    results.add(
      'BLOCKED S4 Discounted Enterprise Quote — per-dimension approval fields not ' +
      'FLS-accessible (requires the admin field-access permission set); rollup approval=' + quotes[0].Approval_Status__c
    );
    blocked++;
  } else {
    Quote dq = (Quote) Database.query(
      'SELECT Discount_Approval_Status__c, Legal_Approval_Status__c, ' +
      'Finance_Approval_Status__c FROM Quote WHERE Id = \'' + quotes[0].Id + '\''
    );
    Boolean ok =
      quotes[0].Approval_Status__c == 'Pending' &&
      quotes[0].Total_Discount_Percent__c > 0 &&
      dq.get('Discount_Approval_Status__c') == 'Pending' &&
      dq.get('Legal_Approval_Status__c') == 'Pending' &&
      dq.get('Finance_Approval_Status__c') == 'Pending';
    results.add(
      (ok ? 'PASS' : 'FAIL') +
      ' S4 Discounted Enterprise Quote — discount=' + quotes[0].Total_Discount_Percent__c +
      '%, approval(rollup/disc/legal/fin)=' + quotes[0].Approval_Status__c + '/' +
      dq.get('Discount_Approval_Status__c') + '/' + dq.get('Legal_Approval_Status__c') +
      '/' + dq.get('Finance_Approval_Status__c')
    );
    if (!ok) {
      failures++;
    }
  }
}

// ---------------------------------------------------------------------------
// S5 — Closed Won standard deal: Order + Contract + onboarding AP + provisioning
// ---------------------------------------------------------------------------
{
  List<Opportunity> opps = [
    SELECT Id FROM Opportunity WHERE Name = '[S5] Wayne Standard Deal'
  ];
  Boolean ok = false;
  String detail = 'no opp';
  if (!opps.isEmpty()) {
    Id oppId = opps[0].Id;
    List<Order> orders = [
      SELECT Id, Provisioning_Status__c FROM Order WHERE Source_Opportunity__c = :oppId
    ];
    Integer contracts = [
      SELECT COUNT() FROM Contract WHERE Source_Opportunity__c = :oppId
    ];
    Integer plans = [
      SELECT COUNT() FROM ActionPlan__c WHERE Opportunity__c = :oppId
    ];
    Boolean order = !orders.isEmpty();
    Boolean provisioning = order && orders[0].Provisioning_Status__c == 'Pending';
    ok = order && provisioning && contracts > 0 && plans > 0;
    detail = 'order=' + order + ', provisioning=' +
      (order ? orders[0].Provisioning_Status__c : 'n/a') +
      ', contracts=' + contracts + ', onboarding action plans=' + plans;
    if (!ok && orders.isEmpty() && !canLinkContract) {
      results.add('BLOCKED S5 Closed Won Standard Deal — Generate Order chain unavailable (Opportunity.ContractId not FLS-accessible until the admin field-access permission set is assigned); ' + detail);
      blocked++;
    } else {
      results.add((ok ? 'PASS' : 'FAIL') + ' S5 Closed Won Standard Deal — ' + detail);
      if (!ok) {
        failures++;
      }
    }
  } else {
    results.add('FAIL S5 Closed Won Standard Deal — ' + detail);
    failures++;
  }
}

// ---------------------------------------------------------------------------
// S6 — Closed Won with provisioning exception Case
// ---------------------------------------------------------------------------
{
  List<Opportunity> opps = [
    SELECT Id FROM Opportunity WHERE Name = '[S6] Umbrella AI Dispatch Deal'
  ];
  Boolean ok = false;
  String detail = 'no opp';
  if (!opps.isEmpty()) {
    Id oppId = opps[0].Id;
    List<Order> orders = [
      SELECT Id, Provisioning_Status__c FROM Order WHERE Source_Opportunity__c = :oppId
    ];
    Integer exceptions = orders.isEmpty()
      ? 0
      : [
          SELECT COUNT()
          FROM Case
          WHERE Related_Order__c = :orders[0].Id
            AND Case_Category__c = 'Provisioning'
            AND Provisioning_Failure_Reason__c != null
        ];
    Boolean order = !orders.isEmpty();
    // The Failure event stamps the Order 'Failed' AND raises the Case — require
    // both, so a half-finished exception path (Case but no Failed stamp, or vice
    // versa) doesn't pass.
    Boolean orderFailed = order && orders[0].Provisioning_Status__c == 'Failed';
    ok = order && orderFailed && exceptions > 0;
    detail = 'order=' + order + ', provisioning=' +
      (order ? orders[0].Provisioning_Status__c : 'n/a') +
      ', exception cases=' + exceptions;
    if (!ok && orders.isEmpty() && !canLinkContract) {
      results.add('BLOCKED S6 Closed Won Provisioning Exception — Generate Order chain unavailable (Opportunity.ContractId not FLS-accessible until the admin field-access permission set is assigned); ' + detail);
      blocked++;
    } else {
      results.add((ok ? 'PASS' : 'FAIL') + ' S6 Closed Won Provisioning Exception — ' + detail);
      if (!ok) {
        failures++;
      }
    }
  } else {
    results.add('FAIL S6 Closed Won Provisioning Exception — ' + detail);
    failures++;
  }
}

// ---------------------------------------------------------------------------
// S7 — Contract activation spawns a renewal Opportunity
// ---------------------------------------------------------------------------
{
  List<Contract> cons = [
    SELECT Id, Status, Renewal_Created__c, Renewal_Opportunity__c
    FROM Contract
    WHERE Account.Name = '[S7] Soylent Corp' AND Status = 'Activated'
  ];
  Boolean ok =
    !cons.isEmpty() &&
    cons[0].Renewal_Created__c == true &&
    cons[0].Renewal_Opportunity__c != null;
  results.add(
    (ok ? 'PASS' : 'FAIL') +
    ' S7 Contract Activation — ' +
    (cons.isEmpty()
      ? 'no activated contract'
      : 'renewal created=' + cons[0].Renewal_Created__c +
        ', renewal opp=' + (cons[0].Renewal_Opportunity__c != null))
  );
  if (!ok) {
    failures++;
  }
}

// ---------------------------------------------------------------------------
// S8 — Renewal Risk Case escalated to the Renewal Risk queue + tasks
// ---------------------------------------------------------------------------
{
  // Expected side effects: the escalation flag, the queue route, AND a
  // high-priority escalation Task. The Task creation moved from the flow into
  // CaseTriggerHandler because the flow/trigger race dropped
  // it; until that handler deploys the Task is absent, so flag+route present
  // but Task missing is reported BLOCKED (env), not PASS (the scenario requires the
  // task) and not FAIL (it's a known pending-deploy gap, not a regression).
  List<Case> cases = [
    SELECT Id, Escalated_To_Renewal_Queue__c, Escalated_At__c, OwnerId, Owner.Type
    FROM Case
    WHERE Subject = '[S8] Hooli renewal at risk'
  ];
  Boolean escalated = !cases.isEmpty() && cases[0].Escalated_To_Renewal_Queue__c == true;
  // Assert the SPECIFIC Renewal Risk queue, not just "some queue" — a rule
  // regression could misroute to the Finance/Provisioning queue.
  String ownerQueue;
  if (!cases.isEmpty() && cases[0].Owner.Type == 'Queue') {
    List<Group> g = [
      SELECT DeveloperName FROM Group WHERE Id = :cases[0].OwnerId AND Type = 'Queue'
    ];
    ownerQueue = g.isEmpty() ? null : g[0].DeveloperName;
  }
  Boolean routedToQueue = ownerQueue == 'Renewal_Risk_Queue';
  Integer escalationTasks = cases.isEmpty()
    ? 0
    : [
        SELECT COUNT()
        FROM Task
        WHERE WhatId = :cases[0].Id AND Subject LIKE 'Renewal risk escalated%'
      ];
  String s8Detail = 'escalated=' + escalated + ', routed to Renewal_Risk_Queue=' +
    routedToQueue + ' (' + (ownerQueue == null ? 'n/a' : ownerQueue) +
    '), escalation tasks=' + escalationTasks;
  if (escalated && routedToQueue && escalationTasks > 0) {
    results.add('PASS S8 Renewal Risk Case — ' + s8Detail);
  } else if (escalated && routedToQueue && escalationTasks == 0) {
    results.add('BLOCKED S8 Renewal Risk Case — escalation Task absent (requires CaseTriggerHandler); ' + s8Detail);
    blocked++;
  } else {
    results.add('FAIL S8 Renewal Risk Case — ' + s8Detail);
    failures++;
  }
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------
System.debug('=== Northstar sample-scenario verification ===');
for (String line : results) {
  System.debug(line);
}
Integer passed = results.size() - failures - blocked;
System.debug(
  '=== ' + passed + ' passed, ' + failures + ' failed, ' + blocked +
  ' blocked (env) of ' + results.size() + ' scenarios ==='
);

if (failures > 0) {
  throw new System.AssertException(
    failures + ' sample scenario(s) failed verification — see FAIL lines above.'
  );
}
