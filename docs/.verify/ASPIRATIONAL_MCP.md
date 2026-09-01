# Aspirational MCP Actions — Documented Backlog

This catalog tracks tutorial/runbook references that use `platform.X(...)`
MCP syntax for actions not yet registered in the parent platform's
`platform_api_tool_registry.rb`. `check-mcp-actions.sh` reads the table
below to tell a **catalogued aspirational** reference from real drift, and
reports the two counts separately.

## This file is DERIVED — do not hand-maintain the table

The source of truth is `ASPIRATIONAL_VERBS` in
`server/spec/docs/module_docs_mcp_call_signatures_spec.rb`. That list is
guarded from both sides: implementing a verb reddens its exemption, and
deleting the exempted example reddens its staleness guard, so it cannot rot
into permanent suppression. The table below is pinned to it by an equality
oracle in the same spec file ("lists exactly the ASPIRATIONAL_VERBS
entries"), keyed on the `[doc, verb]` pair.

**To add or remove a row, edit `ASPIRATIONAL_VERBS` first**, then run
`bundle exec rspec ../extensions/system/server/spec/docs/module_docs_mcp_call_signatures_spec.rb`
from `server/` and make this table match what the oracle reports.

**Never derive this table from a `check-mcp-actions.sh` run.** That was the
2026-06-04 through 2026-09-01 defect: the script skipped `//`, `#` and `>`
lines, every entry below is written on a `//` line, so the script saw none
of them and reported `0 unknown` — and this file cited that clean run as
proof the catalog was empty. A catalog derived from a checker that also
supplies its exemptions agrees with the checker by construction and both
can be wrong together. The script now reports comment-framed references
explicitly and cross-checks them here rather than discarding them, but the
derivation still runs one way only: registry + docs corpus → `ASPIRATIONAL_VERBS`
→ this table → the script.

## Known-aspirational catalog

Verbs are written **bare** (no `platform.` prefix) on purpose.
`check-mcp-actions.sh` globs `docs/.verify/` along with every other doc and
matches `platform.<verb>` wherever it appears, so a prefixed name in a row
below would register as a call site and flag the catalog's own rows as
unknown verbs. (The rspec sweep is stricter — it needs `platform.verb({` —
so a bare table cell would not register there either way.)

<!-- ASPIRATIONAL-CATALOG:BEGIN -->

| Verb | Doc | Operator workaround today |
|------|-----|---------------------------|
| `system_get_sensor_config` | `docs/FLEET_SENSORS.md` | Read `Fleet::SensorConfig` via Rails console or REST; with no record, the sensor class constants are the effective values |
| `system_update_sensor_config` | `docs/FLEET_SENSORS.md` | `Fleet::SensorConfig.upsert_for(account:, sensor:, config:)` via Rails console, as the section itself shows |

<!-- ASPIRATIONAL-CATALOG:END -->

**Scope of that count.** Two verbs, both in the "Configuring Sensor
Thresholds" section of `docs/FLEET_SENSORS.md`, both commented out under a
⚠️ line naming the real path. This is **not** a census of every
unimplemented verb the docs mention — it is every one written in
`platform.<verb>(...)` **call syntax**, which is all either checker can see.
A verb named only in prose is outside both, and at least one exists:
`system_gitops_unregister_repository` at `docs/tutorials/10-gitops-fleet.md:385`
carries the same ⚠️-and-REST-workaround shape but is written as a bare name
in a shell comment, so no call-site extractor yields it.

Do **not** "fix" that by adding it to `ASPIRATIONAL_VERBS`. Every entry there
is asserted to still match a call site (the "exercises every
ASPIRATIONAL_VERBS exemption" guard), and a bare prose mention matches none —
the entry would redden immediately. Widening the checkers' prefix/call-syntax
filter is the real remedy, tracked separately; see the note in
`check-mcp-actions.sh`'s header about what widening would cost.

> **History.** Twelve entries left this catalog on 2026-06-03: nine were
> implemented and registered in `platform_api_tool_registry.rb`
> (`system_create_template`, `system_update_instance`,
> `system_sdwan_update_federation_peer`, `system_sdwan_set_data_residency`,
> `system_sdwan_get_audit_log`, `system_acme_get_certificate`,
> `system_acme_renew_certificate`, `system_acme_revoke_certificate`,
> `system_acme_create_dns_credential`), and three were removed as misaligned
> with the platform design: `system_execute_task` and
> `system_sdwan_probe_federation_peer` (replaced by the autonomy-dispatch /
> scheduled-probe model — no manual trigger) and
> `system_acme_request_certificate` (redundant with the already-shipped
> `system_acme_provision_certificate`, which does create + issue in one
> call). A further three (`system_get_task`, `system_revert_disk_image`,
> `system_update_module_assignment`) were implemented in `SystemFleetTool`.
> The file then recorded the catalog as empty, which was true of the entries
> it had been tracking and false of the corpus — the sensor-config pair had
> been invisible to the harness the whole time.

## When to use this list

- **Adding a new aspirational reference?** Comment the example out, say so
  in the prose at the call site, name the REST/console workaround, add the
  `[doc, verb]` entry to `ASPIRATIONAL_VERBS` with a rationale, then add the
  row here. An entry does NOT exempt a **live** call — a live call to an
  unimplemented verb prescribes the fiction rather than describing it, and
  the sweep fails it regardless of what this catalog says.
- **Implementing one of these wrappers?** Register the action in
  `server/app/services/ai/tools/platform_api_tool_registry.rb` (parent
  platform), implement it in the corresponding extension tool class, delete
  the `ASPIRATIONAL_VERBS` entry (its self-retiring guard will already be
  red), delete the row here, and uncomment the example in the doc.
- **Running the verification harness?** `check-mcp-actions.sh` prints
  `aspirational (catalogued)` and `unknown (uncatalogued)` as separate
  counts. A catalogued reference is expected and does not fail the run; an
  uncatalogued one exits 1. Read both numbers — a `0 unknown` next to
  `0 comment-framed` and a `0 unknown` next to `2 aspirational` are very
  different states.

## Triage heuristics

When the harness reports an unknown action that's NOT in this catalog,
one of three things happened:

1. **A new aspirational reference** was added without updating
   `ASPIRATIONAL_VERBS` → add it there, then here
2. **An action was renamed** in the registry and a doc still uses the old name → fix the doc
3. **A typo or accidental new doc reference** → fix the doc or remove

## Related

- [`README.md`](./README.md) — verification harness overview
- [`../MCP_API_REFERENCE.md`](../MCP_API_REFERENCE.md) — current MCP action catalog
- `server/spec/docs/module_docs_mcp_call_signatures_spec.rb` — `ASPIRATIONAL_VERBS`, the source of truth this file is derived from
- `server/app/services/ai/tools/platform_api_tool_registry.rb` (parent platform) — source of truth for registered actions
