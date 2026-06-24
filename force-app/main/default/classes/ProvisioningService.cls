/**
 * ProvisioningService — turns activated Orders into provisioning signals.
 *
 *
 * `dispatch(orderIds)` (called from OrderTriggerHandler on activation):
 *   1. Reads the Orders' line items and resolves each line's product family
 *      via OrderItem.Product_Family_Rollup__c (formula = Product2.Family).
 *   2. Looks up Product_Provisioning_Rule__mdt by family. An order "needs
 *      provisioning" when any of its line families maps to a rule with
 *      Requires_Provisioning__c = true.
 *   3. Publishes one Provisioning_Requested__e per provisioning order and
 *      stamps the parent Order (Provisioning_Status__c = 'Pending', plus
 *      Requires_AI_Dispatch_Setup__c when a matched rule requires it — the
 * field metadata delegates that stamp to this trigger).
 *   4. When a matched rule has Requires_AI_Dispatch_Setup__c = true, also
 *      raises a provisioning Case (Case_Category__c = 'Provisioning') owned
 *      by the Provisioning Exceptions queue so it gets worked.
 *
 * Design notes:
 *   - The Case owner is the Provisioning_Exceptions_Queue resolved by
 *     DeveloperName, NOT the rule's Provisioning_Owner_Group__c — that seed
 *     value (Northstar_Implementation_Managers) is a public group, and Cases
 *     can only be owned by a User or a Queue. The owner group is consumed by
 * the async provisioning job for SLA/escalation, not here.
 *   - Event payload Product_Family__c carries a single representative family,
 *     preferring the AI-dispatch family when the order mixes families.
 *   - Bulk-safe: one SOQL for Orders, one for OrderItems, rules via getAll()
 *     (no SOQL), one Group SOQL only when a Case is actually needed.
 */
public with sharing class ProvisioningService {
  @TestVisible
  private static final String STATUS_PENDING = 'Pending';
  @TestVisible
  private static final String STATUS_NOT_REQUIRED = 'Not Required';
  @TestVisible
  private static final String STATUS_IN_PROGRESS = 'In Progress';
  @TestVisible
  private static final String STATUS_COMPLETED = 'Completed';
  @TestVisible
  private static final String STATUS_FAILED = 'Failed';
  // Order.Status value that means provisioning has been evaluated (dispatch runs
  // on the activation transition). A not-yet-Activated Order's provisioning
  // status is just the field default, not a determination.
  @TestVisible
  private static final String ORDER_ACTIVATED = 'Activated';
  @TestVisible
  private static final String CASE_CATEGORY_PROVISIONING = 'Provisioning';
  @TestVisible
  private static final String CASE_RECORD_TYPE_PROVISIONING = 'Provisioning';
  @TestVisible
  private static final String EXCEPTIONS_QUEUE_DEVNAME = 'Provisioning_Exceptions_Queue';

  // Test seam: when set, overrides the Product_Provisioning_Rule__mdt.getAll()
  // lookup. Custom metadata can't be inserted in tests, so this keeps the
  // unit tests hermetic and independent of which rules happen to be seeded.
  // One test deliberately leaves it null to exercise the real getAll() path
  // against the deployed seed.
  @TestVisible
  private static Map<String, Product_Provisioning_Rule__mdt> rulesOverrideForTest;

  // Captures the last publish for assertions without standing up a subscriber.
  @TestVisible
  private static List<Provisioning_Requested__e> lastEvents;
  @TestVisible
  private static List<Database.SaveResult> lastPublishResults;

  // -------------------------------------------------------------------------
  // Entry point
  // -------------------------------------------------------------------------

  public static void dispatch(Set<Id> orderIds) {
    if (orderIds == null || orderIds.isEmpty()) {
      return;
    }

    Map<Id, Order> ordersById = new Map<Id, Order>(
      [
        SELECT
          Id,
          AccountId,
          Implementation_Package__c,
          Source_Opportunity__c,
          Provisioning_Status__c
        FROM Order
        WHERE Id IN :orderIds
      ]
    );
    // Every activated Order's source Opportunity is recomputed at the end so the
    // Opp's provisioning status is a faithful rollup of its Orders —
    // including the no-provisioning-required case, where the Order stays
    // 'Not Required' and the Opp would otherwise sit 'Pending' forever (the
    // close-won stamp with nothing to clear it).
    Set<Id> sourceOpportunityIds = new Set<Id>();
    for (Order ord : ordersById.values()) {
      if (ord.Source_Opportunity__c != null) {
        sourceOpportunityIds.add(ord.Source_Opportunity__c);
      }
    }
    Map<Id, List<OrderItem>> itemsByOrder = orderItemsByOrder(orderIds);
    Map<String, Product_Provisioning_Rule__mdt> rulesByFamily = rulesByFamily();

    List<Provisioning_Requested__e> events = new List<Provisioning_Requested__e>();
    List<Order> orderStamps = new List<Order>();
    List<Case> provisioningCases = new List<Case>();

    for (Id orderId : orderIds) {
      Order ord = ordersById.get(orderId);
      List<OrderItem> items = itemsByOrder.get(orderId);
      if (ord == null || items == null || items.isEmpty()) {
        continue;
      }

      Boolean needsProvisioning = false;
      Boolean requiresAIDispatch = false;
      String provisioningFamily;
      String aiDispatchFamily;

      for (OrderItem oi : items) {
        String family = oi.Product_Family_Rollup__c;
        if (String.isBlank(family)) {
          continue;
        }
        Product_Provisioning_Rule__mdt rule = rulesByFamily.get(family);
        if (rule == null || rule.Requires_Provisioning__c != true) {
          continue;
        }
        needsProvisioning = true;
        if (provisioningFamily == null) {
          provisioningFamily = family;
        }
        if (rule.Requires_AI_Dispatch_Setup__c == true) {
          requiresAIDispatch = true;
          if (aiDispatchFamily == null) {
            aiDispatchFamily = family;
          }
        }
      }

      if (!needsProvisioning) {
        // Activated Order with no provisioning-required products: establish the
        // definitive 'Not Required' so a stale 'Pending'/'Failed' (e.g. an API
        // edit before activation) does not roll up to the Opportunity — there is
        // no later completion event to correct it. No event/Case. Skip the DML
        // when it is already 'Not Required'.
        if (ord.Provisioning_Status__c != STATUS_NOT_REQUIRED) {
          orderStamps.add(
            new Order(Id = orderId, Provisioning_Status__c = STATUS_NOT_REQUIRED)
          );
        }
        continue;
      }

      // Prefer the AI-dispatch family for the single-value payload so the
      // most actionable family wins when an order mixes families.
      String payloadFamily = aiDispatchFamily != null
        ? aiDispatchFamily
        : provisioningFamily;

      events.add(
        new Provisioning_Requested__e(
          Order_Id__c = orderId,
          Account_Id__c = ord.AccountId,
          Implementation_Package__c = ord.Implementation_Package__c,
          Product_Family__c = payloadFamily,
          Requires_AI_Dispatch__c = requiresAIDispatch
        )
      );
      orderStamps.add(
        new Order(
          Id = orderId,
          Provisioning_Status__c = STATUS_PENDING,
          Requires_AI_Dispatch_Setup__c = requiresAIDispatch,
          // Stamp the kick-off time so downstream SLA/reporting sees the
          // order as started (the field metadata delegates this to the
          // provisioning service).
          Provisioning_Started_At__c = System.now()
        )
      );
      if (requiresAIDispatch) {
        provisioningCases.add(buildProvisioningCase(ord));
      }
    }

    if (!orderStamps.isEmpty()) {
      update orderStamps;
    }
    if (!provisioningCases.isEmpty()) {
      assignExceptionsQueueOwner(provisioningCases);
      insert provisioningCases;
    }
    publishEvents(events);

    // Roll the just-stamped Order state up to each source Opportunity. Done
    // after the Order DML so the recompute reads the new statuses (Pending for
    // provisioning orders; 'Not Required' default for the rest). This clears the
    // Closed Won 'Pending' for deals whose Order needs no provisioning (which
    // never emit a completion event).
    recomputeOpportunityProvisioning(sourceOpportunityIds);
  }

  // -------------------------------------------------------------------------
  // Opportunity provisioning roll-up
  // -------------------------------------------------------------------------

  /**
   * Recompute Opportunity.Provisioning_Status__c as a faithful rollup of its
   * Orders' provisioning statuses, so the Opportunity reflects real provisioning
   * state end-to-end rather than the one-time 'Pending' stamped at Closed Won.
   *
   * Aggregate precedence over the Opp's Orders:
   *   - any Order 'Failed'                    -> 'Failed'
   *   - else any 'Pending' / 'In Progress'    -> 'Pending'  (still in flight)
   *   - else any 'Completed'                  -> 'Completed'
   *   - else (all 'Not Required')             -> 'Not Required'
   * Opportunities with no Orders are left untouched (the Closed Won handoff
   * stamp stands until an Order exists).
   *
   * This is the single rollup used by every Order-state transition — activation
   * dispatch (here) and, once converged, the completion subscriber.
   * Callable as a shared entry point so those paths agree by construction.
   *
   * NON-BLOCKING (Database.update allOrNone=false): a Closed Won Opp may carry a
   * validation rule the running user can't satisfy (e.g.
   * Discount_Approval_Required_For_Close, which is not transition-gated), and
   * this secondary rollup must never abort the Order / provisioning work.
   */
  public static void recomputeOpportunityProvisioning(Set<Id> opportunityIds) {
    Map<Id, String> statusByOpp = provisioningStatusByOpportunity(
      opportunityIds
    );
    if (statusByOpp.isEmpty()) {
      return;
    }
    List<Opportunity> updates = new List<Opportunity>();
    for (Id oppId : statusByOpp.keySet()) {
      updates.add(
        new Opportunity(
          Id = oppId,
          Provisioning_Status__c = statusByOpp.get(oppId)
        )
      );
    }
    logRollupFailures(Database.update(updates, false));
  }

  /**
   * Pure (no-DML) computation of the rolled-up provisioning status for each
   * Opportunity, keyed by Id. Only Opportunities that actually have Orders
   * appear in the result — callers decide the no-Order default (the before-save
   * Closed Won handler stamps 'Pending' as the handoff). Precedence matches
   * recomputeOpportunityProvisioning. Usable from a before-save trigger (which
   * must not DML the records being saved) to set the field in-memory.
   */
  public static Map<Id, String> provisioningStatusByOpportunity(
    Set<Id> opportunityIds
  ) {
    Map<Id, String> out = new Map<Id, String>();
    if (opportunityIds == null || opportunityIds.isEmpty()) {
      return out;
    }
    Set<Id> failed = new Set<Id>();
    Set<Id> inFlight = new Set<Id>();
    Set<Id> completed = new Set<Id>();
    Set<Id> hasOrder = new Set<Id>();
    for (Order o : [
      SELECT Source_Opportunity__c, Provisioning_Status__c, Status
      FROM Order
      WHERE Source_Opportunity__c IN :opportunityIds
    ]) {
      Id oppId = o.Source_Opportunity__c;
      hasOrder.add(oppId);
      // A not-yet-Activated Order's provisioning is undetermined — it is only
      // evaluated at activation (OrderTriggerHandler -> dispatch) — so its
      // default 'Not Required' must NOT make the deal look resolved. Treat any
      // non-Activated Order as in flight (Pending).
      Boolean activated = o.Status == ORDER_ACTIVATED;
      if (activated && o.Provisioning_Status__c == STATUS_FAILED) {
        failed.add(oppId);
      } else if (
        !activated ||
        o.Provisioning_Status__c == STATUS_PENDING ||
        o.Provisioning_Status__c == STATUS_IN_PROGRESS
      ) {
        inFlight.add(oppId);
      } else if (o.Provisioning_Status__c == STATUS_COMPLETED) {
        completed.add(oppId);
      }
    }
    for (Id oppId : hasOrder) {
      if (failed.contains(oppId)) {
        out.put(oppId, STATUS_FAILED);
      } else if (inFlight.contains(oppId)) {
        out.put(oppId, STATUS_PENDING);
      } else if (completed.contains(oppId)) {
        out.put(oppId, STATUS_COMPLETED);
      } else {
        out.put(oppId, STATUS_NOT_REQUIRED);
      }
    }
    return out;
  }

  private static void logRollupFailures(List<Database.SaveResult> results) {
    for (Database.SaveResult sr : results) {
      if (sr.isSuccess()) {
        continue;
      }
      for (Database.Error err : sr.getErrors()) {
        System.debug(
          LoggingLevel.WARN,
          'Opportunity provisioning roll-up skipped for ' +
            sr.getId() +
            ': ' +
            err.getMessage()
        );
      }
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  private static Map<Id, List<OrderItem>> orderItemsByOrder(Set<Id> orderIds) {
    Map<Id, List<OrderItem>> out = new Map<Id, List<OrderItem>>();
    for (OrderItem oi : [
      SELECT OrderId, Product_Family_Rollup__c
      FROM OrderItem
      WHERE OrderId IN :orderIds
    ]) {
      if (!out.containsKey(oi.OrderId)) {
        out.put(oi.OrderId, new List<OrderItem>());
      }
      out.get(oi.OrderId).add(oi);
    }
    return out;
  }

  private static Map<String, Product_Provisioning_Rule__mdt> rulesByFamily() {
    if (rulesOverrideForTest != null) {
      return rulesOverrideForTest;
    }
    Map<String, Product_Provisioning_Rule__mdt> out = new Map<String, Product_Provisioning_Rule__mdt>();
    for (
      Product_Provisioning_Rule__mdt rule : Product_Provisioning_Rule__mdt.getAll()
        .values()
    ) {
      if (String.isNotBlank(rule.Product_Family__c)) {
        out.put(rule.Product_Family__c, rule);
      }
    }
    return out;
  }

  private static Case buildProvisioningCase(Order ord) {
    // Origin is intentionally left unset: the CaseOrigin standard value set
    // only defines Phone/Email/Web, so any other value would fail a
    // restricted-picklist check and roll back the whole order activation.
    Case c = new Case(
      Subject = 'AI Dispatch provisioning setup for order ' + ord.Id,
      Status = 'New',
      Case_Category__c = CASE_CATEGORY_PROVISIONING,
      Related_Order__c = ord.Id
    );
    Id recordTypeId = provisioningCaseRecordTypeId();
    if (recordTypeId != null) {
      c.RecordTypeId = recordTypeId;
    }
    return c;
  }

  /**
   * Id of the Case 'Provisioning' record type (businessProcess
   * Provisioning_Process), or null if it isn't present/active in this org —
   * in which case the Case falls back to the running user's default type
   * rather than failing the activation.
   */
  private static Id provisioningCaseRecordTypeId() {
    Schema.RecordTypeInfo info = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName()
      .get(CASE_RECORD_TYPE_PROVISIONING);
    return (info != null && info.isActive()) ? info.getRecordTypeId() : null;
  }

  /**
   * Point the provisioning Cases at the Provisioning Exceptions queue. If the
   * queue can't be resolved (e.g. not deployed in a given org) the Cases keep
   * the running user as owner rather than failing the activation.
   */
  private static void assignExceptionsQueueOwner(List<Case> cases) {
    Id queueId = exceptionsQueueId();
    if (queueId == null) {
      return;
    }
    for (Case c : cases) {
      c.OwnerId = queueId;
    }
  }

  private static Id exceptionsQueueId() {
    List<Group> queues = [
      SELECT Id
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = :EXCEPTIONS_QUEUE_DEVNAME
      LIMIT 1
    ];
    return queues.isEmpty() ? null : queues[0].Id;
  }

  private static void publishEvents(List<Provisioning_Requested__e> events) {
    if (events.isEmpty()) {
      return;
    }
    lastEvents = events;
    lastPublishResults = EventBus.publish(events);
    logPublishFailures(lastPublishResults);
  }

  /**
   * Log any failed Provisioning_Requested__e enqueue. Per the issue this is a
   * log-and-continue path (the activation has already committed); a failed
   * publish doesn't roll the Order back.
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
          'Provisioning_Requested__e publish failed: ' + err.getMessage()
        );
      }
    }
  }
}
