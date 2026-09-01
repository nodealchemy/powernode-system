#!/usr/bin/env bash
# Read-only MCP-action checker: walks every .md under docs/, extracts every
# `platform.<action>` reference, and verifies each against the parent
# platform's tool registry.
#
# Requires the `platform.` prefix, so prose mentions like "the
# system_create_node action" are NOT checked — table names, class names and
# file names all match the bare system_* pattern and would swamp the signal.
#
# COMMENT-FRAMED REFERENCES ARE SCANNED (changed 2026-09-01, IMP-2b09c9f22bae).
# This script used to drop every line opening with `//`, `#` or `>` before
# matching, on the stated ground that those are "aspirational annotations,
# not real call sites". That reasoning was backwards: an aspirational
# annotation is exactly what this checker's companion catalog
# (ASPIRATIONAL_MCP.md) exists to track, so the filter deleted the only
# evidence the catalog is about. It reported `0 unknown` while two
# `//`-framed unregistered verbs sat in docs/FLEET_SENSORS.md, and the
# catalog then cited that clean run as proof it was empty.
#
# Measured before removing it: over all .md under docs/, the dropped lines
# carried 9 distinct prefixed verbs, but only 4 were invisible ANYWHERE ELSE
# (the other 5 also appeared on live lines and were already in the found set).
# Of those 4, two are registered — system_get_task, system_lease_ci_runner —
# and two are the genuine aspirational pair. So scanning the dropped lines
# introduced no new unknowns at all: the `platform.` prefix already does the
# work the filter was credited with. See git a899f352, which added the filter
# with the file, not in response to any observed false positive.
#
# Comment framing still MATTERS, it just no longer hides anything: a
# comment-framed reference to an unregistered verb may be catalogued as
# aspirational, and a LIVE one may not. A live call to a verb no registry
# implements prescribes the fiction rather than describing it, and an
# operator copying it cannot run it at all.
#
# Same PRINCIPLE as ASPIRATIONAL_VERBS in
# server/spec/docs/module_docs_mcp_call_signatures_spec.rb, but NOT the same
# framing test, and this script is the looser of the two. Here a line counts
# as framed if it opens with `//`, `#` OR `>`; comment_framed? there accepts
# `//` only, deliberately. So a site reframed from `//` to `#` or `>` still
# reads as aspirational here while that sweep calls it LIVE and fails it. The
# spec is the stricter authority and runs in scripts/validate.sh; this script
# is advisory in CI. Do not read a green run here as agreement with it.
#
# Related: 5 of the 9 lines this script currently classes comment-framed are
# markdown BLOCKQUOTES of prose, not commented-out code. Lumping `//`, `#`
# and `>` under one label is a simplification the catalog does not share.
#
# The catalog is DERIVED from that spec constant and pinned to it by an
# equality oracle there; this script only READS the derived table. The
# derivation runs one way — registry + docs corpus -> ASPIRATIONAL_VERBS ->
# ASPIRATIONAL_MCP.md -> this script — so the script never supplies the
# exemptions it is then measured against.
#
# If the parent registry isn't reachable (e.g., standalone GitHub mirror
# clone without the parent platform), this script warns and exits 0 — it's
# best-effort, not a hard gate.
#
# Exit codes:
#   0 — every referenced action is registered or catalogued as aspirational,
#       OR registry unreachable
#   1 — one or more referenced actions are unknown AND uncatalogued (or a
#       catalogued verb is called LIVE), or dispatcher drift was found
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
found_actions=$(mktemp)
live_actions=$(mktemp)
commented_actions=$(mktemp)
catalogued=$(mktemp)
missing_actions=$(mktemp)
missing_commented=$(mktemp)
missing_live=$(mktemp)
aspirational_hits=$(mktemp)
live_exempt_abuse=$(mktemp)
trap 'rm -f "$known_actions" "$found_actions" "$live_actions" "$commented_actions" "$catalogued" "$missing_actions" "$missing_commented" "$missing_live" "$aspirational_hits" "$live_exempt_abuse"' EXIT

grep -oE '"(system_[a-z_]+|kubernetes_[a-z_]+|docker_[a-z_]+)"' "$REGISTRY" 2>/dev/null \
  | tr -d '"' | sort -u > "$known_actions"

action_count=$(wc -l < "$known_actions" 2>/dev/null | tr -d ' ')
[ -z "$action_count" ] && action_count=0
echo "  $action_count known actions in registry"

# Extract every `platform.<action>` reference from docs, tagged L(ive) or
# C(omment-framed). Comment framing is RECORDED, never used to discard — see
# the header. A line is comment-framed if it OPENS with `//`, `#` or `>`.
find "$DOCS_ROOT" -name '*.md' -type f -print0 \
  | xargs -0 grep -hE 'platform\.(system_[a-z_]+|kubernetes_[a-z_]+|docker_[a-z_]+)' 2>/dev/null \
  | awk '{
      framed = ($0 ~ /^[[:space:]]*(\/\/|#|>)/) ? "C" : "L"
      rest = $0
      while (match(rest, /platform\.(system_|kubernetes_|docker_)[a-z_]+/)) {
        tok = substr(rest, RSTART, RLENGTH)
        sub(/^platform\./, "", tok)
        print framed "\t" tok
        rest = substr(rest, RSTART + RLENGTH)
      }
    }' > "$found_actions"

awk -F'\t' '$1 == "L" { print $2 }' "$found_actions" | sort -u > "$live_actions"
awk -F'\t' '$1 == "C" { print $2 }' "$found_actions" | sort -u > "$commented_actions"

found_count=$(sort -u "$live_actions" "$commented_actions" | grep -c .)
live_count=$(grep -c . < "$live_actions")
commented_count=$(grep -c . < "$commented_actions")
echo "  $found_count distinct referenced actions in docs ($live_count live, $commented_count comment-framed)"

# ── Aspirational catalog (DERIVED — see ASPIRATIONAL_MCP.md header) ──────
# Read the machine-readable region only. If the markers are gone the parse
# yields nothing and every aspirational reference falls through to UNKNOWN,
# which fails the run: this reads FAIL-CLOSED on purpose. An empty catalog
# must never be able to explain away a reference it never saw — that is the
# exact defect (IMP-2b09c9f22bae) this pass exists to stop recurring.
CATALOG_FILE="$DOCS_ROOT/.verify/ASPIRATIONAL_MCP.md"
: > "$catalogued"
if [ ! -f "$CATALOG_FILE" ]; then
  echo "WARN: aspirational catalog not found at $CATALOG_FILE — every unregistered" >&2
  echo "      reference will be reported as UNKNOWN." >&2
elif ! grep -qF '<!-- ASPIRATIONAL-CATALOG:BEGIN -->' "$CATALOG_FILE" 2>/dev/null \
  || ! grep -qF '<!-- ASPIRATIONAL-CATALOG:END -->' "$CATALOG_FILE" 2>/dev/null; then
  echo "WARN: $CATALOG_FILE has no ASPIRATIONAL-CATALOG:BEGIN/END markers." >&2
  echo "      The catalog table is delimited by them and is unreadable without," >&2
  echo "      so every unregistered reference will be reported as UNKNOWN." >&2
else
  # Anchor on the FULL comment form, matching the Ruby oracle's regex. The
  # bare token appears in prose that explains these markers, and matching it
  # would let such a sentence move the region boundary.
  sed -n '/<!-- ASPIRATIONAL-CATALOG:BEGIN -->/,/<!-- ASPIRATIONAL-CATALOG:END -->/p' "$CATALOG_FILE" 2>/dev/null \
    | grep -E '^[[:space:]]*\|' \
    | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }' \
    | grep -oE '^`(system_|kubernetes_|docker_)[a-z_]+`$' \
    | tr -d '`' | sort -u > "$catalogued"
fi
catalogued_count=$(grep -c . < "$catalogued")
echo "  $catalogued_count verbs catalogued as aspirational in docs/.verify/ASPIRATIONAL_MCP.md"

# Unregistered references, split by framing.
comm -23 "$commented_actions" "$known_actions" 2>/dev/null > "$missing_commented"
comm -23 "$live_actions" "$known_actions" 2>/dev/null > "$missing_live"

# A comment-framed unregistered verb the catalog names is EXPECTED.
comm -12 "$missing_commented" "$catalogued" > "$aspirational_hits"
# Everything else unregistered is a finding: uncatalogued comment-framed
# references, plus every live one. A live call is a finding even when
# catalogued — the exemption is for a doc that DESCRIBES a missing
# capability, not one that PRESCRIBES it.
comm -23 "$missing_commented" "$catalogued" > "$missing_actions"
comm -12 "$missing_live" "$catalogued" > "$live_exempt_abuse"
# Buckets are disjoint per (FRAMING, verb), not per verb: a verb written
# BOTH ways appears under two headings, which is intended — the live site is
# a finding even though the commented one is excused. What this split buys is
# that no single site is counted twice, and that the UNKNOWN heading ("not
# catalogued") is never false about a verb printed under it: a catalogued
# verb called live is reported as a live-exemption abuse instead.
comm -23 "$missing_live" "$catalogued" >> "$missing_actions"
sort -u -o "$missing_actions" "$missing_actions"

aspirational_count=$(grep -c . < "$aspirational_hits")
missing_count=$(grep -c . < "$missing_actions")
live_abuse_count=$(grep -c . < "$live_exempt_abuse")

if [ "$aspirational_count" -gt 0 ]; then
  echo
  echo "ASPIRATIONAL (comment-framed, catalogued — expected, does NOT fail the run):"
  while IFS= read -r action; do
    [ -z "$action" ] && continue
    echo "  $action"
    grep -rln "platform\.$action" "$DOCS_ROOT" 2>/dev/null | head -3 | sed 's/^/    referenced in: /'
  done < "$aspirational_hits"
fi

if [ "$live_abuse_count" -gt 0 ]; then
  echo
  echo "LIVE call to a CATALOGUED aspirational verb (the catalog does NOT cover this):"
  echo "  An aspirational entry covers a commented-out example. A live call to a verb"
  echo "  no registry implements cannot be run by anyone who copies it. Comment the"
  echo "  example out, or implement the verb."
  sed 's/^/    /' "$live_exempt_abuse"
fi

if [ "$missing_count" -gt 0 ]; then
  echo
  echo "UNKNOWN actions (referenced via platform.X, not in registry, not catalogued):"
  while IFS= read -r action; do
    [ -z "$action" ] && continue
    echo "  $action"
    grep -rln "platform\.$action" "$DOCS_ROOT" 2>/dev/null | head -3 | sed 's/^/    referenced in: /'
  done < "$missing_actions"
fi

echo
echo "------------------------------------------"
echo "  known:                      $action_count"
echo "  refed:                      $found_count  (live $live_count / comment-framed $commented_count; a verb can be both)"
echo "  aspirational (catalogued):  $aspirational_count"
echo "  live call to catalogued:    $live_abuse_count"
echo "  unknown (uncatalogued):     $missing_count"
echo "------------------------------------------"
# Say which KIND of zero this is. "unknown: 0" over lines that were never
# scanned and "unknown: 0" over lines that were both print the same digit.
if [ "$commented_count" -eq 0 ]; then
  echo "  Note: no comment-framed references found. Comment-framed lines ARE scanned"
  echo "        (they were silently skipped before 2026-09-01), so this zero means the"
  echo "        docs contain none — not that the scan skipped them."
else
  echo "  Note: $commented_count comment-framed references were scanned, not skipped;"
  echo "        $aspirational_count of them resolved via the aspirational catalog rather than"
  echo "        the registry. A catalog that fails to parse reports them as UNKNOWN."
fi
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
  trap 'rm -f "$known_actions" "$found_actions" "$live_actions" "$commented_actions" "$catalogued" "$missing_actions" "$missing_commented" "$missing_live" "$aspirational_hits" "$live_exempt_abuse" "$dispatched" "$registered_ext"' EXIT

  # Actions each extension tool claims: `when "..."` dispatch branches, the
  # `"..." =>` keys (ACTION_PERMISSIONS + action_definitions), and the
  # `name: "..."` a SINGLE-ACTION tool declares in self.definition.
  #
  # That third source is load-bearing. A tool exposing exactly one action has no
  # `when` branch to dispatch on and no ACTION_PERMISSIONS map to key — its only
  # declaration is definition[:name]. Without this line such a tool reads as
  # "registered but never dispatched", i.e. a dead registry entry with no
  # handler, which is the opposite of the truth: SystemBlastRadiusTool
  # implements #call and works. This pass exists to catch a REAL absent handler
  # (audit F8-01), and a false positive here trains people to ignore it.
  {
    grep -rhE '^[[:space:]]*when "(system_|kubernetes_|docker_)' "$TOOLS_DIR"/*.rb 2>/dev/null \
      | grep -oE '"(system_|kubernetes_|docker_)[a-z_]+"'
    grep -rhE '^[[:space:]]*"(system_|kubernetes_|docker_)[a-z_]+"[[:space:]]*=>' "$TOOLS_DIR"/*.rb 2>/dev/null \
      | grep -oE '^[[:space:]]*"(system_|kubernetes_|docker_)[a-z_]+"'
    # Single-action tools ONLY, decided per file. A MULTI-action tool's
    # definition[:name] is the TOOL name (e.g. "system_fleet"), which is not an
    # action and is not in the registry — harvesting it unconditionally invents
    # six phantom "dispatched but unregistered" entries. So take `name:` only
    # from files that declare no `when` branch AND no `"..." =>` key, which is
    # exactly what makes a tool single-action.
    for f in "$TOOLS_DIR"/*.rb; do
      [ -f "$f" ] || continue
      if grep -qE '^[[:space:]]*when "(system_|kubernetes_|docker_)' "$f" 2>/dev/null; then continue; fi
      if grep -qE '^[[:space:]]*"(system_|kubernetes_|docker_)[a-z_]+"[[:space:]]*=>' "$f" 2>/dev/null; then continue; fi
      # Parameter schemas also use `name:`, but as `name: { type: "string" }` —
      # a brace, not a string — so requiring the quote excludes them.
      grep -hE '^[[:space:]]*name:[[:space:]]*"(system_|kubernetes_|docker_)[a-z_]+"' "$f" 2>/dev/null \
        | grep -oE '"(system_|kubernetes_|docker_)[a-z_]+"'
    done
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

if [ "$missing_count" -gt 0 ] || [ "$live_abuse_count" -gt 0 ] || [ "$drift_count" -gt 0 ]; then
  exit 1
fi
exit 0
