/**
 * seed_qq_config.apex — idempotent seed for the Quicker Quotes custom settings
 *.
 *
 * QQ_Config__c (Hierarchy) and QQ_Quote_Template__c (List) hold *data*, not
 * deployable metadata, and creating them at runtime needs Customize Application
 * — which the Northstar_Sales_* personas (correctly) lack. The QQ_New_Quote2
 * flow's first-run branch creates these records, so a non-admin first-runner
 * faults. This script seeds them up front so the first-run branch never fires.
 *
 * Run once per org (e.g. on a fresh clone):
 *   sf apex run --file scripts/apex/seed_qq_config.apex --target-org <alias>
 *
 * Idempotent: upserts the org-default QQ_Config__c. Use_PDF__c is seeded false,
 * so no QQ_Quote_Template__c row is needed (that List setting requires a real
 * Template_Id__c document, only used on the PDF path); add one manually if PDF
 * generation is later enabled.
 */
QQ_Config__c cfg = QQ_Config__c.getOrgDefaults();
if (cfg == null || cfg.Id == null) {
  cfg = new QQ_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
}
// Pre-proposal stage so the new Opportunity never trips
// Cannot_Move_To_Proposal_Without_Products before line items exist.
cfg.Opportunity_Stage_Name__c = 'Qualify';
cfg.Default_Quote_Validity__c = 30;
cfg.Use_PDF__c = false;
upsert cfg;
System.debug('Seeded QQ_Config__c org default: ' + cfg.Id);
