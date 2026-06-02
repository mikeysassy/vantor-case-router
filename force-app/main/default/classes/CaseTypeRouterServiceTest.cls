@IsTest
private class CaseTypeRouterServiceTest {
    private class MockAiProvider implements CaseTypeAiClassifier.Provider {
        CaseTypeAiClassifier.ClassificationResult resultToReturn;

        MockAiProvider(String predictedType, Decimal confidence, String reason) {
            resultToReturn = new CaseTypeAiClassifier.ClassificationResult();
            resultToReturn.predictedType = predictedType;
            resultToReturn.confidence = confidence;
            resultToReturn.reason = reason;
        }

        public CaseTypeAiClassifier.ClassificationResult classify(Case caseRecord, EmailMessage latestEmail, String historySummary) {
            return resultToReturn;
        }
    }

    @IsTest
    static void routesExpectedSubjectKeywordsOnInsert() {
        List<Case> casesToInsert = new List<Case>{
            new Case(Subject = 'SAP access request', Origin = 'Email'),
            new Case(Subject = 'APAC imagery support', Origin = 'Email'),
            new Case(Subject = 'AMEAR contract support', Origin = 'Email'),
            new Case(Subject = 'International Defense customer issue', Origin = 'Email'),
            new Case(Subject = 'Americas delivery request', Origin = 'Email'),
            new Case(Subject = 'General support request', Origin = 'Email')
        };

        insert casesToInsert;

        Map<Id, Case> savedCases = new Map<Id, Case>([
            SELECT Subject, msCase_Type__c
            FROM Case
            WHERE Id IN :casesToInsert
        ]);

        System.assertEquals('SAP', savedCases.get(casesToInsert[0].Id).msCase_Type__c);
        System.assertEquals('APAC', savedCases.get(casesToInsert[1].Id).msCase_Type__c);
        System.assertEquals('AMEAR', savedCases.get(casesToInsert[2].Id).msCase_Type__c);
        System.assertEquals('International Defense', savedCases.get(casesToInsert[3].Id).msCase_Type__c);
        System.assertEquals('Americas', savedCases.get(casesToInsert[4].Id).msCase_Type__c);
        System.assertEquals(null, savedCases.get(casesToInsert[5].Id).msCase_Type__c);
    }

    @IsTest
    static void routesWhenSubjectChangesAndPreservesExistingOnNoMatch() {
        Case c = new Case(Subject = 'APAC initial issue', Origin = 'Email');
        insert c;

        c = [
            SELECT Subject, msCase_Type__c
            FROM Case
            WHERE Id = :c.Id
        ];
        System.assertEquals('APAC', c.msCase_Type__c);

        c.Subject = 'No mapped keyword here';
        update c;

        c = [
            SELECT Subject, msCase_Type__c
            FROM Case
            WHERE Id = :c.Id
        ];
        System.assertEquals('APAC', c.msCase_Type__c, 'No-match updates should preserve the existing value.');

        c.Subject = 'Defense escalation';
        update c;

        c = [
            SELECT Subject, msCase_Type__c
            FROM Case
            WHERE Id = :c.Id
        ];
        System.assertEquals('International Defense', c.msCase_Type__c);
    }

    @IsTest
    static void sapRouteHasPriorityOverOtherKeywords() {
        Case c = new Case(Subject = 'APAC SAP integration case', Origin = 'Email');
        insert c;

        c = [
            SELECT msCase_Type__c
            FROM Case
            WHERE Id = :c.Id
        ];
        System.assertEquals('SAP', c.msCase_Type__c);
    }

    @IsTest
    static void appliesAiClassificationForUnmappedSubjectWithHighConfidence() {
        CaseTypeAiClassifier.provider = new MockAiProvider('Americas', 0.93, 'Email domain and context match Americas.');

        Case c = new Case(Subject = 'Help request without keyword', Description = 'Customer asks for regional support', Origin = 'Email');
        Test.startTest();
        insert c;
        Test.stopTest();

        c = [SELECT msCase_Type__c FROM Case WHERE Id = :c.Id];
        System.assertEquals('Americas', c.msCase_Type__c);

        List<CaseComment> comments = [SELECT CommentBody FROM CaseComment WHERE ParentId = :c.Id ORDER BY CreatedDate DESC];
        System.assertEquals(1, comments.size(), 'AI classifications should always create an audit comment.');
        System.assert(comments[0].CommentBody.contains('method=ai'));
    }

    @IsTest
    static void hybridPolicySetsValueAndFlagsWhenLowConfidence() {
        CaseTypeAiClassifier.provider = new MockAiProvider('APAC', 0.42, 'Limited context confidence.');

        Case c = new Case(Subject = 'Need support from unknown region', Description = 'No clear region in title', Origin = 'Email');
        Test.startTest();
        insert c;
        Test.stopTest();

        c = [SELECT msCase_Type__c FROM Case WHERE Id = :c.Id];
        System.assertEquals('APAC', c.msCase_Type__c);

        List<CaseComment> comments = [SELECT CommentBody FROM CaseComment WHERE ParentId = :c.Id ORDER BY CreatedDate DESC];
        System.assertEquals(1, comments.size(), 'Low confidence should add a review comment.');
        System.assert(comments[0].CommentBody.contains('reason=low confidence'));
    }

    @IsTest
    static void invalidAiOutputFlagsReviewWithoutOverwriting() {
        CaseTypeAiClassifier.provider = new MockAiProvider('Unknown Region', 0.88, 'Model returned unsupported label.');

        Case c = new Case(Subject = 'No deterministic keyword', Origin = 'Email');
        Test.startTest();
        insert c;
        Test.stopTest();

        c = [SELECT msCase_Type__c FROM Case WHERE Id = :c.Id];
        System.assertEquals(null, c.msCase_Type__c, 'Unsupported AI output should not be written.');

        List<CaseComment> comments = [SELECT CommentBody FROM CaseComment WHERE ParentId = :c.Id ORDER BY CreatedDate DESC];
        System.assertEquals(1, comments.size());
        System.assert(comments[0].CommentBody.contains('invalid or empty predicted type'));
    }

    @IsTest
    static void deterministicPathAlwaysCreatesComment() {
        Case c = new Case(Subject = 'SAP deterministic comment check', Origin = 'Email');
        insert c;

        List<CaseComment> comments = [SELECT CommentBody FROM CaseComment WHERE ParentId = :c.Id ORDER BY CreatedDate DESC];
        System.assertEquals(1, comments.size());
        System.assert(comments[0].CommentBody.contains('method=deterministic'));
    }


    @IsTest
    static void aiPathIncludesAccountContactAndHistorySignals() {
        CaseTypeAiClassifier.provider = new MockAiProvider('AMEAR', 0.88, 'Matched account/contact and history signals.');

        Account acct = new Account(Name = 'Router Test Account', BillingCountry = 'United States', Industry = 'Defense');
        insert acct;
        Contact con = new Contact(LastName = 'Router', AccountId = acct.Id, Department = 'Operations', MailingCountry = 'United States');
        insert con;

        insert new Case(
            Subject = 'Previous classified case',
            Origin = 'Email',
            AccountId = acct.Id,
            ContactId = con.Id,
            msCase_Type__c = 'APAC'
        );

        Case c = new Case(
            Subject = 'Needs region classification using richer context',
            Description = 'No deterministic keyword present',
            Origin = 'Email',
            AccountId = acct.Id,
            ContactId = con.Id,
            SuppliedEmail = 'analyst@agency.gov'
        );

        Test.startTest();
        insert c;
        Test.stopTest();

        c = [SELECT msCase_Type__c FROM Case WHERE Id = :c.Id];
        System.assertEquals('AMEAR', c.msCase_Type__c);

        List<CaseComment> comments = [SELECT CommentBody FROM CaseComment WHERE ParentId = :c.Id ORDER BY CreatedDate DESC];
        System.assertEquals(1, comments.size());
        System.assert(comments[0].CommentBody.contains('method=ai'));
    }
}
