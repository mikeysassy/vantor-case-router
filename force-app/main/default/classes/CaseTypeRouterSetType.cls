public with sharing class CaseTypeRouterSetType {
    private static final Set<String> ALLOWED_CASE_TYPES = new Set<String>{
        'AMEAR',
        'APAC',
        'International Defense',
        'Americas',
        'SAP'
    };

    @InvocableMethod(
        label='Case Type Router: Set Case Type'
        description='Sets Case.msCase_Type__c to a validated picklist value'
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
                if (String.isBlank(req.caseTypeValue)) {
                    res = fail('caseTypeValue is required');
                    results.add(res);
                    continue;
                }
                if (!ALLOWED_CASE_TYPES.contains(req.caseTypeValue)) {
                    res = fail('Unsupported msCase_Type__c value: ' + req.caseTypeValue);
                    results.add(res);
                    continue;
                }

                List<Case> rows = [
                    SELECT Id, msCase_Type__c
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

                Case c = rows[0];
                c.msCase_Type__c = req.caseTypeValue;
                update c;

                res.isSuccess = true;
                res.errorMessage = '';
                res.message = 'Updated msCase_Type__c to ' + req.caseTypeValue;
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
            label='Case Type Value'
            description='Value for Case.msCase_Type__c'
            required=true
        )
        public String caseTypeValue;
    }

    public class Result {
        @InvocableVariable(
            label='Success'
            description='Whether update succeeded'
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
