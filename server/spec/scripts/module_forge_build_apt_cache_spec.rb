# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# IMP-01a0813c — the persistent stage-1 apt cache reaches the NATIVE builder.
#
# scripts/module-build/stage1-rootfs.sh has carried the whole cache mechanism
# for a while: STAGE1_APT_CACHE_DIR seeds <dir>/<apt_snapshot>/archives/*.deb
# into the chroot's apt archive before mmdebstrap fetches anything and harvests
# every fetched .deb back afterwards (temp-name + `mv -n`, so a concurrent job
# never sees a half-written file; apt re-verifies each entry against the
# snapshot index, and snapshot content is immutable, so a stale entry can never
# be trusted). Its own documentation stated the gap outright:
#
#   "the build chroot only sees what its caller mounts — a native build needs
#    module-forge-build.sh to bind-mount a persistent host directory into the
#    buildenv and export this variable; until it does, the variable is unset
#    there and this is a no-op."
#
# It never did, so every native module build re-downloaded the same base
# packages from snapshot.ubuntu.com. This drives the REAL script under stubbed
# heavy commands (the module_forge_build_head_sha_spec harness) and asserts the
# three things that make the cache actually work rather than merely be
# configured:
#
#   1. the host cache directory is bind-mounted into the buildenv,
#   2. STAGE1_APT_CACHE_DIR is exported into the BUILD chroot naming the
#      in-chroot path (stage1 runs there; a host path would resolve to nothing),
#   3. the cache OUTLIVES the job — cleanup() rm -rf's $JOB_ROOT on every exit
#      path, so a cache placed under it would be a cache in name only, and
#      every example would still pass 1 and 2.
RSpec.describe "module-forge-build.sh persistent stage-1 apt cache" do
  let(:script) do
    File.expand_path(
      "../../../modules/module-forge/rootfs/usr/local/bin/module-forge-build.sh", __dir__
    )
  end

  # Returns [status, mount_lines, chroot_env_lines, job_base_dir, output].
  # `cache_override` is passed as MODULE_FORGE_APT_CACHE_DIR when non-nil —
  # "" is the deliberate opt-out.
  def run_build(cache_override: nil)
    Dir.mktmpdir("mf-forge-test") do |root|
      stubs   = File.join(root, "stubs")
      baked   = File.join(root, "baked-scripts")
      golden  = File.join(root, "golden-buildenv")
      jobroot = File.join(root, "jobs")
      mount_log = File.join(root, "mount.log")
      env_log   = File.join(root, "chroot-env.log")
      [ stubs, baked, golden, jobroot ].each { |d| FileUtils.mkdir_p(d) }

      %w[build-one-module.sh push.sh].each do |f|
        path = File.join(baked, f)
        File.write(path, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, path)
      end

      write_stub(stubs, "git", git_stub)
      write_stub(stubs, "rsync", "#!/bin/sh\nexit 0\n")
      write_stub(stubs, "uuidgen", "#!/bin/sh\necho 11111111-2222-3333-4444-555555555555\n")
      write_stub(stubs, "mount", "#!/bin/sh\necho \"$@\" >> \"$MOUNT_LOG\"\nexit 0\n")
      write_stub(stubs, "umount", "#!/bin/sh\nexit 0\n")
      write_stub(stubs, "chroot", chroot_stub)

      env = {
        "PATH"                         => "#{stubs}:/usr/bin:/bin",
        "MOUNT_LOG"                    => mount_log,
        "CHROOT_ENV_LOG"               => env_log,
        "MODULE_FORGE_BUILD_SCRIPTS"   => baked,
        "MODULE_FORGE_BUILDENV_GOLDEN" => golden,
        "MODULE_FORGE_JOB_ROOT"        => jobroot,
        "MODULE"                       => "reverse-proxy-traefik",
        "BUILD_SHA"                    => "abc123def456",
        "MODULE_SOURCE_URL"            => "https://example.invalid/powernode/powernode-system.git",
        "ORAS_REGISTRY_USER"           => "ci",
        "ORAS_REGISTRY_PASSWORD"       => "secret", # test-only stub value, never a real credential
        "OCI_REF"                      => "abc123",
        "ORAS_REGISTRY"                => "registry.invalid"
      }
      env["MODULE_FORGE_APT_CACHE_DIR"] = cache_override unless cache_override.nil?

      out = IO.popen(env, [ "bash", script ], err: [ :child, :out ], unsetenv_others: true, &:read)
      status = $?
      mount_lines = File.exist?(mount_log) ? File.read(mount_log).lines.map(&:strip) : []
      env_lines   = File.exist?(env_log) ? File.read(env_log).lines.map(&:strip) : []
      # Snapshot what survived cleanup before the tmpdir goes away.
      survivors = Dir.glob(File.join(jobroot, "**", "*")).map { |p| p.delete_prefix("#{jobroot}/") }
      [ status, mount_lines, env_lines, survivors, out ]
    end
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  def git_stub
    <<~SH
      #!/bin/sh
      if [ "$1" = "clone" ]; then
        dest=""
        for a in "$@"; do dest="$a"; done
        mkdir -p "$dest/modules/$MODULE"
        printf 'build:\\n  apt_snapshot: "x"\\n' > "$dest/modules/$MODULE/manifest.yaml"
        mkdir -p "$dest/scripts/module-build"
        for f in build-one-module.sh push.sh stage15.sh stage1-rootfs.sh stage2-carve.sh; do
          printf '#!/bin/sh\\nexit 0\\n' > "$dest/scripts/module-build/$f"
          chmod 0755 "$dest/scripts/module-build/$f"
        done
      fi
      exit 0
    SH
  end

  # Records the cache variable as the BUILD chroot actually received it, then
  # fabricates the artifacts each step's success is checked on.
  def chroot_stub
    <<~'SH'
      #!/bin/sh
      buildenv="$1"
      cmd="$*"
      case "$cmd" in
        *build-one-module.sh*)
          echo "build STAGE1_APT_CACHE_DIR=${STAGE1_APT_CACHE_DIR-<unset>}" >> "$CHROOT_ENV_LOG"
          mkdir -p "$buildenv/tmp"
          echo erofs > "$buildenv/tmp/$MODULE.erofs"
          printf 'fsverity_root=deadbeef\nsize=4096\n' > "$buildenv/tmp/$MODULE.erofs.meta"
          ;;
        *push.sh*)
          mkdir -p "$buildenv/tmp"
          printf 'erofs_ref=registry.invalid/powernode/%s:abc123\n' "$MODULE" > "$buildenv/tmp/module-forge-push-output.env"
          ;;
        *"oras manifest fetch"*)
          echo '{"digest":"sha256:deadbeef"}'
          ;;
      esac
      exit 0
    SH
  end

  # Matched on the bind's DESTINATION field only, never on the whole line: the
  # first version of this helper matched any line CONTAINING "apt-cache", and
  # the sandbox tmpdir was itself named "mf-apt-cache-test…", so every bind
  # matched and the first example passed vacuously against an unwired script.
  def cache_bind(mount_lines)
    mount_lines.find do |l|
      next false unless l.start_with?("--bind ")

      dst = l.split(/\s+/).last
      # The sandbox root no longer contains "cache" (see above), so the whole
      # DESTINATION path is a safe place to look — and it has to be, since the
      # in-chroot path's last segment need not carry the word.
      dst.include?("cache") && !dst.include?("/etc/")
    end
  end

  def build_cache_var(env_lines)
    line = env_lines.find { |l| l.start_with?("build STAGE1_APT_CACHE_DIR=") }
    line&.delete_prefix("build STAGE1_APT_CACHE_DIR=")
  end

  describe "by default" do
    it "bind-mounts a host cache directory into the buildenv" do
      status, mount_lines, _env_lines, _survivors, out = run_build

      expect(status).to be_success, "script failed:\n#{out}"
      expect(cache_bind(mount_lines)).not_to be_nil,
        "no apt-cache bind in mount log:\n#{mount_lines.join("\n")}"
    end

    it "exports STAGE1_APT_CACHE_DIR into the build chroot, naming the IN-CHROOT path" do
      status, mount_lines, env_lines, _survivors, out = run_build

      expect(status).to be_success, "script failed:\n#{out}"
      value = build_cache_var(env_lines)
      expect(value).not_to eq("<unset>"), "the build chroot never saw STAGE1_APT_CACHE_DIR"
      expect(value).not_to be_nil

      # It must be the path INSIDE the chroot, which is the bind's destination
      # with the buildenv prefix removed — not the host path, which resolves to
      # nothing once stage1 is running under chroot.
      bind_dst = cache_bind(mount_lines).split(/\s+/).last
      expect(bind_dst).to end_with(value)
      expect(value).to start_with("/")
      expect(value).not_to include("/jobs/")
    end

    # THE HALF THAT MAKES IT A CACHE. cleanup() rm -rf's $JOB_ROOT on every exit
    # path, so a cache under it would still satisfy both examples above and
    # still be empty on the next build.
    it "keeps the cache OUTSIDE the per-job scratch, so it survives cleanup" do
      status, _mount_lines, _env_lines, survivors, out = run_build

      expect(status).to be_success, "script failed:\n#{out}"

      # Asserted on WHAT SURVIVED the run, not on the shape of the path: the
      # sandbox's own job base is named "jobs", so a path-substring check for
      # "/jobs/" reads the harness's directory naming rather than the script's
      # placement. The behaviour is the oracle — the cache directory is still
      # there after cleanup() and the per-job scratch is not.
      expect(survivors).to include("apt-cache")
      expect(survivors.grep(%r{\Ajobs/[^/]+\z})).to be_empty,
        "the per-job scratch survived, so this example proves nothing about the cache: #{survivors.inspect}"
    end
  end

  describe "when an operator disables it with MODULE_FORGE_APT_CACHE_DIR=''" do
    it "mounts nothing and leaves the chroot without the variable" do
      status, mount_lines, env_lines, _survivors, out = run_build(cache_override: "")

      expect(status).to be_success, "script failed:\n#{out}"
      expect(cache_bind(mount_lines)).to be_nil,
        "opt-out still bind-mounted a cache:\n#{mount_lines.join("\n")}"
      expect(build_cache_var(env_lines)).to eq("<unset>")
    end
  end
end
