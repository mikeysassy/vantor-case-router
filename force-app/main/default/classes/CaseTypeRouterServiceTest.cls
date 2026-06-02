@IsTest
private class CaseTypeRouterServiceTest {
    private class MockAiProvider implements CaseTypeAiClassifier.Provider {
        private CaseTypeAiClassifier.ClassificationResult resultToReturn;

        MockAiProvider(String suggestedRegion, Id matchedAccountId, Decimal confidence, String reason) {
            resultToReturn = new CaseTypeAiClassifier.ClassificationResult();
            resultToReturn.suggestedRegion = suggestedRegion;
            resultToReturn.matchedAccountId = matchedAccountId;
            resultToReturn.confidence = confidence;
            resultToReturn.reason = reason;
        }

        public CaseTypeAiClassifier.ClassificationResult classify(Case caseRecord, CaseTypeAiClassifier.ResearchContext context) {
            return resultToReturn;
        }
    }

    private static List<CaseComment> routerComments(Id caseId) {
        return [
            SELECT CommentBody
            FROM CaseComment
            WHERE ParentId = :caseId AND CommentBody LIKE '%CaseTypeRouter Region Research%'
            ORDER BY CreatedDate DESC
        ];
    }

    @IsTest
    static void normalizeRegionMapsCommonSpellings() {
        System.assertEquals('AMERICAS', CaseTypeRouterService.normalizeRegion('americas'));
        System.assertEquals('APAC', CaseTypeRouterService.normalizeRegion(' apac '));
        System.assertEquals('EMEAR', CaseTypeRouterService.normalizeRegion('EMEA'));
        System.assertEquals('EMEAR', CaseTypeRouterService.normalizeRegion('AMEAR'));
        System.assertEquals(null, CaseTypeRouterService.normalizeRegion('Galactic'));
        System.assertEquals(null, CaseTypeRouterService.normalizeRegion(null));
    }

    @IsTest
    static void predefinedRegionCaseIsSkipped() {
        Account customer = new Account(Name = 'Defined Region Co', Website = 'https://defined.com', Region__c = 'AMERICAS');
        insert customer;

        // Mock would link a different account if it ever ran; it must NOT run for predefined cases.
        Account other = new Account(Name = 'Other Co', Website = 'https://other.com', Region__c = 'APAC');
        insert other;
        CaseTypeAiClassifier.provider = new MockAiProvider('APAC', other.Id, 0.99, 'should not be applied');

        Case c = new Case(Subject = 'Already regioned', Origin = 'Email', AccountId = customer.Id);

        Test.startTest();
        insert c;
        Test.stopTest();

        c = [SELECT AccountId FROM Case WHERE Id = :c.Id];
        System.assertEquals(customer.Id, c.AccountId, 'Predefined-region case must be left untouched.');
        System.assertEquals(0, routerComments(c.Id).size(), 'Predefined-region case should not be researched.');
    }

    @IsTest
    static void confidentMatchLinksCustomerAccount() {
        Account customer = new Account(Name = 'Acme Imaging', Website = 'https://www.acme.com', Region__c = 'APAC');
        insert customer;

        CaseTypeAiClassifier.provider = new MockAiProvider('APAC', customer.Id, 0.93, 'Domain matches Acme.');

        Case c = new Case(Subject = 'Need imagery help', Origin = 'Email', SuppliedEmail = 'jane@acme.com');

        Test.startTest();
        insert c;
        Test.stopTest();

        c = [SELECT AccountId FROM Case WHERE Id = :c.Id];
        System.assertEquals(customer.Id, c.AccountId, 'Confident match should link the customer Account.');

        List<CaseComment> comments = routerComments(c.Id);
        System.assertEquals(1, comments.size());
        System.assert(comments[0].CommentBody.contains('outcome=account-linked'), comments[0].CommentBody);
    }

    @IsTest
    static void internalForwardResolvesExternalCustomerNotVantor() {
        Account customer = new Account(Name = 'Beta GIS', Website = 'https://beta.com', Region__c = 'EMEAR');
        insert customer;

        CaseTypeAiClassifier.provider = new MockAiProvider('EMEAR', customer.Id, 0.91, 'Unwrapped forwarded customer.');

        // Internal employee forwards a customer email into the case address.
        Case c = new Case(Subject = 'FW: customer issue', Origin = 'Email', SuppliedEmail = 'employee@vantor.com');

        Test.startTest();
        insert c;
        insert new EmailMessage(
            ParentId = c.Id,
            Incoming = true,
            FromAddress = 'employee@vantor.com',
            FromName = 'Internal Employee',
            Subject = 'FW: customer issue',
            Status = '0',
            MessageDate = System.now(),
            TextBody = 'Team, please help this customer.\n\n' +
                'From: Bob Customer <bob@beta.com>\n' +
                'Sent: Monday\n' +
                'To: support@vantor.com\n' +
                'Subject: Imagery problem\n\n' +
                'Our imagery feed is broken.'
        );
        Test.stopTest();

        c = [SELECT AccountId FROM Case WHERE Id = :c.Id];
        System.assertEquals(customer.Id, c.AccountId, 'Should link the external customer, not the internal forwarder.');

        List<CaseComment> comments = routerComments(c.Id);
        System.assertEquals(1, comments.size());
        System.assert(comments[0].CommentBody.contains('internalForward=true'), comments[0].CommentBody);
        System.assert(comments[0].CommentBody.contains('bob@beta.com'), comments[0].CommentBody);
    }

    @IsTest
    static void lowConfidencePostsSuggestionWithoutLinking() {
        Account customer = new Account(Name = 'Gamma Co', Website = 'https://gamma.com', Region__c = 'APAC');
        insert customer;

        CaseTypeAiClassifier.provider = new MockAiProvider('APAC', customer.Id, 0.40, 'Weak signal.');

        Case c = new Case(Subject = 'Ambiguous request', Origin = 'Email', SuppliedEmail = 'someone@gamma.com');

        Test.startTest();
        insert c;
        Test.stopTest();

        c = [SELECT AccountId FROM Case WHERE Id = :c.Id];
        System.assertEquals(null, c.AccountId, 'Low confidence must not link an Account.');

        List<CaseComment> comments = routerComments(c.Id);
        System.assertEquals(1, comments.size());
        System.assert(comments[0].CommentBody.contains('outcome=needs-review'), comments[0].CommentBody);
    }

    @IsTest
    static void confidentNoMatchedIdFallsBackToBestCandidate() {
        Account best = new Account(Name = 'Uptima Primary', Website = 'https://uptima.com', Region__c = 'AMERICAS');
        Account other = new Account(Name = 'Uptima Secondary', Website = 'https://support.uptima.com', Region__c = 'AMERICAS');
        insert new List<Account>{ best, other };

        // Give "best" more related contacts so fallback ranking prefers it.
        insert new List<Contact>{
            new Contact(LastName = 'One', AccountId = best.Id, Email = 'travisw@uptima.com'),
            new Contact(LastName = 'Two', AccountId = best.Id, Email = 'helper1@uptima.com'),
            new Contact(LastName = 'Three', AccountId = best.Id, Email = 'helper2@uptima.com'),
            new Contact(LastName = 'Alt', AccountId = other.Id, Email = 'alt@uptima.com')
        };

        // Simulate AI confidence but no explicit account id.
        CaseTypeAiClassifier.provider = new MockAiProvider('AMERICAS', null, 0.92, 'Domain known, no selected account.');

        Case c = new Case(Subject = 'Fallback ranking test', Origin = 'Email', SuppliedEmail = 'travisw@uptima.com');

        Test.startTest();
        insert c;
        Test.stopTest();

        c = [SELECT AccountId FROM Case WHERE Id = :c.Id];
        System.assertEquals(best.Id, c.AccountId, 'Fallback ranking should link the strongest candidate account.');

        List<CaseComment> comments = routerComments(c.Id);
        System.assertEquals(1, comments.size());
        System.assert(comments[0].CommentBody.contains('outcome=account-linked-fallback'), comments[0].CommentBody);
    }

    @IsTest
    static void rejectsAccountOutsideCandidateSet() {
        // Internal Vantor account exists, but the customer (delta.com) has no Account.
        Account vantorInternal = new Account(Name = 'Vantor', Website = 'https://vantor.com');
        insert vantorInternal;

        // Model (incorrectly, with high confidence) returns the internal account id.
        CaseTypeAiClassifier.provider = new MockAiProvider('AMERICAS', vantorInternal.Id, 0.97, 'Hallucinated match.');

        Case c = new Case(Subject = 'New customer', Origin = 'Email', SuppliedEmail = 'chris@delta.com');

        Test.startTest();
        insert c;
        Test.stopTest();

        c = [SELECT AccountId FROM Case WHERE Id = :c.Id];
        System.assertEquals(null, c.AccountId, 'Accounts outside the candidate set (e.g. internal Vantor) must never be linked.');

        List<CaseComment> comments = routerComments(c.Id);
        System.assertEquals(1, comments.size());
        System.assert(comments[0].CommentBody.contains('outcome=needs-review'), comments[0].CommentBody);
    }

    @IsTest
    static void getContextReturnsRegionContext() {
        Account customer = new Account(Name = 'Context Co', Website = 'https://ctx.com', Region__c = 'AMERICAS');
        insert customer;
        Case c = new Case(Subject = 'Ctx', Origin = 'Email', AccountId = customer.Id);
        insert c;

        CaseTypeRouterGetContext.Request req = new CaseTypeRouterGetContext.Request();
        req.caseId = c.Id;
        List<CaseTypeRouterGetContext.Result> results =
            CaseTypeRouterGetContext.execute(new List<CaseTypeRouterGetContext.Request>{ req });

        System.assertEquals(1, results.size());
        System.assert(results[0].isSuccess);
        System.assertEquals('AMERICAS', results[0].accountRegion);
        System.assertEquals(true, results[0].isRegionDefined);

        CaseTypeRouterGetContext.Request blankReq = new CaseTypeRouterGetContext.Request();
        blankReq.caseId = '';
        List<CaseTypeRouterGetContext.Result> blankResults =
            CaseTypeRouterGetContext.execute(new List<CaseTypeRouterGetContext.Request>{ blankReq });
        System.assertEquals(false, blankResults[0].isSuccess);
    }

    @IsTest
    static void setCaseAccountLinksAccount() {
        Account customer = new Account(Name = 'SetType Co', Website = 'https://settype.com', Region__c = 'APAC');
        insert customer;
        Case c = new Case(Subject = 'Link me', Origin = 'Email');
        insert c;

        CaseTypeRouterSetType.Request req = new CaseTypeRouterSetType.Request();
        req.caseId = c.Id;
        req.accountId = customer.Id;
        List<CaseTypeRouterSetType.Result> results =
            CaseTypeRouterSetType.execute(new List<CaseTypeRouterSetType.Request>{ req });

        System.assert(results[0].isSuccess, results[0].errorMessage);
        c = [SELECT AccountId FROM Case WHERE Id = :c.Id];
        System.assertEquals(customer.Id, c.AccountId);
    }

    @IsTest
    static void setCaseAccountValidatesInputs() {
        CaseTypeRouterSetType.Request missingAccount = new CaseTypeRouterSetType.Request();
        missingAccount.caseId = 'placeholder';
        List<CaseTypeRouterSetType.Result> missingResults =
            CaseTypeRouterSetType.execute(new List<CaseTypeRouterSetType.Request>{ missingAccount });
        System.assertEquals(false, missingResults[0].isSuccess);

        Case c = new Case(Subject = 'Validate', Origin = 'Email');
        insert c;
        CaseTypeRouterSetType.Request wrongType = new CaseTypeRouterSetType.Request();
        wrongType.caseId = c.Id;
        wrongType.accountId = c.Id;
        List<CaseTypeRouterSetType.Result> wrongResults =
            CaseTypeRouterSetType.execute(new List<CaseTypeRouterSetType.Request>{ wrongType });
        System.assertEquals(false, wrongResults[0].isSuccess);
    }

    @IsTest
    static void setCaseAccountHandlesBadIdsAndMissingRecords() {
        CaseTypeRouterSetType.Request badFormat = new CaseTypeRouterSetType.Request();
        badFormat.caseId = 'placeholder';
        badFormat.accountId = 'not-an-id';
        System.assertEquals(false,
            CaseTypeRouterSetType.execute(new List<CaseTypeRouterSetType.Request>{ badFormat })[0].isSuccess);

        CaseTypeRouterSetType.Request missingAccount = new CaseTypeRouterSetType.Request();
        missingAccount.caseId = 'placeholder';
        missingAccount.accountId = '001000000000000AAA';
        System.assertEquals(false,
            CaseTypeRouterSetType.execute(new List<CaseTypeRouterSetType.Request>{ missingAccount })[0].isSuccess);

        Account a = new Account(Name = 'No Region Co');
        insert a;
        CaseTypeRouterSetType.Request missingCase = new CaseTypeRouterSetType.Request();
        missingCase.caseId = '500000000000000AAA';
        missingCase.accountId = a.Id;
        System.assertEquals(false,
            CaseTypeRouterSetType.execute(new List<CaseTypeRouterSetType.Request>{ missingCase })[0].isSuccess);

        // Success path linking an Account that has no Region (covers the null-region message branch).
        Case c = new Case(Subject = 'No region link', Origin = 'Email');
        insert c;
        CaseTypeRouterSetType.Request ok = new CaseTypeRouterSetType.Request();
        ok.caseId = c.Id;
        ok.accountId = a.Id;
        System.assert(
            CaseTypeRouterSetType.execute(new List<CaseTypeRouterSetType.Request>{ ok })[0].isSuccess);
    }

    @IsTest
    static void einsteinProviderBuildsContextAndParsesOutput() {
        Account a = new Account(Name = 'Prov Co', Website = 'https://prov.com', Region__c = 'APAC');
        insert a;
        Case c = new Case(Subject = 'Prov', Origin = 'Email', SuppliedEmail = 'x@prov.com');
        insert c;

        CaseTypeAiClassifier.EinsteinPromptTemplateProvider provider =
            new CaseTypeAiClassifier.EinsteinPromptTemplateProvider();

        CaseTypeAiClassifier.ResearchContext ctx = new CaseTypeAiClassifier.ResearchContext();
        ctx.suppliedEmail = 'x@prov.com';
        ctx.externalSenderEmail = 'x@prov.com';
        ctx.externalSenderDomain = 'prov.com';
        ctx.emailContent = 'Customer needs help.';
        ctx.candidateAccounts.add(new CaseTypeAiClassifier.CandidateAccount(a.Id, a.Name, a.Website, a.Region__c));

        // Callout is unavailable in tests; classify should build context then fail gracefully.
        CaseTypeAiClassifier.ClassificationResult calloutResult = provider.classify(c, ctx);
        System.assertNotEquals(null, calloutResult);

        // Empty context exercises the "(none)"/"no candidate accounts" branches.
        provider.classify(c, new CaseTypeAiClassifier.ResearchContext());

        CaseTypeAiClassifier.ClassificationResult parsed = provider.parseResult(
            '{"suggestedRegion":"APAC","matchedAccountId":"' + a.Id + '","confidence":0.88,"reason":"ok"}'
        );
        System.assertEquals('APAC', parsed.suggestedRegion);
        System.assertEquals(a.Id, parsed.matchedAccountId);
        System.assertEquals(0.88, parsed.confidence);

        CaseTypeAiClassifier.ClassificationResult parsedBadId = provider.parseResult(
            '{"suggestedRegion":null,"matchedAccountId":"not-an-id","confidence":0.10,"reason":"bad id"}'
        );
        System.assertEquals(null, parsedBadId.matchedAccountId);

        CaseTypeAiClassifier.ClassificationResult parsedNullAccount = provider.parseResult(
            '{"suggestedRegion":"EMEAR","matchedAccountId":null,"confidence":0.50,"reason":"no match"}'
        );
        System.assertEquals(null, parsedNullAccount.matchedAccountId);
        System.assertEquals('EMEAR', parsedNullAccount.suggestedRegion);
    }
}
