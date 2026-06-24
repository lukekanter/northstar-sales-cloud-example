/**
 * OpportunityTrigger — logicless dispatch per the Kevin O'Hara framework.
 * All behavior lives in OpportunityTriggerHandler.
 */
trigger OpportunityTrigger on Opportunity(
  before insert,
  before update,
  after insert,
  after update
) {
  new OpportunityTriggerHandler().run();
}
