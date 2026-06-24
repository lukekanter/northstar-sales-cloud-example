/**
 * OrderTrigger — logicless dispatch per the Kevin O'Hara framework.
 * All behavior lives in OrderTriggerHandler.
 *
 * Only `after update` is wired: the provisioning hand-off keys off the
 * Status transition INTO 'Activated', which can only happen on an update
 * (Orders are created Draft and activated later).
 */
trigger OrderTrigger on Order(after update) {
  new OrderTriggerHandler().run();
}
