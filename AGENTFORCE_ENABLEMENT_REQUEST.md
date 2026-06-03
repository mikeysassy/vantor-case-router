# Agentforce enablement request — sandbox `digitalglobe--uptimadev`

**Org ID:** `00DU9000002EdbkMAC` · **Requestor:** Michael Sass (`michael.sass@salesforce.com.uptimadev`)

Hi team,

**The ask:** please provision **Agentforce custom agent publish + runtime** on our `digitalglobe--uptimadev` sandbox — i.e. the standard Agentforce agent permission sets and the agent publish/runtime API. Once that's on I don't need anything else; the agent is built and ready to publish.

**What's going on:** I built a knowledge-grounded Agentforce service agent. It validates and previews fine in simulation, but it won't publish — both `sf agent publish` and the Studio "Commit" button fail. The CLI gets a `404` from the publish/runtime API (`/einstein/ai-agent/v1.1/authoring/agents` and `/preview/sessions`), while the authoring routes (`authoring/scripts`) return `200`. Studio says *"User doesn't have access to agent… processing the Bot entity,"* and no `BotDefinition`/`BotVersion` ever gets created.

**Why I'm confident it's an org provisioning gap, not my config:** the standard Agentforce agent permission sets (`AgentforceServiceAgentUser`, `AgentforceServiceAgent`, `EinsteinServiceAgentUser`) don't exist in this org at all — there's nothing to assign. I'm System Admin with Agentforce Default Admin, the Einstein Agent service user is fully set up (Data Cloud, Copilot, Prompt Template access), and `AiAuthoringBundle` metadata deploy was already enabled here on 5/20. The same wall blocked a different agent (`Case_Type_Router`) on 5/20, so it's recurring — design-time is enabled, publish/runtime isn't.

Happy to jump on a call or walk through a live repro. Thanks!

Michael
