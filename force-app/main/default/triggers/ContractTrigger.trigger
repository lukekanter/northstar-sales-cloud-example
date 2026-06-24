/**
 * ContractTrigger — logicless dispatch per the Kevin O'Hara framework.
 * All behavior lives in ContractTriggerHandler.
 */
trigger ContractTrigger on Contract(before update, after update) {
  new ContractTriggerHandler().run();
}
