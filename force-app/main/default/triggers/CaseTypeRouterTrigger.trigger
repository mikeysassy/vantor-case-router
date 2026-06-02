trigger CaseTypeRouterTrigger on Case (after insert, after update) {
    CaseTypeRouterService.routeAfterSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
