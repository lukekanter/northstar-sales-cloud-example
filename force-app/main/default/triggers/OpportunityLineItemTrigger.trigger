/**
 * OpportunityLineItemTrigger — logicless dispatch per the Kevin O'Hara
 * framework. All behavior lives in
 * OpportunityLineItemTriggerHandler.
 *
 * Why it exists: OpportunityTriggerHandler can only recalculate ARR/ACV
 * when the parent Opportunity is touched. Direct edits to OLIs (Quantity,
 * UnitPrice, Revenue_Type__c) didn't roll up to the parent until this
 * trigger was added — it was flagged as a staleness risk.
 */
trigger OpportunityLineItemTrigger on OpportunityLineItem(
  after insert,
  after update,
  after delete,
  after undelete
) {
  new OpportunityLineItemTriggerHandler().run();
}
