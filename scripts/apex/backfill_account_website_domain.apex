// backfill_account_website_domain.apex
// One-time backfill for Account.Website_Domain__c.
//
// Website_Domain__c is stamped by the Account_Before_Save_Set_Website_Domain
// before-save flow, which only runs on records saved AFTER it deploys. Accounts
// that existed before the deploy keep a blank Website_Domain__c until next saved,
// and because Northstar_Account_Match uses NullNotAllowed, a new Account would
// not alert against those un-stamped existing records. This script re-saves
// every Account that has a Website but no Website_Domain__c so the before-save
// flow populates the field. Run ONCE post-merge (after the field + flow + rule
// are in the org), e.g.:
//
//   sf apex run --file scripts/apex/backfill_account_website_domain.apex \
//     --target-org "$NS_ORG"
//
// Idempotent: re-running only touches rows still missing the domain. A bare
// `update` (no field changes) still fires the before-save flow, which does the
// computation. Batched at 10k to stay under DML row limits; re-run if the org
// has more than 10k matching Accounts.
List<Account> toBackfill = [
  SELECT Id
  FROM Account
  WHERE Website != null AND Website_Domain__c = null
  LIMIT 10000
];
if (!toBackfill.isEmpty()) {
  update toBackfill;
}
System.debug('Website_Domain__c backfill re-saved ' + toBackfill.size() + ' Account(s).');
