# Internal Enablement Request — Agentforce Custom Agent Publish/Runtime

**Requestor:** Michael Sass (`michael.sass@salesforce.com.uptimadev`)
**Org:** `digitalglobe--uptimadev` sandbox
**Org ID:** `00DU9000002EdbkMAC`
**Instance:** `https://digitalglobe--uptimadev.sandbox.my.salesforce.com`
**Release / max API version:** v67.0 (current)
**Date:** 2026-06-02

## Summary / Ask

Please provision **Agentforce custom agent publish + runtime** on this sandbox. The org
has the Agentforce *design-time/authoring* surface and Agentforce *Default (Copilot)*,
but it cannot **publish or run a custom Agentforce agent** (Service or Employee). The
standard Agentforce agent permission sets are absent and the agent publish/runtime
Connect API routes return `404`.

Specifically, please enable whatever provisions:
- The standard Agentforce agent permission sets (e.g. `AgentforceServiceAgentUser`,
  `AgentforceServiceAgent`) — none currently exist in this org.
- The Agent publish/runtime API routes under `/einstein/ai-agent/v1.1/` (see below).

## What works today (design-time)

- `sf agent generate authoring-bundle` ✅
- `sf agent validate authoring-bundle` ✅ (`authoring/scripts` route)
- `sf agent preview --simulate-actions` ✅ (returns a session; routing verified)
- `sf project deploy start` of the `AiAuthoringBundle` ✅ (metadata-deploy was enabled
  for this org on 2026-05-20 via a prior request)
- Data Cloud + Agentforce Data Library (`Vantor_Data_Sheets`) ✅ indexed, retriever live
- Prompt Templates / Einstein generative AI ✅

## What fails (publish + runtime)

All on the same host with valid System Administrator + Agentforce Default Admin auth:

| Operation | CLI | Endpoint | Result |
|---|---|---|---|
| Live preview | `sf agent preview start --use-live-actions` | `POST /einstein/ai-agent/v1.1/preview/sessions` | **404** (api / test.api / dev.api hosts) |
| Publish | `sf agent publish authoring-bundle` | `POST /einstein/ai-agent/v1.1/authoring/agents` | **404** |
| Studio "Commit" (UI) | — | — | "We couldn't commit a version of this agent… An error occurred when processing the Bot entity with name `Vantor_Product_Concierge`. **User doesn't have access to agent.**" |
| `agentAccesses` permset deploy | `sf project deploy start` | Metadata API | "In field: botDefinition — **no Bot named `Vantor_Product_Concierge` found**" |

Note the catch-22: the `agentAccesses` grant cannot deploy because no runtime `Bot`
exists, and the runtime `Bot` cannot be created because publish/commit is blocked.
A failed Studio commit auto-creates an orphan `NextGen_..._Permissions` permset but
**no `BotDefinition`/`BotVersion`** is ever created.

## Evidence of the permission gap

```
-- Standard service-agent permsets: NONE found
SELECT Name FROM PermissionSet
WHERE Name IN ('AgentforceServiceAgentUser','AgentforceServiceAgent',
               'EinsteinServiceAgentUser','EinsteinServiceAgent')
=> 0 records

-- BotDefinition / BotVersion for the agent: NONE
SELECT Id FROM BotDefinition  WHERE DeveloperName = 'Vantor_Product_Concierge' => 0
SELECT Id FROM BotVersion     WHERE BotDefinition.DeveloperName = 'Vantor_Product_Concierge' => 0
```

The Einstein Agent service user is fully provisioned otherwise:
- User: `agent.user.266e881435f2@salesforce.com.uptimadev` (`005U900000UzRA5IAN`), active,
  profile "Einstein Agent User"
- PSLs: `EinsteinGPTCopilotPsl`, `GenieDataPlatformStarterPsl`, `EinsteinGPTPromptTemplatesPsl`
- Permsets: `CopilotSalesforceUser`, `GenieUserEnhancedSecurity` (Data Cloud User),
  `EinsteinGPTPromptTemplateUser`

## Prior precedent (same org)

On 2026-05-20 an Agentforce agent (`Case_Type_Router`) hit the identical wall — publish
blocked, Studio commit "User doesn't have access to agent," `agentAccesses` "no Bot
named…". It was ultimately abandoned in favor of deterministic Apex. This is a recurring
provisioning gap, not a one-off.

## Reproduction (CLI)

```bash
sf agent validate authoring-bundle --json --api-name Vantor_Product_Concierge          # success
sf agent preview start --json --authoring-bundle Vantor_Product_Concierge --simulate-actions  # success
sf agent preview start --json --authoring-bundle Vantor_Product_Concierge --use-live-actions  # 404
sf agent publish authoring-bundle --json --api-name Vantor_Product_Concierge           # 404 (authoring/agents)
```

## After enablement

No code changes expected. Once the org is provisioned, this should publish immediately:

```bash
sf agent publish authoring-bundle --json --api-name Vantor_Product_Concierge
sf agent activate --json --api-name Vantor_Product_Concierge
```

Then assign the staged `agentAccesses` permission set and run the test suite.
