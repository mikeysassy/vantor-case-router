public with sharing class CaseTypeAiClassifier {
    public class ClassificationResult {
        public String predictedType;
        public Decimal confidence;
        public String reason;
    }

    public interface Provider {
        ClassificationResult classify(Case caseRecord, EmailMessage latestEmail, String historySummary);
    }

    @TestVisible
    static Provider provider;

    public static ClassificationResult classify(Case caseRecord, EmailMessage latestEmail, String historySummary) {
        Provider active = (provider == null) ? new EinsteinPromptTemplateProvider() : provider;
        return active.classify(caseRecord, latestEmail, historySummary);
    }

    public class EinsteinPromptTemplateProvider implements Provider {
        private final String templateApiName = 'Case_Type_Classifier';

        public ClassificationResult classify(Case caseRecord, EmailMessage latestEmail, String historySummary) {
            ClassificationResult result = new ClassificationResult();
            try {
                String context = buildCaseContext(caseRecord, latestEmail, historySummary);

                ConnectApi.WrappedValue wrappedInput = new ConnectApi.WrappedValue();
                wrappedInput.value = context;

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
                    String raw = generations.generations[0].text;
                    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(raw);
                    result.predictedType = (String) parsed.get('predictedType');
                    Object confidenceObj = parsed.get('confidence');
                    if (confidenceObj != null) {
                        result.confidence = Decimal.valueOf(String.valueOf(confidenceObj));
                    }
                    result.reason = (String) parsed.get('reason');
                }
            } catch (Exception e) {
                result.predictedType = null;
                result.confidence = null;
                result.reason = 'AI classification failed: ' + e.getMessage();
            }
            return result;
        }

        private String buildCaseContext(Case caseRecord, EmailMessage latestEmail, String historySummary) {
            String suppliedDomain = extractDomain(caseRecord.SuppliedEmail);
            String fromDomain = extractDomain(latestEmail == null ? null : latestEmail.FromAddress);
            List<String> lines = new List<String>{
                'Case Id: ' + String.valueOf(caseRecord.Id),
                'Subject: ' + safeText(caseRecord.Subject),
                'Description: ' + safeText(caseRecord.Description),
                'Origin: ' + safeText(caseRecord.Origin),
                'Supplied Email: ' + safeText(caseRecord.SuppliedEmail),
                'Supplied Email Domain: ' + safeText(suppliedDomain),
                'From Address: ' + safeText(latestEmail == null ? null : latestEmail.FromAddress),
                'From Address Domain: ' + safeText(fromDomain),
                'Latest Email Body: ' + safeText(latestEmail == null ? null : latestEmail.TextBody),
                'Has .gov Domain Signal: ' + String.valueOf(isGovOrMilDomain(suppliedDomain) || isGovOrMilDomain(fromDomain)),
                'Recent Similar Case Type Summary: ' + safeText(historySummary)
            };
            return String.join(lines, '\n');
        }

        private String safeText(String value) {
            return String.isBlank(value) ? '(none)' : value;
        }

        private String extractDomain(String email) {
            if (String.isBlank(email) || !email.contains('@')) {
                return null;
            }
            return email.substringAfter('@').toLowerCase();
        }

        private Boolean isGovOrMilDomain(String domain) {
            return !String.isBlank(domain) && (domain.endsWith('.gov') || domain.endsWith('.mil'));
        }
    }
}
