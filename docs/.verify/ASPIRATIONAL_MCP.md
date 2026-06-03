# Aspirational MCP Actions — Documented Backlog

The `check-mcp-actions.sh` harness will report a non-zero count of
**unknown** actions because some tutorials and runbooks demonstrate
operator workflows using `platform.X(...)` MCP syntax for actions that
aren't yet in the parent platform's `platform_api_tool_registry.rb`.

Each of these "unknowns" is intentional: the doc shows the **intended**
MCP shape, with a callout explaining that the wrapper is forthcoming
and operators should use the REST endpoint today.

## Known-aspirational catalog (as of 2026-06-03)

| Action | Doc | Operator workaround today |
|--------|-----|---------------------------|
| `system_get_task` | `runbooks/node-provisioning.md` | `system_list_tasks` (filter to single task) |
| `system_revert_disk_image` | `DISK_IMAGE_CI.md` | `system_set_default_disk_image_publication` with the previous publication id |
| `system_update_module_assignment` | `runbooks/module-authoring.md` | `PATCH /api/v1/system/node_module_assignments/:id` |

Total: **3 aspirational MCP wrappers**.

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
- **Running the verification harness?** The `check-mcp-actions.sh` script
  will report these as unknowns; this is expected. The script's exit 1
  signals operators to check this catalog rather than treating it as a
  hard error

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
