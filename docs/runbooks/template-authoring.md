# Template Authoring Runbook

> Status: active

Authoring a `NodeTemplate` — the reusable module bundle every `Node` binds to.
Covers creating a template over REST and MCP, attaching modules through the
`TemplateModule` join, the **composition conflict model** (which surfaces refuse
a conflicting write and which only report it), import/clone/export, and applying
a template to a node.

**Audience:** template designers composing fleet-wide module sets, SREs
preparing a node type before provisioning, agents driving the same flow over MCP.

**Prerequisites:** a `NodePlatform` on the account (a template cannot exist
without one), and the modules you intend to compose already registered as
`NodeModule` rows — see [module-authoring.md](./module-authoring.md).

## Quick reference

| Phase | What happens | MCP entry point | REST |
|---|---|---|---|
| 0. Discover | Check whether a template already covers this workload | `system_discover_templates` | — |
| 1. Preview | Resolve the closure + conflicts for a module set; persists nothing | `system_compose_preview_template` | `POST /node_templates/compose_preview` |
| 2. Create | The `NodeTemplate` row (binds to a `NodePlatform`) | `system_create_template` | `POST /node_templates` |
| 3. Assign | One `TemplateModule` join per module — **conflict-checked** | `system_assign_module_to_template` | `POST /node_templates/:id/modules` |
| 4. Tune | Priority / enabled / config / recommends on an existing join | `system_update_template_module` | `PATCH /node_templates/:id/modules/:module_id` |
| 5. Apply | Materialize `NodeModuleAssignment` rows on a node | none — REST only | `POST /nodes/:id/apply_template` |

## Concept reference

| Concept | What it is | Backing model |
|---|---|---|
| **NodeTemplate** | A named, account-scoped module bundle. `belongs_to :node_platform` (NOT NULL) and `has_many :nodes` with `dependent: :restrict_with_error` — a template in use cannot be deleted. | `System::NodeTemplate` |
| **TemplateModule** | The join row binding one `NodeModule` to one `NodeTemplate`. Carries `priority`, `enabled`, `config`, `recommends_override`. Unique on `(node_template_id, node_module_id)`. | `System::TemplateModule` |
| **NodePlatform** | The OS/arch target the template builds for. `has_many :node_templates, dependent: :restrict_with_error`. | `System::NodePlatform` |
| **Closure** | The modules the template actually ships: the enabled joins PLUS everything their `requires`/`recommends` edges pull in transitively. | `System::TemplateExpansionService` |
| **NodeModuleAssignment** | The per-`Node` materialization of the closure, written by apply. Carries `source_template_module_id` back to the join it came from. | `System::NodeModuleAssignment` |
| **Composition conflict** | A collision detected across the closure. Three kinds, two severities — see [the conflict model](#the-composition-conflict-model). | `System::TemplateComposerService#detect_conflicts` |

### How the pieces relate

```
NodePlatform ──1:N──> NodeTemplate ──1:N──> TemplateModule ──N:1──> NodeModule
                           │                      │
                           │                      └── priority / enabled / config / recommends_override
                           │
                           └──1:N──> Node ──1:N──> NodeModuleAssignment
                                                        └── source_template_module_id
```

Two facts that catch people out:

- **The join's `priority` does not reach the node.** `TemplateApplyService`
  writes `priority: mod.priority.to_i` from the **NodeModule's own** `priority`
  column ([`template_apply_service.rb:65-71`](../../server/app/services/system/template_apply_service.rb)).
  `TemplateModule#priority` is used only for display/serialization order
  (`system_get_template`, the export bundle, the modules index). To change
  effective ordering on a node, edit the module's priority or the resulting
  assignment — not the join.
- **`enabled: false` on a join is the correct removal, not `DELETE`.**
  Destroying the join nullifies `source_template_module_id` on every derived
  `NodeModuleAssignment` and orphans them permanently. A disabled join keeps the
  row and the back-reference ([`template_modules_controller.rb:96-102`](../../server/app/controllers/api/v1/system/template_modules_controller.rb)).

## Phase 0 — Does a template already exist for this? ✅

Reuse-first. Search by WORKLOAD, not by guessed name — `system_discover_templates`
ranks existing templates by semantic similarity, and a template's embedding folds
in its assigned modules' names and descriptions, so the match reflects what the
template actually composes rather than what it happens to be called:

```
system_discover_templates intent="public web serving stack"
```

Read the `coverage` field before trusting an empty result — same semantics as
`system_discover_modules` (see [module-authoring.md Phase 0](./module-authoring.md#phase-0--should-this-be-a-module-at-all)).
Ranking is vector-only with no keyword fallback, so an empty result on an
unembedded catalog means **not indexed**, not "nothing exists".

`system_list_templates` is the literal-substring counterpart — it filters on
name OR description with ILIKE, nothing more.

If a near-match exists, prefer **clone** over a fresh author (see
[Import, clone, export](#import-clone-export)).

## Phase 1 — Preview the composition ✅

Do this **before** creating anything. The preview is read-only, persists
nothing, and is the same analysis the assignment path will run — so a conflict
it shows you is a conflict that will be refused later.

```javascript
platform.system_compose_preview_template({
  module_ids: ["<uuid>", "<uuid>", "<uuid>"]   // your explicit picks
})
```

Response keys (identical on both surfaces —
[`template_composition_analysis.rb:64-77`](../../server/app/services/system/template_composition_analysis.rb)):

| Key | Contents |
|---|---|
| `modules` | Serialized closure — your explicit picks **plus** transitive `requires`/`recommends`, each flagged whether it was auto-resolved |
| `conflicts` | Every detected conflict, each with a `kind`, a `severity`, a `detail`, and the module ids involved |
| `footprint` | `{ module_count, estimated_package_count, architectures }` |
| `dependency_graph` | Nodes + edges (`parent_module` hierarchy and `ModuleDependency` edges where both endpoints are in the closure) |
| `warnings` / `errors` | Resolver messages (unsatisfied capabilities, constraint drift) |

The REST equivalent is `POST /api/v1/system/node_templates/compose_preview` with
`{ "module_ids": [...] }`. An empty `module_ids` is a 422; a list that matches no
module in the account is a **404**, not an empty composition.

The operator UI for this is the Visual Template Composer at
`/app/system/templates/compose` ([`register.ts:90`](../../frontend/src/register.ts)).

## Phase 2 — Create the template ✅

```javascript
platform.system_create_template({
  name: "web-edge-tokyo",              // required, unique within the account
  node_platform_id: "<platform-uuid>", // REQUIRED — the column is NOT NULL
  description: "nginx + TLS edge for the Tokyo region",
  enabled: true,
  public: false,
  admin_user: "opsadmin",
  config: { boot_mode: "uefi_disk" }
})
```

Omitting `node_platform_id` fails with an explicit parameter-named error rather
than the model's ambiguous "Node platform must exist"
([`system_fleet_tool.rb:1616-1619`](../../server/app/services/ai/tools/system_fleet_tool.rb)).

**`config` keys that provisioning actually reads** (everything else is inert
metadata until something consumes it):

| Key | Effect |
|---|---|
| `boot_mode` | Template-level default boot mode, threaded through provisioning and federation spawn |
| `init_script` | Default init script for instances built from this template |
| `sdwan_network_id` | Default SDWAN network attachment |
| `legacy_rsa_keys` | `true` makes the node generate RSA rather than the default host keys |

`config` **replaces** the stored hash on update — it does not deep-merge. Read
the current value with `system_get_template` first if you mean to add one key.

REST equivalent: `POST /api/v1/system/node_templates` with the fields nested
under a `node_template` key (`params.require(:node_template)`).

## Phase 3 — Assign modules ✅

```javascript
platform.system_assign_module_to_template({
  template_id: "<template-uuid>",
  module_id:   "<module-uuid>",
  priority: 10,                       // display order only — see above
  enabled: true,                      // default true
  config: { "server_name": "edge.example.com" },
  recommends_override: { excluded: ["nginx-doc"] }
})
```

REST: `POST /api/v1/system/node_templates/:node_template_id/modules` with
`{ "node_module_id": "...", "priority": …, "enabled": …, "config": {…}, "recommends_override": {…} }`.

**`config`** is a per-template overlay deep-merged over the module's own config
at expansion time (`TemplateModule#merged_config`).

**`recommends_override`** shapes which `recommends` edges the closure follows for
this join, and takes one of two forms
([`template_module.rb:42-63`](../../server/app/models/system/template_module.rb)):

```javascript
{ replace:  ["pkg-a", "pkg-b"] }              // exact list; module defaults ignored
{ included: ["pkg-c"], excluded: ["pkg-d"] }  // adjust the module's defaults
```

`replace` wins outright if present. Otherwise `excluded` is subtracted from the
module's `PackageModuleLink.recommends_chosen` defaults, then `included` is
added. `requires` edges are followed unconditionally and cannot be overridden
here.

## The composition conflict model

This is the part worth reading twice: **the same conflict produces different
behaviour depending on which surface writes it.**

### The three conflict kinds

From [`template_composer_service.rb:34-124`](../../server/app/services/system/template_composer_service.rb):

| Kind | Severity | Meaning |
|---|---|---|
| `module_dependency_conflict` | `error` | Two modules in the closure where one declares a `Conflicts:` relation against the other (apt/rpm semantics, carried on `ModuleDependency`) |
| `instance_variety_collision` | `error` | Two or more `instance`-variety modules land in the same category. Only one instance module may ship per category |
| `protected_spec_overlap` | `warning` | One module's `file_spec` covers paths another has claimed via `protected_spec`. The build pipeline auto-resolves this by excluding the paths from the other module's blob — you probably still want to know |

Severity is what partitions blocking from advisory, and it **fails closed**: a
conflict kind added later without a severity blocks the write rather than
sliding through ([`template_composition_analysis.rb:29-32`](../../server/app/services/system/template_composition_analysis.rb)).

### Assign and enable: REFUSED

`system_assign_module_to_template`, `system_update_template_module`, and both
their REST counterparts run `assignment_verdict` before the write. An
error-severity conflict is refused (422 on REST, an error result over MCP) and
the message **names the modules involved**:

```
Module assignment refused: it would introduce 1 composition conflict —
instance_variety_collision — Only one instance-variety module per category
is allowed (modules: hostname-override, hostname-tokyo)
```

Warning-severity conflicts do **not** block. They ride the success payload under
a `warnings` key, which is **absent entirely when empty** — a clean assignment's
response shape is unchanged.

Three properties of this guard that determine what you can and cannot do:

1. **It is a DELTA, not a whole-set check.** The verdict compares the conflicts
   the template's current enabled closure already has against the conflicts it
   would have after your write, and only charges you for what is *new*
   ([`template_composition_analysis.rb:96-103`](../../server/app/services/system/template_composition_analysis.rb)).
   This is deliberate: a template that already composes badly has to stay
   editable, or detaching everything would be the only way out. It also means a
   pre-existing conflict is treated as acceptable baseline forever after.
2. **`enabled: false` skips the check entirely.** A disabled join is never
   expanded onto an instance, so it can collide with nothing. This is a
   legitimate way to stage an assignment — but understand that **enabling it
   later is what runs the check**, and that is where the refusal will land.
3. **Only the disabled → enabled transition is checked on update.** Disabling a
   join, or editing `priority`/`config`/`recommends_override` at an unchanged
   `enabled` flag, changes no membership and so runs no check
   ([`template_modules_controller.rb:119-124`](../../server/app/controllers/api/v1/system/template_modules_controller.rb)).

Two non-operator writers share this refusing behaviour, because they are
*authoring* rather than reproducing: `System::Gitops::ApplyService` raises
`CompositionConflictError` on the one `fleet.yaml` line that breaks composition,
leaving the rest of the repository applied
([`gitops/apply_service.rb:192-195`](../../server/app/services/system/gitops/apply_service.rb));
`ModuleSmokeVerifyExecutor` judges its base-os + target pairing as a single
addition (neither is in the other's baseline) and raises rather than compose a
broken smoke pairing
([`module_smoke_verify_executor.rb:191-196`](../../server/app/services/system/ai/skills/module_smoke_verify_executor.rb)).

### Import and clone: REPORTED, not refused

**`warnings` means something different here, and the difference matters.**

On assign/enable, `warnings` carries *soft* findings — `protected_spec` overlaps
that did not block. On import and clone, `warnings` carries **error-severity
conflicts that were reported rather than blocked**. Same key, opposite severity.
An operator who reads a clone's `warnings` as "just advisory noise" will ship a
template that cannot build.

Both surfaces judge the module set **whole**, with no baseline to diff against —
a write that materializes an entire template in one shot has no earlier state to
charge a conflict to, so everything the resulting closure contains belongs to
that write (`set_verdict`).

- **`TemplateImporter`** puts the verdict in `Result#composition_report`
  ([`template_importer.rb`](../../server/app/services/system/template_importer.rb)),
  and the controller forwards it under `composition_report` on the 201
  ([`node_templates_controller.rb`](../../server/app/controllers/api/v1/system/node_templates_controller.rb)).
  It does not refuse: an import reproduces a template authored elsewhere,
  blocking would make an export/import round trip lossy, and the bundle format
  has no way to say "this collision is deliberate".
- **`TemplateCloneService`** exposes `#composition_report` (the severity-typed
  entries) and `#composition_message` (the prebuilt human summary, which is also
  what gets logged). The clone controller returns the report under
  `composition_report` ([`node_templates_controller.rb`](../../server/app/controllers/api/v1/system/node_templates_controller.rb)).
  Forking a broken template is exactly how an operator gets a copy to repair, so
  refusing would remove the repair path.

**`composition_report`, not `warnings`** (IMP-493db0e5c398). These two surfaces
report a **blocking** verdict they deliberately do not enforce, while the
assignment write paths use `warnings` for conflicts that are genuinely advisory.
One key meaning both left a caller unable to tell which it held. Every entry in
`composition_report` now states its own `severity` (`"error"` | `"warning"`), so
one classifier works on any surface's payload:

```ruby
blocking = payload["composition_report"].select { |e| e["severity"] == "error" }
```

Severity is **stamped from the partition**, not copied from what the conflict
kind declared — a kind added later without a severity is treated as blocking
(the same fail-closed rule as `TemplateCompositionAnalysis#warning?`) and says
so, rather than reporting a nil a caller cannot branch on.

Both analyses run **after** the commit and cannot fail the write — an analysis
that raises reports itself as a `composition_analysis_failed` entry at **error**
severity (fail closed: an analysis that could not run has cleared nothing)
rather than 500-ing an otherwise-good import.

Because clone and import bypass the delta guard, whatever they land becomes the
**baseline every later assignment is obliged to treat as acceptable**. If you
see conflicts in a clone or import response, fix them before you build on the
result.

### Apply: WARNED

Apply warns rather than blocking, and the warning is not surfaced by the
automated callers — see Phase 5 below.

## Phase 4 — Tune or remove a join ✅

```javascript
// Non-destructive removal — the row and its back-references survive
platform.system_update_template_module({
  template_id: "<template-uuid>",
  module_id:   "<module-uuid>",   // the join is addressed by (template, module)
  enabled: false
})
```

The join is addressed by `(template_id, module_id)` on every action — the REST
member `:id` is likewise the **NodeModule** id, not the join row's own id
([`routes.rb:225-236`](../../server/config/routes.rb)).

`config` and `recommends_override` **replace** the stored hash; they do not
merge. Omitted fields are untouched. An update naming none of
`priority`/`enabled`/`config`/`recommends_override` is a 422 ("nothing to
update") rather than a silent no-op.

`system_unassign_module_from_template` (REST `DELETE`) destroys the join. Reach
for it only when you genuinely want the derived assignments orphaned.

## Phase 5 — Apply the template to a node ✅

Apply is **REST-only** — there is no MCP action for it:

```bash
POST /api/v1/system/nodes/<node-id>/apply_template
{ "dry_run": true, "purge_stale": false }
```

Permission: `system.modules.update`
([`nodes_controller.rb:63-64`](../../server/app/controllers/api/v1/system/nodes_controller.rb)).

Response: `dry_run`, `created_count`, `skipped_count`, `purged_count`,
`warnings`, `errors`, `created` (each `{ node_module_id, source_template_module_id }`),
and `purged_module_ids`.

Semantics ([`template_apply_service.rb`](../../server/app/services/system/template_apply_service.rb)):

- **Idempotent.** Re-running adds assignments for modules that entered the
  closure since last time and no-ops for those already assigned.
- **Existing assignments are never modified.** Operator-tuned
  priority/config/enabled on prior assignments survive.
- **`purge_stale: false` by default.** Opting in removes template-derived
  assignments whose modules left the closure — and only those with a non-NULL
  `source_template_module_id`. Hand-authored assignments stay regardless.
- **`dry_run: true`** computes the plan without persisting and appends
  `"dry_run: no changes persisted"` to `warnings`.

**On conflict, apply WARNS — it does not block.** `TemplateExpansionService`
runs the whole-set conflict pass (the half the per-write deltas cannot hold) and
puts error-severity conflicts into `warnings` as
`"composition conflict: <kind> — <detail> (modules: …)"`. It warns rather than
refuses because apply sits on the provisioning critical path
(`ProvisioningService`, `FulfillmentAdvanceOrchestrator`) and on the autonomous
drift-remediation path (`Fleet::DecisionEngine`) — failing closed would turn one
poisoned template into a provisioning outage for every node on it, while the
conflict is fatal at BUILD time, not at assignment materialization.

> **Know this before you rely on the warning:** none of the automated callers
> surface it. `ProvisioningService#apply_node_template` logs only on
> `result.ok? == false` ([`provisioning_service.rb:568-575`](../../server/app/services/system/provisioning_service.rb));
> `Fleet::DecisionEngine#apply_template_closure_drift` reads `ok?`, `errors` and
> `created` and returns none of `warnings`
> ([`decision_engine.rb:1010-1028`](../../server/app/services/system/fleet/decision_engine.rb));
> `FulfillmentAdvanceOrchestrator` reads `ok?` and `created` only
> ([`fulfillment_advance_orchestrator.rb:334-341`, `:427`](../../server/app/services/system/fulfillment_advance_orchestrator.rb)).
> The **only** place the apply warning reaches a human today is the REST
> response above. Run an explicit `dry_run: true` apply after any clone, import,
> or GitOps change to a template you care about — that is the check the
> automated paths will not do for you.

## Import, clone, export

**Export** (`GET /api/v1/system/node_templates/:id/export`, permission
`system.templates.read`) streams a JSON attachment. Bundle shape
([`template_exporter.rb`](../../server/app/services/system/template_exporter.rb)):

```json
{
  "format_version": "1.0",
  "kind": "system.node_template",
  "exported_at": "…",
  "template": { "id", "name", "description", "enabled", "public", "admin_user", "config" },
  "platform": { "id", "name", "architecture_name" },
  "modules": [ { "module_id", "module_name", "module_variety",
                 "module_platform_name", "priority", "enabled", "config" } ]
}
```

Modules are ordered by `priority: :desc`. IDs are same-instance re-import hints
only — **names + variety are the canonical cross-instance keys**.

**Import** (`POST /api/v1/system/node_templates/import`, permission
`system.templates.create`) takes `{ bundle: <the JSON, as an object or a
string>, name: "<optional override>" }`.

- Refuses a `format_version` other than `"1.0"` or a `kind` other than
  `system.node_template`.
- Resolves the platform **by name** in the target account — a missing platform
  is a refusal.
- Resolves modules by `(name, variety)`. Any missing module refuses the whole
  import with a `details.missing_modules` list so you can author them first.
- `recommends_override` is **not** carried by the bundle — the exporter does not
  emit it and the importer does not set it. Re-apply overrides by hand after an
  import.

**Clone** (`POST /api/v1/system/node_templates/:id/clone`, permission
`system.templates.create`) deep-copies the template and every join *including*
`recommends_override`, defaulting the new name to `"<source>-copy"`. The unique
index is scoped to `account_id`, so a same-account clone needs a distinct name;
a collision returns 422.

Both report error-severity conflicts rather than refusing — see
[Import and clone: REPORTED, not refused](#import-and-clone-reported-not-refused).

## Permissions

Registered by the extension engine, granted to `admin`
([`engine.rb:305`](../../server/lib/powernode_system/engine.rb) —
`resource :templates, actions: %i[read create update delete], grant: { admin: :all }`).

| Surface | Permission |
|---|---|
| REST index / show / export | `system.templates.read` |
| REST create / import / clone | `system.templates.create` |
| REST update, **and `compose_preview`** | `system.templates.update` |
| REST destroy | `system.templates.delete` |
| REST modules index | `system.templates.read` |
| REST modules create / update / destroy | `system.templates.update` |
| REST `nodes/:id/apply_template` | `system.modules.update` |
| `system_list_templates`, `system_get_template`, `system_discover_templates` | `system.nodes.read` |
| `system_compose_preview_template` | `system.templates.read` |
| `system_create_template` | `system.templates.create` |
| `system_update_template` | `system.nodes.update` |
| `system_delete_template` | `system.nodes.delete` |
| `system_assign_module_to_template`, `system_update_template_module`, `system_unassign_module_from_template` | `system.modules.update` |

Three mappings are worth noticing because they are not what the action name
suggests: the REST `compose_preview` is gated on `templates.**update**` while
the identical MCP action takes `templates.read` (the REST one was grouped with
the composer's save flow); and `system_update_template` / `system_delete_template`
take `system.nodes.*`, not `system.templates.*`
([`system_fleet_tool.rb:45-53, 75-77`](../../server/app/services/ai/tools/system_fleet_tool.rb)).
All resolve to the same `admin` grant today, so nothing is widened — but a
custom role built on these names will behave surprisingly.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Template create failed: node_platform_id is required` | `node_platform_id` omitted — the column is NOT NULL | Pass a `NodePlatform` id; list them with the platforms catalog |
| `Module assignment refused: it would introduce N composition conflicts — …` | Error-severity conflict (`module_dependency_conflict` or `instance_variety_collision`) | The message names the modules. Drop one, or stage the join with `enabled: false` and resolve before enabling |
| Assignment succeeds but the response carries `warnings` | `protected_spec_overlap` — soft, auto-resolved by the build pipeline | Usually fine. Confirm the claimer is the module you want owning those paths |
| Clone/import succeeds but carries `warnings` | **Error**-severity conflicts, reported not blocked (different meaning from the assign path) | Treat as a build-breaking defect. Fix on the new template before applying it anywhere |
| Enabling a previously-staged join suddenly 422s | The conflict check is skipped at `enabled: false` and runs on the disabled → enabled transition | Preview with `system_compose_preview_template` over the intended final module set, then resolve |
| Template composes badly but assignments still succeed | The guard is a delta — a pre-existing conflict is baseline and is not re-charged | Run `POST /nodes/:id/apply_template` with `dry_run: true` and read `warnings` for the whole-set verdict |
| Apply reports conflicts that provisioning never mentioned | The automated callers do not read `Result#warnings` | Expected today. Run the explicit dry-run apply yourself — see the note in Phase 5 |
| `Template '<name>' is in use by N node(s)` on delete | `has_many :nodes, dependent: :restrict_with_error` | Reassign or delete those nodes first |
| Import 422 with `details.missing_modules` | Modules resolved by `(name, variety)` are absent in the target account | Author/register them first ([module-authoring.md](./module-authoring.md)), then re-import |
| Import 422 `platform not found in account: <name>` | The bundle's platform name has no match in the target account | Create the `NodePlatform` under that exact name, or import into an account that has it |
| Clone 422 on name | Unique index is `(account_id, name)`; default is `"<source>-copy"` | Pass an explicit `name` |
| Node gets none of the template's modules | Apply never ran, or the joins are `enabled: false` (the closure is enabled-only) | Check the joins, then `POST /nodes/:id/apply_template` |
| A template edit never reaches already-provisioned nodes | Nothing re-walks the closure on its own except `TemplateClosureDriftSensor` | Wait for the sensor's remediation, or apply explicitly. Pivot-booted instances compose their union at boot and additionally need a reprovision |
| Semantic search misses a template you know exists | Template embeddings fold in the assigned modules' text, and editing a module does **not** bump the template's `updated_at` — so a module rename leaves the vector quietly stale and `embedding_stale` cannot detect it | `FORCE=true rails system:catalog:backfill_embeddings` |

## How the System Concierge should use this

When an operator asks for a node type ("I need a template for an nginx edge"):

1. `system_discover_templates` first — reuse before authoring, and read
   `coverage` before trusting an empty result.
2. `system_compose_preview_template` over the intended module set. Surface the
   `conflicts` array to the operator **before** creating anything; error-severity
   entries are what the assignment path will refuse.
3. `system_create_template` → `system_assign_module_to_template` per module,
   with `request_confirmation` on the writes.
4. If a response carries `warnings`, say which kind it is: soft on
   assign, **error-severity** on clone/import.

## Related docs

- [`module-authoring.md`](./module-authoring.md) — authoring the `NodeModule` rows a template composes; `protected_spec` / `file_spec` / dependency semantics
- [`node-provisioning.md`](./node-provisioning.md) — the Node + NodeInstance lifecycle a template feeds
- [`gitops-reconciliation.md`](./gitops-reconciliation.md) — declaring template↔module assignments in `fleet.yaml`; template/module destroy is deliberately blocked there
- [`../USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — composition use cases
- [`../FLEET_SENSORS.md`](../FLEET_SENSORS.md) — `template_closure_drift_sensor` and the `system.template_closure_drift` intervention policy
- [`../tutorials/02-first-module.md`](../tutorials/02-first-module.md) — the learning-oriented path into module + template composition

_Last verified: 2026-08-04_
