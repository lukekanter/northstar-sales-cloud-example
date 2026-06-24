/**
 * COPY_QuoteLineItemTrigger — logicless dispatch for the
 * Copy-OLI-to-QLI accelerator.
 *
 * Runs in BEFORE context so the mapped custom fields are stamped on the
 * QuoteLineItem in the same transaction that links it to its source
 * OpportunityLineItem (no extra DML). Coexists with the separate
 * after-context QuoteLineItemTrigger (parent-Quote rollup); the two have
 * independent concerns. All logic lives in COPY_QuoteLineItemTriggerHandler.
 */
trigger COPY_QuoteLineItemTrigger on QuoteLineItem(
  before insert,
  before update
) {
  new COPY_QuoteLineItemTriggerHandler().run();
}
