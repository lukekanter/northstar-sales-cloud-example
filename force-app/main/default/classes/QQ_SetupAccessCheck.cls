/**
 * QQ_SetupAccessCheck
 *
 * Returns whether a user holds the "Customize Application" system permission,
 * i.e. is capable of running the QQ first-run config setup. The QQ_New_Quote2
 * screen flow uses this on its very first element to decide, when the
 * QQ_Config__c hierarchy custom setting has not yet been created, whether the
 * running user can self-provision it (admin) or must be routed to the
 * "ask your administrator" screen.
 *
 * Why Apex: the flow previously made this decision with a Get Records on
 * PermissionSetAssignment filtered by `PermissionSet.PermissionsCustomizeApplication`.
 * Flow "Get Records" filters do NOT support cross-object (spanning) fields, so
 * at runtime that filter could not be parsed and the flow threw an unhandled
 * fault on EVERY launch (the field came through as `null__NotFound`). Apex SOQL
 * does support the spanning filter, so this invocable performs the check
 * server-side and hands the flow a simple Boolean.
 */
public with sharing class QQ_SetupAccessCheck {
    public class Request {
        @InvocableVariable(
            label='User Id (optional; defaults to the running user)'
        )
        public Id userId;
    }

    public class Result {
        @InvocableVariable(label='Has Setup Access')
        public Boolean hasSetupAccess;
    }

    @InvocableMethod(
        label='QQ Check Setup-Capable Access'
        description='True when the user can Customize Application. Used by the QQ_New_Quote2 first-run gate.'
        category='Quicker Quotes'
    )
    public static List<Result> check(List<Request> requests) {
        List<Request> reqs = (requests == null || requests.isEmpty())
            ? new List<Request>{ new Request() }
            : requests;

        Set<Id> userIds = new Set<Id>();
        for (Request req : reqs) {
            userIds.add(resolveUserId(req));
        }

        Set<Id> setupCapable = new Set<Id>();
        for (PermissionSetAssignment psa : [
            SELECT AssigneeId
            FROM PermissionSetAssignment
            WHERE
                AssigneeId IN :userIds
                AND PermissionSet.PermissionsCustomizeApplication = true
        ]) {
            setupCapable.add(psa.AssigneeId);
        }

        List<Result> results = new List<Result>();
        for (Request req : reqs) {
            Result r = new Result();
            r.hasSetupAccess = setupCapable.contains(resolveUserId(req));
            results.add(r);
        }
        return results;
    }

    private static Id resolveUserId(Request req) {
        return (req != null && req.userId != null)
            ? req.userId
            : UserInfo.getUserId();
    }
}
