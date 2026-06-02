public with sharing class CaseTypeRouterGetContext {
    @InvocableMethod(
        label='Case Type Router: Get Context'
        description='Returns Case subject, supplied email, and current Account Region routing context'
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

                List<Case> rows = [
                    SELECT Id, Subject, SuppliedEmail, AccountId, Account.Region__c, Account_Region__c
                    FROM Case
                    WHERE Id = :req.caseId
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (rows.isEmpty()) {
                    res = fail('Case not found: ' + req.caseId);
                    results.add(res);
                    continue;
                }

                Case caseRecord = rows[0];
                res.isSuccess = true;
                res.errorMessage = '';
                res.caseSubject = caseRecord.Subject == null ? '' : caseRecord.Subject;
                res.suppliedEmail = caseRecord.SuppliedEmail == null ? '' : caseRecord.SuppliedEmail;
                res.accountRegion = caseRecord.Account_Region__c == null ? '' : caseRecord.Account_Region__c;
                res.isRegionDefined = caseRecord.AccountId != null && String.isNotBlank(caseRecord.Account.Region__c);
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
        res.caseSubject = '';
        res.suppliedEmail = '';
        res.accountRegion = '';
        res.isRegionDefined = false;
        return res;
    }

    public class Request {
        @InvocableVariable(
            label='Case Id'
            description='Case Id to inspect'
            required=true
        )
        public String caseId;
    }

    public class Result {
        @InvocableVariable(label='Success' description='Whether context retrieval succeeded')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message' description='Error details')
        public String errorMessage;

        @InvocableVariable(label='Case Subject' description='Case title/subject for routing')
        public String caseSubject;

        @InvocableVariable(label='Supplied Email' description='Email-to-case supplied sender address')
        public String suppliedEmail;

        @InvocableVariable(label='Account Region' description='Current Account Region (formula) on the Case')
        public String accountRegion;

        @InvocableVariable(label='Is Region Defined' description='True when the linked Account already has a Region')
        public Boolean isRegionDefined;
    }
}
