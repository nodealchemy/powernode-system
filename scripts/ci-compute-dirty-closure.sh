#!/usr/bin/env bash
# ci-compute-dirty-closure.sh — emits the list of modules that need
# rebuilding for the current CI invocation. Two trigger paths:
#
#   1. Source-path filter (git diff): modules whose source files changed
#      directly, plus the agent special-case (agent/** forces system-base),
#      plus catch-all triggers (workflow yaml, Containerfile).
#   2. Apt-closure drift (oras manifest fetch): modules whose effective
#      apt-closure version-hash differs from the one annotated on the
#      last-published OCI artifact. Dep-graph-aware: packages now owned
#      by a separate module (linked via capability provides/requires) are
#      excluded so a postgres-libs split doesn't re-trigger postgres-primary.
#
# Both trigger paths feed into a single dirty SET, which is then expanded
# transitively via the reverse-dependency graph (provider → dependents)
# to cover everything downstream.
#
# Output: one module name per line on stdout. Suitable for stuffing into
# a GITHUB_ENV / GITEA_ENV file: `DIRTY_MODULES="<space-separated list>"`.
#
# Usage:
#   bash scripts/ci-compute-dirty-closure.sh [BASE_SHA] [HEAD_SHA]
#     BASE_SHA defaults to $GITEA_EVENT_BEFORE / $GITHUB_BASE_SHA / HEAD~1
#     HEAD_SHA defaults to $GITHUB_SHA / HEAD
#
# Env knobs:
#   MODULES_DIR=modules               (root of per-module manifests)
#   APT_DRIFT_CHECK=1                 (1 = enable apt query, 0 = skip — default)
#   APT_REGISTRY=git.ipnode.org       (oras pull source for annotations)
#   APT_OWNER=powernode               (oras namespace)
#   APT_PROBE_MODE=local              (local | docker)
#                                       local: run apt-cache in the current
#                                              shell — works when the runner
#                                              is debian:trixie-slim (the
#                                              default container image), no
#                                              docker dependency
#                                       docker: spawn a debian:trixie-slim
#                                               container per probe — requires
#                                               docker socket access
#   APT_DRIFT_PROBE_IMAGE=debian:trixie-slim
#                                      (only relevant when APT_PROBE_MODE=docker)
#   ALL_TRIGGERS_REGEX                (regex of paths that force full rebuild;
#                                       defaults below)
#
# Subcommands:
#   (default)    Compute and print the dirty closure (one module per line)
#   apt-hash MODULE
#                Compute and print the apt-closure-sha256 for MODULE — used
#                by the build workflow at publish time to write the
#                org.powernode.apt-closure-sha256 annotation on the OCI
#                artifact. The drift check in the default subcommand
#                reads this annotation to compare.
#
# Exit codes:
#   0 — success (dirty list on stdout, may be empty)
#   1 — git diff failed or no module manifests found
#   2 — apt drift probe failed (only when APT_DRIFT_CHECK=1 / apt-hash)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# Subcommand dispatch — `apt-hash MODULE` short-circuits the closure
# computation and prints just the apt-closure-sha256 for the named module.
SUBCOMMAND="${1:-closure}"
if [[ "$SUBCOMMAND" == "apt-hash" ]]; then
  APT_HASH_TARGET="${2:-}"
  if [[ -z "$APT_HASH_TARGET" ]]; then
    echo "usage: $0 apt-hash <module-name>" >&2
    exit 2
  fi
  # Skip the BASE/HEAD positional defaults for this mode.
  BASE_SHA="HEAD"
  HEAD_SHA="HEAD"
else
  # Default subcommand: compute dirty closure. Re-parse positional args
  # in the original way: $1=BASE_SHA, $2=HEAD_SHA (both optional).
  APT_HASH_TARGET=""
  BASE_SHA="${1:-${GITEA_EVENT_BEFORE:-${GITHUB_BASE_SHA:-HEAD~1}}}"
  HEAD_SHA="${2:-${GITHUB_SHA:-HEAD}}"
fi

MODULES_DIR="${MODULES_DIR:-modules}"
APT_DRIFT_CHECK="${APT_DRIFT_CHECK:-0}"
APT_REGISTRY="${APT_REGISTRY:-git.ipnode.org}"
APT_OWNER="${APT_OWNER:-powernode}"
APT_PROBE_MODE="${APT_PROBE_MODE:-local}"
APT_DRIFT_PROBE_IMAGE="${APT_DRIFT_PROBE_IMAGE:-debian:trixie-slim}"

# A change to any of these forces every module to rebuild. The workflow
# yaml itself drives the build (a step rename triggers a rebuild to pick
# up the new step); the Containerfile is the shared Stage 1 base; the
# agent source feeds powernode-system-base's cross-compile but the
# system-base entry alone won't cover dep-graph expansion until the
# closure step runs.
ALL_TRIGGERS_REGEX="${ALL_TRIGGERS_REGEX:-^(\.gitea/workflows/build-platform-modules\.yaml|templates/module-repo/Containerfile|scripts/ci-compute-dirty-closure\.sh)$}"

log() { printf '[dirty-closure] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Build the dependency graph from all manifests
# ---------------------------------------------------------------------------

# We need mikefarah's yq (Go) for YAML parsing — NOT Debian's python3-yq
# (which is a jq wrapper that doesn't accept `-o=json` or `.[]` shapes).
# Detect which variant is installed; if Debian's wrapper is present
# (or yq is missing entirely), download mikefarah's release binary to
# /usr/local/bin/yq. This also fixes the subsequent "Parse manifest"
# step which assumes mikefarah's yq when `command -v yq` succeeds —
# previously `apt install yq` here would install the wrong variant
# and break that step.
have_mikefarah_yq() {
  command -v yq >/dev/null 2>&1 || return 1
  # mikefarah's yq prints "yq (https://github.com/mikefarah/yq/)..."
  # Python yq prints "jq-X.Y" or "yq X.Y" with no mikefarah URL.
  yq --version 2>&1 | grep -q 'mikefarah/yq'
}
if ! have_mikefarah_yq; then
  log "installing mikefarah/yq (current yq variant is missing or incompatible)..."
  if command -v curl >/dev/null 2>&1; then
    arch="$(uname -m)"
    case "$arch" in
      x86_64) yq_arch=amd64 ;;
      aarch64|arm64) yq_arch=arm64 ;;
      *) log "ERROR: unsupported arch for yq install: $arch"; exit 1 ;;
    esac
    yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}"
    if ! curl -fsSL "$yq_url" -o /usr/local/bin/yq 2>/dev/null; then
      log "ERROR: failed to download mikefarah/yq from $yq_url"
      exit 1
    fi
    chmod +x /usr/local/bin/yq
    hash -r  # bash rebuilds command lookup table
    if ! have_mikefarah_yq; then
      log "ERROR: mikefarah/yq install succeeded but binary still not detected"
      exit 1
    fi
  else
    log "ERROR: yq not installed and curl unavailable for self-install"
    exit 1
  fi
fi

declare -A PROVIDES_TO_MODULE  # capability tag (no version) → providing module
declare -A MODULE_REQUIRES     # module → space-separated list of required capabilities/names
declare -A MODULE_PACKAGES     # module → space-separated list of apt packages
declare -a ALL_MODULES         # ordered list of every known module

found_manifests=0
for manifest in "$MODULES_DIR"/*/manifest.yaml; do
  [[ -f "$manifest" ]] || continue
  found_manifests=$((found_manifests + 1))
  mod="$(basename "$(dirname "$manifest")")"
  ALL_MODULES+=("$mod")

  # `provides` may be missing; yq returns "null" string which we treat as empty.
  provides_raw="$(yq -r '.dependencies.provides // [] | .[]' "$manifest" 2>/dev/null || true)"
  while IFS= read -r cap; do
    [[ -z "$cap" ]] && continue
    # Strip version (after @) so the lookup key is just the capability name.
    bare_cap="${cap%@*}"
    PROVIDES_TO_MODULE["$bare_cap"]="$mod"
  done <<< "$provides_raw"

  requires_raw="$(yq -r '.dependencies.requires // [] | .[]' "$manifest" 2>/dev/null || true)"
  reqs=""
  while IFS= read -r req; do
    [[ -z "$req" ]] && continue
    bare="${req%@*}"
    # Drop a leading "capability:" prefix; the resolver in
    # ManifestImportService treats anything else as a direct module name.
    bare="${bare#capability:}"
    reqs+="$bare "
  done <<< "$requires_raw"
  MODULE_REQUIRES["$mod"]="${reqs% }"

  packages_raw="$(yq -r '.package_spec // [] | .[]' "$manifest" 2>/dev/null || true)"
  pkgs=""
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    # Strip apt version constraints (`pkg=1.2` → `pkg`); the version
    # check happens separately via apt-cache.
    pkgs+="${pkg%%=*} "
  done <<< "$packages_raw"
  MODULE_PACKAGES["$mod"]="${pkgs% }"
done

if [[ "$found_manifests" -eq 0 ]]; then
  log "ERROR: no manifest.yaml under $MODULES_DIR/*/ — cannot compute closure"
  exit 1
fi

# Build the reverse-dependency graph: provider → space-separated dependents.
# Used to expand the dirty set transitively (a dirty postgres-primary
# pulls in everything that requires database.postgres).
declare -A DEPENDENTS
for mod in "${!MODULE_REQUIRES[@]}"; do
  for req in ${MODULE_REQUIRES[$mod]}; do
    # req may be a capability tag (resolves via PROVIDES_TO_MODULE) OR
    # a direct module name (matches a key in MODULE_REQUIRES). Try both.
    provider="${PROVIDES_TO_MODULE[$req]:-}"
    if [[ -z "$provider" ]] && [[ -n "${MODULE_REQUIRES[$req]+set}" ]]; then
      provider="$req"
    fi
    if [[ -n "$provider" && "$provider" != "$mod" ]]; then
      DEPENDENTS["$provider"]+="$mod "
    fi
  done
done

# Counts via parameter-expansion guard — under `set -u` bash refuses to
# evaluate ${#assoc[@]} when the array has never had a key assigned.
# `${assoc[@]+set}` returns "set" only when the array is non-empty,
# which is exactly the case where ${#assoc[@]} is safe to query.
prov_count=0; [[ "${PROVIDES_TO_MODULE[@]+set}" == "set" ]] && prov_count="${#PROVIDES_TO_MODULE[@]}"
deps_count=0; [[ "${DEPENDENTS[@]+set}" == "set" ]] && deps_count="${#DEPENDENTS[@]}"
log "parsed $found_manifests manifests; $prov_count capabilities; $deps_count providers with dependents"

# ---------------------------------------------------------------------------
# 2. Source-path filter via git diff
# ---------------------------------------------------------------------------

declare -A DIRTY_SET  # module → 1 if dirty

if ! changed_files="$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" 2>/dev/null)"; then
  log "ERROR: git diff $BASE_SHA..$HEAD_SHA failed"
  exit 1
fi
log "git diff $BASE_SHA..$HEAD_SHA: $(echo "$changed_files" | wc -l | xargs) files changed"

force_all=0
agent_changed=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ "$f" =~ $ALL_TRIGGERS_REGEX ]]; then
    force_all=1
    log "  catch-all trigger: $f"
    continue
  fi
  if [[ "$f" =~ ^agent/ ]]; then
    agent_changed=1
    continue
  fi
  if [[ "$f" =~ ^${MODULES_DIR}/([^/]+)/ ]]; then
    mod="${BASH_REMATCH[1]}"
    if [[ -n "${MODULE_REQUIRES[$mod]+set}" || -n "${MODULE_PACKAGES[$mod]+set}" ]]; then
      DIRTY_SET["$mod"]=1
    fi
  fi
done <<< "$changed_files"

if [[ "$force_all" -eq 1 ]]; then
  log "catch-all triggered — marking ALL modules dirty"
  for mod in "${ALL_MODULES[@]}"; do DIRTY_SET["$mod"]=1; done
fi

if [[ "$agent_changed" -eq 1 ]]; then
  log "agent source changed — forcing powernode-system-base (and dependents) dirty"
  if [[ -n "${MODULE_REQUIRES[powernode-system-base]+set}" || -n "${MODULE_PACKAGES[powernode-system-base]+set}" ]]; then
    DIRTY_SET["powernode-system-base"]=1
  fi
fi

dirty_count=0; [[ "${DIRTY_SET[@]+set}" == "set" ]] && dirty_count="${#DIRTY_SET[@]}"
log "directly-dirty (source path): $dirty_count modules"

# ---------------------------------------------------------------------------
# 3. Apt-closure drift detection (opt-in via APT_DRIFT_CHECK=1)
# ---------------------------------------------------------------------------

# For each module not already dirty, compute its effective package_spec
# (after dep-graph-aware exclusion), query upstream apt for current
# versions, hash the result, and compare to the hash annotated on the
# last-published OCI artifact. Mismatch → mark dirty.
#
# The dep-graph-aware exclusion is the subtle part: when postgres-primary
# requires `database.postgres-libs` (provided by a hypothetical libs
# module) and BOTH modules' package_spec declare libpq-dev, libpq-dev
# should count toward the libs module's drift but NOT postgres-primary's
# — otherwise renaming a sub-dep into its own module would still cascade
# rebuilds back into the original.

effective_packages_for() {
  local mod="$1"
  local out=""
  for pkg in ${MODULE_PACKAGES[$mod]:-}; do
    local excluded=0
    # If ANY required-via-capability dep also declares this package,
    # the dep owns it now — skip in the local closure.
    for req in ${MODULE_REQUIRES[$mod]:-}; do
      local provider="${PROVIDES_TO_MODULE[$req]:-}"
      [[ -z "$provider" && -n "${MODULE_REQUIRES[$req]+set}" ]] && provider="$req"
      [[ -z "$provider" || "$provider" == "$mod" ]] && continue
      for other_pkg in ${MODULE_PACKAGES[$provider]:-}; do
        if [[ "$other_pkg" == "$pkg" ]]; then
          excluded=1
          break 2
        fi
      done
    done
    [[ "$excluded" -eq 0 ]] && out+="$pkg "
  done
  printf '%s\n' "${out% }"
}

# ---------------------------------------------------------------------------
# Apt-probe + hash helpers (used by drift check + apt-hash subcommand)
# ---------------------------------------------------------------------------

# Populate APT_VERSION map with current apt-candidate versions for the
# given packages. Picks local vs docker mode based on APT_PROBE_MODE.
# Idempotent — repeated calls just overwrite the map.
declare -A APT_VERSION
APT_PROBE_DONE=0

probe_apt_versions() {
  local pkgs="$1"
  [[ -z "${pkgs// /}" ]] && return 0
  local probe_script
  probe_script="apt-get update -qq && apt-cache policy $pkgs 2>/dev/null | awk '/^[a-z]/{p=\$1; sub(\":\$\", \"\", p)} /Candidate:/{print p\" \"\$2}'"
  case "$APT_PROBE_MODE" in
    local)
      while IFS=' ' read -r p v; do
        [[ -n "$p" && -n "$v" ]] && APT_VERSION["$p"]="$v"
      done < <(bash -c "$probe_script" 2>/dev/null || true)
      ;;
    docker)
      if ! command -v docker >/dev/null 2>&1; then
        log "WARN: APT_PROBE_MODE=docker but docker missing — apt versions will be 'unknown'"
        return 0
      fi
      while IFS=' ' read -r p v; do
        [[ -n "$p" && -n "$v" ]] && APT_VERSION["$p"]="$v"
      done < <(docker run --rm "$APT_DRIFT_PROBE_IMAGE" bash -c "$probe_script" 2>/dev/null || true)
      ;;
    *)
      log "WARN: unknown APT_PROBE_MODE='$APT_PROBE_MODE' — apt versions will be 'unknown'"
      ;;
  esac
}

# Compute the apt-closure-sha256 for one module: take its effective
# packages (after dep-graph-aware exclusion), look up current versions
# from the APT_VERSION map (probe-on-demand), and sha256 the sorted
# "pkg=version" snapshot. Empty package_spec → empty hash (so modules
# that don't install apt packages aren't subject to drift).
compute_apt_hash_for_module() {
  local mod="$1"
  local eff
  eff="$(effective_packages_for "$mod")"
  if [[ -z "${eff// /}" ]]; then
    printf ''  # empty hash signals "no apt closure"
    return 0
  fi
  # Lazy probe on first compute.
  if [[ "$APT_PROBE_DONE" -eq 0 ]]; then
    probe_apt_versions "$(printf '%s\n' $eff | sort -u | tr '\n' ' ')"
    APT_PROBE_DONE=1
  fi
  local snapshot=""
  for p in $eff; do
    snapshot+="$p=${APT_VERSION[$p]:-unknown}"$'\n'
  done
  printf '%s' "$snapshot" | sort | sha256sum | cut -d' ' -f1
}

# ---------------------------------------------------------------------------
# 3 (continued). Apt-closure drift detection — opt-in
# ---------------------------------------------------------------------------

if [[ "$APT_DRIFT_CHECK" == "1" ]]; then
  if ! command -v oras >/dev/null 2>&1; then
    log "WARN: APT_DRIFT_CHECK=1 but oras missing — skipping apt-closure drift"
  else
    log "apt-closure drift check enabled (probe mode: $APT_PROBE_MODE)"

    # Probe once for the UNION of packages across all NOT-already-dirty
    # modules. Avoids per-module apt-get update; the runner shares a
    # single apt cache for all queries.
    union_packages=""
    for mod in "${ALL_MODULES[@]}"; do
      [[ -n "${DIRTY_SET[$mod]:-}" ]] && continue
      union_packages+="$(effective_packages_for "$mod") "
    done
    union_packages="$(printf '%s\n' $union_packages | sort -u | tr '\n' ' ')"
    if [[ -n "${union_packages// /}" ]]; then
      log "probing apt versions for $(echo "$union_packages" | wc -w | xargs) unique packages..."
      probe_apt_versions "$union_packages"
      APT_PROBE_DONE=1
      apt_count=0; [[ "${APT_VERSION[@]+set}" == "set" ]] && apt_count="${#APT_VERSION[@]}"
      log "apt probe returned $apt_count version pairs"
    else
      log "no packages in union to probe"
    fi

    for mod in "${ALL_MODULES[@]}"; do
      [[ -n "${DIRTY_SET[$mod]:-}" ]] && continue
      local_hash="$(compute_apt_hash_for_module "$mod")"
      [[ -z "$local_hash" ]] && continue

      # Fetch the previously-recorded hash from the last-published
      # OCI artifact's annotation. Tag convention: powernode/<mod>:latest
      # carries `org.powernode.apt-closure-sha256` written by the build
      # job at publish time. First-ever publish: annotation absent →
      # treat as drift (forces an initial rebuild that records the
      # baseline).
      last_hash=""
      if oras manifest fetch \
          "${APT_REGISTRY}/${APT_OWNER}/${mod}:latest" 2>/dev/null \
          | yq -r '.annotations["org.powernode.apt-closure-sha256"] // ""' \
          > /tmp/apt-hash-"$mod".txt 2>/dev/null; then
        last_hash="$(cat /tmp/apt-hash-"$mod".txt)"
      fi
      rm -f /tmp/apt-hash-"$mod".txt

      if [[ "$last_hash" != "$local_hash" ]]; then
        log "  drift: $mod (was=${last_hash:-<none>} now=$local_hash)"
        DIRTY_SET["$mod"]=1
      fi
    done

    dirty_after=0; [[ "${DIRTY_SET[@]+set}" == "set" ]] && dirty_after="${#DIRTY_SET[@]}"
    log "after apt-closure drift: $dirty_after modules dirty"
  fi
fi

# ---------------------------------------------------------------------------
# apt-hash subcommand — short-circuit closure work, emit hash for one module
# ---------------------------------------------------------------------------

if [[ "$SUBCOMMAND" == "apt-hash" ]]; then
  if [[ -z "${MODULE_PACKAGES[$APT_HASH_TARGET]+set}" && -z "${MODULE_REQUIRES[$APT_HASH_TARGET]+set}" ]]; then
    log "ERROR: module '$APT_HASH_TARGET' has no manifest under $MODULES_DIR/"
    exit 2
  fi
  compute_apt_hash_for_module "$APT_HASH_TARGET"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Expand to closure: add all transitive dependents
# ---------------------------------------------------------------------------

declare -A CLOSURE
queue=()
for mod in "${!DIRTY_SET[@]}"; do queue+=("$mod"); done

while [[ "${#queue[@]}" -gt 0 ]]; do
  mod="${queue[0]}"
  queue=("${queue[@]:1}")
  [[ -n "${CLOSURE[$mod]:-}" ]] && continue
  CLOSURE["$mod"]=1
  for dep in ${DEPENDENTS[$mod]:-}; do
    [[ -n "${CLOSURE[$dep]:-}" ]] && continue
    queue+=("$dep")
  done
done

closure_count=0; [[ "${CLOSURE[@]+set}" == "set" ]] && closure_count="${#CLOSURE[@]}"
log "final closure: $closure_count modules"

# ---------------------------------------------------------------------------
# 5. Emit closure on stdout (sorted; one per line)
# ---------------------------------------------------------------------------

for mod in "${!CLOSURE[@]}"; do printf '%s\n' "$mod"; done | sort -u
