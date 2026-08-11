# Concierge Provisioning Guide

> Status: active

Operator guide for running a provisioning mission by talking to the **System
Concierge** chat agent. This walks the full lifecycle — describe what you want,
review the composed plan, approve it inline in chat, and watch the resources
provision step by step.

This is the operator-facing companion to
[`MISSION_COMPOSITION_ARCHITECTURE.md`](./MISSION_COMPOSITION_ARCHITECTURE.md),
which documents how plans are composed and executed under the hood.

---

## 1. What this is

The provisioning conversation turns a plain-English request ("stand up a small
web app in us-east-1 with a $200/month budget") into an executable,
approval-gated infrastructure mission. You never have to assemble the DAG by
hand — the Concierge captures a structured brief, the platform composes a plan,
and you approve it before any resource is created.

Every provisioning run is backed by an `Ai::Mission` of
`mission_type: "infrastructure"`, bound to the system-wide
`system_provisioning` mission template. The template is seeded by
[`server/db/seeds/system_provisioning_mission_template.rb`](../server/db/seeds/system_provisioning_mission_template.rb)
— if you have not run that seed, the Concierge will tell you the template is
missing.

---

## 2. Asking the System Concierge to provision

Open the System Concierge chat and describe what you want in natural language.
You do not need a special command or syntax — describe the workload, the region,
the scale, and any budget.

Example openers:

- "Provision a 2-instance API server in us-east-1, budget around $300/month."
- "Stand up a containerized app stack and deploy https://git.example.com/team/app.git on it."
- "I need a small database node with 99.9% availability."

### How the message is routed

When you send a message, the Concierge runs it through an intent classifier
before the general chat tool loop:

1. **Intent classification** — `Ai::ConciergeToolBridge#classify_and_dispatch_provisioning`
   calls `Ai::Provisioning::IntentCaptureService#classify`. This combines a
   regex pre-filter with an LLM confidence-scoring pass.
2. **Threshold gate** — the message is treated as a provisioning request only
   when the classified intent is `provision_infrastructure` **and** confidence
   is at least `0.5` (`PROVISIONING_CONFIDENCE_THRESHOLD`). Below that, the
   message falls through to the normal chat flow, so a casual mention of
   "infrastructure" will not accidentally start a mission.
3. **Brief capture** — on a hit, the bridge dispatches the
   `platform_provisioning_capture_brief` action of
   `Ai::Tools::ProvisioningTool`. With no `mission_id`, this creates a fresh
   infrastructure mission bound to the `system_provisioning` template and
   captures the first brief.

You can also drive the same flow directly through MCP tool actions if you are
scripting against the platform — see [§7](#7-mcp-tool-surface).

> **Why the Concierge stays on-topic.** The System Concierge runs with a
> `concierge_tool_filter` that narrows its tool surface to the provisioning- and
> fleet-relevant actions (`system_*`, `docker_*`, `kubernetes_*`, plus
> `discover_skills` / `get_skill_context` / `request_confirmation`) — roughly
> two dozen actions rather than the full platform catalog. This keeps plan
> composition focused and prevents the agent from reaching for unrelated tools
> mid-provision.

---

## 3. The phase pipeline

Every provisioning mission moves through the seven phases defined on the
`system_provisioning` template
([`system_provisioning_mission_template.rb`](../server/db/seeds/system_provisioning_mission_template.rb),
`PROVISIONING_PHASES`). Two of them are **approval gates** — the mission pauses
there until you act.

| Order | Phase key | Label | Approval gate | Worker job (server-driven path) |
|-------|-----------|-------|---------------|---------------------------------|
| 0 | `capture_intent` | Capture Brief | no | `AiProvisioningCaptureIntentJob` |
| 1 | `compose_plan` | Compose Plan | no | `AiProvisioningComposePlanJob` |
| 2 | `review_plan` | Review & Approve | **yes** (`plan_review`) | — (waits for you) |
| 3 | `execute` | Provision Resources | no | `AiProvisioningExecuteJob` |
| 4 | `verify` | Verify SLO Targets | no | `AiProvisioningVerifyJob` |
| 5 | `handoff` | Hand Off | **yes** (`handoff`) | — (waits for you) |
| 6 | `adapting` | Continuous Adaptation | no | — (sensor-driven, long-lived) |

The canonical pipeline is therefore:

```
capture_intent → compose_plan → review_plan(gate) → execute → verify → handoff(gate) → adapting
```

### capture_intent

`Ai::Provisioning::IntentCaptureService` translates your utterance into a
structured **Project Brief** stored at `mission.configuration["brief"]`. The
brief has required fields (`intent`, `use_case`, `scale`, `regions`,
`budget_cap_usd_monthly` — see `IntentCaptureService::REQUIRED_FIELDS`). The
tool returns the brief plus a `missing_fields` list.

- **If fields are missing**, the Concierge asks you for them. Reply in chat;
  each reply is merged onto the existing brief as a clarification (the tool
  calls `IntentCaptureService#refine`). The mission stays at `capture_intent`.
- **When the brief is complete** (`missing_fields` empty), the tool advances
  the mission to `compose_plan`.

### compose_plan

The platform composes an executable plan from the brief. For infrastructure
missions this runs `Ai::Provisioning::PlanComposerService#compose!`, which
decomposes the brief into a DAG of provisioning-skill steps (an `Ai::GoalPlan`).
The plan id is stamped onto `mission.configuration["plan"]["plan_id"]` so every
downstream consumer resolves the same plan. The mission then advances to
`review_plan`, where it stops and waits for you.

> The two composition paths (deterministic provisioning vs. LLM-general) and
> how they converge on the same plan shape are covered in
> [`MISSION_COMPOSITION_ARCHITECTURE.md`](./MISSION_COMPOSITION_ARCHITECTURE.md).

A few outcomes you may see at this phase:

- **Provider clarification** — if your account has multiple cloud providers
  configured and the brief does not name one, composition pauses and the chat
  surfaces a "which provider?" question with the available options. Answer it
  and the next compose round proceeds.
- **Cost cap reached** — if the account has exhausted its daily LLM cost cap,
  composition returns no plan and the chat surfaces an upgrade prompt rather
  than retrying.

### review_plan (approval gate)

The composed plan is presented in chat as a rich card with the step list. The
mission is now `awaiting_approval?` at the `plan_review` gate. **Nothing is
provisioned yet.** See [§4](#4-the-inline-approvereject-card) for how to act.

### execute

Once you approve, the mission advances to `execute` and
`AiProvisioningExecuteJob` kicks off `Ai::Provisioning::SkillCompositionRunner`.
The runner computes parallel-safe layers from the step dependencies and
dispatches one worker job per step. Each step runs its skill executor; steps
stream progress to chat and to the live UI as they transition. See
[§5](#5-monitoring-mission-and-step-progress).

### verify

After the steps complete, `AiProvisioningVerifyJob` runs a verification pass
against the mission's `slo_targets` and records the result on
`mission.configuration["verification"]`. On success the orchestrator advances to
`handoff`.

### handoff (approval gate)

The mission pauses at `handoff` — the second approval gate. Approving here
creates a per-mission `Ai::RalphLoop` (the long-lived adaptation driver) and
advances the mission to `adapting`. A system message marks the handoff in chat.

> On Business+ plans with `second_signature_required` enabled, the `handoff`
> gate requires **two distinct approvers**. The first approval is recorded and
> the mission stays at `handoff` until a different user also approves. Free/Pro
> tiers advance after a single approval.

### adapting

The terminal, long-lived phase. There is no worker job — the mission stays in
`adapting` while the `ProjectSloSensor` reconciler samples health and the
mission's RalphLoop holds the adaptation context. The mission remains active here.

> **What "adapting" does and doesn't do today.** The phase, the per-mission
> RalphLoop, and the SLO sensor are all live, so the mission keeps **monitoring**
> health. What is **not** yet wired is the step that turns an observed breach
> into a *new* adaptation plan: the `platform_provisioning_adapt` action is an
> M0 stub that returns `{ todo: "M2", adaptation_plan: nil }`. So treat
> `adapting` as continuous monitoring for now — don't expect the mission to
> self-replan or re-provision in response to drift until the M2 sensor
> reconciler ships.

### Rejections

Rejecting a gate rolls the mission back per the template's
`rejection_mappings`:

- Rejecting `review_plan` sends the mission back to `compose_plan` so you can
  refine the brief and recompose.
- Rejecting `handoff` sends it back to `verify`.

---

## 4. The inline Approve/Reject card

Approval gates on infrastructure missions render as a **clickable card directly
in the Concierge chat** — you do not need to leave the conversation or open a
separate modal.

### Where the card comes from

When the mission enters an approval-gate phase, `Ai::Mission#post_milestone_to_conversation`
posts a system message into the mission's conversation. For infrastructure
missions at a gate, that message carries action metadata:

```text
concierge_action: true
action_type:      "approve_mission_gate"
action_params:    { mission_id: <id>, gate: <phase>, decision: "approved" }
actions:          [ { type: "confirm", label: "Approve", style: "primary" },
                    { type: "reject",  label: "Reject",  style: "danger" } ]
action_context:   { type: "mission_approval", action_type: "approve_mission_gate", status: "pending" }
```

The chat UI renders this metadata as an Approve / Reject card.

### What happens when you click

Clicking **Approve** or **Reject** posts to the conversation's
`confirm_action` endpoint
(`POST /api/v1/ai/conversations/:id/confirm_action` with `action_type` and
`action_params`). That routes into
`Ai::ConciergeService#handle_confirmed_action`, which for
`approve_mission_gate` calls
`Ai::Missions::OrchestratorService#handle_approval!`. The orchestrator:

- records an `Ai::MissionApproval` (with your user id, the gate, and the
  decision),
- honors the second-signature gate at `handoff` when configured,
- on **approve**, advances the mission to the next phase (which dispatches the
  next phase's worker job — e.g. approving `review_plan` kicks off
  `AiProvisioningExecuteJob`),
- on **reject**, rolls the mission back per `rejection_mappings`.

The Concierge then posts a confirmation message ("Approved Review Plan for
… — now in Execute") and the original gate card is marked resolved.

> **Why approval is the only path to execution.** There is intentionally **no**
> `platform_provisioning_execute` action. Approval at `review_plan` is what
> advances the mission into `execute`; the orchestrator drives the run from
> there. A separate execute action used to race this path and double-provision.
> Approve once and let the pipeline carry it forward.

---

## 5. Monitoring mission and step progress

You have two live surfaces plus the chat transcript.

### In chat (system messages)

The runner posts a system message into the mission conversation as the run
starts and on every step transition, for example:

- `Provisioning run started — 4 step(s) across 2 layer(s).`
- `Step 1 (provision_full_stack) → executing`
- `Step 1 (provision_full_stack) → completed`

These are emitted by `SkillCompositionRunner` via the mission conversation's
`add_system_message`, so they appear inline in the same Concierge thread.

### Live UI streaming (`MissionChannel`)

For real-time step streaming, subscribe to the mission's `MissionChannel`
rather than polling. The runner (through
`Ai::Missions::OrchestratorService#broadcast_step_event!`) broadcasts:

| Event | When | Key payload |
|-------|------|-------------|
| `provisioning_run_started` | run kicks off | `runner_id`, `step_count`, `layer_count` |
| `provisioning_step_changed` | each step transition | `step_id`, `step_number`, `status`, `outputs`, `error` |
| `phase_changed` / `status_changed` | mission phase / status change | `current_phase`, `status`, `phase_progress` |

Step `status` values are `executing`, `completed`, `failed`, and `rolled_back`.
The provisioning UI consumes these via the step-progress stream and the
provisioning page.

### Status snapshot (point-in-time)

For a one-shot snapshot, use the `platform_provisioning_status` tool action
(or the Concierge's status reply). It returns the current mission `phase`, the
currently-executing step number, and step-number lists by status (`completed`,
`pending`, `failed`).

### When a step fails

If a step fails and its `on_failure` is `rollback`, the runner walks the
completed predecessors in reverse and runs each one's rollback hook, emitting
`rolled_back` events as it goes. Failures surface in both chat and the live
stream with the error message attached.

---

## 6. Run-my-code deploys

If your brief includes a `repo_url`, the composer attaches a runtime role module
to the provisioned node template and appends a `deploy_app_code` step that
depends on the provision step. The deploy step receives the provisioned
instance id at runtime (resolved from the upstream provision step's outputs),
so it deploys onto the instance the run just created. Provide `branch` and
`start_command` in the conversation to control how your code is checked out and
launched.

---

## 7. MCP tool surface

The whole lifecycle is also available as MCP tool actions on
`Ai::Tools::ProvisioningTool`, for scripting or for the Concierge tool bridge:

| Action | Purpose |
|--------|---------|
| `platform_provisioning_capture_brief` | NL + optional `mission_id` → brief + `missing_fields` (creates the mission when `mission_id` is omitted) |
| `platform_provisioning_compose_plan` | `mission_id` → plan id + DAG, with cost / topology / risk enrichments |
| `platform_provisioning_approve_plan` | `plan_id` + `decision` (`approved` / `rejected` / `modified`) → advances or rolls back the mission |
| `platform_provisioning_status` | `mission_id` → phase + step lists by status |
| `platform_provisioning_adapt` | adaptation entry point — **M0 stub** today; returns `{ todo: "M2", adaptation_plan: nil }`. Wires up with the M2 SLO-sensor reconciler |

For live progress, prefer subscribing to `MissionChannel` over polling
`platform_provisioning_status`.

---

## 8. Troubleshooting

| Symptom | Likely cause | What to do |
|---------|--------------|------------|
| Concierge answers normally instead of starting a mission | Intent classified below the `0.5` confidence threshold | Rephrase more explicitly ("provision…", "stand up…", state region + scale) |
| "Mission template 'system_provisioning' not seeded" | Template seed not run | Run [`system_provisioning_mission_template.rb`](../server/db/seeds/system_provisioning_mission_template.rb) |
| Chat asks "which provider?" | Multiple providers configured, brief did not name one | Reply with the provider; composition resumes |
| Compose returns no plan, upgrade prompt shown | Daily LLM cost cap reached | Wait for the cap window to reset or raise the plan limit |
| Mission stuck at `review_plan` | Awaiting your approval | Use the inline Approve card |
| Mission stuck at `handoff` after one approval | Second-signature gate (Business+) | Have a second distinct user approve |
| Steps not progressing past the first layer | Worker not draining `ai_execution` | Check `powernode-*-sidekiq.service` status |

_Last verified: 2026-06-03_
