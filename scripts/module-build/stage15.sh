#!/usr/bin/env bash
# stage15.sh — Stage 1.5 of the platform module build pipeline: stages
# parent-platform content + cross-compiles the Go agent for Class-B
# modules (the ones that ship source/vendored binaries instead of plain
# apt packages).
#
# Extracted VERBATIM (campaign 019f5885 inc6 — pure refactor, no logic
# changes) from the "Stage 1.5 — stage parent platform content (Class B
# modules)" step of .gitea/workflows/build-platform-modules.yaml: same
# commands, same order, same env semantics, same hardcoded /tmp/* scratch
# paths, same 11 `case "$MODULE"` arms (runtime-ruby, runtime-node,
# powernode-hub-backend, powernode-hub-worker, powernode-hub-frontend,
# powernode-extension-system, reverse-proxy-traefik, powernode-system-base,
# base-os-ubuntu-noble, claude-tmux, gitea-act-runner — the design note this
# increment worked from said "10"; an 11th arm (gitea-act-runner) landed in
# a later commit and is included here too, moved as-is) — so the staged
# /tmp/fat content this produces is byte-identical to the pre-refactor
# inline step. The workflow step is now a thin invocation of this script; a
# future on-node/native build (inc7+, driven by build-one-module.sh in this
# same directory) runs the identical script with no Gitea Actions context
# at all.
#
# A 12th arm, `module-forge`, landed in campaign 019f5885 inc7 (Part A) —
# this one is NOT a verbatim extraction of anything (there is no prior
# inline workflow step for it): it bakes module-forge's own /opt/buildenv
#
# A 13th arm, `tmux-manager`, landed later still: fetches
# github.com/rett/tmux-manager (pinned commit sha, no releases exist) and
# installs it via plain install(1) calls — see that arm's own comment.
#
# A 14th arm, `dev-cell-browser`, fetches a pinned-version, sha256-verified
# google-chrome-stable .deb directly from Google's own pool (no apt repo,
# no essential-hook) and dpkg-deb -x's it — see that arm's own comment.
# (a nested debian:trixie buildroot) + stages scripts/module-build/*.sh
# into /opt/module-build/, the two things the module-forge NodeModule
# needs to natively build OTHER modules on a fleet instance. See its case
# arm below and modules/module-forge/manifest.yaml for the full design
# rationale.
#
# Every value that varied by workflow context in the original inline step
# is threaded through as an explicit CLI arg below (never read from the
# process environment directly by this script — the workflow step / driver
# supplies them), using the SAME variable names the body already expected,
# so the extracted body needed exactly ONE line changed (the `ws=` line
# below no longer falls back to $GITHUB_WORKSPACE/$GITHUB_REPOSITORY):
#   $MODULE                  — was GITHUB_ENV-set by "Resolve build slot"
#                              (untouched); now --module.
#   $GITHUB_WORKSPACE          — was read directly by the inline step's own
#                              `ws="${GITHUB_WORKSPACE:-...}"` fallback
#                              expression; now required --workspace (no
#                              Actions-env fallback — the caller supplies
#                              it explicitly).
#   $PARENT_PAT                — was, and remains, the step's `env:` block,
#                              resolved by the WORKFLOW (not this script)
#                              from secrets.POWERNODE_PARENT_PAT ||
#                              secrets.POWERNODE_REGISTRY_TOKEN ||
#                              secrets.GITHUB_TOKEN. Deliberately NOT a CLI
#                              flag: per the platform's cryptographic
#                              material safety rule, secrets must never be
#                              passed as function/CLI arguments (visible in
#                              `ps`, shell history, and CI step logs) — this
#                              script reads it from the process environment
#                              exactly as the inline step did, so the
#                              caller's `env:` block is unchanged.
#   $POWERNODE_PARENT_HOST,
#   $POWERNODE_PARENT_PATH     — were ambient shell env vars the inline step
#                              read with defaults (never actually set
#                              anywhere in this workflow); now
#                              --parent-host / --parent-path, same
#                              defaults.
#   $ARCH                      — same story as the two above (ambient,
#                              never set, defaults to amd64); now --arch.
# Every /tmp/* path (fat rootfs, /tmp/parent clone, /tmp/manifest.json, the
# per-arm scratch downloads) is the SAME hardcoded literal the inline step
# used — not parameterized, since none of them are sourced from Actions
# context; they're the pipeline's existing shared-/tmp convention (the same
# container filesystem is shared by every step in a job), unchanged here.
#
# Usage:
#   PARENT_PAT=token stage15.sh --module MODULE --workspace DIR
#                                [--parent-host HOST]
#                                [--parent-path OWNER/REPO] [--arch amd64|arm64]
#
# Required:
#   --module MODULE             module slug (selects the case arm)
#   --workspace DIR              checked-out repo root (was
#                                $GITHUB_WORKSPACE) — this script `cd`s
#                                here; the powernode-system-base arm reads
#                                agent/go.mod and cross-compiles agent/,
#                                the powernode-extension-system arm reads
#                                server/ + extension.json, all relative to
#                                this directory
#
# Optional:
#   PARENT_PAT (env var, NOT a flag)  PAT for cloning the parent
#                                powernode-platform repo (only used by the
#                                powernode-hub-backend/worker/frontend and
#                                powernode-extension-system arms — the last
#                                needs core's frontend/ to build this
#                                extension's dedicated-module bundle against
#                                its host-api/modules.ts contract); default:
#                                empty. Set in the calling
#                                environment (the workflow step's `env:`
#                                block) — never pass secrets as CLI args.
#   CORE_REF (env var, NOT a flag)   the core (parent powernode-platform)
#                                commit this batch must be assembled from —
#                                the batch's own expected_core_sha, set by
#                                the platform at dispatch and delivered via
#                                ci_build_context -> the agent's
#                                ci.module_build handler -> module-forge-
#                                build.sh's export -> here, by plain process-
#                                environment inheritance (same channel as
#                                PARENT_PAT, though this one is NOT a
#                                secret; it is an env var because it varies
#                                PER BATCH, unlike the static --parent-*
#                                config flags). When set, the Class-B arm
#                                fetches EXACTLY that ref and fails the
#                                build if the remote does not have it —
#                                there is deliberately no fallback. When
#                                unset (the Gitea Actions path; a batch
#                                whose core tip would not resolve) the arm
#                                clones the remote's default branch and says
#                                UNPINNED out loud. Default: empty.
#   --parent-host HOST             default: github.com (PUBLIC repo)
#   --parent-path OWNER/REPO       default: nodealchemy/powernode-platform
#   --arch amd64|arm64             default: amd64
#
# Reads:  /tmp/manifest.json (produced by the workflow's untouched "Parse
#         manifest" step) for build.ruby_version / build.node_version /
#         build.act_runner_version; /tmp/fat (Stage 1's output, layered
#         onto here)
# Writes: /tmp/fat (Class-B content layered on top), /tmp/parent (parent
#         repo clone, hub-* arms only)
#
# Exit: non-zero on any arm's failure (set -euo pipefail propagates the
# first one); several arms also have explicit FATAL guards (e.g. the agent
# binary size/symlink check, the npm-install-landed check).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: PARENT_PAT=token stage15.sh --module MODULE --workspace DIR
                                    [--parent-host HOST]
                                    [--parent-path OWNER/REPO] [--arch amd64|arm64]

Stage 1.5 of the module build pipeline: stages parent-platform content +
cross-compiles the Go agent for Class-B modules. See the file header for
the full option reference and the workflow-env-var mapping. PARENT_PAT is
a secret — set it in the environment, never as a CLI argument.
EOF
}

die() {
  echo "stage15.sh: error: $*" >&2
  exit 2
}

MODULE=""
WORKSPACE=""
# PARENT_PAT is deliberately NOT initialized/parsed as a CLI flag — it's a
# secret, read only from the process environment (see file header). The
# `:-` default keeps this safe under `set -u` when the caller (e.g. a
# Class-A-only local run) never set it.
PARENT_PAT="${PARENT_PAT:-}"
POWERNODE_PARENT_HOST="github.com"
POWERNODE_PARENT_PATH="nodealchemy/powernode-platform"
ARCH="amd64"

while [ $# -gt 0 ]; do
  case "$1" in
    --module)
      [ $# -ge 2 ] || die "--module requires an argument"
      MODULE="$2"; shift 2 ;;
    --workspace)
      [ $# -ge 2 ] || die "--workspace requires an argument"
      WORKSPACE="$2"; shift 2 ;;
    --parent-host)
      [ $# -ge 2 ] || die "--parent-host requires an argument"
      POWERNODE_PARENT_HOST="$2"; shift 2 ;;
    --parent-path)
      [ $# -ge 2 ] || die "--parent-path requires an argument"
      POWERNODE_PARENT_PATH="$2"; shift 2 ;;
    --arch)
      [ $# -ge 2 ] || die "--arch requires an argument"
      ARCH="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

[ -n "$MODULE" ] || { usage >&2; die "--module is required"; }
[ -n "$WORKSPACE" ] || { usage >&2; die "--workspace is required"; }

# ---------------------------------------------------------------------------
# Everything below is VERBATIM from the workflow's Stage 1.5 step body,
# except the `ws=` line: the original read $GITHUB_WORKSPACE (with a
# $GITHUB_REPOSITORY-based fallback) directly; here it's simply the
# --workspace value from the arg parsing above. Every other reference
# (PARENT_PAT, POWERNODE_PARENT_HOST, POWERNODE_PARENT_PATH, ARCH, MODULE,
# and every /tmp/* path) is byte-for-byte identical to the inline step —
# those variable NAMES are unchanged, only now populated by this script's
# arg parsing instead of the workflow step's `env:`/ambient shell
# environment.
# ---------------------------------------------------------------------------

ws="$WORKSPACE"
cd "$ws"

# --- BEGIN stale-provenance clear ---
# Core-source provenance (IMP-b2aebb9f4b17): drop any file a PREVIOUS job on
# this runner left behind BEFORE deciding whether this module clones a parent.
# A Gitea runner reuses /tmp across jobs, so a stale file would let a module
# that clones no parent inherit the previous module's core sha — the same
# silently-wrong provenance this capture exists to remove. After this line the
# file exists only if THIS run's Class-B arm wrote it.
rm -f /tmp/parent-provenance.env
# --- END stale-provenance clear ---

needs_parent=0
case "$MODULE" in
  powernode-hub-backend|powernode-hub-worker|powernode-hub-frontend|powernode-extension-system) needs_parent=1 ;;
esac

if [ "$needs_parent" = "1" ]; then
  parent_host="${POWERNODE_PARENT_HOST:-github.com}"
  parent_path="${POWERNODE_PARENT_PATH:-nodealchemy/powernode-platform}"

  # powernode-platform is the PUBLIC MIT repo and is sourced from GitHub, not
  # from a private Gitea. The previous default (git.powernode.org) is a
  # DIFFERENT Gitea from the one releases are pushed to, so its parent clone
  # lacked commits the extension frontend imports — extension-system builds
  # died at "Rollup failed to resolve import @/shared/components/charts" from
  # 2026-08-06 onward. GitHub's default branch for this repo is `develop`, so
  # the credential-free --depth 1 clone below lands on the right ref.
  #
  # Credentials are OMITTED for a public host: PARENT_PAT is the Gitea token
  # (config_controller sends the GitProvider's access_token as parent_pat), and
  # injecting it as x-access-token into a github.com URL can 401 even on a
  # public repo. Keep the token form only for a private host.
  case "$parent_host" in
    github.com|*.github.com) clone_url="https://${parent_host}/${parent_path}.git" ;;
    *)
      if [ -n "${PARENT_PAT:-}" ]; then
        clone_url="https://x-access-token:${PARENT_PAT}@${parent_host}/${parent_path}.git"
      else
        clone_url="https://${parent_host}/${parent_path}.git"
      fi
      ;;
  esac

  # --- BEGIN per-batch core-ref pin ---
  # $CORE_REF is the core (parent powernode-platform) commit the PLATFORM
  # decided, at dispatch, that this batch must be assembled from. It is the
  # batch's own metadata["expected_core_sha"] — the SAME value
  # System::CoreMirrorPreflight compares the mirror's HEAD against before any
  # builder is leased, and the SAME value System::CoreProvenanceGate compares
  # the published artifact's org.powernode.core_source_sha annotation against
  # at promote. One field, three layers: they cannot disagree about what "the
  # expected core" is.
  #
  # It reaches this script the way PARENT_PAT does — process-environment
  # inheritance, set by the agent's ci.module_build handler from
  # ci_build_context's `core_ref` and exported through the chroot by
  # module-forge-build.sh. It is NOT a credential and NOT a CLI arg (the two
  # CLI knobs here, --parent-host/--parent-path, are static config; this one is
  # per-batch).
  #
  # ACCEPTED CONSEQUENCE, decided by the operator: $clone_url still points at
  # the public MIRROR (github.com), which is pushed separately from the Gitea
  # core actually lands on. Pinning therefore converts "the mirror lags -> we
  # silently ship stale core" into "the mirror lags -> this build FAILS until
  # the mirror is pushed". That is the trade. It is not to be softened.
  core_ref="${CORE_REF:-}"
  clone_remote="${parent_host}/${parent_path}"

  if [ -n "$core_ref" ]; then
    echo "Fetching parent ${clone_remote} at pinned core ref ${core_ref}..."

    # WHY NOT `git clone --depth 1 --branch`: --branch takes a branch or tag
    # NAME only and REJECTS a raw commit sha, so it cannot express this pin at
    # all. init + remote add + fetch <ref> + checkout --detach FETCH_HEAD is
    # the only form that fetches an ARBITRARY ref (a full sha included) at
    # depth 1. It needs the server to honour fetch-by-sha
    # (uploadpack.allowReachableSHA1InWant), which github.com does.
    #
    # ############################################################
    # DO NOT ADD A FALLBACK ARM TO ANY LINE BELOW. NOT `|| git clone ...`,
    # not `|| git fetch origin HEAD`, not a retry that drops the ref.
    #
    # This is not a style rule. An unpinned clone here IS the 2026-08-15
    # incident: hub-backend v71 shipped with three-day-old core, passed every
    # checkpoint the platform had (real oci_digest, real fs-verity root, valid
    # signature, batch success, auto-promote), reached the fleet, and cost two
    # outages. It was found by unpacking the layer and diffing a file by hand.
    # A `||` here restores exactly that, and restores it SILENTLY.
    #
    # A failed pinned fetch means the remote does not have the commit this
    # batch was dispatched against. The correct outcome is a RED BUILD.
    # `set -euo pipefail` (line 139) already makes an unhandled failure fatal;
    # the explicit `if !` forms below exist so there is no `||` for anyone to
    # innocently extend.
    # ############################################################
    # `git init <dir>` creates the directory itself, so no mkdir. The rm gets
    # its own named failure: everything else in this block dies with a message
    # naming the ref and the remote, and a bare `set -e` abort here would be
    # the one silent exit on the pinned path.
    rm -rf /tmp/parent || die "could not clear /tmp/parent before the pinned fetch of ${core_ref}" \
                              "from ${clone_remote}"
    git init -q /tmp/parent
    git -C /tmp/parent remote add origin "$clone_url"

    # git's OWN stderr is redacted before it is shown. The remote is
    # $clone_url, which for a PRIVATE host embeds PARENT_PAT in its userinfo
    # (see the case statement above), and git prints the configured remote
    # verbatim on a failed fetch. That failure is no longer exceptional — it
    # is the DESIGNED outcome whenever the mirror lags — so this path now runs
    # routinely and must not become a recurring credential leak into the build
    # log. Captured to a file rather than a process substitution so git's exit
    # status is unambiguous under `set -e` and there is no async interleaving.
    #
    # Today $parent_host defaults to github.com, whose URL carries no
    # credential at all; this is the guard for the day it does not.
    fetch_err="/tmp/parent-fetch.err"
    fetch_ok=1
    git -C /tmp/parent fetch --depth 1 origin "$core_ref" 2>"$fetch_err" || fetch_ok=0
    sed -E 's#//[^@/]*@#//#g' "$fetch_err" >&2 || true
    rm -f "$fetch_err"

    if [ "$fetch_ok" != "1" ]; then
      # BOTH the ref AND the remote: the incident was a RIGHT ref name on a
      # STALE MIRROR, and a message naming only one of the two reads as
      # entirely plausible while sending the operator to the wrong place.
      # $clone_remote, never $clone_url — for a private host that URL embeds
      # PARENT_PAT in its userinfo and this text is logged.
      die "could not fetch pinned core ref ${core_ref} from ${clone_remote} — that remote does not" \
          "have this batch's core commit (the public mirror is pushed SEPARATELY from the Gitea core" \
          "lands on, and lags). Push the mirror and re-dispatch. Building an UNPINNED parent instead" \
          "is what shipped stale core on 2026-08-15."
    fi

    git -C /tmp/parent checkout --detach FETCH_HEAD

    # ASSERT the pin actually took. "the fetch succeeded" and "we are standing
    # on that commit" are different claims, and a REF NAME can resolve
    # anywhere — which is precisely how this bug happened. Only meaningful
    # when $core_ref is a full commit identity; a 40-hex sha names exactly one
    # object, whereas an abbreviation or a branch name does not, so the
    # comparison is conditional on the shape rather than skipped or faked.
    # (The platform only ever sends 40-hex today — see
    # ConfigController#pinned_core_ref — so this arm is the live one.)
    if [[ "$core_ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
      resolved_head="$(git -C /tmp/parent rev-parse --verify HEAD)"
      want_ref="$(printf '%s' "$core_ref" | tr 'A-Z' 'a-z')"
      got_ref="$(printf '%s' "$resolved_head" | tr 'A-Z' 'a-z')"
      if [ "$got_ref" != "$want_ref" ]; then
        die "pinned parent fetch landed on ${got_ref} but this batch pinned core ${core_ref}" \
            "(remote ${clone_remote}) — the pin is NOT what was checked out"
      fi
      echo "[stage-1.5] parent PINNED to ${core_ref} from ${clone_remote} (identity VERIFIED)"
    else
      # A ref that is not a full commit identity was fetched successfully, but
      # nothing was verified — and saying "PINNED" here would report a NAME
      # that resolved on a mirror as a pin, which is the 2026-08-15 incident
      # restated in the reassuring direction. The platform never sends this
      # shape (ConfigController#pinned_core_ref requires 40-hex); a hand run or
      # the Gitea workflow could.
      echo "[stage-1.5] WARNING: CORE_REF ${core_ref} is not a 40-hex commit — it was fetched from" \
           "${clone_remote} but NOT verified; a name can resolve to a different commit on a mirror" >&2
      echo "[stage-1.5] parent fetched at ref ${core_ref} from ${clone_remote} (identity NOT verified)"
    fi
  else
    # No pin supplied. This is a REAL, non-fabricated state, not an error:
    #   - the legacy Gitea Actions path (.gitea/workflows/build-platform-
    #     modules.yaml) calls this script with no CORE_REF at all;
    #   - a native batch whose core tip would not resolve records no
    #     expectation, deliberately (NativeModuleBuildOrchestrator
    #     #record_expected_core_ref! never fabricates one, and
    #     CoreProvenanceGate stays inert for that batch rather than refusing
    #     good builds forever).
    # So it still builds — but it must NEVER read as if it were pinned. The
    # failure mode this whole mechanism exists to remove is a protection that
    # looks present and is not.
    echo "[stage-1.5] WARNING: no CORE_REF supplied — parent clone is UNPINNED; this build takes" \
         "whatever ${clone_remote} HEAD points at right now, which may not be the core this batch" \
         "expects" >&2
    echo "Cloning parent ${clone_remote} (UNPINNED)..."
    git clone --depth 1 "$clone_url" /tmp/parent
  fi
  # --- END per-batch core-ref pin ---

  # --- BEGIN core-source provenance capture ---
  # Record WHICH core commit this build actually landed on (IMP-b2aebb9f4b17).
  #
  # STILL REQUIRED AFTER THE CORE-REF PIN ABOVE, for two independent reasons:
  # (1) the unpinned arm exists and is reachable (no CORE_REF supplied — the
  # Gitea Actions path, a batch with no resolved core tip), and there the
  # commit is knowable only here, after the fact; (2) even on the pinned arm
  # this is the value the PROMOTE gate reads, and a provenance capture that
  # trusted the pin instead of measuring the checkout would be attesting to an
  # intention rather than to what is on disk — the whole class of defect this
  # exists to close. Measure, do not assume. Downstream, `built_from_sha` is
  # the MODULE-SOURCE sha (this repo), not core; without this capture a Class-B
  # artifact assembled from a stale core mirror reports IDENTICALLY to a correct
  # one at every checkpoint (real oci_digest, real fsverity root, batch success,
  # promotion proceeds). That is what shipped hub-backend v71 with three-day-old
  # core on 2026-08-15 and cost two outages; it was found only by unpacking the
  # layer and diffing a file by hand.
  #
  # The REMOTE is recorded alongside the sha because that incident was a correct
  # branch name on a STALE MIRROR — github.com and git.powernode.net both carried
  # a `develop`, three days apart. A sha alone would have looked plausible.
  #
  # DEFENSIVE: a rev-parse failure records `unknown` rather than aborting the
  # build or omitting the key — an absent value must never be indistinguishable
  # from a successful one. `|| true` keeps `set -e` from killing the build here.
  #
  # `--verify` is load-bearing, not decoration. A BARE `git rev-parse HEAD` on a
  # repo with an UNBORN head prints the literal string "HEAD" to STDOUT (exit
  # 128), which `|| true` swallows and the non-empty test then accepts — writing
  # `core_source_sha=HEAD`, a fourth state that is neither a sha nor `unknown`
  # and reads like an answer. That is reachable: `git clone --depth 1` of an
  # empty/freshly-created parent mirror exits 0, and the extension-system arm
  # below tolerates a parent with no frontend/package.json, so the module would
  # build green and stamp "HEAD" permanently onto the published artifact.
  # `--verify` prints nothing on failure, which is what the fallback needs.
  #
  # CREDENTIAL SAFETY: the remote recorded is ${parent_host}/${parent_path},
  # NEVER $clone_url — for a private host that URL embeds PARENT_PAT in its
  # userinfo. This value flows into the build result JSON and into an OCI
  # annotation on the published artifact, both persisted and human-read; a token
  # here would be a permanent cleartext leak.
  core_source_sha="$(git -C /tmp/parent rev-parse --verify HEAD 2>/dev/null || true)"
  [ -n "$core_source_sha" ] || core_source_sha="unknown"
  {
    printf 'core_source_sha=%s\n' "$core_source_sha"
    printf 'core_source_remote=%s\n' "${parent_host}/${parent_path}"
  } > /tmp/parent-provenance.env
  echo "[stage-1.5] core provenance: ${core_source_sha} from ${parent_host}/${parent_path}"

  # --- BEGIN build identity (BUILD_INFO.json) ---
  # What the running platform can truthfully say about itself. The staged
  # server/worker trees ship WITHOUT .git (see the rsync --exclude below), so
  # Powernode::Version's `git rev-parse` is structurally "unknown" on a node,
  # and the Vite bundle is static files behind Caddy with no runtime env at
  # all. This file is the ONE carrier for both: it is copied into
  # /opt/powernode/{server,worker}/BUILD_INFO.json and exported as
  # POWERNODE_BUILD_INFO_JSON to the frontend build (vite.config.ts bakes it
  # into the __BUILD_INFO__ define).
  #
  # `release` is deliberately strict: an exact X.Y.Z tag (no "v" prefix —
  # CLAUDE.md's convention) that equals the VERSION file AND refs/heads/master
  # pointing at this very commit. A hotfix on master past the tag, a develop
  # build, or a build of a tag whose VERSION file disagrees all display the
  # 7-char sha instead. The parent clone is depth-1 and detached, so branch
  # and tag are read from the remote's refs (ls-remote), never from the
  # checkout; output is never echoed because the origin URL can carry a token.
  build_version="$(tr -d '[:space:]' < /tmp/parent/VERSION 2>/dev/null || true)"
  [ -n "$build_version" ] || build_version="0.0.0"
  build_short_sha="$(printf '%s' "$core_source_sha" | cut -c1-7)"
  remote_refs="$(git -C /tmp/parent ls-remote --heads --tags origin 2>/dev/null || true)"
  build_tag="$(printf '%s\n' "$remote_refs" | awk -v s="$core_source_sha" '$1==s && $2 ~ /^refs\/tags\// { t=$2; sub("^refs/tags/","",t); sub("\\^\\{\\}$","",t); print t }' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
  master_sha="$(printf '%s\n' "$remote_refs" | awk '$2=="refs/heads/master" {print $1}' | head -1)"
  branch_candidates="$(printf '%s\n' "$remote_refs" | awk -v s="$core_source_sha" '$1==s && $2 ~ /^refs\/heads\// { b=$2; sub("^refs/heads/","",b); print b }')"
  if printf '%s\n' "$branch_candidates" | grep -qx master; then
    build_branch=master
  elif printf '%s\n' "$branch_candidates" | grep -qx develop; then
    build_branch=develop
  else
    build_branch="$(printf '%s\n' "$branch_candidates" | head -1)"
  fi
  [ -n "$build_branch" ] || build_branch="unknown"
  build_release=false
  if [ -n "$build_tag" ] && [ "$build_tag" = "$build_version" ] && [ -n "$master_sha" ] && [ "$master_sha" = "$core_source_sha" ]; then
    build_release=true
  fi
  build_built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"version":"%s","sha":"%s","short_sha":"%s","branch":"%s","tag":%s,"release":%s,"built_at":"%s","source":"module-build"}\n' \
    "$build_version" "$core_source_sha" "$build_short_sha" "$build_branch" \
    "$( [ -n "$build_tag" ] && printf '"%s"' "$build_tag" || printf null )" "$build_release" "$build_built_at" \
    > /tmp/parent-build-info.json
  echo "[stage-1.5] build identity: version=${build_version} sha=${build_short_sha} branch=${build_branch} tag=${build_tag:-none} release=${build_release}"
  # --- END build identity ---
  # --- END core-source provenance capture ---
fi

case "$MODULE" in
  runtime-ruby)
    # Noble's apt `ruby` is 3.2.3; the platform pins 3.2.8
    # (server/.ruby-version), and the dev-cell module composes
    # this runtime specifically so scripts/validate.sh runs
    # against the app's EXACT toolchain — an ABI-compatible
    # 3.2.x isn't enough. package_spec therefore no longer
    # lists ruby/ruby-dev/bundler (Noble's apt build); it lists
    # build-essential + the standard Ruby source-build deps
    # instead (libssl-dev, libyaml-dev, libffi-dev,
    # libreadline-dev, libgdbm-dev, libncurses-dev, libgmp-dev,
    # autoconf, bison — all already in /tmp/fat from Stage 1's
    # mmdebstrap), and this arm compiles Ruby from source.
    RUBY_VER=$(jq -r '.build.ruby_version // "3.2.8"' /tmp/manifest.json)
    RUBY_MINOR="${RUBY_VER%.*}"

    # --- Resolve on the RUNNER, never inside the chroot -----
    # mmdebstrap's minbase rootfs has no guaranteed working DNS,
    # so /tmp/fat can't be relied on to reach the network.
    # Fetch + verify the Ruby source tarball and the bundler
    # .gem here, then hand the chroot already-verified local
    # files — it never touches the network itself.
    #
    # Pinned sha256 for ruby-${RUBY_VER}.tar.gz, published at
    # https://www.ruby-lang.org/en/news/2025/03/26/ruby-3-2-8-released/
    # (cross-checked against an independent download). Bump
    # this alongside `build.ruby_version` in manifest.yaml on
    # any version change — a mismatch fails the build rather
    # than shipping an unverified interpreter.
    RUBY_SHA256="77acdd8cfbbe1f8e573b5e6536e03c5103df989dc05fa68c70f011833c356075"
    curl -fsSL "https://cache.ruby-lang.org/pub/ruby/${RUBY_MINOR}/ruby-${RUBY_VER}.tar.gz" -o /tmp/ruby-src.tar.gz
    echo "${RUBY_SHA256}  /tmp/ruby-src.tar.gz" | sha256sum -c -

    # Bundler 2.7.1 (matching the platform Gemfile.lock's
    # BUNDLED WITH, same pin hub-backend/hub-worker install
    # below). `gem fetch` downloads the .gem without installing
    # it — use the runner's own ruby (apt-installed on demand)
    # just to resolve it.
    if ! command -v gem >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends ruby
    fi
    ( cd /tmp && gem fetch bundler -v 2.7.1 )
    test -s /tmp/bundler-2.7.1.gem || { echo "[stage-1.5] FATAL: bundler-2.7.1.gem fetch failed"; exit 1; }

    # --- Compile INSIDE /tmp/fat -----------------------------
    # Ruby must link against the EXACT libssl/libyaml/zlib this
    # module ships (not the runner's own), so build inside the
    # chroot. configure/make redirect heavily to /dev/null and a
    # bare mmdebstrap rootfs has no populated /dev. The CI runner
    # container forbids mount --bind (no CAP_SYS_ADMIN — the bind
    # failed "permission denied", and mmdebstrap itself logs
    # "skipping mount proc" for the same reason), so mknod the few
    # device nodes configure/make need directly: CAP_MKNOD IS
    # available (mmdebstrap --mode=root already used it to bootstrap
    # the rootfs) and chroot works (mmdebstrap chroots to install
    # packages). file_spec is /usr,/lib,/etc only, so these /dev
    # nodes are never carved into the shipped erofs — no cleanup needed.
    mkdir -p /tmp/fat/usr/src /tmp/fat/dev
    cp /tmp/ruby-src.tar.gz "/tmp/fat/usr/src/ruby-${RUBY_VER}.tar.gz"
    cp /tmp/bundler-2.7.1.gem /tmp/fat/usr/src/bundler-2.7.1.gem
    for node in "null c 1 3" "zero c 1 5" "full c 1 7" "random c 1 8" "urandom c 1 9" "tty c 5 0"; do
      # shellcheck disable=SC2086  # intentional word-splitting: unpacks the "name type major minor" tuple positionally (verbatim from the original inline workflow step)
      set -- $node
      [ -e "/tmp/fat/dev/$1" ] || mknod -m 666 "/tmp/fat/dev/$1" "$2" "$3" "$4" || true
    done

    echo "[stage-1.5] compiling ruby ${RUBY_VER} inside /tmp/fat chroot…"
    chroot /tmp/fat /bin/sh -c "
      set -e
      export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      cd /usr/src
      tar xzf ruby-${RUBY_VER}.tar.gz
      cd ruby-${RUBY_VER}
      ./configure --prefix=/usr/local --disable-install-doc --enable-shared
      make -j\$(nproc)
      make install
      ldconfig
    "
    chroot /tmp/fat /usr/local/bin/gem install --local /usr/src/bundler-2.7.1.gem --no-document

    rm -rf /tmp/fat/usr/src

    # --- Verify what actually shipped ------------------------
    echo "[stage-1.5] verifying compiled toolchain…"
    RUBY_OUT=$(chroot /tmp/fat /usr/local/bin/ruby -v)
    echo "$RUBY_OUT"
    echo "$RUBY_OUT" | grep -q "ruby ${RUBY_VER}" || { echo "[stage-1.5] FATAL: expected ruby ${RUBY_VER}, got: $RUBY_OUT"; exit 1; }
    BUNDLER_OUT=$(chroot /tmp/fat /usr/local/bin/bundler -v)
    echo "$BUNDLER_OUT"
    echo "$BUNDLER_OUT" | grep -q "2.7.1" || { echo "[stage-1.5] FATAL: expected bundler 2.7.1, got: $BUNDLER_OUT"; exit 1; }
    ;;
  runtime-node)
    # Noble's apt `nodejs` is v18 (no npm, too old for the frontend's
    # engines >=24.9.0, and it SIGABRTs on V8 snapshot init in the
    # pivot environment even as bare root). Ship the official prebuilt
    # Node binary instead — no source compile (unlike runtime-ruby),
    # just fetch + verify + extract the linux-x64 tarball into
    # /usr/local. (imp 605b / BUG-E)
    NODE_VER=$(jq -r '.build.node_version // "24.13.0"' /tmp/manifest.json)

    # Pinned sha256 for node-v${NODE_VER}-linux-x64.tar.gz from
    # https://nodejs.org/dist/v${NODE_VER}/SHASUMS256.txt (the .gz, not
    # .xz — gzip needs no xz-utils on the runner). Bump this alongside
    # build.node_version + frontend/.nvmrc on any version change; a
    # mismatch fails the build rather than shipping an unverified
    # runtime. Fetch on the RUNNER (the mmdebstrap minbase rootfs has
    # no guaranteed DNS), then extract the already-verified local file.
    NODE_SHA256="6223aad1a81f9d1e7b682c59d12e2de233f7b4c37475cd40d1c89c42b737ffa8"
    curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-x64.tar.gz" -o /tmp/node.tar.gz
    echo "${NODE_SHA256}  /tmp/node.tar.gz" | sha256sum -c -

    # Extract into /tmp/fat/usr/local, stripping the
    # node-v*-linux-x64/ top dir, so /usr/local/bin/{node,npm,npx} +
    # /usr/local/lib/node_modules land where file_spec (/usr/local/**)
    # carves them into the shipped erofs.
    mkdir -p /tmp/fat/usr/local
    tar -xzf /tmp/node.tar.gz -C /tmp/fat/usr/local --strip-components=1

    # Verify what shipped. The prebuilt binary links against glibc +
    # libstdc++ (the runner has both; base-os provides them at runtime)
    # so it runs on the runner for a version check.
    NODE_OUT=$(/tmp/fat/usr/local/bin/node -v)
    echo "[stage-1.5] node: $NODE_OUT"
    echo "$NODE_OUT" | grep -q "v${NODE_VER}" || { echo "[stage-1.5] FATAL: expected node v${NODE_VER}, got: $NODE_OUT"; exit 1; }
    test -x /tmp/fat/usr/local/bin/npm || { echo "[stage-1.5] FATAL: npm missing from node tarball"; exit 1; }
    ;;
  runtime-go)
    # Go toolchain, fetched + sha256-pinned here so it ships INSIDE the signed
    # erofs. Same hermetic pattern as runtime-node above. Deliberately not an
    # apt package: noble ships Go 1.22, below the `go 1.25.0` directive in
    # extensions/system/agent/go.mod, and go(1) refuses to build when the
    # toolchain is older than the directive.
    GO_VER=$(jq -r '.build.go_version // "1.25.0"' /tmp/manifest.json)

    # Official checksums from https://go.dev/dl/?mode=json for go${GO_VER}.
    # Bump BOTH arches alongside build.go_version on any version change.
    case "${ARCH:-amd64}" in
      amd64) GO_SHA256=2852af0cb20a13139b3448992e69b868e50ed0f8a1e5940ee1de9e19a123b613 ;;
      arm64) GO_SHA256=05de75d6994a2783699815ee553bd5a9327d8b79991de36e38b66862782f54ae ;;
      *) echo "[stage-1.5] FATAL: no pinned go sha256 for ARCH=${ARCH:-amd64}"; exit 1 ;;
    esac

    curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${ARCH:-amd64}.tar.gz" -o /tmp/go.tar.gz
    echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c -

    # Upstream tarball contains a top-level go/ directory: extracting to
    # /usr/local yields the canonical /usr/local/go layout. NO --strip-components
    # here (unlike node, whose tarball is node-vX/bin/... and must be flattened).
    mkdir -p /tmp/fat/usr/local
    tar -xzf /tmp/go.tar.gz -C /tmp/fat/usr/local

    # Symlink the two user-facing entrypoints onto the default PATH so no
    # profile.d wiring is needed anywhere downstream. Relative targets so the
    # links resolve identically in the builder chroot and on the composed node.
    mkdir -p /tmp/fat/usr/local/bin
    ln -sf ../go/bin/go    /tmp/fat/usr/local/bin/go
    ln -sf ../go/bin/gofmt /tmp/fat/usr/local/bin/gofmt

    # Verify what actually shipped, on the runner (amd64-only exec, same caveat
    # as the act_runner arm: a cross-arch fetch is covered by the sha256 above).
    if [ "${ARCH:-amd64}" = "amd64" ]; then
      GO_OUT=$(/tmp/fat/usr/local/go/bin/go version)
      echo "[stage-1.5] go: $GO_OUT"
      echo "$GO_OUT" | grep -q "go${GO_VER}" || { echo "[stage-1.5] FATAL: expected go${GO_VER}, got: $GO_OUT"; exit 1; }
    fi
    test -x /tmp/fat/usr/local/go/bin/gofmt || { echo "[stage-1.5] FATAL: gofmt missing from go tarball"; exit 1; }
    ;;

  powernode-hub-backend)
    mkdir -p /tmp/fat/opt/powernode
    rsync -a \
      --exclude='.git' --exclude='node_modules' --exclude='tmp' \
      --exclude='log' --exclude='coverage' --exclude='extensions' \
      /tmp/parent/server/ /tmp/fat/opt/powernode/server/
    # Build identity for Powernode::Version (see the BUILD_INFO block above).
    [ -f /tmp/parent-build-info.json ] && cp /tmp/parent-build-info.json /tmp/fat/opt/powernode/server/BUILD_INFO.json
    # extensions_loader_helper.rb is required by the Gemfile
    cp /tmp/parent/extensions_loader_helper.rb /tmp/fat/opt/powernode/extensions_loader_helper.rb
    # Startup scripts (powernode-backend.sh etc.)
    if [ -d /tmp/parent/scripts ]; then
      rsync -a /tmp/parent/scripts/ /tmp/fat/opt/powernode/scripts/
    fi

    # --- Vendor gems offline (managed children have no rubygems egress) ---
    # Populate server/vendor/cache with every .gem so the on-node
    # rails-start.sh can `bundle install --local` (offline); native
    # extensions compile on-instance against runtime-ruby.
    #
    # Resolve gems the SAME way the runtime does. discover_extension_gems
    # (server/Gemfile) only promotes an extension to a path gem when its
    # slug is in /opt/powernode/.gitmodules — which is NOT shipped to
    # /sysroot — so at runtime NO extension is a path gem and the Gemfile
    # resolves core-only. We therefore re-lock here WITHOUT staging
    # .gitmodules or any extensions/, producing a core-only lock + cache
    # that match the runtime resolution exactly (so the on-node --local
    # install needs no re-resolution and no network).
    if ! command -v gem >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends ruby ruby-dev git
    fi
    # Install + pin the EXACT bundler the lockfile was generated with and
    # invoke it via the _<version>_ selector. Otherwise an older apt bundler
    # self-installs the lock's version and re-execs mid-command, which
    # intermittently exits 18 (observed on hub-worker in CI run 682).
    SRVB=$(awk '/BUNDLED WITH/{getline; gsub(/[[:space:]]/, ""); print; exit}' /tmp/fat/opt/powernode/server/Gemfile.lock)
    gem install bundler ${SRVB:+-v "$SRVB"} --no-document
    ( cd /tmp/fat/opt/powernode/server
      bundle ${SRVB:+_${SRVB}_} config set --local path vendor/bundle
      bundle ${SRVB:+_${SRVB}_} config set --local without development:test
      bundle ${SRVB:+_${SRVB}_} lock
      bundle ${SRVB:+_${SRVB}_} cache --no-install --all-platforms )
    # shellcheck disable=SC2012  # ls glob is fine here — just counting *.gem cache entries (verbatim from the original inline workflow step)
    echo "=== hub-backend vendored cache: $(ls /tmp/fat/opt/powernode/server/vendor/cache/*.gem 2>/dev/null | wc -l) gems ==="
    ;;
  powernode-hub-worker)
    mkdir -p /tmp/fat/opt/powernode
    rsync -a \
      --exclude='.git' --exclude='node_modules' --exclude='tmp' --exclude='log' \
      /tmp/parent/worker/ /tmp/fat/opt/powernode/worker/
    [ -f /tmp/parent-build-info.json ] && cp /tmp/parent-build-info.json /tmp/fat/opt/powernode/worker/BUILD_INFO.json

    # --- Vendor worker gems offline (same rationale as hub-backend) ---
    # The worker Gemfile has no extension path gems, so its lock is
    # self-consistent — just download every .gem into worker/vendor/cache
    # so the on-node sidekiq-start.sh can `bundle install --local`
    # (offline; native extensions compile on-instance against runtime-ruby).
    if ! command -v gem >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends ruby ruby-dev git
    fi
    # The worker Gemfile hard-pins `ruby '3.2.8'`, but the CI runner is
    # ruby 3.3.x and runtime-ruby is noble's 3.2.x — neither is exactly
    # 3.2.8, so bundler exits 18 ("Your Ruby version is X, but your
    # Gemfile specified 3.2.8"). `bundle cache` only downloads .gem source
    # (no ruby execution) and any 3.2.x satisfies the gems at runtime, so
    # drop the strict pin from the staged (shipped) Gemfile — matching
    # server/Gemfile, which carries no ruby directive.
    sed -i -E "/^ruby[[:space:]]+['\"]3\.2\.8['\"]/d" /tmp/fat/opt/powernode/worker/Gemfile
    # Pin the lockfile's exact bundler so `bundle` never self-installs +
    # re-execs mid-command.
    WKRB=$(awk '/BUNDLED WITH/{getline; gsub(/[[:space:]]/, ""); print; exit}' /tmp/fat/opt/powernode/worker/Gemfile.lock)
    gem install bundler ${WKRB:+-v "$WKRB"} --no-document
    ( cd /tmp/fat/opt/powernode/worker
      bundle ${WKRB:+_${WKRB}_} config set --local path vendor/bundle
      bundle ${WKRB:+_${WKRB}_} config set --local without development:test
      bundle ${WKRB:+_${WKRB}_} lock
      bundle ${WKRB:+_${WKRB}_} cache --no-install --all-platforms )
    # shellcheck disable=SC2012  # ls glob is fine here — just counting *.gem cache entries (verbatim from the original inline workflow step)
    echo "=== hub-worker vendored cache: $(ls /tmp/fat/opt/powernode/worker/vendor/cache/*.gem 2>/dev/null | wc -l) gems ==="
    ;;
  powernode-hub-frontend)
    # The Vite build needs a modern Node — the frontend's package.json engines
    # require >=24.9.0. Noble's apt `nodejs` is v18 with NO npm (see the
    # runtime-node arm above), which is why the old `apt-get install nodejs npm`
    # path here ALWAYS failed `command -v npm` and shipped an empty dist. Instead
    # fetch the same pinned prebuilt Node the runtime-node arm ships — but onto
    # the BUILDER (/opt/node-build, not the shipped rootfs) — and build with it.
    # dist/ is one of two deliverables (the Caddy static server below is the
    # other); a build failure still ships the module with an empty dist that
    # Caddy 404s on rather than failing the whole module. Every build diagnostic
    # goes to stderr (>&2) so it rides the task's stderr log_tail for diagnosis;
    # each fetch/build step is guarded so a failure degrades to empty-dist under
    # `set -e` instead of aborting the module.
    mkdir -p /tmp/fat/opt/powernode/frontend/dist
    if ! command -v npm >/dev/null 2>&1; then
      FE_NODE_VER=$(jq -r '.build.node_version // "24.13.0"' /tmp/manifest.json)
      # KEEP IN SYNC with the runtime-node arm's NODE_SHA256 (same tarball).
      FE_NODE_SHA256="6223aad1a81f9d1e7b682c59d12e2de233f7b4c37475cd40d1c89c42b737ffa8"
      echo "[stage-1.5] hub-frontend: fetching pinned node v${FE_NODE_VER} onto the builder for the Vite build" >&2
      if curl -fsSL "https://nodejs.org/dist/v${FE_NODE_VER}/node-v${FE_NODE_VER}-linux-x64.tar.gz" -o /tmp/node-build.tar.gz \
         && echo "${FE_NODE_SHA256}  /tmp/node-build.tar.gz" | sha256sum -c - >&2 \
         && mkdir -p /opt/node-build \
         && tar -xzf /tmp/node-build.tar.gz -C /opt/node-build --strip-components=1; then
        export PATH="/opt/node-build/bin:$PATH"
      else
        echo "[stage-1.5] hub-frontend: node fetch/verify FAILED — shipping empty dist" >&2
      fi
    fi
    # Stage the system extension's own frontend source into the parent
    # clone's extensions/ tree BEFORE the Vite build below, so
    # frontend/vite.config.ts's build-time extension discovery (scans
    # ../extensions/<slug> for an extension.json + a frontend/src dir, then
    # aliases @ext/<slug> + @<slug> to that frontend/src — see its ~lines
    # 43-71) picks up the system extension and compiles its register.ts
    # (menu items + routes) into the bundle. /tmp/parent is a shallow clone
    # of the CORE repo with NO submodules, so without this the parent clone
    # has ZERO extensions and hub-frontend ships with no system menu/pages
    # even though the backend has the extension enabled (imp: hub-frontend
    # v17 shipped this way).
    #
    # $ws (this checkout, already `cd`'d into at the top of this script) IS
    # the system extension's own repo root — the SAME source the
    # powernode-extension-system arm above stages server/+extension.json
    # from. Only the PUBLIC system extension is assembled here — ops-hub
    # runs core mode, so there is no private/business frontend to include.
    # node_modules is excluded from the copy: the extension carries no
    # dependencies of its own (see the symlink below); .git/coverage are
    # dev-only noise this checkout may have accumulated.
    if [ -f extension.json ] && [ -d frontend/src ]; then
      echo "[stage-1.5] hub-frontend: staging system extension frontend into parent clone" >&2
      mkdir -p /tmp/parent/extensions/system
      cp extension.json /tmp/parent/extensions/system/extension.json
      rsync -a --exclude='node_modules' --exclude='.git' --exclude='coverage' \
        frontend/ /tmp/parent/extensions/system/frontend/
    else
      echo "[stage-1.5] hub-frontend: no extension.json/frontend/src in this checkout — system extension UI will be absent" >&2
    fi
    if command -v npm >/dev/null 2>&1 && [ -f /tmp/parent/frontend/package.json ]; then
      echo "[stage-1.5] hub-frontend: node=$(node -v 2>&1) npm=$(npm -v 2>&1) — running npm ci + build" >&2
      if (
        cd /tmp/parent/frontend
        npm ci --no-audit
        # The extension's frontend/src imports react/lucide-react/etc as
        # bare specifiers but ships no node_modules of its own — Vite (like
        # Node) resolves bare imports by walking UP from the importing
        # file's directory looking for a node_modules dir, and
        # extensions/system/frontend/ has none of its own ancestry in
        # common with frontend/node_modules. The local dev checkout solves
        # this with a gitignored symlink at extensions/system/frontend/
        # node_modules -> the platform's frontend/node_modules (created by
        # scripts/setup-extension-frontend-symlinks.sh / scripts/
        # validate.sh's tsc gate); reproduce the identical symlink here so
        # the exact same resolution mechanism applies inside this shallow
        # clone. Guarded on the staged dir existing (skipped entirely if
        # the block above found no extension source to stage).
        if [ -d /tmp/parent/extensions/system/frontend ]; then
          ln -sfn ../../../frontend/node_modules /tmp/parent/extensions/system/frontend/node_modules
        fi
        # Build identity for the __BUILD_INFO__ define (vite.config.ts); the
        # bundle is static files behind Caddy, so build time is the only time.
        if [ -f /tmp/parent-build-info.json ]; then
          POWERNODE_BUILD_INFO_JSON="$(cat /tmp/parent-build-info.json)"
          export POWERNODE_BUILD_INFO_JSON
        fi
        npm run build
      ) 1>&2; then
        echo "[stage-1.5] hub-frontend: Vite build succeeded" >&2
      else
        echo "[stage-1.5] hub-frontend: FRONTEND BUILD FAILED — shipping empty dist (npm output above)" >&2
      fi
      # Vite's outDir is `build/` (frontend/vite.config.ts), NOT the default
      # `dist/` — read Vite's build/ output and ship it into the Caddy-served
      # /opt/powernode/frontend/dist. (This mismatch is why the Vite build
      # "succeeded" yet every module shipped an empty dist.)
      if [ -d /tmp/parent/frontend/build ] && [ -n "$(ls -A /tmp/parent/frontend/build 2>/dev/null)" ]; then
        rsync -a /tmp/parent/frontend/build/ /tmp/fat/opt/powernode/frontend/dist/
        echo "[stage-1.5] hub-frontend: dist shipped ($(find /tmp/fat/opt/powernode/frontend/dist -type f | wc -l) files)" >&2
      else
        echo "[stage-1.5] hub-frontend: dist EMPTY after build" >&2
      fi
    else
      echo "[stage-1.5] hub-frontend: no npm/node available — shipping empty dist" >&2
    fi
    # Traefik (reverse-proxy-traefik) has no static-file-serving mode —
    # it's a reverse proxy only. Something has to actually listen on
    # 127.0.0.1:3001 (the powernode-frontend router's upstream) and
    # serve dist/ with SPA fallback, so this module vendors Caddy the
    # same hermetic fetch-and-sha256-verify pattern as
    # reverse-proxy-traefik's own vendored /usr/bin/traefik below in
    # this same stage: no checked-in binary, a version bump here picks
    # up upstream CVE fixes. amd64-only (matches the dogfood VMs).
    # Static (CGO_ENABLED=0) build confirmed via `ldd` — no dynamic
    # libc dependency, so unlike an apt-installed binary this module
    # does NOT need a `capability:os.userland` edge on base-os (see
    # manifest comment).
    CADDY_VERSION="2.11.4"
    CADDY_SHA256="527fbf917c39189a1e3b31d34fa955601680b2d5c8055d2a87b8b9588dec7bb9"
    curl -fsSL \
      "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
      -o /tmp/caddy.tar.gz
    echo "${CADDY_SHA256}  /tmp/caddy.tar.gz" | sha256sum -c -
    mkdir -p /tmp/fat/usr/bin
    tar -xzf /tmp/caddy.tar.gz -C /tmp/fat/usr/bin caddy
    chmod 0755 /tmp/fat/usr/bin/caddy
    mkdir -p /tmp/fat/etc/caddy
    # Static SPA config, generated the same printf way as
    # reverse-proxy-traefik's /etc/traefik/traefik.yml below (avoids
    # YAML/Caddyfile heredoc indent conflicts). Immutable-overlay-rootfs
    # constraints (only /run, /tmp, /persist are writable; /var/log is
    # masked by base-os): `admin off` means no admin-API listener/socket
    # to carve or write state for; `auto_https off` means no ACME/TLS
    # activity at all (Traefik already terminates TLS and proxies here
    # in plain HTTP — this must stay TLS-free); `persist_config off`
    # stops Caddy autosaving the loaded config to disk; `storage
    # file_system /run/caddy` (paired with the service's `mkdir -p
    # /run/caddy` start_command + `XDG_DATA_HOME=/run` env — see
    # manifest services: block) points every on-disk write Caddy might
    # make — TLS/certmagic storage AND the separate app-data
    # instance.uuid marker, which is NOT governed by this `storage`
    # directive — at /run's writable tmpfs, never the read-only overlay
    # or /var. `log { output stdout }` (global + per-site) sends all
    # logging to stdout/journald — no /var/log/**, no on-disk log file.
    #
    # Site address is bare `:3001` + an explicit `bind 127.0.0.1`, NOT
    # `http://127.0.0.1:3001` — verified empirically that the latter is
    # a trap: in the Caddyfile, a host in the site address is a
    # Host-header MATCH, not a listen-interface restriction, so
    # `http://127.0.0.1:3001` still binds 0.0.0.0:3001 (wrong — must be
    # loopback-only) AND only matches requests whose Host header is
    # literally "127.0.0.1", which real traffic never has (Traefik
    # forwards the ORIGINAL Host header to this upstream, e.g. the
    # node's cert CN) — so it would 404 every real proxied request
    # while looking fine under `caddy validate`. `bind 127.0.0.1` +
    # site address `:3001` (no host component, so no Host matcher at
    # all) is the correct combination: confirmed via `ss` that Caddy
    # listens on 127.0.0.1:3001 only (non-loopback connect attempts
    # fail), and a curl with an arbitrary Host header still gets a 200.
    #
    # try_files + file_server is the SPA fallback: any path that isn't
    # an existing file under dist/ resolves to /index.html for React
    # Router (confirmed byte-identical response); existing files (the
    # Vite build's hashed JS/CSS/assets) are served as-is with Caddy's
    # built-in extension-based Content-Type detection (confirmed
    # text/javascript, text/css — no mime.types file needed, unlike
    # nginx).
    printf '%s\n' \
      '{' \
      '	admin off' \
      '	auto_https off' \
      '	persist_config off' \
      '	storage file_system /run/caddy' \
      '	log {' \
      '		output stdout' \
      '	}' \
      '}' \
      '' \
      ':3001 {' \
      '	bind 127.0.0.1' \
      '	log {' \
      '		output stdout' \
      '	}' \
      '' \
      '	root * /opt/powernode/frontend/dist' \
      '	encode gzip' \
      '	try_files {path} /index.html' \
      '	file_server' \
      '}' \
      > /tmp/fat/etc/caddy/Caddyfile
    ;;
  powernode-extension-system)
    # THIS submodule (powernode-system) IS the system extension.
    # Stage its server/ + extension.json into the parent's
    # extensions/system/ tree shape.
    mkdir -p /tmp/fat/opt/powernode/extensions/system
    rsync -a \
      --exclude='.git' --exclude='tmp' --exclude='log' \
      --exclude='node_modules' --exclude='coverage' \
      server/ /tmp/fat/opt/powernode/extensions/system/server/
    if [ -f extension.json ]; then
      cp extension.json /tmp/fat/opt/powernode/extensions/system/extension.json
    fi

    # --- Worker component (Sidekiq jobs + scheduler) --------------------
    # extension.json declares components.worker:true, so BOTH runtime seams
    # in the hub-worker process look for this extension's worker tree under
    # /opt/powernode/extensions/system/worker/ (paths are relative to the
    # core worker checkout, ../../extensions):
    #   * worker/config/boot.rb — its generic extension loader requires
    #     worker/app/{services,jobs}/**; the loop GATES on
    #     `Dir.exist?(<ext>/worker)` and `next`s when it's absent.
    #   * worker/config/application.rb — its generic scheduler scan merges
    #     <ext>/worker/config/sidekiq_*.yml into sidekiq-scheduler.
    # Nothing staged this tree before now: the powernode-hub-worker arm
    # copies ONLY the core worker (/opt/powernode/worker/), and this arm
    # shipped only server/ + extension.json. So on the composed node the
    # worker dir did not exist, boot.rb skipped it, and the extension's
    # top-level job classes (SystemExecuteTaskJob — enqueued by
    # WorkerDispatch on every System::Task create — SystemTaskReaperJob,
    # and the seven scheduled reconcilers) were never loaded: every
    # worker-dispatched system task died with `uninitialized constant
    # SystemExecuteTaskJob`, and the sidekiq_system.yml schedule never ran.
    # Ship it here (this module already owns everything under
    # /opt/powernode/extensions/system/**, so its file_spec carves it with
    # no manifest change, and the worker component lands with the same
    # extension.json that declares it — no split ownership with hub-worker).
    # The jobs need no extension SERVER code and no path-gem: each is a thin
    # BaseJob (core) that POSTs to the backend worker_api over HTTP and rides
    # the core worker's own bundle — same rationale as the server arm cloning
    # no worker gems.
    if [ -d worker ]; then
      rsync -a \
        --exclude='.git' --exclude='tmp' --exclude='log' \
        --exclude='node_modules' --exclude='coverage' \
        worker/ /tmp/fat/opt/powernode/extensions/system/worker/
      # shellcheck disable=SC2012  # ls glob is fine here — just counting the shipped job files
      echo "=== extension-system worker component: $(ls /tmp/fat/opt/powernode/extensions/system/worker/app/jobs/*.rb 2>/dev/null | wc -l) job files + $(ls /tmp/fat/opt/powernode/extensions/system/worker/config/sidekiq_*.yml 2>/dev/null | wc -l) scheduler yml ==="
    else
      echo "[stage-1.5] extension-system: FATAL — worker/ tree missing from workspace; extension.json declares components.worker:true but no worker code to ship" >&2
      exit 1
    fi

    # --- Dedicated-module frontend build (P2) ---------------------------
    # Builds this extension's frontend as a standalone ESM bundle (every
    # HOST_EXPOSED_IDS id — core's @/… surface + the npm singletons — left
    # EXTERNAL, resolved at runtime through core's injected import map; see
    # frontend/src/shared/host-api/modules.ts and this extension's own
    # frontend/vite.config.build.ts for the full contract) and ships it to
    # /opt/powernode/frontend/dist/extensions/system/ — the SAME root
    # powernode-hub-frontend serves from (Caddy), so the overlay union
    # exposes /extensions/system/manifest.json same-origin with zero serve
    # config change (see this module's manifest.yaml file_spec).
    #
    # Needs /tmp/parent (core's frontend/, cloned above because this module
    # is now in the `needs_parent` list) for the modules.ts contract +
    # node_modules. A build failure degrades to shipping NO dedicated-module
    # bundle — the extension simply stays off the runtime menu until the
    # next successful build — never aborts the whole module; every step
    # below is guarded and every diagnostic goes to stderr, mirroring the
    # powernode-hub-frontend arm's own degrade-gracefully pattern above.
    #
    # Wrap the whole frontend-build block so its stderr diagnostics are
    # BOTH surfaced live AND persisted into a carved marker
    # (/opt/powernode/extensions/system/.frontend-build.log — under the
    # first file_spec entry, so it ships in the erofs). The builder is an
    # ephemeral pool instance, terminated before its journal can be read,
    # and the task log_tail is truncated to the (later) carve output — so
    # a silent degrade left no way to see WHY. This marker makes every
    # build self-diagnosing: read it out of the composed module post-boot.
    FE_TMPLOG=$(mktemp)
    {
    if [ ! -f /tmp/parent/frontend/package.json ]; then
      echo "[stage-1.5] extension-system: /tmp/parent/frontend missing — skipping dedicated-module frontend build" >&2
    elif ! command -v jq >/dev/null 2>&1; then
      echo "[stage-1.5] extension-system: jq missing — skipping dedicated-module frontend build" >&2
    else
      if ! command -v npm >/dev/null 2>&1; then
        FE_NODE_VER=$(jq -r '.build.node_version // "24.13.0"' /tmp/manifest.json)
        # KEEP IN SYNC with the runtime-node / powernode-hub-frontend arms'
        # NODE_SHA256 (same tarball).
        FE_NODE_SHA256="6223aad1a81f9d1e7b682c59d12e2de233f7b4c37475cd40d1c89c42b737ffa8"
        echo "[stage-1.5] extension-system: fetching pinned node v${FE_NODE_VER} onto the builder for the extension Vite build" >&2
        if curl -fsSL "https://nodejs.org/dist/v${FE_NODE_VER}/node-v${FE_NODE_VER}-linux-x64.tar.gz" -o /tmp/node-build-ext.tar.gz \
           && echo "${FE_NODE_SHA256}  /tmp/node-build-ext.tar.gz" | sha256sum -c - >&2 \
           && mkdir -p /opt/node-build \
           && tar -xzf /tmp/node-build-ext.tar.gz -C /opt/node-build --strip-components=1; then
          export PATH="/opt/node-build/bin:$PATH"
        else
          echo "[stage-1.5] extension-system: node fetch/verify FAILED — skipping dedicated-module frontend build" >&2
        fi
      fi

      if command -v npm >/dev/null 2>&1; then
        echo "[stage-1.5] extension-system: node=$(node -v 2>&1) npm=$(npm -v 2>&1) — running npm ci" >&2
        if ( cd /tmp/parent/frontend && npm ci --no-audit ) 1>&2; then
          # Stage THIS extension's frontend/ + extension.json into the
          # freshly-cloned parent's extensions/system/ (a plain `git clone`
          # of the parent never checks out submodules, so extensions/system/
          # is empty there) — vite.config.build.ts resolves its own
          # `../../../frontend/…` imports relative to ITS OWN location, so
          # it must live at that exact depth under the parent checkout.
          mkdir -p /tmp/parent/extensions/system
          rsync -a \
            --exclude='.git' --exclude='node_modules' --exclude='dist' \
            frontend/ /tmp/parent/extensions/system/frontend/
          cp extension.json /tmp/parent/extensions/system/extension.json

          # Same symlink trick scripts/setup-extension-frontend-symlinks.sh
          # uses for Jest: the extension ships no node_modules of its own,
          # so its bare imports (react, lucide-react, …) resolve through the
          # parent frontend's install.
          ln -sf ../../../frontend/node_modules /tmp/parent/extensions/system/frontend/node_modules

          if ( cd /tmp/parent/extensions/system/frontend && npx vite build --config vite.config.build.ts ) 1>&2; then
            echo "[stage-1.5] extension-system: dedicated-module Vite build succeeded" >&2
            if [ -d /tmp/parent/extensions/system/frontend/dist ] && [ -n "$(ls -A /tmp/parent/extensions/system/frontend/dist 2>/dev/null)" ]; then
              mkdir -p /tmp/fat/opt/powernode/frontend/dist/extensions/system
              rsync -a /tmp/parent/extensions/system/frontend/dist/ /tmp/fat/opt/powernode/frontend/dist/extensions/system/
              echo "[stage-1.5] extension-system: dedicated-module bundle shipped ($(find /tmp/fat/opt/powernode/frontend/dist/extensions/system -type f | wc -l) files)" >&2
            else
              echo "[stage-1.5] extension-system: dist EMPTY after build — shipping no dedicated-module bundle" >&2
            fi
          else
            echo "[stage-1.5] extension-system: DEDICATED-MODULE BUILD FAILED — shipping no dedicated-module bundle (npm/vite output above)" >&2
          fi
        else
          echo "[stage-1.5] extension-system: npm ci FAILED in /tmp/parent/frontend — skipping dedicated-module frontend build" >&2
        fi
      else
        echo "[stage-1.5] extension-system: no npm/node available — skipping dedicated-module frontend build" >&2
      fi
    fi
    } 2>"$FE_TMPLOG"
    cat "$FE_TMPLOG" >&2
    mkdir -p /tmp/fat/opt/powernode/extensions/system
    cp "$FE_TMPLOG" /tmp/fat/opt/powernode/extensions/system/.frontend-build.log 2>/dev/null || true
    # A dedicated-module FRONTEND with no frontend dist is a broken module —
    # its whole purpose is the System menu + pages. Silently degrading to a
    # backend-only erofs (the prior behavior) shipped a module that looked
    # fine but rendered no menu, and the later carve stage overwrote the
    # arm's stderr in the task log_tail so the reason was invisible. Hard-fail
    # instead: aborting here BEFORE the carve leaves the arm's diagnostics as
    # the build's log_tail (readable via system_get_task), and refuses to
    # publish a useless module.
    if [ ! -d /tmp/fat/opt/powernode/frontend/dist/extensions/system ] || \
       [ -z "$(ls -A /tmp/fat/opt/powernode/frontend/dist/extensions/system 2>/dev/null)" ]; then
      echo "[stage-1.5] extension-system: FATAL — dedicated-module frontend dist was NOT produced; refusing to ship a frontend module with no frontend. Arm diagnostics follow:" >&2
      cat "$FE_TMPLOG" >&2
      exit 1
    fi
    echo "[stage-1.5] extension-system: dedicated-module frontend dist present ($(find /tmp/fat/opt/powernode/frontend/dist/extensions/system -type f | wc -l) files) — OK" >&2
    ;;
  reverse-proxy-traefik)
    # Traefik isn't in noble's required-priority apt set
    # (mmdebstrap's narrow filter drops it), so fetch the
    # upstream release binary and verify its sha256 — the same
    # hermetic pattern as the cosign/oras fetch earlier in this
    # job. No checked-in binary; a version bump here picks up
    # upstream CVE fixes. amd64-only, matching the dogfood VMs
    # (multi-arch fetch is a follow-up when arm64 nodes land).
    TRAEFIK_VERSION="3.7.1"
    TRAEFIK_SHA256="e92bcfb03fa1e6a70c4e7ad4eb4f1604967e6fa3c21d8e7605aca5407a40162c"
    curl -fsSL \
      "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz" \
      -o /tmp/traefik.tar.gz
    echo "${TRAEFIK_SHA256}  /tmp/traefik.tar.gz" | sha256sum -c -
    mkdir -p /tmp/fat/usr/bin
    tar -xzf /tmp/traefik.tar.gz -C /tmp/fat/usr/bin traefik
    chmod 0755 /tmp/fat/usr/bin/traefik
    mkdir -p /tmp/fat/etc/traefik/dynamic
    # Default static config — dynamic configs land in /etc/traefik/dynamic/
    # Use printf to avoid YAML/heredoc indent conflicts.
    printf '%s\n' \
      'api:' \
      '  dashboard: true' \
      'ping: {}' \
      'entryPoints:' \
      '  web:' \
      '    address: ":80"' \
      '  websecure:' \
      '    address: ":443"' \
      'providers:' \
      '  file:' \
      '    directory: /etc/traefik/dynamic' \
      '    watch: true' \
      'log:' \
      '  level: INFO' \
      > /tmp/fat/etc/traefik/traefik.yml
    ;;
  powernode-system-base)
    # Truly-minimal foundation: only the cross-compiled Go
    # agent + the /etc/powernode/ skeleton. No userland, no
    # init system, no apt packages — those land in
    # base-os-ubuntu-noble (or future
    # -debian-trixie, -alpine variants) which depend on
    # this module via the Powernode dependency resolver
    # and inherit /usr/sbin/powernode-agent through the
    # overlay union.
    #
    # CGO_ENABLED=0 + -trimpath + -s -w produces a static
    # binary that runs on every glibc/musl Linux without
    # additional deps — the whole point of decoupling the
    # agent from any specific base-OS.
    # The agent's go.mod pins a `go` directive (currently 1.25.x)
    # NEWER than Debian Trixie's apt `golang-go` (1.24). Relying on
    # apt + GOTOOLCHAIN=auto made `go build` try to fetch the pinned
    # toolchain from the module proxy at build time; on a runner with
    # a restricted GOPROXY that fetch fails, `go build` errors, and —
    # because Stage 2/push run on the dirty closure — the carve+push
    # still shipped an EMPTY 4 KB erofs (the agent is this module's
    # ENTIRE payload, so a failed build = a hollow base = no
    # /sbin/powernode-agent in any node that unions this layer).
    # Fix: fetch the EXACT toolchain go.mod asks for straight from
    # go.dev/dl (a plain HTTPS GET, bypassing GOPROXY) and pin
    # GOTOOLCHAIN=local so the build uses precisely it and never
    # attempts a surprise download. (success() guards on Stage 2/push
    # below now also abort the publish if this step ever fails.)
    GOVER=$(awk '/^go [0-9]/{print $2; exit}' agent/go.mod)
    echo "[stage-1.5] go.mod requires go ${GOVER}; fetching official toolchain from go.dev"
    curl -fsSL "https://go.dev/dl/go${GOVER}.linux-amd64.tar.gz" -o /tmp/go.tgz

    # VERIFY BEFORE EXTRACTING. This toolchain compiles powernode-agent, which
    # is this module's ENTIRE payload and the platform-trust boundary
    # (protected_spec /usr/sbin/powernode-agent — no higher module may overlay
    # it). An unverified tarball here means a tampered compiler produces a
    # backdoored agent that then gets cosign-signed as authentic and unioned
    # into EVERY node. Until 2026-07-28 this was a bare curl|tar with no check
    # at all, the one fetch in this file that skipped the house rule.
    #
    # Keyed on GOVER because it is read from agent/go.mod above, not pinned
    # here: an unrecognised version FAILS CLOSED rather than silently skipping
    # verification. Bump these alongside the go directive in agent/go.mod AND
    # the identical pins in the runtime-go arm above (same artifact, same
    # values — the cosign pin is shared between arms the same way).
    case "${GOVER}" in
      1.25.0) GO_SB_SHA256=2852af0cb20a13139b3448992e69b868e50ed0f8a1e5940ee1de9e19a123b613 ;;
      *) echo "[stage-1.5] FATAL: agent/go.mod asks for go ${GOVER} but no sha256 is pinned for it in stage15.sh — add the official checksum from https://go.dev/dl/?mode=json (and update the runtime-go arm to match) before building."; exit 1 ;;
    esac
    echo "${GO_SB_SHA256}  /tmp/go.tgz" | sha256sum -c -

    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tgz
    export PATH="/usr/local/go/bin:${PATH}"
    export GOTOOLCHAIN=local
    go version
    # IMP-f1c1e6d61104 follow-up — STAMP A REAL BUILD IDENTITY.
    #
    # cmd/powernode-agent/main.go declares Version/GitCommit/BuildDate as
    # -ldflags -X targets and its comment claims the Gitea workflow stamps
    # them. This build path — the one that actually produces the binary the
    # fleet runs — did not, so every instance heartbeated agent_version "dev"
    # and nothing server-side could stage a change by agent capability. That
    # cost two diagnoses: whether the fleet carries the hot-add reconcile work,
    # and whether the convergence-failure change is live.
    #
    # `--verify` is load-bearing here for the same reason it is at the
    # core-provenance probe above: a BARE `git rev-parse HEAD` outside a repo
    # prints the literal string "HEAD" and reads like an answer, which is how a
    # placeholder becomes a fleet-wide constant in the first place.
    agent_source_sha="$(git rev-parse --verify HEAD 2>/dev/null || true)"
    : "${agent_source_sha:=unknown}"
    agent_build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Version stays human-readable and sorts by build; GitCommit carries the
    # exact ref. Both, because a sha alone cannot be compared for "at or past".
    agent_version_str="${agent_build_date%T*}-${agent_source_sha:0:12}"
    echo "[stage-1.5] stamping agent version=${agent_version_str} commit=${agent_source_sha}"

    echo "[stage-1.5] cross-compiling powernode-agent for amd64…"
    ( cd agent && \
      CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      /usr/local/go/bin/go build -trimpath \
        -ldflags "-s -w \
          -X main.Version=${agent_version_str} \
          -X main.GitCommit=${agent_source_sha} \
          -X main.BuildDate=${agent_build_date}" \
        -o /tmp/powernode-agent ./cmd/powernode-agent )
    # Hard guard: the agent binary IS this module's payload. If the
    # build silently produced nothing, fail loudly here rather than
    # let Stage 2 carve + push a hollow erofs.
    test -s /tmp/powernode-agent || { echo "[stage-1.5] FATAL: agent binary not built"; exit 1; }
    echo "[stage-1.5] agent built: $(stat -c%s /tmp/powernode-agent) bytes"
    mkdir -p /tmp/fat/usr/sbin /tmp/fat/sbin /tmp/fat/etc/powernode
    install -m 0755 /tmp/powernode-agent /tmp/fat/usr/sbin/powernode-agent
    # /sbin/powernode-agent symlink — initramfs/dracut
    # hook looks at /sbin first; post-switch_root systemd
    # unit uses /usr/sbin/. Both paths kept for either
    # codepath.
    # CRITICAL: only create the /sbin compat symlink on a REAL /sbin.
    # On a usrmerged base (Ubuntu noble: /sbin -> usr/sbin) this link
    # name resolves THROUGH the /sbin symlink to
    # /tmp/fat/usr/sbin/powernode-agent, and `ln -sf` would CLOBBER the
    # real 9.7MB binary just installed there with a ~20-byte
    # self-referential symlink — the carve then ships a 4 KB hollow
    # erofs. On usrmerge, /sbin/powernode-agent already resolves to the
    # real binary, so the extra link is unnecessary AND destructive.
    if [ ! -L /tmp/fat/sbin ]; then
      ln -sf /usr/sbin/powernode-agent /tmp/fat/sbin/powernode-agent
    fi
    # Guard what actually SHIPS (not just the build output at
    # /tmp/powernode-agent): the rootfs binary must be a real >1MB
    # file, never a symlink. Catches the usrmerge clobber + any future
    # regression before Stage 2 can carve a hollow erofs.
    if [ -L /tmp/fat/usr/sbin/powernode-agent ] || [ "$(stat -c%s /tmp/fat/usr/sbin/powernode-agent 2>/dev/null || echo 0)" -lt 1000000 ]; then
      echo "[stage-1.5] FATAL: /tmp/fat/usr/sbin/powernode-agent is not a real >1MB binary (usrmerge clobber?)"; exit 1
    fi
    ;;
  base-os-ubuntu-noble)
    # OS-specific layer: Ubuntu's apt-installed userland
    # comes from Stage 1's mmdebstrap (package_spec, which
    # now includes systemd-resolved explicitly — it's a
    # separate binary package on Noble, not bundled into
    # `systemd` like networkd is). The rootfs/ overlay adds
    # the Powernode-curated systemd units (powernode-agent.
    # service, ssh-host-keygen.service, powernode-network-
    # reload.service) + sshd config + systemd-networkd DHCP
    # profile + the /etc/resolv.conf -> resolved-stub symlink.
    #
    # No agent binary baked here — it's inherited from
    # powernode-system-base via overlay union when both are
    # mounted on a node. Keeps the cross-compile in exactly
    # one place.
    #
    # /sbin/init → systemd symlink. mmdebstrap installs
    # systemd at /usr/lib/systemd/systemd. The systemd-sysv
    # package normally creates /sbin/init but in minbase
    # it may not — make it explicit so switch_root finds
    # an init binary at the conventional path.
    if [ ! -e /tmp/fat/sbin/init ]; then
      mkdir -p /tmp/fat/sbin
      ln -sf /usr/lib/systemd/systemd /tmp/fat/sbin/init
    fi
    # Stage cosign (checksum-verified) → /usr/bin/cosign for the
    # on-node upgrade_boot_image handler's UKI signature verification
    # (campaign 019f505f inc2). base-os's file_spec includes
    # /usr/bin/** so Stage-2's carve keeps it. The Makefile's
    # stage-cosign target was orphaned from CI (this workflow
    # cross-compiles the agent directly and never runs `make`), so
    # cosign never shipped and the in-place upgrade failed closed on
    # every node. Pinned version + BOTH checksums mirror
    # modules/base-os-ubuntu-noble/Makefile — bump them together.
    COSIGN_VERSION=3.0.6
    case "${ARCH:-amd64}" in
      amd64) COSIGN_SHA=c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74 ;;
      arm64) COSIGN_SHA=bedac92e8c3729864e13d4a17048007cfafa79d5deca993a43a90ffe018ef2b8 ;;
      *) echo "[stage-1.5] FATAL: no pinned cosign sha256 for ARCH=${ARCH:-amd64}"; exit 1 ;;
    esac
    mkdir -p /tmp/fat/usr/bin
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${ARCH:-amd64}" -o /tmp/fat/usr/bin/cosign
    got=$(sha256sum /tmp/fat/usr/bin/cosign | awk '{print $1}')
    [ "$got" = "$COSIGN_SHA" ] || { echo "[stage-1.5] FATAL: cosign sha256 mismatch (want $COSIGN_SHA got $got)"; rm -f /tmp/fat/usr/bin/cosign; exit 1; }
    chmod +x /tmp/fat/usr/bin/cosign
    echo "[stage-1.5] staged cosign v${COSIGN_VERSION} ${ARCH:-amd64} → /usr/bin/cosign"
    # Stage oras (checksum-verified) → /usr/bin/oras for the on-node native
    # module-build + local cosign-signing path, which shells out to `oras` to
    # push/pull erofs artifacts (campaign 019f71dc #48 local-signing proof
    # found oras MISSING on PATH — base-os shipped cosign but never oras, so
    # ops-hub's Vault-less native signing had no oras to publish the signature).
    # Mirrors the cosign stage above: base-os's file_spec includes /usr/bin/**
    # so Stage-2's carve keeps it; pinned version + BOTH per-arch checksums are
    # the vendor-published oras_${ORAS_VERSION}_checksums.txt values (same
    # ORAS_VERSION already pinned in the module-forge arm's /opt/buildenv oras
    # below — bump them together). oras ships as a tarball (unlike cosign's raw
    # binary), so it is downloaded to /tmp, checksum-verified, then extracted —
    # the identical fetch idiom this stage already uses for oras further down.
    ORAS_VERSION=1.2.0
    case "${ARCH:-amd64}" in
      amd64) ORAS_SHA256=5b3f1cbb86d869eee68120b9b45b9be983f3738442f87ee5f06b00edd0bab336 ;;
      arm64) ORAS_SHA256=27df680a39fc2fcedc549cb737891623bc696c9a92a03fd341e9356a35836bae ;;
      *) echo "[stage-1.5] FATAL: no pinned oras sha256 for ARCH=${ARCH:-amd64}"; exit 1 ;;
    esac
    mkdir -p /tmp/fat/usr/bin
    curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${ARCH:-amd64}.tar.gz" -o /tmp/oras.tar.gz
    got=$(sha256sum /tmp/oras.tar.gz | awk '{print $1}')
    [ "$got" = "$ORAS_SHA256" ] || { echo "[stage-1.5] FATAL: oras sha256 mismatch (want $ORAS_SHA256 got $got)"; rm -f /tmp/oras.tar.gz; exit 1; }
    tar -xzf /tmp/oras.tar.gz -C /tmp/fat/usr/bin oras
    chmod +x /tmp/fat/usr/bin/oras
    rm -f /tmp/oras.tar.gz
    echo "[stage-1.5] staged oras v${ORAS_VERSION} ${ARCH:-amd64} → /usr/bin/oras"
    ;;
  claude-tmux)
    # The Claude Code CLI (@anthropic-ai/claude-code) is an npm
    # package with no apt equivalent — package_spec (mmdebstrap,
    # Stage 1) already installed tmux + nodejs + npm into
    # /tmp/fat from apt; this step npm-installs the CLI itself
    # directly into that same tree via --prefix, using the
    # RUNNER's own node/npm (same cross-install technique as the
    # runtime-ruby case above's `gem install --install-dir`).
    # Pure-JS-plus-prebuilt-native-optionalDependencies package,
    # same linux/x64 target as the runner — no chroot needed.
    if ! command -v npm >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends nodejs npm
    fi
    # Pin the CLI version from the manifest (build.claude_code_version)
    # rather than floating to npm's implicit @latest — reproducible builds
    # and controlled bumps, same manifest-driven idiom as the act_runner
    # case below. npm has no single release-binary sha to `sha256sum -c`;
    # the exact version + npm's own package-lock integrity is the pin.
    CLAUDE_CODE_VERSION=$(jq -r '.build.claude_code_version // "2.1.220"' /tmp/manifest.json)
    mkdir -p /tmp/fat/usr
    npm install -g --prefix /tmp/fat/usr --no-audit --no-fund \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
    # Guard what actually SHIPS: the CLI is this module's entire
    # payload (beyond tmux) — a failed/partial npm install must
    # not silently carve an empty module.
    if [ ! -e /tmp/fat/usr/bin/claude ] && [ ! -e /tmp/fat/usr/lib/node_modules/@anthropic-ai/claude-code ]; then
      echo "[stage-1.5] FATAL: @anthropic-ai/claude-code did not install into /tmp/fat/usr"; exit 1
    fi
    # Assert the pinned version actually landed (mirrors the act_runner
    # --version check below) — catch an npm resolution that silently
    # deviated from the manifest pin before it ships.
    CLAUDE_INSTALLED_VERSION=$(jq -r '.version' \
      /tmp/fat/usr/lib/node_modules/@anthropic-ai/claude-code/package.json 2>/dev/null || echo "")
    if [ "$CLAUDE_INSTALLED_VERSION" != "$CLAUDE_CODE_VERSION" ]; then
      echo "[stage-1.5] FATAL: expected @anthropic-ai/claude-code ${CLAUDE_CODE_VERSION}, got: ${CLAUDE_INSTALLED_VERSION:-<none>}"; exit 1
    fi
    echo "=== claude-tmux: npm install result (pinned ${CLAUDE_CODE_VERSION}) ==="
    ls -la /tmp/fat/usr/bin/claude* 2>/dev/null || true
    ls -d /tmp/fat/usr/lib/node_modules/@anthropic-ai/claude-code 2>/dev/null || true
    ;;
  grok-cli)
    # xAI's Grok Build CLI (@xai-official/grok) is an npm package with no
    # apt equivalent — same situation, and the same cross-install
    # technique, as the claude-tmux case above: npm-install it into
    # /tmp/fat via --prefix using the RUNNER's own node/npm. The package
    # is a small JS wrapper plus a PREBUILT NATIVE binary delivered as a
    # platform-specific optionalDependency (@xai-official/grok-linux-x64),
    # targeting the same linux/x64 as the runner — no chroot needed.
    if ! command -v npm >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends nodejs npm
    fi
    # Pin from the manifest (build.grok_version) rather than floating to
    # npm's implicit @latest — reproducible builds and controlled bumps,
    # same manifest-driven idiom as claude-tmux/act_runner. npm has no
    # single release-binary sha to `sha256sum -c`; the exact version plus
    # npm's own integrity metadata is the pin.
    GROK_VERSION=$(jq -r '.build.grok_version // "1.0.5"' /tmp/manifest.json)
    mkdir -p /tmp/fat/usr
    npm install -g --prefix /tmp/fat/usr --no-audit --no-fund \
      "@xai-official/grok@${GROK_VERSION}"
    # Guard what actually SHIPS: the CLI is this module's entire payload —
    # a failed/partial npm install must not silently carve an empty module
    # (gitleaks v4, 2026-08-07: an empty artifact auto-promoted and the
    # agent's hot-prune then whiteout-DELETED the binary off a live root,
    # with every digest matching end to end).
    if [ ! -e /tmp/fat/usr/bin/grok ] && [ ! -e /tmp/fat/usr/lib/node_modules/@xai-official/grok ]; then
      echo "[stage-1.5] FATAL: @xai-official/grok did not install into /tmp/fat/usr"; exit 1
    fi
    # Assert the pinned version actually landed — catch an npm resolution
    # that silently deviated from the manifest pin before it ships.
    GROK_INSTALLED_VERSION=$(jq -r '.version' \
      /tmp/fat/usr/lib/node_modules/@xai-official/grok/package.json 2>/dev/null || echo "")
    if [ "$GROK_INSTALLED_VERSION" != "$GROK_VERSION" ]; then
      echo "[stage-1.5] FATAL: expected @xai-official/grok ${GROK_VERSION}, got: ${GROK_INSTALLED_VERSION:-<none>}"; exit 1
    fi
    # THIRD guard, specific to this package's shape and NOT present in the
    # claude-tmux case: the executable lives in a platform-specific
    # OPTIONAL dependency, and npm treats a failed optionalDependency as a
    # SUCCESS. Without this check a registry hiccup or an os/cpu mismatch
    # ships a wrapper with nothing behind it — a `grok` that exists on PATH
    # and cannot run, which is exactly the shape the manifest's verify
    # probe would then report as broken on a live node instead of here.
    #
    # Assert the PAYLOAD, not a directory, and FIND it rather than naming a
    # path. Two reasons, both learned the hard way on build 01a03945 (which
    # this guard failed closed on — correctly in spirit, wrongly in detail):
    #
    #   1. npm nests the platform package UNDER the wrapper for a
    #      `-g --prefix` install:
    #        .../@xai-official/grok/node_modules/@xai-official/grok-linux-x64
    #      not at the top level of node_modules/. The first version of this
    #      guard globbed the top level, found nothing, and killed a build
    #      whose install was in fact complete. Depth-searching from
    #      @xai-official survives that layout AND a future npm that hoists.
    #   2. A directory can exist and be empty. What must actually ship is
    #      bin/grok.br — the ~45 MB brotli-compressed executable the wrapper
    #      expands on first run. The size floor catches a truncated or
    #      placeholder file, which an existence test would wave through.
    GROK_PAYLOAD=$(find /tmp/fat/usr/lib/node_modules/@xai-official \
      -type f -path '*/grok-linux-*/bin/grok.br' -print -quit 2>/dev/null || true)
    if [ -z "$GROK_PAYLOAD" ]; then
      echo "[stage-1.5] FATAL: no @xai-official/grok-linux-*/bin/grok.br staged — the optionalDependency carrying the real binary did not install"
      echo "[stage-1.5] what IS under @xai-official:"; find /tmp/fat/usr/lib/node_modules/@xai-official -maxdepth 4 2>/dev/null | head -40
      exit 1
    fi
    GROK_PAYLOAD_BYTES=$(stat -c %s "$GROK_PAYLOAD" 2>/dev/null || echo 0)
    if [ "$GROK_PAYLOAD_BYTES" -lt 1000000 ]; then
      echo "[stage-1.5] FATAL: staged grok payload $GROK_PAYLOAD is only ${GROK_PAYLOAD_BYTES} bytes — expected tens of MB; treating as a truncated/placeholder download"; exit 1
    fi
    echo "[stage-1.5] grok payload staged: $GROK_PAYLOAD (${GROK_PAYLOAD_BYTES} bytes)"
    echo "=== grok-cli: npm install result (pinned ${GROK_VERSION}) ==="
    ls -la /tmp/fat/usr/bin/grok* 2>/dev/null || true
    ls -d /tmp/fat/usr/lib/node_modules/@xai-official/* 2>/dev/null || true
    ;;
  gitea-act-runner)
    # act_runner has no apt package — fetch the pinned upstream
    # release binary and verify its sha256, same hermetic pattern
    # as the traefik/cosign fetches elsewhere in this stage.
    # This module's Docker packages (docker.io + docker-buildx) came
    # from Ubuntu noble's own universe via Stage 1's mmdebstrap — no
    # apt-source hook needed (see the manifest package_spec comment).
    ACT_RUNNER_VERSION=$(jq -r '.build.act_runner_version // "0.2.13"' /tmp/manifest.json)

    # Pinned sha256 for act_runner-${ACT_RUNNER_VERSION}-linux-<arch>
    # from https://gitea.com/gitea/act_runner/releases. arm64 is
    # pre-pinned for the future multi-arch fetch (campaign 019f5885
    # inc2 design note) — only amd64 is actually built today.  Bump
    # both alongside build.act_runner_version on any version change.
    case "${ARCH:-amd64}" in
      amd64) ACT_RUNNER_SHA256=3acac8b506ac8cadc88a55155b5d6378f0fab0b8f62d1e0c0450f4ccd69733e2 ;;
      arm64) ACT_RUNNER_SHA256=0b79090cd6e06adbe4f10dac500b16abae9504b70948ea94b7f888e84fae12f9 ;;
      *) echo "[stage-1.5] FATAL: no pinned act_runner sha256 for ARCH=${ARCH:-amd64}"; exit 1 ;;
    esac

    curl -fsSL \
      "https://dl.gitea.com/act_runner/${ACT_RUNNER_VERSION}/act_runner-${ACT_RUNNER_VERSION}-linux-${ARCH:-amd64}" \
      -o /tmp/act_runner
    echo "${ACT_RUNNER_SHA256}  /tmp/act_runner" | sha256sum -c -

    mkdir -p /tmp/fat/usr/local/bin
    install -m0755 /tmp/act_runner /tmp/fat/usr/local/bin/act_runner

    # Verify what actually shipped. Only exec the binary on an
    # amd64 runner (the only ARCH this campaign increment actually
    # builds) — a cross-arch (future arm64) fetch already has its
    # integrity confirmed by the sha256sum -c above and can't be
    # exec'd on this runner anyway.
    if [ "${ARCH:-amd64}" = "amd64" ]; then
      ACT_RUNNER_OUT=$(/tmp/fat/usr/local/bin/act_runner --version 2>&1 || true)
      echo "[stage-1.5] act_runner: $ACT_RUNNER_OUT"
      echo "$ACT_RUNNER_OUT" | grep -q "${ACT_RUNNER_VERSION}" || { echo "[stage-1.5] FATAL: expected act_runner ${ACT_RUNNER_VERSION}, got: $ACT_RUNNER_OUT"; exit 1; }
    else
      echo "[stage-1.5] skipping act_runner --version exec check for ARCH=${ARCH:-amd64} (cross-arch binary, runner can't exec it) — sha256 already verified above"
    fi

    # Docker sanity — Stage 1's package_spec (docker.io) must have
    # actually landed dockerd; catch a silently-empty docker install
    # here rather than ship a runner with no daemon to talk to.
    test -e /tmp/fat/usr/bin/dockerd || { echo "[stage-1.5] FATAL: /tmp/fat/usr/bin/dockerd missing — docker.io did not install"; exit 1; }
    ;;
  tmux-manager)
    # tmux-manager (github.com/rett/tmux-manager, MIT, Everett C. Haimes
    # III) is a pure-bash tool with no apt package and no GitHub Releases
    # (`gh api repos/rett/tmux-manager/tags` returns empty as of this
    # writing) — so unlike traefik/cosign/oras/act_runner above, there is
    # no tagged release artifact to fetch+verify. Pin to a specific commit
    # SHA on `develop` instead of a floating branch ref, and verify the
    # clone actually landed on it before trusting anything in the tree —
    # same hermetic discipline as the sha256-pinned fetches elsewhere in
    # this stage, just keyed on a commit rather than a release checksum.
    #
    # Do NOT run the repo's own scripts/install.sh here — it self-elevates
    # via sudo and assumes a live systemd/bash-completion/host environment
    # (an already-booted machine), not a build chroot. Replicate exactly
    # what it does with plain install(1) calls instead.
    TMUX_MANAGER_REF="develop"
    TMUX_MANAGER_SHA="58892994f9f5afc753feb8dfe017fbc59d7088eb"

    rm -rf /tmp/tmux-manager-src
    git clone --depth 1 --branch "$TMUX_MANAGER_REF" \
      https://github.com/rett/tmux-manager.git /tmp/tmux-manager-src
    got_sha=$(cd /tmp/tmux-manager-src && git rev-parse HEAD)
    if [ "$got_sha" != "$TMUX_MANAGER_SHA" ]; then
      echo "[stage-1.5] FATAL: tmux-manager HEAD sha mismatch (want $TMUX_MANAGER_SHA got $got_sha) — refusing to build against an unpinned/moved upstream ref" >&2
      exit 1
    fi
    echo "[stage-1.5] tmux-manager: verified clone at pinned commit ${TMUX_MANAGER_SHA}"

    # Main binary — mirrors install.sh's 0755 install to /opt/tmux-manager/bin/.
    mkdir -p /tmp/fat/opt/tmux-manager/bin
    install -m 0755 /tmp/tmux-manager-src/bin/tmux-manager /tmp/fat/opt/tmux-manager/bin/tmux-manager

    # Symlink on PATH — mirrors install.sh's /usr/local/bin symlink.
    mkdir -p /tmp/fat/usr/local/bin
    ln -sf /opt/tmux-manager/bin/tmux-manager /tmp/fat/usr/local/bin/tmux-manager

    # systemd TEMPLATE unit — installed only, never enabled by this module
    # (see manifest.yaml's file_spec comment for why this isn't a
    # `services:` entry).
    mkdir -p /tmp/fat/etc/systemd/system
    install -m 0644 /tmp/tmux-manager-src/systemd/tmux-manager@.service \
      /tmp/fat/etc/systemd/system/tmux-manager@.service

    # bash completion — install whatever single file is in the repo's
    # completions/ dir under the canonical target name `tmux-manager`.
    # FATAL if the directory is empty or ambiguous rather than guessing.
    mkdir -p /tmp/fat/usr/share/bash-completion/completions
    comp_files=(/tmp/tmux-manager-src/completions/*)
    if [ "${#comp_files[@]}" -ne 1 ] || [ ! -f "${comp_files[0]}" ]; then
      echo "[stage-1.5] FATAL: expected exactly one file in tmux-manager's completions/ dir, found: ${comp_files[*]:-<none>}" >&2
      exit 1
    fi
    install -m 0644 "${comp_files[0]}" \
      /tmp/fat/usr/share/bash-completion/completions/tmux-manager

    # Guard what actually SHIPS: this module's entire payload beyond apt
    # tmux is these 4 files — a failed/partial clone or install must not
    # silently carve an empty module (same discipline as claude-tmux's
    # npm-install guard and act_runner's binary guard above).
    if [ ! -s /tmp/fat/opt/tmux-manager/bin/tmux-manager ] || \
       [ ! -L /tmp/fat/usr/local/bin/tmux-manager ] || \
       [ ! -s /tmp/fat/etc/systemd/system/tmux-manager@.service ] || \
       [ ! -s /tmp/fat/usr/share/bash-completion/completions/tmux-manager ]; then
      echo "[stage-1.5] FATAL: tmux-manager did not fully install into /tmp/fat" >&2
      exit 1
    fi
    echo "=== tmux-manager: install result ==="
    ls -la /tmp/fat/opt/tmux-manager/bin/tmux-manager \
           /tmp/fat/usr/local/bin/tmux-manager \
           /tmp/fat/etc/systemd/system/tmux-manager@.service \
           /tmp/fat/usr/share/bash-completion/completions/tmux-manager
    ;;
  dev-cell-browser)
    # Google Chrome (google-chrome-stable) has no apt package on Ubuntu
    # Noble — chromium-browser/firefox are both transitional snap-redirect
    # stubs, and adding Google's own apt repo via an mmdebstrap
    # essential-hook hits the same failure already documented for the
    # docker-ce repo (see gitea-act-runner/manifest.yaml's package_spec
    # comment: the hook runs AFTER the package index is built, with no
    # re-index before --include, so a newly-added repo's packages are
    # never found). Sidestep both problems: fetch the exact-version .deb
    # directly from Google's own pool (a real, versioned, sha256-pinned
    # artifact — verified against dl.google.com/linux/chrome/deb/dists/
    # stable/main/binary-amd64/Packages at authoring time, then
    # independently re-downloaded and re-hashed to confirm) and extract it
    # with dpkg-deb -x. Chrome's real Ubuntu-apt Depends: closure is
    # declared in this module's package_spec instead (ordinary Noble
    # packages, resolved normally by mmdebstrap — no third-party repo
    # needed for those).
    CHROME_VERSION="150.0.7871.128-1"
    CHROME_SHA256="83ed59c85878ebb8fa53915ebe7066cafc58d1c04c1c95449486e6f9d99a1efb"
    CHROME_DEB_URL="https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_${CHROME_VERSION}_amd64.deb"

    curl -fsSL "$CHROME_DEB_URL" -o /tmp/google-chrome-stable.deb
    echo "${CHROME_SHA256}  /tmp/google-chrome-stable.deb" | sha256sum -c -

    # dpkg-deb -x extracts the archive's data.tar payload only — it does
    # NOT run postinst (no update-alternatives, no doc-base/menu
    # registration triggers). That's fine for the plain file payload under
    # /opt/google/chrome/**, but the `google-chrome` alternatives symlink
    # postinst would normally create has to be made by hand below.
    mkdir -p /tmp/fat
    dpkg-deb -x /tmp/google-chrome-stable.deb /tmp/fat

    # Postinst-equivalent: the common invocation name most tooling/scripts
    # expect is `google-chrome`, not the literal `google-chrome-stable`
    # binary the .deb ships — normally an update-alternatives symlink
    # (/usr/bin/google-chrome -> /etc/alternatives/google-chrome ->
    # .../google-chrome-stable) that dpkg-deb -x never creates. A plain
    # symlink gets the same practical result without needing the
    # alternatives system's own bookkeeping files at boot.
    ln -sf /usr/bin/google-chrome-stable /tmp/fat/usr/bin/google-chrome

    # Guard what actually SHIPS: a failed/partial fetch or extraction must
    # not silently carve an empty module (same discipline as every other
    # arm in this file). NOTE: /usr/bin/google-chrome-stable ships as a
    # symlink to the ABSOLUTE path /opt/google/chrome/google-chrome (the
    # .deb's own doing) — that only resolves correctly once /tmp/fat is
    # deployed AS the real root (chroot/boot), not while merely staged
    # here, so `-s` on the symlink itself would falsely report missing.
    # Check the real underlying file at its actual staged path instead,
    # and just confirm the symlinks themselves exist (`-L`) rather than
    # trying to resolve through them.
    if [ ! -s /tmp/fat/opt/google/chrome/google-chrome ] || \
       [ ! -L /tmp/fat/usr/bin/google-chrome-stable ] || \
       [ ! -L /tmp/fat/usr/bin/google-chrome ]; then
      echo "[stage-1.5] FATAL: google-chrome-stable did not fully install into /tmp/fat" >&2
      exit 1
    fi
    echo "=== dev-cell-browser: install result ==="
    ls -la /tmp/fat/usr/bin/google-chrome /tmp/fat/usr/bin/google-chrome-stable /tmp/fat/opt/google/chrome/google-chrome
    du -sh /tmp/fat/opt/google/chrome
    ;;
  module-forge)
    # Bakes /opt/buildenv: a NESTED mmdebstrap'd debian:trixie tree
    # carrying the same toolchain this very workflow's own "Install build
    # tools" + "Install signing toolchain" steps install onto the
    # docker.io/library/debian:trixie-slim CI runner, so a fleet instance
    # running the module-forge NodeModule (campaign 019f5885 inc7) can
    # chroot into a byte-for-byte reproduction of the CI container and
    # produce IDENTICAL build output to a Gitea-Actions-dispatched run of
    # THIS SAME workflow. This is nested mmdebstrap: the OUTER mmdebstrap
    # already ran in Stage 1 (module-forge's OWN noble-based fat rootfs,
    # from its manifest's package_spec); this arm runs a SECOND,
    # independent mmdebstrap of a completely different suite (trixie, not
    # noble) into a subtree that gets carved into module-forge's shipped
    # erofs at /opt/buildenv/** (see its manifest.yaml file_spec).
    #
    # No --keyring override needed for THIS bootstrap the way Stage 1's
    # noble bootstrap needs ubuntu-keyring: the runner already IS
    # debian:trixie-slim, so mmdebstrap can bootstrap trixie from the
    # runner's own already-trusted debian-archive-keyring (installed
    # defensively below in case a future runner image ever ships without
    # it). ubuntu-keyring is instead something this arm installs INTO the
    # nested tree (see package list below) — build-one-module.sh, run
    # later inside this buildroot, bootstraps a TARGET module's own
    # noble-based fat rootfs and needs ubuntu-keyring available from
    # within the chroot to do that cross-distro bootstrap, exactly as
    # Stage 1 does out here.
    #
    # Package list intentionally goes beyond module-forge's design note's
    # short-hand list (mmdebstrap, arch-test, ubuntu-keyring, erofs-utils,
    # fsverity, uuid-runtime, oras, cosign) to also include jq, rsync,
    # python3-yaml, git, curl, gnupg, tar, ca-certificates — every one of
    # these is a hard dependency of build-one-module.sh and the three
    # stage scripts it calls (jq: manifest parsing everywhere; rsync:
    # Stage 2's carve, plus module-forge-build.sh's own buildroot-seed
    # copy; python3-yaml: the yq-unavailable fallback in the manifest-
    # parse replication; git: cloning the module source + `git log`/
    # SOURCE_DATE_EPOCH in Stage 2; curl/gnupg/ca-certificates: every
    # sha256-pinned fetch across this stage's other arms). Omitting any of
    # these would make module-forge's own buildroot unable to build most
    # OTHER modules — a strictly worse reproduction of the CI container
    # than the explicit list below already achieves for free (this arm
    # just installs the CI container's own already-vetted package set).
    apt-get install -y --no-install-recommends debian-archive-keyring >/dev/null 2>&1 || true
    mkdir -p /tmp/buildenv
    mmdebstrap \
      --mode=root \
      --variant=minbase \
      --components=main \
      --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
      --include=git,mmdebstrap,arch-test,ubuntu-keyring,erofs-utils,fsverity,jq,rsync,python3-yaml,ca-certificates,curl,gnupg,tar,uuid-runtime \
      trixie /tmp/buildenv http://deb.debian.org/debian

    # erofs-utils version guard: Stage 2 (campaign 019f5885 inc5) relies
    # on mkfs.erofs's -T/-U flags, confirmed present from erofs-utils
    # 1.8.6 onward (see stage2-carve.sh's own comment, verified against
    # the SAME debian:trixie-slim container this arm just reproduced). A
    # build inside an older buildroot would silently drop those
    # determinism flags rather than failing loudly, so check explicitly
    # rather than trust trixie's current version forever.
    EROFS_UTILS_VER=$(chroot /tmp/buildenv mkfs.erofs --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    if ! dpkg --compare-versions "${EROFS_UTILS_VER:-0}" ge "1.8.6"; then
      echo "[stage-1.5] FATAL: /opt/buildenv's erofs-utils ${EROFS_UTILS_VER:-<unknown>} is older than the required 1.8.6 (mkfs.erofs -T/-U support) — trixie's archive has drifted; investigate before shipping this buildroot"
      exit 1
    fi
    echo "[stage-1.5] buildenv erofs-utils: ${EROFS_UTILS_VER}"

    # oras (sha256-pinned) — same ORAS_VERSION=1.2.0 already pinned
    # elsewhere in this pipeline's own toolchain (this workflow's "Install
    # signing toolchain" step), so this buildroot's oras is the identical
    # version CI itself runs. That step's own fetch is NOT sha256-checked
    # today; this one is — the checksum below is the vendor-published
    # oras_1.2.0_checksums.txt value, independently re-verified against a
    # fresh download.
    ORAS_VERSION="1.2.0"
    ORAS_SHA256=5b3f1cbb86d869eee68120b9b45b9be983f3738442f87ee5f06b00edd0bab336
    mkdir -p /tmp/buildenv/usr/local/bin
    curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" -o /tmp/oras.tar.gz
    echo "${ORAS_SHA256}  /tmp/oras.tar.gz" | sha256sum -c -
    tar -xzf /tmp/oras.tar.gz -C /tmp/buildenv/usr/local/bin oras
    chmod 0755 /tmp/buildenv/usr/local/bin/oras
    rm -f /tmp/oras.tar.gz

    # cosign (sha256-pinned) — REUSES the exact version+checksum ALREADY
    # pinned in the base-os-ubuntu-noble arm above (COSIGN_VERSION=3.0.6),
    # not a second independent pin, so this repo never has two different
    # "trusted" cosign versions to keep straight. Shipped for parity with
    # the CI container's own toolchain / future use only — NOT invoked by
    # push.sh (this increment's builds are UNSIGNED; cosign signing moves
    # server-side in campaign 019f5885 inc8).
    COSIGN_VERSION=3.0.6
    COSIGN_SHA256=c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" -o /tmp/buildenv/usr/local/bin/cosign
    got=$(sha256sum /tmp/buildenv/usr/local/bin/cosign | awk '{print $1}')
    [ "$got" = "$COSIGN_SHA256" ] || { echo "[stage-1.5] FATAL: buildenv cosign sha256 mismatch (want $COSIGN_SHA256 got $got)"; rm -f /tmp/buildenv/usr/local/bin/cosign; exit 1; }
    chmod 0755 /tmp/buildenv/usr/local/bin/cosign

    echo "[stage-1.5] buildenv toolchain:"
    chroot /tmp/buildenv mmdebstrap --version || true
    chroot /tmp/buildenv mkfs.erofs --version || true
    chroot /tmp/buildenv fsverity --version || true
    /tmp/buildenv/usr/local/bin/oras version | head -1
    /tmp/buildenv/usr/local/bin/cosign version | head -1

    # Layer the nested buildroot into module-forge's OWN fat rootfs at
    # /opt/buildenv — carved into the shipped erofs by that manifest's
    # file_spec "/opt/buildenv/**" entry.
    mkdir -p /tmp/fat/opt/buildenv
    rsync -a /tmp/buildenv/ /tmp/fat/opt/buildenv/
    rm -rf /tmp/buildenv

    # Ship the build scripts this buildroot exists to run
    # (scripts/module-build/*.sh, campaign 019f5885 inc6) at
    # /opt/module-build/ — COPIED (not symlinked/referenced): the erofs
    # artifact must be self-contained, and no live path back into this
    # repo checkout exists on a running fleet instance. Copied at BUILD
    # TIME from this checkout's own scripts/module-build/ (relative to
    # $ws, already `cd`'d into at the top of this script) — never
    # hand-duplicated as static rootfs/ files — so every module-forge
    # rebuild automatically re-syncs any later fix to those shared
    # scripts with zero drift risk.
    mkdir -p /tmp/fat/opt/module-build
    rsync -a scripts/module-build/ /tmp/fat/opt/module-build/
    find /tmp/fat/opt/module-build -maxdepth 1 -name '*.sh' -exec chmod 0755 {} +
    echo "=== module-forge: staged buildenv + build scripts ==="
    du -sh /tmp/fat/opt/buildenv 2>&1 | awk 'NR==1'
    ls /tmp/fat/opt/module-build/
    ;;
  gitleaks)
    # gitleaks has no apt package — fetch the pinned upstream release
    # tarball and verify its sha256, same hermetic pattern as the
    # act_runner/oras/cosign fetches elsewhere in this stage. gitleaks is a
    # fully-static Go binary, so it needs no *.so companions (contrast the
    # apt-sourced modules) — the single /usr/local/bin/gitleaks entry in the
    # manifest file_spec is the module's entire payload.
    GITLEAKS_VERSION=$(jq -r '.build.gitleaks_version // "8.21.2"' /tmp/manifest.json)

    # Upstream names amd64 assets "x64", arm64 assets "arm64"
    # (github.com/gitleaks/gitleaks/releases). Pinned sha256 for
    # gitleaks_${GITLEAKS_VERSION}_linux_<glarch>.tar.gz — bump both alongside
    # build.gitleaks_version on any version change.
    case "${ARCH:-amd64}" in
      amd64) GL_ARCH=x64;   GITLEAKS_SHA256=5bc41815076e6ed6ef8fbecc9d9b75bcae31f39029ceb55da08086315316e3ba ;;
      arm64) GL_ARCH=arm64; GITLEAKS_SHA256=654c935542c89f565aabe7bf7c6c500830f116c114f0aeb509d2460c1ac2e6da ;;
      *) echo "[stage-1.5] FATAL: no pinned gitleaks sha256 for ARCH=${ARCH:-amd64}"; exit 1 ;;
    esac

    curl -fsSL \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GL_ARCH}.tar.gz" \
      -o /tmp/gitleaks.tar.gz
    echo "${GITLEAKS_SHA256}  /tmp/gitleaks.tar.gz" | sha256sum -c -

    mkdir -p /tmp/fat/usr/local/bin
    tar -xzf /tmp/gitleaks.tar.gz -C /tmp/fat/usr/local/bin gitleaks
    chmod 0755 /tmp/fat/usr/local/bin/gitleaks
    rm -f /tmp/gitleaks.tar.gz

    # Verify what actually shipped. Only exec on an amd64 runner (the only
    # ARCH built today) — a cross-arch fetch has its integrity confirmed by
    # the sha256sum -c above and can't be exec'd on this runner anyway.
    if [ "${ARCH:-amd64}" = "amd64" ]; then
      GITLEAKS_OUT=$(/tmp/fat/usr/local/bin/gitleaks version 2>&1 || true)
      echo "[stage-1.5] gitleaks: $GITLEAKS_OUT"
      echo "$GITLEAKS_OUT" | grep -q "${GITLEAKS_VERSION}" || { echo "[stage-1.5] FATAL: expected gitleaks ${GITLEAKS_VERSION}, got: $GITLEAKS_OUT"; exit 1; }
    else
      echo "[stage-1.5] skipping gitleaks version exec check for ARCH=${ARCH:-amd64} (cross-arch binary) — sha256 already verified above"
    fi
    ;;

  gh)
    # gh (GitHub CLI) has no apt package — fetch the pinned upstream release
    # tarball and verify its sha256, same hermetic pattern as the gitleaks /
    # act_runner / oras / cosign fetches elsewhere in this stage. gh is a
    # fully-static Go binary (verified `statically linked`), so it needs no
    # *.so companions — the single /usr/local/bin/gh entry in the manifest
    # file_spec is the module's entire payload. Unlike gitleaks (flat tarball),
    # gh's release tarball NESTS the binary at gh_<ver>_linux_<arch>/bin/gh.
    GH_VERSION=$(jq -r '.build.gh_version // "2.97.0"' /tmp/manifest.json)

    # Pinned sha256 for gh_${GH_VERSION}_linux_<arch>.tar.gz
    # (github.com/cli/cli/releases). Bump both alongside build.gh_version on any
    # version change — values come from the release's gh_<ver>_checksums.txt.
    case "${ARCH:-amd64}" in
      amd64) GH_ARCH=amd64; GH_SHA256=a2c9b8497e1f85b1ad0dfcb78b5a622e098801b8e461e459e88e1ee12f018112 ;;
      arm64) GH_ARCH=arm64; GH_SHA256=73ea440ecad9c9e284429997ee6f93577bc6f7bc6fba357ef62c53ad8fb641a5 ;;
      *) echo "[stage-1.5] FATAL: no pinned gh sha256 for ARCH=${ARCH:-amd64}"; exit 1 ;;
    esac

    curl -fsSL \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${GH_ARCH}.tar.gz" \
      -o /tmp/gh.tar.gz
    echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c -

    mkdir -p /tmp/fat/usr/local/bin
    # Nested layout: extract ONLY the binary, dropping the bundled man pages and
    # shell completions the tarball also carries.
    tar -xzf /tmp/gh.tar.gz -C /tmp/fat/usr/local/bin --strip-components=2 \
      "gh_${GH_VERSION}_linux_${GH_ARCH}/bin/gh"
    chmod 0755 /tmp/fat/usr/local/bin/gh
    rm -f /tmp/gh.tar.gz

    # Verify what actually shipped. Only exec on an amd64 runner (the only ARCH
    # built today) — a cross-arch fetch has its integrity confirmed by the
    # sha256sum -c above and can't be exec'd on this runner anyway.
    if [ "${ARCH:-amd64}" = "amd64" ]; then
      GH_OUT=$(/tmp/fat/usr/local/bin/gh --version 2>&1 || true)
      echo "[stage-1.5] gh: $GH_OUT"
      echo "$GH_OUT" | grep -q "${GH_VERSION}" || { echo "[stage-1.5] FATAL: expected gh ${GH_VERSION}, got: $GH_OUT"; exit 1; }
    else
      echo "[stage-1.5] skipping gh version exec check for ARCH=${ARCH:-amd64} (cross-arch binary) — sha256 already verified above"
    fi
    ;;

  vault)
    # HashiCorp Vault has no package in the Ubuntu archive (HashiCorp ship
    # their own apt repo, which this build model does not consume) — fetch the
    # pinned upstream release and verify its sha256, the same hermetic pattern
    # as the gh / gitleaks / act_runner / oras / cosign fetches above. Vault is
    # a fully-static Go binary, so it needs no *.so companions.
    #
    # UNLIKE every other fetch in this stage, the release asset is a ZIP, not a
    # tar.gz. unzip is not guaranteed in the builder image and no other case
    # needs it, so this falls back to python3's zipfile module (present in the
    # base image for the platform's own tooling) and fails LOUDLY if neither
    # extractor exists — rather than silently shipping a module with no binary.
    #
    # LICENCE: Vault is BUSL-1.1 from 1.15 onward, not MPL/MIT. See the manifest
    # header before widening where this module is used.
    VAULT_VERSION=$(jq -r '.build.vault_version // "1.20.4"' /tmp/manifest.json)

    # Pinned sha256 for vault_${VAULT_VERSION}_linux_<arch>.zip, taken from
    # https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS
    # Bump both alongside build.vault_version on any version change; a version
    # bump without them fails closed here rather than shipping unverified bytes.
    case "${ARCH:-amd64}" in
      amd64) VAULT_ARCH=amd64; VAULT_SHA256=fc5fb5d01d192f1216b139fb5c6af17e3af742aaeffc289fd861920ec55f2c9c ;;
      arm64) VAULT_ARCH=arm64; VAULT_SHA256=d1e9548efd89e772b6be9dc37914579cabd86362779b7239d2d769cfb601d835 ;;
      *) echo "[stage-1.5] FATAL: no pinned vault sha256 for ARCH=${ARCH:-amd64}"; exit 1 ;;
    esac

    curl -fsSL \
      "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${VAULT_ARCH}.zip" \
      -o /tmp/vault.zip
    echo "${VAULT_SHA256}  /tmp/vault.zip" | sha256sum -c -

    mkdir -p /tmp/fat/usr/local/bin
    # python3, not unzip. The CI container is debian:trixie-slim and installs a
    # fixed apt list (build-platform-modules.yaml) that includes python3-yaml but
    # NOT unzip; module-forge's buildroot mirrors the same list. An `unzip ||
    # python3` fallback would therefore have a primary branch that never
    # executes, which is worse than no branch: it reads as covered and is never
    # exercised. python3 is guaranteed by python3-yaml being installed.
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract('vault', sys.argv[2])" \
      /tmp/vault.zip /tmp/fat/usr/local/bin
    chmod 0755 /tmp/fat/usr/local/bin/vault
    rm -f /tmp/vault.zip

    # Verify what actually shipped. Only exec on an amd64 runner (the only ARCH
    # built today) — a cross-arch fetch has its integrity confirmed by the
    # sha256sum -c above and can't be exec'd on this runner anyway.
    if [ "${ARCH:-amd64}" = "amd64" ]; then
      VAULT_OUT=$(/tmp/fat/usr/local/bin/vault version 2>&1 || true)
      echo "[stage-1.5] vault: $VAULT_OUT"
      echo "$VAULT_OUT" | grep -q "${VAULT_VERSION}" || { echo "[stage-1.5] FATAL: expected vault ${VAULT_VERSION}, got: $VAULT_OUT"; exit 1; }
    else
      echo "[stage-1.5] skipping vault version exec check for ARCH=${ARCH:-amd64} (cross-arch binary) — sha256 already verified above"
    fi
    ;;
esac

echo "=== /tmp/fat top-level layout after stage 1.5 ==="
find /tmp/fat -maxdepth 3 -type d | sort | awk 'NR<=30'
echo "=== file count ==="
find /tmp/fat -type f | wc -l
