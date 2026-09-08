#!/usr/bin/env bash
# stage1-rootfs.sh — Stage 1 of the platform module build pipeline:
# mmdebstrap fat rootfs bootstrap from package_spec + per-module apt-source
# hooks, plus the inc5 package-provenance (dpkg-query) capture.
#
# Extracted (campaign 019f5885 inc6 — pure refactor at the time) from the
# "Stage 1 — bootstrap fat rootfs (mmdebstrap + package_spec)" step of
# .gitea/workflows/build-platform-modules.yaml. The CONTENT-DETERMINING inputs
# of that step are unchanged: same suite/variant/components, same --include
# list from package_spec, same keyring, same apt_snapshot pin resolved to the
# same base URL, same hardcoded /tmp/* scratch paths — so the fat rootfs +
# provenance capture are what the inline step produced. The workflow step is
# a thin invocation of this script; a native build (build-one-module.sh in
# this same directory, driven by module-forge-build.sh) runs the identical
# script with no Gitea Actions context at all.
#
# MIRROR RESILIENCE (fix/stage1-mirror-resilience, 2026-09-08). The pinned
# snapshot.ubuntu.com mirror flaps 200/502/503 for stretches of an hour or
# more, and the original inline step failed the whole build on the FIRST apt
# error — every module in a batch burned its retries in ~30 s. The mmdebstrap
# invocation is now wrapped in a bounded probe-then-retry loop:
#
#   1. Before mmdebstrap runs, the mirror's dists/noble/InRelease is probed
#      with curl until it answers HTTP 200. 5xx / 429 / no-response are
#      treated as transient and waited out with exponential backoff (5 s
#      doubling to a 60 s cap); any other 4xx (a 404 = the pinned snapshot
#      does not exist on this mirror) fails immediately.
#      HEALTHY-BACKEND PINNING: the observed outage is a PARTIAL backend
#      failure — the snapshot host has several A records and only some of
#      them serve the snapshot; a build "flaps" purely on which address the
#      resolver hands apt. So when the mirror host resolves to more than one
#      address, every address is probed in turn with curl --resolve and the
#      first one answering 200 is pinned for this job: a per-job hosts file
#      (/tmp/stage1-hosts) is bind-mounted over /etc/hosts in a PRIVATE
#      mount namespace around the mmdebstrap process only (unshare -m), so
#      nothing outside that process tree — and never the builder host's
#      own /etc/hosts — sees the pin. Where unshare -m is denied (the Gitea
#      CI container has no CAP_SYS_ADMIN) the job-scoped /etc/hosts of that
#      container/chroot is edited in place and restored on exit. The pin is
#      re-derived before every retry. If no address is healthy the wait/
#      backoff above applies; on giving up every address and its HTTP code
#      is named. Where apt resolves: on a native build this script already
#      runs INSIDE the per-job buildenv chroot (module-forge-build.sh
#      chroots before invoking build-one-module.sh) and mmdebstrap
#      --mode=root runs apt on that same side with Dir pointed into
#      /tmp/fat, so /etc/hosts here IS the file apt's http method reads.
#   2. mmdebstrap itself is run up to STAGE1_MMDEBSTRAP_ATTEMPTS times. A
#      failed run is retried ONLY if its output carries a transient-mirror
#      signature (5xx/429 on a fetch, connection errors, Hash Sum mismatch);
#      any other failure (unknown package, keyring, disk) fails at once.
#      Before a retry the partial /tmp/fat is removed and the mirror is
#      re-probed.
#   3. Every wait shares ONE deadline, STAGE1_MIRROR_WAIT_MAX seconds from
#      the moment this script starts. Worst case for a dead mirror is that
#      budget spent probing, then a clear failure naming the mirror URL and
#      the last HTTP code; worst case for a flapping mirror is that budget
#      plus up to STAGE1_MMDEBSTRAP_ATTEMPTS mmdebstrap runs.
#
# apt's own transport retry (Acquire::Retries) is also enabled. Nothing here
# alters or substitutes the apt_snapshot pin: the timestamp comes from the
# manifest, the base URL is the canonical snapshot service unless the
# operator OPTS IN to an alternate mirror of the same snapshot tree (below),
# and archive.ubuntu.com is never used as a fallback.
#
# Only two values varied by workflow context in the original inline step —
# both threaded through as explicit CLI args below (never read from the
# process environment, so this script has no Actions-env-var dependency):
#   $MODULE       — was set via GITHUB_ENV by the "Resolve build slot" step
#                   (untouched); now --module.
#   $APT_SNAPSHOT — was the step's own `env:` block, sourced from
#                   steps.manifest.outputs.apt_snapshot (the "Parse
#                   manifest" step, untouched); now --apt-snapshot.
# Every /tmp/* path below (fat rootfs, hooks dir, package_spec.txt, the
# packages provenance file) is the SAME hardcoded literal the inline step
# used — not parameterized, because none of them are sourced from Actions
# context; they're the pipeline's existing shared-/tmp convention (the same
# container filesystem is shared by every step in a job), unchanged here.
#
# Usage:
#   stage1-rootfs.sh --module MODULE [--apt-snapshot SNAPSHOT_OR_none]
#
# Required:
#   --module MODULE            module slug
#
# Optional:
#   --apt-snapshot VALUE        manifest's build.apt_snapshot, or the
#                               literal string "none" (default)
#
# Env (optional — none is a credential; all reach a native build by plain
# process-environment inheritance from module-forge-build.sh through
# build-one-module.sh, the same channel BUILD_SKIP_UNCHANGED / CORE_REF use;
# in the Gitea workflow set them in the step's `env:` block):
#   STAGE1_MIRROR_WAIT_MAX       Total seconds this stage may spend WAITING
#                                for the mirror across every probe (default
#                                900 = 15 min). One deadline for the whole
#                                stage, not per attempt.
#   STAGE1_MMDEBSTRAP_ATTEMPTS   How many times mmdebstrap is run before
#                                giving up (default 3). Only transient-mirror
#                                failures are retried — see above.
#   STAGE1_BACKEND_PIN           1 (default) = probe every address of the
#                                mirror host and pin a healthy one for this
#                                job as described above; 0 = probe the host
#                                name only and let the resolver choose.
#   STAGE1_SNAPSHOT_BASE_URL     OPT-IN, default unset. An alternate base URL
#                                that serves the SAME immutable snapshot tree
#                                at <base>/<apt_snapshot>/ — e.g. an internal
#                                proxy or mirror of snapshot.ubuntu.com. It
#                                replaces https://snapshot.ubuntu.com/ubuntu/
#                                for this run only; the timestamp pin still
#                                comes from the manifest, so the resolved
#                                package set is identical by construction.
#                                Any *.ubuntu.com live rolling mirror
#                                (archive/security/ports) is REFUSED: a
#                                rolling mirror cannot serve a snapshot tree
#                                and would silently change package versions.
#                                Ignored when apt_snapshot is "none".
#   STAGE1_APT_CACHE_DIR         OPT-IN, default unset. Absolute path of a
#                                persistent .deb cache keyed by snapshot:
#                                <dir>/<apt_snapshot>/archives/*.deb are
#                                seeded into the chroot's apt cache before
#                                mmdebstrap fetches anything, and every .deb
#                                mmdebstrap fetched is harvested back
#                                afterwards (before its own apt-get clean, so
#                                the produced rootfs is unchanged). apt
#                                verifies each cached file against the
#                                snapshot index's hashes and re-fetches on
#                                mismatch, so a stale or corrupt entry is
#                                never trusted — and snapshot content is
#                                immutable, so the key can never go stale.
#                                Degrades to "no cache" with a WARNING when
#                                the directory is missing or unwritable;
#                                disabled when apt_snapshot is "none" (live
#                                mirror content is not immutable, so there
#                                is no safe cache key). NOTE: the build
#                                chroot only sees what its caller mounts —
#                                a native build needs module-forge-build.sh
#                                to bind-mount a persistent host directory
#                                into the buildenv and export this variable;
#                                until it does, the variable is unset there
#                                and this is a no-op.
#
# Reads:  /tmp/package_spec.txt (produced by the workflow's untouched
#         "Parse manifest" step)
# Writes: /tmp/fat (the bootstrapped rootfs), /tmp/hooks/* (apt-source
#         hooks for log-forwarder-vector / storage-tools),
#         /tmp/$MODULE.packages.txt (resolved-package provenance),
#         /tmp/stage1-mmdebstrap.log (the last mmdebstrap run's output,
#         used for the transient-failure classification),
#         /tmp/stage1-hosts (the per-job hosts file carrying the backend
#         pin) and /tmp/stage1-hosts.orig (backup of /etc/hosts, only in
#         the in-place fallback),
#         /tmp/stage1-apt-cache-{seed,harvest}.sh (only when
#         STAGE1_APT_CACHE_DIR is in effect)
#
# Exit: non-zero on any mmdebstrap/dpkg-query failure (set -euo pipefail
# propagates the first one); 2 with a message naming the mirror URL and the
# last HTTP code when the mirror wait budget is exhausted or the failure is
# classified as non-transient.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: stage1-rootfs.sh --module MODULE [--apt-snapshot SNAPSHOT_OR_none]

Stage 1 of the module build pipeline: mmdebstrap fat rootfs bootstrap +
package-provenance capture. See the file header for the full option
reference, the STAGE1_* resilience/cache env knobs, and the
workflow-env-var mapping.
EOF
}

die() {
  echo "stage1-rootfs.sh: error: $*" >&2
  exit 2
}

log() {
  echo "[stage-1] $*"
}

MODULE=""
APT_SNAPSHOT="none"

while [ $# -gt 0 ]; do
  case "$1" in
    --module)
      [ $# -ge 2 ] || die "--module requires an argument"
      MODULE="$2"; shift 2 ;;
    --apt-snapshot)
      [ $# -ge 2 ] || die "--apt-snapshot requires an argument"
      APT_SNAPSHOT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

[ -n "$MODULE" ] || { usage >&2; die "--module is required"; }

# ---------------------------------------------------------------------------
# Resilience knobs (see the header). Validated up front so a typo fails the
# job in the first second, not after a 15-minute wait.
# ---------------------------------------------------------------------------
MIRROR_WAIT_MAX="${STAGE1_MIRROR_WAIT_MAX:-900}"
MMDEBSTRAP_ATTEMPTS="${STAGE1_MMDEBSTRAP_ATTEMPTS:-3}"
SNAPSHOT_BASE_URL_OVERRIDE="${STAGE1_SNAPSHOT_BASE_URL:-}"
APT_CACHE_DIR="${STAGE1_APT_CACHE_DIR:-}"
[[ "$MIRROR_WAIT_MAX" =~ ^[0-9]+$ ]] \
  || die "STAGE1_MIRROR_WAIT_MAX must be a non-negative integer number of seconds, got '${MIRROR_WAIT_MAX}'"
[[ "$MMDEBSTRAP_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
  || die "STAGE1_MMDEBSTRAP_ATTEMPTS must be a positive integer, got '${MMDEBSTRAP_ATTEMPTS}'"
BACKEND_PIN="${STAGE1_BACKEND_PIN:-1}"
case "$BACKEND_PIN" in
  0|1) ;;
  *) die "STAGE1_BACKEND_PIN must be 0 or 1, got '${BACKEND_PIN}'" ;;
esac

SNAPSHOT_BASE_URL_DEFAULT="https://snapshot.ubuntu.com/ubuntu/"
LIVE_MIRROR_URL="http://archive.ubuntu.com/ubuntu/"

# Output lines that mean "the MIRROR (or the path to it) failed", as opposed
# to "this build is wrong". Matched case-insensitively against the captured
# mmdebstrap output to decide whether a failed run is worth retrying. apt
# prints fetch failures as `Err:N <url> <suite> <file>` followed by the HTTP
# status line; mmdebstrap then reports `apt-get update --error-on=any ...
# failed: process exited with 100` — the exit code alone cannot distinguish
# a 503 from a misspelled package, which is why the text is inspected.
TRANSIENT_OUTPUT_RE='Err:[0-9]+ .*[[:space:]](408|425|429|5[0-9][0-9])[[:space:]]|Service Unavailable|Bad Gateway|Gateway Time-?out|Internal Server Error|Could not connect|Failed to connect|Connection (timed out|refused|reset)|Temporary failure resolving|Could not resolve|Unable to connect|Error reading from server|Network is unreachable|Undetermined Error|Hash Sum mismatch'

# --- mirror probe ----------------------------------------------------------
# One deadline for the whole stage: however many probes and retries happen,
# the total time spent WAITING is bounded by STAGE1_MIRROR_WAIT_MAX.
MIRROR_DEADLINE=$(( $(date +%s) + MIRROR_WAIT_MAX ))
MIRROR_PROBES=0
MIRROR_LAST_CODE="n/a"

# probe_http_code URL — prints the HTTP status of a GET (000 = no HTTP
# response at all: DNS, connect or TLS failure, or a timeout).
probe_http_code() {
  local code
  code=$(curl -sS -L -o /dev/null -w '%{http_code}' --max-time 30 "$1" 2>/dev/null) || true
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  printf '%s\n' "$code"
}

transient_http_code() {
  case "$1" in
    000|408|425|429|5[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- healthy-backend pinning -------------------------------------------------
HOSTS_PIN_FILE=/tmp/stage1-hosts
HOSTS_ORIG_BACKUP=/tmp/stage1-hosts.orig
PINNED_IP=""          # address pinned for the next mmdebstrap run ("" = none)
PIN_MODE=""           # namespace | inplace | off — decided once, lazily
BACKEND_REPORT=""     # "addr=code addr=code ..." from the last probe round

url_host() {
  local hp="${1#*://}"
  hp="${hp%%/*}"
  printf '%s\n' "${hp%%:*}"
}

url_port() {
  local hp="${1#*://}"
  hp="${hp%%/*}"
  case "$hp" in
    *:*) printf '%s\n' "${hp##*:}" ;;
    *) case "$1" in https://*) echo 443 ;; *) echo 80 ;; esac ;;
  esac
}

# resolve_backends HOST — every address HOST resolves to, resolver order,
# de-duplicated. Empty when getent is unavailable or HOST does not resolve.
resolve_backends() {
  command -v getent >/dev/null 2>&1 || return 0
  getent ahosts "$1" 2>/dev/null | awk '!seen[$1]++ { print $1 }'
}

# probe_backend URL HOST PORT ADDR — HTTP code of URL fetched from ADDR
# specifically (curl --resolve), so TLS/SNI still see the real host name.
probe_backend() {
  local code addr="$4"
  case "$addr" in *:*) addr="[${addr}]" ;; esac
  code=$(curl -sS -L -o /dev/null -w '%{http_code}' --max-time 30 \
           --resolve "${2}:${3}:${addr}" "$1" 2>/dev/null) || true
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  printf '%s\n' "$code"
}

# select_backend URL — probes URL's host address by address, stopping at
# the first that answers 200. Sets PINNED_IP and BACKEND_REPORT.
# Returns 0 = healthy address pinned; 1 = none healthy, at least one
# transient; 2 = none healthy, none transient; 3 = nothing to pin (fewer
# than two addresses, or no resolver).
select_backend() {
  local url="$1" host port addr code any_transient=0
  local -a addrs
  host=$(url_host "$url")
  port=$(url_port "$url")
  mapfile -t addrs < <(resolve_backends "$host")
  PINNED_IP=""
  BACKEND_REPORT=""
  [ "${#addrs[@]}" -ge 2 ] || return 3
  for addr in "${addrs[@]}"; do
    code=$(probe_backend "$url" "$host" "$port" "$addr")
    BACKEND_REPORT="${BACKEND_REPORT:+${BACKEND_REPORT} }${addr}=${code}"
    if [ "$code" = "200" ]; then
      PINNED_IP="$addr"
      return 0
    fi
    if transient_http_code "$code"; then
      any_transient=1
    fi
  done
  [ "$any_transient" -eq 1 ] && return 1
  return 2
}

# write_hosts_pin HOST — (re)writes the per-job hosts file: the current
# /etc/hosts minus any existing line for HOST, plus the pinned address.
write_hosts_pin() {
  local host="$1"
  {
    if [ -r /etc/hosts ]; then
      awk -v h="$host" '{ keep = 1; for (i = 2; i <= NF; i++) if ($i == h) keep = 0; if (keep) print }' /etc/hosts
    fi
    printf '%s %s\n' "$PINNED_IP" "$host"
  } > "$HOSTS_PIN_FILE"
}

restore_hosts_inplace() {
  if [ -f "$HOSTS_ORIG_BACKUP" ]; then
    cat "$HOSTS_ORIG_BACKUP" > /etc/hosts 2>/dev/null || true
    rm -f "$HOSTS_ORIG_BACKUP"
  fi
}

# decide_pin_mode — once: can the pin be applied in a private mount
# namespace (preferred: nothing outside the mmdebstrap process tree sees
# it), or only by editing this job's /etc/hosts in place (restored on
# exit), or not at all?
decide_pin_mode() {
  [ -z "$PIN_MODE" ] || return 0
  if [ ! -e /etc/hosts ]; then
    : > /etc/hosts 2>/dev/null || true
  fi
  # shellcheck disable=SC2016  # the $1 is for the inner sh, deliberately unexpanded here
  if [ -e /etc/hosts ] && command -v unshare >/dev/null 2>&1 \
     && unshare -m --propagation private sh -c 'mount --bind "$1" /etc/hosts' sh "$HOSTS_PIN_FILE" >/dev/null 2>&1; then
    PIN_MODE=namespace
    log "backend pin mode: private mount namespace around mmdebstrap (nothing outside it sees the pin)"
  elif [ -w /etc/hosts ]; then
    PIN_MODE=inplace
    trap restore_hosts_inplace EXIT
    log "backend pin mode: in-place edit of this job's /etc/hosts (unshare -m unavailable here); restored after mmdebstrap and on exit"
  else
    PIN_MODE=off
    log "WARNING: backend pin cannot be applied (/etc/hosts not writable and unshare -m unavailable) — proceeding unpinned"
  fi
}

# run_mmdebstrap — mmdebstrap "${mmdebstrap_args[@]}" with the backend pin
# in effect (if any). Returns mmdebstrap's exit status.
run_mmdebstrap() {
  local rc
  if [ -z "$PINNED_IP" ] || [ "$PIN_MODE" = "off" ]; then
    mmdebstrap "${mmdebstrap_args[@]}"
    return $?
  fi
  case "$PIN_MODE" in
    namespace)
      # shellcheck disable=SC2016  # $0/$@ are for the inner bash, deliberately unexpanded here
      unshare -m --propagation private bash -c 'mount --bind "$0" /etc/hosts && exec "$@"' \
        "$HOSTS_PIN_FILE" mmdebstrap "${mmdebstrap_args[@]}"
      return $? ;;
    inplace)
      [ -f "$HOSTS_ORIG_BACKUP" ] || cp /etc/hosts "$HOSTS_ORIG_BACKUP"
      cat "$HOSTS_PIN_FILE" > /etc/hosts
      mmdebstrap "${mmdebstrap_args[@]}"
      rc=$?
      restore_hosts_inplace
      return "$rc" ;;
  esac
}

# wait_for_mirror URL — returns once URL answers 200 (from a pinned healthy
# backend when the host has several), with PINNED_IP set accordingly. Dies
# (exit 2) when the shared deadline passes or every answer is non-transient.
wait_for_mirror() {
  local url="$1" delay=5 now remaining code rc host
  PINNED_IP=""
  if ! command -v curl >/dev/null 2>&1; then
    log "curl not on PATH — skipping the mirror probe (mmdebstrap retries still apply)"
    return 0
  fi
  host=$(url_host "$url")
  while :; do
    MIRROR_PROBES=$((MIRROR_PROBES + 1))
    rc=3
    if [ "$BACKEND_PIN" = "1" ]; then
      set +e
      select_backend "$url"
      rc=$?
      set -e
    fi
    case "$rc" in
      0)
        MIRROR_LAST_CODE="$BACKEND_REPORT"
        write_hosts_pin "$host"
        decide_pin_mode
        log "mirror probe OK: pinning ${host} -> ${PINNED_IP} for this job (${BACKEND_REPORT}; probe ${MIRROR_PROBES})"
        return 0 ;;
      1)
        code="$BACKEND_REPORT"
        MIRROR_LAST_CODE="$code" ;;
      2)
        die "mirror probe: no address of ${host} serves ${url} and none failed transiently (${BACKEND_REPORT}) — not retrying (404 here means the pinned apt_snapshot does not exist on this mirror)" ;;
      *)
        code=$(probe_http_code "$url")
        MIRROR_LAST_CODE="$code"
        if [ "$code" = "200" ]; then
          log "mirror probe OK: HTTP 200 from ${url} (probe ${MIRROR_PROBES}; single address or no resolver — nothing to pin)"
          return 0
        fi
        if ! transient_http_code "$code"; then
          die "mirror probe: HTTP ${code} from ${url} — not a transient error (404 here means the pinned apt_snapshot does not exist on this mirror); not retrying"
        fi ;;
    esac
    now=$(date +%s)
    remaining=$(( MIRROR_DEADLINE - now ))
    if [ "$remaining" -le 0 ]; then
      die "apt mirror ${url} still unhealthy after ${MIRROR_WAIT_MAX}s of waiting (${MIRROR_PROBES} probes; last result: ${code}) — giving up. The pinned snapshot is unreachable, not misconfigured: re-run the batch once the mirror recovers, or set STAGE1_SNAPSHOT_BASE_URL to an alternate mirror of the SAME snapshot tree (see this script's header)."
    fi
    if [ "$delay" -gt "$remaining" ]; then
      delay="$remaining"
    fi
    log "mirror probe: ${code} from ${url} — transient; retrying in ${delay}s (${remaining}s of wait budget left)"
    sleep "$delay"
    delay=$(( delay * 2 ))
    if [ "$delay" -gt 60 ]; then
      delay=60
    fi
  done
}

# transient_mmdebstrap_failure LOGFILE — true if the captured output carries
# a transient-mirror signature (see TRANSIENT_OUTPUT_RE).
transient_mmdebstrap_failure() {
  [ -s "$1" ] && grep -qiE "$TRANSIENT_OUTPUT_RE" "$1"
}

# reset_fat_dir — clear a partial /tmp/fat left by a failed mmdebstrap run
# so the retry starts from the empty target mmdebstrap requires. Any mounts
# mmdebstrap may have left under it are unmounted innermost-first.
reset_fat_dir() {
  [ -e /tmp/fat ] || return 0
  local m
  if [ -r /proc/self/mountinfo ]; then
    while read -r m; do
      umount -l "$m" 2>/dev/null || true
    done < <(awk '$5 ~ "^/tmp/fat(/|$)" { print $5 }' /proc/self/mountinfo | sort -r)
  fi
  rm -rf /tmp/fat || die "could not clear the partial /tmp/fat before retrying mmdebstrap"
}

# --- alternate snapshot base (opt-in) --------------------------------------
# Sets SNAPSHOT_BASE_URL (a global, deliberately NOT a command substitution:
# the announcement below goes to stdout and must never end up inside the
# URL handed to mmdebstrap).
SNAPSHOT_BASE_URL="$SNAPSHOT_BASE_URL_DEFAULT"
resolve_snapshot_base_url() {
  local u="$SNAPSHOT_BASE_URL_OVERRIDE"
  if [ -z "$u" ]; then
    SNAPSHOT_BASE_URL="$SNAPSHOT_BASE_URL_DEFAULT"
    return 0
  fi
  [[ "$u" =~ ^https?://[^[:space:]\'\"]+$ ]] \
    || die "STAGE1_SNAPSHOT_BASE_URL='${u}' is not an http(s) URL"
  case "$u" in
    *archive.ubuntu.com*|*security.ubuntu.com*|*ports.ubuntu.com*)
      die "STAGE1_SNAPSHOT_BASE_URL='${u}' names a live rolling mirror; it must serve the immutable snapshot tree at <base>/<apt_snapshot>/ (never archive.ubuntu.com — that would silently change the resolved package versions)" ;;
  esac
  [[ "$u" == */ ]] || u="${u}/"
  log "STAGE1_SNAPSHOT_BASE_URL is set — using operator-supplied snapshot base ${u} in place of ${SNAPSHOT_BASE_URL_DEFAULT} (the manifest's apt_snapshot pin is unchanged)"
  SNAPSHOT_BASE_URL="$u"
}

# --- persistent apt cache (opt-in) -----------------------------------------
# Populates cache_hook_args with the mmdebstrap flags that seed/harvest the
# cache, or leaves it empty (default) so the mmdebstrap command line is
# exactly the historical one.
cache_hook_args=()
setup_apt_cache() {
  [ -n "$APT_CACHE_DIR" ] || return 0
  if [ "$APT_SNAPSHOT" = "none" ]; then
    log "STAGE1_APT_CACHE_DIR is set but apt_snapshot=none — cache disabled (live-mirror content is not immutable; no safe cache key)"
    return 0
  fi
  case "$APT_CACHE_DIR" in
    /*) ;;
    *) log "WARNING: STAGE1_APT_CACHE_DIR='${APT_CACHE_DIR}' is not an absolute path — cache disabled"; return 0 ;;
  esac
  case "$APT_CACHE_DIR" in
    *[[:space:]\'\"\\]*) log "WARNING: STAGE1_APT_CACHE_DIR='${APT_CACHE_DIR}' contains whitespace or quoting characters — cache disabled"; return 0 ;;
  esac
  local cache="${APT_CACHE_DIR}/${APT_SNAPSHOT}/archives"
  if ! mkdir -p "$cache" 2>/dev/null || [ ! -w "$cache" ]; then
    log "WARNING: apt cache directory ${cache} is missing or not writable — cache disabled"
    return 0
  fi
  # Both hooks run on the HOST side of mmdebstrap (root mode executes hooks
  # outside the chroot with the chroot path as $1), which is where the cache
  # directory is visible. Plain cp rather than mmdebstrap's rsync-based
  # sync-in/sync-out so partial/ and lock files are never copied and so a
  # concurrent job on the same cache cannot observe a half-written .deb
  # (harvest writes to a temp name and renames; an entry that already
  # exists is left alone).
  cat > /tmp/stage1-apt-cache-seed.sh <<EOF
#!/bin/sh
# generated by stage1-rootfs.sh — mmdebstrap --setup-hook; \$1 = chroot dir.
# Seeds the chroot's apt archive cache from the persistent snapshot cache.
set -eu
cache='${cache}'
dst="\$1/var/cache/apt/archives"
mkdir -p "\$dst"
n=0
for f in "\$cache"/*.deb; do
  [ -f "\$f" ] || continue
  name=\${f##*/}
  if [ ! -e "\$dst/\$name" ]; then
    if cp "\$f" "\$dst/\$name"; then
      n=\$((n + 1))
    else
      echo "[stage-1] apt cache: WARNING could not seed \$name (ignored)"
      rm -f "\$dst/\$name"
    fi
  fi
done
echo "[stage-1] apt cache: seeded \$n .deb(s) from \$cache"
EOF
  cat > /tmp/stage1-apt-cache-harvest.sh <<EOF
#!/bin/sh
# generated by stage1-rootfs.sh — mmdebstrap --customize-hook; \$1 = chroot dir.
# Runs after every package is installed and BEFORE mmdebstrap's final
# apt-get clean, so every .deb this run fetched is still present.
set -eu
cache='${cache}'
src="\$1/var/cache/apt/archives"
n=0
for f in "\$src"/*.deb; do
  [ -f "\$f" ] || continue
  name=\${f##*/}
  if [ ! -e "\$cache/\$name" ]; then
    tmp="\$cache/.\$name.\$\$.tmp"
    if cp "\$f" "\$tmp" 2>/dev/null; then
      mv -n "\$tmp" "\$cache/\$name" 2>/dev/null || true
    fi
    rm -f "\$tmp"
    if [ -e "\$cache/\$name" ]; then
      n=\$((n + 1))
    fi
  fi
done
echo "[stage-1] apt cache: harvested \$n new .deb(s) into \$cache"
EOF
  chmod +x /tmp/stage1-apt-cache-seed.sh /tmp/stage1-apt-cache-harvest.sh
  # --skip=essential/unlink keeps the essential-set .debs in the chroot's
  # archive dir until the customize hook has copied them out; mmdebstrap's
  # final cleanup (apt-get clean) still removes them from the produced
  # rootfs, so the bootstrapped tree is identical with or without the cache.
  cache_hook_args=(
    --skip=essential/unlink
    --setup-hook=/tmp/stage1-apt-cache-seed.sh
    --customize-hook=/tmp/stage1-apt-cache-harvest.sh
  )
  log "apt cache enabled: ${cache}"
}

# ---------------------------------------------------------------------------
# Stage body. The package/apt inputs below are the workflow's original Stage 1
# step values; $MODULE/$APT_SNAPSHOT come from the arg parsing above.
# ---------------------------------------------------------------------------

# mmdebstrap produces a minimal Ubuntu noble rootfs at
# /tmp/fat with `ca-certificates` + every package the
# module's manifest declared in package_spec. --mode=root
# avoids any namespace setup (we're running as root inside
# the Trixie CI container).
#
# The mmdebstrap output is functionally identical to what
# `buildah bud` against templates/module-repo/Containerfile
# produced — pinned base image + apt install + static
# ca-certs. We trade buildah's OCI-runtime isolation for a
# plain chroot, which is fine for the CI hermeticity envelope
# (the runner container itself is the security boundary).
#
# apt-snapshot pin (campaign 019f5885 inc5 — determinism
# hardening): archive.ubuntu.com serves whatever the current
# apt index is on the day the build runs, so two builds of the
# SAME commit on different days can resolve different package
# versions — a hard blocker for a bit-reproducible erofs.
# snapshot.ubuntu.com serves a frozen historical index at the
# module manifest's declared `build.apt_snapshot` timestamp, so
# every rebuild of an unchanged module resolves the identical
# package set. "none" (declared or the field's absence — both
# normalize to this string in the "Parse manifest" step above)
# is the documented per-module opt-out for the case where
# snapshot.ubuntu.com hasn't caught up on a package this module
# needs (coverage/lag risk) — it keeps today's live-mirror
# behavior unchanged.
if [[ "${APT_SNAPSHOT:-none}" != "none" ]]; then
  resolve_snapshot_base_url
  base_url="${SNAPSHOT_BASE_URL}${APT_SNAPSHOT}/"
  log "apt_snapshot=${APT_SNAPSHOT} — pinning mmdebstrap base_url to ${base_url}"
else
  if [ -n "$SNAPSHOT_BASE_URL_OVERRIDE" ]; then
    log "STAGE1_SNAPSHOT_BASE_URL is set but apt_snapshot=none — ignored (there is no snapshot to redirect)"
  fi
  base_url="$LIVE_MIRROR_URL"
  log "apt_snapshot=none — using live ${base_url} (per-module opt-out, or manifest hasn't pinned yet)"
fi
probe_url="${base_url}dists/noble/InRelease"
pkgs="ca-certificates"
if [ -s /tmp/package_spec.txt ]; then
  pkgs="${pkgs},$(tr '\n' ',' < /tmp/package_spec.txt | sed 's/,$//')"
fi

# Some modules declare packages that aren't in Ubuntu's main/universe:
#   - log-forwarder-vector ships `vector` (Timber/Datadog apt repo)
#   - storage-tools ships `gcsfuse` (Google Cloud apt repo)
# For those modules, register the upstream apt source + key via an
# --essential-hook so the package is resolvable when mmdebstrap's
# --include step runs. Hook executes after essential packages
# install but BEFORE the manifest's package_spec packages.
#
# DOCUMENTED REPRODUCIBILITY WAIVER (campaign 019f5885 inc5): both
# hooks below point at the vendor's live apt repo
# (apt.vector.dev, packages.cloud.google.com) — neither vendor
# offers a snapshot-pinned mirror we can substitute the way
# snapshot.ubuntu.com stands in for archive.ubuntu.com above. Two
# builds of log-forwarder-vector / storage-tools can therefore
# still pick up a newer `vector` / `gcsfuse` package between runs
# even with apt_snapshot pinned — this is residual, irreducible
# per-module nondeterminism until/unless either vendor ships a
# snapshot service. Every other module's apt_snapshot pin is
# unaffected.
hook_args=()
mkdir -p /tmp/hooks
case "$MODULE" in
  log-forwarder-vector)
    # Post-Datadog-acquisition, vector's apt key moved to
    # keys.datadoghq.com (DATADOG_APT_KEY_CURRENT.public) and
    # the legacy https://apt.vector.dev/vector.gpg returns 404.
    # The repo line is also `vector-<major>` not `main` per
    # vector's setup.vector.dev install script. Without these
    # updates the hook dies with: "gpg: not found" (fixed via
    # gnupg install above) + "curl: 404" (this URL change).
    cat > /tmp/hooks/essential00-vector-source.sh <<'EOF'
#!/bin/sh
# At essential-hook stage apt isn't yet installed in the chroot
# (it comes in via mmdebstrap's --include pass that runs AFTER
# this hook). Just drop the key + sources.list into place; the
# subsequent apt-get pass will see them. Trying to chroot in
# and apt-get update here dies with "chroot: failed to run
# command 'apt-get': No such file or directory".
set -eu
ROOT="$1"
mkdir -p "$ROOT/etc/apt/keyrings" "$ROOT/etc/apt/sources.list.d"
curl -fsSL https://keys.datadoghq.com/DATADOG_APT_KEY_CURRENT.public | gpg --dearmor > "$ROOT/etc/apt/keyrings/vector.gpg"
echo "deb [signed-by=/etc/apt/keyrings/vector.gpg] https://apt.vector.dev/ stable vector-0" > "$ROOT/etc/apt/sources.list.d/vector.list"
EOF
    chmod +x /tmp/hooks/essential00-vector-source.sh
    hook_args+=("--hook-directory=/tmp/hooks")
    ;;
  storage-tools)
    cat > /tmp/hooks/essential00-gcsfuse-source.sh <<'EOF'
#!/bin/sh
# Same essential-hook-stage constraint as the vector hook above:
# apt isn't yet in the chroot, so we only drop the key +
# sources.list. mmdebstrap's --include pass will pick them up.
set -eu
ROOT="$1"
mkdir -p "$ROOT/etc/apt/keyrings" "$ROOT/etc/apt/sources.list.d"
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor > "$ROOT/etc/apt/keyrings/google-cloud.gpg"
echo "deb [signed-by=/etc/apt/keyrings/google-cloud.gpg] https://packages.cloud.google.com/apt gcsfuse-noble main" > "$ROOT/etc/apt/sources.list.d/gcsfuse.list"
EOF
    chmod +x /tmp/hooks/essential00-gcsfuse-source.sh
    hook_args+=("--hook-directory=/tmp/hooks")
    ;;
  # gitea-act-runner needs no apt-source hook: its Docker packages
  # (docker.io + docker-buildx) live in Ubuntu noble's own universe
  # component, already indexed by mmdebstrap's base apt-get update.
esac

setup_apt_cache

# The content-determining arguments (suite, variant, components, --include,
# keyring, base URL) are the original inline step's. Acquire::Retries is
# apt's own per-fetch transport retry, layered under the probe/retry loop
# below; it cannot change which packages resolve.
# shellcheck disable=SC2054  # the commas are inside single --components= / --include= words, not element separators
mmdebstrap_args=(
  --mode=root
  --variant=minbase
  --components=main,universe
  "${hook_args[@]}"
  "${cache_hook_args[@]}"
  --include="$pkgs"
  --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
  --aptopt='Acquire::http::Pipeline-Depth "0"'
  --aptopt='Acquire::Retries "3"'
  noble /tmp/fat
  "$base_url"
)

MMDEBSTRAP_LOG=/tmp/stage1-mmdebstrap.log
attempt=1
while :; do
  wait_for_mirror "$probe_url"
  if [ "$attempt" -gt 1 ]; then
    reset_fat_dir
  fi
  log "mmdebstrap attempt ${attempt}/${MMDEBSTRAP_ATTEMPTS} against ${base_url}${PINNED_IP:+ (backend ${PINNED_IP})}"
  rm -f "$MMDEBSTRAP_LOG"
  # Output is tee'd (not swallowed) so the job log stays as verbose as before;
  # the copy is only for the transient-failure classification below.
  set +e
  run_mmdebstrap 2>&1 | tee "$MMDEBSTRAP_LOG"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -eq 0 ]; then
    log "mmdebstrap succeeded on attempt ${attempt}"
    break
  fi
  if ! transient_mmdebstrap_failure "$MMDEBSTRAP_LOG"; then
    die "mmdebstrap failed (exit ${rc}) on attempt ${attempt} with no transient-mirror signature in its output — not retrying (a missing package, keyring or disk problem does not get better by waiting; see the mmdebstrap output above)"
  fi
  if [ "$attempt" -ge "$MMDEBSTRAP_ATTEMPTS" ]; then
    die "mmdebstrap failed ${MMDEBSTRAP_ATTEMPTS} times against ${base_url} with a transient-mirror signature each time (last exit ${rc}; last probe result: ${MIRROR_LAST_CODE}) — giving up. Re-run the batch once the mirror recovers, or set STAGE1_SNAPSHOT_BASE_URL to an alternate mirror of the SAME snapshot tree."
  fi
  log "mmdebstrap attempt ${attempt} failed (exit ${rc}) with a transient-mirror signature — re-probing the mirror before attempt $((attempt + 1))"
  attempt=$((attempt + 1))
done

# Build provenance: capture the exact resolved package set (SBOM
# stepping stone — campaign 019f5885 inc5; full SLSA provenance
# is separately queued as 019f3112-f719-7152-aeac-51a3e833259f,
# out of scope here). mmdebstrap leaves a normal dpkg database at
# /tmp/fat/var/lib/dpkg — query it via --admindir from the
# RUNNER's own dpkg-query rather than chrooting: same technique
# this workflow already uses for the apt-closure-sha256
# annotation (APT_PROBE_MODE=local, "the runner IS
# debian:trixie-slim"), and dpkg's on-disk database format is
# stable across Debian/Ubuntu regardless of which one is being
# queried. Captured HERE (immediately after mmdebstrap, before
# Stage 1.5 layers any Class-B content that isn't apt-installed)
# so this is exactly "what apt resolved for package_spec", not a
# mix of apt + hand-staged binaries.
dpkg-query --admindir=/tmp/fat/var/lib/dpkg -W \
    -f='${Package}\t${Version}\t${Architecture}\n' \
  | LC_ALL=C sort > "/tmp/$MODULE.packages.txt"
echo "[stage-1] captured $(wc -l < "/tmp/$MODULE.packages.txt") resolved packages to /tmp/$MODULE.packages.txt"
