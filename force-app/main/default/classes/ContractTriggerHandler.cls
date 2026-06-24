/**
 * ContractTriggerHandler — Northstar Contract behaviors.
 *
 * Two behaviors:
 *   - afterUpdate: on the Status transition INTO 'Activated', hand the
 *     activated Contract ids to RenewalService.createRenewalOpportunity,
 *     which spawns (or schedules) the Renewal Opportunity.
 *   - beforeUpdate: when Renewal_Opportunity__c is newly linked (null → set),
 *     stamp the renewal bookkeeping — Renewal_Created__c = true and
 *     Renewal_Created_Date__c = today. RenewalService links the Opp back to
 *     the Contract via a second-pass update, and this stamp rides that same
 *     save.
 *
 * Recursion: the renewal hand-off fires only on the activation edge, and the
 * second-pass link update leaves Status unchanged, so it never re-enters the
 * renewal path. The bookkeeping stamp is naturally idempotent (it only fires
 * on the null → set transition of Renewal_Opportunity__c).
 */
public with sharing class ContractTriggerHandler extends TriggerHandler {
  @TestVisible
  private static final String STATUS_ACTIVATED = 'Activated';

  public override void beforeUpdate() {
    stampRenewalBookkeeping(
      (List<Contract>) Trigger.new,
      (Map<Id, Contract>) Trigger.oldMap
    );
  }

  public override void afterUpdate() {
    Set<Id> activatedIds = activatedContractIds(
      (List<Contract>) Trigger.new,
      (Map<Id, Contract>) Trigger.oldMap
    );
    if (!activatedIds.isEmpty()) {
      RenewalService.createRenewalOpportunity(activatedIds);
    }
  }

  /**
   * Stamp Renewal_Created__c / Renewal_Created_Date__c when the renewal Opp
   * is first linked. Only fires on the null → set transition of
   * Renewal_Opportunity__c, so manual edits to an already-linked contract
   * don't re-stamp the date.
   */
  private static void stampRenewalBookkeeping(
    List<Contract> incoming,
    Map<Id, Contract> priors
  ) {
    for (Contract con : incoming) {
      Contract prior = priors.get(con.Id);
      Boolean justLinked =
        con.Renewal_Opportunity__c != null &&
        (prior == null ||
        prior.Renewal_Opportunity__c == null);
      if (justLinked) {
        con.Renewal_Created__c = true;
        con.Renewal_Created_Date__c = Date.today();
      }
    }
  }

  private static Set<Id> activatedContractIds(
    List<Contract> incoming,
    Map<Id, Contract> priors
  ) {
    Set<Id> out = new Set<Id>();
    for (Contract con : incoming) {
      Contract prior = priors.get(con.Id);
      if (
        con.Status == STATUS_ACTIVATED &&
        prior != null &&
        prior.Status != STATUS_ACTIVATED
      ) {
        out.add(con.Id);
      }
    }
    return out;
  }
}
