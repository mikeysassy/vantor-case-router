public with sharing class CaseTypeRouterGetContext {
    @InvocableMethod(
        label='Case Type Router: Get Context'
        description='Gets Case subject and deterministic routing recommendation'
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
                    SELECT Id, Subject
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

                String subject = rows[0].Subject == null ? '' : rows[0].Subject;
                String normalized = subject.toLowerCase();
                String mappedType = '';
                Boolean sapTitle = false;

                if (normalized.contains('sap')) {
                    sapTitle = true;
                    mappedType = 'SAP';
                } else if (normalized.contains('international defense') || normalized.contains('defense')) {
                    mappedType = 'International Defense';
                } else if (normalized.contains('amear')) {
                    mappedType = 'AMEAR';
                } else if (normalized.contains('apac')) {
                    mappedType = 'APAC';
                } else if (normalized.contains('americas')) {
                    mappedType = 'Americas';
                }

                res.isSuccess = true;
                res.errorMessage = '';
                res.caseSubject = subject;
                res.isSapTitle = sapTitle;
                res.suggestedCaseType = mappedType;
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
        res.isSapTitle = false;
        res.suggestedCaseType = '';
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

        @InvocableVariable(label='Is SAP Title' description='True when title contains SAP')
        public Boolean isSapTitle;

        @InvocableVariable(label='Suggested Case Type' description='Deterministic mapping result')
        public String suggestedCaseType;
    }
}
