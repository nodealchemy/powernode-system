# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "shellwords"
require "yaml"

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
        when :empty_repo
          # `git clone --depth 1` of an EMPTY remote exits 0 (only a warning),
          # leaving a real repo with an UNBORN HEAD.
          FileUtils.mkdir_p(parent_dir)
          system("git", "init", "-q", "-b", "develop", parent_dir, out: File::NULL, err: File::NULL)
          nil
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

      out = IO.popen({ "PATH" => "/usr/bin:/bin" }, [ "bash", "-c", harness ],
                     err: [ :child, :out ], unsetenv_others: true, &:read)
      status = $?

      prov_path = File.join(root, "parent-provenance.env")
      parsed =
        if File.exist?(prov_path)
          File.read(prov_path).lines.each_with_object({}) do |line, h|
            k, v = line.chomp.split("=", 2)
            h[k] = v if k
          end
        end
      [ status, parsed, out, expected_sha ]
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

    # `git rev-parse HEAD` on an UNBORN head prints the literal string "HEAD" to
    # STDOUT and exits 128 — so a bare rev-parse records `core_source_sha=HEAD`,
    # a fourth state that is neither a sha nor `unknown` and reads like an
    # answer. It is reachable: cloning an empty/freshly-created parent mirror
    # exits 0, and the powernode-extension-system arm tolerates a parent with no
    # frontend/package.json (stage15.sh logs and continues), so that module would
    # build green and stamp `HEAD` permanently onto the published artifact.
    # `rev-parse --verify` prints nothing on failure, which is what the `unknown`
    # fallback needs.
    it "records `unknown`, never the literal string HEAD, for a parent with an unborn HEAD" do
      Dir.mktmpdir("stage15-prov") do |root|
        status, prov, out, _sha = run_capture(root, parent: :empty_repo)

        expect(status).to be_success, out
        expect(prov).not_to be_nil, out
        expect(prov["core_source_sha"]).not_to eq("HEAD")
        expect(prov["core_source_sha"]).to eq("unknown")
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

    # The literal paths the sandboxed runs substitute away. Asserted on ALL
    # THREE files: the writer and both readers must agree on the same path, and
    # the sandboxing gsub in the examples above cannot prove that agreement.
    it "writes the provenance file at the exact path push.sh and module-forge-build.sh read" do
      expect(extract_block(stage15_script, "core-source provenance capture"))
        .to include("/tmp/parent-provenance.env")
      expect(File.read(push_script)).to include("/tmp/parent-provenance.env")
      # The forge reads it from OUTSIDE the chroot, so its path is $BUILDENV-relative.
      expect(File.read(forge_script)).to include('$BUILDENV/tmp/parent-provenance.env')
    end

    # A CI runner reuses /tmp across jobs. Without an unconditional clear, a
    # provenance file left by a PREVIOUS Class-B build would make a later
    # non-parent module claim a core sha it never cloned — the same class of
    # silently-wrong provenance this task exists to remove.
    #
    # EXECUTED, not grepped: an `src.index("rm -f …")` assertion passes just as
    # happily when the line is commented out, or deleted with the string left
    # behind in any comment — which is exactly the reuse hazard going unguarded.
    it "actually deletes a stale provenance file left by a previous job" do
      Dir.mktmpdir("stage15-clear") do |root|
        stale = File.join(root, "parent-provenance.env")
        File.write(stale, "core_source_sha=stalefromapreviousjob\n")

        block = extract_block(stage15_script, "stale-provenance clear")
                  .gsub("/tmp/parent", File.join(root, "parent"))
        out = IO.popen({ "PATH" => "/usr/bin:/bin" },
                       [ "bash", "-c", "set -euo pipefail\n#{block}" ],
                       err: [ :child, :out ], unsetenv_others: true, &:read)

        expect($?).to be_success, out
        expect(File).not_to exist(stale),
                            "a previous job's provenance file survived into this build"
      end
    end

    # …and it must run for EVERY module, not only inside the parent branch —
    # otherwise the module that inherits the stale sha (one that clones no
    # parent) is precisely the one that never clears it.
    it "clears before the needs_parent branch, so non-parent modules are covered too" do
      src = File.read(stage15_script)
      clear_at  = src.index(extract_block(stage15_script, "stale-provenance clear").strip.lines.last.strip)
      branch_at = src.index('if [ "$needs_parent" = "1" ]')

      expect(clear_at).not_to be_nil
      expect(branch_at).not_to be_nil
      expect(clear_at).to be < branch_at
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

      out = IO.popen({ "PATH" => "/usr/bin:/bin" }, [ "bash", "-c", harness ],
                     err: [ :child, :out ], unsetenv_others: true, &:read)
      [ $?, out.lines.map(&:chomp) ]
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

    # The two per-key guards need a fixture the file-exists guard LETS THROUGH,
    # or they are unpinned no matter how many of the examples above pass (both
    # guards otherwise reject exactly the same fixtures). A provenance file that
    # exists but is missing a key is what a build killed mid-write leaves behind;
    # an empty `--annotation org.powernode.core_source_sha=` on a published
    # artifact is worse than no annotation, because it reads as an answer.
    it "omits only the missing key when the provenance file is truncated" do
      Dir.mktmpdir("push-prov") do |root|
        status, args = run_annotations(root, provenance: "core_source_remote=github.com/o/r\n")

        expect(status).to be_success, args.join("\n")
        expect(args).to include("org.powernode.core_source_remote=github.com/o/r")
        expect(args.grep(/core_source_sha/)).to be_empty
      end
    end

    it "omits only the remote when the remote line is missing" do
      Dir.mktmpdir("push-prov") do |root|
        status, args = run_annotations(root, provenance: "core_source_sha=deadbeef\n")

        expect(status).to be_success, args.join("\n")
        expect(args).to include("org.powernode.core_source_sha=deadbeef")
        expect(args.grep(/core_source_remote/)).to be_empty
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Gitea CI path — the ONE path that reaches NodeModuleVersion.artifacts today
  # ---------------------------------------------------------------------------
  #
  # The native path's result JSON dead-ends at the agent's moduleBuildResult
  # struct, which does not decode the two core_* keys (encoding/json drops
  # unknown fields silently) — closing that needs an AGENT rebuild. The CI
  # workflow instead POSTs its own artifacts payload straight to
  # /api/v1/system/module_publications, whose controller does
  # `params[:artifacts].to_unsafe_h` with NO strong-params filtering and writes
  # it to the JSONB column verbatim (module_publications_controller.rb:62-63,
  # :141) — so a key added here genuinely lands in what
  # system_list_module_versions returns.
  describe "Gitea workflow notify-platform payload" do
    let(:workflow) { File.join(ext_root, ".gitea/workflows/build-platform-modules.yaml") }

    it "is still valid YAML after the payload edit" do
      expect { YAML.load_file(workflow, aliases: true) }.not_to raise_error
    end

    # Executes the shipped provenance read + the real jq payload assembly. A jq
    # syntax error here would break EVERY CI module build, and would otherwise
    # only be discovered on the next dispatch.
    def run_payload(root, provenance:)
      prov = File.join(root, "parent-provenance.env")
      File.write(prov, provenance) if provenance

      src = File.read(workflow)
      read_block = extract_block(workflow, "ci core-source provenance read")
      payload_block = src[/^\s*payload=\$\(jq -nc \\.*?\n\s*\}'\)$/m]
      raise "could not locate the payload jq assembly in #{workflow}" unless payload_block

      # The step is a YAML literal block: strip its indentation, and neutralise
      # the Gitea Actions `${{ … }}` expressions, which are substituted at
      # workflow-render time and are not shell syntax.
      body = "#{read_block}\n#{payload_block}"
              .gsub(/\$\{\{[^}]*\}\}/, "actions-expr")
              .gsub("/tmp/parent-provenance.env", prov)
      body = body.lines.map { |l| l.sub(/\A {10}/, "") }.join

      harness = <<~SH
        set -euo pipefail
        MODULE=powernode-hub-backend
        EROFS_ROOT=deadbeef
        EROFS_SIZE=4096
        MANIFEST_B64=bWFuaWZlc3Q=
        PACKAGES_COUNT=12
        PACKAGES_SHA256=abc123
        GITHUB_SHA=modulesourcesha000000000000000000000000
        #{body}
        printf '%s\\n' "$payload"
      SH

      out = IO.popen({ "PATH" => "/usr/bin:/bin" }, [ "bash", "-c", harness ],
                     err: [ :child, :out ], unsetenv_others: true, &:read)
      [ $?, out, (JSON.parse(out.lines.map(&:strip).reject(&:empty?).last) rescue nil) ]
    end

    it "carries the core sha and remote into artifacts.erofs, distinct from built_from_sha" do
      Dir.mktmpdir("ci-payload") do |root|
        status, out, payload = run_payload(
          root,
          provenance: "core_source_sha=fedcba9876543210fedcba9876543210fedcba98\n" \
                      "core_source_remote=github.com/nodealchemy/powernode-platform\n"
        )

        expect(status).to be_success, out
        expect(payload).not_to be_nil, "payload jq produced no parseable JSON:\n#{out}"

        erofs = payload.dig("artifacts", "erofs")
        expect(erofs["core_source_sha"]).to eq("fedcba9876543210fedcba9876543210fedcba98")
        expect(erofs["core_source_remote"]).to eq("github.com/nodealchemy/powernode-platform")
        expect(erofs["built_from_sha"]).to eq("modulesourcesha000000000000000000000000")
        expect(erofs["core_source_sha"]).not_to eq(erofs["built_from_sha"])
      end
    end

    it "keeps the pre-existing payload keys intact" do
      Dir.mktmpdir("ci-payload") do |root|
        _status, out, payload = run_payload(root, provenance: "core_source_sha=a\ncore_source_remote=b\n")

        expect(payload).not_to be_nil, out
        expect(payload["module_name"]).to eq("powernode-hub-backend")
        expect(payload.dig("artifacts", "erofs", "fsverity_root")).to eq("deadbeef")
        expect(payload.dig("artifacts", "erofs", "size")).to eq(4096)
        expect(payload.dig("artifacts", "packages", "count")).to eq(12)
      end
    end

    it "reports not_applicable for a module that cloned no parent" do
      Dir.mktmpdir("ci-payload") do |root|
        status, out, payload = run_payload(root, provenance: nil)

        expect(status).to be_success, out
        expect(payload.dig("artifacts", "erofs", "core_source_sha")).to eq("not_applicable")
        expect(payload.dig("artifacts", "erofs", "core_source_remote")).to eq("not_applicable")
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
        [ stubs, baked, golden, jobroot ].each { |d| FileUtils.mkdir_p(d) }

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

        out = IO.popen(env, [ "bash", forge_script ],
                       err: [ :child, :out ], unsetenv_others: true, &:read)
        status = $?
        json_line = out.lines.map(&:strip).reject(&:empty?).last
        parsed = (JSON.parse(json_line) rescue nil)
        [ status, parsed, out ]
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

    # not_applicable means "this module clones no parent" and must be reachable
    # ONLY from the file-absent branch. Deciding it per KEY lets a present file
    # with one key missing report `core_source_sha=not_applicable` alongside a
    # named `core_source_remote` — a self-contradictory record, and one a
    # consumer keying on the sha alone reads as "not Class-B". The reachable
    # cause is key drift: rename the key in stage15.sh and every Class-B build
    # silently reports not_applicable forever, with nothing failing anywhere.
    it "reports `unknown`, not `not_applicable`, when the file is present but the sha key is missing" do
      status, result, out = run_build(provenance: "core_source_remote=github.com/o/r\n")

      expect(status).to be_success, out
      expect(result["core_source_sha"]).to eq("unknown")
      expect(result["core_source_remote"]).to eq("github.com/o/r")
    end

    it "reports `unknown` for the remote when only the sha key is present" do
      status, result, out = run_build(provenance: "core_source_sha=deadbeefcafe\n")

      expect(status).to be_success, out
      expect(result["core_source_sha"]).to eq("deadbeefcafe")
      expect(result["core_source_remote"]).to eq("unknown")
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
