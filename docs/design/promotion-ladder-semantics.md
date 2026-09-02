# Promotion-ladder semantics: what `promotion_state` is for

**Status:** decided (option **(c)**, below) · **Task:** IMP-c7d618b0b72f · **Date:** 2026-09-02
**Scope:** `System::NodeModuleVersion#promotion_state` and its two consumers.
**Not decided here:** option **(a)** — making the ladder gate the fleet pointer. See
[What this does not decide](#what-this-does-not-decide).

`System::NodeModuleVersion` carries a five-rung ladder — `built → staging → blessed →
live → retired` (`server/app/models/system/node_module_version.rb:103-109`) — and
`System::NodeModule` carries a pointer, `current_version_id`, which is what a node
actually downloads (`NodeApi::ModulesController#download` reads
`@module.current_version&.artifact`).

Nothing in the codebase said what the ladder is *for*. Five separate tasks each
implied a different answer, none owned the question, and the two consumers of the
ladder were written against two different unstated assumptions. This note fixes one
answer.

---

## 1. What was measured

Read from the live control plane on 2026-09-01/02 through the authenticated MCP read
path (`system_list_modules`, `system_list_module_versions`). No privileged DB access,
no mutating verb.

| Module | Versions | `built` | `staging` | `blessed` | `live` |
|---|---|---|---|---|---|
| `powernode-hub-backend` | 64 | 57 | 0 | 0 | 7 |
| `powernode-hub-frontend` | 7 returned | 5 | 0 | 0 | 2 |
| `powernode-hub-worker` | 13 returned | 11 | 0 | 0 | 2 |
| `reverse-proxy-traefik` | 4 | 3 | 0 | 0 | 1 |
| `runtime-go` | 7 | 7 | 0 | 0 | 0 |
| `sdwan-overlay` | 2 | 2 | 0 | 0 | 0 |

**`staging` and `blessed` are 0 everywhere. `live` splits cleanly into two populations**,
and the discriminator is the timestamp column, because `promote_to!` is the only
application writer of `live_at` (`node_module_version.rb:124`; the only other writer in
the tree is the hand-run `db/seeds/smoke_test_k3s_rolling_upgrade.rb:81`):

* **`live` with `live_at: null` and `oci_digest: null`** — hub-frontend v20, hub-worker
  v14, traefik v13. **Provenance not established, and deliberately left unclaimed.**
  `System::AccountBootstrapService` is the obvious suspect and is *not* it: it
  `assign_attributes(promotion_state: "live")` (`account_bootstrap_service.rb:278`) but
  in the same call writes a **non-nil** `oci_digest` (`:277`), only ever touches
  `version_number: 1` (`:270`), and its six baseline modules (`system-base`,
  `security-hardening`, `chrony`, `apache`, `nginx`, `rpi4-firmware`) include none of the
  three above. No writer in §1.2 produces this shape. That is itself a finding — see §6.
  (`AccountBootstrapService` *is* production code rather than a seed:
  `after_create_commit :run_account_bootstrap` at
  `../../server/app/models/account.rb:268`, in the **core** tree, fires on every account
  creation — so it does write ladder-`live` rows, just not these ones.)
* **`live` with a real `live_at` stamp** — hub-frontend v26 (2026-08-31), hub-worker v23
  (2026-08-11), and five more on hub-backend. Only `promote_to!` stamps that column, and
  reaching `live` through it requires the row to have been `blessed` first. **So the
  ladder's upper rungs have been transited through the promote verbs at least twice in
  the last three weeks.** Whether `staging` was also transited depends on where the row
  entered the ladder — see §1.1, which bounds this inference rather than restating it.

### 1.1 This corrects the finding this task was opened on

The finding said the `staging` rung is *unreachable* and the sensor's scope empty *by
construction*, and that `live` is written only by bootstrap so `newer_blessed_version_for`
returns nil for everything. Both halves need correcting:

* `blessed` is **reachable and demonstrably reached** — just never *rested on*. A
  caller walking the ladder in one sitting occupies each rung for milliseconds and
  leaves nothing behind. The scope is empty because nobody pauses, not because nothing
  can enter.
* For `staging` the inference is weaker and must be stated as such. `promote_to!("live")`
  requires only that the row already be `blessed` (`node_module_version.rb:103-109`), and
  `PackageBuildWebhookService` *creates* `auto_generated` versions at `blessed` outright
  (§1.2), so a `live_at` stamp does not by itself prove `staging` was ever occupied. It
  does for the modules measured here — hub-frontend and hub-worker are top-level, not
  `auto_generated` — but not in general.
* "Walked by hand" means "walked through the two promote verbs", **not** "walked by a
  human". One of those verbs is the MCP `system_promote_module_version`, which an
  autonomous agent can call. Nothing in the code binds any rung to a person; §3's
  ownership column is a convention this note establishes, not an invariant the code
  enforces.
* There are at least **two** `live` writers, not one, and telling them apart matters
  because they mean opposite things (§1, above).

### 1.2 The complete writer set

Verified by an exhaustive sweep of `server/`, `worker/`, all four `extensions/*` trees
(including `extensions/private`, which the shell's `grep` wrapper hides — `command grep`
was used), `scripts/`, and all 81 rake tasks. `worker/` and the marketing, supply-chain
and private extensions contain **zero** references to the column.

| Writer | file:line | Produces | Trigger |
|---|---|---|---|
| `NodeModuleVersion#promote_to!` | `node_module_version.rb:111-131` | any rung, one hop | the 3 call sites below |
| ↳ operator REST | `api/v1/system/node_module_versions_controller.rb:26` | any | `POST /node_module_versions/:id/promote`, from the module-versions panel |
| ↳ MCP verb | `ai/tools/system_fleet_tool.rb:3738` | any | `system_promote_module_version` |
| ↳ `ModulePromotionService` | `fleet/module_promotion_service.rb:31` | **`blessed` only** | `DecisionEngine#apply_module_promotion` (`decision_engine.rb:1465`), the one automated caller |
| `AccountBootstrapService` | `account_bootstrap_service.rb:278` | **`live`** | every `Account` creation |
| `PackageBuildWebhookService#create_version` | `package_build_webhook_service.rb:128` | `blessed` if `auto_generated`, else `built` | CI callback `POST /webhooks/package_build` |
| `ManifestImportService` | `manifest_import_service.rb:1070` | `built` | manifest import |
| `AgentModuleCommitService` | `agent_module_commit_service.rb:47` | `built` | on-node agent commit |
| column default | `20250101000009_system_baseline.rb:980` | `built` | `ModulePublicationProcessor`, `ModuleVersionService`, `ModulePublicationsController`, `NativeModuleBuildOrchestrator` |
| `db/seeds/example_custom_module.rb:84` | `update!(promotion_state: target_state)` over `%w[staging blessed live]` | all three | hand-run example seed, no orchestrator invokes it |
| `db/seeds/example_rolling_upgrade.rb:57,61` | `live`, `blessed` | both | hand-run example seed |
| `db/seeds/smoke_test_k3s_rolling_upgrade.rb:80-81` | `live` **and `live_at` directly** | `live` | hand-run smoke test |

The three seed rows are in the swept tree and are listed because "no automated writer"
is a claim about the pipeline, not about what exists on disk. `example_custom_module.rb`
is also the known blind spot of the guard that enforces the conclusion below: it writes a
*variable*, so no literal-shape regex can see it
(`spec/docs/module_promotion_sensor_docs_accuracy_spec.rb`, "is written by no literal
automated writer").

**On call-site counts:** this table lists **three** `promote_to!` call sites; `FLEET_SENSORS.md`
says **four**, and the guard spec asserts a four-**file** caller set. Both are right about
different things — the guard counts `ModulePromotionService` as its own file, and
`FLEET_SENSORS.md` counts the frontend versions panel separately from the endpoint it
calls. Three distinct code paths, four files.

Two things fall out of that table:

1. **No automated path ever writes `staging`.** The only automated `promote_to!` caller
   targets `blessed` and *requires* the source row already be `staging`
   (`decision_engine.rb:1459-1463`) — it consumes the sensor's output, it cannot produce
   its input.
2. **`auto_generated` modules skip the ladder outright**, minted at `blessed` by a
   `create!` rather than a transition (so they carry no `blessed_at`).
   `auto_generated` is set only by `PackageModuleMaterializer#upsert_module_for_package`
   (`package_module_materializer.rb:302`: `auto_generated: !top_level`), i.e. transitive
   package dependencies nobody explicitly chose.

### 1.3 The pointer does not wait for the ladder

In all six modules sampled, `current_version_number` equals the highest version number
that exists. Publish moves the pointer to whatever it just built —
`PackageBuildWebhookService` does it inline (`package_build_webhook_service.rb:140`), and
`ModulePublicationProcessor` defaults `auto_promote?` to true. The ladder gates nothing
today, and has never gated anything.

---

## 2. The options

**(a) The ladder GATES the pointer.** Matches the M1 intent recorded at
`node_module_version.rb:86-88` ("Full AASM with PromotionCriteria gates lands in M1").
Publish would stop moving `current_version_id` until a version is `blessed`.

**(b) The ladder is OBSERVATIONAL only** — a label with no authority. Re-scope both
consumers to stop asking it questions.

**(c) The middle.** Pre-pointer rungs (`built`/`staging`/`blessed`) stay
human-meaningful ELIGIBILITY labels answering *"may this be rolled out?"*.
`live`/`retired` become HISTORICAL stamps — a record that a version was once promoted —
and the question *"what does the fleet serve?"* is answered by `current_version_id`
alone.

## 3. The decision: (c)

**Option (a) is out of scope for this task** and is not implemented here — it changes how
every deployment ships and needs operator sign-off. It is also the option this data
argues hardest against right now: `PromotionCriteria` has never executed against
production data (§4), so wiring it as a *gate* would make its first live evaluation the
thing standing between a build and the fleet.

**Option (b) is rejected**, and this is the substantive call. It reads as the tidy answer
— the pointer is the actuator, so make the ladder inert prose — but one consumer needs a
*decision-bearing* answer, not an observation. The CVE rolling-upgrade lane
(`cve_remediation_orchestration_executor.rb:253`) asks "is there a fix I may ship
fleet-wide, unattended?" That is an eligibility judgement. Under (b) it would have to
either roll out any `built` row — shipping unreviewed builds fleet-wide on a CVE timer —
or invent a second, parallel eligibility concept beside the one already in the schema.

That said, the dilemma is not as tight as it looks, and the honest version is worth
recording: the lane already has a third branch — `skip_entry`
(`cve_remediation_orchestration_executor.rb:302-334`) returns
`candidate_version_not_promoted` with the legal next rung, i.e. it defers to a human
rather than shipping anything. That behaviour is coherent under (b) too, since naming a
state in an operator message does not require the state to carry authority. So (b) is
survivable, not absurd. What decides it is §4.1's prohibition: under (c) `staging`
*asserts* a deliberate nomination, which makes "no pipeline may write it" a real
invariant with a real guard behind it
(`spec/docs/module_promotion_sensor_docs_accuracy_spec.rb`, the no-literal-automated-writer
oracle). Under (b) nobody would care what writes an inert label, and that guard would have
nothing to protect. **That invariant is the substantive difference between (b) and (c),
and it is the reason for the choice** — not the code change in §3.1, which any of the
three options would want.

Note what (b) would *not* fix. The operator's earlier framing — that the CVE lane's
`blessed`/`live` filter is "wrong" and the ladder is "bypassed where risk is taken and
binding where risk is reduced" — was **retracted**, and this note does not build on it.
Restricting unattended rollout to criteria-blessed or human-blessed material is
defensible conservatism; "built but current" is the risky state. **The filter is not the
defect. The defect is that no pipeline produces `blessed` material** for an
operator-authored module, so a conservative filter degenerates to "never".

**(c) is adopted** because it is the only option under which each rung has exactly one
meaning and one owner:

| Rung | Means | Owned by |
|---|---|---|
| `built` | exists, unreviewed | the build pipeline |
| `staging` | nominated for evidence-based blessing | a human (`promote_to!`) |
| `blessed` | fit for unattended rollout | `PromotionCriteria`, or a human |
| `live` | *was* promoted, once, at `live_at` | history — **not** a fitness claim |
| `retired` | withdrawn | a human |

And it leaves the actuator untouched: `NodeModule#promote_to_version!`
(`node_module.rb:556-576`) stays the sole writer of `current_version_id` and the only
thing that arms a restart. `FLEET_SENSORS.md`'s `module_promotion_backlog_sensor` block
already states this invariant from the other side — *"It does not read `promotion_state`,
and must not"* — and (c) is what makes that consistent with the rest of the system rather
than a local exception.

### 3.1 What (c) changes

One consumer changes. It is worth saying plainly that this fix is **option-neutral** —
(a), (b) and (c) would all want it, because "a fix must be newer than what is served" does
not depend on what the ladder means. It is listed here because it is the code this task
touched, not as evidence for (c); the evidence for (c) is the invariant in §3 above. **`#newer_blessed_version_for`
(`cve_remediation_orchestration_executor.rb:423`) is now bounded to versions created
after the served one.** Under (c), `live` is a historical stamp, so an *older* `live` row
is not a fix — it is a downgrade. The unbounded query excluded only the served row
(`where.not(id: current_version_id)`), so every stale `live` row fell through it. Against
the data in §1 that was not theoretical: it would have offered

* `powernode-hub-frontend` v20 as the remediation for v26 — `live`, `oci_digest: nil`,
  i.e. a bootstrap placeholder with **no mountable artifact at all**;
* `reverse-proxy-traefik` v13 as the remediation for v16 — same shape;
* `powernode-hub-backend` v79 as the remediation for v87 — eight versions back.

This is the second half of a bound the sibling `#unpromoted_candidate_for` already
carries; its comment recorded that it "left the blessed/live filter untouched", and that
untouched half is what §1's data turned into a live defect. **The blessed/live filter
itself is unchanged**, per the retraction above.

### 3.2 What (c) does not change

* Publish still moves the pointer. No deployment flow changes.
* `PromotionCriteria` thresholds, the sensor's scope, and the `promote_to!` transition
  table are untouched.
* `AccountBootstrapService`'s `live` v1 rows are left in place. Under (c) they are
  wrong-by-meaning — they assert a promotion that never happened — but rewriting rows on
  the live control plane is a data migration, not a decision, and it is filed rather
  than done (§6).

---

## 4. The promotion sensor: kept, and why

`ModulePromotionSensor` scopes on `promotion_state == "staging"`
(`module_promotion_sensor.rb:40`). The brief for this task said the sensor must not be
left scoped to a set nothing populates — *real input, or delete it*.

**It has real input**, and §1's `live_at` stamps are the evidence: the two operator verbs
put rows at `staging`, and they have been used. What the rung lacks is a *reason to rest
on it*, which is a consequence of the ladder never having had a stated meaning — the gap
this note closes. Under (c), `staging` now means something an operator would deliberately
use: *"I nominate this build; bless it when the fleet gives you evidence."*

**Deleting it forecloses the only designed automated path to `blessed`.** Be precise
about the strength of that, because the obvious overstatement is false: the two promote
verbs can write `blessed` directly, so this sensor is *not* the only way a version
becomes blessed. What it is, is the only **automated, evidence-gated** producer — the
sensor → `DecisionEngine#apply_module_promotion` →
`ModulePromotionService.promote!(target_state: "blessed")` path, where
`PromotionCriteria` is the thing consulted. The sole other automated producer,
`PackageBuildWebhookService:128`, fires only for `auto_generated` transitive
dependencies. Delete this sensor and `blessed` is reachable by hand alone, which makes
the CVE lane permanently manual rather than merely unused.

**Honesty about "real input":** what §1's `live_at` stamps demonstrate is that the rung is
*transited*, not that it is *rested on*, and a scope occupied for milliseconds is not
input in the sense the brief meant. The defensible claim is narrower than "it has real
input": the rung has real, exercised **producers**, deleting the sensor forecloses the
automated lane permanently, and §4.1 is the gate on whether that lane ever becomes real.
If the shadow-mode pass shows `PromotionCriteria` cannot pass on any realistic fleet, the
right follow-up is to fix the criteria or delete the lane — not to leave this note's
answer standing unexamined.

### 4.1 Precondition before the lane is trusted: a shadow-mode pass

`PromotionCriteria.evaluate` has never run against production data. Its first real
execution must not be an execution that decides something. Before any change that makes
the lane load-bearing:

1. Run `PromotionCriteria.evaluate` over real versions and **record** `{eligible:,
   reason:, running_count:, required_count:, dwell_time_minutes:}` without emitting a
   signal or promoting anything.
2. Confirm the thresholds are satisfiable on this fleet at all. They probably are not
   today: `REQUIRED_COUNT` defaults to 3 (`promotion_criteria.rb:28`) against a fleet of
   1-2 instances, and the dwell anchor is `min(last_heartbeat_at)`
   (`promotion_criteria.rb:56`), so clearing the 30-minute default needs the stalest
   qualifying instance to have been quiet for 30 minutes *while still* `status: "running"`
   — ten times the 3-minute age at which `InstanceStatusSensor` already raises
   `system.instance_silent`. Both are overridable per-module → per-account → per-site
   (`promotion_criteria.rb:31-32`).
3. Only then consider the lane trustworthy.

**Explicitly forbidden**, and forbidden by this decision rather than merely by the task
brief: making the build pipeline write `"staging"` so the sensor has input. This is the
one prohibition that is genuinely specific to (c), and it already has a guard behind it —
`spec/docs/module_promotion_sensor_docs_accuracy_spec.rb`, the `"is written by no literal
automated writer"` example, which scans `server/app`, `server/lib` and `server/db/seeds`
for literal staging-write shapes and pins the `promote_to!` caller set. Its documented
blind spot is a write whose value is a variable (§1.2). That
manufactures traffic for a lane instead of deciding what the lane is for, and under (c)
it is also semantically false — `staging` asserts a human nomination, and a build is not
one.

---

## 5. Where this note is referenced from

`module_promotion_sensor.rb` · `node_module_version.rb` (the M1-intent comment) ·
`cve_remediation_orchestration_executor.rb#newer_blessed_version_for` ·
`ai/tools/system_fleet_tool.rb#promote_module_version` (which recorded these as "open
lifecycle-gating questions filed separately") · `docs/FLEET_SENSORS.md`.

Pinned by `spec/services/system/fleet/promotion_ladder_decision_spec.rb`, whose fixtures
are built through `PackageBuildWebhookService` — the real CI-callback path — rather than
by stamping `promotion_state: "blessed"` by hand. Every pre-existing fixture for
`#newer_blessed_version_for` stamps it
(`cve_remediation_orchestration_executor_spec.rb:90, 255, 275, 301, 325`), which is why
none of them could see that the input set was unreachable.

## 6. What this does not decide

* **Option (a).** Whether publish should stop moving `current_version_id` until a version
  is `blessed`. Needs operator sign-off; the argument for it is `node_module_version.rb:86-88`,
  the argument against is §4.1.
* **The bootstrap `live` rows.** `AccountBootstrapService:278` writes a state that,
  under (c), it has no standing to write — `built` is the honest value. Changing it
  changes what a fresh account looks like, and the existing rows need a backfill. Filed,
  not done.
* **Artifact usability in the rollout gate.** `#newer_blessed_version_for` still does not
  check that its target is mountable. The recency bound in §3.1 removes every
  artifact-less row observed in §1 (all are bootstrap v1s, older than current), so the
  measured defect is closed — but the *class* is not: a `blessed` row with
  `oci_digest: nil` created after the current version would still be returned.
  `NodeModuleVersion#rollback_usable?` is the admission test the rollback path already
  uses, and `module_promotion_backlog_sensor` uses it for exactly this purpose. Filed,
  not done — it is a different premise from this decision.
* **Who wrote the null-digest `live` rows.** hub-frontend v20, hub-worker v14 and
  traefik v13 are `live` with no `live_at` and no `oci_digest`, at version numbers no
  enumerated writer can produce (`set_version_number` derives `max + 1`,
  `node_module_version.rb:190-195`, and `AccountBootstrapService` only touches v1). Either
  a writer is missing from §1.2 or these rows predate the current code. Worth resolving
  before anyone relies on `promotion_state` as an audit trail — but it does not change
  this decision, and §3.1's bound is correct regardless of provenance.
* **Whether `live`/`retired` should be derived columns or dropped.** (c) says they *mean*
  history; it does not migrate them to be computed from `current_version_id`.
