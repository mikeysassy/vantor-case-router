public with sharing class CaseTypeRouterSetType {
    @InvocableMethod(
        label='Case Type Router: Set Case Account'
        description='Links a Case to an Account so Account Region (and Tier) resolve via formula'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            try {
                if (String.isBlank(req.caseId)) {
                    res = fail('caseId is required');
                    results.add(res);
                    continue;
                }
                if (String.isBlank(req.accountId)) {
                    res = fail('accountId is required');
                    results.add(res);
                    continue;
                }

                Id accountId;
                try {
                    accountId = (Id) req.accountId;
                } catch (Exception e) {
                    res = fail('Invalid accountId: ' + req.accountId);
                    results.add(res);
                    continue;
                }
                if (accountId.getSobjectType() != Account.SObjectType) {
                    res = fail('accountId is not an Account Id: ' + req.accountId);
                    results.add(res);
                    continue;
                }

                List<Account> accounts = [
                    SELECT Id, Region__c
                    FROM Account
                    WHERE Id = :accountId
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (accounts.isEmpty()) {
                    res = fail('Account not found: ' + req.accountId);
                    results.add(res);
                    continue;
                }

                List<Case> cases = [
                    SELECT Id, AccountId
                    FROM Case
                    WHERE Id = :req.caseId
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (cases.isEmpty()) {
                    res = fail('Case not found: ' + req.caseId);
                    results.add(res);
                    continue;
                }

                Case caseRecord = cases[0];
                caseRecord.AccountId = accountId;
                update caseRecord;

                res.isSuccess = true;
                res.errorMessage = '';
                res.message = 'Linked Case to Account ' + accountId
                    + ' (Region=' + (accounts[0].Region__c == null ? '(none)' : accounts[0].Region__c) + ')';
            } catch (Exception e) {
                res = fail(e.getMessage());
            }
            results.add(res);
        }
        return results;
    }

    private static Result fail(String message) {
        Result res = new Result();
        res.isSuccess = false;
        res.errorMessage = message;
        res.message = '';
        return res;
    }

    public class Request {
        @InvocableVariable(
            label='Case Id'
            description='Case Id to update'
            required=true
        )
        public String caseId;

        @InvocableVariable(
            label='Account Id'
            description='Account to link to the Case (drives Account Region)'
            required=true
        )
        public String accountId;
    }

    public class Result {
        @InvocableVariable(
            label='Success'
            description='Whether the update succeeded'
        )
        public Boolean isSuccess;

        @InvocableVariable(
            label='Error Message'
            description='Error details'
        )
        public String errorMessage;

        @InvocableVariable(
            label='Message'
            description='Outcome message'
        )
        public String message;
    }
}
