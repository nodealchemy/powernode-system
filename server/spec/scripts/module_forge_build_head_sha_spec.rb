# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# inc29 fix (improvement 019f6ef4-da9e): native builds must run the build
# scripts checked out at BUILD_SHA, not the ones baked into the module-forge
# image. module-forge-build.sh clones MODULE_SOURCE_URL@BUILD_SHA into its
# workspace (which therefore contains scripts/module-build/ at the requested
# commit) but historically bind-mounted the BAKED /opt/module-build into the
# chroot, so build-one-module.sh + the whole stage chain reflected whatever
# commit the forge was last built from — silent-wrong artifacts.
#
# This drives the REAL script under stubbed heavy commands (git/rsync/mount/
# chroot/umount) and asserts which scripts directory it bind-mounts at
# /opt/module-build inside the chroot — head_sha workspace when present, baked
# only as a fallback.
RSpec.describe "module-forge-build.sh head_sha build-script selection" do
  let(:script) do
    File.expand_path(
      "../../../modules/module-forge/rootfs/usr/local/bin/module-forge-build.sh", __dir__
    )
  end

  # Runs the script in a hermetic sandbox. `workspace_has_scripts:` controls
  # whether the (stubbed) git clone materializes scripts/module-build/ at
  # BUILD_SHA. Returns [status, mount_log_lines, combined_output].
  def run_build(workspace_has_scripts:)
    Dir.mktmpdir("mf-build-test") do |root|
      stubs   = File.join(root, "stubs")
      baked   = File.join(root, "baked-scripts")   # MODULE_FORGE_BUILD_SCRIPTS
      golden  = File.join(root, "golden-buildenv")  # MODULE_FORGE_BUILDENV_GOLDEN
      jobroot = File.join(root, "jobs")             # MODULE_FORGE_JOB_ROOT
      mount_log = File.join(root, "mount.log")
      [ stubs, baked, golden, jobroot ].each { |d| FileUtils.mkdir_p(d) }

      # Baked scripts (preflight requires build-one-module.sh + push.sh present
      # and executable). Distinct marker dir so we can tell it apart from the
      # workspace copy in the assertion.
      %w[build-one-module.sh push.sh].each do |f|
        path = File.join(baked, f)
        File.write(path, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, path)
      end

      write_stub(stubs, "git", git_stub(workspace_has_scripts))
      write_stub(stubs, "rsync", "#!/bin/sh\nexit 0\n")
      write_stub(stubs, "mount", "#!/bin/sh\necho \"$@\" >> \"$MOUNT_LOG\"\nexit 0\n")
      write_stub(stubs, "umount", "#!/bin/sh\nexit 0\n")
      write_stub(stubs, "chroot", chroot_stub)

      env = {
        "PATH"                        => "#{stubs}:/usr/bin:/bin",
        "MOUNT_LOG"                   => mount_log,
        "MODULE_FORGE_BUILD_SCRIPTS"  => baked,
        "MODULE_FORGE_BUILDENV_GOLDEN" => golden,
        "MODULE_FORGE_JOB_ROOT"       => jobroot,
        "MODULE"                      => "reverse-proxy-traefik",
        "BUILD_SHA"                   => "abc123def456",
        "MODULE_SOURCE_URL"           => "https://example.invalid/powernode/powernode-system.git",
        "ORAS_REGISTRY_USER"          => "ci",
        "ORAS_REGISTRY_PASSWORD"      => "secret", # test-only stub value, never a real credential
        "OCI_REF"                     => "abc123",
        "ORAS_REGISTRY"               => "registry.invalid"
      }

      out = IO.popen(env, [ "bash", script ], err: [ :child, :out ], unsetenv_others: true, &:read)
      status = $?
      lines = File.exist?(mount_log) ? File.read(mount_log).lines.map(&:strip) : []
      [ status, lines, out ]
    end
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  # git clone <url> <dest> materializes the checked-out tree; checkout/fetch are
  # no-ops. `with_scripts` toggles whether scripts/module-build/ exists at
  # BUILD_SHA in the clone.
  def git_stub(with_scripts)
    scripts_block =
      if with_scripts
        <<~SH
          mkdir -p "$dest/scripts/module-build"
          for f in build-one-module.sh push.sh stage15.sh stage1-rootfs.sh stage2-carve.sh; do
            printf '#!/bin/sh\\nexit 0\\n' > "$dest/scripts/module-build/$f"
            chmod 0755 "$dest/scripts/module-build/$f"
          done
        SH
      else
        "true\n"
      end
    <<~SH
      #!/bin/sh
      if [ "$1" = "clone" ]; then
        dest=""
        for a in "$@"; do dest="$a"; done
        mkdir -p "$dest/modules/$MODULE"
        printf 'build:\\n  apt_snapshot: "x"\\n' > "$dest/modules/$MODULE/manifest.yaml"
        #{scripts_block}
      fi
      exit 0
    SH
  end

  # chroot <buildenv> /bin/bash -c "<cmd>" — fabricate the artifacts each
  # in-chroot step's success is checked on. $BUILDENV is $1; $MODULE from env.
  def chroot_stub
    <<~'SH'
      #!/bin/sh
      buildenv="$1"
      cmd="$*"
      case "$cmd" in
        *build-one-module.sh*)
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

  # The chroot target the scripts dir is bind-mounted at. bind_mount emits
  # `mount --bind <src> <dst>`; find the line whose dst ends /opt/module-build.
  def bound_scripts_src(mount_lines)
    line = mount_lines.find { |l| l.start_with?("--bind ") && l.end_with?("/opt/module-build") }
    return nil unless line

    line.split(/\s+/)[1]
  end

  it "bind-mounts the scripts checked out at BUILD_SHA when the workspace has them" do
    status, mount_lines, out = run_build(workspace_has_scripts: true)

    expect(status).to be_success, "script failed:\n#{out}"
    src = bound_scripts_src(mount_lines)
    expect(src).not_to be_nil, "no /opt/module-build bind in mount log:\n#{mount_lines.join("\n")}"
    # head_sha scripts live under the cloned workspace, NOT the baked dir.
    expect(src).to end_with("/workspace/scripts/module-build")
  end

  it "falls back to the baked scripts when the checkout lacks scripts/module-build" do
    status, mount_lines, out = run_build(workspace_has_scripts: false)

    expect(status).to be_success, "script failed:\n#{out}"
    src = bound_scripts_src(mount_lines)
    expect(src).not_to be_nil, "no /opt/module-build bind in mount log:\n#{mount_lines.join("\n")}"
    expect(src).to end_with("/baked-scripts")
  end
end
