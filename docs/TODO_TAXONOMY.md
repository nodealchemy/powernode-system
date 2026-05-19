# TODO Taxonomy

Every **standalone TODO comment** in this extension's Ruby source must be labeled. The label tells future-readers (and future-you) what scheduling bucket the work belongs to — preventing the "what does this TODO mean?" pile-up that audits surface.

The gate runs in CI via [`scripts/audit-todos.sh`](../scripts/audit-todos.sh).

## Labeled form

```ruby
# TODO(<label>): <description>
```

A standalone TODO is a comment line whose first word after `#` is `TODO`. Inline TODOs embedded mid-prose are not gated:

```ruby
# This is gated — must be labeled:
# TODO: extract this into a helper

# This is fine — TODO is mid-prose inside a contextful comment:
# Returns 200 in all branches (TODO: wire Rack::Attack rule).
```

## Valid labels

| Label | Meaning | Example |
|---|---|---|
| `M<N>-<slug>` | Phase-gated work, tagged to a project milestone | `# TODO(M7-K3s-HA): wire kubeconfig storage` |
| `P<N>-<slug>` | Phase or slice within an active sweep | `# TODO(P3-pool-ha): cross-AZ replenishment` |
| `security-review` | Requires security sign-off before action | `# TODO(security-review): confirm CSP for inline scripts` |
| `refactor` | Cleanup intent, low priority, no scheduled date | `# TODO(refactor): rename to follow service naming convention` |
| `unscheduled` | Open intent acknowledged, no schedule yet | `# TODO(unscheduled): support region-only lookup` |

## When to add a new label

Add it here first (PR to this file), then start using it. Labels should be one of the five categories above unless there's a clear reason to add a sixth. Keep the taxonomy small — every new label is a new context future-you needs to remember.

## When NOT to write a TODO

- **Resolved in the same PR?** Don't write the TODO — fix the issue inline.
- **Long-term open question?** Open a GitHub/Gitea issue and reference it: `# TODO(unscheduled): see issue #123`.
- **Tracking a missing feature with a deadline?** Tag the milestone: `# TODO(M7-K3s-HA): wire X by 2026-06`.

## CI behavior

`audit-todos.sh` walks `server/app/` and `worker/app/` for `*.rb` files. On a bare `# TODO` it prints the file + line + offending text, plus the list of valid labels, and exits non-zero.

```bash
# Run locally before pushing:
bash extensions/system/scripts/audit-todos.sh

# Output on success:
OK: all standalone TODOs are labeled.

# Output on failure:
FAIL: 1 unlabeled standalone TODO comment(s) found.
server/app/services/foo.rb:12:    # TODO: rename
```

## Out of scope (today)

- **Inline-prose TODOs** (TODO mid-comment) — surrounding prose carries context; gating them is more friction than value.
- **Go agent TODOs** — Go's convention is `// TODO(handle): text` and existing TODOs (`v1.1`) already follow it; covered by `go vet`-style tooling if needed in future.
- **Spec TODOs** — specs with TODOs are usually a sign of test debt, separately tracked via SimpleCov coverage gates (see audit plan P3.7).
- **FIXME / XXX / HACK** — none currently exist in source as bare comments; the gate can be extended if/when they appear.

## Related

- [`CONTRIBUTING.md` → TODO Discipline](../CONTRIBUTING.md#todo-discipline)
- [`scripts/audit-todos.sh`](../scripts/audit-todos.sh)
- [`.gitea/workflows/ci.yaml`](../.gitea/workflows/ci.yaml) — `todo-audit` job
