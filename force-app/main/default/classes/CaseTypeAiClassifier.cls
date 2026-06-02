public with sharing class CaseTypeAiClassifier {
    public class CandidateAccount {
        public Id accountId;
        public String name;
        public String website;
        public String region;

        public CandidateAccount(Id accountId, String name, String website, String region) {
            this.accountId = accountId;
            this.name = name;
            this.website = website;
            this.region = region;
        }
    }

    public class ResearchContext {
        public String suppliedEmail;
        public String externalSenderEmail;
        public String externalSenderName;
        public String externalSenderDomain;
        public Boolean isInternalForward = false;
        public String emailContent;
        public List<CandidateAccount> candidateAccounts = new List<CandidateAccount>();
    }

    public class ClassificationResult {
        public String suggestedRegion;
        public Id matchedAccountId;
        public Decimal confidence;
        public String reason;
    }

    public interface Provider {
        ClassificationResult classify(Case caseRecord, ResearchContext context);
    }

    @TestVisible
    static Provider provider;

    public static ClassificationResult classify(Case caseRecord, ResearchContext context) {
        Provider active = (provider == null) ? new EinsteinPromptTemplateProvider() : provider;
        return active.classify(caseRecord, context);
    }

    public class EinsteinPromptTemplateProvider implements Provider {
        private final String templateApiName = 'Case_Type_Classifier';

        public ClassificationResult classify(Case caseRecord, ResearchContext context) {
            ClassificationResult result = new ClassificationResult();
            try {
                String contextText = buildCaseContext(caseRecord, context);

                ConnectApi.WrappedValue wrappedInput = new ConnectApi.WrappedValue();
                wrappedInput.value = contextText;

                ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                    new ConnectApi.EinsteinPromptTemplateGenerationsInput();
                input.isPreview = false;
                input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
                input.additionalConfig.applicationName = 'PromptBuilderPreview';
                input.additionalConfig.numGenerations = 1;
                input.additionalConfig.temperature = 0;
                input.inputParams = new Map<String, ConnectApi.WrappedValue>{
                    'Input:CaseContext' => wrappedInput
                };

                ConnectApi.EinsteinPromptTemplateGenerationsRepresentation generations =
                    ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(templateApiName, input);

                if (generations != null && generations.generations != null && !generations.generations.isEmpty()) {
                    result = parseResult(generations.generations[0].text);
                }
            } catch (Exception e) {
                result.suggestedRegion = null;
                result.matchedAccountId = null;
                result.confidence = null;
                result.reason = 'AI research failed: ' + e.getMessage();
            }
            return result;
        }

        @TestVisible
        private ClassificationResult parseResult(String raw) {
            ClassificationResult parsedResult = new ClassificationResult();
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(raw);
            parsedResult.suggestedRegion = (String) parsed.get('suggestedRegion');

            Object accObj = parsed.get('matchedAccountId');
            String accString = accObj == null ? null : String.valueOf(accObj);
            if (String.isNotBlank(accString) && accString != 'null') {
                try {
                    parsedResult.matchedAccountId = (Id) accString;
                } catch (Exception ignored) {
                    parsedResult.matchedAccountId = null;
                }
            }

            Object confidenceObj = parsed.get('confidence');
            if (confidenceObj != null) {
                parsedResult.confidence = Decimal.valueOf(String.valueOf(confidenceObj));
            }
            parsedResult.reason = (String) parsed.get('reason');
            return parsedResult;
        }

        private String buildCaseContext(Case caseRecord, ResearchContext context) {
            List<String> lines = new List<String>{
                'Case Id: ' + String.valueOf(caseRecord.Id),
                'Subject: ' + safeText(caseRecord.Subject),
                'Description: ' + safeText(caseRecord.Description),
                'Origin: ' + safeText(caseRecord.Origin),
                'Case Supplied Email: ' + safeText(context.suppliedEmail),
                'Is Internal Forward (vantor.com/maxar.com sender): ' + String.valueOf(context.isInternalForward),
                'Resolved External Customer Email: ' + safeText(context.externalSenderEmail),
                'Resolved External Customer Name: ' + safeText(context.externalSenderName),
                'Resolved External Customer Domain: ' + safeText(context.externalSenderDomain),
                'Email Content (internal forwarders should be ignored as the customer):',
                safeText(context.emailContent),
                'Candidate Accounts (pick matchedAccountId ONLY from these Ids, otherwise null):',
                buildCandidateBlock(context.candidateAccounts)
            };
            return String.join(lines, '\n');
        }

        private String buildCandidateBlock(List<CandidateAccount> candidates) {
            if (candidates == null || candidates.isEmpty()) {
                return '(no candidate accounts found)';
            }
            List<String> parts = new List<String>();
            for (CandidateAccount candidate : candidates) {
                parts.add('- accountId=' + candidate.accountId
                    + '; name=' + safeText(candidate.name)
                    + '; website=' + safeText(candidate.website)
                    + '; region=' + safeText(candidate.region));
            }
            return String.join(parts, '\n');
        }

        private String safeText(String value) {
            return String.isBlank(value) ? '(none)' : value;
        }
    }
}
