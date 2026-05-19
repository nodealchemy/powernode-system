#!/usr/bin/env bash
# audit-todos.sh — fail if any source file has an unlabeled standalone TODO comment.
#
# Per docs/TODO_TAXONOMY.md, every standalone '# TODO' comment in Ruby
# source MUST use the labeled form: # TODO(<label>): <text>
# where <label> is one of: M<N>-<slug>, P<N>-<slug>, security-review,
# refactor, unscheduled.
#
# This script scans the extension's Ruby source for *standalone* TODO
# comments (i.e., comment lines whose first word after '#' is TODO).
# Inline TODOs embedded mid-prose ("(TODO: ...)" inside a longer comment)
# are NOT flagged — the surrounding prose carries the scheduling context.
#
# Exit 0: all standalone TODOs are labeled (or none exist).
# Exit 1: one or more bare TODO comments found.
#
# Run locally:
#   bash extensions/system/scripts/audit-todos.sh
#
# Audit plan item: P3.2 (~/.claude/plans/forform-a-deep-examination-fizzy-lobster.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Match a standalone TODO comment:
#   - line begins with optional whitespace + '#'
#   - then optional whitespace
#   - then literal 'TODO'
#   - then NOT '(' (i.e. no parenthesized label)
# So '# TODO: foo' and '# TODO ' fail; '# TODO(refactor): foo' passes.
# Lines like 'foo "TODO"' or '# Returns (TODO later)' don't match.
pattern='^[[:space:]]*#[[:space:]]*TODO([^(]|$)'

paths=(
  "${EXT_ROOT}/server/app"
  "${EXT_ROOT}/worker/app"
)

unlabeled=()
for p in "${paths[@]}"; do
  [[ -d "$p" ]] || continue
  while IFS= read -r line; do
    [[ -n "$line" ]] && unlabeled+=("$line")
  done < <(grep -rnE "$pattern" "$p" --include='*.rb' 2>/dev/null || true)
done

if [[ ${#unlabeled[@]} -eq 0 ]]; then
  echo "OK: all standalone TODOs are labeled."
  exit 0
fi

echo "FAIL: ${#unlabeled[@]} unlabeled standalone TODO comment(s) found."
echo ""
printf '%s\n' "${unlabeled[@]}"
echo ""
echo "Every standalone '# TODO' comment must use the labeled form:"
echo "    # TODO(<label>): <text>"
echo ""
echo "Valid labels:"
echo "    M<milestone>-<slug>   e.g. M6-seeds, M7-K3s-HA"
echo "    P<phase>-<slug>       e.g. P3-pool-ha, P2-cve-depth"
echo "    security-review       requires security sign-off before action"
echo "    refactor              cleanup intent, no scheduled date"
echo "    unscheduled           open intent, no schedule yet"
echo ""
echo "See extensions/system/docs/TODO_TAXONOMY.md for the full convention."
exit 1
