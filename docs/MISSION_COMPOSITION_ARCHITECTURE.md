# Mission Composition Architecture

How the platform turns an operator's intent into an executable, approval-gated
infrastructure plan — and runs it. This is the architecture reference behind the
operator-facing [`CONCIERGE_PROVISIONING_GUIDE.md`](./CONCIERGE_PROVISIONING_GUIDE.md).

The central design choice is **two composition paths that converge on one
runtime**. A deterministic path handles recognized provisioning scenarios; an
LLM-general path handles novel intents. Both emit the *same* plan shape, so a
single runner, a single cross-step data-flow substrate, a single rollback
mechanism, and a single approval gate apply to either.

All file references are to the **parent platform** tree (`server/…`) unless
noted; these composition services are core, and the system extension supplies
the executors, the mission template, and the Concierge surface.

---

## 1. The shared plan shape

Both composers produce an `Ai::GoalPlan` whose steps are
`Ai::GoalPlanStep` records of `step_type: "provisioning_skill"`. Each step's
`execution_config` is the contract the runner consumes:

```ruby
{
  "skill"              => "<executor_name>",   # e.g. "provision_full_stack"
  "inputs"             => { ... },             # resolved executor inputs
  "depends_on_outputs" => { ... },             # optional cross-step wiring (see §4)
  "on_failure"         => "rollback" | "continue"
}
```

Plus, on the step record itself:

- `step_number` — integer, the dependency token.
- `dependencies` — array of predecessor `step_number`s.

Because both paths emit exactly this, everything downstream — the
`SkillCompositionRunner`, the `plan_review` approval gate, rollback, and the
live `MissionChannel` streaming — is path-agnostic. This reuse-first stance is
explicit in the `MissionComposer` class documentation: rather than introduce a
parallel plan model, it emits the same shape `SkillCompositionRunner` already
executes.

---

## 2. Path A — deterministic provisioning (`PlanComposerService`)

`Ai::Provisioning::PlanComposerService`
([`server/app/services/ai/provisioning/plan_composer_service.rb`](../../../server/app/services/ai/provisioning/plan_composer_service.rb))
is the path for **known provisioning scenarios**. It is what runs today for
every infrastructure mission.

### Inputs and flow

1. Reads the Project Brief from `mission.configuration["brief"]` (raises
   `BriefMissingError` if absent — capture must run first).
2. Guards on the daily LLM cost cap (`CostCapGuard`); returns `nil` and sets
   `cap_exceeded_payload` when exhausted.
3. Resolves the BYOC provider choice. With multiple configured providers and no
   unambiguous `preferred_provider`, it short-circuits and returns a
   `{ clarification_needed: true, … }` payload instead of composing.
4. Finds or creates a backing `Ai::AgentGoal`, then defers DAG synthesis to the
   `Ai::Autonomy::GoalDecompositionService` LLM kernel.
5. **Rewrites** every emitted step into the provisioning shape via
   `rewrite_step!` — dropping advisory step types (`human_review`,
   `observation`, `sub_goal`) and keeping only executable ones.
6. Resolves human-readable brief values into concrete record UUIDs
   (`template_id`, `provider_region_id`, `provider_instance_type_id`) so the
   persisted plan carries actionable inputs.
7. Stamps the plan id onto `mission.configuration["plan"]["plan_id"]`.

### The hard constraint: `ALLOWED_EXECUTORS`

The defining property of this path is that **every step's skill must be in a
fixed allow-list** — `PlanComposerService::ALLOWED_EXECUTORS`. The composer maps
an action description to a skill via, in order:

1. `Ai::Tools::SemanticToolDiscoveryService` (semantic match, filtered to the
   allow-list), then
2. a static regex `STATIC_ACTION_MAP` (first match wins), then
3. `DEFAULT_EXECUTOR` (`provision_full_stack`).

`validate_plan` re-checks that every step's skill is in `ALLOWED_EXECUTORS`,
that the graph is acyclic, and that every dependency references a real step.
This is what makes the path *deterministic and bounded*: the brief can only
produce provisioning skills the platform recognizes.

### Over-decomposition guards

The LLM kernel sometimes emits redundant trees for a trivial brief. The composer
folds them: `collapse_consecutive_same_target_steps!` merges linear-chain
duplicates, and `collapse_redundant_provisioning_clusters!` collapses
identical-fingerprint `provision_full_stack` steps regardless of DAG shape,
capping the count to `brief.scale.initial`. The result is that a one-instance
brief produces a one-instance plan even if the kernel hallucinated eight
redundant steps.

### Run-my-code extension

When the brief carries `repo_url`, the composer attaches a runtime role module
to the node template (`ROLE_MODULE_FOR_USE_CASE` / `RUNTIME_HINT_TO_MODULE`)
and appends a `deploy_app_code` step. That step's `node_instance_id` is unknown
at compose time, so it is wired via `depends_on_outputs` to the upstream
`provision_full_stack` step's `outputs.node_instance_ids` (see §4).

---

## 3. Path B — LLM-general composition (`MissionComposer`)

`Ai::Missions::MissionComposer`
([`server/app/services/ai/missions/mission_composer.rb`](../../../server/app/services/ai/missions/mission_composer.rb))
is the **novel-intent** half. Where Path A is constrained to the provisioning
allow-list, Path B can sequence **any agent-bound skill** — federation, SDWAN,
ingress, runtime, and so on. It is the general composer the router selects for
novel intents, converging on the same plan shape as Path A.

### Candidate pool (the real constraint)

Path B does not have a static allow-list. Its constraint is the **candidate
pool**: only skills that are `status: "active"` **and** bound to at least one
agent (`Ai::AgentSkill` with `is_active: true`) **and** resolve to an executor
descriptor are composable, capped at `MAX_CANDIDATES` (20). Each candidate is
resolved to its executor's I/O contract (descriptor `inputs` / `outputs`) so the
LLM can wire data flow and so the runner-dispatched identifier (the executor
`name`, not the `Ai::Skill` slug) can be validated. The LLM cannot invent a
skill outside this pool.

### Decompose → validate → persist

1. **Cost cap** — `CostCapGuard` gates the LLM call; returns `nil` on exhaust.
2. **Decompose** — the LLM is prompted with the candidate catalog (skill ids +
   input/output keys) and asked for an ordered DAG as strict JSON.
3. **Validate / normalize** — steps referencing a non-candidate skill are
   *dropped* (a near-miss should not fail the whole plan); steps are renumbered
   contiguous from 1; `depends_on_outputs.from_step` is remapped; the graph is
   cycle-checked (a cyclic plan is rejected outright); at most `MAX_STEPS` (15)
   steps survive.
4. **Persist** — creates a `draft` `Ai::GoalPlan` and the same
   `provisioning_skill` steps with `{ skill, inputs, depends_on_outputs,
   on_failure: "rollback" }`, then links the plan id to the mission via
   `mission.configuration["plan"]["plan_id"]` — exactly the pointer Path A sets.

Because the persisted shape and the mission pointer are identical, the existing
execute path (`AiProvisioningExecuteJob` → `SkillCompositionRunner`) runs a
Path-B plan unchanged once the operator clears the `plan_review` gate.

---

## 4. Cross-step data flow (`depends_on_outputs`)

A step rarely knows, at compose time, a value another step will produce at
runtime (e.g. the instance id a `provision_full_stack` step creates). Both
composers express this with `execution_config["depends_on_outputs"]`, resolved
by `Ai::Provisioning::SkillCompositionRunner`
([`server/app/services/ai/provisioning/skill_composition_runner.rb`](../../../server/app/services/ai/provisioning/skill_composition_runner.rb)).

Shape:

```ruby
"depends_on_outputs" => {
  "<input_key>" => {
    "from_step" => <predecessor step_number>,
    "path"      => "<dot.path into that step's recorded outputs>", # default: input_key
    "select"    => "first" | "last" | "all" | <Integer index>      # default: "all"
  }
}
```

### How the runner resolves it

Each completed step's outputs are persisted to its `metadata["last_outputs"]`
(`record_outputs`). Before invoking a step, `merge_depends_on_outputs`:

1. builds `{ predecessor_step_number => recorded_outputs }` for the step's
   declared dependencies (`upstream_outputs_for`, reading each predecessor's
   `metadata["last_outputs"]`),
2. for each mapping entry, digs the dot-path into the source outputs
   (`dig_path`, tolerant of string/symbol keys across the JSON round-trip),
3. applies the array selector (`select_output` — `first`/`last`/index/`all`),
4. overwrites the compose-time placeholder for that input key. A missing/blank
   upstream value is skipped, never clobbering an existing input with `nil`.

The canonical example: `deploy_app_code` pulls `node_instance_id` from the
upstream `provision_full_stack` step's `outputs.node_instance_ids` with
`select: "first"`. This is the same substrate the `MissionComposer` prompt
instructs the LLM to use, so Path A and Path B wire data flow identically.

---

## 5. Hybrid routing

The platform's intended composition strategy is **template-match first, LLM
fallback**:

- **Template / recognized-scenario match** — when an intent maps to a known
  provisioning scenario, the deterministic Path A
  (`Ai::MissionTemplate` + `PlanComposerService`) composes it. This is bounded
  by `ALLOWED_EXECUTORS` and benefits from the over-decomposition guards and
  brief→UUID resolution.
- **LLM fallback for novel intents** — when the intent does not fit a recognized
  provisioning scenario, the general Path B (`MissionComposer`) sequences any
  agent-bound skill into the same plan shape.

### Where the routing lives

The decision is centralized in `Ai::Missions::ComposerRouter`
([`server/app/services/ai/missions/composer_router.rb`](../../../server/app/services/ai/missions/composer_router.rb)),
which exposes a side-effect-free `deterministic_provisioning?(brief)` predicate
and a `select(brief:)` that returns the chosen — but not-yet-invoked — composer.
The predicate is grounded entirely in `PlanComposerService`'s existing signal
maps (`ROLE_MODULE_FOR_USE_CASE`, `RUNTIME_HINT_TO_MODULE`) plus provisioning-shaped
brief fields (a non-empty `regions` list, a `preferred_provider`, a mappable
`runtime_hint`, or `scale.initial > 0`) — there is no hardcoded use_case enum. It
runs **before** composing (never try-then-discard), because `PlanComposerService`
persists on success and a discarded probe would leak a real plan.

All three compose entry points route through `ComposerRouter`, so the decision is
identical everywhere, and all three read/write the same
`mission.configuration["plan"]["plan_id"]`:

- **Server-driven (worker phase job)** — `AiProvisioningComposePlanJob` POSTs to
  `POST /api/v1/internal/ai/provisioning/missions/:mission_id/compose_plan`
  (`Api::V1::Internal::Ai::ProvisioningController#compose_plan`), which selects its
  composer via `ComposerRouter`. This is the path the orchestrator drives
  automatically when the mission enters the `compose_plan` phase.
- **Concierge chat** — `Ai::Tools::ProvisioningTool#compose_plan` (the MCP action
  the Concierge dispatches through `ConciergeToolBridge`) selects its composer via
  `ComposerRouter`.
- **Interactive deep-link (REST)** — `POST /api/v1/ai/missions/:id/compose_plan`
  (`Api::V1::Ai::MissionsController#compose_plan`) branches on
  `mission_type == "infrastructure"`, reuses the cached plan when one already
  exists (no extra LLM cost), and otherwise composes a new one via `ComposerRouter`.

Because every path emits the identical `provisioning_skill` plan shape and the
same mission pointer, the execute/approve/runner spine carries a Path-A or Path-B
plan unchanged. The routing decision selects a composer, not a runtime.

---

## 6. Convergence: one runner, one gate

After either composer persists a plan and stamps the mission's `plan_id`, the
lifecycle is identical.

### The runner

`Ai::Provisioning::SkillCompositionRunner` orchestrates the plan as a DAG of
skill invocations, server-side, in parallel-safe layers:

- `execute!` computes Kahn-style topological layers from `step.dependencies`,
  dispatches the first ready layer as per-step worker jobs
  (`WorkerJobService.enqueue_job("AiProvisioningStepJob", …)`), and records
  run-start side effects. It is idempotent — if any step is already past
  `pending`, it returns the existing run state instead of re-dispatching (this
  closed a double-provision race).
- `execute_step!(step)` is the per-step entrypoint called back via the internal
  API. It resolves the executor by convention
  (`provision_full_stack` → `System::Ai::Skills::ProvisionFullStackExecutor`,
  falling back to `Ai::Skills::…`), merges `depends_on_outputs`, invokes the
  executor, records outputs, marks progress, and dispatches newly-unblocked
  successors. Also idempotent per step.
- On step failure with `on_failure: "rollback"`, it walks completed
  predecessors in reverse and runs each one's `descriptor[:rollback]` hook.

Every transition emits two side effects: a system message into the mission
conversation, and a `provisioning_step_changed` broadcast through
`Ai::Missions::OrchestratorService#broadcast_step_event!` — the single canonical
emission path for step events.

### The approval gates (`OrchestratorService#handle_approval!`)

Execution is never automatic — it is gated. The `system_provisioning` template
defines two approval gates: `review_plan` (gate name `plan_review`) and
`handoff`. The mission pauses at each (`Ai::Mission#awaiting_approval?`), and an
inline Approve/Reject card is posted to chat.

Approving routes through
`Ai::Missions::OrchestratorService#handle_approval!`
([`server/app/services/ai/missions/orchestrator_service.rb`](../../../server/app/services/ai/missions/orchestrator_service.rb)),
which:

1. records an `Ai::MissionApproval` (user, gate, decision),
2. honors the second-signature gate at `handoff` (Business+ plans require two
   distinct approvers),
3. on approve, calls `advance!`, transitioning the mission to the next phase and
   dispatching that phase's worker job — approving `review_plan` advances to
   `execute`, which dispatches `AiProvisioningExecuteJob` → the runner,
4. on reject, rolls the mission back per the template's `rejection_mappings`
   (`review_plan` → `compose_plan`, `handoff` → `verify`).

The phase-name → gate-name mapping is centralized in
`Ai::MissionApproval.gate_for_phase` (`review_plan` → `plan_review`), so every
layer agrees on which gate is active.

### Why approval is the single execution trigger

There is deliberately **no** `platform_provisioning_execute` tool action — the
internal `#execute` endpoint reached by `AiProvisioningExecuteJob` is the only
path to a run. Approval at `review_plan` is what advances the mission into
`execute`; the orchestrator drives it from there. A separate execute tool
variant raced this path and double-provisioned, which is why it was removed.

---

## 7. The orchestration spine end to end

```
Operator NL  ──▶  ConciergeToolBridge.classify_and_dispatch_provisioning
                     │  (intent == provision_infrastructure, confidence ≥ 0.5)
                     ▼
              ProvisioningTool: capture_brief
                     │  IntentCaptureService → mission.configuration["brief"]
                     ▼
              ┌── HYBRID ROUTING ──────────────────────────────────────┐
              │  recognized provisioning scenario → PlanComposerService │  (Path A: ALLOWED_EXECUTORS)
              │  novel intent                     → MissionComposer     │  (Path B: any agent-bound skill)
              └────────────────────────────────────────────────────────┘
                     │  both: Ai::GoalPlan of provisioning_skill steps
                     │        + mission.configuration["plan"]["plan_id"]
                     ▼
              review_plan gate  ──▶  inline Approve/Reject card
                     │  OrchestratorService#handle_approval! (records MissionApproval, advance!)
                     ▼
              AiProvisioningExecuteJob → SkillCompositionRunner.execute!
                     │  topological layers → AiProvisioningStepJob per step
                     │  execute_step! → executor → record outputs → dispatch successors
                     │  depends_on_outputs resolved from predecessor metadata.last_outputs
                     │  broadcasts via OrchestratorService#broadcast_step_event!
                     ▼
              verify → handoff gate → RalphLoop → adapting (sensor-driven)
```

---

## 8. Key source files

| Concern | File |
|---------|------|
| Deterministic composer (Path A) | `server/app/services/ai/provisioning/plan_composer_service.rb` |
| LLM-general composer (Path B) | `server/app/services/ai/missions/mission_composer.rb` |
| DAG runner + cross-step data flow | `server/app/services/ai/provisioning/skill_composition_runner.rb` |
| Worker phase callbacks (internal API) | `server/app/controllers/api/v1/internal/ai/provisioning_controller.rb` |
| Interactive compose entry | `server/app/controllers/api/v1/ai/missions_controller.rb` (`#compose_plan`) |
| Concierge MCP surface | `server/app/services/ai/tools/provisioning_tool.rb` |
| Approval engine + phase advance + step broadcast | `server/app/services/ai/missions/orchestrator_service.rb` |
| Phase → gate mapping | `server/app/models/ai/mission_approval.rb` |
| Mission model + inline gate card metadata | `server/app/models/ai/mission.rb` |
| Mission template (phases, gates, rejection mappings) | `extensions/system/server/db/seeds/system_provisioning_mission_template.rb` |
| Compose worker job | `worker/app/jobs/ai_provisioning_compose_plan_job.rb` |
| Execute worker job | `worker/app/jobs/ai_provisioning_execute_job.rb` |
| Per-step worker job | `worker/app/jobs/ai_provisioning_step_job.rb` |
