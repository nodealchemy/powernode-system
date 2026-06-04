# Aspirational MCP Actions — Documented Backlog

This catalog tracks tutorial/runbook references that use `platform.X(...)`
MCP syntax for actions not yet registered in the parent platform's
`platform_api_tool_registry.rb`. The `check-mcp-actions.sh` harness reports
such references as **unknown** actions; this file is where intentional
aspirational references are documented so the harness's exit code can be
triaged rather than treated as a hard error.

**The catalog is currently empty** — every previously-aspirational wrapper
has been implemented. A clean `check-mcp-actions.sh` run should now report
**0 unknown** actions. If the harness reports an unknown, it is NOT an
expected aspirational reference — see the triage heuristics below.

## Known-aspirational catalog (as of 2026-06-03)

| Action | Doc | Operator workaround today |
|--------|-----|---------------------------|
| _(none — catalog empty)_ | | |

Total: **0 aspirational MCP wrappers**.

> **Implemented now:** the final three entries
> (`system_get_task`, `system_revert_disk_image`,
> `system_update_module_assignment`) were implemented in
> `SystemFleetTool` and registered in
> `platform_api_tool_registry.rb`, emptying this catalog. The docs
> referenced above now describe shipped MCP actions rather than
> aspirational ones.

> **2026-06-03 update:** twelve former entries left this catalog. Nine were
> **implemented** and registered in `platform_api_tool_registry.rb`
> (`system_create_template`, `system_update_instance`,
> `system_sdwan_update_federation_peer`, `system_sdwan_set_data_residency`,
> `system_sdwan_get_audit_log`, `system_acme_get_certificate`,
> `system_acme_renew_certificate`, `system_acme_revoke_certificate`,
> `system_acme_create_dns_credential`). Three were **removed** as misaligned
> with the platform design: `system_execute_task` and
> `system_sdwan_probe_federation_peer` (replaced by the autonomy-dispatch /
> scheduled-probe model — no manual trigger) and `system_acme_request_certificate`
> (redundant with the already-shipped `system_acme_provision_certificate`,
> which does create + issue in one call).

## When to use this list

- **Adding a new aspirational reference?** Append to the table above + add
  a comment-callout in the doc (`// ⚠️ aspirational MCP — use REST today`)
  + briefly explain the REST workaround at the call site
- **Implementing one of these wrappers?** Add the action to
  `server/app/services/ai/tools/platform_api_tool_registry.rb` (parent
  platform), implement the action method in the corresponding tool class
  (extension), then remove the row from this table
- **Running the verification harness?** With the catalog empty,
  `check-mcp-actions.sh` should report **0 unknown** actions and exit 0.
  If it reports any unknowns, they are not expected aspirational
  references — work the triage heuristics below to resolve each one
  (either implement + register the action, or fix the doc)

## Triage heuristics

When the harness reports an unknown action that's NOT in this catalog,
one of three things happened:

1. **A new aspirational reference** was added without updating this catalog → add it
2. **An action was renamed** in the registry and a doc still uses the old name → fix the doc
3. **A typo or accidental new doc reference** → fix the doc or remove

## Related

- [`README.md`](./README.md) — verification harness overview
- [`../MCP_API_REFERENCE.md`](../MCP_API_REFERENCE.md) — current MCP action catalog
- `server/app/services/ai/tools/platform_api_tool_registry.rb` (parent platform) — source of truth for registered actions
