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
| `check-mcp-actions.sh` | Every referenced MCP action (`system_*`, `docker_*`, `kubernetes_*`) is defined in the parent platform's tool registry, or catalogued in [`ASPIRATIONAL_MCP.md`](./ASPIRATIONAL_MCP.md) | 0=clean (or registry unreachable), 1=unknown/uncatalogued actions or dispatcher drift, 2=invocation error |

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
- **In CI** — already wired; see "Wiring into CI" below for what gates and
  what only reports.

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
UNKNOWN actions (referenced via platform.X, not in registry, not catalogued):
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

The script requires the `platform.` prefix, which is what keeps prose
mentions, table names and class names that happen to match the bare
`system_*` pattern out of the results.

**Comment-framed lines are scanned, not skipped** (changed 2026-09-01,
IMP-2b09c9f22bae). Until then the script dropped every line opening with
`//`, `#` or `>` before matching, on the ground that those are "aspirational
annotations, not real call sites". That is backwards: an aspirational
annotation is precisely what `ASPIRATIONAL_MCP.md` exists to catalogue, so
the filter deleted the only evidence the catalog is about — and the catalog
then declared itself empty citing the script's clean run as proof, while two
`//`-framed unregistered verbs sat in `docs/FLEET_SENSORS.md`. Removing the
filter introduced no new unknowns: measured over all `.md` under `docs/`, the
dropped lines carried 9 distinct prefixed verbs, but only 4 were invisible
anywhere else (the other 5 also appeared on live lines) — and of those 4, two
are registered and two are the genuine aspirational pair.

Comment framing is now recorded rather than used to discard, and it decides
how a reference is classified:

| Reference | Registered? | Verdict |
|---|---|---|
| live or comment-framed | yes | clean |
| comment-framed, in the catalog | no | **aspirational** — expected, does not fail |
| comment-framed, not in the catalog | no | **unknown** — exit 1 |
| live, in the catalog | no | **live call to a catalogued verb** — exit 1 |
| live, not in the catalog | no | **unknown** — exit 1 |

"Comment-framed" here means the line opens with `//`, `#` **or** `>`, so it
lumps commented-out code together with blockquoted prose — as it happens, 5
of the 9 currently classed comment-framed are blockquotes, not comments.

A live call to an unimplemented verb prescribes the fiction rather than
describing it, and an operator copying it cannot run it at all — so the
catalog never excuses one. That is the same **principle** as
`ASPIRATIONAL_VERBS` in
`server/spec/docs/module_docs_mcp_call_signatures_spec.rb`, but **not the
same framing test**: `comment_framed?` there accepts `//` only. This script
is the looser of the two, so a site reframed from `//` to `#` or `>` still
reads as aspirational here while that sweep calls it live and fails it. The
spec is the stricter authority and runs in `scripts/validate.sh`; this script
is advisory in CI. Never read a green run here as agreement with it.

The catalog is **derived** from that spec constant and pinned to it by an
equality oracle there; this script only reads the derived table, and reads
it fail-closed — a missing file, missing `ASPIRATIONAL-CATALOG:BEGIN`/`END`
markers, or an unparseable table all yield an empty exemption set, which
reports every aspirational reference as UNKNOWN rather than silently
excusing it.

The summary footer prints `aspirational (catalogued)`, `live call to
catalogued` and `unknown (uncatalogued)` separately, and states whether a
zero comment-framed count means "the docs contain none" or would have meant
"the scan skipped them". Read both numbers: `0 unknown` alone does not
distinguish a corpus that was checked from one that was not.

When the harness reports unknowns, cross-reference against
`ASPIRATIONAL_MCP.md` — and remember that file is derived: fix
`ASPIRATIONAL_VERBS` first, never the markdown alone, and never take the
catalog's contents from this script's output.

## Wiring into CI

All three run on doc-touching pull requests via
[`.gitea/workflows/docs.yml`](../../.gitea/workflows/docs.yml). (This
section previously said they were "intentionally NOT wired into
`.gitea/workflows/` yet"; the workflow has existed since it was added and
the claim was simply stale.)

Gating policy, as the workflow declares it:

| Step | Gates the job? |
|---|---|
| `check-links.sh` | **yes** — broken markdown links fail the build |
| `check-code-refs.sh` | no — `continue-on-error: true` |
| `check-mcp-actions.sh` | no — `continue-on-error: true` |

So `check-mcp-actions.sh` exiting 1 **reports** but does not turn the job
red today. Read the exit code as a finding to triage, not as a build break —
and do not assume a green Docs-checks job means the MCP pass was clean.

Operator override: include `[docs-skip-verify]` in the head commit message
and the guard step skips every verify step (e.g. during a documented
breaking doc refactor).

The parent platform has its own copy of this harness at
`docs/.verify/` with the same gating split, plus `check-counts.sh` and
`check-auto-gen-headers.sh`.

## Related

- [`RENDER_PARITY.md`](./RENDER_PARITY.md) — Mermaid diagram render
  parity between Gitea and GitHub
- [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) §Doc conventions —
  authoring rules these scripts validate
