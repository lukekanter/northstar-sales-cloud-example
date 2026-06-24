// seed_action_plan_templates.apex
// Idempotent seed for the six Northstar Action Plan templates.
//
// Anonymous Apex cannot read repo files, so the canonical JSON dataset under
// `data/action-plan-templates.json` is embedded inline below. Keep them in
// sync — the script is the runtime source of truth; the JSON file is the
// reviewable source.
//
// Upsert key:
//   - ActionPlanTemplate__c: Name (queried, Id stamped, then upserted).
//     Child APTemplateTask__c rows are fully rebuilt each run (delete by
//     parent + re-insert) so edits to the embedded JSON are picked up and the
//     script stays idempotent (re-running does not duplicate tasks).
//
// Tasks are seeded with no explicit User__c, so the Action Plan owner (the
// running user when created by the onboarding flow) owns them. The
// Implementation_Playbook_Rule__mdt.Owner_Group__c carries the intended owning
// group for a future round-robin enhancement.
//
// Prerequisite: the running user MUST have the Action Plans V4
// custom-field FLS, granted by the `Action_Plans_Admin` permission set. Without
// it the Action Plans V4 fields (e.g. ActionPlanTemplate__c.Description__c) are
// FLS-hidden and this script fails to COMPILE ("Variable does not exist:
// Description__c") even though the fields are deployed. Assign once per org:
//   sf org assign permset --name Action_Plans_Admin --target-org "$NS_ORG"
//
// Run:
//   sf apex run --file scripts/apex/seed_action_plan_templates.apex \
//     --target-org "$NS_ORG"

String TEMPLATES_JSON = '[{"name":"New Customer Onboarding - Standard","description":"Standard onboarding playbook for Quickstart/Standard implementation packages. Run by the Implementation Managers team after Closed Won.","skipWeekends":true,"tasks":[{"index":1,"subject":"Onboarding kickoff call with customer","type":"Call","priority":"High","daysFromStart":0,"comments":"Introduce the implementation team, confirm goals, success criteria, and timeline."},{"index":2,"subject":"Provision core platform access","type":"Other","priority":"Normal","daysFromStart":2,"comments":"Create org/users and grant the purchased entitlements."},{"index":3,"subject":"Configure standard workflows","type":"Other","priority":"Normal","daysFromStart":5,"comments":"Apply the standard Northstar configuration baseline."},{"index":4,"subject":"30-day adoption check-in","type":"Call","priority":"Normal","daysFromStart":30,"comments":"Confirm adoption, resolve blockers, capture expansion signals."}]},{"name":"New Customer Onboarding - Enterprise","description":"Enterprise onboarding playbook for the Enterprise implementation package. White-glove engagement led by Implementation Managers with a named TAM/CSM.","skipWeekends":true,"tasks":[{"index":1,"subject":"Executive kickoff & success plan","type":"Meeting","priority":"High","daysFromStart":0,"comments":"Align executive sponsors on the mutual success plan."},{"index":2,"subject":"Assign named TAM & CSM","type":"Other","priority":"High","daysFromStart":1,"comments":"Staff the account with a Technical Account Manager and Customer Success Manager."},{"index":3,"subject":"Provision enterprise platform + SSO","type":"Other","priority":"Normal","daysFromStart":3,"comments":"Stand up the enterprise tenant and wire up SSO/identity."},{"index":4,"subject":"Custom workflow design workshop","type":"Meeting","priority":"Normal","daysFromStart":7,"comments":"Run the design workshop and capture the configuration backlog."},{"index":5,"subject":"Administrator training session","type":"Meeting","priority":"Normal","daysFromStart":14,"comments":"Train the customer\'s admins on day-2 operations."},{"index":6,"subject":"30-day executive business review","type":"Meeting","priority":"High","daysFromStart":30,"comments":"Review outcomes against the success plan with the sponsors."}]},{"name":"Implementation Services Kickoff","description":"Project-services kickoff for Custom Statement of Work engagements. Owned by Implementation Managers.","skipWeekends":true,"tasks":[{"index":1,"subject":"SOW review & scope confirmation","type":"Meeting","priority":"High","daysFromStart":0,"comments":"Walk the signed SOW and confirm scope, assumptions, and exclusions."},{"index":2,"subject":"Build project plan & milestones","type":"Other","priority":"Normal","daysFromStart":3,"comments":"Produce the project plan with milestone dates and owners."},{"index":3,"subject":"Data migration plan","type":"Other","priority":"Normal","daysFromStart":7,"comments":"Define source systems, mapping, and migration approach."},{"index":4,"subject":"Go-live readiness review","type":"Meeting","priority":"High","daysFromStart":21,"comments":"Confirm cutover readiness and sign-off criteria."}]},{"name":"Premium Support Activation","description":"Activates Premium Support entitlements and introduces SLAs. Owned by Customer Success.","skipWeekends":true,"tasks":[{"index":1,"subject":"Activate premium support entitlements","type":"Other","priority":"High","daysFromStart":0,"comments":"Turn on the purchased support tier and entitlements."},{"index":2,"subject":"Introduce support contacts & SLAs","type":"Email","priority":"Normal","daysFromStart":1,"comments":"Send the support contacts, escalation paths, and SLA summary."},{"index":3,"subject":"Schedule quarterly business review","type":"Call","priority":"Normal","daysFromStart":5,"comments":"Book the recurring QBR cadence."}]},{"name":"Renewal Save Plan","description":"Retention playbook for at-risk renewals. Owned by Customer Success Managers.","skipWeekends":true,"tasks":[{"index":1,"subject":"Assess renewal risk & usage","type":"Other","priority":"High","daysFromStart":0,"comments":"Review health score, usage trend, and open issues."},{"index":2,"subject":"Executive sponsor outreach","type":"Call","priority":"High","daysFromStart":2,"comments":"Re-engage the executive sponsor on value delivered."},{"index":3,"subject":"Build retention offer","type":"Other","priority":"Normal","daysFromStart":5,"comments":"Construct the renewal offer / incentive with Deal Desk."},{"index":4,"subject":"Renewal proposal review","type":"Meeting","priority":"Normal","daysFromStart":10,"comments":"Present the renewal proposal to the customer."}]},{"name":"At-Risk Customer Escalation","description":"Escalation playbook triggered when a provisioning exception Case is raised. Owned by Customer Success.","skipWeekends":true,"tasks":[{"index":1,"subject":"Triage provisioning/health exception","type":"Other","priority":"High","daysFromStart":0,"comments":"Assess the failing provisioning step and customer impact."},{"index":2,"subject":"Customer escalation call","type":"Call","priority":"High","daysFromStart":1,"comments":"Acknowledge the issue and set expectations with the customer."},{"index":3,"subject":"Remediation plan & owner","type":"Other","priority":"High","daysFromStart":3,"comments":"Document the fix, owner, and target date."},{"index":4,"subject":"Follow-up & confirm resolution","type":"Call","priority":"Normal","daysFromStart":7,"comments":"Verify the issue is resolved and the customer is satisfied."}]}]';

List<Object> templateList = (List<Object>) JSON.deserializeUntyped(
  TEMPLATES_JSON
);

// ---------- 1) Upsert ActionPlanTemplate__c by Name ----------

Set<String> names = new Set<String>();
for (Object o : templateList) {
  names.add((String) ((Map<String, Object>) o).get('name'));
}

Map<String, ActionPlanTemplate__c> existing = new Map<String, ActionPlanTemplate__c>();
for (ActionPlanTemplate__c t : [
  SELECT Id, Name
  FROM ActionPlanTemplate__c
  WHERE Name IN :names
]) {
  existing.put(t.Name, t);
}

List<ActionPlanTemplate__c> templatesToUpsert = new List<ActionPlanTemplate__c>();
for (Object o : templateList) {
  Map<String, Object> m = (Map<String, Object>) o;
  String name = (String) m.get('name');
  ActionPlanTemplate__c t = existing.containsKey(name)
    ? existing.get(name)
    : new ActionPlanTemplate__c();
  t.Name = name;
  t.Description__c = (String) m.get('description');
  Boolean skipWeekends = (Boolean) m.get('skipWeekends');
  t.SkipWeekends__c = skipWeekends;
  // SkipDay__c is a restricted, dependent picklist (controlled by
  // SkipWeekends__c) backed by the SkipDay global value set
  // ("Start of next week" / "End of previous week"). It MUST be set when
  // SkipWeekends__c is true, otherwise ActionPlanCreateInvocable's
  // weekend-adjustment path is skipped (it requires SkipWeekends__c == true
  // AND SkipDay__c != null) and weekend due dates are not avoided.
  t.SkipDay__c = skipWeekends ? 'Start of next week' : null;
  templatesToUpsert.add(t);
}
upsert templatesToUpsert;

Map<String, Id> templateIdByName = new Map<String, Id>();
for (ActionPlanTemplate__c t : templatesToUpsert) {
  templateIdByName.put(t.Name, t.Id);
}

// ---------- 2) Rebuild child APTemplateTask__c rows ----------

delete [
  SELECT Id
  FROM APTemplateTask__c
  WHERE Action_Plan_Template__c IN :templateIdByName.values()
];

List<APTemplateTask__c> tasksToInsert = new List<APTemplateTask__c>();
for (Object o : templateList) {
  Map<String, Object> m = (Map<String, Object>) o;
  Id templateId = templateIdByName.get((String) m.get('name'));
  for (Object to : (List<Object>) m.get('tasks')) {
    Map<String, Object> tm = (Map<String, Object>) to;
    APTemplateTask__c task = new APTemplateTask__c();
    task.Action_Plan_Template__c = templateId;
    task.TaskIndex__c = (Integer) tm.get('index');
    String subject = (String) tm.get('subject');
    task.Subject__c = subject;
    // APTemplateTask__c uses a required Text Name field (not an auto-number),
    // so it must be set before insert or the DML fails with
    // REQUIRED_FIELD_MISSING. Mirror the Subject (capped at the 80-char Name
    // limit), matching how the vendor builder names template tasks.
    task.Name = subject.length() > 80 ? subject.substring(0, 80) : subject;
    task.Type__c = (String) tm.get('type');
    task.Priority__c = (String) tm.get('priority');
    task.DaysFromStart__c = (Integer) tm.get('daysFromStart');
    task.Comments__c = (String) tm.get('comments');
    task.Dependent__c = 'None';
    task.Reminder__c = false;
    task.SendEmail__c = false;
    tasksToInsert.add(task);
  }
}
insert tasksToInsert;

System.debug(
  'Seeded ' +
    templatesToUpsert.size() +
    ' Action Plan templates with ' +
    tasksToInsert.size() +
    ' template tasks.'
);
