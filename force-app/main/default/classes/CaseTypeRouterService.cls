public with sharing class CaseTypeRouterService {
    @TestVisible
    private static final Set<String> ALLOWED_REGIONS = new Set<String>{ 'AMERICAS', 'APAC', 'EMEAR' };

    @TestVisible
    private static Set<Id> candidateCaseIds = new Set<Id>();

    public static void routeAfterSave(List<Case> newCases, Map<Id, Case> oldMap) {
        if (newCases == null || newCases.isEmpty()) {
            return;
        }

        candidateCaseIds.clear();
        for (Case caseRecord : newCases) {
            if (caseRecord == null || caseRecord.Id == null) {
                continue;
            }
            if (shouldRoute(caseRecord, oldMap)) {
                candidateCaseIds.add(caseRecord.Id);
            }
        }

        if (!candidateCaseIds.isEmpty()) {
            System.enqueueJob(new CaseTypeRouterAiQueueable(new List<Id>(candidateCaseIds)));
        }
    }

    // The authoritative "skip cases whose region is already defined" decision lives in
    // CaseTypeRouterAiQueueable, because the cross-object formula Account_Region__c is not
    // reliably recalculated in trigger context. Here we only gate which DML changes are worth
    // re-evaluating to avoid enqueuing on every unrelated Case update.
    @TestVisible
    private static Boolean shouldRoute(Case caseRecord, Map<Id, Case> oldMap) {
        if (Trigger.isInsert || oldMap == null || !oldMap.containsKey(caseRecord.Id)) {
            return true;
        }

        Case oldRecord = oldMap.get(caseRecord.Id);
        return caseRecord.AccountId != oldRecord.AccountId
            || caseRecord.SuppliedEmail != oldRecord.SuppliedEmail
            || caseRecord.Subject != oldRecord.Subject;
    }

    // Maps an AI-suggested region label onto the writable Account.Region__c picklist value,
    // tolerating common spellings/casing. Returns null for anything outside the allowed set.
    public static String normalizeRegion(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String normalized = value.trim().toUpperCase();
        if (normalized == 'AMERICAS' || normalized == 'AMERICA' || normalized == 'AMER') {
            return 'AMERICAS';
        }
        if (normalized == 'APAC') {
            return 'APAC';
        }
        if (normalized == 'EMEAR' || normalized == 'EMEA' || normalized == 'AMEAR') {
            return 'EMEAR';
        }
        return ALLOWED_REGIONS.contains(normalized) ? normalized : null;
    }
}
