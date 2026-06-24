// seed_sample_data.apex
// Idempotent seed for the eight Northstar sample scenarios. Each scenario
// seeds named records (prefixed `[Sn] `) and drives the same automation a
// real user would, so the org's automation chains
// (assignment rules, before/after-save flows, triggers, invocable Apex,
// platform events) actually fire.
//
// WHY DIRECT DML, NOT `sf data import tree`: six of the eight
// scenarios are *Update-triggered* (Lead→Qualified, Opp→Proposal,
// Opp→Closed Won, Order→Activated, Contract→Activated, Case→Renewal Risk) and
// some need procedural steps a static tree file can't express — Lead convert,
// SyncedQuote + quote-accept, Order activation, and a published
// Provisioning_Completed__e. The reviewable per-object datasets live under
// `data/sample-*.json`; this script is the runtime source of truth (same split
// as seed_product_catalog.apex).
//
// ONE SCENARIO PER RUN: each Closed Won / activation chain fires a lot of
// downstream automation, so seeding all eight in a single transaction blows the
// per-transaction SOQL limit. This script therefore seeds the FIRST not-yet
// present scenario, then stops — wrap it in a loop (scripts/deploy-sample-data.sh
// does this) and re-run until it prints `ALL_SEEDED`. Idempotent: a scenario
// whose anchor record already exists is skipped, so it never double-converts a
// Lead, re-accepts a Quote, or duplicates an Order.
//
// Run (single scenario):
//   sf apex run --file scripts/apex/seed_sample_data.apex --target-org "$NS_ORG"
// Run (all scenarios): ./scripts/deploy-sample-data.sh
// Prereqs: products & price books and all triggers/flows deployed.

// ===========================================================================
//  Shared lookups
// ===========================================================================

Id stdPbId = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

Map<String, PricebookEntry> pbeByCode = new Map<String, PricebookEntry>();
for (PricebookEntry pbe : [
  SELECT Id, UnitPrice, Product2.ProductCode
  FROM PricebookEntry
  WHERE Pricebook2Id = :stdPbId
    AND Product2.ProductCode IN ('NS-CORE-COMM', 'NS-CORE-ENT', 'NS-ADD-AIDISPATCH', 'NS-IMPL-ENT')
    AND IsActive = true
]) {
  pbeByCode.put(pbe.Product2.ProductCode, pbe);
}
if (pbeByCode.isEmpty()) {
  throw new System.AssertException(
    'No standard PricebookEntries found — run seed_product_catalog.apex first.'
  );
}

Database.DMLOptions assignRule = new Database.DMLOptions();
assignRule.assignmentRuleHeader.useDefaultRule = true;

// The Generate Order chain (Closed Won → GO_GenerateOrderInvocable) derives the
// Order from an activated Contract linked via the standard Opportunity.ContractId
// lookup. That field EXISTS in the org, but until the System Admin profile is
// granted FLS on it, the seed (anonymous Apex, user mode)
// can't read or set it — a describe getMap() omits FLS-inaccessible fields, so
// this doubles as the capability check. When false, S5/S6 seed the base deal
// and report the gap instead of failing the run; after it flips true.
Boolean canLinkContract = Opportunity.SObjectType.getDescribe()
  .fields.getMap()
  .containsKey('contractid');

// `claimed` is set by a HEAVY op (fresh seed / purge+reseed) — at most one per
// run, to stay under per-transaction limits. `repaired` is set by a LIGHT
// re-drive (republish an event, re-fire a transition) — those don't consume the
// claim slot, so an async lag on one scenario can't starve later ones. Either flag keeps the deploy loop going; only both-false = ALL_SEEDED.
Boolean claimed = false;
Boolean repaired = false;
List<String> log = new List<String>();

// ===========================================================================
//  S1 — Inbound Commercial Lead → SDR queue + follow-up task
// ===========================================================================

// Completion anchors on the routed owner (Inbound_SDR_Queue) AND the SDR
// follow-up Task — not just the Lead — so a run made before the assignment rule
// SDR flow worked isn't treated as done. Both side effects are
// synchronous (assignment rule on the routed update; SDR flow on the Qualified
// transition), so an incomplete Lead is re-driven by re-routing + re-firing and
// re-checking.
List<Lead> s1Leads = [
  SELECT Id, OwnerId, Owner.Type
  FROM Lead
  WHERE Company = 'Acme Logistics' AND LastName = '[S1] Inbound'
];
Id s1LeadId = s1Leads.isEmpty() ? null : s1Leads[0].Id;
Boolean s1Routed =
  s1LeadId != null &&
  s1Leads[0].Owner.Type == 'Queue' &&
  ![SELECT Id FROM Group WHERE Id = :s1Leads[0].OwnerId AND DeveloperName = 'Inbound_SDR_Queue']
    .isEmpty();
Boolean s1Task =
  s1LeadId != null &&
  [SELECT COUNT() FROM Task WHERE WhoId = :s1LeadId AND Subject LIKE 'SDR follow-up%'] > 0;
if (s1LeadId != null && s1Routed && s1Task) {
  log.add('S1 already present (complete)');
} else if (claimed) {
  // another scenario seeded this run
} else if (s1LeadId != null) {
  // Lead exists but routing or SDR task is incomplete — re-route (assignment
  // rule header) and re-fire the Qualified transition, then re-check.
  Database.update(new Lead(Id = s1LeadId, Status = 'Working - Contacted'), assignRule);
  update new Lead(Id = s1LeadId, Status = 'Qualified');
  Lead s1Chk = [SELECT OwnerId, Owner.Type FROM Lead WHERE Id = :s1LeadId];
  Boolean routedNow =
    s1Chk.Owner.Type == 'Queue' &&
    ![SELECT Id FROM Group WHERE Id = :s1Chk.OwnerId AND DeveloperName = 'Inbound_SDR_Queue']
      .isEmpty();
  Boolean taskNow =
    [SELECT COUNT() FROM Task WHERE WhoId = :s1LeadId AND Subject LIKE 'SDR follow-up%'] > 0;
  if (routedNow && taskNow) {
    repaired = true;
    log.add('S1 re-driven (routed to Inbound_SDR_Queue + SDR task for lead ' + s1LeadId + ')');
  } else {
    log.add('S1 blocked (routing/SDR task not created — assignment rule or SDR flow not live) — left as-is');
  }
} else {
  Lead l = new Lead(
    LastName = '[S1] Inbound',
    FirstName = 'Dana',
    Company = 'Acme Logistics',
    Customer_Segment__c = 'Commercial',
    Region__c = 'NA West',
    LeadSource = 'Web',
    Lead_Source_Detail__c = 'Inbound Form',
    Lead_Score__c = 60,
    Status = 'Open - Not Contacted'
  );
  Database.insert(l, assignRule); // assignment rule → Inbound SDR queue
  update new Lead(Id = l.Id, Status = 'Qualified'); // SDR follow-up flow
  claimed = true;
  log.add('S1 seeded (Lead ' + l.Id + ')');
}

// ===========================================================================
//  S2 — Enterprise Lead converted to Account / Contact / Opportunity
// ===========================================================================

if ([SELECT COUNT() FROM Lead WHERE Company = 'Globex Corporation' AND LastName = '[S2] Enterprise'] != 0) {
  log.add('S2 already present');
} else if (!claimed) {
  Lead l = new Lead(
    LastName = '[S2] Enterprise',
    FirstName = 'Priya',
    Company = 'Globex Corporation',
    Customer_Segment__c = 'Enterprise',
    Region__c = 'NA East',
    LeadSource = 'Web',
    Lead_Source_Detail__c = 'Content Download',
    Lead_Score__c = 85,
    Status = 'Qualified'
  );
  insert l;
  // The org has no lead→account field mapping for these custom fields, so
  // converting into a fresh account leaves segment/region (and therefore the
  // Opportunity's trigger-stamped Territory_Segment__c) blank. Convert INTO a
  // pre-stamped Enterprise account so OpportunityTriggerHandler stamps
  // Territory_Segment__c = "NA East - Enterprise" at conversion.
  // The missing conversion field mapping is tracked as a follow-up (see the PR).
  Account a = new Account(
    Name = 'Globex Corporation',
    Customer_Segment__c = 'Enterprise',
    Region__c = 'NA East',
    Support_Tier__c = 'Standard'
  );
  insert a;
  Database.LeadConvert lc = new Database.LeadConvert();
  lc.setLeadId(l.Id);
  lc.setConvertedStatus([SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel);
  lc.setAccountId(a.Id);
  lc.setOpportunityName('[S2] Globex Enterprise Expansion');
  Database.LeadConvertResult res = Database.convertLead(lc);
  claimed = true;
  log.add('S2 seeded (Opp ' + res.getOpportunityId() + ')');
}

// ===========================================================================
//  S3 — Opportunity enters Proposal → "Build Quote" task
// ===========================================================================

// Completion anchors on the "Build quote" Task (the proposal-automation side
// effect), not the Opportunity — else a run made before the flow worked would
// skip S3 forever once it's fixed. The task is created
// SYNCHRONOUSLY by the after-save flow on the Proposal transition, so a
// task-less Opp is re-driven by re-firing the transition and re-checking.
List<Opportunity> s3Opps = [
  SELECT Id FROM Opportunity WHERE Name = '[S3] Initech Platform Proposal'
];
Id s3OppId = s3Opps.isEmpty() ? null : s3Opps[0].Id;
Boolean s3TaskExists =
  s3OppId != null &&
  [SELECT COUNT() FROM Task WHERE WhatId = :s3OppId AND Subject LIKE 'Build quote%'] > 0;
if (s3TaskExists) {
  log.add('S3 already present (complete)');
} else if (claimed) {
  // another scenario seeded this run
} else if (s3OppId != null) {
  // Opp exists but no Build Quote task — re-fire the Proposal transition (the
  // Opp already has products, so the validation passes), then re-check.
  update new Opportunity(Id = s3OppId, StageName = 'Prospecting');
  update new Opportunity(Id = s3OppId, StageName = 'Proposal/Price Quote');
  Boolean s3TaskNow =
    [SELECT COUNT() FROM Task WHERE WhatId = :s3OppId AND Subject LIKE 'Build quote%'] > 0;
  if (s3TaskNow) {
    repaired = true;
    log.add('S3 re-driven (Build Quote task created for opp ' + s3OppId + ')');
  } else {
    log.add('S3 blocked (Build Quote task not created — proposal automation not live) — left as-is');
  }
} else {
  Account a = new Account(
    Name = '[S3] Initech',
    Customer_Segment__c = 'Commercial',
    Region__c = 'NA East',
    Support_Tier__c = 'Standard'
  );
  insert a;
  Opportunity opp = new Opportunity(
    Name = '[S3] Initech Platform Proposal',
    AccountId = a.Id,
    StageName = 'Prospecting',
    CloseDate = Date.today().addDays(45),
    Pricebook2Id = stdPbId,
    Subscription_Term_Months__c = '12 Months',
    Subscription_Start_Date__c = Date.today(),
    Billing_Frequency__c = 'Annual',
    Implementation_Package__c = 'Quickstart',
    Support_Tier__c = 'Standard',
    Sales_Motion__c = 'New Logo',
    Provisioning_Status__c = 'Not Required'
  );
  insert opp;
  PricebookEntry pbe = pbeByCode.get('NS-CORE-COMM');
  insert new OpportunityLineItem(
    OpportunityId = opp.Id,
    PricebookEntryId = pbe.Id,
    Quantity = 25,
    UnitPrice = pbe.UnitPrice,
    Revenue_Type__c = 'Subscription',
    Implementation_Phase__c = 'Phase 1',
    Billing_Start_Offset_Days__c = 0,
    Support_Tier__c = 'Standard'
  );
  update new Opportunity(Id = opp.Id, StageName = 'Proposal/Price Quote'); // proposal automation
  claimed = true;
  log.add('S3 seeded (Opp ' + opp.Id + ')');
}

// ===========================================================================
//  S4 — Discounted Enterprise Quote → approval + legal/finance flags
// ===========================================================================

if ([SELECT COUNT() FROM Quote WHERE Name = '[S4] Stark Discounted Quote'] != 0) {
  log.add('S4 already present');
} else if (!claimed) {
  Account a = new Account(
    Name = '[S4] Stark Industries',
    Customer_Segment__c = 'Enterprise',
    Region__c = 'NA East',
    Support_Tier__c = 'Premium Enterprise'
  );
  insert a;
  Opportunity opp = new Opportunity(
    Name = '[S4] Stark Enterprise Deal',
    AccountId = a.Id,
    StageName = 'Prospecting',
    CloseDate = Date.today().addDays(60),
    Pricebook2Id = stdPbId,
    Subscription_Term_Months__c = '12 Months',
    Subscription_Start_Date__c = Date.today(),
    Billing_Frequency__c = 'Annual',
    Implementation_Package__c = 'Enterprise',
    Support_Tier__c = 'Premium Enterprise',
    Sales_Motion__c = 'New Logo',
    Provisioning_Status__c = 'Not Required'
  );
  insert opp;
  PricebookEntry corePbe = pbeByCode.get('NS-CORE-ENT');
  insert new OpportunityLineItem(
    OpportunityId = opp.Id,
    PricebookEntryId = corePbe.Id,
    Quantity = 50,
    UnitPrice = corePbe.UnitPrice,
    Revenue_Type__c = 'Subscription',
    Implementation_Phase__c = 'Phase 1',
    Billing_Start_Offset_Days__c = 0,
    Support_Tier__c = 'Premium Enterprise'
  );
  Quote q = new Quote(
    Name = '[S4] Stark Discounted Quote',
    OpportunityId = opp.Id,
    Pricebook2Id = stdPbId,
    Subscription_Term_Months__c = '12 Months',
    Billing_Frequency__c = 'Annual',
    Implementation_Package__c = 'Enterprise',
    Premium_Support_Tier__c = 'Premium Enterprise',
    Legal_Terms_Required__c = true,
    Discount_Reason__c = 'Competitive Replacement',
    Effective_Date__c = Date.today(),
    Validity_Period_Days__c = 30,
    Status = 'Draft'
  );
  insert q;
  PricebookEntry implPbe = pbeByCode.get('NS-IMPL-ENT');
  insert new List<QuoteLineItem>{
    new QuoteLineItem(
      QuoteId = q.Id, PricebookEntryId = corePbe.Id, Quantity = 50,
      UnitPrice = corePbe.UnitPrice, Discount = 25, Revenue_Type__c = 'Subscription',
      Implementation_Phase__c = 'Phase 1', Billing_Start_Offset_Days__c = 0,
      Support_Tier__c = 'Premium Enterprise'
    ),
    new QuoteLineItem(
      QuoteId = q.Id, PricebookEntryId = implPbe.Id, Quantity = 1,
      UnitPrice = implPbe.UnitPrice, Discount = 30, Revenue_Type__c = 'Services',
      Implementation_Phase__c = 'Phase 1', Billing_Start_Offset_Days__c = 0,
      Support_Tier__c = 'Premium Enterprise'
    )
  };
  // Re-touch so the afterUpdate rollup re-evaluates the blended discount; the
  // Quote trigger stamps Approval_Status__c = 'Pending' (the Deal Desk gate).
  update new Quote(Id = q.Id, Description = 'Sample discounted enterprise quote (S4).');
  claimed = true;
  log.add('S4 seeded (Quote ' + q.Id + ')');
}

// ===========================================================================
//  S5 / S6 — Closed Won deals (standard provisioning vs provisioning exception)
// ===========================================================================

for (Integer variant = 5; variant <= 6; variant++) {
  Boolean isException = (variant == 6);
  String tag = '[S' + variant + '] ';
  String accountName = tag + (isException ? 'Umbrella Corp' : 'Wayne Enterprises');
  String oppName = tag + (isException ? 'Umbrella AI Dispatch Deal' : 'Wayne Standard Deal');

  // Completion anchors on each scenario's verified side effects, not record
  // existence: S5 = Order + onboarding ActionPlan; S6 = failure
  // Case. Repair without spinning or duplicating:
  //   - Order present but the ASYNC side effect (S5 plan / S6 Case) hasn't
  //     landed yet → PENDING: no action this pass. The queued/enqueued work
  //     settles and the deploy loop's post-seed wait + verify observe it. We do
  //     NOT republish the Failure event — ProvisioningCompletedSubscriber
  //     inserts a Case per event, so republishing duplicates the exception Case.
  //   - no Order + ContractId FLS not accessible → leave the partial, DON'T
  //     claim, so later scenarios still run (re-purging would starve them).
  //   - no Order + ContractId accessible → purge and reseed.
  //   - no Opportunity → fresh seed.
  List<Opportunity> existingOpps = [SELECT Id FROM Opportunity WHERE Name = :oppName];
  Id existingOppId = existingOpps.isEmpty() ? null : existingOpps[0].Id;
  List<Order> existingOrders = existingOppId == null
    ? new List<Order>()
    : [SELECT Id FROM Order WHERE Source_Opportunity__c = :existingOppId];
  Boolean orderPresent = !existingOrders.isEmpty();
  Boolean sideEffectDone;
  if (isException) {
    sideEffectDone =
      orderPresent &&
      [
        SELECT COUNT()
        FROM Case
        WHERE Related_Order__c = :existingOrders[0].Id
          AND Provisioning_Failure_Reason__c != null
      ] > 0;
  } else {
    sideEffectDone =
      orderPresent &&
      [SELECT COUNT() FROM ActionPlan__c WHERE Opportunity__c = :existingOppId] > 0;
  }
  if (orderPresent && sideEffectDone) {
    log.add('S' + variant + ' already present (complete)');
    continue;
  }
  if (claimed) {
    continue;
  }
  if (orderPresent) {
    // Synchronous chain done; the async side effect just hasn't landed yet.
    log.add(
      'S' + variant + ' pending (async ' +
      (isException ? 'failure Case' : 'onboarding Action Plan') +
      ' not yet created) — left to settle'
    );
    continue;
  }
  // No Order yet.
  if (existingOppId != null && !canLinkContract) {
    log.add('S' + variant + ' blocked (Opportunity.ContractId not FLS-accessible) — partial state left as-is');
    continue;
  }
  // No Order but we can now complete it: purge the partial records and reseed.
  if (existingOppId != null) {
    Set<Id> staleAcctIds = new Map<Id, Account>(
      [SELECT Id FROM Account WHERE Name = :accountName]
    ).keySet();
    if (!staleAcctIds.isEmpty()) {
      List<Order> staleOrders = [SELECT Id, Status FROM Order WHERE AccountId IN :staleAcctIds];
      if (!staleOrders.isEmpty()) {
        for (Order o : staleOrders) {
          o.Status = 'Draft'; // can't delete an Activated Order
        }
        update staleOrders;
        delete staleOrders;
      }
      delete [SELECT Id FROM Case WHERE AccountId IN :staleAcctIds];
      delete [SELECT Id FROM Contract WHERE AccountId IN :staleAcctIds];
      delete [SELECT Id FROM Opportunity WHERE AccountId IN :staleAcctIds];
      delete [SELECT Id FROM Contact WHERE AccountId IN :staleAcctIds];
      delete [SELECT Id FROM Account WHERE Id IN :staleAcctIds];
    }
    log.add('S' + variant + ' purged incomplete partial state, reseeding');
  }

  Account a = new Account(
    Name = accountName, Customer_Segment__c = 'Commercial',
    Region__c = 'NA East', Support_Tier__c = 'Standard'
  );
  insert a;
  insert new Contact(LastName = tag + 'Primary Contact', AccountId = a.Id);

  Opportunity opp = new Opportunity(
    Name = oppName, AccountId = a.Id, StageName = 'Prospecting',
    CloseDate = Date.today().addDays(15), Pricebook2Id = stdPbId,
    Subscription_Term_Months__c = '12 Months', Subscription_Start_Date__c = Date.today(),
    Billing_Frequency__c = 'Annual', Implementation_Package__c = 'Quickstart',
    Support_Tier__c = 'Standard', Sales_Motion__c = 'New Logo',
    Provisioning_Status__c = 'Not Required'
  );
  insert opp;

  PricebookEntry corePbe = pbeByCode.get('NS-CORE-COMM');
  PricebookEntry aiPbe = pbeByCode.get('NS-ADD-AIDISPATCH');
  List<OpportunityLineItem> olis = new List<OpportunityLineItem>{
    new OpportunityLineItem(
      OpportunityId = opp.Id, PricebookEntryId = corePbe.Id, Quantity = 20,
      UnitPrice = corePbe.UnitPrice, Revenue_Type__c = 'Subscription',
      Implementation_Phase__c = 'Phase 1', Billing_Start_Offset_Days__c = 0,
      Support_Tier__c = 'Standard'
    )
  };
  if (isException) {
    olis.add(new OpportunityLineItem(
      OpportunityId = opp.Id, PricebookEntryId = aiPbe.Id, Quantity = 20,
      UnitPrice = aiPbe.UnitPrice, Revenue_Type__c = 'Subscription',
      Implementation_Phase__c = 'Phase 1', Billing_Start_Offset_Days__c = 0,
      Support_Tier__c = 'Standard'
    ));
  }
  insert olis;

  Quote q = new Quote(
    Name = tag + 'Accepted Quote', OpportunityId = opp.Id, Pricebook2Id = stdPbId,
    Subscription_Term_Months__c = '12 Months', Billing_Frequency__c = 'Annual',
    Implementation_Package__c = 'Quickstart', Premium_Support_Tier__c = 'Standard',
    Legal_Terms_Required__c = false, Effective_Date__c = Date.today(),
    Validity_Period_Days__c = 30, Status = 'Draft'
  );
  insert q;
  List<QuoteLineItem> qlis = new List<QuoteLineItem>{
    new QuoteLineItem(
      QuoteId = q.Id, PricebookEntryId = corePbe.Id, Quantity = 20,
      UnitPrice = corePbe.UnitPrice, Revenue_Type__c = 'Subscription',
      Implementation_Phase__c = 'Phase 1', Billing_Start_Offset_Days__c = 0,
      Support_Tier__c = 'Standard'
    )
  };
  if (isException) {
    qlis.add(new QuoteLineItem(
      QuoteId = q.Id, PricebookEntryId = aiPbe.Id, Quantity = 20,
      UnitPrice = aiPbe.UnitPrice, Revenue_Type__c = 'Subscription',
      Implementation_Phase__c = 'Phase 1', Billing_Start_Offset_Days__c = 0,
      Support_Tier__c = 'Standard'
    ));
  }
  insert qlis;

  // The Generate Order invocable derives the Order's effective date from an
  // ACTIVATED Contract on the Opportunity, so the contract must exist and be
  // activated (and linked via Opportunity.ContractId) BEFORE Closed Won.
  Contract con = new Contract(
    AccountId = a.Id, Status = 'Draft', StartDate = Date.today(), ContractTerm = 12,
    Subscription_Start_Date__c = Date.today(),
    Subscription_End_Date__c = Date.today().addMonths(12).addDays(-1),
    Support_Tier__c = 'Standard', Source_Opportunity__c = opp.Id
  );
  insert con;
  update new Contract(Id = con.Id, Status = 'Activated');

  // Link the activated contract via Opportunity.ContractId (the field GO reads)
  // when the org exposes it; always set the synced quote.
  Opportunity oppUpdate = new Opportunity(Id = opp.Id, SyncedQuoteId = q.Id);
  if (canLinkContract) {
    oppUpdate.put('ContractId', con.Id);
  }
  update oppUpdate;
  update new Quote(Id = q.Id, Status = 'Accepted'); // stamps Primary_Quote_Accepted__c
  update new Opportunity(Id = opp.Id, StageName = 'Closed Won'); // Generate Order + onboarding AP

  List<Order> generated = [
    SELECT Id FROM Order WHERE Source_Opportunity__c = :opp.Id LIMIT 1
  ];
  if (generated.isEmpty()) {
    log.add(
      'S' + variant + ' WARNING: no Order generated from Closed Won' +
      (canLinkContract ? '' : ' (Opportunity.ContractId not FLS-accessible until the admin field-access permission set is assigned — Generate Order chain unavailable)')
    );
  } else {
    Order ord = generated[0];
    update new Order(Id = ord.Id, ContractId = con.Id, Status = 'Activated'); // provisioning dispatch
    if (isException) {
      // Simulate the external provisioning system reporting failure so
      // ProvisioningCompletedSubscriber raises the exception Case.
      EventBus.publish(new Provisioning_Completed__e(
        Order_Id__c = ord.Id, Status__c = 'Failure',
        Failure_Reason__c = 'AI Dispatch endpoint timed out during setup (sample scenario S6).'
      ));
    }
    log.add('S' + variant + ' seeded (Opp ' + opp.Id + ', Order ' + ord.Id + ')');
  }
  claimed = true;
}

// ===========================================================================
//  S7 — Contract activation → synchronous renewal Opportunity
// ===========================================================================

// Completion anchors on the renewal being CREATED (Renewal_Opportunity__c set),
// not merely an Activated Contract: if activation fired but renewal creation
// skipped, anchoring on the Contract alone would skip S7 forever and the
// verifier would keep failing. An Activated contract with no
// renewal is re-driven by re-invoking RenewalService directly — a light op that
// doesn't consume the claim slot, so S8 still seeds.
List<Contract> s7Cons = [
  SELECT Id, Renewal_Opportunity__c
  FROM Contract
  WHERE Account.Name = '[S7] Soylent Corp' AND Status = 'Activated'
];
if (!s7Cons.isEmpty() && s7Cons[0].Renewal_Opportunity__c != null) {
  log.add('S7 already present (complete)');
} else if (!s7Cons.isEmpty()) {
  // Activated but renewal not created — re-drive RenewalService (idempotent).
  RenewalService.createRenewalOpportunity(new Set<Id>{ s7Cons[0].Id });
  repaired = true;
  log.add('S7 re-driven (RenewalService for contract ' + s7Cons[0].Id + ')');
} else if (!claimed) {
  Account a = new Account(
    Name = '[S7] Soylent Corp', Customer_Segment__c = 'Enterprise',
    Region__c = 'NA East', Support_Tier__c = 'Standard'
  );
  insert a;
  Opportunity source = new Opportunity(
    Name = '[S7] Soylent Initial Deal', AccountId = a.Id, StageName = 'Prospecting',
    CloseDate = Date.today().addDays(-300), Subscription_Term_Months__c = '12 Months',
    Sales_Motion__c = 'New Logo', Provisioning_Status__c = 'Not Required'
  );
  insert source;
  Contract con = new Contract(
    AccountId = a.Id, Status = 'Draft', StartDate = Date.today().addDays(-335),
    ContractTerm = 12, Subscription_Start_Date__c = Date.today().addDays(-335),
    Subscription_End_Date__c = Date.today().addDays(30), // inside the renewal window
    Auto_Renewal_Enabled__c = true, Support_Tier__c = 'Standard',
    Source_Opportunity__c = source.Id
  );
  insert con;
  update new Contract(Id = con.Id, Status = 'Activated'); // RenewalService creates renewal Opp
  claimed = true;
  log.add('S7 seeded (Contract ' + con.Id + ')');
}

// ===========================================================================
//  S8 — Renewal Risk Case → escalation tasks + Renewal Risk queue
// ===========================================================================

// Completion anchors on the escalation Task (the dropped side effect), not the
// Case: a run made before that handler was live left the Case escalated/routed
// but task-less, so anchoring on the Case alone would skip it forever once it
// is live. The escalation Task is created SYNCHRONOUSLY by CaseTriggerHandler on
// the High transition, so the re-drive re-fires the transition and then checks
// whether the Task appeared — no dependence on the unrelated ContractId FLS flag
// If the Task still isn't created, the handler isn't live;
// leave it as-is (no flag) so an org without that handler doesn't churn every pass.
List<Case> s8Cases = [
  SELECT Id FROM Case WHERE Subject = '[S8] Hooli renewal at risk'
];
Boolean s8TaskExists =
  !s8Cases.isEmpty() &&
  [
    SELECT COUNT()
    FROM Task
    WHERE WhatId = :s8Cases[0].Id AND Subject LIKE 'Renewal risk escalated%'
  ] > 0;
if (s8TaskExists) {
  log.add('S8 already present (complete)');
} else if (claimed) {
  // another scenario seeded this run
} else if (!s8Cases.isEmpty()) {
  // Case exists but no escalation Task — re-fire the High transition, then check.
  update new Case(
    Id = s8Cases[0].Id,
    Renewal_Risk_Level__c = 'Medium',
    Escalated_To_Renewal_Queue__c = false
  );
  update new Case(Id = s8Cases[0].Id, Renewal_Risk_Level__c = 'High');
  Boolean s8TaskNow =
    [
      SELECT COUNT()
      FROM Task
      WHERE WhatId = :s8Cases[0].Id AND Subject LIKE 'Renewal risk escalated%'
    ] > 0;
  if (s8TaskNow) {
    repaired = true; // light re-drive — doesn't consume the claim slot
    log.add('S8 re-driven (escalation Task created for case ' + s8Cases[0].Id + ')');
  } else {
    log.add('S8 blocked (escalation Task not created — CaseTriggerHandler not live) — left as-is');
  }
} else {
  Account a = new Account(
    Name = '[S8] Hooli', Customer_Segment__c = 'Commercial', Region__c = 'NA East',
    Support_Tier__c = 'Standard', Renewal_Risk_Level__c = 'High'
  );
  insert a;
  Case c = new Case(
    Subject = '[S8] Hooli renewal at risk', AccountId = a.Id,
    Case_Category__c = 'Renewal Risk', Renewal_Risk_Level__c = 'Medium',
    Escalated_To_Renewal_Queue__c = false, Status = 'New'
  );
  Database.insert(c, assignRule);
  update new Case(Id = c.Id, Renewal_Risk_Level__c = 'High'); // fires escalation
  claimed = true;
  log.add('S8 seeded (Case ' + c.Id + ')');
}

// ===========================================================================
//  Summary — `claimed` false means nothing was left to seed this run.
// ===========================================================================

System.debug('=== Northstar sample-data seed summary ===');
for (String line : log) {
  System.debug(line);
}
System.debug((claimed || repaired) ? 'SEEDED_ONE' : 'ALL_SEEDED');
