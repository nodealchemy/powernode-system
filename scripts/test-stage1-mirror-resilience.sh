#!/usr/bin/env bash
# test-stage1-mirror-resilience.sh — stubbed-command harness for the mirror
# probe / retry / cache behaviour of scripts/module-build/stage1-rootfs.sh.
# Mirrors the shape of test-compute-build-inputs-hash.sh: drive the REAL
# script with curl/mmdebstrap/dpkg-query/sleep/date replaced by PATH stubs,
# then assert what it did (which commands ran, how many times, with which
# arguments, how long it "waited", and what it said when it gave up).
#
# The properties under test are the ones the deploy pipeline rests on:
#   - a flapping mirror is WAITED OUT, not failed on the first 5xx;
#   - a dead mirror fails within the wait budget, naming the URL + last code;
#   - a failed mmdebstrap is retried only on a transient-mirror signature;
#   - the apt_snapshot pin is never replaced by archive.ubuntu.com;
#   - the opt-in cache seeds before, harvests after, and is OFF by default.
#
# stage1-rootfs.sh writes to hardcoded /tmp/* paths (its shared-/tmp
# contract), so this harness re-executes itself under `unshare -rm` with a
# private tmpfs on /tmp when that works, and otherwise refuses to run if a
# real /tmp/fat exists. Time is virtual: the `sleep` stub advances a fake
# clock the `date +%s` stub reads, so backoff is asserted, not endured.
#
# Usage: bash scripts/test-stage1-mirror-resilience.sh
# Exit codes: 0 = all pass, non-zero = failure count

# shellcheck disable=SC2016  # stub bodies and the unshare re-exec are deliberately single-quoted: they must reach sh unexpanded
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE1="$SCRIPT_DIR/module-build/stage1-rootfs.sh"

# --- private /tmp when possible ------------------------------------------
if [ -z "${STAGE1_TEST_INNER:-}" ]; then
  if unshare -rm true 2>/dev/null; then
    export STAGE1_TEST_INNER=1
    # Private tmpfs /tmp AND a scratch copy bind-mounted over /etc/hosts, so
    # the in-place backend-pin fallback under test can never touch the real one.
    exec unshare -rm bash -c 'mount -t tmpfs tmpfs /tmp && cp /etc/hosts /tmp/hosts.harness && mount --bind /tmp/hosts.harness /etc/hosts && exec bash "$0" "$@"' "$0" "$@"
  fi
  if [ -e /tmp/fat ]; then
    echo "refusing to run: /tmp/fat exists and unshare -rm is unavailable (stage1-rootfs.sh uses hardcoded /tmp/* paths)" >&2
    exit 99
  fi
  echo "NOTE: unshare -rm unavailable — backend-pin cases are skipped (they need a private /etc/hosts)" >&2
  PIN_TESTS=0
fi
PIN_TESTS="${PIN_TESTS:-1}"

failures=0
tmproot=""
# shellcheck disable=SC2317  # invoked via the EXIT trap
cleanup() {
  [ -n "$tmproot" ] && rm -rf "$tmproot"
  rm -rf /tmp/fat /tmp/hooks /tmp/package_spec.txt /tmp/stage1-mmdebstrap.log \
         /tmp/stage1-apt-cache-seed.sh /tmp/stage1-apt-cache-harvest.sh /tmp/stage1-selftest.packages.txt
  rm -rf /tmp/stage1-apt-cache
}
trap cleanup EXIT

pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; failures=$((failures + 1)); }
assert_eq() {
  local expected="$1" actual="$2" what="$3"
  if [ "$expected" = "$actual" ]; then pass "$what"; else fail "$what (expected '$expected', got '$actual')"; fi
}
assert_match() {
  local pattern="$1" text="$2" what="$3"
  if grep -qE -- "$pattern" <<<"$text"; then pass "$what"; else fail "$what (no match for /$pattern/ in: $(head -c 400 <<<"$text"))"; fi
}
assert_no_match() {
  local pattern="$1" text="$2" what="$3"
  if grep -qE -- "$pattern" <<<"$text"; then fail "$what (unexpected match for /$pattern/)"; else pass "$what"; fi
}

# --- stubs -----------------------------------------------------------------
tmproot=$(mktemp -d)
STUBS="$tmproot/stubs"; mkdir -p "$STUBS"
REAL_DATE=$(command -v date)
export REAL_DATE
export FAKE_CLOCK="$tmproot/clock" SLEEP_LOG="$tmproot/sleeps" CURL_CODES="$tmproot/curl-codes" \
       CURL_LOG="$tmproot/curl-urls" MM_OUTCOMES="$tmproot/mm-outcomes" MM_LOG="$tmproot/mm-calls" \
       MM_ARCHIVES_SEEN="$tmproot/mm-archives-seen" GETENT_ADDRS="$tmproot/getent-addrs" \
       CURL_IP_CODES="$tmproot/curl-ip-codes" MM_HOSTS_SEEN="$tmproot/mm-hosts-seen"

write_stub() { printf '%s\n' "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }

write_stub date '#!/bin/sh
if [ "${1:-}" = "+%s" ]; then cat "$FAKE_CLOCK"; else exec "$REAL_DATE" "$@"; fi'

write_stub sleep '#!/bin/sh
now=$(cat "$FAKE_CLOCK"); echo $((now + $1)) > "$FAKE_CLOCK"; echo "$1" >> "$SLEEP_LOG"'

# curl: pops one HTTP code per call from $CURL_CODES (the last line repeats
# forever); records the URL (last argument).
# getent ahosts HOST: one address per line from $GETENT_ADDRS (empty = no addresses).
write_stub getent '#!/bin/sh
[ -s "$GETENT_ADDRS" ] || exit 2
while read -r a; do printf "%s STREAM %s\n" "$a" "$2"; done < "$GETENT_ADDRS"'

# curl: with --resolve host:port:ADDR, pops ADDR'"'"'s next code from $CURL_IP_CODES
# (lines "addr code[,code...]", last code repeats) and logs "resolve=ADDR URL";
# otherwise pops one code per call from $CURL_CODES (last line repeats).
write_stub curl '#!/bin/sh
url=""; resolve=""; prev=""
for a in "$@"; do [ "$prev" = "--resolve" ] && resolve="$a"; prev="$a"; url="$a"; done
if [ -n "$resolve" ]; then
  addr=${resolve##*:}; addr=${addr#[}; addr=${addr%]}
  echo "resolve=$addr $url" >> "$CURL_LOG"
  line=$(grep "^$addr " "$CURL_IP_CODES"); codes=${line#* }
  code=${codes%%,*}; rest=${codes#*,}
  grep -v "^$addr " "$CURL_IP_CODES" > "$CURL_IP_CODES.n"; echo "$addr $rest" >> "$CURL_IP_CODES.n"; mv "$CURL_IP_CODES.n" "$CURL_IP_CODES"
  printf "%s" "$code"; exit 0
fi
echo "$url" >> "$CURL_LOG"
code=$(head -n1 "$CURL_CODES")
if [ "$(wc -l < "$CURL_CODES")" -gt 1 ]; then tail -n +2 "$CURL_CODES" > "$CURL_CODES.n" && mv "$CURL_CODES.n" "$CURL_CODES"; fi
printf "%s" "$code"'

# mmdebstrap: pops one outcome per call from $MM_OUTCOMES (ok | transient |
# fatal), records its argv, and for "ok" runs any --setup-hook/--customize-hook
# it was given exactly the way mmdebstrap does (host side, chroot dir as $1),
# "downloading" one new .deb in between.
write_stub mmdebstrap '#!/bin/sh
printf "%s\n" "$*" >> "$MM_LOG"
{ grep -E "snapshot(-mirror)?\." /etc/hosts 2>/dev/null || echo "(no pin)"; } >> "$MM_HOSTS_SEEN"
outcome=$(head -n1 "$MM_OUTCOMES")
if [ "$(wc -l < "$MM_OUTCOMES")" -gt 1 ]; then tail -n +2 "$MM_OUTCOMES" > "$MM_OUTCOMES.n" && mv "$MM_OUTCOMES.n" "$MM_OUTCOMES"; fi
[ -e /tmp/fat ] && [ -n "$(ls -A /tmp/fat 2>/dev/null)" ] && { echo "E: /tmp/fat is not empty"; exit 1; }
case "$outcome" in
  ok)
    setup=""; customize=""
    for a in "$@"; do case "$a" in --setup-hook=*) setup=${a#--setup-hook=};; --customize-hook=*) customize=${a#--customize-hook=};; esac; done
    mkdir -p /tmp/fat/var/lib/dpkg /tmp/fat/var/cache/apt/archives
    [ -n "$setup" ] && "$setup" /tmp/fat
    ls /tmp/fat/var/cache/apt/archives > "$MM_ARCHIVES_SEEN"
    echo fetched > /tmp/fat/var/cache/apt/archives/newpkg_2.0_amd64.deb
    [ -n "$customize" ] && "$customize" /tmp/fat
    rm -f /tmp/fat/var/cache/apt/archives/*.deb
    echo "I: success"; exit 0 ;;
  transient)
    # apt got one .deb through (hash-verified, moved out of partial/) and
    # was mid-way through another when the mirror died.
    mkdir -p /tmp/fat/partial /tmp/fat/var/cache/apt/archives/partial
    setup=""
    for a in "$@"; do case "$a" in --setup-hook=*) setup=${a#--setup-hook=};; esac; done
    [ -n "$setup" ] && "$setup" /tmp/fat
    ls /tmp/fat/var/cache/apt/archives > "$MM_ARCHIVES_SEEN"
    echo partial-fetched > /tmp/fat/var/cache/apt/archives/resumed_1.0_amd64.deb
    echo half > /tmp/fat/var/cache/apt/archives/partial/half_0.1_amd64.deb
    echo "Err:1 https://snapshot.invalid/ubuntu/20260415T000000Z noble InRelease"
    echo "  503 Service Unavailable [IP: 0.0.0.0 443]"
    echo "E: apt-get update --error-on=any -oAPT::Status-Fd=<\$fd> ... failed: process exited with 100"
    echo "E: mmdebstrap failed to run"; exit 1 ;;
  fatal)
    mkdir -p /tmp/fat/partial
    echo "E: Unable to locate package no-such-package-xyz"
    echo "E: mmdebstrap failed to run"; exit 1 ;;
  *) echo "stub: unknown outcome $outcome"; exit 97 ;;
esac'

write_stub dpkg-query '#!/bin/sh
printf "ca-certificates\t20240203\tall\n"'

# run_stage1 "<curl codes, space-separated>" "<mmdebstrap outcomes>" [ENV=VAL ...]
# Sets STAGE1_MIRROR_WAIT_MAX=100 unless overridden. Captures output + rc.
OUT=""; RC=0
run_stage1() {
  local codes="$1" outcomes="$2"; shift 2
  rm -rf /tmp/fat /tmp/stage1-mmdebstrap.log /tmp/stage1-apt-cache-*.sh /tmp/stage1-apt-cache
  echo 1000 > "$FAKE_CLOCK"; : > "$SLEEP_LOG"; : > "$CURL_LOG"; : > "$MM_LOG"; : > "$MM_ARCHIVES_SEEN"; : > "$MM_HOSTS_SEEN"
  [ -n "${KEEP_BACKENDS:-}" ] || { : > "$GETENT_ADDRS"; : > "$CURL_IP_CODES"; }
  # shellcheck disable=SC2086  # intentional word-splitting: one line per space-separated code/outcome
  printf '%s\n' $codes > "$CURL_CODES"
  # shellcheck disable=SC2086
  printf '%s\n' $outcomes > "$MM_OUTCOMES"
  printf 'jq\ncurl\n' > /tmp/package_spec.txt
  set +e
  OUT=$(env -i PATH="$STUBS:/usr/bin:/bin" HOME="$tmproot" \
        REAL_DATE="$REAL_DATE" FAKE_CLOCK="$FAKE_CLOCK" SLEEP_LOG="$SLEEP_LOG" CURL_CODES="$CURL_CODES" \
        CURL_LOG="$CURL_LOG" MM_OUTCOMES="$MM_OUTCOMES" MM_LOG="$MM_LOG" MM_ARCHIVES_SEEN="$MM_ARCHIVES_SEEN" \
        GETENT_ADDRS="$GETENT_ADDRS" CURL_IP_CODES="$CURL_IP_CODES" MM_HOSTS_SEEN="$MM_HOSTS_SEEN" \
        STAGE1_MIRROR_WAIT_MAX=100 STAGE1_RETRY_PAUSE=0 "$@" \
        bash "$STAGE1" --module stage1-selftest --apt-snapshot 20260415T000000Z 2>&1)
  RC=$?
  set -e
}
mm_calls() { wc -l < "$MM_LOG" | tr -d ' '; }
sleeps()   { tr '\n' ' ' < "$SLEEP_LOG" | sed 's/ $//'; }
set -e

echo "stage1-rootfs.sh mirror resilience"

# --- 1. healthy mirror: unchanged fast path ---------------------------------
run_stage1 "200" "ok"
assert_eq 0 "$RC" "healthy mirror -> exit 0"
assert_eq 1 "$(mm_calls)" "healthy mirror -> mmdebstrap runs exactly once"
assert_eq "" "$(sleeps)" "healthy mirror -> no waiting"
assert_match 'https://snapshot\.ubuntu\.com/ubuntu/20260415T000000Z/dists/noble/InRelease' "$(cat "$CURL_LOG")" "probe targets the pinned snapshot's InRelease"
assert_match ' noble /tmp/fat https://snapshot\.ubuntu\.com/ubuntu/20260415T000000Z/$' "$(cat "$MM_LOG")" "mmdebstrap base_url is the pinned snapshot"
assert_match '--include=ca-certificates,jq,curl ' "$(cat "$MM_LOG")" "package_spec still drives --include"
assert_match "--aptopt=Acquire::Retries \"10\"" "$(cat "$MM_LOG")" "apt transport retries enabled (default 10)"
assert_match "--aptopt=Acquire::http::Timeout \"30\"" "$(cat "$MM_LOG")" "apt transport timeout bounded (default 30s)"
assert_no_match '--setup-hook|--customize-hook|--skip=' "$(cat "$MM_LOG")" "no cache hooks by default"
assert_eq "ca-certificates	20240203	all" "$(cat /tmp/stage1-selftest.packages.txt)" "provenance capture unchanged"

# --- 2. flapping mirror: waited out with backoff ----------------------------
run_stage1 "503 502 000 200" "ok"
assert_eq 0 "$RC" "flapping mirror -> eventually exit 0"
assert_eq "5 10 20" "$(sleeps)" "flapping mirror -> exponential backoff 5,10,20"
assert_eq 1 "$(mm_calls)" "flapping mirror -> mmdebstrap runs once, after the mirror recovers"
assert_match 'mirror probe: 503 .* transient' "$OUT" "transient probe codes are logged as such"

# --- 3. dead mirror: bounded, clear failure ---------------------------------
run_stage1 "503" "ok"
assert_eq 2 "$RC" "dead mirror -> exit 2"
assert_eq 0 "$(mm_calls)" "dead mirror -> mmdebstrap never runs"
total=0; for s in $(sleeps); do total=$((total + s)); done
assert_eq 100 "$total" "dead mirror -> total wait equals STAGE1_MIRROR_WAIT_MAX exactly"
assert_match 'still unhealthy after 100s .*last result: 503' "$OUT" "failure names the wait budget and last HTTP code"
assert_match 'snapshot\.ubuntu\.com/ubuntu/20260415T000000Z/dists/noble/InRelease' "$OUT" "failure names the mirror URL"

# --- 4. non-transient probe code fails immediately --------------------------
run_stage1 "404" "ok"
assert_eq 2 "$RC" "404 on InRelease -> exit 2"
assert_eq "" "$(sleeps)" "404 on InRelease -> no waiting"
assert_match 'HTTP 404 .* not a transient error' "$OUT" "404 is reported as non-transient"

# --- 5. transient mmdebstrap failure is retried (partial /tmp/fat cleared) --
run_stage1 "200" "transient ok"
assert_eq 0 "$RC" "transient mmdebstrap failure -> retried to success"
assert_eq 2 "$(mm_calls)" "transient mmdebstrap failure -> two mmdebstrap runs"
assert_match 'attempt 1 failed .*transient-mirror signature' "$OUT" "retry reason is logged"
assert_match 'succeeded on attempt 2' "$OUT" "success attempt is logged"

# --- 5b. a retry resumes from the .debs the failed run already fetched -----
assert_no_match '--setup-hook' "$(sed -n 1p "$MM_LOG")" "first run: historical command line, no cache hook"
assert_match '^--setup-hook=/tmp/stage1-apt-cache-seed\.sh ' "$(sed -n 2p "$MM_LOG")" "retry: seeded from the job-local resume cache"
assert_no_match '--customize-hook|--skip=' "$(sed -n 2p "$MM_LOG")" "retry: harvest is host-side, no customize hook without a persistent cache"
assert_match 'apt cache: harvested 1 new \.deb\(s\) into /tmp/stage1-apt-cache/archives' "$OUT" "completed .deb harvested after the transient failure"
assert_match 'resumed_1\.0_amd64\.deb' "$(cat "$MM_ARCHIVES_SEEN")" "retry found the harvested .deb in its apt archive dir"
assert_eq "absent" "$([ -e /tmp/stage1-apt-cache/archives/half_0.1_amd64.deb ] && echo present || echo absent)" "a half-downloaded file in partial/ is never harvested"
assert_match 'retry resumes from the \.deb\(s\) harvested into /tmp/stage1-apt-cache/archives' "$OUT" "resume is logged"
assert_match "--aptopt=Acquire::http::Timeout \"12\"" "$(run_stage1 "200" "ok" STAGE1_APT_TIMEOUT=12; cat "$MM_LOG")" "STAGE1_APT_TIMEOUT overrides the apt timeout"

# --- 6. deterministic mmdebstrap failure is NOT retried ---------------------
run_stage1 "200" "fatal ok"
assert_eq 2 "$RC" "deterministic mmdebstrap failure -> exit 2"
assert_eq 1 "$(mm_calls)" "deterministic mmdebstrap failure -> exactly one run"
assert_match 'no transient-mirror signature .* not retrying' "$OUT" "non-retry reason is logged"

# --- 7. attempts are bounded ------------------------------------------------
run_stage1 "200" "transient transient transient ok" STAGE1_MMDEBSTRAP_ATTEMPTS=2
assert_eq 2 "$RC" "attempts exhausted -> exit 2"
assert_eq 2 "$(mm_calls)" "attempts exhausted -> exactly STAGE1_MMDEBSTRAP_ATTEMPTS runs"
assert_match 'failed 2 times against https://snapshot\.ubuntu\.com/ubuntu/20260415T000000Z/' "$OUT" "exhaustion names the mirror"

# --- 7b. paced pause before each retry (default 30s x attempt; 0 in this harness) ---
run_stage1 "200" "transient transient ok" STAGE1_MMDEBSTRAP_ATTEMPTS=3 STAGE1_RETRY_PAUSE=7
assert_eq 0 "$RC" "paced retries -> eventually exit 0"
assert_eq 3 "$(mm_calls)" "paced retries -> three mmdebstrap runs"
assert_eq "7 14" "$(sleeps)" "pause grows with the attempt number (7s, then 14s)"
assert_match 'pausing 7s, then re-probing' "$OUT" "pause is logged with its length"
run_stage1 "200" "transient transient transient ok" STAGE1_MMDEBSTRAP_ATTEMPTS=4 STAGE1_RETRY_PAUSE=60 STAGE1_MIRROR_WAIT_MAX=70
assert_eq 2 "$RC" "pause consumes the shared wait budget -> deadline still bounds the stage"
assert_eq "60 10" "$(sleeps)" "pause is clamped to the remaining budget, then the deadline fails the stage"
assert_match 'wait budget is exhausted' "$OUT" "exhaustion via pause is named"

# --- 8. alternate snapshot base: opt-in, live mirrors refused ---------------
run_stage1 "200" "ok" STAGE1_SNAPSHOT_BASE_URL=https://snapshot-mirror.example.test/ubuntu
assert_eq 0 "$RC" "alternate snapshot base -> exit 0"
assert_match 'https://snapshot-mirror\.example\.test/ubuntu/20260415T000000Z/dists/noble/InRelease' "$(cat "$CURL_LOG")" "alternate base is probed with the SAME snapshot timestamp"
assert_match ' /tmp/fat https://snapshot-mirror\.example\.test/ubuntu/20260415T000000Z/$' "$(cat "$MM_LOG")" "alternate base reaches mmdebstrap with the pin intact"
assert_match 'STAGE1_SNAPSHOT_BASE_URL is set' "$OUT" "alternate base use is announced"

run_stage1 "200" "ok" STAGE1_SNAPSHOT_BASE_URL=http://archive.ubuntu.com/ubuntu
assert_eq 2 "$RC" "archive.ubuntu.com as snapshot base -> refused"
assert_eq 0 "$(mm_calls)" "archive.ubuntu.com as snapshot base -> mmdebstrap never runs"
assert_match 'live rolling mirror' "$OUT" "refusal explains why"

# --- 9. opt-in apt cache: seed before, harvest after -----------------------
CACHE="$tmproot/apt-cache"
mkdir -p "$CACHE/20260415T000000Z/archives"
echo cached > "$CACHE/20260415T000000Z/archives/oldpkg_1.0_amd64.deb"
run_stage1 "200" "ok" STAGE1_APT_CACHE_DIR="$CACHE"
assert_eq 0 "$RC" "cache enabled -> exit 0"
assert_match '--skip=essential/unlink --setup-hook=/tmp/stage1-apt-cache-seed.sh --customize-hook=/tmp/stage1-apt-cache-harvest.sh' "$(cat "$MM_LOG")" "cache hooks passed to mmdebstrap"
assert_match 'oldpkg_1.0_amd64.deb' "$(cat "$MM_ARCHIVES_SEEN")" "cached .deb was seeded into the chroot's apt archives before fetching"
assert_eq "fetched" "$(cat "$CACHE/20260415T000000Z/archives/newpkg_2.0_amd64.deb" 2>/dev/null)" "newly fetched .deb was harvested into the cache"
assert_eq "cached" "$(cat "$CACHE/20260415T000000Z/archives/oldpkg_1.0_amd64.deb")" "pre-existing cache entry left untouched"
assert_match 'apt cache: seeded 1 ' "$OUT" "seed count logged"
assert_match 'apt cache: harvested 1 ' "$OUT" "harvest count logged"
run_stage1 "200" "transient ok" STAGE1_APT_CACHE_DIR="$CACHE"
assert_eq 0 "$RC" "persistent cache + transient failure -> exit 0"
assert_eq "partial-fetched" "$(cat "$CACHE/20260415T000000Z/archives/resumed_1.0_amd64.deb" 2>/dev/null)" "partial fetch harvested into the PERSISTENT cache when one is in effect"
assert_eq 1 "$(sed -n 2p "$MM_LOG" | grep -o -- '--setup-hook=' | wc -l | tr -d ' ')" "persistent cache retry carries exactly one seed hook"
assert_no_match '/tmp/stage1-apt-cache/archives' "$OUT" "job-local resume cache unused when the persistent cache is in effect"

run_stage1 "200" "ok" STAGE1_APT_CACHE_DIR="$tmproot/does-not-exist/nested"
assert_eq 0 "$RC" "creatable cache dir -> created and used"
run_stage1 "200" "ok" STAGE1_APT_CACHE_DIR="relative/path"
assert_eq 0 "$RC" "relative cache dir -> build still succeeds"
assert_no_match '--setup-hook' "$(cat "$MM_LOG")" "relative cache dir -> cache disabled"
assert_match 'WARNING: STAGE1_APT_CACHE_DIR' "$OUT" "relative cache dir -> warned"

# --- 10. apt_snapshot=none keeps the historical live-mirror path ------------
rm -rf /tmp/fat; echo 1000 > "$FAKE_CLOCK"; : > "$SLEEP_LOG"; : > "$CURL_LOG"; : > "$MM_LOG"; : > "$GETENT_ADDRS"; : > "$CURL_IP_CODES"; : > "$MM_HOSTS_SEEN"
printf '200\n' > "$CURL_CODES"; printf 'ok\n' > "$MM_OUTCOMES"
set +e
OUT=$(env -i PATH="$STUBS:/usr/bin:/bin" HOME="$tmproot" REAL_DATE="$REAL_DATE" FAKE_CLOCK="$FAKE_CLOCK" \
      SLEEP_LOG="$SLEEP_LOG" CURL_CODES="$CURL_CODES" CURL_LOG="$CURL_LOG" MM_OUTCOMES="$MM_OUTCOMES" MM_LOG="$MM_LOG" \
      MM_ARCHIVES_SEEN="$MM_ARCHIVES_SEEN" GETENT_ADDRS="$GETENT_ADDRS" CURL_IP_CODES="$CURL_IP_CODES" MM_HOSTS_SEEN="$MM_HOSTS_SEEN" STAGE1_APT_CACHE_DIR="$CACHE" STAGE1_SNAPSHOT_BASE_URL=https://snapshot-mirror.example.test/ubuntu \
      bash "$STAGE1" --module stage1-selftest --apt-snapshot none 2>&1); RC=$?
set -e
assert_eq 0 "$RC" "apt_snapshot=none -> exit 0"
assert_match ' /tmp/fat http://archive\.ubuntu\.com/ubuntu/$' "$(cat "$MM_LOG")" "apt_snapshot=none -> live mirror, as before"
assert_no_match '--setup-hook' "$(cat "$MM_LOG")" "apt_snapshot=none -> cache disabled"
assert_match 'STAGE1_SNAPSHOT_BASE_URL is set but apt_snapshot=none' "$OUT" "apt_snapshot=none -> alternate base ignored, announced"

# --- 11. healthy-backend pinning --------------------------------------------
# backends "addr1 addr2 ..." "addr code[,code...]"...  (codes pop per probe, last repeats)
# shellcheck disable=SC2086  # intentional word-splitting of the address list
backends() { printf '%s\n' $1 > "$GETENT_ADDRS"; shift; printf '%s\n' "$@" > "$CURL_IP_CODES"; }
HOSTS_BEFORE=$(cat /etc/hosts)
if [ "$PIN_TESTS" = 1 ]; then
  # a. partial outage: pin the first healthy address, never probe past it
  backends "192.0.2.36 192.0.2.37 192.0.2.69" "192.0.2.36 502" "192.0.2.37 200" "192.0.2.69 000"
  KEEP_BACKENDS=1 run_stage1 "200" "ok"
  assert_eq 0 "$RC" "partial backend outage -> exit 0"
  assert_eq "" "$(sleeps)" "partial backend outage -> no waiting"
  assert_match '^resolve=192\.0\.2\.36 .*InRelease$' "$(sed -n 1p "$CURL_LOG")" "first address probed with --resolve"
  assert_eq 2 "$(wc -l < "$CURL_LOG" | tr -d ' ')" "probing stops at the first healthy address"
  assert_eq "192.0.2.37 snapshot.ubuntu.com" "$(cat "$MM_HOSTS_SEEN")" "mmdebstrap ran with the healthy address pinned in /etc/hosts"
  assert_eq "$HOSTS_BEFORE" "$(cat /etc/hosts)" "the pin never reached /etc/hosts outside the mmdebstrap namespace"
  assert_match 'pinning snapshot\.ubuntu\.com -> 192\.0\.2\.37 .*192\.0\.2\.36=502 192\.0\.2\.37=200' "$OUT" "pin decision logged with every probed address and code"
  assert_match 'backend pin mode: private mount namespace' "$OUT" "namespace pin mode chosen when unshare -m works"

  # b. all backends bad, one recovers later: waited out, then pinned
  backends "192.0.2.36 192.0.2.37" "192.0.2.36 502,502,200" "192.0.2.37 000"
  KEEP_BACKENDS=1 run_stage1 "200" "ok"
  assert_eq 0 "$RC" "all backends bad then one recovers -> exit 0"
  assert_eq "5 10" "$(sleeps)" "all backends bad then one recovers -> backoff between rounds"
  assert_eq "192.0.2.36 snapshot.ubuntu.com" "$(cat "$MM_HOSTS_SEEN")" "the recovered address is the one pinned"

  # c. every backend dead: bounded failure naming every address and code
  backends "192.0.2.36 192.0.2.37" "192.0.2.36 502" "192.0.2.37 000"
  KEEP_BACKENDS=1 run_stage1 "200" "ok"
  assert_eq 2 "$RC" "every backend dead -> exit 2"
  assert_eq 0 "$(mm_calls)" "every backend dead -> mmdebstrap never runs"
  total=0; for s in $(sleeps); do total=$((total + s)); done
  assert_eq 100 "$total" "every backend dead -> total wait equals the budget"
  assert_match 'last result: 192\.0\.2\.36=502 192\.0\.2\.37=000' "$OUT" "failure names every address and its code"

  # d. every backend 404: non-transient, immediate
  backends "192.0.2.36 192.0.2.37" "192.0.2.36 404" "192.0.2.37 404"
  KEEP_BACKENDS=1 run_stage1 "200" "ok"
  assert_eq 2 "$RC" "every backend 404 -> exit 2"
  assert_eq "" "$(sleeps)" "every backend 404 -> no waiting"
  assert_match 'none failed transiently \(192\.0\.2\.36=404 192\.0\.2\.37=404\)' "$OUT" "404s reported per address"

  # e. re-pin between mmdebstrap attempts
  backends "192.0.2.36 192.0.2.37" "192.0.2.36 200,502" "192.0.2.37 200"
  KEEP_BACKENDS=1 run_stage1 "200" "transient ok"
  assert_eq 0 "$RC" "transient mmdebstrap failure with re-pin -> exit 0"
  assert_eq "192.0.2.36 snapshot.ubuntu.com
192.0.2.37 snapshot.ubuntu.com" "$(cat "$MM_HOSTS_SEEN")" "each attempt ran with the backend that was healthy at that moment"

  # f. in-place fallback when unshare -m is unavailable: applied, then restored
  printf '#!/bin/sh\nexit 1\n' > "$STUBS/unshare"; chmod +x "$STUBS/unshare"
  backends "192.0.2.36 192.0.2.37" "192.0.2.36 502" "192.0.2.37 200"
  KEEP_BACKENDS=1 run_stage1 "200" "ok"
  rm -f "$STUBS/unshare"
  assert_eq 0 "$RC" "in-place fallback -> exit 0"
  assert_match 'backend pin mode: in-place edit' "$OUT" "in-place fallback announced"
  assert_eq "192.0.2.37 snapshot.ubuntu.com" "$(cat "$MM_HOSTS_SEEN")" "in-place fallback -> mmdebstrap saw the pin"
  assert_eq "$HOSTS_BEFORE" "$(cat /etc/hosts)" "in-place fallback -> /etc/hosts restored afterwards"
  if [ -e /tmp/stage1-hosts.orig ]; then fail "in-place fallback -> backup file left behind"; else pass "in-place fallback -> backup removed"; fi

  # g. single address / pin disabled: plain host-name probe, nothing pinned
  backends "192.0.2.37" "192.0.2.37 200"
  KEEP_BACKENDS=1 run_stage1 "200" "ok"
  assert_eq 0 "$RC" "single address -> exit 0"
  assert_eq "(no pin)" "$(cat "$MM_HOSTS_SEEN")" "single address -> nothing pinned"
  assert_no_match 'resolve=' "$(cat "$CURL_LOG")" "single address -> plain host-name probe"
  backends "192.0.2.36 192.0.2.37" "192.0.2.36 502" "192.0.2.37 200"
  KEEP_BACKENDS=1 run_stage1 "200" "ok" STAGE1_BACKEND_PIN=0
  assert_eq 0 "$RC" "STAGE1_BACKEND_PIN=0 -> exit 0"
  assert_eq "(no pin)" "$(cat "$MM_HOSTS_SEEN")" "STAGE1_BACKEND_PIN=0 -> nothing pinned"
  assert_no_match 'resolve=' "$(cat "$CURL_LOG")" "STAGE1_BACKEND_PIN=0 -> no per-address probes"

  # h. alternate base with an explicit port: pin targets that host/port
  backends "192.0.2.10 192.0.2.11" "192.0.2.10 000" "192.0.2.11 200"
  KEEP_BACKENDS=1 run_stage1 "200" "ok" STAGE1_SNAPSHOT_BASE_URL=http://snapshot-mirror.example.test:3142/ubuntu
  assert_eq 0 "$RC" "alternate base with port -> exit 0"
  assert_match '^resolve=192\.0\.2\.10 http://snapshot-mirror\.example\.test:3142/ubuntu/20260415T000000Z/dists/noble/InRelease$' "$(sed -n 1p "$CURL_LOG")" "alternate base probed per address at its port"
  assert_eq "192.0.2.11 snapshot-mirror.example.test" "$(cat "$MM_HOSTS_SEEN")" "alternate base host is what gets pinned"
fi

# --- 12. knob validation fails fast -----------------------------------------
run_stage1 "200" "ok" STAGE1_MIRROR_WAIT_MAX=soon
assert_eq 2 "$RC" "non-numeric STAGE1_MIRROR_WAIT_MAX -> exit 2 before any work"
assert_eq 0 "$(mm_calls)" "non-numeric STAGE1_MIRROR_WAIT_MAX -> mmdebstrap never runs"
run_stage1 "200" "ok" STAGE1_BACKEND_PIN=maybe
assert_eq 2 "$RC" "bad STAGE1_BACKEND_PIN -> exit 2 before any work"
run_stage1 "200" "ok" STAGE1_APT_TIMEOUT=0
assert_eq 2 "$RC" "zero STAGE1_APT_TIMEOUT -> exit 2 before any work"
assert_eq 0 "$(mm_calls)" "zero STAGE1_APT_TIMEOUT -> mmdebstrap never runs"

echo
if [ "$failures" -eq 0 ]; then echo "all passed"; else echo "$failures failure(s)"; fi
exit "$failures"
