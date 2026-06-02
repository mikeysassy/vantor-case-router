public with sharing class CaseTypeRouterAiQueueable implements Queueable, Database.AllowsCallouts {
    private static final Decimal CONFIDENCE_THRESHOLD = 0.75;
    private static final Integer MAX_CANDIDATES_PER_DOMAIN = 10;
    private static final Integer MAX_EMAIL_CONTENT_CHARS = 6000;

    @TestVisible
    private static final Set<String> INTERNAL_DOMAINS = new Set<String>{ 'vantor.com', 'maxar.com' };

    private final List<Id> caseIds;

    public CaseTypeRouterAiQueueable(List<Id> caseIds) {
        this.caseIds = caseIds == null ? new List<Id>() : new List<Id>(caseIds);
    }

    public void execute(QueueableContext context) {
        if (caseIds.isEmpty()) {
            return;
        }

        List<Case> candidateCases = [
            SELECT Id, Subject, Description, SuppliedEmail, Origin, AccountId, ContactId,
                Account.Name, Account.Region__c, Contact.Email
            FROM Case
            WHERE Id IN :caseIds
            WITH USER_MODE
        ];

        // Skip cases whose region is already defined (predefined => skip).
        List<Case> pending = new List<Case>();
        for (Case caseRecord : candidateCases) {
            Boolean regionDefined = caseRecord.AccountId != null
                && caseRecord.Account != null
                && String.isNotBlank(caseRecord.Account.Region__c);
            if (!regionDefined) {
                pending.add(caseRecord);
            }
        }
        if (pending.isEmpty()) {
            return;
        }

        Set<Id> pendingIds = new Set<Id>();
        for (Case caseRecord : pending) {
            pendingIds.add(caseRecord.Id);
        }

        Map<Id, List<EmailMessage>> emailsByCase = loadEmailsByCase(pendingIds);

        Map<Id, CaseTypeAiClassifier.ResearchContext> contextByCase =
            new Map<Id, CaseTypeAiClassifier.ResearchContext>();
        Set<String> domainsToMatch = new Set<String>();
        for (Case caseRecord : pending) {
            CaseTypeAiClassifier.ResearchContext ctx = buildResearchContext(caseRecord, emailsByCase.get(caseRecord.Id));
            contextByCase.put(caseRecord.Id, ctx);
            if (String.isNotBlank(ctx.externalSenderDomain)) {
                domainsToMatch.add(ctx.externalSenderDomain);
            }
        }

        Map<String, List<CaseTypeAiClassifier.CandidateAccount>> candidatesByDomain =
            findCandidateAccounts(domainsToMatch);
        Set<Id> allCandidateAccountIds = new Set<Id>();
        for (List<CaseTypeAiClassifier.CandidateAccount> bucket : candidatesByDomain.values()) {
            for (CaseTypeAiClassifier.CandidateAccount candidate : bucket) {
                allCandidateAccountIds.add(candidate.accountId);
            }
        }
        Map<Id, Datetime> accountLastModifiedById = loadAccountLastModified(allCandidateAccountIds);
        Map<Id, Integer> contactCountByAccountId = loadContactCounts(allCandidateAccountIds);
        Map<String, Map<Id, Integer>> exactEmailMatchesByEmail = loadExactEmailMatches(
            allCandidateAccountIds,
            contextByCase.values()
        );

        List<Case> updates = new List<Case>();
        List<CaseComment> comments = new List<CaseComment>();

        for (Case caseRecord : pending) {
            CaseTypeAiClassifier.ResearchContext ctx = contextByCase.get(caseRecord.Id);
            if (String.isNotBlank(ctx.externalSenderDomain) && candidatesByDomain.containsKey(ctx.externalSenderDomain)) {
                ctx.candidateAccounts = candidatesByDomain.get(ctx.externalSenderDomain);
            }

            Set<Id> validAccountIds = new Set<Id>();
            for (CaseTypeAiClassifier.CandidateAccount candidate : ctx.candidateAccounts) {
                validAccountIds.add(candidate.accountId);
            }

            CaseTypeAiClassifier.ClassificationResult research = CaseTypeAiClassifier.classify(caseRecord, ctx);

            Boolean confident = research.confidence != null && research.confidence >= CONFIDENCE_THRESHOLD;
            // Only accept an Account the research was actually offered. This prevents linking a
            // hallucinated Id or the internal Vantor/Maxar account on an internal forward.
            Boolean validMatch = research.matchedAccountId != null && validAccountIds.contains(research.matchedAccountId);
            Id fallbackMatchId = selectBestCandidateAccountId(
                ctx,
                ctx.candidateAccounts,
                accountLastModifiedById,
                contactCountByAccountId,
                exactEmailMatchesByEmail
            );

            if (confident && validMatch) {
                updates.add(new Case(Id = caseRecord.Id, AccountId = research.matchedAccountId));
                comments.add(buildComment(
                    caseRecord.Id,
                    ctx,
                    research,
                    'account-linked',
                    'Linked Case.AccountId=' + research.matchedAccountId + '; Account Region resolves via formula.'
                ));
            } else if (confident && fallbackMatchId != null) {
                updates.add(new Case(Id = caseRecord.Id, AccountId = fallbackMatchId));
                comments.add(buildComment(
                    caseRecord.Id,
                    ctx,
                    research,
                    'account-linked-fallback',
                    'Linked best candidate AccountId=' + fallbackMatchId
                        + ' using exact-email/contact-activity/recency ranking.'
                ));
            } else {
                String why = !validMatch ? 'no confident account match in candidate set' : 'confidence below threshold';
                comments.add(buildComment(
                    caseRecord.Id,
                    ctx,
                    research,
                    'needs-review',
                    why + '; suggestedRegion=' + CaseTypeRouterService.normalizeRegion(research.suggestedRegion)
                ));
            }
        }

        if (!updates.isEmpty()) {
            update updates;
        }
        if (!comments.isEmpty()) {
            insert comments;
        }
    }

    private Map<Id, List<EmailMessage>> loadEmailsByCase(Set<Id> pendingIds) {
        Map<Id, List<EmailMessage>> emailsByCase = new Map<Id, List<EmailMessage>>();
        for (EmailMessage email : [
            SELECT ParentId, FromAddress, FromName, ToAddress, CcAddress, Incoming,
                TextBody, HtmlBody, Headers, MessageDate
            FROM EmailMessage
            WHERE ParentId IN :pendingIds
            WITH USER_MODE
            ORDER BY MessageDate ASC
        ]) {
            if (!emailsByCase.containsKey(email.ParentId)) {
                emailsByCase.put(email.ParentId, new List<EmailMessage>());
            }
            emailsByCase.get(email.ParentId).add(email);
        }
        return emailsByCase;
    }

    private CaseTypeAiClassifier.ResearchContext buildResearchContext(Case caseRecord, List<EmailMessage> emails) {
        CaseTypeAiClassifier.ResearchContext ctx = new CaseTypeAiClassifier.ResearchContext();
        ctx.suppliedEmail = caseRecord.SuppliedEmail;

        String combinedText = buildCombinedEmailText(emails);
        ctx.emailContent = truncate(combinedText, MAX_EMAIL_CONTENT_CHARS);

        String primarySender = caseRecord.SuppliedEmail;
        String primaryName = null;
        if (emails != null) {
            for (EmailMessage email : emails) {
                if (email.Incoming == true && String.isNotBlank(email.FromAddress)) {
                    primarySender = email.FromAddress;
                    primaryName = email.FromName;
                    break;
                }
            }
            if (String.isBlank(primarySender)) {
                for (EmailMessage email : emails) {
                    if (String.isNotBlank(email.FromAddress)) {
                        primarySender = email.FromAddress;
                        primaryName = email.FromName;
                        break;
                    }
                }
            }
        }

        String primaryDomain = extractDomain(primarySender);
        Boolean internalPrimary = isInternalDomain(primaryDomain);
        ctx.isInternalForward = internalPrimary;

        if (!internalPrimary && String.isNotBlank(primarySender)) {
            // The apparent sender is already external: that is the customer.
            ctx.externalSenderEmail = primarySender.trim().toLowerCase();
            ctx.externalSenderName = primaryName;
            ctx.externalSenderDomain = primaryDomain;
        } else {
            // Internal forward (or no usable sender): recover the original customer from the body.
            String original = parseForwardedSender(combinedText);
            if (String.isNotBlank(original)) {
                ctx.externalSenderEmail = original;
                ctx.externalSenderDomain = extractDomain(original);
            }
        }
        return ctx;
    }

    private String buildCombinedEmailText(List<EmailMessage> emails) {
        if (emails == null || emails.isEmpty()) {
            return null;
        }
        List<String> parts = new List<String>();
        for (EmailMessage email : emails) {
            String body = String.isNotBlank(email.TextBody) ? email.TextBody : stripHtml(email.HtmlBody);
            parts.add('--- Email (' + (email.Incoming == true ? 'inbound' : 'outbound')
                + ', from ' + email.FromAddress + ') ---\n' + (body == null ? '' : body));
        }
        return String.join(parts, '\n\n');
    }

    // Pull the original customer address out of a forwarded message body. Prefers explicit
    // "From:" lines (as produced by Outlook/Gmail forwards), then falls back to the first
    // external email address found anywhere in the content.
    private String parseForwardedSender(String text) {
        if (String.isBlank(text)) {
            return null;
        }
        Matcher fromMatcher = Pattern.compile('(?im)from\\s*:\\s*([^\\n\\r]+)').matcher(text);
        while (fromMatcher.find()) {
            String email = firstExternalEmail(fromMatcher.group(1));
            if (String.isNotBlank(email)) {
                return email;
            }
        }
        return firstExternalEmail(text);
    }

    private String firstExternalEmail(String text) {
        if (String.isBlank(text)) {
            return null;
        }
        Matcher emailMatcher = Pattern.compile('[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}').matcher(text);
        while (emailMatcher.find()) {
            String email = emailMatcher.group().toLowerCase();
            if (!isInternalDomain(extractDomain(email)) && !isSystemAddress(email)) {
                return email;
            }
        }
        return null;
    }

    private Boolean isSystemAddress(String email) {
        if (String.isBlank(email)) {
            return true;
        }
        return email.startsWith('noreply')
            || email.startsWith('no-reply')
            || email.startsWith('mailer-daemon')
            || email.startsWith('postmaster')
            || email.contains('salesforce.com');
    }

    private String stripHtml(String html) {
        if (String.isBlank(html)) {
            return null;
        }
        return html.replaceAll('<[^>]+>', ' ').replaceAll('&nbsp;', ' ').replaceAll('\\s+', ' ').trim();
    }

    private String extractDomain(String email) {
        if (String.isBlank(email) || !email.contains('@')) {
            return null;
        }
        String domain = email.substringAfterLast('@').trim().toLowerCase();
        domain = domain.replaceAll('[>"\\)\\]\\s,;].*$', '');
        return String.isBlank(domain) ? null : domain;
    }

    private Boolean isInternalDomain(String domain) {
        return String.isNotBlank(domain) && INTERNAL_DOMAINS.contains(domain);
    }

    private Map<String, List<CaseTypeAiClassifier.CandidateAccount>> findCandidateAccounts(Set<String> domains) {
        Map<String, List<CaseTypeAiClassifier.CandidateAccount>> byDomain =
            new Map<String, List<CaseTypeAiClassifier.CandidateAccount>>();
        if (domains == null || domains.isEmpty()) {
            return byDomain;
        }

        Map<String, Map<Id, CaseTypeAiClassifier.CandidateAccount>> seen =
            new Map<String, Map<Id, CaseTypeAiClassifier.CandidateAccount>>();
        for (String domain : domains) {
            seen.put(domain, new Map<Id, CaseTypeAiClassifier.CandidateAccount>());
        }

        // Match on Account.Website.
        List<String> websiteFilters = new List<String>();
        for (String domain : domains) {
            websiteFilters.add('Website LIKE \'%' + String.escapeSingleQuotes(domain) + '%\'');
        }
        String accountQuery = 'SELECT Id, Name, Website, Region__c FROM Account WHERE '
            + String.join(websiteFilters, ' OR ') + ' LIMIT 200';
        for (Account account : Database.query(accountQuery, AccessLevel.USER_MODE)) {
            addCandidateForMatchingDomains(seen, domains, account.Website, account.Id, account.Name, account.Website, account.Region__c);
        }

        // Match on related Contact email domains.
        List<String> contactFilters = new List<String>();
        for (String domain : domains) {
            contactFilters.add('Email LIKE \'%@' + String.escapeSingleQuotes(domain) + '\'');
        }
        String contactQuery = 'SELECT AccountId, Account.Name, Account.Website, Account.Region__c, Email '
            + 'FROM Contact WHERE AccountId != null AND (' + String.join(contactFilters, ' OR ') + ') LIMIT 200';
        for (Contact contact : Database.query(contactQuery, AccessLevel.USER_MODE)) {
            String contactDomain = extractDomain(contact.Email);
            if (contactDomain != null && seen.containsKey(contactDomain)) {
                addCandidate(seen.get(contactDomain), contact.AccountId, contact.Account.Name,
                    contact.Account.Website, contact.Account.Region__c);
            }
        }

        for (String domain : seen.keySet()) {
            byDomain.put(domain, seen.get(domain).values());
        }
        return byDomain;
    }

    private Map<Id, Datetime> loadAccountLastModified(Set<Id> accountIds) {
        Map<Id, Datetime> lastModifiedById = new Map<Id, Datetime>();
        if (accountIds == null || accountIds.isEmpty()) {
            return lastModifiedById;
        }
        for (Account account : [
            SELECT Id, LastModifiedDate
            FROM Account
            WHERE Id IN :accountIds
            WITH USER_MODE
        ]) {
            lastModifiedById.put(account.Id, account.LastModifiedDate);
        }
        return lastModifiedById;
    }

    private Map<Id, Integer> loadContactCounts(Set<Id> accountIds) {
        Map<Id, Integer> countByAccountId = new Map<Id, Integer>();
        if (accountIds == null || accountIds.isEmpty()) {
            return countByAccountId;
        }
        for (AggregateResult row : [
            SELECT AccountId aid, COUNT(Id) contactCount
            FROM Contact
            WHERE AccountId IN :accountIds
            WITH USER_MODE
            GROUP BY AccountId
        ]) {
            countByAccountId.put((Id) row.get('aid'), (Integer) row.get('contactCount'));
        }
        return countByAccountId;
    }

    private Map<String, Map<Id, Integer>> loadExactEmailMatches(
        Set<Id> accountIds,
        List<CaseTypeAiClassifier.ResearchContext> contexts
    ) {
        Map<String, Map<Id, Integer>> matchesByEmail = new Map<String, Map<Id, Integer>>();
        if (accountIds == null || accountIds.isEmpty() || contexts == null || contexts.isEmpty()) {
            return matchesByEmail;
        }
        Set<String> emails = new Set<String>();
        for (CaseTypeAiClassifier.ResearchContext ctx : contexts) {
            if (ctx != null && String.isNotBlank(ctx.externalSenderEmail)) {
                emails.add(ctx.externalSenderEmail.trim().toLowerCase());
            }
        }
        if (emails.isEmpty()) {
            return matchesByEmail;
        }
        for (Contact contact : [
            SELECT AccountId, Email
            FROM Contact
            WHERE AccountId IN :accountIds
                AND Email IN :emails
            WITH USER_MODE
        ]) {
            if (contact.AccountId == null || String.isBlank(contact.Email)) {
                continue;
            }
            String normalizedEmail = contact.Email.trim().toLowerCase();
            if (!matchesByEmail.containsKey(normalizedEmail)) {
                matchesByEmail.put(normalizedEmail, new Map<Id, Integer>());
            }
            Map<Id, Integer> counts = matchesByEmail.get(normalizedEmail);
            Integer current = counts.containsKey(contact.AccountId) ? counts.get(contact.AccountId) : 0;
            counts.put(contact.AccountId, current + 1);
        }
        return matchesByEmail;
    }

    private Id selectBestCandidateAccountId(
        CaseTypeAiClassifier.ResearchContext ctx,
        List<CaseTypeAiClassifier.CandidateAccount> candidates,
        Map<Id, Datetime> accountLastModifiedById,
        Map<Id, Integer> contactCountByAccountId,
        Map<String, Map<Id, Integer>> exactEmailMatchesByEmail
    ) {
        if (ctx == null || candidates == null || candidates.isEmpty()) {
            return null;
        }
        String senderEmail = String.isBlank(ctx.externalSenderEmail) ? null : ctx.externalSenderEmail.trim().toLowerCase();
        Map<Id, Integer> exactCounts = senderEmail == null || !exactEmailMatchesByEmail.containsKey(senderEmail)
            ? new Map<Id, Integer>()
            : exactEmailMatchesByEmail.get(senderEmail);

        Id bestId;
        Integer bestExact = -1;
        Integer bestContactCount = -1;
        Datetime bestLastModified;
        for (CaseTypeAiClassifier.CandidateAccount candidate : candidates) {
            Integer exact = exactCounts.containsKey(candidate.accountId) ? exactCounts.get(candidate.accountId) : 0;
            Integer contactCount = contactCountByAccountId.containsKey(candidate.accountId)
                ? contactCountByAccountId.get(candidate.accountId)
                : 0;
            Datetime lastModified = accountLastModifiedById.containsKey(candidate.accountId)
                ? accountLastModifiedById.get(candidate.accountId)
                : null;
            if (
                bestId == null
                || exact > bestExact
                || (exact == bestExact && contactCount > bestContactCount)
                || (
                    exact == bestExact
                    && contactCount == bestContactCount
                    && lastModified != null
                    && (bestLastModified == null || lastModified.getTime() > bestLastModified.getTime())
                )
            ) {
                bestId = candidate.accountId;
                bestExact = exact;
                bestContactCount = contactCount;
                bestLastModified = lastModified;
            }
        }
        return bestId;
    }

    private void addCandidateForMatchingDomains(
        Map<String, Map<Id, CaseTypeAiClassifier.CandidateAccount>> seen,
        Set<String> domains,
        String website,
        Id accountId,
        String name,
        String websiteValue,
        String region
    ) {
        if (String.isBlank(website)) {
            return;
        }
        String lowerWebsite = website.toLowerCase();
        for (String domain : domains) {
            if (lowerWebsite.contains(domain)) {
                addCandidate(seen.get(domain), accountId, name, websiteValue, region);
            }
        }
    }

    private void addCandidate(
        Map<Id, CaseTypeAiClassifier.CandidateAccount> bucket,
        Id accountId,
        String name,
        String website,
        String region
    ) {
        if (accountId == null || bucket.containsKey(accountId) || bucket.size() >= MAX_CANDIDATES_PER_DOMAIN) {
            return;
        }
        bucket.put(accountId, new CaseTypeAiClassifier.CandidateAccount(accountId, name, website, region));
    }

    private String truncate(String value, Integer max) {
        if (value == null) {
            return null;
        }
        return value.length() > max ? value.substring(0, max) : value;
    }

    private CaseComment buildComment(
        Id caseId,
        CaseTypeAiClassifier.ResearchContext ctx,
        CaseTypeAiClassifier.ClassificationResult research,
        String outcome,
        String detail
    ) {
        String confidence = (research == null || research.confidence == null) ? 'null' : String.valueOf(research.confidence);
        return new CaseComment(
            ParentId = caseId,
            IsPublished = true,
            CommentBody = '[CaseTypeRouter Region Research] outcome=' + outcome
                + '; internalForward=' + (ctx == null ? 'null' : String.valueOf(ctx.isInternalForward))
                + '; externalSender=' + (ctx == null ? 'null' : String.valueOf(ctx.externalSenderEmail))
                + '; suggestedRegion=' + (research == null ? 'null' : String.valueOf(research.suggestedRegion))
                + '; matchedAccountId=' + (research == null ? 'null' : String.valueOf(research.matchedAccountId))
                + '; confidence=' + confidence
                + '; detail=' + detail
                + '; reason=' + (research == null ? '' : research.reason)
        );
    }
}
