# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "shellwords"

# IMP-b2aebb9f4b17: a module build recorded NO core-tree provenance.
#
# `built_from_sha` is the MODULE-SOURCE sha (powernode-system) — deliberately
# so — which means a Class-B artifact assembled from a three-day-stale core
# mirror reported IDENTICALLY to a correct one at every downstream checkpoint:
# real oci_digest, real fsverity root, batch success, promotion proceeds. That
# is what shipped hub-backend v71 on 2026-08-15 and cost two outages; the only
# thing that eventually caught it was unpacking the layer and diffing a file by
# hand.
#
# stage15.sh clones the parent platform repo into /tmp/parent with a bare
# `--depth 1` (no ref), so the commit it lands on is knowable ONLY after the
# fact. These specs pin the three-hop channel that now carries it:
#
#   stage15.sh  -> /tmp/parent-provenance.env  (capture: sha + REMOTE)
#     -> push.sh                                (OCI annotations on the artifact)
#     -> module-forge-build.sh                  (result JSON, distinct field)
#
# Both the remote AND the sha are recorded: the v71 incident was a correct
# branch name on a STALE MIRROR (github.com and git.powernode.net both had a
# `develop`, three days apart), so a sha alone would have looked plausible.
#
# Verification shape: the module-forge-build.sh examples drive the REAL script
# end to end under stubbed heavy commands (the shape established by
# module_forge_build_head_sha_spec.rb). The stage15.sh/push.sh examples execute
# the REAL marker-delimited block text lifted from the shipped file, with the
# hardcoded /tmp paths redirected into a sandbox — those two scripts have no
# env seam for their scratch paths, and running them unredirected would write
# to the developer host's real /tmp. The path literals those examples cannot
# cover are asserted statically alongside.
RSpec.describe "module build core-source provenance" do
  ext_root = File.expand_path("../../..", __dir__)

  let(:forge_script) do
    File.join(ext_root, "modules/module-forge/rootfs/usr/local/bin/module-forge-build.sh")
  end
  let(:stage15_script) { File.join(ext_root, "scripts/module-build/stage15.sh") }
  let(:push_script)    { File.join(ext_root, "scripts/module-build/push.sh") }

  # Lifts the shipped text between `# --- BEGIN <name> ---` / `# --- END ... ---`
  # so these examples execute the real bytes rather than a restated copy. A
  # missing marker fails loudly instead of silently testing nothing.
  def extract_block(path, name)
    src = File.read(path)
    re = /^[ \t]*# --- BEGIN #{Regexp.escape(name)} ---[ \t]*$\n(.*?)^[ \t]*# --- END #{Regexp.escape(name)} ---[ \t]*$/m
    m = src.match(re)
    raise "no '#{name}' marker block found in #{path}" unless m

    m[1]
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
    path
  end

  # ---------------------------------------------------------------------------
  # stage15.sh — the capture itself
  # ---------------------------------------------------------------------------
  describe "stage15.sh core-source provenance capture" do
    # Runs the shipped capture block with /tmp/parent* redirected into `root`.
    # `parent:` selects what the (already-completed) clone left behind:
    #   :repo      — a real git repo, the success path
    #   :not_a_repo — a directory git cannot rev-parse
    #   :missing    — no clone at all
    # Returns [status, parsed_provenance_hash, combined_output].
    def run_capture(root, parent:)
      parent_dir = File.join(root, "parent")
      expected_sha =
        case parent
        when :repo
          FileUtils.mkdir_p(parent_dir)
          git = ->(*args) { system("git", "-C", parent_dir, *args, out: File::NULL, err: File::NULL) }
          git.call("init", "-q", "-b", "develop")
          git.call("config", "user.email", "spec@example.invalid")
          git.call("config", "user.name", "spec")
          File.write(File.join(parent_dir, "README"), "core\n")
          git.call("add", "-A")
          git.call("commit", "-q", "-m", "core commit")
          `git -C #{parent_dir} rev-parse HEAD`.strip
        when :not_a_repo
          FileUtils.mkdir_p(parent_dir)
          nil
        when :missing
          nil
        end

      block = extract_block(stage15_script, "core-source provenance capture")
                .gsub("/tmp/parent", File.join(root, "parent"))

      harness = <<~SH
        set -euo pipefail
        parent_host='github.com'
        parent_path='nodealchemy/powernode-platform'
        #{block}
      SH

      out = IO.popen({ "PATH" => "/usr/bin:/bin" }, ["bash", "-c", harness],
                     err: [:child, :out], unsetenv_others: true, &:read)
      status = $?

      prov_path = File.join(root, "parent-provenance.env")
      parsed =
        if File.exist?(prov_path)
          File.read(prov_path).lines.each_with_object({}) do |line, h|
            k, v = line.chomp.split("=", 2)
            h[k] = v if k
          end
        end
      [status, parsed, out, expected_sha]
    end

    it "records the commit the parent clone actually landed on" do
      Dir.mktmpdir("stage15-prov") do |root|
        status, prov, out, expected_sha = run_capture(root, parent: :repo)

        expect(status).to be_success, "capture block failed:\n#{out}"
        expect(prov).not_to be_nil, "no provenance file written:\n#{out}"
        expect(prov["core_source_sha"]).to eq(expected_sha)
        expect(prov["core_source_sha"]).to match(/\A[0-9a-f]{40}\z/)
      end
    end

    it "records the remote HOST and PATH, so a stale mirror is distinguishable from a stale sha" do
      Dir.mktmpdir("stage15-prov") do |root|
        _status, prov, out, _sha = run_capture(root, parent: :repo)

        expect(prov).not_to be_nil, out
        expect(prov["core_source_remote"]).to eq("github.com/nodealchemy/powernode-platform")
      end
    end

    # The task's hard constraint: "an absent field must never be
    # indistinguishable from a successful one". A rev-parse failure records
    # `unknown` — it does not abort the build, and it does not omit the key.
    it "records `unknown` (never absent, never empty) when the parent is not a git repo" do
      Dir.mktmpdir("stage15-prov") do |root|
        status, prov, out, _sha = run_capture(root, parent: :not_a_repo)

        expect(status).to be_success, "a rev-parse failure must not abort the build:\n#{out}"
        expect(prov).not_to be_nil, "the key must be written even on failure:\n#{out}"
        expect(prov["core_source_sha"]).to eq("unknown")
        expect(prov["core_source_remote"]).to eq("github.com/nodealchemy/powernode-platform")
      end
    end

    it "records `unknown` when the clone left nothing behind at all" do
      Dir.mktmpdir("stage15-prov") do |root|
        status, prov, out, _sha = run_capture(root, parent: :missing)

        expect(status).to be_success, "a missing parent must not abort the build:\n#{out}"
        expect(prov).not_to be_nil, out
        expect(prov["core_source_sha"]).to eq("unknown")
      end
    end

    # CREDENTIAL SAFETY (crypto-material-safety rule): the recorded remote must
    # be built from $parent_host/$parent_path, NEVER from $clone_url, which for
    # a private host embeds PARENT_PAT in its userinfo. This value flows into a
    # result JSON and an OCI annotation on a published artifact — a token here
    # would be a permanent cleartext leak. Static, because the executed examples
    # above cannot prove the ABSENCE of a reference.
    it "never reads the credentialed clone_url or PARENT_PAT into the recorded remote" do
      block = extract_block(stage15_script, "core-source provenance capture")
      # Assert on CODE only. The block's comments deliberately NAME clone_url and
      # PARENT_PAT to explain why they are excluded; matching those would pass
      # the example for the wrong reason and fail it for a good one.
      code = block.lines.reject { |l| l =~ /\A\s*#/ }.join

      expect(code).not_to match(/\$\{?clone_url\b/),
                          "clone_url embeds PARENT_PAT for a private host — never record it"
      expect(code).not_to match(/\$\{?PARENT_PAT\b/)
      expect(code).to include('${parent_host}/${parent_path}')
      # The comments must still carry the reason — this is a footgun for the
      # next person editing the block.
      expect(block).to match(/PARENT_PAT/)
    end

    # The literal paths the sandboxed run substitutes away.
    it "writes the provenance file at the path push.sh and module-forge-build.sh read" do
      src = File.read(stage15_script)

      expect(src).to include("/tmp/parent-provenance.env")
      expect(extract_block(stage15_script, "core-source provenance capture"))
        .to include("/tmp/parent-provenance.env")
    end

    # A CI runner reuses /tmp across jobs. Without an unconditional clear, a
    # provenance file left by a PREVIOUS Class-B build would make a later
    # non-parent module claim a core sha it never cloned — the same class of
    # silently-wrong provenance this task exists to remove.
    it "clears a stale provenance file before the needs_parent branch" do
      src = File.read(stage15_script)
      clear_at  = src.index("rm -f /tmp/parent-provenance.env")
      branch_at = src.index('if [ "$needs_parent" = "1" ]')

      expect(clear_at).not_to be_nil, "no unconditional stale-provenance clear in stage15.sh"
      expect(branch_at).not_to be_nil
      expect(clear_at).to be < branch_at,
                          "the clear must run for EVERY module, not only inside the parent branch"
    end
  end

  # ---------------------------------------------------------------------------
  # push.sh — stamp it on the artifact, where it is readable without a shell
  # ---------------------------------------------------------------------------
  describe "push.sh core-source provenance annotations" do
    # Executes the shipped annotation block against a sandboxed provenance file
    # and returns the resulting ORAS_PUSH_ARGS entries.
    def run_annotations(root, provenance:)
      prov_path = File.join(root, "parent-provenance.env")
      File.write(prov_path, provenance) if provenance

      block = extract_block(push_script, "core-source provenance annotations")
                .gsub("/tmp/parent-provenance.env", prov_path)

      harness = <<~SH
        set -euo pipefail
        ORAS_PUSH_ARGS=()
        #{block}
        for a in "${ORAS_PUSH_ARGS[@]+"${ORAS_PUSH_ARGS[@]}"}"; do printf '%s\\n' "$a"; done
      SH

      out = IO.popen({ "PATH" => "/usr/bin:/bin" }, ["bash", "-c", harness],
                     err: [:child, :out], unsetenv_others: true, &:read)
      [$?, out.lines.map(&:chomp)]
    end

    it "stamps the core sha and remote as OCI annotations on the pushed artifact" do
      Dir.mktmpdir("push-prov") do |root|
        status, args = run_annotations(
          root,
          provenance: "core_source_sha=abc123def4567890abc123def4567890abc123de\n" \
                      "core_source_remote=github.com/nodealchemy/powernode-platform\n"
        )

        expect(status).to be_success, args.join("\n")
        expect(args).to include(
          "org.powernode.core_source_sha=abc123def4567890abc123def4567890abc123de"
        )
        expect(args).to include(
          "org.powernode.core_source_remote=github.com/nodealchemy/powernode-platform"
        )
      end
    end

    # A module with no parent clone (not Class-B) has no core content at all —
    # an ABSENT annotation is the correct, distinct answer there. It must not
    # be confused with `unknown`, which means "it has core content and we could
    # not attribute it".
    it "adds no core annotations when the module cloned no parent" do
      Dir.mktmpdir("push-prov") do |root|
        status, args = run_annotations(root, provenance: nil)

        expect(status).to be_success, args.join("\n")
        expect(args.grep(/core_source/)).to be_empty
      end
    end

    it "still stamps the remote when the sha could not be resolved" do
      Dir.mktmpdir("push-prov") do |root|
        _status, args = run_annotations(
          root,
          provenance: "core_source_sha=unknown\ncore_source_remote=git.powernode.org/x/y\n"
        )

        expect(args).to include("org.powernode.core_source_sha=unknown")
        expect(args).to include("org.powernode.core_source_remote=git.powernode.org/x/y")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # module-forge-build.sh — the RESULT JSON contract (real script, end to end)
  # ---------------------------------------------------------------------------
  describe "module-forge-build.sh result JSON" do
    # Drives the REAL script under stubbed git/rsync/mount/umount/chroot. The
    # chroot stub fabricates exactly what each in-chroot step's success is
    # checked on, plus — when `provenance:` is given — the parent-provenance
    # file stage15.sh would have written inside the chroot.
    def run_build(provenance: nil)
      Dir.mktmpdir("mf-prov") do |root|
        stubs   = File.join(root, "stubs")
        baked   = File.join(root, "baked-scripts")
        golden  = File.join(root, "golden-buildenv")
        jobroot = File.join(root, "jobs")
        [stubs, baked, golden, jobroot].each { |d| FileUtils.mkdir_p(d) }

        %w[build-one-module.sh push.sh].each do |f|
          write_stub(baked, f, "#!/bin/sh\nexit 0\n")
        end

        write_stub(stubs, "git", <<~SH)
          #!/bin/sh
          if [ "$1" = "clone" ]; then
            dest=""
            for a in "$@"; do dest="$a"; done
            mkdir -p "$dest/modules/$MODULE"
            printf 'build:\\n  apt_snapshot: "x"\\n' > "$dest/modules/$MODULE/manifest.yaml"
          fi
          exit 0
        SH
        write_stub(stubs, "rsync",  "#!/bin/sh\nexit 0\n")
        write_stub(stubs, "mount",  "#!/bin/sh\nexit 0\n")
        write_stub(stubs, "umount", "#!/bin/sh\nexit 0\n")

        prov_block =
          if provenance
            "printf '%s' #{Shellwords.escape(provenance)} > \"$buildenv/tmp/parent-provenance.env\""
          else
            "true"
          end

        write_stub(stubs, "chroot", <<~SH)
          #!/bin/sh
          buildenv="$1"
          cmd="$*"
          case "$cmd" in
            *build-one-module.sh*)
              mkdir -p "$buildenv/tmp"
              echo erofs > "$buildenv/tmp/$MODULE.erofs"
              printf 'fsverity_root=deadbeef\\nsize=4096\\n' > "$buildenv/tmp/$MODULE.erofs.meta"
              #{prov_block}
              ;;
            *push.sh*)
              mkdir -p "$buildenv/tmp"
              printf 'erofs_ref=registry.invalid/powernode/%s:abc123\\n' "$MODULE" \\
                > "$buildenv/tmp/module-forge-push-output.env"
              ;;
            *"oras manifest fetch"*)
              echo '{"digest":"sha256:deadbeef"}'
              ;;
          esac
          exit 0
        SH

        env = {
          "PATH"                         => "#{stubs}:/usr/bin:/bin",
          "MODULE_FORGE_BUILD_SCRIPTS"   => baked,
          "MODULE_FORGE_BUILDENV_GOLDEN" => golden,
          "MODULE_FORGE_JOB_ROOT"        => jobroot,
          "MODULE"                       => "powernode-hub-backend",
          "BUILD_SHA"                    => "modulesourcesha0000000000000000000000000",
          "MODULE_SOURCE_URL"            => "https://example.invalid/powernode/powernode-system.git",
          "ORAS_REGISTRY_USER"           => "ci",
          "ORAS_REGISTRY_PASSWORD"       => "stub-not-a-real-credential",
          "OCI_REF"                      => "abc123",
          "ORAS_REGISTRY"                => "registry.invalid"
        }

        out = IO.popen(env, ["bash", forge_script],
                       err: [:child, :out], unsetenv_others: true, &:read)
        status = $?
        json_line = out.lines.map(&:strip).reject(&:empty?).last
        parsed = (JSON.parse(json_line) rescue nil)
        [status, parsed, out]
      end
    end

    it "emits the core sha as a field DISTINCT from built_from_sha" do
      status, result, out = run_build(
        provenance: "core_source_sha=fedcba9876543210fedcba9876543210fedcba98\n" \
                    "core_source_remote=github.com/nodealchemy/powernode-platform\n"
      )

      expect(status).to be_success, "script failed:\n#{out}"
      expect(result).not_to be_nil, "no parseable result JSON on stdout:\n#{out}"

      expect(result["core_source_sha"]).to eq("fedcba9876543210fedcba9876543210fedcba98")
      expect(result["core_source_remote"]).to eq("github.com/nodealchemy/powernode-platform")

      # The whole point of the finding: these two must not be the same value,
      # and built_from_sha must keep meaning the MODULE-SOURCE commit.
      expect(result["built_from_sha"]).to eq("modulesourcesha0000000000000000000000000")
      expect(result["core_source_sha"]).not_to eq(result["built_from_sha"])
    end

    it "keeps the pre-existing four contract keys intact" do
      status, result, out = run_build(
        provenance: "core_source_sha=aa\ncore_source_remote=h/p\n"
      )

      expect(status).to be_success, out
      expect(result).to include(
        "oci_digest"     => "sha256:deadbeef",
        "fsverity_root"  => "deadbeef",
        "size"           => 4096,
        "built_from_sha" => "modulesourcesha0000000000000000000000000"
      )
    end

    # An absent field must never be indistinguishable from a successful one:
    # a module that cloned no parent reports `not_applicable`, which is a
    # different answer from both a real sha and from `unknown`.
    it "reports not_applicable — not an empty or missing key — when no parent was cloned" do
      status, result, out = run_build(provenance: nil)

      expect(status).to be_success, "a missing provenance file must not fail the build:\n#{out}"
      expect(result).not_to be_nil, out
      expect(result).to have_key("core_source_sha")
      expect(result["core_source_sha"]).to eq("not_applicable")
      expect(result["core_source_remote"]).to eq("not_applicable")
    end

    it "propagates stage15's `unknown` rather than masking it as not_applicable" do
      status, result, out = run_build(
        provenance: "core_source_sha=unknown\ncore_source_remote=github.com/nodealchemy/powernode-platform\n"
      )

      expect(status).to be_success, out
      expect(result["core_source_sha"]).to eq("unknown")
      expect(result["core_source_remote"]).to eq("github.com/nodealchemy/powernode-platform")
    end
  end
end
