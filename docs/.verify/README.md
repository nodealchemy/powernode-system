# Documentation Verification Harness

Three read-only bash scripts that audit the docs corpus for common drift
classes: broken markdown links, missing code path references, unknown MCP
action names.

**All scripts are read-only.** They never modify the file tree.

## Scripts

| Script | What it checks | Exit codes |
|--------|----------------|------------|
| `check-links.sh` | Every `[text](path)` in every `.md` resolves on disk | 0=clean, 1=broken links, 2=invocation error |
| `check-code-refs.sh` | Every cited code path (e.g. `extensions/system/server/app/services/...`) exists | 0=clean, 1=missing references, 2=invocation error |
| `check-mcp-actions.sh` | Every referenced MCP action (`system_*`, `docker_*`, `kubernetes_*`) is defined in the parent platform's tool registry | 0=clean (or registry unreachable), 1=unknown actions, 2=invocation error |

## Running locally

From the extension root:

```bash
bash docs/.verify/check-links.sh
bash docs/.verify/check-code-refs.sh
bash docs/.verify/check-mcp-actions.sh
```

Run any one in isolation, or wire them together:

```bash
set -e
for script in docs/.verify/check-links.sh docs/.verify/check-code-refs.sh docs/.verify/check-mcp-actions.sh; do
  echo "--- $script ---"
  bash "$script"
done
echo "All checks passed."
```

## When to run

- **Before pushing doc changes** — catch broken links + dead code refs
  before review
- **As part of doc PR review** — reviewers run before approving
- **In CI** (future) — wire each script into `.gitea/workflows/docs.yml`
  as a gating job. See "Wiring into CI" below.

## Output format

Each script prints findings as `<file>:<line>: <CLASSIFICATION> → <detail>`
followed by a summary footer.

Example `check-links.sh` finding:

```
docs/runbooks/cve-response.md:120: BROKEN → ../examples/05-cve-response-walkthrough.md
```

Example `check-code-refs.sh` finding:

```
docs/agent-internals.md:45: MISSING → agent/internal/old_package/
```

Example `check-mcp-actions.sh` finding:

```
UNKNOWN actions (in docs but not in registry):
  system_old_action
    referenced in: docs/runbooks/legacy.md
```

## Tradeoffs + limitations

**`check-links.sh`** uses simple regex extraction of `[text](path)` pairs.
It correctly handles:

- Relative paths (resolved against the file's directory)
- Anchor fragments (stripped before resolution)
- URL schemes (http/https/mailto/ftp/tel → skipped)

It does NOT handle:

- Reference-style links (`[text][ref]` then `[ref]: path`) — extension lacks consistent use of these
- Auto-links (`<http://...>`)
- Diagrams or images referencing paths

**`check-code-refs.sh`** uses a conservative whitelist of extension-prefix
patterns. It checks paths matching:

- `extensions/system/...`
- `agent/internal/...` and `agent/cmd/...`
- `app/services/system/...`, `app/models/system/...`, etc. (resolved relative to extension's `server/`)
- `db/migrate/...`, `db/seeds/...` (resolved relative to extension's `server/`)

It does NOT check parent-platform paths (`server/app/...` without `extensions/system/` prefix) because those can't be resolved from inside the submodule.

**`check-mcp-actions.sh`** depends on finding the parent platform's
`server/app/services/ai/tools/platform_api_tool_registry.rb`. If the
extension is checked out standalone (no parent platform around), the
script warns and exits 0 — it's a best-effort gate, not a hard requirement.

The script extracts ONLY call-site invocations matching `platform.<action>(`
to minimize false positives from prose mentions, table names, or class
names that happen to match the `system_*` pattern.

Lines that are commented out (`//`, `#`) or inside markdown blockquotes
(`> `) are skipped — they're aspirational annotations / future-action
callouts, not real call sites.

A small set of actions ARE referenced via real `platform.X(...)` syntax
in tutorials + runbooks but aren't yet in the registry — these are the
MCP wrappers planned but not yet shipped. See
[`ASPIRATIONAL_MCP.md`](./ASPIRATIONAL_MCP.md) for the full catalog with
REST workarounds.

When the harness reports unknowns, cross-reference against
`ASPIRATIONAL_MCP.md`. New entries not in that catalog indicate real
drift — either fix the doc or update the registry.

## Wiring into CI

These scripts are intentionally NOT wired into `.gitea/workflows/` yet —
the harness shape is still settling and CI flake from
overaggressive checks is worse than a missed link.

When wiring (recommended as a follow-up after this harness is exercised
for a release cycle):

1. Create `.gitea/workflows/docs.yml`:

   ```yaml
   name: Docs checks
   on:
     pull_request:
       paths:
         - 'docs/**'
         - 'agent/README.md'
         - 'CONTRIBUTING.md'
         - 'README.md'

   jobs:
     verify:
       runs-on: [self-hosted, ubuntu-24.04]
       steps:
         - uses: actions/checkout@v4
         - name: check-links
           run: bash docs/.verify/check-links.sh
         - name: check-code-refs
           run: bash docs/.verify/check-code-refs.sh
         - name: check-mcp-actions
           run: bash docs/.verify/check-mcp-actions.sh
   ```

2. Test on a draft PR before promoting to required-check status.
3. Allow operator override via a `[docs-skip-verify]` commit message
   marker for genuine exceptions (e.g., during a documented breaking
   refactor).

## Related

- [`RENDER_PARITY.md`](./RENDER_PARITY.md) — Mermaid diagram render
  parity between Gitea and GitHub
- [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) §Doc conventions —
  authoring rules these scripts validate
