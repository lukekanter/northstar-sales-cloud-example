/**
 * ProvisioningCompletedTrigger — subscribes to Provisioning_Completed__e and
 * immediately dispatches to ProvisioningCompletedSubscriber. Event
 * subscribers run as the Automated Process user in an async after-insert
 * context; all behavior lives in the handler so it stays unit-testable.
 */
trigger ProvisioningCompletedTrigger on Provisioning_Completed__e(
  after insert
) {
  ProvisioningCompletedSubscriber.handle(Trigger.new);
}
