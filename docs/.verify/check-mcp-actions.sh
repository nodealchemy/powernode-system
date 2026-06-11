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

# ── Pass 2 (F8-09) — dispatcher ↔ registry bidirectional parity ──────────
# The docs pass above only catches a doc that names a non-existent action.
# It is BLIND to the real failure mode (F8-01): an action implemented +
# DISPATCHED in an extension Ai::Tools class but never registered, so agents
# can never reach it. This pass diffs each tool's dispatched actions
# (`when "..."` branches + ACTION_PERMISSIONS/action_definitions keys)
# against the registry entries that map to that tool's class, both ways.
TOOLS_DIR="${MCP_TOOLS_DIR:-$EXT_ROOT/server/app/services/ai/tools}"
drift_count=0

if [ -d "$TOOLS_DIR" ]; then
  echo
  echo "Dispatcher pass: $TOOLS_DIR"

  dispatched=$(mktemp)
  registered_ext=$(mktemp)
  trap 'rm -f "$known_actions" "$found_actions" "$missing_actions" "$dispatched" "$registered_ext"' EXIT

  # Actions each extension tool claims: `when "..."` dispatch branches plus
  # the `"..." =>` keys (ACTION_PERMISSIONS + action_definitions).
  {
    grep -rhE '^[[:space:]]*when "(system_|kubernetes_|docker_)' "$TOOLS_DIR"/*.rb 2>/dev/null \
      | grep -oE '"(system_|kubernetes_|docker_)[a-z_]+"'
    grep -rhE '^[[:space:]]*"(system_|kubernetes_|docker_)[a-z_]+"[[:space:]]*=>' "$TOOLS_DIR"/*.rb 2>/dev/null \
      | grep -oE '^[[:space:]]*"(system_|kubernetes_|docker_)[a-z_]+"'
  } | tr -d ' "' | sort -u > "$dispatched"

  # Registry entries mapped to one of the extension's tool classes.
  ext_classes=$(grep -rhoE 'class [A-Za-z0-9]+Tool' "$TOOLS_DIR"/*.rb 2>/dev/null | awk '{print $2}' | sort -u)
  : > "$registered_ext"
  for cls in $ext_classes; do
    grep -E "=> \"Ai::Tools::${cls}\"" "$REGISTRY" 2>/dev/null \
      | grep -oE '^[[:space:]]*"(system_|kubernetes_|docker_)[a-z_]+"' \
      | tr -d ' "' >> "$registered_ext"
  done
  sort -u -o "$registered_ext" "$registered_ext"

  dispatched_count=$(wc -l < "$dispatched" | tr -d ' ')
  registered_count=$(wc -l < "$registered_ext" | tr -d ' ')
  echo "  $dispatched_count dispatched actions, $registered_count registered to extension tools"

  orphan_dispatched=$(comm -23 "$dispatched" "$registered_ext")
  orphan_registered=$(comm -13 "$dispatched" "$registered_ext")

  if [ -n "$orphan_dispatched" ]; then
    echo
    echo "DISPATCHED but NOT REGISTERED (agents cannot reach these — the F8-01 mode):"
    echo "$orphan_dispatched" | sed 's/^/  /'
    drift_count=$((drift_count + $(echo "$orphan_dispatched" | grep -c .)))
  fi
  if [ -n "$orphan_registered" ]; then
    echo
    echo "REGISTERED but NOT DISPATCHED (dead registry entry — no handler):"
    echo "$orphan_registered" | sed 's/^/  /'
    drift_count=$((drift_count + $(echo "$orphan_registered" | grep -c .)))
  fi

  echo
  echo "------------------------------------------"
  echo "  dispatched:    $dispatched_count"
  echo "  registered:    $registered_count"
  echo "  drift:         $drift_count"
  echo "------------------------------------------"
else
  echo "WARN: extension Ai::Tools dir not found ($TOOLS_DIR) — skipping dispatcher pass." >&2
fi

if [ "$missing_count" -gt 0 ] || [ "$drift_count" -gt 0 ]; then
  exit 1
fi
exit 0
