#!/bin/sh
# gitea-act-runner-start.sh — registers (first start only) and launches the
# Gitea Act runner daemon.
#
# Runs as the unprivileged pnrunner service user (systemd User=/Group=).
# The registration token staged by gitea-act-runner-register.sh is
# deliberately NOT passed as a command-line argument to `act_runner
# register` (would leak into `ps`/`/proc/<pid>/cmdline` for any local
# user) — it is piped in over STDIN, matching act_runner v0.2.13's
# interactive prompt order (instance URL, token, runner name, labels). set
# -eu deliberately, NEVER set -x (a trace would print the token to the
# unit's journal output).
set -eu

STATE_DIR="${STATE_DIRECTORY:-/var/lib/gitea-act-runner}"
RUNTIME_DIR="${RUNTIME_DIRECTORY:-/run/gitea-act-runner}"
CFG="${GITEA_ACT_RUNNER_CONFIG:-/etc/gitea-act-runner/config.yaml}"
INPUT_FILE="$RUNTIME_DIR/register_input"
FLAGS_FILE="$RUNTIME_DIR/register_flags"

log() { echo "gitea-act-runner-start: $*" >&2; }

if [ ! -s "$STATE_DIR/.runner" ]; then
  # Best-effort: give a freshly-started docker.service up to ~60s to bring
  # up its unix socket before registering — `act_runner register` itself
  # doesn't strictly need docker, but a runner that daemonizes before
  # docker is reachable would fail its very first job. Non-fatal: if
  # docker still isn't up after the retry window, log a warning and
  # proceed anyway rather than crash-looping the whole unit over a
  # transient ordering race (docker.service is already an After=/Wants=
  # of this unit — this is belt-and-suspenders, not the primary ordering
  # guarantee).
  i=0
  while [ "$i" -lt 60 ]; do
    if docker info >/dev/null 2>&1; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  if [ "$i" -ge 60 ]; then
    log "docker daemon not reachable after ~60s — proceeding anyway (best-effort)"
  fi

  if [ ! -s "$INPUT_FILE" ]; then
    log "no registration input at $INPUT_FILE — did gitea-act-runner-register.sh run?"
    exit 1
  fi

  EPH=""
  if [ "$(cat "$FLAGS_FILE" 2>/dev/null)" = "true" ]; then
    EPH="--ephemeral"
  fi

  # shellcheck disable=SC2086 # $EPH is a single optional flag token, never
  # attacker-controlled free text — it's derived from a literal "true"/
  # "false" comparison above.
  act_runner register --config "$CFG" $EPH < "$INPUT_FILE"

  shred -u "$INPUT_FILE"

  if [ ! -s "$STATE_DIR/.runner" ]; then
    log "act_runner register did not produce $STATE_DIR/.runner — registration failed"
    exit 1
  fi
  log "registered runner (labels/name staged by gitea-act-runner-register.sh, not repeated here)"
fi

exec act_runner daemon --config "$CFG"
