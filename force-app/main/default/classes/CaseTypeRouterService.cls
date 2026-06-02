public with sharing class CaseTypeRouterService {
    private static final String TYPE_AMEAR = 'AMEAR';
    private static final String TYPE_APAC = 'APAC';
    private static final String TYPE_INTERNATIONAL_DEFENSE = 'International Defense';
    private static final String TYPE_AMERICAS = 'Americas';
    private static final String TYPE_SAP = 'SAP';

    @TestVisible
    private static Set<Id> candidateCaseIds = new Set<Id>();

    public static void routeBeforeSave(List<Case> newCases, Map<Id, Case> oldMap) {
        if (newCases == null || newCases.isEmpty()) {
            return;
        }

        candidateCaseIds.clear();
        for (Case caseRecord : newCases) {
            if (caseRecord == null || !shouldRoute(caseRecord, oldMap)) {
                continue;
            }

            String caseType = mapCaseToCaseType(caseRecord.Subject, caseRecord.SuppliedEmail);
            if (!String.isBlank(caseType)) {
                caseRecord.msCase_Type__c = caseType;
            } else if (caseRecord.Id != null) {
                candidateCaseIds.add(caseRecord.Id);
            }
        }
    }

    public static void routeAfterSave(List<Case> newCases, Map<Id, Case> oldMap) {
        if (newCases == null || newCases.isEmpty()) {
            return;
        }

        Set<Id> pendingIds = new Set<Id>();
        List<CaseComment> deterministicComments = new List<CaseComment>();
        for (Case caseRecord : newCases) {
            if (caseRecord == null || !shouldRoute(caseRecord, oldMap) || caseRecord.Id == null) {
                continue;
            }

            String caseType = mapCaseToCaseType(caseRecord.Subject, caseRecord.SuppliedEmail);
            if (String.isBlank(caseType)) {
                pendingIds.add(caseRecord.Id);
            } else {
                deterministicComments.add(new CaseComment(
                    ParentId = caseRecord.Id,
                    IsPublished = true,
                    CommentBody = '[CaseTypeRouter Classification] method=deterministic; predictedType=' + caseType +
                        '; confidence=1.00; reason=' + getDeterministicReason(caseRecord.Subject, caseRecord.SuppliedEmail)
                ));
            }
        }

        if (!deterministicComments.isEmpty()) {
            insert deterministicComments;
        }
        if (!pendingIds.isEmpty()) {
            System.enqueueJob(new CaseTypeRouterAiQueueable(new List<Id>(pendingIds)));
        }
    }

    @TestVisible
    private static Boolean shouldRoute(Case caseRecord, Map<Id, Case> oldMap) {
        if (Trigger.isInsert || oldMap == null || !oldMap.containsKey(caseRecord.Id)) {
            return true;
        }

        Case oldRecord = oldMap.get(caseRecord.Id);
        return caseRecord.Subject != oldRecord.Subject || caseRecord.SuppliedEmail != oldRecord.SuppliedEmail;
    }

    @TestVisible
    private static String mapCaseToCaseType(String subject, String suppliedEmail) {
        String normalized = String.isBlank(subject) ? '' : subject.toLowerCase();
        if (normalized.contains('sap')) {
            return TYPE_SAP;
        }
        if (normalized.contains('international defense') || normalized.contains('defense')) {
            return TYPE_INTERNATIONAL_DEFENSE;
        }
        if (normalized.contains('amear')) {
            return TYPE_AMEAR;
        }
        if (normalized.contains('apac')) {
            return TYPE_APAC;
        }
        if (normalized.contains('americas')) {
            return TYPE_AMERICAS;
        }

        return null;
    }

    @TestVisible
    private static String getDeterministicReason(String subject, String suppliedEmail) {
        String normalized = String.isBlank(subject) ? '' : subject.toLowerCase();
        if (normalized.contains('sap')) {
            return 'Subject contains SAP keyword.';
        }
        if (normalized.contains('international defense') || normalized.contains('defense')) {
            return 'Subject contains defense indicator.';
        }
        if (normalized.contains('amear')) {
            return 'Subject contains AMEAR keyword.';
        }
        if (normalized.contains('apac')) {
            return 'Subject contains APAC keyword.';
        }
        if (normalized.contains('americas')) {
            return 'Subject contains Americas keyword.';
        }
        return 'No deterministic keyword or weighted email-domain signal matched.';
    }


    public static String normalizeCandidate(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String normalized = value.trim().toLowerCase();
        if (normalized == TYPE_SAP.toLowerCase()) {
            return TYPE_SAP;
        }
        if (normalized == TYPE_APAC.toLowerCase()) {
            return TYPE_APAC;
        }
        if (normalized == TYPE_AMEAR.toLowerCase()) {
            return TYPE_AMEAR;
        }
        if (normalized == TYPE_AMERICAS.toLowerCase()) {
            return TYPE_AMERICAS;
        }
        if (normalized == TYPE_INTERNATIONAL_DEFENSE.toLowerCase()) {
            return TYPE_INTERNATIONAL_DEFENSE;
        }
        return null;
    }
}
