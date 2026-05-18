#!/usr/bin/env bash
# Read-only MCP-action checker: walks every .md under docs/, extracts every
# MCP action **call site** (pattern: `platform.<action>(`), and verifies
# each against the parent platform's tool registry.
#
# Only extracts call-site invocations. Prose mentions like
# "the system_create_node action" are NOT checked — they're hand-curated
# and would generate too many false positives (table names, class names,
# file names all match the system_* pattern).
#
# If the parent registry isn't reachable (e.g., standalone GitHub mirror
# clone without the parent platform), this script warns and exits 0 — it's
# best-effort, not a hard gate.
#
# Exit codes:
#   0 — all referenced call-site actions exist, OR registry unreachable
#   1 — one or more referenced actions are unknown to the registry
#   2 — script invocation error
#
# Run from extension root:
#   bash docs/.verify/check-mcp-actions.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS_ROOT="$EXT_ROOT/docs"

# Try common locations for the parent platform's registry file
REGISTRY_CANDIDATES=(
  "$EXT_ROOT/../../server/app/services/ai/tools/platform_api_tool_registry.rb"
  "$EXT_ROOT/../../../server/app/services/ai/tools/platform_api_tool_registry.rb"
)

REGISTRY=""
for cand in "${REGISTRY_CANDIDATES[@]}"; do
  if [ -f "$cand" ]; then
    REGISTRY="$cand"
    break
  fi
done

if [ -z "$REGISTRY" ]; then
  echo "WARN: parent platform's MCP tool registry not found." >&2
  echo "      Tried:" >&2
  for cand in "${REGISTRY_CANDIDATES[@]}"; do
    echo "        $cand" >&2
  done
  echo "WARN: skipping MCP action verification (best-effort)." >&2
  echo "      To enable, run from inside a powernode-platform clone where this submodule is mounted." >&2
  exit 0
fi

echo "Registry: $REGISTRY"

# Extract known actions from registry — anything quoted that looks like an MCP action name
known_actions=$(mktemp)
trap 'rm -f "$known_actions" "$found_actions" "$missing_actions"' EXIT

grep -oE '"(system_[a-z_]+|kubernetes_[a-z_]+|docker_[a-z_]+)"' "$REGISTRY" 2>/dev/null \
  | tr -d '"' | sort -u > "$known_actions"

action_count=$(wc -l < "$known_actions" 2>/dev/null | tr -d ' ')
[ -z "$action_count" ] && action_count=0
echo "  $action_count known actions in registry"

# Extract call-site references from docs: `platform.<action>(` pattern only.
# Skip lines that are commented out (`//`, `#`) or inside markdown blockquotes
# (`> `) — those are aspirational annotations / future-action callouts, not
# real call sites.
found_actions=$(mktemp)
find "$DOCS_ROOT" -name '*.md' -type f -print0 \
  | xargs -0 grep -vhE '^[[:space:]]*(//|#|>)' 2>/dev/null \
  | grep -ohE 'platform\.(system_[a-z_]+|kubernetes_[a-z_]+|docker_[a-z_]+)' 2>/dev/null \
  | sed 's/^platform\.//' \
  | sort -u > "$found_actions"

found_count=$(wc -l < "$found_actions" 2>/dev/null | tr -d ' ')
[ -z "$found_count" ] && found_count=0
echo "  $found_count distinct call-site actions in docs"

# Find references that aren't in the known set
missing_actions=$(mktemp)
comm -23 "$found_actions" "$known_actions" 2>/dev/null > "$missing_actions"
missing_count=$(wc -l < "$missing_actions" 2>/dev/null | tr -d ' ')
[ -z "$missing_count" ] && missing_count=0

if [ "$missing_count" -gt 0 ]; then
  echo
  echo "UNKNOWN actions (referenced via platform.X but not in registry):"
  while IFS= read -r action; do
    [ -z "$action" ] && continue
    echo "  $action"
    grep -rln "platform\.$action" "$DOCS_ROOT" 2>/dev/null | head -3 | sed 's/^/    referenced in: /'
  done < "$missing_actions"
fi

echo
echo "------------------------------------------"
echo "  known:    $action_count"
echo "  refed:    $found_count"
echo "  unknown:  $missing_count"
echo "------------------------------------------"

if [ "$missing_count" -gt 0 ]; then
  exit 1
fi
exit 0
