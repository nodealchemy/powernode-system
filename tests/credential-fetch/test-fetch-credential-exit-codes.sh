#!/usr/bin/env bash
# test-fetch-credential-exit-codes.sh — regression suite for the
# claude-tmux credential fetch's FAILURE TAXONOMY and the systemd wiring
# that consumes it.
#
# Background (incident 2026-08-17): an uncredentialed dev-cell is the
# INTENDED steady state — `dev_cell_account_provider_credential_fallback`
# defaults OFF (inc21, 2026-07-10) so an idle cell cannot burn Anthropic
# credits. The node_api endpoint therefore 404s by design. But the script
# reported that designed state as `exit 1`, indistinguishable from a
# transient mTLS/network fault, and both consuming units carry
# Restart=on-failure — so the deliberate absence of a credential became an
# unbounded crash loop (243 restarts in 21 min of uptime, one full mTLS
# handshake against the control plane every 5s, forever) whose journal +
# audit noise masked real failures.
#
# The fix splits "intentionally absent" from "transiently broken":
#   HTTP 404          -> exit 78 (EX_CONFIG) -> RestartPreventExitStatus
#   anything else bad -> exit 1              -> still retried
# 78 is deliberately outside every exit status curl (1-99, and anyway
# converted to 1 by the script's own `||` handler) or jq (0,1,2,3,5) can
# produce, so the code cannot be forged by a tool the script shells out to.
#
# Two layers, mirroring tests/module-build/test-derive-file-spec.sh:
#   1. Behavioural — run the real script as a subprocess against a stub
#      `curl` on PATH, asserting the exit code for each response class.
#   2. Wiring — parse the module manifests and assert both consuming units
#      actually honour code 78, and that their start-limit hold-down is
#      REACHABLE. Layer 1 alone proves nothing: exit 78 with no
#      RestartPreventExitStatus= at the far end is still an infinite loop.
#
# Usage: bash tests/credential-fetch/test-fetch-credential-exit-codes.sh
# Exit: non-zero if any assertion failed.

set -uo pipefail
# (deliberately NOT -e: a failed assertion must not abort the remaining
# cases — assert_* record failures instead of exiting.)

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$TEST_DIR/../.."
SCRIPT="$ROOT/modules/claude-tmux/rootfs/usr/local/bin/claude-tmux-fetch-credential.sh"
CLAUDE_TMUX_MANIFEST="$ROOT/modules/claude-tmux/manifest.yaml"
DEV_CELL_MANIFEST="$ROOT/modules/dev-cell/manifest.yaml"

EX_CONFIG=78

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

assert_eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

assert_contains() { # <label> <haystack> <needle>
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected to contain '$3'" ;; esac
}

# ---------------------------------------------------------------------
# Harness: a hermetic fake node (PKI dir + identity.cfg + stub curl)
# ---------------------------------------------------------------------
# The script resolves its PKI directory from POWERNODE_PKI_DIR when set,
# falling back to the two absolute on-node paths. That override is the ONLY
# reason this suite can run off a real enrolled node; systemd never sets
# it, so production always takes the absolute-path chain.

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/pki" "$WORK/bin" "$WORK/run"
: > "$WORK/pki/node.crt"
: > "$WORK/pki/node.key"
: > "$WORK/pki/ca-bundle.crt"

# Stub curl: honours -o <file> and -w, emits $STUB_HTTP_CODE, writes
# $STUB_BODY to the -o target, and fails transport-style when
# $STUB_TRANSPORT_FAIL=1 (the `curl ... || { exit 1 }` branch).
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
if [ "${STUB_TRANSPORT_FAIL:-0}" = "1" ]; then
  echo "stub curl: simulated transport failure" >&2
  exit 7
fi
[ -n "$out" ] && printf '%s' "${STUB_BODY:-}" > "$out"
printf '%s' "${STUB_HTTP_CODE:-200}"
exit 0
STUB
chmod +x "$WORK/bin/curl"

# run_fetch <http_code> <body> [transport_fail] -> sets RC / OUT
run_fetch() {
  OUT="$(
    PATH="$WORK/bin:$PATH" \
    POWERNODE_PKI_DIR="$WORK/pki" \
    POWERNODE_PLATFORM_URL="https://platform.invalid" \
    RUNTIME_DIRECTORY="$WORK/run" \
    CLAUDE_TMUX_USER="$(id -un)" \
    STUB_HTTP_CODE="$1" \
    STUB_BODY="$2" \
    STUB_TRANSPORT_FAIL="${3:-0}" \
    sh "$SCRIPT" 2>&1
  )"
  RC=$?
}

echo "== layer 1: script exit taxonomy =="

# THE RED CASE — the designed steady state must be distinguishable.
run_fetch 404 ''
assert_eq "HTTP 404 (no credential configured) exits EX_CONFIG=$EX_CONFIG" "$EX_CONFIG" "$RC"
assert_contains "HTTP 404 explains an operator must set one" "$OUT" "operator must set one"

# Everything else stays retryable (exit 1) — a transient control-plane or
# network fault MUST still be retried by systemd.
run_fetch 500 ''
assert_eq "HTTP 500 stays retryable (exit 1)" "1" "$RC"

run_fetch 503 ''
assert_eq "HTTP 503 stays retryable (exit 1)" "1" "$RC"

run_fetch 000 '' 1
assert_eq "transport/mTLS failure stays retryable (exit 1)" "1" "$RC"

run_fetch 200 '{"data":{"not_the_key":"x"}}'
assert_eq "200 with no api_key field stays retryable (exit 1)" "1" "$RC"

# Happy path still works, and still lands 0600.
run_fetch 200 '{"data":{"api_key":"sk-ant-test-not-a-real-key"}}'
assert_eq "200 with api_key succeeds (exit 0)" "0" "$RC"
if [ -f "$WORK/run/api_key" ]; then
  pass "200 stages the credential file"
  assert_eq "staged credential is mode 0600" "600" "$(stat -c '%a' "$WORK/run/api_key")"
else
  fail "200 stages the credential file" "no file at $WORK/run/api_key"
  fail "staged credential is mode 0600" "no file to stat"
fi
# The key must never be echoed — the script logs, and this suite captures
# stderr, so assert the captured output cannot leak it.
case "$OUT" in
  *sk-ant-test-not-a-real-key*) fail "credential never appears in script output" "key leaked to stdout/stderr" ;;
  *) pass "credential never appears in script output" ;;
esac

echo "== layer 2: systemd wiring that consumes the taxonomy =="

# WHY THESE ASSERTIONS AND NOT "RestartPreventExitStatus is set":
# that was the original fix and it was INERT. RestartPreventExitStatus= (and
# Restart= decisions generally) key off the MAIN process; the fetch used to run
# as an ExecStartPre, which is a CONTROL process, so systemd restarted the unit
# regardless of the exit code. Measured on live systemd 2026-08-17: exit 78 from
# ExecStartPre with the directive set gave NRestarts=5; the same exit from
# ExecStart gave NRestarts=0. The suite passed the whole time, because it only
# checked that the directive was PRESENT in the manifest — never that it
# governed the failure it was written for.
#
# So the invariants below are about SHAPE, which is what actually decides
# whether systemd honours the intent:
#   1. no manifest may run the fetch from an ExecStartPre at all;
#   2. it runs as some unit's ExecStart, whose exit IS the main-process exit;
#   3. that unit maps 78 to success, so "no credential" is not a fault;
#   4. every consumer gates on the staged file with ConditionPathExists —
#      a false condition is a SKIP, not a failure, so nothing restarts.

# Extract one service's unit_body from a module manifest, then read a
# directive out of a named INI section of that body. Section matters:
# StartLimitIntervalSec/StartLimitBurst are silently IGNORED in [Service]
# and must live in [Unit].
unit_directive() { # <manifest> <service> <section> <directive>
  python3 - "$@" <<'PY'
import sys, yaml
manifest, service, section, directive = sys.argv[1:5]
with open(manifest) as fh:
    doc = yaml.safe_load(fh)
svc = next((s for s in (doc.get("services") or []) if s.get("name") == service), None)
if svc is None:
    print("<no such service>"); sys.exit(0)
cur = None
for raw in (svc.get("unit_body") or "").splitlines():
    line = raw.strip()
    if line.startswith("[") and line.endswith("]"):
        cur = line
        continue
    if cur == section and line.startswith(directive + "="):
        print(line.split("=", 1)[1].strip()); sys.exit(0)
print("<unset>")
PY
}

# seconds_of 5s|30s|180|1800 -> integer seconds (systemd's bare-number
# form is seconds; this suite only needs s/min granularity).
seconds_of() {
  case "$1" in
    *min) echo $(( ${1%min} * 60 )) ;;
    *s)   echo "${1%s}" ;;
    *)    echo "$1" ;;
  esac
}

# THE BUG-CLASS GUARD. The fetch signals "no credential configured" with an
# exit code, and an exit code can only steer systemd's restart decision from
# the MAIN process. Running it as a pre-hook silently discards that signal.
no_fetch_in_execstartpre() { # <label> <manifest>
  local label="$1" manifest="$2" hits
  hits="$(python3 - "$manifest" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
bad = []
for svc in (doc.get("services") or []):
    for raw in (svc.get("unit_body") or "").splitlines():
        line = raw.strip()
        if line.startswith("ExecStartPre=") and "claude-tmux-fetch-credential.sh" in line:
            bad.append(svc.get("name"))
print(",".join(bad))
PY
)"
  if [ -z "$hits" ]; then
    pass "$label: credential fetch is never an ExecStartPre"
  else
    fail "$label: credential fetch is never an ExecStartPre" \
         "found in unit(s) [$hits] — a pre-hook is a control process, so its exit code cannot prevent a restart"
  fi
}

# The stager: the fetch must be an ExecStart (main process), and 78 must be
# success so a deliberately uncredentialed instance is not a fault to retry.
check_stager() { # <label> <manifest> <service>
  local label="$1" manifest="$2" service="$3" exec_start success
  exec_start="$(unit_directive "$manifest" "$service" "[Service]" "ExecStart")"
  case "$exec_start" in
    */claude-tmux-fetch-credential.sh) pass "$label: fetch runs as ExecStart (main process)" ;;
    *) fail "$label: fetch runs as ExecStart (main process)" "ExecStart='$exec_start'" ;;
  esac
  success="$(unit_directive "$manifest" "$service" "[Service]" "SuccessExitStatus")"
  assert_eq "$label: EX_CONFIG is success, not a retryable fault" "$EX_CONFIG" "$success"
}

# The consumer: gated on the staged credential, so absence is a SKIP.
check_gate() { # <label> <manifest> <service> <expected-path>
  local label="$1" manifest="$2" service="$3" want="$4" conds
  conds="$(python3 - "$manifest" "$service" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) or {}
svc = next((s for s in (doc.get("services") or []) if s.get("name") == sys.argv[2]), None)
out = []
if svc:
    for raw in (svc.get("unit_body") or "").splitlines():
        line = raw.strip()
        if line.startswith("ConditionPathExists="):
            out.append(line.split("=", 1)[1].strip())
print("\n".join(out))
PY
)"
  if printf '%s\n' "$conds" | grep -qx -- "$want"; then
    pass "$label: gated on the staged credential ($want)"
  else
    fail "$label: gated on the staged credential ($want)" "ConditionPathExists set was: $(echo $conds)"
  fi
  # A gated unit must NOT also carry the inert directive.
  local prevent
  prevent="$(unit_directive "$manifest" "$service" "[Service]" "RestartPreventExitStatus")"
  if [ "$prevent" = "<unset>" ]; then
    pass "$label: no inert RestartPreventExitStatus left behind"
  else
    fail "$label: no inert RestartPreventExitStatus left behind" \
         "found RestartPreventExitStatus=$prevent — the condition gate handles this now"
  fi
}

check_unit() { # <label> <manifest> <service>
  local label="$1" manifest="$2" service="$3"

  # The hold-down for every OTHER persistent failure must be reachable:
  # systemd only trips the limit if Burst starts fit inside the interval,
  # i.e. interval > RestartSec * Burst. The stock defaults (10s/5) with
  # RestartSec=5s can NEVER trip — that is the second half of this bug.
  local interval burst restartsec
  interval="$(unit_directive "$manifest" "$service" "[Unit]" "StartLimitIntervalSec")"
  burst="$(unit_directive "$manifest" "$service" "[Unit]" "StartLimitBurst")"
  restartsec="$(unit_directive "$manifest" "$service" "[Service]" "RestartSec")"

  if [ "$interval" = "<unset>" ] || [ "$burst" = "<unset>" ]; then
    fail "$label: start limit declared in [Unit]" \
         "StartLimitIntervalSec='$interval' StartLimitBurst='$burst' (must be in [Unit]; [Service] is silently ignored)"
  else
    pass "$label: start limit declared in [Unit]"
    local i r need
    i="$(seconds_of "$interval")"; r="$(seconds_of "$restartsec")"
    need=$(( r * burst ))
    if [ "$i" -gt "$need" ]; then
      pass "$label: start limit is reachable (${i}s > ${r}s x ${burst})"
    else
      fail "$label: start limit is reachable" \
           "interval ${i}s must exceed RestartSec ${r}s x burst ${burst} = ${need}s, else it can never trip"
    fi
  fi

  # Guard against the directives being parked in the wrong section.
  local stray_i stray_b
  stray_i="$(unit_directive "$manifest" "$service" "[Service]" "StartLimitIntervalSec")"
  stray_b="$(unit_directive "$manifest" "$service" "[Service]" "StartLimitBurst")"
  if [ "$stray_i" = "<unset>" ] && [ "$stray_b" = "<unset>" ]; then
    pass "$label: no start-limit directives stranded in [Service]"
  else
    fail "$label: no start-limit directives stranded in [Service]" \
         "found StartLimitIntervalSec='$stray_i' StartLimitBurst='$stray_b' in [Service] — systemd ignores these"
  fi
}

no_fetch_in_execstartpre "claude-tmux" "$CLAUDE_TMUX_MANIFEST"
no_fetch_in_execstartpre "dev-cell"    "$DEV_CELL_MANIFEST"

check_stager "claude-tmux/credential" "$CLAUDE_TMUX_MANIFEST" "credential"
check_stager "dev-cell/credential"    "$DEV_CELL_MANIFEST"    "credential"

check_gate "claude-tmux/claude" "$CLAUDE_TMUX_MANIFEST" "claude"   "/run/claude-tmux/api_key"
check_gate "dev-cell/executor"  "$DEV_CELL_MANIFEST"    "executor" "/run/dev-cell/api_key"

check_unit "claude-tmux/claude"      "$CLAUDE_TMUX_MANIFEST" "claude"
check_unit "claude-tmux/credential"  "$CLAUDE_TMUX_MANIFEST" "credential"
check_unit "dev-cell/executor"       "$DEV_CELL_MANIFEST"    "executor"
check_unit "dev-cell/credential"     "$DEV_CELL_MANIFEST"    "credential"

echo
printf 'passed: %d   failed: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
