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
#                                powernode-hub-backend/worker/frontend
#                                arms); default: empty. Set in the calling
#                                environment (the workflow step's `env:`
#                                block) — never pass secrets as CLI args.
#   --parent-host HOST             default: git.powernode.org
#   --parent-path OWNER/REPO       default: powernode/powernode-platform
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
POWERNODE_PARENT_HOST="git.powernode.org"
POWERNODE_PARENT_PATH="powernode/powernode-platform"
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

needs_parent=0
case "$MODULE" in
  powernode-hub-backend|powernode-hub-worker|powernode-hub-frontend) needs_parent=1 ;;
esac

if [ "$needs_parent" = "1" ]; then
  parent_host="${POWERNODE_PARENT_HOST:-git.powernode.org}"
  parent_path="${POWERNODE_PARENT_PATH:-powernode/powernode-platform}"
  clone_url="https://x-access-token:${PARENT_PAT}@${parent_host}/${parent_path}.git"
  echo "Cloning parent ${parent_host}/${parent_path}..."
  git clone --depth 1 "$clone_url" /tmp/parent
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
  powernode-hub-backend)
    mkdir -p /tmp/fat/opt/powernode
    rsync -a \
      --exclude='.git' --exclude='node_modules' --exclude='tmp' \
      --exclude='log' --exclude='coverage' --exclude='extensions' \
      /tmp/parent/server/ /tmp/fat/opt/powernode/server/
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
    # Vite build needs node — install if missing. dist/ is
    # the only deliverable; if the build fails the module
    # still ships (just with an empty dist that traefik
    # serves a default error page from).
    mkdir -p /tmp/fat/opt/powernode/frontend/dist
    if ! command -v npm >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends nodejs npm || true
    fi
    if command -v npm >/dev/null 2>&1 && [ -f /tmp/parent/frontend/package.json ]; then
      (cd /tmp/parent/frontend && npm ci --no-audit --prefer-offline 2>&1 | tail -20 && npm run build 2>&1 | tail -20) || echo "frontend build failed — shipping empty dist"
      if [ -d /tmp/parent/frontend/dist ]; then
        rsync -a /tmp/parent/frontend/dist/ /tmp/fat/opt/powernode/frontend/dist/
      fi
    else
      echo "no npm or no frontend package.json — shipping empty dist"
    fi
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
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tgz
    export PATH="/usr/local/go/bin:${PATH}"
    export GOTOOLCHAIN=local
    go version
    echo "[stage-1.5] cross-compiling powernode-agent for amd64…"
    ( cd agent && \
      CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      /usr/local/go/bin/go build -trimpath -ldflags '-s -w' \
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
    mkdir -p /tmp/fat/usr
    npm install -g --prefix /tmp/fat/usr --no-audit --no-fund @anthropic-ai/claude-code
    # Guard what actually SHIPS: the CLI is this module's entire
    # payload (beyond tmux) — a failed/partial npm install must
    # not silently carve an empty module.
    if [ ! -e /tmp/fat/usr/bin/claude ] && [ ! -e /tmp/fat/usr/lib/node_modules/@anthropic-ai/claude-code ]; then
      echo "[stage-1.5] FATAL: @anthropic-ai/claude-code did not install into /tmp/fat/usr"; exit 1
    fi
    echo "=== claude-tmux: npm install result ==="
    ls -la /tmp/fat/usr/bin/claude* 2>/dev/null || true
    ls -d /tmp/fat/usr/lib/node_modules/@anthropic-ai/claude-code 2>/dev/null || true
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
esac

echo "=== /tmp/fat top-level layout after stage 1.5 ==="
find /tmp/fat -maxdepth 3 -type d | sort | awk 'NR<=30'
echo "=== file count ==="
find /tmp/fat -type f | wc -l
