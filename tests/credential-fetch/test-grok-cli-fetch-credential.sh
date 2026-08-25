#!/usr/bin/env bash
# test-grok-cli-fetch-credential.sh — regression suite for the grok-cli
# module's credential fetch, its systemd wiring, and the profile.d shim
# that is the only consumer of what it stages.
#
# Sibling of test-fetch-credential-exit-codes.sh (claude-tmux), and
# deliberately a SEPARATE file rather than more cases bolted onto that one:
# these two modules share a failure taxonomy but not a shape. claude-tmux
# hands its credential to a session it starts itself; grok-cli stages a file
# and lets a login shell pick it up. That difference is where this module's
# own bugs live, so it gets its own suite.
#
# Three layers:
#   1. Script exit taxonomy — 404 -> 78 (designed steady state), everything
#      else broken -> 1 (retryable), 200 -> 0 with a 0600 file.
#   2. The handoff to the login shell — the staged file must actually be
#      REACHABLE by the session user, and the profile.d shim must export it.
#      Layer 1 alone proves nothing here: a perfectly staged 0600 file inside
#      a root-owned 0700 directory is unreadable, and every symptom of that
#      is silent (the shim no-ops, `grok` just acts unauthenticated).
#   3. Manifest wiring — the unit must honour 78 via SuccessExitStatus, and
#      its start-limit hold-down must be REACHABLE and in [Unit].
#
# Usage: bash tests/credential-fetch/test-grok-cli-fetch-credential.sh
# Exit: non-zero if any assertion failed.

set -uo pipefail
# (deliberately NOT -e: a failed assertion must not abort the remaining
# cases — assert_* record failures instead of exiting.)

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$TEST_DIR/../.."
SCRIPT="$ROOT/modules/grok-cli/rootfs/usr/local/bin/grok-cli-fetch-credential.sh"
PROFILE_SHIM="$ROOT/modules/grok-cli/rootfs/etc/profile.d/grok-cli.sh"
MANIFEST="$ROOT/modules/grok-cli/manifest.yaml"

EX_CONFIG=78
FAKE_KEY="xai-test-not-a-real-key"

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
# Harness: a hermetic fake node (PKI dir + stub curl)
# ---------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/pki" "$WORK/bin" "$WORK/run"
: > "$WORK/pki/node.crt"
: > "$WORK/pki/node.key"
: > "$WORK/pki/ca-bundle.crt"

# Stub curl: honours -o <file> and -w, emits $STUB_HTTP_CODE, writes
# $STUB_BODY to the -o target, and fails transport-style when
# $STUB_TRANSPORT_FAIL=1. It also RECORDS its argv so the request URL can
# be asserted — a fetch script pointed at the wrong provider would pass
# every exit-code case in this file while staging another module's key.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
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

CURL_LOG="$WORK/curl-calls.log"

# run_fetch <http_code> <body> [transport_fail] -> sets RC / OUT
# POWERNODE_PKI_DIR is the test seam that lets this run off an enrolled
# node; systemd never sets it, so production always takes the absolute-path
# chain. GROK_CLI_USER is set to the invoking user so the script's chown
# calls are no-ops rather than requiring root.
run_fetch() {
  : > "$CURL_LOG"
  rm -rf "$WORK/run"
  mkdir -p "$WORK/run"
  OUT="$(
    PATH="$WORK/bin:$PATH" \
    CURL_LOG="$CURL_LOG" \
    POWERNODE_PKI_DIR="$WORK/pki" \
    POWERNODE_PLATFORM_URL="https://platform.invalid" \
    RUNTIME_DIRECTORY="$WORK/run" \
    GROK_CLI_USER="$(id -un)" \
    STUB_HTTP_CODE="$1" \
    STUB_BODY="$2" \
    STUB_TRANSPORT_FAIL="${3:-0}" \
    sh "$SCRIPT" 2>&1
  )"
  RC=$?
}

echo "== layer 1: script exit taxonomy =="

# THE DESIGNED STEADY STATE. An uncredentialed instance is intended (the
# account-provider fallback defaults OFF so an idle cell cannot burn API
# credits), so it must be distinguishable from a transient fault — the
# claude-tmux incident of 2026-08-17 was exactly this conflation producing
# 243 restarts in 21 minutes.
run_fetch 404 ''
assert_eq "HTTP 404 (no credential configured) exits EX_CONFIG=$EX_CONFIG" "$EX_CONFIG" "$RC"
assert_contains "HTTP 404 explains an operator must set one" "$OUT" "operator must set one"

run_fetch 500 ''
assert_eq "HTTP 500 stays retryable (exit 1)" "1" "$RC"

run_fetch 503 ''
assert_eq "HTTP 503 stays retryable (exit 1)" "1" "$RC"

run_fetch 000 '' 1
assert_eq "transport/mTLS failure stays retryable (exit 1)" "1" "$RC"

run_fetch 200 '{"data":{"not_the_key":"x"}}'
assert_eq "200 with no api_key field stays retryable (exit 1)" "1" "$RC"

run_fetch 200 'not json at all'
assert_eq "200 with an unparsable body stays retryable (exit 1)" "1" "$RC"

run_fetch 200 '{"data":{"api_key":""}}'
assert_eq "200 with an EMPTY api_key stays retryable (exit 1)" "1" "$RC"

# An oauth-kind response is a platform/module skew, not something to
# half-apply: xAI has no oauth shape, and staging its payload as an api_key
# would write a JSON blob where a bearer token belongs.
run_fetch 200 '{"data":{"credential_type":"oauth","oauth_credentials":{}}}'
assert_eq "an oauth-kind response is refused, not mis-staged (exit 1)" "1" "$RC"
[ ! -e "$WORK/run/api_key" ] \
  && pass "an oauth-kind response stages nothing" \
  || fail "an oauth-kind response stages nothing" "unexpected $WORK/run/api_key"

# Happy path.
run_fetch 200 "{\"data\":{\"api_key\":\"$FAKE_KEY\",\"credential_type\":\"api_key\"}}"
assert_eq "200 with api_key succeeds (exit 0)" "0" "$RC"
if [ -f "$WORK/run/api_key" ]; then
  pass "200 stages the credential file"
  assert_eq "staged credential is mode 0600" "600" "$(stat -c '%a' "$WORK/run/api_key")"
  assert_eq "staged credential is the key VERBATIM (no trailing newline)" \
    "$FAKE_KEY" "$(cat "$WORK/run/api_key")"
else
  fail "200 stages the credential file" "no file at $WORK/run/api_key"
  fail "staged credential is mode 0600" "no file to stat"
  fail "staged credential is the key VERBATIM (no trailing newline)" "no file to read"
fi

# The key must never be echoed — the script logs, and this suite captures
# stderr, so assert the captured output cannot leak it.
case "$OUT" in
  *"$FAKE_KEY"*) fail "credential never appears in script output" "key leaked to stdout/stderr" ;;
  *) pass "credential never appears in script output" ;;
esac

# It must ask for ITS OWN provider. Without this, a copy-paste from the
# claude-tmux script would stage the Anthropic key into /run/grok-cli and
# every other assertion here would still pass.
assert_contains "fetch targets the provider-general endpoint" \
  "$(cat "$CURL_LOG")" "config/ai_cli_credential"
assert_contains "fetch asks for provider_type=grok" \
  "$(cat "$CURL_LOG")" "provider_type=grok"

# Hygiene: no branch may leave the plaintext response, or a half-written
# staging temp, behind.
run_fetch 200 'not json at all'
[ ! -e "$WORK/run/.credential-response.json" ] \
  && pass "hygiene: unparsable response leaves no response temp file" \
  || fail "hygiene: unparsable response leaves no response temp file" "found the temp file"
[ ! -e "$WORK/run/api_key.tmp" ] \
  && pass "hygiene: no half-written staging temp left behind" \
  || fail "hygiene: no half-written staging temp left behind" "found api_key.tmp"

# A revoked credential must not stay readable on the node until the next
# success — the script clears the staged file BEFORE it fetches.
run_fetch 200 "{\"data\":{\"api_key\":\"$FAKE_KEY\"}}"
run_fetch 404 ''
[ ! -e "$WORK/run/api_key" ] \
  && pass "a 404 after a success clears the previously staged key" \
  || fail "a 404 after a success clears the previously staged key" "stale key still readable"

echo "== layer 2: the handoff to the login shell =="

# The staged file is useless if the session user cannot TRAVERSE the
# directory holding it. systemd's RuntimeDirectory= creates it root:root
# 0700; the script must hand it over. Every symptom of getting this wrong is
# silent, which is exactly why it is asserted rather than assumed.
run_fetch 200 "{\"data\":{\"api_key\":\"$FAKE_KEY\"}}"
assert_eq "runtime directory is owned by the session user" \
  "$(id -un)" "$(stat -c '%U' "$WORK/run")"
assert_eq "runtime directory stays 0700 (no other user may enumerate it)" \
  "700" "$(stat -c '%a' "$WORK/run")"

# The shim itself. It runs SOURCED in the caller's shell, so it must never
# exit, never `set -e`, and never write to stdout (profile.d output corrupts
# scp/rsync). Asserted by sourcing it exactly the way /etc/profile does.
run_shim() { # -> SHIM_KEY / SHIM_STDOUT (reads whatever is staged in $WORK/run)
  SHIM_STDOUT="$(
    RUN_DIR="$WORK/run" sh -c '
      # Rewrite the shim'"'"'s absolute path onto the sandbox, then source it
      # exactly as a login shell would.
      sed "s#/run/grok-cli#$RUN_DIR#g" "$1" > "$RUN_DIR/shim.sh"
      unset XAI_API_KEY
      . "$RUN_DIR/shim.sh"
      printf "KEY=%s\n" "${XAI_API_KEY:-<unset>}" >&2
      exit 0
    ' _ "$PROFILE_SHIM" 2>"$WORK/shim.err"
  )"
  SHIM_KEY="$(sed -n 's/^KEY=//p' "$WORK/shim.err")"
}

run_shim
assert_eq "shim exports the staged key as XAI_API_KEY" "$FAKE_KEY" "$SHIM_KEY"
assert_eq "shim writes NOTHING to stdout (would corrupt scp/rsync)" "" "$SHIM_STDOUT"

# No staged key: a silent no-op, NOT an empty export. An empty XAI_API_KEY
# makes the CLI fail with an auth error instead of the clearer "no key set".
rm -f "$WORK/run/api_key"
run_shim
assert_eq "shim leaves XAI_API_KEY unset when nothing is staged" "<unset>" "$SHIM_KEY"
assert_eq "shim writes nothing to stdout on the no-op path" "" "$SHIM_STDOUT"

# An empty staged file must also leave the variable unset.
: > "$WORK/run/api_key"
run_shim
assert_eq "shim leaves XAI_API_KEY unset for an EMPTY staged file" "<unset>" "$SHIM_KEY"

echo "== layer 3: manifest wiring =="

# unit_directive <manifest> <service> <section> <key>
# Extracts a directive from the named service's unit_body. Mirrors the
# helper in the claude-tmux suite; kept local so this file stands alone.
unit_directive() {
  python3 - "$@" <<'PY'
import sys, yaml
manifest, service, section, key = sys.argv[1:5]
doc = yaml.safe_load(open(manifest))
body = ""
for svc in doc.get("services") or []:
    if svc.get("name") == service:
        body = svc.get("unit_body") or ""
cur = None
for line in body.splitlines():
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        cur = s
        continue
    if cur == section and s.startswith(key + "="):
        print(s.split("=", 1)[1])
        sys.exit(0)
print("<unset>")
PY
}

seconds_of() { # 30s / 1800 -> integer seconds
  case "$1" in
    *s) echo "${1%s}" ;;
    *)  echo "$1" ;;
  esac
}

# The whole point of exit 78: without SuccessExitStatus at the far end,
# the designed steady state is still an infinite restart loop.
assert_eq "credential unit maps 78 to success" \
  "78" "$(unit_directive "$MANIFEST" credential '[Service]' SuccessExitStatus)"

# RestartPreventExitStatus is the WRONG mechanism here and its presence
# would signal a misunderstanding — asserted absent for the same reason the
# claude-tmux suite asserts it.
assert_eq "credential unit does NOT use RestartPreventExitStatus" \
  "<unset>" "$(unit_directive "$MANIFEST" credential '[Service]' RestartPreventExitStatus)"

assert_eq "credential unit retries genuine faults" \
  "on-failure" "$(unit_directive "$MANIFEST" credential '[Service]' Restart)"

# The runtime directory must survive the oneshot's own exit — the profile.d
# shim reads it long afterwards, and an auto-removed RuntimeDirectory would
# take the credential with it the moment the unit went inactive.
assert_eq "runtime directory is preserved past the oneshot's exit" \
  "yes" "$(unit_directive "$MANIFEST" credential '[Service]' RuntimeDirectoryPreserve)"

# Start-limit directives are SILENTLY IGNORED in [Service].
INTERVAL="$(unit_directive "$MANIFEST" credential '[Unit]' StartLimitIntervalSec)"
BURST="$(unit_directive "$MANIFEST" credential '[Unit]' StartLimitBurst)"
RESTARTSEC="$(unit_directive "$MANIFEST" credential '[Service]' RestartSec)"

if [ "$INTERVAL" = "<unset>" ] || [ "$BURST" = "<unset>" ]; then
  fail "start limit declared in [Unit]" \
       "StartLimitIntervalSec='$INTERVAL' StartLimitBurst='$BURST' (must be in [Unit])"
else
  pass "start limit declared in [Unit]"
  I="$(seconds_of "$INTERVAL")"; R="$(seconds_of "$RESTARTSEC")"
  NEED=$(( R * BURST ))
  if [ "$I" -gt "$NEED" ]; then
    pass "start limit is reachable (${I}s > ${R}s x ${BURST})"
  else
    fail "start limit is reachable" \
         "interval ${I}s must exceed RestartSec ${R}s x burst ${BURST} = ${NEED}s, else it can never trip"
  fi
fi

STRAY_I="$(unit_directive "$MANIFEST" credential '[Service]' StartLimitIntervalSec)"
STRAY_B="$(unit_directive "$MANIFEST" credential '[Service]' StartLimitBurst)"
if [ "$STRAY_I" = "<unset>" ] && [ "$STRAY_B" = "<unset>" ]; then
  pass "no start-limit directives stranded in [Service]"
else
  fail "no start-limit directives stranded in [Service]" \
       "found StartLimitIntervalSec='$STRAY_I' StartLimitBurst='$STRAY_B' in [Service]"
fi

# The CLI must be declared as egress-allowed to its own API host. An empty
# egress_allow is not "no policy" — the agent unions these into a node-wide
# DEFAULT-DENY chain, so shipping the CLI without its host guarantees it can
# never work (observed on ops-cell 2026-07-29 for api.anthropic.com).
if python3 -c "
import sys, yaml
doc = yaml.safe_load(open('$MANIFEST'))
sys.exit(0 if 'api.x.ai' in ((doc.get('security') or {}).get('egress_allow') or []) else 1)
"; then
  pass "manifest allows egress to api.x.ai"
else
  fail "manifest allows egress to api.x.ai" \
       "security.egress_allow must name the API host or every grok call fails closed"
fi

echo
printf 'passed: %d   failed: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
