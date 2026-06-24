/*
Action Plans v4
David Schach 2022
https://appexchange.salesforce.com/appxListingDetail?listingId=a0N4V00000Gg6NVUAZ

Copyright (c) 2022, salesforce.com, inc.
All rights reserved.
SPDX-License-Identifier: BSD-3-Clause
For full license text, see the LICENSE file in the repo root or https://opensource.org/licenses/BSD-3-Clause
*/
/**
 * Test class for Section Header Visualforce Controller
 * @author {@link [David Schach](https://github.com/dschach)}
 * @since 2022
 * @see ActionPlansSectionHeaderController
 * @group Tests
 */
@IsTest
private class ActionPlansSectionHeaderControllerTest {
	/**
	 * Set up custom settings
	 */
	@TestSetup
	private static void makeData() {
		ActionPlansTestUtilities testUtil = new ActionPlansTestUtilities();
		User u = testUtil.createTestUser();
		testUtil.assignAPPermissionSets(u.Id, false);
	}

	@IsTest
	private static void objectTabDescribePositive() {
		User u = [SELECT Id FROM User WHERE Email = 'test@aptest.com' AND IsActive = TRUE LIMIT 1];

		System.runAs(u) {
			ActionPlansSectionHeaderController shc = new ActionPlansSectionHeaderController();
			shc.objectName = ActionPlansUtilities.namespacePrefix + 'ActionPlan__c';
			shc.getObjectIconInfo();
			Assert.isTrue(shc.getIsCustom(), 'ActionPlan is a custom object');

			shc = new ActionPlansSectionHeaderController();
			shc.objectName = 'Account';
			shc.getObjectIconInfo();
			Assert.isFalse(shc.getIsCustom(), 'Account is a standard object');
		}
	}

	@IsTest
	private static void objectTabDescribeNegative() {
		User u = [SELECT Id FROM User WHERE Email = 'test@aptest.com' LIMIT 1];

		System.runAs(u) {
			ActionPlansSectionHeaderController shc = new ActionPlansSectionHeaderController();
			shc.objectName = 'CaseComment';
			shc.getObjectIconInfo();
			Assert.isFalse(shc.getIsCustom(), 'CaseComment is a standard object');

			shc = new ActionPlansSectionHeaderController();
			shc.objectName = ActionPlansUtilities.namespacePrefix + 'APTask__c';
			shc.getObjectIconInfo();
			Assert.isTrue(shc.getIsCustom(), 'APTask is a custom object');
			Map<String, String> iconInfo = shc.getObjectIconInfo();
			Assert.areEqual(iconInfo.get('iconTag'), 'record', 'Should not be a tab/icon for APTask');
		}
	}

	@IsTest
	private static void objectTabDescribeNotInApplication() {
		User u = [SELECT Id FROM User WHERE Email = 'test@aptest.com' LIMIT 1];

		System.runAs(u) {
			ActionPlansSectionHeaderController shc = new ActionPlansSectionHeaderController();
			shc.objectName = 'Contract';
			shc.getObjectIconInfo();
			Assert.isFalse(shc.getIsCustom(), 'Contract is a standard object');
		}
	}

	@IsTest
	private static void nullObject() {
		User u = [SELECT Id FROM User WHERE Email = 'test@aptest.com' LIMIT 1];

		System.runAs(u) {
			ActionPlansSectionHeaderController shc = new ActionPlansSectionHeaderController();
			shc.objectName = null;
			shc.getIsCustom();
			shc.getObjectIconInfo();
			String nullIconTag = shc.getObjectIconInfo().get('iconTag');
			Assert.areEqual('record', nullIconTag, 'Should have reached null section of header controller');
		}

	}

	/**
	 * `queryRecords` returns the single record addressed by Id, exposing the
	 * requested display field. Covers the lookup-component RemoteAction path.
	 */
	@IsTest
	private static void queryRecordsReturnsRecordById() {
		ActionPlansTestUtilities testUtil = new ActionPlansTestUtilities();
		Account acc = testUtil.createNewAccount();

		Test.startTest();
		List<SObject> records = ActionPlansSectionHeaderController.queryRecords(acc.Id, 'Name');
		Test.stopTest();

		Assert.areEqual(1, records.size(), 'Should return exactly the record addressed by Id');
		Assert.areEqual(acc.Id, records[0].Id, 'Should return the account we queried');
		Assert.areEqual(acc.Name, (String) records[0].get('Name'), 'Should expose the requested display field');
	}

	/**
	 * A non-Id string passed to `queryRecords` is rejected with a clear
	 * IllegalArgumentException rather than an opaque cast failure.
	 */
	@IsTest
	private static void queryRecordsRejectsInvalidId() {
		Boolean threw = false;

		Test.startTest();
		try {
			ActionPlansSectionHeaderController.queryRecords('not-an-id', 'Name');
		} catch (IllegalArgumentException e) {
			threw = true;
			Assert.isTrue(e.getMessage().contains('Invalid record Id'), 'Message should name the bad Id');
		}
		Test.stopTest();

		Assert.isTrue(threw, 'An invalid Id must raise IllegalArgumentException');
	}

	/**
	 * `searchRecords` finds records by a LIKE search on the display field,
	 * both without and with a (valid) additional WHERE clause.
	 */
	@IsTest
	private static void searchRecordsReturnsMatches() {
		ActionPlansTestUtilities testUtil = new ActionPlansTestUtilities();
		Account acc = testUtil.createNewAccount();

		Test.startTest();
		List<SObject> noClause = ActionPlansSectionHeaderController.searchRecords('Account', 'Name', acc.Name, null);
		List<SObject> withClause = ActionPlansSectionHeaderController.searchRecords('Account', 'Name', acc.Name, 'AND Id != null');
		Test.stopTest();

		Assert.isFalse(noClause.isEmpty(), 'Should find the account by a LIKE name search');
		Assert.areEqual(acc.Id, noClause[0].Id, 'Should return the matching account');
		Assert.isFalse(withClause.isEmpty(), 'A valid AND additional clause should still match');
	}

	/**
	 * An additional WHERE clause that does not begin with AND/OR is rejected,
	 * guarding the SOQL-injection surface on the lookup RemoteAction.
	 */
	@IsTest
	private static void searchRecordsRejectsUnsafeAdditionalWhere() {
		Boolean threw = false;

		Test.startTest();
		try {
			ActionPlansSectionHeaderController.searchRecords('Account', 'Name', 'x', 'LIMIT 1');
		} catch (IllegalArgumentException e) {
			threw = true;
			Assert.isTrue(e.getMessage().contains('must start with AND or OR'), 'Message should explain the clause rule');
		}
		Test.stopTest();

		Assert.isTrue(threw, 'A clause not starting with AND/OR must be rejected');
	}
}