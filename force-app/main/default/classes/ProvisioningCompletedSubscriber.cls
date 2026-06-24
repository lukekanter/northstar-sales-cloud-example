/**
 * ProvisioningCompletedSubscriber — consumes Provisioning_Completed__e.
 *
 *
 * Provisioning_Completed__e.Status__c is a Text field with the documented
 * enumerated convention Success / Failure / Partial (platform-event fields
 * can't be Picklists). This subscriber treats:
 *   - 'Success' on a resolvable, existing Order → stamp the Order
 *     Provisioning_Status__c = 'Completed' + Provisioning_Completed_At__c.
 *   - 'Failure' / 'Partial' / any other token, on a resolvable existing Order →
 *     stamp Provisioning_Status__c = 'Failed' + Provisioning_Completed_At__c
 *     AND raise a Provisioning Exception Case. (Partial is surfaced for triage
 *     rather than left mid-flight; the Order has no 'Partial' status, and the
 *     completion timestamp is stamped on both finished outcomes per the field
 *     contract.)
 *   - A missing / unparseable / deleted Order_Id__c → raise an unlinked
 *     Provisioning Exception Case only (no Order to stamp).
 *
 * Case ownership + record type mirror ProvisioningService — the
 * Case is owned by the Provisioning_Exceptions_Queue and carries the
 * Provisioning record type, each resolved defensively.
 */
public with sharing class ProvisioningCompletedSubscriber {
  @TestVisible
  private static final String STATUS_SUCCESS = 'Success';
  @TestVisible
  private static final String ORDER_STATUS_COMPLETED = 'Completed';
  @TestVisible
  private static final String ORDER_STATUS_FAILED = 'Failed';
  @TestVisible
  private static final String CASE_CATEGORY_PROVISIONING = 'Provisioning';
  @TestVisible
  private static final String CASE_RECORD_TYPE_PROVISIONING = 'Provisioning';
  @TestVisible
  private static final String EXCEPTIONS_QUEUE_DEVNAME = 'Provisioning_Exceptions_Queue';

  // Captures for assertions (mirrors ProvisioningService).
  @TestVisible
  private static List<Order> lastOrdersStamped;
  @TestVisible
  private static List<Case> lastExceptionCases;

  public static void handle(List<Provisioning_Completed__e> events) {
    if (events == null || events.isEmpty()) {
      return;
    }

    // Resolve every referenced Order Id once; the existence check is shared by
    // both the success and failure outcomes (a Case can't link a deleted Order,
    // and a "Success" naming a non-existent Order is itself a data gap).
    Set<Id> referenced = new Set<Id>();
    for (Provisioning_Completed__e e : events) {
      Id orderId = toOrderId(e.Order_Id__c);
      if (orderId != null) {
        referenced.add(orderId);
      }
    }
    Set<Id> existingOrderIds = referenced.isEmpty()
      ? new Set<Id>()
      : new Map<Id, Order>([SELECT Id FROM Order WHERE Id IN :referenced])
          .keySet();

    Map<Id, Order> orderUpdates = new Map<Id, Order>();
    List<Provisioning_Completed__e> exceptions = new List<Provisioning_Completed__e>();

    for (Provisioning_Completed__e e : events) {
      Id orderId = toOrderId(e.Order_Id__c);
      Boolean orderExists =
        orderId != null && existingOrderIds.contains(orderId);

      if (e.Status__c == STATUS_SUCCESS && orderExists) {
        orderUpdates.put(
          orderId,
          stampedOrder(orderId, ORDER_STATUS_COMPLETED)
        );
      } else {
        // Failure / Partial / unknown status, or a "Success" naming a missing
        // Order — all surface as exceptions. Stamp the Order 'Failed' when it
        // exists so Order-level status/reporting reflects the finished outcome.
        if (orderExists) {
          orderUpdates.put(orderId, stampedOrder(orderId, ORDER_STATUS_FAILED));
        }
        exceptions.add(e);
      }
    }

    if (!orderUpdates.isEmpty()) {
      update orderUpdates.values();
    }
    lastOrdersStamped = orderUpdates.isEmpty() ? null : orderUpdates.values();
    raiseExceptionCases(exceptions, existingOrderIds);

    // Roll the just-stamped Order state up to each source Opportunity via the
    // single shared rollup, so completion and activation use one
    // implementation. Resolve the stamped Orders' source Opportunities (the
    // stamped Order sObjects here carry only Id/status), then delegate — the
    // shared helper is Status-aware, non-blocking, and authoritative.
    if (!orderUpdates.isEmpty()) {
      Set<Id> sourceOpportunityIds = new Set<Id>();
      for (Order o : [
        SELECT Source_Opportunity__c
        FROM Order
        WHERE
          Id IN :orderUpdates.keySet()
          AND Source_Opportunity__c != NULL
      ]) {
        sourceOpportunityIds.add(o.Source_Opportunity__c);
      }
      ProvisioningService.recomputeOpportunityProvisioning(
        sourceOpportunityIds
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Exception Cases
  // ---------------------------------------------------------------------------

  private static void raiseExceptionCases(
    List<Provisioning_Completed__e> failures,
    Set<Id> existingOrderIds
  ) {
    if (failures.isEmpty()) {
      lastExceptionCases = null;
      return;
    }
    Id recordTypeId = provisioningCaseRecordTypeId();
    Id queueId = exceptionsQueueId();
    List<Case> cases = new List<Case>();
    for (Provisioning_Completed__e e : failures) {
      Id orderId = toOrderId(e.Order_Id__c);
      Boolean linkable = orderId != null && existingOrderIds.contains(orderId);
      Case c = new Case(
        Subject = 'Provisioning did not complete for order ' +
          (orderId != null ? String.valueOf(orderId) : '(unknown)'),
        Status = 'New',
        Case_Category__c = CASE_CATEGORY_PROVISIONING,
        Related_Order__c = linkable ? orderId : null,
        Provisioning_Failure_Reason__c = failureReason(e)
      );
      if (recordTypeId != null) {
        c.RecordTypeId = recordTypeId;
      }
      if (queueId != null) {
        c.OwnerId = queueId;
      }
      cases.add(c);
    }
    insert cases;
    lastExceptionCases = cases;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private static Order stampedOrder(Id orderId, String status) {
    return new Order(
      Id = orderId,
      Provisioning_Status__c = status,
      Provisioning_Completed_At__c = System.now()
    );
  }

  /** Parse the event's text Order_Id__c into an Order Id, or null if unusable. */
  private static Id toOrderId(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    try {
      Id parsed = Id.valueOf(raw);
      return parsed.getSObjectType() == Order.SObjectType ? parsed : null;
    } catch (System.StringException e) {
      return null;
    }
  }

  private static String failureReason(Provisioning_Completed__e e) {
    if (String.isNotBlank(e.Failure_Reason__c)) {
      return e.Failure_Reason__c;
    }
    return String.isBlank(e.Order_Id__c)
      ? 'Provisioning_Completed event received without an Order Id.'
      : 'Provisioning reported status "' + e.Status__c + '".';
  }

  private static Id provisioningCaseRecordTypeId() {
    Schema.RecordTypeInfo info = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName()
      .get(CASE_RECORD_TYPE_PROVISIONING);
    return (info != null && info.isActive()) ? info.getRecordTypeId() : null;
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
}
