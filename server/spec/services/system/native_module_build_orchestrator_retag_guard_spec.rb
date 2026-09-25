# frozen_string_literal: true

require "rails_helper"

# NARROW-DISPATCH part 2 — a content-address SKIP must not publish a stale
# artifact.
#
# On a skip, module-forge-build.sh does `oras tag <module>:latest <this tag>` and
# reports that digest as if it were a fresh build. push.sh moves :latest on
# EVERY push — shadow batches, publishes later refused by the core-provenance
# gate or the size floor, pushes never recorded — so :latest is not guaranteed
# to be what the fleet runs, and a skip would then auto-promote a different
# artifact. The orchestrator snapshots :latest at dispatch, and refuses at
# finalize (before signing) a re-tag that is not the current version, as well
# as any artifact that is a recorded NON-current version.
RSpec.describe System::NativeModuleBuildOrchestrator, "stale re-tag guard" do
  let(:account)         { create(:account) }
  let(:node_template)   { create(:system_node_template, account: account) }
  let(:provider_region) { create(:system_provider_region, account: account) }
  let(:instance_type)   { create(:system_provider_instance_type, account: account) }

  let(:pool) do
    System::InstancePool.create!(
      account: account, node_template: node_template, name: described_class::DEFAULT_POOL_NAME,
      target_size: 5, min_size: 1, max_size: 5, lifecycle_class: "ephemeral", status: "active",
      provider_region: provider_region, provider_instance_type: instance_type
    )
  end

  def seed_pool_member
    pool
    node = create(:system_node, account: account, node_template: node_template)
    create(:system_node_instance, node: node, name: "member-#{SecureRandom.hex(3)}", variety: "cloud",
                                  status: "running", provider_region: provider_region,
                                  provider_instance_type: instance_type, instance_pool_id: pool.id,
                                  pool_state: "ready", last_heartbeat_at: Time.current,
                                  pool_warming_started_at: 1.minute.ago)
  end

  let(:mod) { create(:system_node_module, account: account, name: "powernode-system-base") }

  let(:current_layer)   { "sha256:#{'c' * 64}" }
  let(:stale_layer)     { "sha256:#{'5' * 64}" }
  let(:fresh_layer)     { "sha256:#{'f' * 64}" }
  let(:latest_manifest) { "sha256:#{'1' * 64}" }
  let(:fresh_manifest)  { "sha256:#{'2' * 64}" }

  def version_with(layer, number:, tag:)
    create(:system_node_module_version, node_module: mod, version_number: number, config: { "git_tag" => tag },
                                        oci_digest: layer,
                                        artifacts: { System::NodeModuleVersion::PRIMARY_ARTIFACT_FORMAT =>
                                                       { "oci_digest" => layer, "size" => 6_000_000 } })
  end

  let!(:current_version) do
    v = version_with(current_layer, number: 21, tag: "1b88b02")
    mod.update_columns(current_version_id: v.id)
    v
  end

  def latest_ref
    "registry.example.com/powernode/powernode-system-base:latest"
  end

  def built_ref
    "registry.example.com/powernode/powernode-system-base:abc1234"
  end

  def stub_registry(latest:, built:)
    allow(::System::OciArtifactDigests).to receive(:resolve) do |node_module:, oci_ref:|
      expect(node_module).to eq(mod)
      { latest_ref => latest, built_ref => built }.fetch(oci_ref)
    end
  end

  def dispatch_batch
    seed_pool_member
    batch = System::ModuleBuildBatch.create_for(account: account, plan: [ { module: mod.name, oci_ref: "abc1234" } ],
                                                trigger: "manual", base_sha: "base0000", head_sha: "headsha1234567")
    described_class.dispatch!(batch: batch)
    batch.reload
  end

  def complete_with(manifest_digest)
    task = System::Task.find_by(account: account, command: "ci.module_build")
    task.update!(status: "complete", completed_at: Time.current,
                 events: (task.events || []) + [ { "type" => "completed", "message" => "done",
                                                    "result" => { "oci_digest" => manifest_digest },
                                                    "timestamp" => Time.current.iso8601 } ])
  end

  before do
    allow(::System::DiskImageRegistryConfig).to receive(:registry_host).and_return("registry.example.com")
    allow(::System::CoreMirrorPreflight).to receive(:resolve_mirror_tip).and_return(nil)
  end

  def expect_publish
    expect(System::ModuleSigningService).to receive(:sign!)
      .and_return(System::ModuleSigningService::Result.new(ok?: true, oci_ref: "x", digest: "d"))
    expect(System::ModulePublicationProcessor).to receive(:process!)
      .and_return(System::ModulePublicationProcessor::Result.new(ok?: true, node_module_version: nil))
  end

  def expect_no_publish
    expect(System::ModuleSigningService).not_to receive(:sign!)
    expect(System::ModulePublicationProcessor).not_to receive(:process!)
  end

  describe "dispatch-time snapshot" do
    it "records :latest's manifest and layer digests per module" do
      stub_registry(latest: { manifest_digest: latest_manifest, layer_digest: stale_layer }, built: nil)

      batch = dispatch_batch

      expect(batch.metadata.dig("modules", mod.name, "pre_dispatch_latest")).to eq(
        "manifest_digest" => latest_manifest, "layer_digest" => stale_layer
      )
    end

    it "never blocks dispatch when the registry read fails, and says so" do
      allow(::System::OciArtifactDigests).to receive(:resolve).and_return(nil)

      batch = dispatch_batch

      expect(batch.status).to eq("dispatched")
      expect(batch.metadata.dig("modules", mod.name, "pre_dispatch_latest")).to be_nil
      expect(batch.metadata.dig("modules", mod.name, "pre_dispatch_latest_unresolved")).to be true
    end
  end

  describe "an allowlisted batch" do
    it "publishes through the same gated path: signed, core provenance threaded, promote on" do
      allow(::System::OciArtifactDigests).to receive(:resolve).and_return(nil)
      seed_pool_member
      batch = System::ModuleBuildBatch.create_for(
        account: account, plan: [ { module: mod.name, oci_ref: "abc1234" } ], trigger: "manual",
        base_sha: "base0000", head_sha: "headsha1234567",
        selection: { module_slugs: [ mod.name ], expand_dependents: false, withheld_dependents: %w[base-os],
                     requested_by: { type: "internal", id: nil } }
      )
      described_class.dispatch!(batch: batch)
      complete_with(fresh_manifest)

      expect(System::ModuleSigningService).to receive(:sign!)
        .with(hash_including(expected_digest: fresh_manifest))
        .and_return(System::ModuleSigningService::Result.new(ok?: true, oci_ref: "x", digest: "d"))
      expect(System::ModulePublicationProcessor).to receive(:process!)
        .with(node_module: mod, tag: "abc1234", promote: true,
              native_build: hash_including(:expected_core_sha, :fsverity_root))
        .and_return(System::ModulePublicationProcessor::Result.new(ok?: true, node_module_version: nil))

      expect(described_class.advance!(batch: batch.reload).succeeded).to eq(1)
    end
  end

  describe "finalize" do
    it "REFUSES a skip that re-tagged a :latest which is not the current version" do
      stub_registry(latest: { manifest_digest: latest_manifest, layer_digest: stale_layer },
                    built: { manifest_digest: latest_manifest, layer_digest: stale_layer })
      batch = dispatch_batch
      complete_with(latest_manifest)
      seed_pool_member # a retry would have a builder available; it must not use it
      expect_no_publish

      result = described_class.advance!(batch: batch)

      entry = batch.reload.metadata["modules"][mod.name]
      # Terminal, not retried: a re-run would skip and re-tag the same :latest.
      expect(result.failed).to eq(1)
      expect(result.retried).to eq(0)
      expect(entry["state"]).to eq("failed")
      expect(entry["error"]).to include("re-tagged :latest", stale_layer, current_layer)
    end

    it "allows a skip whose :latest IS the current version (a byte-identical republish)" do
      stub_registry(latest: { manifest_digest: latest_manifest, layer_digest: current_layer },
                    built: { manifest_digest: latest_manifest, layer_digest: current_layer })
      batch = dispatch_batch
      complete_with(latest_manifest)
      expect_publish

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end

    it "allows a fresh build" do
      stub_registry(latest: { manifest_digest: latest_manifest, layer_digest: stale_layer },
                    built: { manifest_digest: fresh_manifest, layer_digest: fresh_layer })
      batch = dispatch_batch
      complete_with(fresh_manifest)
      expect_publish

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end

    it "REFUSES an artifact that is a recorded non-current version, even without a snapshot" do
      version_with(stale_layer, number: 19, tag: "0ld0ld0")
      allow(::System::OciArtifactDigests).to receive(:resolve) do |oci_ref:, **|
        oci_ref == built_ref ? { manifest_digest: fresh_manifest, layer_digest: stale_layer } : nil
      end
      batch = dispatch_batch
      complete_with(fresh_manifest)
      expect_no_publish

      result = described_class.advance!(batch: batch)

      expect(result.failed).to eq(1)
      expect(batch.reload.metadata["modules"][mod.name]["error"]).to include("recorded non-current version v19")
    end

    it "does not count this build's own version row (a finalize re-run after a partial publish)" do
      version_with(fresh_layer, number: 22, tag: "abc1234")
      # The dispatch snapshot predates this build's push, so it shows the OLD :latest.
      stub_registry(latest: { manifest_digest: latest_manifest, layer_digest: stale_layer },
                    built: { manifest_digest: fresh_manifest, layer_digest: fresh_layer })
      batch = dispatch_batch
      complete_with(fresh_manifest)
      expect_publish

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end

    it "falls back to today's behaviour when the built artifact cannot be read from the registry" do
      allow(::System::OciArtifactDigests).to receive(:resolve).and_return(nil)
      batch = dispatch_batch
      complete_with(fresh_manifest)
      expect_publish

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end
  end
end
