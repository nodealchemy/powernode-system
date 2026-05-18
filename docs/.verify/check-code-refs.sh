#!/usr/bin/env bash
# Read-only code-reference checker: walks every .md under docs/, extracts
# every reference to a code path inside the extension (or commonly-cited
# parent platform paths), and verifies the path exists on disk.
#
# Verifies:
#   - extensions/system/server/app/...
#   - extensions/system/server/db/...
#   - extensions/system/server/spec/...
#   - extensions/system/agent/internal/...
#   - extensions/system/agent/cmd/...
#   - extensions/system/frontend/src/...
#   - extensions/system/worker/...
#   - extensions/system/initramfs/...
#   - extensions/system/templates/...
#
# Parent platform paths (server/app/...) without the extensions/system/
# prefix are skipped — they can't be checked from inside the submodule.
#
# Exit codes:
#   0 — all referenced code paths exist
#   1 — one or more references missing
#   2 — script invocation error
#
# Run from extension root:
#   bash docs/.verify/check-code-refs.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS_ROOT="$EXT_ROOT/docs"

if [ ! -d "$DOCS_ROOT" ]; then
  echo "ERROR: docs/ not found at $DOCS_ROOT" >&2
  exit 2
fi

total=0
missing=0

while IFS= read -r mdfile; do
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    # Extract backtick-quoted content (`...`)
    ticks=$(echo "$line" | grep -oE '`[^`]+`' 2>/dev/null || true)
    [ -z "$ticks" ] && continue
    while IFS= read -r tickref; do
      [ -z "$tickref" ] && continue
      raw=$(echo "$tickref" | sed -E 's/^`//; s/`$//')
      # Heuristic: must contain a slash AND look like a path (no spaces)
      case "$raw" in
        */*) ;;
        *) continue ;;
      esac
      case "$raw" in
        http*|https*|mailto*) continue ;;
        *" "*) continue ;;
      esac
      # Resolve candidate to filesystem
      target=""
      if [[ "$raw" == extensions/system/* ]]; then
        target="$EXT_ROOT/${raw#extensions/system/}"
      elif [[ "$raw" == agent/internal/* ]] || [[ "$raw" == agent/cmd/* ]]; then
        target="$EXT_ROOT/$raw"
      elif [[ "$raw" == app/services/system/* ]] || [[ "$raw" == app/models/system/* ]] || [[ "$raw" == app/controllers/api/v1/system/* ]] || [[ "$raw" == app/services/sdwan/* ]] || [[ "$raw" == app/models/sdwan/* ]]; then
        target="$EXT_ROOT/server/$raw"
      elif [[ "$raw" == db/migrate/* ]] || [[ "$raw" == db/seeds/* ]]; then
        target="$EXT_ROOT/server/$raw"
      else
        continue
      fi
      # Strip trailing punctuation
      target="${target%[.,;:]}"
      total=$((total + 1))
      # Check existence (with glob expansion for wildcarded paths)
      if [ ! -e "$target" ]; then
        # Try glob expansion
        shopt -s nullglob
        matches=( $target )
        shopt -u nullglob
        if [ "${#matches[@]}" -eq 0 ]; then
          echo "$mdfile:$lineno: MISSING -> $raw"
          missing=$((missing + 1))
        fi
      fi
    done <<< "$ticks"
  done < "$mdfile"
done < <(find "$DOCS_ROOT" -name '*.md' -type f)

echo
echo "------------------------------------------"
echo "  checked:  $total code references"
echo "  missing:  $missing"
echo "------------------------------------------"

if [ "$missing" -gt 0 ]; then
  exit 1
fi
exit 0
