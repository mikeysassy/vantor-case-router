trigger CaseTypeRouterTrigger on Case (before insert, before update, after insert, after update) {
    if (Trigger.isBefore) {
        CaseTypeRouterService.routeBeforeSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    } else if (Trigger.isAfter) {
        CaseTypeRouterService.routeAfterSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    }
}
