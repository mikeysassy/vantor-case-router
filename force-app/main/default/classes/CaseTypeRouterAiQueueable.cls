public with sharing class CaseTypeRouterAiQueueable implements Queueable {
    private static final Decimal LOW_CONFIDENCE_THRESHOLD = 0.75;
    private final List<Id> caseIds;

    public CaseTypeRouterAiQueueable(List<Id> caseIds) {
        this.caseIds = caseIds == null ? new List<Id>() : new List<Id>(caseIds);
    }

    public void execute(QueueableContext context) {
        if (caseIds.isEmpty()) {
            return;
        }

        List<Case> casesToClassify = [
            SELECT Id, Subject, Description, SuppliedEmail, Origin, msCase_Type__c,
                AccountId, ContactId,
                Account.Name, Account.Industry, Account.BillingCountry,
                Contact.Title, Contact.Department, Contact.MailingCountry
            FROM Case
            WHERE Id IN :caseIds
            WITH USER_MODE
        ];
        if (casesToClassify.isEmpty()) {
            return;
        }

        Map<Id, EmailMessage> latestEmailByCaseId = new Map<Id, EmailMessage>();
        for (EmailMessage email : [
            SELECT ParentId, FromAddress, TextBody, CreatedDate
            FROM EmailMessage
            WHERE ParentId IN :caseIds
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ]) {
            if (!latestEmailByCaseId.containsKey(email.ParentId)) {
                latestEmailByCaseId.put(email.ParentId, email);
            }
        }

        Set<Id> accountIds = new Set<Id>();
        Set<Id> contactIds = new Set<Id>();
        for (Case c : casesToClassify) {
            if (c.AccountId != null) {
                accountIds.add(c.AccountId);
            }
            if (c.ContactId != null) {
                contactIds.add(c.ContactId);
            }
        }

        List<Case> recentCases = new List<Case>();
        if (!accountIds.isEmpty() || !contactIds.isEmpty()) {
            recentCases = [
                SELECT Id, AccountId, ContactId, msCase_Type__c, CreatedDate
                FROM Case
                WHERE (AccountId IN :accountIds OR ContactId IN :contactIds)
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 200
            ];
        }

        List<Case> updates = new List<Case>();
        List<CaseComment> classificationComments = new List<CaseComment>();
        for (Case caseRecord : casesToClassify) {
            String historySummary = buildHistorySummary(caseRecord, recentCases);
            CaseTypeAiClassifier.ClassificationResult aiResult =
                CaseTypeAiClassifier.classify(caseRecord, latestEmailByCaseId.get(caseRecord.Id), historySummary);
            String normalizedType = CaseTypeRouterService.normalizeCandidate(aiResult.predictedType);
            if (String.isBlank(normalizedType)) {
                classificationComments.add(buildClassificationComment(
                    caseRecord.Id,
                    null,
                    aiResult,
                    'invalid or empty predicted type'
                ));
                continue;
            }

            Case updated = new Case(Id = caseRecord.Id, msCase_Type__c = normalizedType);
            updates.add(updated);

            String reason = 'ai classification';
            if (aiResult.confidence == null || aiResult.confidence < LOW_CONFIDENCE_THRESHOLD) {
                reason = 'low confidence';
            }
            classificationComments.add(buildClassificationComment(caseRecord.Id, normalizedType, aiResult, reason));
        }

        if (!updates.isEmpty()) {
            update updates;
        }
        if (!classificationComments.isEmpty()) {
            insert classificationComments;
        }
    }

    private static String buildHistorySummary(Case caseRecord, List<Case> recentCases) {
        if (recentCases == null || recentCases.isEmpty()) {
            return 'No recent related cases found.';
        }

        Map<String, Integer> typeCounts = new Map<String, Integer>();
        Integer matched = 0;
        for (Case recent : recentCases) {
            if (recent.Id == caseRecord.Id) {
                continue;
            }
            Boolean related = (caseRecord.AccountId != null && recent.AccountId == caseRecord.AccountId) ||
                (caseRecord.ContactId != null && recent.ContactId == caseRecord.ContactId);
            if (!related) {
                continue;
            }
            matched++;
            String key = String.isBlank(recent.msCase_Type__c) ? 'Unclassified' : recent.msCase_Type__c;
            Integer count = typeCounts.containsKey(key) ? typeCounts.get(key) : 0;
            typeCounts.put(key, count + 1);
            if (matched >= 25) {
                break;
            }
        }
        if (matched == 0) {
            return 'No recent related cases found.';
        }

        List<String> summaryParts = new List<String>();
        for (String typeName : typeCounts.keySet()) {
            summaryParts.add(typeName + '=' + String.valueOf(typeCounts.get(typeName)));
        }
        return 'Related recent case type counts: ' + String.join(summaryParts, ', ');
    }

    private static CaseComment buildClassificationComment(
        Id caseId,
        String normalizedType,
        CaseTypeAiClassifier.ClassificationResult aiResult,
        String reason
    ) {
        String confidence = aiResult == null || aiResult.confidence == null ? 'null' : String.valueOf(aiResult.confidence);
        String predicted = aiResult == null ? 'null' : aiResult.predictedType;
        String detail = aiResult == null ? '' : aiResult.reason;

        return new CaseComment(
            ParentId = caseId,
            IsPublished = true,
            CommentBody = '[CaseTypeRouter Classification] method=ai; reason=' + reason +
                '; appliedType=' + String.valueOf(normalizedType) +
                '; predictedType=' + predicted +
                '; confidence=' + confidence +
                '; detail=' + detail
        );
    }
}
