# Governance gaps — the Platform Architect's improvement offers

> Status: active (HIER-P3, 2026-09-04)
> Audience: platform operators reviewing the Platform Architect's offers
> Prerequisites: `ai.agents.manage` (the approver on the `Platform Architect Actions` chain), the Autonomy panel
> Runtime: ~5 min per offer

The platform reports its own governance drift. On every fleet tick
`GovernanceGapSensor` compares the declarations the agent hierarchy is built
from (`System::Governance::PolicyDeclarations`, `SkillBindings`,
`DecisionEngine::SIGNAL_BINDINGS`, `HierarchyReconciler`) with the running
database and emits one `system.governance_gap` signal per gap. The
`DecisionEngine` routes it to the **Platform Architect**, which files ONE
`Ai::ImprovementRecommendation` per gap — the offer you review here — and, for
the gaps the runtime can close, materialises the fix under the approval gates
the operator rulings of 2026-09-03 set (skill and prompt refinements auto-apply
on a trusted agent; structural changes always wait for you).

Every gap kind is one the 2026-09-03 hierarchy audit found by hand. The sensor
exists so the next one is found by the tick, not by the next audit.

## What an offer means

| `gap_kind` | The gap | Offer type | Closes by |
|---|---|---|---|
| `category_unowned` | A `system.` / `sdwan.` category is registered (tunable in the Autonomy panel) but no `PolicyDeclarations` set declares it, so no agent owns it and `PolicyReconciler` never writes its row | `capability_gap` | Code: declare it in the owning agent's set (`extensions/system/server/app/services/system/governance/policy_declarations.rb`) or deregister it |
| `agent_without_skills` | A declared agent carries a policy set and binds no skill | `skill_creation` | Code (a `binds_to` + a catalog row), or **materialised** when the registry already declares pairs for it |
| `binding_without_skill` | A `SIGNAL_BINDINGS` lane is bound to `skill: nil` with no applier and no declaration that it is notify-only | `capability_gap` | Code: an executor, an applier, or a DECLARED exemption in `RemediationValidator` |
| `executor_without_skill_row` | An executor's `binds_to` names a skill slug with no global `Ai::Skill` row — the strict bindings seed would abort | `skill_creation` | Code: the catalog entry in `system_skills_seed.rb` |
| `binding_agent_unknown` | An executor's `binds_to` names no global agent | `capability_gap` | Code: the alias or the agent seed |
| `skill_binding_missing` | The registry declares an (agent, skill) pair and no `Ai::AgentSkill` row exists | `skill_creation` | **Materialised** (the boot reconcile writes it too) |
| `lineage_edge_missing` | A canonical has no active lineage edge under System Concierge | `team_composition` | **Materialised** (structural — always parks) |
| `delegation_policy_missing` | A canonical has no delegation policy on this account | `team_composition` | **Materialised** (structural — always parks) |
| `policy_owner_undeclared` | A declared category's agent-shape row sits on an agent the declarations do not know; the reconciler never touches it | `capability_gap` | Operator: re-home or deactivate the row (record a move in `PolicyReconciler::FORMER_OWNERS`) |
| `tool_family_unregistered` | A canonical's `tool_families` entry matches no registered action (exact or `<family>_` prefix) | `capability_gap` | Code: the agent's seed |

The offer's `evidence` carries the fingerprint (`governance_gap:<kind>:<subject>`),
the concrete subject and ids, the files a code fix touches, the number of
ticks that re-detected it and, when one exists, the `materialization` the
Platform Architect proposed and its status. `recommended_config.fix` is the
reviewable fix in one paragraph.

## Reviewing an offer

1. **Find it.** `platform.list_improvements` (or the Improvements page) with
   the offer type; the title reads `Governance gap (<kind>): <subject>` and
   `evidence.proposed_by` is `platform-architect`.
2. **Read the fix and the files.** A code fix names the file it lands in; a
   materialised fix names the seam (`HierarchyWriter`, `Ai::AgentSkill`,
   `Ai::SkillVersion`) and the deferred operation, if it parked.
3. **Decide.**
   - **Approve** a code-path offer (`capability_gap`, and any
     `skill_creation` / `team_composition` without a materialisation): it
     becomes work for the Platform Developer or a Claude Code session. Note
     that `platform.approve_improvement` promotes only the code-quality
     types into a dev-improve task; a governance offer is approved through
     the recommendations API (`POST /api/v1/ai/learning/recommendations/:id/apply`)
     or by handing the offer id to the executor of your choice — see the
     open question recorded for HIER-P3 in the proposal's ruling record.
   - **Approve the parked materialisation** (an `Ai::DeferredOperation` on
     the `Platform Architect Actions` chain — the Autonomy panel's pending
     operations, or `platform.approve_deferred_operation`): the operation
     replays as the Platform Architect, applies the write, and closes the
     offer as `applied`.
   - **Dismiss** an offer you do not want. A dismissed gap that is still
     present is re-filed as a NEW offer on the next tick — dismissal records
     your decision on that offer, it does not silence the sensor; close the
     gap, or declare the condition deliberate in code (the
     `binding_without_skill` kind, for example, is exactly a missing
     declaration).
4. **Watch it clear.** The sensor stops emitting the fingerprint the moment
   the gap closes; nothing needs cleaning up.

## What materialises, and under which gate

| Materialisation | Gate | `trusted` Platform Architect | Below `trusted` |
|---|---|---|---|
| `skill_binding` — an `Ai::AgentSkill` row | `dev.skill_refine` (core's trust-conditioned pair, **or the account-wide floor** — see below) | applies at once | parks **only where the pair is seeded** |
| `prompt_refinement` (**seam only — no sensor detector produces it yet**) — a new active `Ai::SkillVersion` on an existing skill, the previous prompt kept in the version's metadata | `dev.prompt_refine` (core's trust-conditioned pair, **or the account-wide floor**) | applies at once | parks **only where the pair is seeded** |
| `lineage_edge` — `HierarchyWriter#attach!` under System Concierge | `dev.governance_materialize` (`require_approval`, `PLATFORM_ARCHITECT_POLICIES`) | parks | parks |
| `delegation_policy` — `HierarchyWriter#ensure_delegation_policy!` with the declared attributes | `dev.governance_materialize` | parks | parks |

**The refine rows are not trust-conditioned on every account** (IMP-a51963f8717f,
proposal §5 ruling 11c). Core writes a scope-`global`, agent-less `auto_approve`
FLOOR for `dev.skill_refine` and `dev.prompt_refine` on EVERY account
(`Ai::Engineering::ReleaseDispatchFloorSeeder`), so that the MCP principals that
own no policy row — an operator's `mcp_client` identity, a dev-cell instance
principal — keep refining instead of parking. The trust-conditioned PAIR that
outranks a floor is seeded only on the **`Powernode Admin`** account's
canonicals. On any other account the acting Platform Architect owns no refine
row, so the floor decides and a binding or prompt refinement **applies at every
trust tier**, including `supervised`.

To restore the fail-safe on an account, give that account's Platform Architect
its own row for the category — an agent-scoped row outranks a global one at any
priority (`Ai::InterventionPolicy#specificity_key`), so `priority` cannot do it:

```ruby
Ai::InterventionPolicy.create!(
  account: account, scope: "agent", ai_agent_id: architect.id,
  action_category: "dev.skill_refine", policy: "require_approval",
  priority: 10, is_active: true, conditions: {}
)
```

The STRUCTURAL kinds are unaffected: nothing writes a floor for
`dev.governance_materialize`, so a lineage edge or delegation policy parks on
every account whatever the tier.

`prompt_refinement` is WIRED but UNPRODUCED: every `materialization` hash
`GovernanceGapSensor` stamps today is `skill_binding`, `lineage_edge` or
`delegation_policy` — there is no prompt-drift detector, so no offer reaches an
operator carrying a prompt refinement. The arm exists so a future detector (or
the Platform Architect's own offer) has a gated, versioned path to refine a
canonical skill's prompt rather than writing `ai_skills.system_prompt` in place.
Do not read the row above as something the loop does unattended today.

The gate is the policy row, not the code: an account with no row for a
category meets the `require_approval` default and parks. Every applied
materialisation writes one `AuditLog` row (`system.governance.gap_materialized`)
and one `fleet.governance_gap_materialized` event, both naming the offer.

To let refinements apply unattended, raise the Platform Architect's trust
tier to `trusted` (`platform.update_agent_trust_score` on the account's clone,
never the global canonical — see the canonical rule in
`docs/concepts/platform-engineering-agents.md`). Structural changes never
unlock by trust: that is operator ruling #3.

## A `fleet.governance_gap_stuck` event

The lane is SCORED: filing the offer is the remediation, and the gap's
persistence across settle windows is what the validate arc measures. A gap
that stands `STUCK_STREAK_THRESHOLD` (3) settle windows (90 s each) without
closing escalates as a HIGH `fleet.governance_gap_stuck` event — the same
mechanics as `fleet.remediation_stuck`, under its own kind — and the lane is
forced to `require_approval`, which mints ONE `Ai::ApprovalRequest` on the
`Platform Architect Actions` chain. That request is the terminal state: the
lane stays quiet while it is open.

What it means: the offer for this gap is still pending (nobody approved,
dismissed or materialised it). What to do: review the offer exactly as above.
Approving the approval request itself replays the propose executor (it
re-files or refreshes the same offer); rejecting it suppresses the escalation
for the ordinary rejection cooldown and the gap re-escalates if it still
stands. Neither replaces reviewing the offer.

## Tuning

- `platform.system_update_sensor_config({ sensor: "governance_gap", config: { max_per_tick: 50 } })`
  — the per-tick cap (default 25, highest severity first).
- The lane's verbs are the Platform Architect's rows in the Autonomy panel:
  `dev.campaign_propose` (proposing; retuning it to `require_approval` makes
  the executor run plan-only into the request), `dev.governance_materialize`
  (structural materialisations), and core's `dev.skill_refine` /
  `dev.prompt_refine` pair (refinements).

## Where the pieces live

- Sensor: `extensions/system/server/app/services/system/fleet/sensors/governance_gap_sensor.rb`
- Binding and the scoring applier: `extensions/system/server/app/services/system/fleet/decision_engine.rb`
- Propose executor: `extensions/system/server/app/services/system/ai/skills/governance_gap_propose_executor.rb`
- Materialiser and its gates: `extensions/system/server/app/services/system/governance/gap_materializer.rb`
- The versioned prompt path: `server/app/services/ai/self_improvement/skill_refinement_service.rb`
- The declared set and the core-canonical identity: `extensions/system/server/app/services/system/governance/policy_declarations.rb`
- Concept: `docs/concepts/platform-engineering-agents.md` (parent tree)
