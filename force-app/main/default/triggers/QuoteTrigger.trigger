/**
 * QuoteTrigger — logicless dispatch per the Kevin O'Hara framework.
 * All behavior lives in QuoteTriggerHandler.
 */
trigger QuoteTrigger on Quote(before insert, before update, after update) {
  new QuoteTriggerHandler().run();
}
