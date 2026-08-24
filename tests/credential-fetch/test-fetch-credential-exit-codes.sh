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

mkdir -p "$WORK/pki" "$WORK/bin" "$WORK/run" "$WORK/home"
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
# CLAUDE_TMUX_CRED_HOME redirects the OAuth install target into the
# sandbox — same test seam as POWERNODE_PKI_DIR; systemd never sets it,
# so production always resolves the session user's real home via getent.
# WITHOUT it, the oauth cases below would write into the REAL
# ~/.claude/.credentials.json of whoever runs this suite.
run_fetch() {
  OUT="$(
    PATH="$WORK/bin:$PATH" \
    POWERNODE_PKI_DIR="$WORK/pki" \
    POWERNODE_PLATFORM_URL="https://platform.invalid" \
    RUNTIME_DIRECTORY="$WORK/run" \
    CLAUDE_TMUX_USER="$(id -un)" \
    CLAUDE_TMUX_CRED_HOME="$WORK/home" \
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

echo "== layer 1b: oauth credential kind (seed-once / node-authoritative) =="

# Obviously-fake tokens only. The response shape mirrors the node_api:
# data.credential_type discriminates, data.oauth_credentials is VERBATIM
# ~/.claude/.credentials.json content.
FAKE_RT="fake-oauth-refresh-token-for-harness"
OAUTH_BODY='{"data":{"credential_type":"oauth","oauth_credentials":{"claudeAiOauth":{"accessToken":"fake-oauth-access-token-for-harness","refreshToken":"'"$FAKE_RT"'","expiresAt":4102444800000,"refreshTokenExpiresAt":4102444800000,"scopes":["user:inference"],"subscriptionType":"max"}}}}'
CRED_JSON="$WORK/home/.claude/.credentials.json"

reset_oauth_state() { rm -rf "$WORK/home/.claude" "$WORK/run/oauth_ready" "$WORK/run/api_key"; }

# Fresh node, no local credential: the Vault seed is installed.
reset_oauth_state
run_fetch 200 "$OAUTH_BODY"
assert_eq "oauth: fresh node installs the seed (exit 0)" "0" "$RC"
if [ -f "$CRED_JSON" ]; then
  pass "oauth: installs ~/.claude/.credentials.json"
  assert_eq "oauth: credentials file is mode 0600" "600" "$(stat -c '%a' "$CRED_JSON")"
  assert_eq "oauth: .claude dir is mode 0700" "700" "$(stat -c '%a' "$WORK/home/.claude")"
  if jq -e --arg rt "$FAKE_RT" '.claudeAiOauth.refreshToken == $rt' "$CRED_JSON" >/dev/null 2>&1; then
    pass "oauth: installed file is the verbatim claudeAiOauth blob"
  else
    fail "oauth: installed file is the verbatim claudeAiOauth blob" "refreshToken mismatch or unparsable file"
  fi
else
  fail "oauth: installs ~/.claude/.credentials.json" "no file at $CRED_JSON"
  fail "oauth: credentials file is mode 0600" "no file to stat"
  fail "oauth: .claude dir is mode 0700" "no dir to stat"
  fail "oauth: installed file is the verbatim claudeAiOauth blob" "no file"
fi
[ -f "$WORK/run/oauth_ready" ] && pass "oauth: stages the oauth_ready marker"   || fail "oauth: stages the oauth_ready marker" "no marker at $WORK/run/oauth_ready"
[ ! -e "$WORK/run/api_key" ] && pass "oauth: does NOT stage an api_key file"   || fail "oauth: does NOT stage an api_key file" "unexpected $WORK/run/api_key"
case "$OUT" in
  *"$FAKE_RT"*|*fake-oauth-access-token-for-harness*)
    fail "oauth: tokens never appear in script output" "token leaked to stdout/stderr" ;;
  *) pass "oauth: tokens never appear in script output" ;;
esac

# SEED-ONCE: a usable local credential is NODE-AUTHORITATIVE — a re-fetch
# must NEVER overwrite it with the (by-design stale) Vault snapshot.
# This is the silent-weeks-later failure mode: Claude Code rotated the
# refresh token in place; clobbering the file with the seed kills the
# session.
printf '%s' '{"claudeAiOauth":{"accessToken":"fake-locally-refreshed-access","refreshToken":"fake-locally-refreshed-refresh","expiresAt":4102444800000}}' > "$CRED_JSON.want"
cp "$CRED_JSON.want" "$CRED_JSON"
chmod 600 "$CRED_JSON"
rm -f "$WORK/run/oauth_ready"
run_fetch 200 "$OAUTH_BODY"
assert_eq "oauth seed-once: exits 0 with a usable local credential" "0" "$RC"
if cmp -s "$CRED_JSON" "$CRED_JSON.want"; then
  pass "oauth seed-once: local file left byte-identical (never clobbered by the stale seed)"
else
  fail "oauth seed-once: local file left byte-identical (never clobbered by the stale seed)"        "the fetch overwrote a locally-refreshed credential"
fi
[ -f "$WORK/run/oauth_ready" ] && pass "oauth seed-once: still stages the marker so the session starts"   || fail "oauth seed-once: still stages the marker so the session starts" "no marker"
assert_contains "oauth seed-once: says it is leaving the local credential authoritative" "$OUT" "node-authoritative"
rm -f "$CRED_JSON.want"

# An UNUSABLE local file (no refreshToken) is not a credential — replace it.
printf '%s' '{"claudeAiOauth":{"accessToken":"fake-only-access-no-refresh"}}' > "$CRED_JSON"
rm -f "$WORK/run/oauth_ready"
run_fetch 200 "$OAUTH_BODY"
assert_eq "oauth: unusable local file is re-seeded (exit 0)" "0" "$RC"
if jq -e --arg rt "$FAKE_RT" '.claudeAiOauth.refreshToken == $rt' "$CRED_JSON" >/dev/null 2>&1; then
  pass "oauth: unusable local file was replaced by the seed"
else
  fail "oauth: unusable local file was replaced by the seed" "file not replaced"
fi

# A response declaring oauth but carrying no usable blob is a fault.
reset_oauth_state
run_fetch 200 '{"data":{"credential_type":"oauth","oauth_credentials":{"claudeAiOauth":{"accessToken":"fake-x"}}}}'
assert_eq "oauth: response without a refreshToken stays retryable (exit 1)" "1" "$RC"
[ ! -e "$CRED_JSON" ] && pass "oauth: no file installed from an unusable response"   || fail "oauth: no file installed from an unusable response" "unexpected $CRED_JSON"
[ ! -e "$WORK/run/oauth_ready" ] && pass "oauth: no marker staged from an unusable response"   || fail "oauth: no marker staged from an unusable response" "unexpected marker"

# NODE-AUTHORITATIVE CONTINUITY: with a usable LOCAL credential, the
# session must be able to start even when the platform cannot bless it —
# a control-plane outage (or a deleted platform row) must not take down
# the one session it cannot help anyway. The fetch degrades to staging
# the gate marker from the local file.
seed_local() {
  mkdir -p "$WORK/home/.claude"
  printf '%s' '{"claudeAiOauth":{"accessToken":"fake-local-a","refreshToken":"fake-local-r","expiresAt":4102444800000}}' > "$CRED_JSON"
  chmod 600 "$CRED_JSON"
  cp "$CRED_JSON" "$CRED_JSON.want"
}
check_local_survives() { # <label>
  assert_eq "$1: exits 0 on the local credential" "0" "$RC"
  [ -f "$WORK/run/oauth_ready" ] && pass "$1: stages the marker from the local credential"     || fail "$1: stages the marker from the local credential" "no marker"
  if cmp -s "$CRED_JSON" "$CRED_JSON.want"; then
    pass "$1: local file untouched"
  else
    fail "$1: local file untouched" "file changed"
  fi
}

reset_oauth_state; seed_local
run_fetch 404 ''
check_local_survives "oauth continuity/404 (deleted platform row does not revoke the node)"

reset_oauth_state; seed_local
run_fetch 000 '' 1
check_local_survives "oauth continuity/transport failure"

reset_oauth_state; seed_local
run_fetch 503 ''
check_local_survives "oauth continuity/HTTP 503"
rm -f "$CRED_JSON.want"

# And WITHOUT a local credential the taxonomy is unchanged (404 -> 78,
# faults -> 1) — re-asserted here because the continuity fallback sits in
# exactly those branches.
reset_oauth_state
run_fetch 404 ''
assert_eq "oauth continuity: 404 with no local credential still exits 78" "78" "$RC"
run_fetch 000 '' 1
assert_eq "oauth continuity: transport failure with no local credential still exits 1" "1" "$RC"

# Temp-file hygiene: no branch may leave the plaintext response (or a
# half-written install temp) behind — including the parse-failure exits.
reset_oauth_state
run_fetch 200 'not json at all'
[ ! -e "$WORK/run/.credential-response.json" ] && pass "hygiene: unparsable response leaves no response temp file"   || fail "hygiene: unparsable response leaves no response temp file" "found $WORK/run/.credential-response.json"
[ ! -e "$CRED_JSON.tmp" ] && pass "hygiene: no half-written credentials temp left behind"   || fail "hygiene: no half-written credentials temp left behind" "found $CRED_JSON.tmp"

# A home that does not exist must be REFUSED, never manufactured — a
# root-owned 0700 home chain would lock the session user out of their own
# home (prior fleet incident class).
reset_oauth_state
rmdir "$WORK/home" 2>/dev/null || rm -rf "$WORK/home"
run_fetch 200 "$OAUTH_BODY"
assert_eq "oauth: nonexistent home is refused (exit 1, retryable)" "1" "$RC"
[ ! -d "$WORK/home" ] && pass "oauth: home directory is never manufactured"   || fail "oauth: home directory is never manufactured" "script created $WORK/home"
mkdir -p "$WORK/home"

echo "== layer 1c: start script consumes the right credential shape =="

START_SCRIPT="$ROOT/modules/claude-tmux/rootfs/usr/local/bin/claude-tmux-start.sh"
TMUX_LOG="$WORK/tmux-calls.log"

# Stub tmux: has-session always says "no session"; every other call is
# recorded argv-verbatim so the send-keys payload can be asserted.
cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" = "has-session" ] && exit 1
done
printf '%s
' "$*" >> "${TMUX_LOG:?}"
exit 0
STUB
chmod +x "$WORK/bin/tmux"

run_start() { # -> RC / OUT / TMUX log
  : > "$TMUX_LOG"
  OUT="$(PATH="$WORK/bin:$PATH" RUNTIME_DIRECTORY="$WORK/run" TMUX_LOG="$TMUX_LOG" sh "$START_SCRIPT" 2>&1)"
  RC=$?
}

# api_key staged: byte-for-byte the original behaviour — export + delete.
reset_oauth_state
printf '%s' "sk-ant-test-not-a-real-key" > "$WORK/run/api_key"
run_start
assert_eq "start/api_key: exits 0" "0" "$RC"
assert_contains "start/api_key: pane exports ANTHROPIC_API_KEY" "$(cat "$TMUX_LOG")" "export ANTHROPIC_API_KEY"
assert_contains "start/api_key: pane deletes the staged key file" "$(cat "$TMUX_LOG")" "rm -f"

# oauth marker staged: claude reads ~/.claude/.credentials.json itself —
# the pane must NOT export ANTHROPIC_API_KEY (it would OVERRIDE the OAuth
# login) and must NOT delete anything (Claude Code rewrites the file on
# every token refresh; deleting it kills the session).
reset_oauth_state
: > "$WORK/run/oauth_ready"
run_start
assert_eq "start/oauth: exits 0" "0" "$RC"
assert_contains "start/oauth: pane execs claude" "$(cat "$TMUX_LOG")" "exec claude"
case "$(cat "$TMUX_LOG")" in
  *ANTHROPIC_API_KEY*) fail "start/oauth: never exports ANTHROPIC_API_KEY" "found in tmux argv" ;;
  *) pass "start/oauth: never exports ANTHROPIC_API_KEY" ;;
esac
case "$(cat "$TMUX_LOG")" in
  *"rm -f"*|*credentials.json*) fail "start/oauth: never deletes the credential file" "deletion found in tmux argv" ;;
  *) pass "start/oauth: never deletes the credential file" ;;
esac

# Neither staged: refuse to start.
reset_oauth_state
run_start
assert_eq "start/none: exits 1 with nothing staged" "1" "$RC"

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

# StartLimitBurst counts STARTS, not FAILURES. The stager has no
# RemainAfterExit, so the consumer pulls it afresh on every one of its own
# starts and those starts SUCCEED. If the stager's burst does not clear the
# consumer's, ordinary restarts exhaust it, systemd answers the next pull with
# "Start request repeated too quickly", and Requires= surfaces that on the
# consumer as "Dependency failed" — a self-inflicted outage from a limit that
# was only meant to bound a fetch loop. Observed on dev-cell 2026-08-17.
check_burst_headroom() { # <label> <manifest> <stager> <consumer>
  local label="$1" manifest="$2" stager="$3" consumer="$4" sb cb
  sb="$(unit_directive "$manifest" "$stager" "[Unit]" "StartLimitBurst")"
  cb="$(unit_directive "$manifest" "$consumer" "[Unit]" "StartLimitBurst")"
  if [ "$sb" = "<unset>" ] || [ "$cb" = "<unset>" ]; then
    fail "$label: stager burst clears consumer burst" "stager='$sb' consumer='$cb'"
  elif [ "$sb" -gt "$cb" ]; then
    pass "$label: stager burst clears consumer burst ($sb > $cb)"
  else
    fail "$label: stager burst clears consumer burst" \
         "stager burst $sb must exceed consumer burst $cb — each consumer start consumes one stager start"
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

# The claude unit is gated on EITHER staged shape — systemd's |-prefixed
# ConditionPathExists lines are OR'd together (plain ones stay AND'd), so
# both entries must carry the pipe or the unit would require BOTH files.
check_gate "claude-tmux/claude" "$CLAUDE_TMUX_MANIFEST" "claude"   "|/run/claude-tmux/api_key"
check_gate "claude-tmux/claude" "$CLAUDE_TMUX_MANIFEST" "claude"   "|/run/claude-tmux/oauth_ready"
check_gate "dev-cell/executor"  "$DEV_CELL_MANIFEST"    "executor" "/run/dev-cell/api_key"

check_burst_headroom "claude-tmux" "$CLAUDE_TMUX_MANIFEST" "credential" "claude"
check_burst_headroom "dev-cell"    "$DEV_CELL_MANIFEST"    "credential" "executor"

check_unit "claude-tmux/claude"      "$CLAUDE_TMUX_MANIFEST" "claude"
check_unit "claude-tmux/credential"  "$CLAUDE_TMUX_MANIFEST" "credential"
check_unit "dev-cell/executor"       "$DEV_CELL_MANIFEST"    "executor"
check_unit "dev-cell/credential"     "$DEV_CELL_MANIFEST"    "credential"

echo
printf 'passed: %d   failed: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
