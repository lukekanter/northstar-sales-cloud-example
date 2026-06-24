/**
 * LeadTriggerHandler — Northstar Lead behaviors.
 *
 * Four behaviors:
 *   1. Normalize Lead_Source_Detail__c — couple to standard LeadSource so the
 *      restricted picklist has a value when LeadSource = "Partner Referral".
 *   2. Derive Region__c from State / Country when blank.
 *   3. Stamp Routing_Reason__c by looking up the Lead's post-assignment
 * OwnerId (a Queue Group) in Lead_Routing_Reason__mdt. See
 *      why this replaces the earlier criteria-duplication approach.
 *   4. Side-effects:
 *        a. High-score inbound leads (Lead_Score__c >= HIGH_SCORE_THRESHOLD,
 *           inbound source) get a "Qualify high-score lead" Task.
 *        b. Status transitions to "Qualified" get a "Lead Qualified — prepare
 *           for conversion follow-up" Task (the downstream signal — see
 * for why a Task and not a platform event).
 *      Idempotent via Trigger.oldMap comparison; setMaxLoopCount intentionally
 *      NOT used (it caps across the whole transaction, blocking legitimate
 *      side-effects from two separate user-initiated updates).
 *
 * Routing-stamp architecture:
 *   - The native Lead.assignmentRules-meta.xml is the sole owner of routing
 *     CRITERIA. Its only responsibility is setting OwnerId.
 *   - This handler reads OwnerId after the assignment rule has fired,
 *     resolves it to a Queue.DeveloperName, and looks up the reason text in
 *     Lead_Routing_Reason__mdt. The MDT is the sole owner of REASON TEXT.
 *   - The handler does NOT re-evaluate any of the assignment rule's criteria,
 *     so changes to the rule order or criteria in the XML cannot drift away
 *     from the stamp text. Adding a new Queue to the routing rule requires a
 *     matching new MDT row — that's the only coupling left.
 *
 * Test trade-off: AssignmentRules don't fire on Apex DML unless the caller
 * sets DmlOptions.AssignmentRuleHeader.useDefaultRule = true. Tests here
 * manually set OwnerId to a Queue Group Id before insert — that tests the
 * stamp logic (the read-back + MDT lookup) without depending on AR firing.
 */
public with sharing class LeadTriggerHandler extends TriggerHandler {
  // Score at which an inbound Lead earns a same-day SDR follow-up Task.
  @TestVisible
  private static final Integer HIGH_SCORE_THRESHOLD = 75;

  // Lead_Source_Detail__c values that count as "inbound" for the high-score
  // qualification rule. Sourced from the Northstar_Lead_Source_Detail GVS.
  @TestVisible
  private static final Set<String> INBOUND_SOURCE_DETAILS = new Set<String>{
    'Inbound Form',
    'Inbound MQL',
    'Trial Signup',
    'Content Download',
    'Webinar',
    'Paid Search'
  };

  // US state codes that map into the NA West Northstar_Region bucket.
  // Pacific + Mountain time zones. Everything else US falls to NA Central
  // unless the state is explicitly East.
  @TestVisible
  private static final Set<String> NA_WEST_STATES = new Set<String>{
    'WA',
    'OR',
    'CA',
    'NV',
    'AZ',
    'AK',
    'HI',
    'ID',
    'UT',
    'CO',
    'MT',
    'WY',
    'NM'
  };
  @TestVisible
  private static final Set<String> NA_EAST_STATES = new Set<String>{
    'NY',
    'NJ',
    'MA',
    'CT',
    'RI',
    'NH',
    'ME',
    'VT',
    'PA',
    'MD',
    'DE',
    'VA',
    'DC',
    'NC',
    'SC',
    'GA',
    'FL',
    'WV'
  };
  // All country sets are uppercased — `canonicalCountry` upper-cases input
  // before set membership. Names AND ISO-2 codes both included so the same
  // set matches whatever form the integration gives us.
  @TestVisible
  private static final Set<String> EMEA_COUNTRIES = new Set<String>{
    'UNITED KINGDOM',
    'UK',
    'GB',
    'IRELAND',
    'IE',
    'GERMANY',
    'DE',
    'FRANCE',
    'FR',
    'NETHERLANDS',
    'NL',
    'SPAIN',
    'ES',
    'ITALY',
    'IT',
    'SWEDEN',
    'SE',
    'NORWAY',
    'NO',
    'DENMARK',
    'DK',
    'FINLAND',
    'FI'
  };
  @TestVisible
  private static final Set<String> APAC_COUNTRIES = new Set<String>{
    'AUSTRALIA',
    'AU',
    'NEW ZEALAND',
    'NZ',
    'JAPAN',
    'JP',
    'SINGAPORE',
    'SG',
    'INDIA',
    'IN',
    'HONG KONG',
    'HK',
    'SOUTH KOREA',
    'KR'
  };
  @TestVisible
  private static final Set<String> LATAM_COUNTRIES = new Set<String>{
    'BRAZIL',
    'BR',
    'MEXICO',
    'MX',
    'ARGENTINA',
    'AR',
    'CHILE',
    'CL',
    'COLOMBIA',
    'CO',
    'PERU',
    'PE'
  };

  // US / Canada country aliases. All other variants normalize to the ISO-2
  // code via canonicalCountry. Recognition of the lead as US/Canada gates
  // application of the NA_WEST / NA_EAST state buckets — without this
  // gate, non-US leads with overlapping state codes (e.g. Australia
  // StateCode='WA') would be misclassified as NA West.
  private static final Set<String> US_COUNTRY_TOKENS = new Set<String>{
    'US',
    'USA',
    'UNITED STATES',
    'UNITED STATES OF AMERICA'
  };
  private static final Set<String> CA_COUNTRY_TOKENS = new Set<String>{
    'CA',
    'CAN',
    'CANADA'
  };

  // US state full name → ISO-2 code. Used by canonicalState when the text
  // fallback path supplies a name (e.g. `Lead.State = "California"`) rather
  // than the picklist code. Covers every state + DC so the text-fallback
  // path can recover the West/East distinction.
  private static final Map<String, String> US_STATE_NAME_TO_CODE = new Map<String, String>{
    'ALABAMA' => 'AL',
    'ALASKA' => 'AK',
    'ARIZONA' => 'AZ',
    'ARKANSAS' => 'AR',
    'CALIFORNIA' => 'CA',
    'COLORADO' => 'CO',
    'CONNECTICUT' => 'CT',
    'DELAWARE' => 'DE',
    'DISTRICT OF COLUMBIA' => 'DC',
    'FLORIDA' => 'FL',
    'GEORGIA' => 'GA',
    'HAWAII' => 'HI',
    'IDAHO' => 'ID',
    'ILLINOIS' => 'IL',
    'INDIANA' => 'IN',
    'IOWA' => 'IA',
    'KANSAS' => 'KS',
    'KENTUCKY' => 'KY',
    'LOUISIANA' => 'LA',
    'MAINE' => 'ME',
    'MARYLAND' => 'MD',
    'MASSACHUSETTS' => 'MA',
    'MICHIGAN' => 'MI',
    'MINNESOTA' => 'MN',
    'MISSISSIPPI' => 'MS',
    'MISSOURI' => 'MO',
    'MONTANA' => 'MT',
    'NEBRASKA' => 'NE',
    'NEVADA' => 'NV',
    'NEW HAMPSHIRE' => 'NH',
    'NEW JERSEY' => 'NJ',
    'NEW MEXICO' => 'NM',
    'NEW YORK' => 'NY',
    'NORTH CAROLINA' => 'NC',
    'NORTH DAKOTA' => 'ND',
    'OHIO' => 'OH',
    'OKLAHOMA' => 'OK',
    'OREGON' => 'OR',
    'PENNSYLVANIA' => 'PA',
    'RHODE ISLAND' => 'RI',
    'SOUTH CAROLINA' => 'SC',
    'SOUTH DAKOTA' => 'SD',
    'TENNESSEE' => 'TN',
    'TEXAS' => 'TX',
    'UTAH' => 'UT',
    'VERMONT' => 'VT',
    'VIRGINIA' => 'VA',
    'WASHINGTON' => 'WA',
    'WEST VIRGINIA' => 'WV',
    'WISCONSIN' => 'WI',
    'WYOMING' => 'WY'
  };

  // Group SObject Id prefix — queues are Groups with Type='Queue'. Used to
  // distinguish auto-routed leads (OwnerId starts with 00G) from manually
  // reassigned leads (OwnerId starts with 005 / User).
  private static final String QUEUE_ID_PREFIX = '00G';

  // Fallback stamp when a Queue has no Lead_Routing_Reason__mdt row.
  // Visible by design — a missing row should surface as a stamp value, not
  // a silently-empty Routing_Reason__c field.
  @TestVisible
  private static final String UNMAPPED_QUEUE_REASON_FORMAT = 'Routed to {0} (no Lead_Routing_Reason__mdt row — add one)';

  // Lazy-loaded cache of MDT rows. Static so a single trigger transaction
  // pays for one query at most. Keyed by Queue_Developer_Name__c.
  private static Map<String, Lead_Routing_Reason__mdt> reasonByQueueCache;

  // -------------------------------------------------------------------------
  // Context overrides
  // -------------------------------------------------------------------------

  public override void beforeInsert() {
    List<Lead> incoming = (List<Lead>) Trigger.new;
    normalizeLeadSourceDetail(incoming);
    deriveRegion(incoming);
    // OwnerId stamping deferred to afterInsert — the AssignmentRule fires
    // between beforeInsert and afterInsert, so beforeInsert's OwnerId is the
    // pre-routing value (still the inserting user) and not useful for stamp.
    stampReasonFromCurrentOwner(incoming, null);
  }

  public override void beforeUpdate() {
    List<Lead> incoming = (List<Lead>) Trigger.new;
    Map<Id, Lead> priors = (Map<Id, Lead>) Trigger.oldMap;
    normalizeLeadSourceDetail(incoming);
    deriveRegion(incoming);
    stampReasonFromCurrentOwner(incoming, priors);
  }

  public override void afterInsert() {
    // Post-AssignmentRule fire — OwnerId now reflects the queue assignment.
    // Need a second-pass update to write Routing_Reason__c since we're in
    // an after-context. Recursion is bounded because the second pass'
    // beforeUpdate sees OwnerId unchanged from the prior state and skips
    // re-stamping.
    stampReasonAfterAssignment((List<Lead>) Trigger.new);
    createSideEffectTasks((List<Lead>) Trigger.new, null);
  }

  public override void afterUpdate() {
    createSideEffectTasks(
      (List<Lead>) Trigger.new,
      (Map<Id, Lead>) Trigger.oldMap
    );
  }

  // -------------------------------------------------------------------------
  // Behavior 1 — normalize Lead_Source_Detail__c
  // -------------------------------------------------------------------------

  /**
   * If the lead's standard LeadSource is "Partner Referral" but the
   * Northstar Lead_Source_Detail__c is blank, copy the value across so the
   * downstream Partner-routing rule and partner-attribution reports both
   * agree. We only fill in blanks — we never overwrite a value the SDR
   * explicitly chose.
   */
  private void normalizeLeadSourceDetail(List<Lead> leads) {
    for (Lead lead : leads) {
      if (
        String.isBlank(lead.Lead_Source_Detail__c) &&
        lead.LeadSource == 'Partner Referral'
      ) {
        lead.Lead_Source_Detail__c = 'Partner Referral';
      }
    }
  }

  // -------------------------------------------------------------------------
  // Behavior 2 — derive Region__c
  // -------------------------------------------------------------------------

  /**
   * When Region__c is blank, infer the Northstar_Region from the lead's
   * standard State / Country. Inference is intentionally conservative — it
   * only sets a value, never overrides one. The full lookup table lives in
   * the *_STATES / *_COUNTRIES constants.
   *
   * Reads `StateCode` / `CountryCode` first (the integration value in orgs
   * with State/Country picklists enabled, e.g. "CA" for California). Falls
   * back to the text fields if codes are blank — that covers orgs without
   * State/Country picklists and integrations that only populate text.
   */
  private void deriveRegion(List<Lead> leads) {
    for (Lead lead : leads) {
      if (String.isNotBlank(lead.Region__c)) {
        continue;
      }
      String state = preferCodeThenText(lead.StateCode, lead.State);
      String country = preferCodeThenText(lead.CountryCode, lead.Country);
      String derived = inferRegion(state, country);
      if (derived != null) {
        lead.Region__c = derived;
      }
    }
  }

  private static String preferCodeThenText(String code, String text) {
    if (String.isNotBlank(code)) {
      return code.trim();
    }
    return normalize(text);
  }

  /**
   * Region inference. Inputs are the raw values from `Lead.StateCode|State`
   * and `Lead.CountryCode|Country` — preferCodeThenText picks the better
   * of the two before we get here. This function then canonicalizes both
   * inputs (case + name→code) so all set membership is case-insensitive
   * and supports the text-fallback path.
   *
   * Critical: state buckets are only applied when the country resolves to
   * US or Canada. Without that gate, a non-US lead with a colliding state
   * code (e.g. Australia StateCode='WA') would be misclassified as
   * NA West.
   */
  @TestVisible
  private static String inferRegion(String stateInput, String countryInput) {
    String state = canonicalState(stateInput);
    String country = canonicalCountry(countryInput);

    // US / Canada: state determines East / West, anything else → NA Central.
    if (country == 'US' || country == 'CA') {
      if (state != null && NA_WEST_STATES.contains(state)) {
        return 'NA West';
      }
      if (state != null && NA_EAST_STATES.contains(state)) {
        return 'NA East';
      }
      return 'NA Central';
    }

    // Anywhere else: country drives the region; state is not consulted.
    if (country != null) {
      if (EMEA_COUNTRIES.contains(country)) {
        return 'EMEA';
      }
      if (APAC_COUNTRIES.contains(country)) {
        return 'APAC';
      }
      if (LATAM_COUNTRIES.contains(country)) {
        return 'LATAM';
      }
    }
    return null;
  }

  /**
   * Canonicalize a state value to an uppercase 2-letter US state code.
   * Returns null when the input doesn't recognizably name a US state —
   * which is fine because inferRegion only applies state buckets to US
   * leads (country-gated).
   */
  @TestVisible
  private static String canonicalState(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    String s = raw.trim().toUpperCase();
    if (s.length() == 2) {
      return s;
    }
    return US_STATE_NAME_TO_CODE.get(s);
  }

  /**
   * Canonicalize a country value. US / Canada variants collapse to 'US' /
   * 'CA' so the inferRegion country gate is a simple equality check.
   * Anything else returns the uppercased input — the regional country
   * sets are pre-uppercased to match.
   */
  @TestVisible
  private static String canonicalCountry(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    String c = raw.trim().toUpperCase();
    if (US_COUNTRY_TOKENS.contains(c)) {
      return 'US';
    }
    if (CA_COUNTRY_TOKENS.contains(c)) {
      return 'CA';
    }
    return c;
  }

  private static String normalize(String s) {
    return String.isBlank(s) ? null : s.trim();
  }

  // -------------------------------------------------------------------------
  // Behavior 3 — stamp Routing_Reason__c via MDT lookup
  // -------------------------------------------------------------------------

  /**
   * Before-context stamping. Used in two scenarios:
   *   - Lead is being inserted with an OwnerId already set to a Queue
   *     (e.g., test data, integration code that pre-assigns).
   *   - Lead is being updated and OwnerId is changing to a Queue
   *     (e.g., a manual reassignment to a queue, or a later AR re-fire).
   * In both cases we can stamp synchronously without a second DML pass.
   *
   * If OwnerId is a User, the previous Routing_Reason__c is preserved as
   * the historical record of how the lead originally got there.
   *
   * Bulk-safe: one SOQL to resolve all Queue Ids → DeveloperNames in the
   * batch, then a single MDT-cache lookup per record.
   */
  private void stampReasonFromCurrentOwner(
    List<Lead> incoming,
    Map<Id, Lead> priors
  ) {
    Set<Id> queueIdsNeeded = new Set<Id>();
    for (Lead lead : incoming) {
      if (!isQueueOwner(lead.OwnerId)) {
        continue;
      }
      if (priors != null && lead.OwnerId == priors.get(lead.Id).OwnerId) {
        continue;
      }
      queueIdsNeeded.add(lead.OwnerId);
    }
    if (queueIdsNeeded.isEmpty()) {
      return;
    }
    Map<Id, String> devNameByQueueId = queueDeveloperNames(queueIdsNeeded);

    for (Lead lead : incoming) {
      if (!isQueueOwner(lead.OwnerId)) {
        continue;
      }
      if (priors != null && lead.OwnerId == priors.get(lead.Id).OwnerId) {
        continue;
      }
      lead.Routing_Reason__c = reasonForDevName(
        devNameByQueueId.get(lead.OwnerId)
      );
    }
  }

  /**
   * After-insert stamping — needed because AssignmentRule fires between
   * beforeInsert and afterInsert, so the queue OwnerId only becomes visible
   * here. Requires a second-pass update DML. Recursion-bounded: the second
   * pass enters beforeUpdate with OwnerId already equal to the queue, so
   * stampReasonFromCurrentOwner skips the re-stamp.
   *
   * Bulk-safe: one SOQL for the queue-Id → DeveloperName resolution, one
   * update for all leads that need a stamp change.
   */
  private void stampReasonAfterAssignment(List<Lead> incoming) {
    Set<Id> queueIdsNeeded = new Set<Id>();
    for (Lead lead : incoming) {
      if (isQueueOwner(lead.OwnerId)) {
        queueIdsNeeded.add(lead.OwnerId);
      }
    }
    if (queueIdsNeeded.isEmpty()) {
      return;
    }
    Map<Id, String> devNameByQueueId = queueDeveloperNames(queueIdsNeeded);

    List<Lead> toUpdate = new List<Lead>();
    for (Lead lead : incoming) {
      if (!isQueueOwner(lead.OwnerId)) {
        continue;
      }
      String expected = reasonForDevName(devNameByQueueId.get(lead.OwnerId));
      if (expected != lead.Routing_Reason__c) {
        toUpdate.add(new Lead(Id = lead.Id, Routing_Reason__c = expected));
      }
    }
    if (!toUpdate.isEmpty()) {
      update toUpdate;
    }
  }

  private static Boolean isQueueOwner(Id ownerId) {
    return ownerId != null &&
      String.valueOf(ownerId).startsWith(QUEUE_ID_PREFIX);
  }

  /**
   * Resolve queue DeveloperName to reason text. Returns a visible
   * "unmapped" sentinel if no MDT row exists for the queue — surfacing
   * a deploy-time problem on the record itself rather than leaving the
   * stamp empty.
   */
  private static String reasonForDevName(String developerName) {
    if (developerName == null) {
      return null;
    }
    Lead_Routing_Reason__mdt row = reasonByQueue().get(developerName);
    if (row != null) {
      return row.Reason__c;
    }
    return String.format(
      UNMAPPED_QUEUE_REASON_FORMAT,
      new List<String>{ developerName }
    );
  }

  /** One SOQL per batch to resolve a set of Queue Group Ids. */
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
   * Cached MDT lookup. Test methods that need to override the cache (e.g.,
   * to test the "unmapped queue" sentinel without deploying an extra row)
   * can call setReasonCache before the trigger fires.
   */
  private static Map<String, Lead_Routing_Reason__mdt> reasonByQueue() {
    if (reasonByQueueCache == null) {
      reasonByQueueCache = new Map<String, Lead_Routing_Reason__mdt>();
      for (Lead_Routing_Reason__mdt row : [
        SELECT Queue_Developer_Name__c, Reason__c
        FROM Lead_Routing_Reason__mdt
      ]) {
        reasonByQueueCache.put(row.Queue_Developer_Name__c, row);
      }
    }
    return reasonByQueueCache;
  }

  @TestVisible
  private static void setReasonCache(
    Map<String, Lead_Routing_Reason__mdt> replacement
  ) {
    reasonByQueueCache = replacement;
  }

  // -------------------------------------------------------------------------
  // Behavior 4 — side-effect Tasks in after-context
  // -------------------------------------------------------------------------

  private void createSideEffectTasks(
    List<Lead> incoming,
    Map<Id, Lead> priors
  ) {
    List<Task> toInsert = new List<Task>();
    for (Lead lead : incoming) {
      Lead prior = priors == null ? null : priors.get(lead.Id);

      if (qualifiesAsHighScoreInbound(lead, prior)) {
        toInsert.add(buildHighScoreTask(lead));
      }
      if (qualifiedTransitionFired(lead, prior)) {
        toInsert.add(buildQualifiedSignalTask(lead));
      }
    }
    if (!toInsert.isEmpty()) {
      insert toInsert;
    }
  }

  private static Boolean qualifiesAsHighScoreInbound(Lead lead, Lead prior) {
    if (!meetsHighScoreBar(lead)) {
      return false;
    }
    if (prior == null) {
      return true;
    }
    // Fire if the prior state did NOT meet the bar — that includes the
    // reopen path (was Disqualified at high score, now active at high
    // score → bar transitioned from false to true → fire). Comparing only
    // score and source missed this case.
    return !meetsHighScoreBar(prior);
  }

  private static Boolean meetsHighScoreBar(Lead lead) {
    return lead.Lead_Score__c != null &&
      lead.Lead_Score__c >= HIGH_SCORE_THRESHOLD &&
      INBOUND_SOURCE_DETAILS.contains(lead.Lead_Source_Detail__c) &&
      lead.Status != 'Closed - Converted' &&
      lead.Status != 'Closed - Not Converted' &&
      lead.Status != 'Disqualified';
  }

  private static Boolean qualifiedTransitionFired(Lead lead, Lead prior) {
    if (lead.Status != 'Qualified') {
      return false;
    }
    if (prior == null) {
      // Insert-at-Qualified is NOT a transition. The spec calls for the
      // signal to fire on a Status → Qualified transition only, otherwise
      // importing historical Qualified leads creates false-positive
      // conversion follow-up signals.
      return false;
    }
    return prior.Status != 'Qualified';
  }

  private static Task buildHighScoreTask(Lead lead) {
    Task t = new Task(
      WhoId = lead.Id,
      Subject = 'Qualify high-score lead — score ' + lead.Lead_Score__c,
      Status = 'Not Started',
      Priority = 'High',
      ActivityDate = Date.today(),
      Lead_Score_At_Creation__c = lead.Lead_Score__c,
      Routing_Reason__c = 'High-score inbound — auto-created by LeadTriggerHandler',
      Action_Plan_Source__c = 'High-Score Inbound Qualification'
    );
    applyLeadOwnership(t, lead);
    return t;
  }

  private static Task buildQualifiedSignalTask(Lead lead) {
    Task t = new Task(
      WhoId = lead.Id,
      Subject = 'Lead Qualified — prepare for conversion follow-up',
      Status = 'Not Started',
      Priority = 'Normal',
      ActivityDate = Date.today().addDays(1),
      Lead_Score_At_Creation__c = lead.Lead_Score__c,
      Routing_Reason__c = 'Qualified status transition — downstream conversion signal',
      Action_Plan_Source__c = 'Lead Qualified Signal'
    );
    applyLeadOwnership(t, lead);
    return t;
  }

  /**
   * Set Task.OwnerId to the lead's owner so SDR follow-up tasks land with
   * the routed owner instead of defaulting to whoever performed the DML
   * (the integration user in API contexts).
   *
   * Caveat: this DE org does not enable Task queues (explicitly
   * lists Lead and Case as the only queue-supporting objects). When the
   * lead is queue-owned, leaving Task.OwnerId default avoids an
   * INVALID_OWNER deploy error. The Task is then visible via the WhoId
   * relationship and downstream automation can re-own it once a queue
   * member picks the lead up.
   */
  private static void applyLeadOwnership(Task t, Lead lead) {
    if (lead.OwnerId != null && !isQueueOwner(lead.OwnerId)) {
      t.OwnerId = lead.OwnerId;
    }
  }
}
