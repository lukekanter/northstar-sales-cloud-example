/**
 * CaseTrigger — logicless dispatch per the Kevin O'Hara framework.
 * All behavior lives in CaseTriggerHandler.
 *
 * `after insert`  — flag Provisioning-exception cases that arrive without a
 *                   Related_Order__c so the Provisioning Exceptions queue can
 *                   see the gap.
 * `after update`  — escalate cases that transition INTO High/Critical renewal
 *                   risk (publishes Renewal_Risk_Raised__e).
 */
trigger CaseTrigger on Case(after insert, after update) {
  new CaseTriggerHandler().run();
}
