/**
 * LeadTrigger — logicless dispatch per the Kevin O'Hara framework.
 * All behavior lives in LeadTriggerHandler.
 */
trigger LeadTrigger on Lead(
  before insert,
  before update,
  after insert,
  after update
) {
  new LeadTriggerHandler().run();
}
