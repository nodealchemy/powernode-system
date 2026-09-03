# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

# IMP-e2c2da99b4b5: the platform module pipeline computed an fs-verity root
# and then published artifacts that did not carry it.
#
# stage2-carve.sh writes `fsverity_root=sha256:...` into /tmp/$MODULE.erofs.meta
# and push.sh pushes that sidecar as a LAYER — but the only place the ingest
# side reads the root from is the OCI MANIFEST annotation
# `io.powernode.fsverity_root_hash` (ModuleOciIngestService::OrasOciAdapter
# #fetch_manifest / #fetch_manifest_single_arch). push.sh never stamped it, so
# every module ingested through `ingest!` (the Gitea-webhook / worker_api
# processor path) landed with ModuleArtifact.fsverity_root_hash = nil and
# NodeModuleVersion.fsverity_root_hash = nil — and the agent's fs-verity gate
# (agent/internal/runtime/reconcile.go mountModuleArtifact) fails CLOSED on an
# empty root, so enabling it would have refused exactly those mounts.
#
# These examples execute the REAL marker-delimited block lifted from push.sh
# (the shape established by module_build_core_provenance_spec.rb), with the
# hardcoded /tmp sidecar path redirected into a sandbox.
RSpec.describe "push.sh fs-verity root annotation" do
  ext_root = File.expand_path("../../..", __dir__)

  let(:push_script)    { File.join(ext_root, "scripts/module-build/push.sh") }
  let(:ingest_service) { File.join(ext_root, "server/app/services/system/module_oci_ingest_service.rb") }

  # The exact key the ingest adapter parses off the manifest. Read from the
  # ingest source rather than restated here, so a rename on either side
  # fails this spec instead of silently severing the channel.
  let(:annotation_key) do
    keys = File.read(ingest_service).scan(/dig\("annotations",\s*"(io\.powernode\.fsverity_root_hash)"\)/).flatten.uniq
    expect(keys).to eq([ "io.powernode.fsverity_root_hash" ]), "ingest service no longer reads the fs-verity annotation"
    keys.first
  end

  def extract_block(path, name)
    src = File.read(path)
    re = /^[ \t]*# --- BEGIN #{Regexp.escape(name)} ---[ \t]*$\n(.*?)^[ \t]*# --- END #{Regexp.escape(name)} ---[ \t]*$/m
    m = src.match(re)
    raise "no '#{name}' marker block found in #{path}" unless m

    m[1]
  end

  # Executes the shipped annotation block against a sandboxed .erofs.meta and
  # returns [status, ORAS_PUSH_ARGS entries, stderr lines].
  def run_annotation(root, meta:)
    meta_path = File.join(root, "testmod.erofs.meta")
    File.write(meta_path, meta) if meta

    block = extract_block(push_script, "fsverity root annotation")
              .gsub("/tmp/$MODULE.erofs.meta", File.join(root, "$MODULE.erofs.meta"))

    harness = <<~SH
      set -euo pipefail
      MODULE=testmod
      ORAS_PUSH_ARGS=()
      #{block}
      for a in "${ORAS_PUSH_ARGS[@]+"${ORAS_PUSH_ARGS[@]}"}"; do printf '%s\\n' "$a"; done
    SH

    err_r, err_w = IO.pipe
    out = IO.popen({ "PATH" => "/usr/bin:/bin" }, [ "bash", "-c", harness ],
                   err: err_w, unsetenv_others: true, &:read)
    status = $?
    err_w.close
    stderr = err_r.read
    err_r.close
    [ status, out.lines.map(&:chomp), stderr.lines.map(&:chomp) ]
  end

  let(:root_hash) { "sha256:#{'a1' * 32}" }

  it "stamps the fs-verity root from the .erofs.meta sidecar as the annotation ingest reads" do
    Dir.mktmpdir("push-fsv") do |root|
      status, args, stderr = run_annotation(root, meta: "fsverity_root=#{root_hash}\nsize=6066176\n")

      expect(status).to be_success, (args + stderr).join("\n")
      expect(args).to include("--annotation")
      expect(args).to include("#{annotation_key}=#{root_hash}")
    end
  end

  it "reads only the fsverity_root line, never the sibling size line" do
    Dir.mktmpdir("push-fsv") do |root|
      _status, args, _stderr = run_annotation(root, meta: "size=6066176\nfsverity_root=#{root_hash}\n")

      expect(args.grep(/fsverity_root_hash=/)).to eq([ "#{annotation_key}=#{root_hash}" ])
    end
  end

  # An empty `--annotation io.powernode.fsverity_root_hash=` on a published
  # artifact is worse than no annotation: it reads as an answer, and the
  # agent would compare against "". Omit, and say so loudly.
  it "omits the annotation and warns when the sidecar carries an empty root" do
    Dir.mktmpdir("push-fsv") do |root|
      status, args, stderr = run_annotation(root, meta: "fsverity_root=\nsize=6066176\n")

      expect(status).to be_success, (args + stderr).join("\n")
      expect(args.grep(/fsverity_root_hash/)).to be_empty
      expect(stderr.join("\n")).to match(/fsverity_root/i)
      expect(stderr.join("\n")).to match(/WARNING|warn/i)
    end
  end

  it "omits the annotation and warns when the sidecar is missing entirely" do
    Dir.mktmpdir("push-fsv") do |root|
      status, args, stderr = run_annotation(root, meta: nil)

      expect(status).to be_success, (args + stderr).join("\n")
      expect(args.grep(/fsverity_root_hash/)).to be_empty
      expect(stderr.join("\n")).to match(/fsverity_root/i)
    end
  end

  # The block must sit where ORAS_PUSH_ARGS is still being assembled — after
  # the array is declared and before `oras push` consumes it. Asserted
  # statically because the harness above cannot see the surrounding script.
  it "is stamped before oras push consumes ORAS_PUSH_ARGS" do
    src = File.read(push_script)
    declared = src.index("ORAS_PUSH_ARGS=(")
    begin_at = src.index("# --- BEGIN fsverity root annotation ---")
    pushed   = src.index('oras push "${ORAS_PUSH_ARGS[@]}"')

    expect(declared).not_to be_nil
    expect(begin_at).not_to be_nil, "no fsverity root annotation block in push.sh"
    expect(pushed).not_to be_nil
    expect(declared).to be < begin_at
    expect(begin_at).to be < pushed
  end
end
