# Documentation Archive

This shelf holds documents that captured point-in-time state of the System
extension at earlier phases of its evolution. Each archived doc carries an
`ARCHIVED` banner at the top with a date and pointers to the current sources
of truth.

**Why we keep these:** traceability. Phase plans, acceptance reports, and
shipped-backlog writeups often contain the *why* behind a current code path.
Deleting them strips that context; leaving them on the active surface
confuses new readers about what's current.

## Archive Layout

| Path | What it is | Archived |
|------|------------|----------|
| [`TASKS.md`](./TASKS.md) | Milestone tracker (Tracks A–F, Phase 10 stabilization sweep). Superseded by the live state in [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) and parent-platform plan files. | 2026-05-17 |
| [`plans/missing-features.md`](./plans/missing-features.md) | Implementation plan for 6 gated MCP actions across GitOps reconciler, SDWAN federation, and Vault credential restoration. Most items have since shipped — see [`docs/MCP_API_REFERENCE.md`](../MCP_API_REFERENCE.md) and the relevant runbooks for current state. | 2026-05-17 |
| [`federation/phase-reports/P2.5-acceptance-2026-05-17.md`](./federation/phase-reports/P2.5-acceptance-2026-05-17.md) | Acceptance report for Phase P2.5 (Reverse Proxy + ACME DNS-01 + Endpoint Discovery). Captures the six lifecycle defects found and fixed during live verification. | 2026-05-17 |

## Archive Convention

When archiving a doc:

1. `git mv` it under `docs/history/<original-subpath>` (preserves git history)
2. Add the standard `ARCHIVED` banner immediately after the title:

   ```markdown
   > **ARCHIVED — historical record only.**
   > This document captures point-in-time state from a prior phase and is no longer
   > maintained. For current state see <relative-paths-to-current-docs>.
   > _Archived YYYY-MM-DD as part of <reason>._
   ```

3. Update the active doc map in `README.md` and `CLAUDE.md` to remove any
   active-surface links to the archived file (the only links should be from
   this shelf README and from other archived docs).
4. Add a row to the Archive Layout table above.

Phase reports (under `history/federation/phase-reports/`) are archived
automatically after the next major phase ships. Other docs are archived when
their content is superseded by a current operator-facing doc.
