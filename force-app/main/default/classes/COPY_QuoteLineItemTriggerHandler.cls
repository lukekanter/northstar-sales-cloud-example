/**
 * COPY_QuoteLineItemTriggerHandler — copies custom OpportunityLineItem field
 * values down to the QuoteLineItem fields they map to, when a Quote is created
 * from an Opportunity.
 *
 * Adapted for Northstar from Doug Ayers'
 * "sfdc-copy-opportunity-line-item-custom-fields-to-quote-line-items"
 * accelerator (BSD-3-Clause — original copyright header preserved below).
 *
 * Northstar adaptations vs the vendor original:
 *   - Renamed with the COPY_ prefix and folded into the repo's Kevin O'Hara
 * TriggerHandler framework: extends TriggerHandler and overrides
 *     beforeInsert/beforeUpdate, so it honours the per-handler bypass API
 *     (TriggerHandler.bypass('COPY_QuoteLineItemTriggerHandler')). The existing
 *     QuoteLineItemTriggerHandler runs in AFTER context (Quote rollup); this
 *     runs in BEFORE context and mutates Trigger.new in place with no DML, so
 *     there is no QLI -> Quote -> QLI recursion between the two.
 *   - The field-mapping config is the Quote_Line_Item_Field_Mapping__mdt Custom
 *     Metadata Type (not the vendor's List custom setting) so the mapping rows
 * ship as deployable, version-controlled metadata.
 *
 * Original vendor attribution:
 *   Developed by Doug Ayers
 *   https://github.com/DouglasCAyers/sfdc-copy-opportunity-line-item-custom-fields-to-quote-line-items
 *   BSD 3-Clause License, Copyright (c) 2017, Doug Ayers. See
 * for the full license text.
 */
public with sharing class COPY_QuoteLineItemTriggerHandler extends TriggerHandler {
  /**
   * New QLIs that already carry a source-OLI link (e.g. created
   * programmatically, or by the test) get their mapped fields copied now. In
   * the live UI flow the link is blank at insert and is stamped by the
   * QuoteLineItem workflow afterwards, which fires the beforeUpdate path below.
   */
  public override void beforeInsert() {
    List<QuoteLineItem> withSource = new List<QuoteLineItem>();
    for (QuoteLineItem qli : (List<QuoteLineItem>) Trigger.new) {
      if (String.isNotBlank(qli.Opportunity_Line_Item_ID__c)) {
        withSource.add(qli);
      }
    }
    copyFields(withSource);
  }

  /**
   * Copy down only when the source-OLI link transitions blank -> populated
   * (the workflow stamping it on create), so re-saving an established QLI does
   * not clobber subsequent manual edits to the mapped fields.
   */
  public override void beforeUpdate() {
    Map<Id, QuoteLineItem> priors = (Map<Id, QuoteLineItem>) Trigger.oldMap;
    List<QuoteLineItem> newlyLinked = new List<QuoteLineItem>();
    for (QuoteLineItem qli : (List<QuoteLineItem>) Trigger.new) {
      QuoteLineItem prior = priors.get(qli.Id);
      if (
        String.isBlank(prior.Opportunity_Line_Item_ID__c) &&
        String.isNotBlank(qli.Opportunity_Line_Item_ID__c)
      ) {
        newlyLinked.add(qli);
      }
    }
    copyFields(newlyLinked);
  }

  /**
   * Given QLIs whose Opportunity_Line_Item_ID__c is populated, read the mapped
   * source fields off the related OpportunityLineItems and assign them onto the
   * QLIs (before-context, no DML). One CMDT read and one OLI query regardless
   * of batch size.
   */
  private void copyFields(List<QuoteLineItem> quoteLineItems) {
    if (quoteLineItems.isEmpty()) {
      return;
    }

    List<Quote_Line_Item_Field_Mapping__mdt> allMappings = [
      SELECT Quote_Line_Item_Field__c, Opportunity_Line_Item_Field__c
      FROM Quote_Line_Item_Field_Mapping__mdt
    ];

    // Keep only mappings whose target QuoteLineItem field can actually be
    // assigned. A mapping that points at a formula/rollup or auto-number field
    // is skipped rather than allowed to throw "not editable" and block the
    // entire QLI DML. Note: this is deliberately NOT an FLS check
    // (isUpdateable/isCreateable) — qli.put() bypasses FLS, so an FLS-based
    // filter would wrongly drop writeable fields the running user lacks grants
    // on. isCalculated()/isAutoNumber() identify the genuinely read-only ones.
    Map<String, Schema.SObjectField> qliFields = Schema.SObjectType.QuoteLineItem.fields.getMap();
    List<Quote_Line_Item_Field_Mapping__mdt> mappings = new List<Quote_Line_Item_Field_Mapping__mdt>();
    for (Quote_Line_Item_Field_Mapping__mdt m : allMappings) {
      Schema.SObjectField target = qliFields.get(m.Quote_Line_Item_Field__c);
      if (target == null) {
        continue;
      }
      Schema.DescribeFieldResult d = target.getDescribe();
      if (!d.isCalculated() && !d.isAutoNumber()) {
        mappings.add(m);
      }
    }
    if (mappings.isEmpty()) {
      return;
    }

    Set<Id> oliIds = new Set<Id>();
    for (QuoteLineItem qli : quoteLineItems) {
      oliIds.add((Id) qli.Opportunity_Line_Item_ID__c);
    }

    // Build the source-field projection. Field names come from the
    // admin-controlled CMDT, not end-user input.
    Set<String> sourceFields = new Set<String>();
    for (Quote_Line_Item_Field_Mapping__mdt m : mappings) {
      sourceFields.add(m.Opportunity_Line_Item_Field__c);
    }
    String soql =
      'SELECT Id, ' +
      String.join(new List<String>(sourceFields), ', ') +
      ' FROM OpportunityLineItem WHERE Id IN :oliIds';
    Map<Id, OpportunityLineItem> oliById = new Map<Id, OpportunityLineItem>(
      (List<OpportunityLineItem>) Database.query(soql)
    );

    for (QuoteLineItem qli : quoteLineItems) {
      OpportunityLineItem oli = oliById.get(
        (Id) qli.Opportunity_Line_Item_ID__c
      );
      if (oli == null) {
        continue;
      }
      for (Quote_Line_Item_Field_Mapping__mdt m : mappings) {
        qli.put(
          m.Quote_Line_Item_Field__c,
          oli.get(m.Opportunity_Line_Item_Field__c)
        );
      }
    }
  }
}
