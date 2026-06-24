// Adapted from Quicker-Quotes (https://github.com/SalesforceLabs/Quicker-Quotes) @ d1c406e — BSD 3-Clause (© 2024 salesforce.com, inc.). See LICENSES/.
global with sharing class QQ_UpsertAndDeleteQuoteLineItems {
  @InvocableMethod(
    label='Upsert Quote Line Items'
    description='Upserts quote line items after an update to the BOM'
  )
  global static void upsertQuoteLineItems(List<RequestInput> inputs) {
    RequestInput ri = inputs[0];
    // QQ patch: normalize null collections. The edit flow can finish
    // neither output attribute dispatched (e.g. an empty quote opened then
    // finished), so the invocable can receive null lists; calling .size() on
    // them would fault instead of letting the user exit cleanly.
    List<QuoteLineItem> lineItems = ri.lineItems != null
      ? ri.lineItems
      : new List<QuoteLineItem>();
    List<QuoteLineItem> deletedLineItems = ri.deletedLineItems != null
      ? ri.deletedLineItems
      : new List<QuoteLineItem>();
    // QQ patch: make the upsert + delete one atomic unit and fail loudly.
    // Upstream caught DML errors with System.debug and then fell through to the
    // delete, so a failed replacement upsert (validation rule, trigger addError,
    // FLS) would still delete the original line — silently losing it while the
    // flow appeared to finish. Roll back and rethrow so the flow surfaces a fault
    // instead of corrupting the quote. Diverges from upstream d1c406e.
    Savepoint sp = Database.setSavepoint();
    try {
      if (lineItems.size() > 0) {
        // QQ patch: throw on insufficient create/update access (object OR
        // field level) rather than silently skipping the upsert. Upstream only
        // skipped, then still ran the delete below — discarding the user's edits
        // and dropping a replaced line. Failing lets the flow fault instead.
        // Only the fields this action actually writes are gated — Product2Id is
        // derived from PricebookEntryId and isn't user-writable, so gating on it
        // faulted ordinary quantity/discount edits for non-admins.
        Boolean canUpsert =
          Schema.SObjectType.QuoteLineItem.isCreateable() &&
          Schema.SObjectType.QuoteLineItem.isUpdateable() &&
          Schema.sObjectType.QuoteLineItem.fields.Quantity.isCreateable() &&
          Schema.sObjectType.QuoteLineItem.fields.UnitPrice.isCreateable() &&
          Schema.sObjectType.QuoteLineItem.fields.Discount.isCreateable() &&
          Schema.sObjectType.QuoteLineItem.fields.Quantity.isUpdateable() &&
          Schema.sObjectType.QuoteLineItem.fields.UnitPrice.isUpdateable() &&
          Schema.sObjectType.QuoteLineItem.fields.Discount.isUpdateable();
        if (!canUpsert) {
          throw new DmlException(
            'User does not have access to upsert Quote Line Items'
          );
        }
        upsert lineItems;
      }
      if (deletedLineItems.size() > 0) {
        // QQ patch: throw on missing delete access rather than silently
        // skipping — otherwise a delete (or product replacement) appears to save
        // while the original line remains, leaving a duplicate/partial result.
        if (!QuoteLineItem.SObjectType.getDescribe().isDeletable()) {
          throw new DmlException(
            'User does not have access to delete Quote Line Items'
          );
        }
        delete deletedLineItems;
      }
    } catch (Exception e) {
      Database.rollback(sp);
      throw e;
    }
  }

  global class RequestInput {
    @InvocableVariable(label='Quote Line Items' required=true)
    global List<QuoteLineItem> lineItems;
    @InvocableVariable(label='Deleted Line Items' required=true)
    global List<QuoteLineItem> deletedLineItems;
  }
}
