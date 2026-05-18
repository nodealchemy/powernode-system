# Aspirational MCP Actions — Documented Backlog

The `check-mcp-actions.sh` harness will report a non-zero count of
**unknown** actions because some tutorials and runbooks demonstrate
operator workflows using `platform.X(...)` MCP syntax for actions that
aren't yet in the parent platform's `platform_api_tool_registry.rb`.

Each of these "unknowns" is intentional: the doc shows the **intended**
MCP shape, with a callout explaining that the wrapper is forthcoming
and operators should use the REST endpoint today.

## Known-aspirational catalog (as of 2026-05-17)

| Action | Doc | Operator workaround today |
|--------|-----|---------------------------|
| `system_acme_create_dns_credential` | `runbooks/acme-issuance.md` | `POST /api/v1/system/acme_dns_credentials` |
| `system_acme_get_certificate` | `runbooks/acme-issuance.md` | `GET /api/v1/system/acme_certificates/:id` |
| `system_acme_renew_certificate` | `runbooks/acme-issuance.md` | `POST /api/v1/system/acme_certificates/:id/renew` |
| `system_acme_request_certificate` | `runbooks/acme-issuance.md` | `POST /api/v1/system/acme_certificates` |
| `system_acme_revoke_certificate` | `runbooks/acme-issuance.md` | `POST /api/v1/system/acme_certificates/:id/revoke` |
| `system_create_template` | `tutorials/05`, `tutorials/10` | `POST /api/v1/system/node_templates` |
| `system_execute_task` | `CONTAINER_RUNTIMES.md` | Use `system_provision_instance` + watch `platform.recent_events` |
| `system_get_task` | `runbooks/node-provisioning.md` | `system_list_tasks` (filter to single task) |
| `system_revert_disk_image` | `DISK_IMAGE_CI.md` | `system_set_default_disk_image_publication` with the previous publication id |
| `system_sdwan_get_audit_log` | `tutorials/11-federation.md` | `GET /api/v1/system/sdwan/federation_peers/:id/audit_log` |
| `system_sdwan_probe_federation_peer` | `runbooks/acme-issuance.md` | Scheduled probe runs every `endpoint_probe_interval_seconds`; no manual MCP trigger |
| `system_sdwan_set_data_residency` | `tutorials/11-federation.md` | `POST /api/v1/system/sdwan/federation_peers/:id/data_residency` |
| `system_sdwan_update_federation_peer` | `runbooks/acme-issuance.md` | `PATCH /api/v1/system/sdwan/federation_peers/:id` |
| `system_update_instance` | `tutorials/05`, `tutorials/10` | `PATCH /api/v1/system/instances/:id` |
| `system_update_module_assignment` | `runbooks/module-authoring.md` | `PATCH /api/v1/system/node_module_assignments/:id` |

Total: **15 aspirational MCP wrappers** spanning 7 docs.

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
