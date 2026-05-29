# Authoring System Skill Executors (with cross-step data flow)

How to write a system-extension AI skill executor so it is (a) invocable by an agent, (b) discoverable
by the concierge, and (c) **composable** — its outputs can feed a later step in a multi-step
provisioning mission. Companion to `SKILL_EXECUTORS.md` (reference) and `SKILL_EXECUTOR_CATALOG.md`
(auto-generated; never hand-edit).

> A new skill is "done" only with: executor + `Ai::Skill` row + agent binding + (if autonomous) an
> intervention policy + MCP action + tests + this doc's output convention. See the root plan's
> Definition of Done.

## 1. Anatomy

Every executor subclasses `System::Ai::Skills::BaseSkillExecutor`
(`server/app/services/system/ai/skills/base_skill_executor.rb`):

```ruby
module System
  module Ai
    module Skills
      class ExposeServicePubliclyExecutor < BaseSkillExecutor
        skill_descriptor(
          name: "expose_service_publicly",
          description: "Allocate a VIP, map a port, issue an ACME cert, create a DNS record, and regenerate the Traefik route for a service",
          category: "networking",
          inputs: {
            service_endpoint: { type: "string", required: true, description: "host:port the proxy forwards to" },
            public_hostname:  { type: "string", required: true, description: "FQDN to expose" },
            network_id:       { type: "string", required: false, description: "Sdwan::Network to allocate the VIP from" }
          },
          outputs: {                      # <-- see §3 for the convention
            outputs: {
              vip_id: :string,
              port_mapping_id: :string,
              certificate_id: :string,
              dns_record_id: :string
            }
          },
          requires_approval: false,
          rollback: :rollback_expose_service_publicly,
          blast_radius: :medium
        )

        binds_to "Fleet Autonomy"        # agent name or alias (SkillBindings::AGENT_ALIASES)

        protected

        # `**_extras` swallows context kwargs the composer injects into every
        # step (notably `brief`) so the runner's execute(**inputs) never raises.
        def perform(service_endpoint:, public_hostname:, network_id: nil, **_extras)
          # ... orchestrate, then:
          success(outputs: { vip_id:, port_mapping_id:, certificate_id:, dns_record_id: })
        end
      end
    end
  end
end
```

`execute` (in the base) validates required inputs, audit-logs, calls `perform`, and wraps exceptions
in `failure(...)`. Build dependent tools with `tool(::Ai::Tools::SomeTool)`. Return `success(payload)`
or `failure(message)`.

## 2. Binding, seeding, gating

1. **`binds_to "<Agent>"`** registers the executor with `SkillBindings`; `system_skill_bindings_seed.rb`
   walks `SkillBindings.discover` to create `Ai::AgentSkill` rows. The slug is derived as
   `system-<class.demodulize.underscore.sub(/_executor$/,'').dasherize>` (e.g.
   `ExposeServicePubliclyExecutor` → `system-expose-service-publicly`).
2. Add a matching **`Ai::Skill` row** in `system_skills_seed.rb` (slug must match — `SkillBindings.validate!`
   fails the seed otherwise).
3. **Autonomous** skills also need a `system.<action>` **intervention policy** in the owning agent
   seed (e.g. `fleet_autonomy_agent.rb`).
4. After seed changes: `cd server && rails db:seed` and watch for `SkillBindings.validate!` errors.

## 3. Output-key convention (REQUIRED for composability)

Downstream steps reference a predecessor's outputs by **dot-path** (see §4). To make every executor
predictably consumable, follow this convention — modeled on the most mature executor,
`ProvisionFullStackExecutor`:

- **Nest produced resource identifiers under a top-level `outputs:` key** in the `success(...)`
  payload (i.e. the returned `data[:outputs]` hash), separate from status fields like `dry_run`,
  `count`, `planned_actions`, `failures`, `partial`.
- **Plural array** for collections (`node_instance_ids`, `sdwan_peer_ids`, `storage_volume_ids`);
  **singular scalar** for a single resource (`network_id`, `vip_id`, `certificate_id`,
  `dns_record_id`, `port_mapping_id`).
- **Name by resource**, matching the AR model + the `*_id`/`*_ids` foreign-key style used elsewhere.
- The **`outputs:` declaration in `skill_descriptor` MUST match what `success(...)` actually returns.**
  A mismatch is a silent data-flow failure: the downstream step resolves `nil` and dies on
  `BaseSkillExecutor`'s required-input validation.

So a provider executor returns `{ success: true, data: { outputs: { node_instance_ids: [...] }, ... } }`
and a consumer references the dot-path `outputs.node_instance_ids`.

> An executor-output normalization sweep is bringing every executor onto this convention; see the
> Phase 0 task. New executors must conform from the start.

## 4. Cross-step data flow (`depends_on_outputs`)

`SkillCompositionRunner` (`server/app/services/ai/provisioning/skill_composition_runner.rb`) executes a
provisioning plan as a DAG. A step that needs a value produced by a predecessor declares it in its
`execution_config`:

```ruby
"depends_on_outputs" => {
  "<input_key>" => {
    "from_step" => <Integer predecessor step_number>,
    "path"      => "<dot.path into the predecessor's recorded outputs>",  # default: input_key
    "select"    => "first" | "last" | "all" | <Integer index>            # default: "all"
  }
}
```

At runtime, `execute_step!` calls `merge_depends_on_outputs`, which:
1. reads each predecessor's persisted `metadata["last_outputs"]` (the runner records `result[:data]`
   there on completion — persisted via the `ai_goal_plan_steps.metadata` jsonb column),
2. `dig_path`s into it (tolerating string AND symbol keys — outputs survive a JSON round-trip across
   the per-step worker-job boundary),
3. applies the `select` selector (array→scalar via `first`/`last`/index, or `all` for the whole value),
4. merges the resolved value into the step's inputs (overwriting compose-time placeholders; a missing
   upstream value is skipped — never clobbers an existing input with `nil`).

**Canonical example** — `PlanComposerService#append_deploy_app_code_step!` wires the deploy step's
required `node_instance_id` (singular scalar) from the upstream provision step's
`outputs.node_instance_ids` (plural array, nested):

```ruby
"depends_on_outputs" => {
  "node_instance_id" => { "from_step" => last_provision.step_number,
                          "path" => "outputs.node_instance_ids", "select" => "first" }
}
```

The composer (deterministic path) and the LLM `MissionComposer` (Phase 1) both emit this same shape;
the runner is the single resolver.

## 5. Rollback contract

Declare `rollback: :method_name` in the descriptor and define it as an **instance method** taking the
recorded outputs as kwargs:

```ruby
def rollback_expose_service_publicly(vip_id: nil, certificate_id: nil, dns_record_id: nil, **_extras)
  # reverse side effects LIFO; collect errors, never raise
  { success: errors.empty?, errors: errors }
end
```

On a step failure with `on_failure: "rollback"`, the runner walks completed predecessors in reverse
and invokes each one's rollback hook with its recorded outputs. (Note: rollback relies on the same
`metadata` persistence as data flow — both were dead before the `metadata` column was added 2026-05-28.)

## 6. Testing

- **Executor spec** (`server/spec/services/system/ai/skills/<name>_executor_spec.rb`): success path,
  failure path, `dry_run`, rollback, and that `success(...)` returns exactly the declared `outputs:` keys.
- **Runner integration**: if the skill participates in a multi-step plan, assert the `depends_on_outputs`
  mapping resolves (see `skill_composition_runner_spec.rb` "cross-step data flow" examples).
- **Composer**: if a composer appends the step, assert the emitted `execution_config` carries the
  expected `depends_on_outputs` (see `plan_composer_service_spec.rb`).
- End-to-end provider verification runs against a **Proxmox host** (`ProxmoxProvider`), not LocalQemu.
