/**
 * QuoteLineItemTriggerHandler — rolls QuoteLineItem changes up to the parent
 * Quote's trigger-maintained fields (Total_Discount_Percent__c and the three
 * approval dimensions).
 *
 * Fires on after-insert / after-update / after-delete / after-undelete.
 * Collects the affected parent Quote Ids (both new and old parents when
 * QuoteId reassigns) and re-saves those Quotes, which re-fires
 * QuoteTriggerHandler.beforeUpdate so the blended discount and the
 * Discount/Legal/Finance approval state are recomputed from the CURRENT line
 * set. Without this, editing a QLI without re-saving the parent left those
 * fields stale — the same staleness the
 * OpportunityLineItem trigger fixed.
 *
 * Recursion: the parent-Quote re-save runs QuoteTriggerHandler, which does no
 * QuoteLineItem DML (it only SOQL-queries QLIs and, in afterUpdate, may update
 * the parent Opportunity). So there is no QLI -> Quote -> QLI loop and no
 * bypass is needed. Overflow on the QLI fetch is handled inside
 * QuoteTriggerHandler (its own QLI_ROW_CAP addError path), which rolls back the
 * triggering QLI DML too, so this handler delegates rather than re-checking.
 */
public with sharing class QuoteLineItemTriggerHandler extends TriggerHandler {
  public override void afterInsert() {
    resaveParents(parentIdsFromNew());
  }

  public override void afterUpdate() {
    resaveParents(parentIdsFromUpdate());
  }

  public override void afterDelete() {
    resaveParents(parentIdsFromOld());
  }

  public override void afterUndelete() {
    resaveParents(parentIdsFromNew());
  }

  private Set<Id> parentIdsFromNew() {
    Set<Id> ids = new Set<Id>();
    for (QuoteLineItem qli : (List<QuoteLineItem>) Trigger.new) {
      if (qli.QuoteId != null) {
        ids.add(qli.QuoteId);
      }
    }
    return ids;
  }

  private Set<Id> parentIdsFromOld() {
    Set<Id> ids = new Set<Id>();
    for (QuoteLineItem qli : (List<QuoteLineItem>) Trigger.old) {
      if (qli.QuoteId != null) {
        ids.add(qli.QuoteId);
      }
    }
    return ids;
  }

  /**
   * On update, only re-save when a field that feeds the blended discount or
   * the services-floor check actually changed. A QLI can't reparent to another
   * Quote in practice, but guard for it for symmetry with the OLI handler.
   */
  private Set<Id> parentIdsFromUpdate() {
    Map<Id, QuoteLineItem> priors = (Map<Id, QuoteLineItem>) Trigger.oldMap;
    Set<Id> ids = new Set<Id>();
    for (QuoteLineItem qli : (List<QuoteLineItem>) Trigger.new) {
      QuoteLineItem prior = priors.get(qli.Id);
      if (
        qli.Discount != prior.Discount ||
        qli.UnitPrice != prior.UnitPrice ||
        qli.Quantity != prior.Quantity ||
        qli.Revenue_Type__c != prior.Revenue_Type__c ||
        qli.QuoteId != prior.QuoteId
      ) {
        if (qli.QuoteId != null) {
          ids.add(qli.QuoteId);
        }
        if (prior.QuoteId != null && prior.QuoteId != qli.QuoteId) {
          ids.add(prior.QuoteId);
        }
      }
    }
    return ids;
  }

  private void resaveParents(Set<Id> parentQuoteIds) {
    if (parentQuoteIds.isEmpty()) {
      return;
    }
    // Re-query (not Trigger context) and update — QuoteTriggerHandler's
    // beforeUpdate recomputes Total_Discount_Percent__c and the approval
    // dimensions from the current QLI set. A no-field-change update still
    // fires before-update triggers, which is exactly what we want.
    List<Quote> parents = [
      SELECT Id
      FROM Quote
      WHERE Id IN :parentQuoteIds
    ];
    if (!parents.isEmpty()) {
      update parents;
    }
  }
}
