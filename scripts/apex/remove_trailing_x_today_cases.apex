List<Case> todayCases = [
    SELECT Id, Subject
    FROM Case
    WHERE CreatedDate = TODAY
    WITH USER_MODE
];

List<Case> toUpdate = new List<Case>();
Integer skipped = 0;
for (Case c : todayCases) {
    String subj = c.Subject == null ? '' : c.Subject;
    if (!subj.endsWith('x')) {
        skipped++;
        continue;
    }
    c.Subject = subj.substring(0, subj.length() - 1);
    toUpdate.add(c);
}

if (!toUpdate.isEmpty()) {
    update toUpdate;
}

System.debug('TODAY_CASES=' + todayCases.size());
System.debug('UPDATED=' + toUpdate.size());
System.debug('SKIPPED=' + skipped);
