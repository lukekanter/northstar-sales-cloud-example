/**
 * QuoteLineItemTrigger — logicless dispatch per the Kevin O'Hara framework.
 * All behavior lives in QuoteLineItemTriggerHandler.
 *
 * Why it exists: QuoteTriggerHandler recomputes the blended discount and the
 * per-dimension approval state only when the parent Quote is saved. Direct
 * edits to QuoteLineItems (Discount, UnitPrice, Quantity, Revenue_Type__c)
 * didn't roll up to the parent until this trigger was added — it flagged
 * the stale Finance_Approval_Status__c discriminator as a risk,
 * mirroring the OpportunityLineItem fix.
 */
trigger QuoteLineItemTrigger on QuoteLineItem(
  after insert,
  after update,
  after delete,
  after undelete
) {
  new QuoteLineItemTriggerHandler().run();
}
