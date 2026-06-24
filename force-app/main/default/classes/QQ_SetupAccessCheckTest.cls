/**
 * QQ_SetupAccessCheckTest — coverage for QQ_SetupAccessCheck.
 */
@IsTest
private class QQ_SetupAccessCheckTest {
    @IsTest
    static void runningUserCheckReturnsPopulatedFlag() {
        Test.startTest();
        List<QQ_SetupAccessCheck.Result> res = QQ_SetupAccessCheck.check(
            new List<QQ_SetupAccessCheck.Request>{
                new QQ_SetupAccessCheck.Request()
            }
        );
        Test.stopTest();
        System.assertEquals(1, res.size(), 'one result expected for one request');
        System.assertNotEquals(
            null,
            res[0].hasSetupAccess,
            'flag must be populated, never null'
        );
    }

    @IsTest
    static void nullAndEmptyInputsDefaultToRunningUser() {
        Test.startTest();
        List<QQ_SetupAccessCheck.Result> nullRes = QQ_SetupAccessCheck.check(null);
        List<QQ_SetupAccessCheck.Result> emptyRes = QQ_SetupAccessCheck.check(
            new List<QQ_SetupAccessCheck.Request>()
        );
        Test.stopTest();
        System.assertEquals(
            1,
            nullRes.size(),
            'null input defaults to a single running-user check'
        );
        System.assertEquals(
            1,
            emptyRes.size(),
            'empty input defaults to a single running-user check'
        );
    }

    @IsTest
    static void minimumAccessUserLacksSetupAccess() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE Name = 'Minimum Access - Salesforce'
            LIMIT 1
        ];
        User u = new User(
            Alias = 'qqsa',
            Email = 'qq.setupaccess@example.com.invalid',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SetupAccessTest',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'qq.setupaccess.' +
                System.now().getTime() +
                '@example.com.invalid'
        );
        insert u;

        QQ_SetupAccessCheck.Request req = new QQ_SetupAccessCheck.Request();
        req.userId = u.Id;

        Test.startTest();
        List<QQ_SetupAccessCheck.Result> res = QQ_SetupAccessCheck.check(
            new List<QQ_SetupAccessCheck.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, res.size(), 'one result expected');
        System.assertEquals(
            false,
            res[0].hasSetupAccess,
            'a Minimum Access user cannot Customize Application'
        );
    }
}
