# Template Versioning Audit — the join set, its effective closure, and what is reconstructable today

**Task:** IMP-c7d7f82e66f1 — "Template versioning: audit the join set and its effective closure,
starting without a migration."
**Disposition:** audit only. No source was changed and no specs were added; every defect below is
filed here rather than fixed. Anything that should change becomes its own task.
**Date:** 2026-08-05

Read against `System::TemplateModule`, `System::TemplateExpansionService`,
`System::TemplateComposerService`, `System::TemplateCompositionAnalysis`,
`Api::V1::System::TemplateModulesController`, `Ai::Tools::SystemFleetTool`, and
`System::LifecycleAuditable`, plus the `system_template_modules`,
`system_node_module_assignments` and `system_node_templates` tables in the core schema.

---

## 1. The join set vs the effective closure

**The join set** is the `system_template_modules` rows for one template. Each row carries
`node_module_id`, `priority` (integer, default 0), `enabled` (boolean, default true), `config`
(jsonb) and `recommends_override` (jsonb), with a unique index on
`(node_template_id, node_module_id)`.

**The effective closure** is what `TemplateExpansionService` produces and `TemplateApplyService`
then materialises onto a node as `NodeModuleAssignment` rows. It is computed by taking the
**enabled** joins, resolving transitively through `DependencyResolutionService`, and ordering by
priority (higher first) then resolution order.

The join set is therefore an **input**, not a description of what ships. Six ways the two diverge:

| # | Divergence | Direction | Deliberate? |
|---|---|---|---|
| D1 | `enabled: false` joins | in the set, **not** in the closure | Yes — the documented non-destructive removal |
| D2 | Transitively-pulled modules | in the closure, **not** in the set (`source_template_module_for[id]` is nil) | Yes — that is what resolution is for |
| D3 | `recommends_override` | per-join hash changes which `recommends` edges are followed, so **identical join sets can yield different closures** | Yes |
| D4 | Catalog drift | a dependency added to a module *after* the join was written silently enlarges the closure with **no join change** | Emergent |
| D5 | Missing dependency | resolver records an error; expansion still returns and apply proceeds | Emergent |
| D6 | Error-severity conflict | expansion **warns**, does not refuse | Yes — see §4 |

D4 is the one that matters most for versioning: **the closure is a function of the join set *and*
the account's module catalog at the moment of expansion.** Re-expanding a template today does not
reproduce what it expanded to last week, even if no join changed.

---

## 2. Versioning today — what is answerable without a migration

**There is no versioning.** `system_node_templates` has no version column (only `created_at` /
`updated_at`); there is no history table for joins; and the closure is never persisted anywhere.

Taking the task's own constraint seriously — what the *current* schema can answer:

**Per node: partially reconstructable.** `system_node_module_assignments` is the closest thing to a
build record that exists. Each row carries `node_module_id`, `priority`, `config` and
`source_template_module_id` (indexed) — a materialised snapshot of the closure *as applied to that
node*. Three limits:

- `source_template_module_id` is **nullable and is nullified when the join is destroyed** (stated in
  both the MCP tool description and the controller comment). Provenance is erased by the operation
  most likely to prompt the question "what was this built from?".
- A null is **ambiguous**: it means either "pulled transitively" (D2, by construction) or "the join
  was deleted afterwards" (F3). Nothing distinguishes them.
- There is no record of *which* apply produced the row beyond its own timestamps.

**Per template: nothing.** `updated_at` on a join says it changed; it does not say what it was.
There is no audit row (F1), and the only event emitted is partial and one-surface-only (F2).

**So, to the question as asked:**

- *Can an operator tell which version of a template a node was built from?* **No.** No version
  identifier exists on the template, the join set, or the assignment.
- *Can they reconstruct it?* **Partially, per node, and only until a join is destroyed** — by
  reading that node's assignments. Never per template, and never as of a past point in time.

---

## 3. What `LifecycleAuditable` records for these joins

**Nothing. It does not touch them.**

`System::LifecycleAuditable` is prepended onto `System::NodeInstance` and decorates AASM lifecycle
events only — `AUDITED_EVENTS` = start/stop/reboot/terminate plus the `mark_*` transitions —
emitting `system.node_instance.<event>`. It has no relationship to `TemplateModule`. The task names
it, so this is recorded plainly to stop the next reader looking there: **the join audit story is not
in this concern.**

What *is* missing is covered by F1 and F2 below.

---

## 4. Findings

Filed, not fixed. Each is a candidate task.

### F1 — `System::TemplateModule` is not auditable at all
`TemplateModule` does not `include Auditable`, and neither `System::BaseRecord` nor the
`System::Base` concern pulls it in. **No audit row is written for any join create, update or destroy,
on any surface.** Given that a join edit changes what every node on the template ships at next
apply, this is the single largest gap in the area. It is also the direct answer to "what is
missing": not a versioning refinement — the base record does not exist.

### F2 — the mutation event is emitted by one surface only, and only sometimes
`system.template_mutation` (a `Fleet::EventBroadcaster` event carrying the blast radius) is emitted
**only** from `SystemFleetTool#record_template_blast_radius`. `TemplateModulesController` — the REST
surface the operator UI uses — emits nothing. Two surfaces perform the same mutation and leave
different records. Additionally, even on the MCP path the recorder returns `nil` unless
`TemplateApprovalPolicy.for(template:).requires_approval?`, so a mutation on a template with **no
live nodes yet** is recorded nowhere — including the mutation that sets a template up before its
first node exists.

### F3 — destroying a join erases the provenance of every assignment derived from it
`source_template_module_id` is nullified on join destroy. The codebase already knows this (both
write surfaces document "prefer `enabled: false`"), but the guidance is advisory: `DELETE
/node_templates/:id/modules/:id` and `system_unassign_module_from_template` remain reachable and
destructive. Combined with D2, the resulting null is indistinguishable from a transitive pull.

### F4 — `LifecycleAuditable` has the accountless blind spot again
`record_lifecycle_audit!` opens with `return unless account.present?`. A NodeInstance that cannot
resolve an account is audited nowhere, silently — the same shape as finding 019fcfd2 (accountless
rows are skipped and the skip itself is unobservable), in a second concern. Noted here because this
audit walked the same machinery; it is not specific to template joins.

### F5 — the closure is never persisted, so drift is unobservable
Because no expansion result is stored (§1, D4), "what this node actually got" can only be compared
against "what this template expands to **today**". There is no way to ask what it expanded to at
build time. Any future drift detection built on re-expansion will silently compare against a moved
baseline.

---

## 5. Verdict on IMP-8e1cbf3a8dbd (asked separately: is it stale?)

**Partly stale, and the surviving half is not a defect as written. Recommend retiring it as
written.** It bundles three claims:

**(a) "Unguarded TemplateModule writers exist" — STALE.** `5bed3773d` closed the fifth and last one
(`PlanComposerService#attach_role_module_to_template!` in core). Every server-side writer now either
runs a composition verdict (`additions_verdict` for authoring paths: TemplateModulesController#create,
`system_assign_module_to_template`, `Gitops::ApplyService`, `ModuleSmokeVerifyExecutor`,
`PlanComposerService`; `set_verdict` for reproducing paths: `TemplateCloneService`,
`TemplateImporter`) or is the orphan reaper, which creates nothing. **Count of unguarded writers: 0,
not 1.**

**(b) "Conflicts only warn at apply and nothing blocks them" — TRUE BUT DELIBERATE, and documented
as such.** `TemplateExpansionService` states the decision and its reason in the class comment:
`apply!` sits on the provisioning critical path (`ProvisioningService`,
`FulfillmentAdvanceOrchestrator`) and on the autonomous drift-remediation path
(`Fleet::DecisionEngine`), so failing closed would turn **one poisoned template into a provisioning
outage for every node on it** — and the conflict is fatal at build time, not at assignment
materialisation, so refusing there "would remove the signal without preventing the damage". This is
a considered trade-off with a named failure mode, not an oversight. Implementing a block here would
re-create the self-detach outage shape on a self-hosted hub.

**(c) The residual, genuinely open question.** Claim (b) rests on "the conflict is fatal at BUILD
time". I looked for the guard that makes that true and **did not find a Ruby one** — build-time
fatality appears to mean a physical union-blob path collision during the actual build, not a code
refusal. If the real concern behind IMP-8e1cbf3a8dbd is *"the build does not in fact refuse a
conflicted composition"*, that is a different question, about the build pipeline rather than the
write paths, and it deserves a fresh narrow task rather than inheriting this one's stale framing.

**Not assessed:** the task also names `agent/internal/runtime/compose.go`, a **node-side** compose
refusal. On a self-hosted hub that is the self-detach outage shape, so it is an operator decision and
is deliberately left untouched here.

---

## 6. If a migration is later authorised

Out of scope for this audit (the task says "starting without a migration"), recorded only so the
next task starts from the constraint rather than rediscovering it. Nothing below is proposed;
these are the questions a schema change would have to answer:

1. What identifies a template *version* — a monotonic counter on the template, or a content hash of
   the ordered join set plus each module's resolved version?
2. Is the versioned artefact the **join set** (cheap, but D3/D4 mean it does not determine the
   closure) or the **expanded closure** (answers the real question, larger, and needs a write on
   every apply)?
3. What happens to `source_template_module_id`'s nullify-on-destroy (F3) — does a version record
   supersede it, or does the FK need to become non-destructive?

F1 is worth noting as a prerequisite: an audit row for join mutation is answerable **without** any
of the above, and without a migration on the template side.
