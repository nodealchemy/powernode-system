#!/bin/bash
# dev-cell-executor.sh — the autonomous campaign dev-loop, run as a ROOT
# supervisor over an UNPRIVILEGED sandbox (pnagent). Each iteration is TWO
# headless `claude -p` calls, both run AS PNAGENT via `runuser`, with the
# validate->push decision made entirely by THIS SCRIPT's own exit codes —
# never trusted from an LLM's self-report, and never made by code the
# agent itself could have influenced:
#
#   stage 1 (implement, pnagent): dev_next_task -> re-verify -> branch ->
#     test-first -> fix -> verify -> commit on the loop branch. STOPS
#     THERE — never runs `git push` (it doesn't even have the SSH deploy
#     key or GIT_SSH_COMMAND to do so), never calls dev_complete_task.
#   [executor.sh itself, root]: confirms the loop branch actually
#     advanced, fetches origin/develop over the EXPLICIT clone_url (never
#     the pnagent-writable "origin" remote — see the ROOT GIT SAFETY note
#     below), hands off to dev-cell-validate-pnagent.sh (pnagent) to
#     restore the IMMUTABLE validator machinery and run scripts/
#     validate.sh sandboxed, and only on that script's exit 0 does root
#     itself run a plain, UNFORCED `git push` (never --force/--force-
#     with-lease, never develop/master; there is no `--ff-only` flag for
#     `git push` — a plain push is already fast-forward-only on the
#     remote by default) — again over the explicit clone_url.
#   stage 2 (report, pnagent): reads the JSON file executor.sh (root)
#     wrote with the ALREADY-DECIDED outcome and calls
#     platform.dev_complete_task with exactly those fields — no judgment
#     left for it to exercise, and it runs AFTER the push, so it cannot
#     influence whether the push happened either.
#
# ROOT GIT SAFETY (CRITICAL — read before touching any `git`/`rootgit`
# call in this file): pnagent OWNS $WORKDIR, including its .git/
# directory. A malicious or compromised stage1 could plant
# .git/hooks/pre-push, `core.fsmonitor=<cmd>`, `remote.origin.url=
# ext::sh -c ...`, a `url.<x>.insteadOf` rewrite pointing at ext::, or a
# .gitattributes smudge/clean filter — any of which would execute AS
# ROOT the moment this script ran a bare `git` command inside that
# directory. Two mitigations, both required together:
#   1. `rootgit()` below wraps EVERY root-run git invocation with
#      -c core.hooksPath=/dev/null -c core.fsmonitor= -c
#      protocol.ext.allow=never -c protocol.file.allow=user -c
#      core.attributesFile=/dev/null (plus safe.directory, needed at all
#      just to let root operate on a directory it doesn't own). Verified
#      empirically against a REAL planted pre-push hook AND a REAL
#      url.insteadOf rewrite to ext:: — both fire without this wrapper,
#      neither fires with it.
#   2. Root's fetch/push target the EXPLICIT clone_url read from the
#      root-only gitea_credentials.json, NEVER the "origin" remote name —
#      a named remote resolves through pnagent-writable .git/config,
#      which `url.<x>.insteadOf` can rewrite even when the literal URL
#      passed on the command line is trusted; an explicit URL closes most
#      of that path, and protocol.ext.allow=never closes the rest (an
#      insteadOf rule CAN still rewrite an explicit URL — verified).
# Root's ONLY git operations are therefore: read-only rev-parse/show, the
# network fetch (needs the deploy key), and the network push (ditto).
# EVERY operation that actually touches/writes the working tree — the
# validator restore, running validate.sh, and reverting the tree back to
# HEAD afterward — runs AS PNAGENT via dev-cell-validate-pnagent.sh, so
# even an unexpected hook/filter firing there fires as the already-
# unprivileged sandbox user, never root.
#
# PRIVILEGE SEPARATION (see this module's manifest.yaml description for
# the full rationale): pnagent NEVER holds the Gitea deploy key, the
# node's own mTLS cert/key, or GIT_SSH_COMMAND. Its `claude` reaches /mcp
# through dev-cell-mcp-proxy.service (a separate root-owned process that
# IS the only thing holding the node cert) at a plain
# http://127.0.0.1:<port>/mcp — no cert material passed to pnagent at
# all, even though Claude Code has native CLAUDE_CODE_CLIENT_CERT/KEY mTLS
# support: handing pnagent the node key would let a compromised agent
# re-call dev_cell_bootstrap directly and mint itself a fresh deploy key.
# The residual: pnagent CAN still reach the Anthropic API (needs the key
# to run `claude` at all) — a cost-abuse exposure, not a credential-theft
# one.
#
# Runs as ROOT, started by systemd with ANTHROPIC_API_KEY staged (not yet
# exported) at $RUNTIME_DIRECTORY/api_key by this unit's ExecStartPre
# (reusing claude-tmux-fetch-credential.sh with CLAUDE_TMUX_USER=root —
# see dev-cell-executor.service; root reads the key itself and hands it
# to pnagent's `claude` process via `runuser --preserve-environment`,
# never a chowned file pnagent reads on its own). Assumes
# dev-cell-provision.service already produced a runnable checkout at
# $DEV_CELL_WORKDIR, chowned to pnagent, and dev-cell-mcp-proxy.service is
# already listening (systemd After=/Requires= on both).
set -euo pipefail

DEV_CELL_RUNTIME_DIR="${DEV_CELL_RUNTIME_DIR:-/run/dev-cell}"
PNAGENT_USER="${DEV_CELL_PNAGENT_USER:-pnagent}"
# BUG-D: must match dev-cell-provision.sh's WORKDIR default — the durable
# /persist workspace, not /home on the 512M tmpfs overlay.
WORKDIR="${DEV_CELL_WORKDIR:-/persist/dev-cell/workspace}"
DEV_LOOP_NAME="${DEV_LOOP_NAME:-dev-improve}"
LOOP_BRANCH="dev-loop/${DEV_LOOP_NAME}"
POLL_INTERVAL_ACTIVE="${POLL_INTERVAL_ACTIVE:-15}"
POLL_INTERVAL_IDLE="${POLL_INTERVAL_IDLE:-300}"
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-5}"
MCP_PROXY_BIND="${DEV_CELL_MCP_PROXY_BIND:-127.0.0.1}"
MCP_PROXY_PORT="${DEV_CELL_MCP_PROXY_PORT:-18443}"
MCP_PROXY_URL="http://${MCP_PROXY_BIND}:${MCP_PROXY_PORT}/mcp"
VALIDATE_PNAGENT_SCRIPT="${DEV_CELL_VALIDATE_PNAGENT_SCRIPT:-/usr/local/bin/dev-cell-validate-pnagent.sh}"

log() { echo "dev-cell-executor: $*"; }

# See the ROOT GIT SAFETY header comment. -C "$WORKDIR" is passed by each
# call site (not baked in here) so every invocation is self-evidently
# scoped, matching how it reads at each call site below.
rootgit() {
  git -c safe.directory="$WORKDIR" -c core.hooksPath=/dev/null -c core.fsmonitor= -c protocol.ext.allow=never -c protocol.file.allow=user -c core.attributesFile=/dev/null "$@"
}

# --- ANTHROPIC_API_KEY: read-then-delete exactly once, THIS (root)
# process's env only — never a systemd/claude argv (would leak into
# `ps`), mirroring claude-tmux-start.sh's handling of the same underlying
# secret. Handed to pnagent's `claude` invocations below via `runuser
# --preserve-environment`, which inherits this exported variable without
# ever writing it to a pnagent-readable file or passing it as argv.
API_KEY_FILE="${RUNTIME_DIRECTORY:-$DEV_CELL_RUNTIME_DIR}/api_key"
[ -r "$API_KEY_FILE" ] || { log "no Anthropic API key at $API_KEY_FILE — did the ExecStartPre credential fetch run?"; exit 1; }
export ANTHROPIC_API_KEY
ANTHROPIC_API_KEY="$(cat "$API_KEY_FILE")"
rm -f "$API_KEY_FILE"

[ -d "$WORKDIR/.git" ] || { log "no checkout at $WORKDIR — dev-cell-provision.service did not complete"; exit 1; }
cd "$WORKDIR"

# --- explicit clone_url, read once (root-only file; doesn't change
# mid-boot) — see the ROOT GIT SAFETY note on why fetch/push target this
# directly instead of the pnagent-writable "origin" remote name.
GITEA_FILE="$DEV_CELL_RUNTIME_DIR/gitea_credentials.json"
[ -r "$GITEA_FILE" ] || { log "no Gitea credentials at $GITEA_FILE — did dev-cell-bootstrap.service run?"; exit 1; }
CLONE_URL=$(jq -r '.clone_url // empty' "$GITEA_FILE")
[ -n "$CLONE_URL" ] || { log "gitea_credentials.json is missing clone_url"; exit 1; }

# --- MCP reachability: wait for the local proxy to be listening ----------
# systemd's After=/Requires=dev-cell-mcp-proxy.service on this unit
# guarantees that service was STARTED first, not that it's already
# accepting connections — poll briefly rather than race it, same
# defensive spirit as the pg_isready wait in the provisioning scripts.
# A raw TCP connect probe (bash's /dev/tcp), not an HTTP request: a GET
# to /mcp would be forwarded upstream and could legitimately hang open as
# an SSE stream per the streamable-HTTP transport spec, which a
# --max-time-bounded curl GET would then misreport as "not ready" on
# timeout. Connecting the socket and immediately closing it again avoids
# that ambiguity entirely — all this needs to know is "is something bound
# to the port yet".
proxy_ready=0
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/${MCP_PROXY_BIND}/${MCP_PROXY_PORT}") 2>/dev/null; then
    exec 3<&- 3>&-
    proxy_ready=1
    break
  fi
  sleep 1
done
[ "$proxy_ready" = "1" ] || { log "dev-cell-mcp-proxy never became reachable at ${MCP_PROXY_BIND}:${MCP_PROXY_PORT} after 30s"; exit 1; }

# NOTE on GIT_SSH_COMMAND scoping: dev-cell-git-ssh-env.sh is
# DELIBERATELY NOT sourced here at top level. `export`ing it into this
# script's own environment this early would make it a permanent part of
# the environment `run_claude_as_pnagent`'s `runuser -p
# (--preserve-environment)` calls inherit on EVERY iteration (stage1 AND
# stage2) below — exactly the credential leak privilege separation exists
# to prevent, even though pnagent still couldn't read the deploy_key FILE
# the command references (see confinement notes throughout this module).
# Defense in depth: it is instead sourced in a SUBSHELL at each of the
# TWO points that actually need it — the `rootgit fetch` and `rootgit
# push` below — verified empirically that a subshell-scoped `export`
# inside a sourced script does NOT leak into the parent shell's
# environment, and that the sourced script's fail-closed `return 1`
# correctly short-circuits the following `&&`-chained git command while
# still propagating its exit status out to the caller.

STAGE1_PROMPT=$(cat <<PROMPT_EOF
Run ONE iteration of the /dev-loop skill for loop "${DEV_LOOP_NAME}", with
these overrides for this fully-unattended dev-cell context:

- Follow .claude/skills/dev-loop/SKILL.md steps 1-7 exactly (pull,
  re-verify, branch, test-first, fix, verify, commit).
- STOP after step 7. Do NOT perform step 8 (dev_complete_task) — a
  separate, narrowly-scoped process independently re-runs
  scripts/validate.sh and attempts the push, then reports the outcome. Do
  NOT run \`git push\` yourself either (you do not have credentials to do
  so in this sandbox) — this is belt-and-suspenders on top of that.
- End your final turn with EXACTLY these three lines and nothing after
  them:
    DEV_CELL_TASK_ID: <the task id from dev_next_task, or NONE>
    DEV_CELL_STAGE1_OUTCOME: queue_empty|halted|passed|failed|blocked
    DEV_CELL_STAGE1_SUMMARY: <one-line summary for the operator>
  Use "passed" ONLY if you completed a step-7 commit on the loop branch.
  Use "queue_empty"/"halted" if dev_next_task returned either (TASK_ID:
  NONE in that case). Use "failed" for the 3-failed-attempts stop
  condition, "blocked" for a genuine architecture fork/scope expansion —
  neither of those involves a commit.
PROMPT_EOF
)

# $1=output text, $2..=secret values to strip before it is ever printed or
# logged. ${var//pat/repl} is a pure shell builtin — no argv/subprocess, so
# none of these secrets are ever visible via `ps`. Applied to EVERY
# transcript this script prints/logs, not just the two claude stages:
# scripts/validate.sh and `git push` output get the same treatment below,
# since either could in principle echo something derived from a secret
# path/file this root process has read.
redact() {
  local out="$1"; shift
  local secret
  for secret in "$@"; do
    [ -n "$secret" ] && out="${out//$secret/[REDACTED]}"
  done
  printf '%s' "$out"
}

# All the values this script ever redacts against, computed once per
# iteration where relevant (deploy_key/node.key are read fresh each call
# so a mid-run credential rotation would still be caught).
redact_all() {
  local out="$1" deploy_key_value node_key_value
  deploy_key_value=""; [ -r "$DEV_CELL_RUNTIME_DIR/deploy_key" ] && deploy_key_value="$(cat "$DEV_CELL_RUNTIME_DIR/deploy_key")"
  node_key_value=""; [ -r "$DEV_CELL_RUNTIME_DIR/node.key" ] && node_key_value="$(cat "$DEV_CELL_RUNTIME_DIR/node.key")"
  redact "$out" "$deploy_key_value" "$node_key_value" "$ANTHROPIC_API_KEY"
}

run_claude_as_pnagent() {
  # $1=prompt. Sets the CLAUDE_STATUS + CLAUDE_OUTPUT globals (does NOT print
  # to stdout — see BUG-N below re: why callers must NOT use $(...)).
  # `-p, --preserve-environment`: inherits THIS (root) PROCESS's exported
  # ANTHROPIC_API_KEY (needed) without also inheriting anything this
  # script never exports in the first place (GIT_SSH_COMMAND is scoped to
  # the fetch/push steps only, below — never exported at the top level,
  # so preserving the environment here cannot leak it). BUT `-p` preserves
  # HOME verbatim too — root's $HOME (/root), which pnagent cannot read
  # or write — verified empirically; without this override `claude`'s own
  # config/session directory resolution (~/.claude/) would try to write
  # into a directory pnagent has no access to. `env HOME=...` after `-p`
  # overrides just that one variable for this invocation while the rest
  # of the preserved environment (ANTHROPIC_API_KEY) still passes through
  # — also verified empirically.
  local prompt="$1" raw
  set +e
  raw=$(runuser -u "$PNAGENT_USER" -p -- env HOME="/home/$PNAGENT_USER" \
    claude -p "$prompt" \
    --mcp-config "{\"mcpServers\":{\"powernode\":{\"type\":\"http\",\"url\":\"${MCP_PROXY_URL}\"}}}" \
    --strict-mcp-config \
    --permission-mode bypassPermissions \
    --output-format text \
    2>&1)
  CLAUDE_STATUS=$?
  set -e
  # BUG-N: assign the redacted output to a GLOBAL rather than printing it to
  # stdout, so callers invoke this function WITHOUT command substitution. Under
  # $(...) the function ran in a subshell, so its CLAUDE_STATUS assignment was
  # set + discarded there and the caller's `STATUS=$CLAUDE_STATUS` died
  # "CLAUDE_STATUS: unbound variable" under `set -u` on iteration 1 — before any
  # stage ran. Callers now read $CLAUDE_STATUS + $CLAUDE_OUTPUT directly.
  CLAUDE_OUTPUT=$(redact_all "$raw")
}

# --- IMMUTABLE VALIDATOR: root fetches origin/develop over the EXPLICIT
# clone_url (never named "origin" — see ROOT GIT SAFETY) into FETCH_HEAD,
# then hands off ENTIRELY to dev-cell-validate-pnagent.sh (pnagent) to
# restore the validator machinery from FETCH_HEAD, run scripts/
# validate.sh, and revert the tree back to HEAD — sets VALIDATE_STATUS
# and prints redacted output. A stage1 commit that tampered with the
# validator itself (e.g. neutered a check in scripts/validate.sh, or the
# rspec/tsc config it reads — see that script's own H2-fix comment) is
# judged by develop's version instead, not its own. KNOWN EDGE CASE,
# human-reviewed: an increment that LEGITIMATELY needs to change the
# validator or its config is validated against develop's OLDER copy, not
# its own — acceptable since a human reviews the loop branch before it's
# ever merged past this gate, and app/config remain agent-authored so
# test-first work is still genuinely exercised.
run_immutable_validator() {
  # Guarded with `if ! ( ... )`, NOT left to `set -e`: a transient
  # network blip fetching develop should fail THIS iteration (reported
  # "failed", loop keeps running), not crash the whole executor process.
  if ! (
    # shellcheck source=dev-cell-git-ssh-env.sh
    . /usr/local/bin/dev-cell-git-ssh-env.sh && rootgit -C "$WORKDIR" fetch "$CLONE_URL" develop
  ); then
    log "could not fetch develop from $CLONE_URL — refusing to validate/push"
    VALIDATE_STATUS=1
    VALIDATE_OUTPUT="(immutable validator: git fetch develop failed — see executor log)"
    return
  fi

  set +e
  VALIDATE_OUTPUT=$(runuser -u "$PNAGENT_USER" -- env DEV_CELL_WORKDIR="$WORKDIR" bash "$VALIDATE_PNAGENT_SCRIPT" 2>&1)
  VALIDATE_STATUS=$?
  set -e
}

consecutive_failures=0

while true; do
  PRE_SHA=$(rootgit -C "$WORKDIR" rev-parse --verify -q "refs/heads/$LOOP_BRANCH" 2>/dev/null || true)

  run_claude_as_pnagent "$STAGE1_PROMPT"
  STAGE1_STATUS=$CLAUDE_STATUS
  STAGE1_OUTPUT=$CLAUDE_OUTPUT
  log "stage1 (implement, pnagent) exit=$STAGE1_STATUS"
  printf '%s\n' "$STAGE1_OUTPUT"

  if [ "$STAGE1_STATUS" -ne 0 ]; then
    consecutive_failures=$((consecutive_failures + 1))
    log "claude exited non-zero ($consecutive_failures/$MAX_CONSECUTIVE_FAILURES consecutive) — backing off ${POLL_INTERVAL_IDLE}s"
    if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
      log "giving up after $MAX_CONSECUTIVE_FAILURES consecutive claude failures — exiting so systemd's Restart=on-failure takes over"
      exit 1
    fi
    sleep "$POLL_INTERVAL_IDLE"
    continue
  fi

  TASK_ID=$(printf '%s\n' "$STAGE1_OUTPUT" | sed -n 's/^DEV_CELL_TASK_ID: *//p' | tail -n1)
  STAGE1_OUTCOME=$(printf '%s\n' "$STAGE1_OUTPUT" | sed -n 's/^DEV_CELL_STAGE1_OUTCOME: *//p' | tail -n1)
  STAGE1_SUMMARY=$(printf '%s\n' "$STAGE1_OUTPUT" | sed -n 's/^DEV_CELL_STAGE1_SUMMARY: *//p' | tail -n1)

  if [ -z "$STAGE1_OUTCOME" ]; then
    consecutive_failures=$((consecutive_failures + 1))
    log "could not parse a DEV_CELL_STAGE1_OUTCOME from claude's output ($consecutive_failures/$MAX_CONSECUTIVE_FAILURES consecutive) — backing off ${POLL_INTERVAL_IDLE}s"
    if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
      log "giving up after $MAX_CONSECUTIVE_FAILURES consecutive unparseable iterations — exiting so systemd's Restart=on-failure takes over"
      exit 1
    fi
    sleep "$POLL_INTERVAL_IDLE"
    continue
  fi

  consecutive_failures=0

  if [ "$STAGE1_OUTCOME" = "queue_empty" ] || [ "$STAGE1_OUTCOME" = "halted" ]; then
    log "$STAGE1_OUTCOME — sleeping ${POLL_INTERVAL_IDLE}s"
    sleep "$POLL_INTERVAL_IDLE"
    continue
  fi

  REPORT_FILE="$WORKDIR/.dev-cell-stage2-report.json"

  if [ "$STAGE1_OUTCOME" = "passed" ]; then
    # --- MECHANICAL gate below: THIS SCRIPT's own exit codes decide
    # validate + push, never claude's self-report. -----------------------
    POST_SHA=$(rootgit -C "$WORKDIR" rev-parse --verify -q "refs/heads/$LOOP_BRANCH" 2>/dev/null || true)
    if [ -z "$POST_SHA" ] || [ "$POST_SHA" = "$PRE_SHA" ]; then
      # stage1 said "passed" but the PARENT repo's loop branch didn't
      # actually advance — e.g. a submodule-only change (this dev-cell's
      # deploy key is scoped to ONE source repo; it cannot push
      # extensions/system's own separate Gitea repo — see
      # dev-cell-provision.sh's private-extensions step comment for the
      # same single-repo-scope limitation), or a self-report error. Treat
      # as failed rather than push/report something stale.
      log "stage1 reported passed but $LOOP_BRANCH has no new commit in $WORKDIR — not pushing"
      jq -n --arg loop "$DEV_LOOP_NAME" --arg task_id "$TASK_ID" \
        --arg summary "stage1 reported passed but the parent repo's $LOOP_BRANCH has no new commit (possible submodule-only change outside this cell's single-repo push scope, or a self-report error): $STAGE1_SUMMARY" \
        '{loop_id: $loop, task_id: $task_id, outcome: "failed", summary: $summary}' \
        > "$REPORT_FILE"
    else
      log "$LOOP_BRANCH advanced $PRE_SHA -> $POST_SHA — running the IMMUTABLE (develop) scripts/validate.sh, sandboxed as $PNAGENT_USER"
      run_immutable_validator
      VALIDATE_OUTPUT=$(redact_all "$VALIDATE_OUTPUT")
      VALIDATE_TAIL=$(printf '%s\n' "$VALIDATE_OUTPUT" | tail -n 60)
      log "scripts/validate.sh exit=$VALIDATE_STATUS"
      printf '%s\n' "$VALIDATE_OUTPUT"

      if [ "$VALIDATE_STATUS" -ne 0 ]; then
        jq -n --arg loop "$DEV_LOOP_NAME" --arg task_id "$TASK_ID" \
          --arg summary "scripts/validate.sh failed after implementation: $STAGE1_SUMMARY" \
          --arg check "$VALIDATE_TAIL" \
          '{loop_id: $loop, task_id: $task_id, outcome: "failed", summary: $summary, check_results: {validate_sh: $check}}' \
          > "$REPORT_FILE"
      else
        # Only the push itself runs as root — never agent code. Plain,
        # unforced push — git rejects this outright as non-fast-forward
        # if the remote branch has diverged. No --force/--force-with-lease,
        # ever. Same GIT_SSH_COMMAND subshell-scoping as the fetch above
        # (see the top-level NOTE) and the same explicit-clone_url +
        # rootgit wrapper as everywhere else root touches git (see ROOT
        # GIT SAFETY).
        set +e
        PUSH_OUTPUT=$(
          # shellcheck source=dev-cell-git-ssh-env.sh
          . /usr/local/bin/dev-cell-git-ssh-env.sh && rootgit -C "$WORKDIR" push "$CLONE_URL" "$LOOP_BRANCH" 2>&1
        )
        PUSH_STATUS=$?
        set -e
        PUSH_OUTPUT=$(redact_all "$PUSH_OUTPUT")
        log "git push $LOOP_BRANCH exit=$PUSH_STATUS"
        printf '%s\n' "$PUSH_OUTPUT"

        if [ "$PUSH_STATUS" -eq 0 ]; then
          FILES_JSON=$(rootgit -C "$WORKDIR" show --name-only --format= "$POST_SHA" | jq -R -s 'split("\n") | map(select(length > 0))')
          jq -n --arg loop "$DEV_LOOP_NAME" --arg task_id "$TASK_ID" --arg summary "$STAGE1_SUMMARY" \
            --arg branch "$LOOP_BRANCH" --arg sha "$POST_SHA" --arg check "$VALIDATE_TAIL" \
            --argjson files "$FILES_JSON" \
            '{loop_id: $loop, task_id: $task_id, outcome: "passed", summary: $summary, git_branch: $branch, commit_sha: $sha, files_changed: $files, check_results: {validate_sh: $check}}' \
            > "$REPORT_FILE"
        else
          # Never force — a non-fast-forward push means something else
          # moved the remote loop branch since claude committed.
          jq -n --arg loop "$DEV_LOOP_NAME" --arg task_id "$TASK_ID" \
            --arg summary "push to $LOOP_BRANCH rejected (non-fast-forward) — possible conflicting remote change: $STAGE1_SUMMARY" \
            '{loop_id: $loop, task_id: $task_id, outcome: "blocked", summary: $summary}' \
            > "$REPORT_FILE"
        fi
      fi
    fi
  else
    # failed / blocked from stage1 itself — nothing to validate or push.
    jq -n --arg loop "$DEV_LOOP_NAME" --arg task_id "$TASK_ID" --arg outcome "$STAGE1_OUTCOME" --arg summary "$STAGE1_SUMMARY" \
      '{loop_id: $loop, task_id: $task_id, outcome: $outcome, summary: $summary}' \
      > "$REPORT_FILE"
  fi

  # pnagent (stage2) needs to READ this file — it lives in the
  # pnagent-owned workspace, not $DEV_CELL_RUNTIME_DIR (root-only, see
  # dev-cell-bootstrap.sh). It carries no secrets (outcome/summary/
  # commit_sha/files_changed/a validate.sh tail — already redacted above)
  # but is still kept narrowly scoped: chowned to pnagent, 0600, and
  # removed immediately after stage2 reads it.
  chown "$PNAGENT_USER:$PNAGENT_USER" "$REPORT_FILE"
  chmod 600 "$REPORT_FILE"

  STAGE2_PROMPT=$(cat <<PROMPT_EOF
Read the JSON file at ${REPORT_FILE} and call platform.dev_complete_task
with exactly the fields it contains (its keys already match the tool's
argument names; omit any key whose value is null or empty). Do not re-run
verification, do not inspect the repo, do not form your own judgment about
the outcome — it has already been decided. Then stop.
PROMPT_EOF
)

  run_claude_as_pnagent "$STAGE2_PROMPT"
  STAGE2_STATUS=$CLAUDE_STATUS
  STAGE2_OUTPUT=$CLAUDE_OUTPUT
  log "stage2 (report, pnagent) exit=$STAGE2_STATUS"
  printf '%s\n' "$STAGE2_OUTPUT"

  rm -f "$REPORT_FILE"
  sleep "$POLL_INTERVAL_ACTIVE"
done
