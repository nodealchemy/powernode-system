#!/usr/bin/env bash
# Read-only link checker: walks every .md under docs/, extracts every
# [text](path) reference, and verifies the resolved path exists on disk.
#
# Exit codes:
#   0 — all links resolve
#   1 — one or more broken links found
#   2 — script invocation error
#
# Output format:
#   <file>:<line>: BROKEN -> <target>
# Run from extension root:
#   bash docs/.verify/check-links.sh

# Resolve extension root regardless of cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCS_ROOT="$EXT_ROOT/docs"

if [ ! -d "$DOCS_ROOT" ]; then
  echo "ERROR: docs/ not found at $DOCS_ROOT" >&2
  exit 2
fi

broken=0
total_links=0
total_files=0

# Walk every .md under docs/
while IFS= read -r mdfile; do
  total_files=$((total_files + 1))
  dir="$(dirname "$mdfile")"
  lineno=0

  while IFS= read -r line; do
    lineno=$((lineno + 1))
    # Strip inline code spans (backtick-quoted) — they're literal text,
    # not links. Avoids false positives in docs that describe link syntax.
    stripped_line=$(echo "$line" | sed -E 's/`[^`]*`//g')
    # Extract [text](path) pairs from the stripped line
    matches=$(echo "$stripped_line" | grep -oE '\[[^]]+\]\([^)]+\)' || true)
    [ -z "$matches" ] && continue
    while IFS= read -r match; do
      [ -z "$match" ] && continue
      # Extract the (path) part
      path=$(echo "$match" | sed -E 's/^\[[^]]+\]\(//; s/\)$//')
      # Skip URLs and special schemes
      case "$path" in
        http://*|https://*|mailto:*|ftp://*|tel:*|"#"*) continue ;;
      esac
      # Strip anchor fragment for resolution
      target="${path%%#*}"
      [ -z "$target" ] && continue
      total_links=$((total_links + 1))
      # Resolve relative paths against the file's directory
      if [[ "$target" == /* ]]; then
        echo "$mdfile:$lineno: ABSOLUTE -> $target (use relative paths)"
        broken=$((broken + 1))
        continue
      fi
      resolved="$dir/$target"
      if [ ! -e "$resolved" ]; then
        echo "$mdfile:$lineno: BROKEN -> $target"
        broken=$((broken + 1))
      fi
    done <<< "$matches"
  done < "$mdfile"
done < <(find "$DOCS_ROOT" -name '*.md' -type f)

echo
echo "------------------------------------------"
echo "  scanned: $total_files files / $total_links links"
echo "  broken:  $broken"
echo "------------------------------------------"

if [ "$broken" -gt 0 ]; then
  exit 1
fi
exit 0
