/**
 * OrderTriggerHandler — Northstar Order and Provisioning behaviors.
 *
 * One behavior:
 *   - afterUpdate: on the Status transition INTO 'Activated', hand the
 *     activated Order Ids to ProvisioningService.dispatch(...), which reads
 *     the line items, consults Product_Provisioning_Rule__mdt, publishes
 *     Provisioning_Requested__e, and raises a provisioning Case when a
 *     matched rule requires AI Dispatch setup.
 *
 * Recursion: the hand-off fires only on the activation edge
 * (prior.Status != 'Activated' AND current == 'Activated'). The service's
 * second-pass Order stamp (Provisioning_Status__c / Requires_AI_Dispatch_Setup__c)
 * leaves Status unchanged, so the re-entrant afterUpdate sees no transition
 * and does nothing — no setMaxLoopCount needed (consistent with the other
 * Northstar handlers).
 */
public with sharing class OrderTriggerHandler extends TriggerHandler {
  @TestVisible
  private static final String STATUS_ACTIVATED = 'Activated';

  public override void afterUpdate() {
    Set<Id> activatedIds = activatedOrderIds(
      (List<Order>) Trigger.new,
      (Map<Id, Order>) Trigger.oldMap
    );
    if (!activatedIds.isEmpty()) {
      ProvisioningService.dispatch(activatedIds);
    }
  }

  /**
   * Ids of Orders that just transitioned INTO 'Activated'. Steady-state
   * Activated orders (and orders updated for any other reason) are excluded,
   * so an already-activated order re-saved later does not re-provision.
   */
  private static Set<Id> activatedOrderIds(
    List<Order> incoming,
    Map<Id, Order> priors
  ) {
    Set<Id> out = new Set<Id>();
    for (Order ord : incoming) {
      Order prior = priors.get(ord.Id);
      if (
        ord.Status == STATUS_ACTIVATED &&
        prior != null &&
        prior.Status != STATUS_ACTIVATED
      ) {
        out.add(ord.Id);
      }
    }
    return out;
  }
}
