# frozen_string_literal: true

require "rails_helper"

# NARROW-DISPATCH part 2 — a content-address SKIP must not auto-promote a stale
# artifact.
#
# On a skip, module-forge-build.sh does `oras tag <module>:latest <this tag>` and
# reports that digest as if it were a fresh build. push.sh moves :latest on
# EVERY push — shadow batches, publishes later refused by the core-provenance
# gate or the size floor, pushes never recorded — so :latest is not guaranteed
# to be what the fleet runs, and a promoting publish would then deploy a
# different artifact. Each module's :latest is snapshotted when its build is
# handed to a builder (outside the batch lock), and finalize refuses, before
# signing, a PROMOTING publish of a re-tag that is not the current version or
# of a recorded non-current (held) version. A publish that will not promote
# (shadow batch, auto_promote false, package batch) is not guarded: refusing it
# would fail the batch and hold every sibling for no safety gain.
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

  def version_with(layer, number:, tag:, node_module: mod)
    create(:system_node_module_version, node_module: node_module, version_number: number,
                                        config: { "git_tag" => tag }, oci_digest: layer,
                                        artifacts: { System::NodeModuleVersion::PRIMARY_ARTIFACT_FORMAT =>
                                                       { "oci_digest" => layer, "size" => 6_000_000 } })
  end

  let!(:current_version) do
    v = version_with(current_layer, number: 21, tag: "1b88b02")
    mod.update_columns(current_version_id: v.id)
    v
  end

  def manifest(manifest_digest, layer_digest)
    System::OciManifestClient::Manifest.new(manifest_digest: manifest_digest,
                                            erofs_layer: { "digest" => layer_digest, "size" => 6_000_000 })
  end

  def ref(node_module, tag)
    "registry.example.com/powernode/#{node_module.name}:#{tag}"
  end

  # { oci_ref => Manifest }; a ref in not_found reads as a definitive 404,
  # any other unlisted ref as unmeasured (registry unavailable).
  # Callers pass the map brace-less (string keys), which Ruby collects into **refs.
  def stub_registry(map = {}, not_found: [], **refs)
    map = map.merge(refs)
    allow(::System::OciManifestClient).to receive(:fetch) { |oci_ref:, **| map[oci_ref] }
    allow(::System::OciManifestClient).to receive(:lookup) do |oci_ref:, **|
      if map[oci_ref]
        System::OciManifestClient::Lookup.new(status: :found, manifest: map[oci_ref])
      elsif not_found.include?(oci_ref)
        System::OciManifestClient::Lookup.new(status: :not_found, manifest: nil)
      else
        System::OciManifestClient::Lookup.new(status: :unavailable, manifest: nil)
      end
    end
  end

  def build_batch(modules: [ mod ], shadow: false, trigger: "manual", selection: nil)
    System::ModuleBuildBatch.create_for(account: account, plan: modules.map { |m| { module: m.name, oci_ref: "abc1234" } },
                                        trigger: trigger, base_sha: "base0000", head_sha: "headsha1234567",
                                        shadow: shadow, selection: selection)
  end

  def dispatch_batch(**opts)
    seed_pool_member
    batch = build_batch(**opts)
    described_class.dispatch!(batch: batch)
    batch.reload
  end

  def complete_with(manifest_digest, slug: mod.name)
    task = System::Task.where(account: account, command: "ci.module_build")
                       .detect { |t| t.options["module"] == slug }
    task.update!(status: "complete", completed_at: Time.current,
                 events: (task.events || []) + [ { "type" => "completed", "message" => "done",
                                                    "result" => { "oci_digest" => manifest_digest },
                                                    "timestamp" => Time.current.iso8601 } ])
  end

  before do
    allow(::System::DiskImageRegistryConfig).to receive(:registry_host).and_return("registry.example.com")
    allow(::System::CoreMirrorPreflight).to receive(:resolve_mirror_tip).and_return(nil)
  end

  def expect_publish(promote: true)
    expect(System::ModuleSigningService).to receive(:sign!)
      .and_return(System::ModuleSigningService::Result.new(ok?: true, oci_ref: "x", digest: "d"))
    expect(System::ModulePublicationProcessor).to receive(:process!)
      .with(hash_including(promote: promote))
      .and_return(System::ModulePublicationProcessor::Result.new(ok?: true, node_module_version: nil))
  end

  def expect_no_publish
    expect(System::ModuleSigningService).not_to receive(:sign!)
    expect(System::ModulePublicationProcessor).not_to receive(:process!)
  end

  describe ":latest snapshot" do
    it "is recorded for a module when its build is handed to a builder" do
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer))

      batch = dispatch_batch

      expect(batch.metadata.dig("modules", mod.name, "pre_dispatch_latest")).to eq(
        "manifest_digest" => latest_manifest, "layer_digest" => stale_layer
      )
    end

    it "is read outside the batch's advisory lock" do
      lock_counts = []
      allow(::System::OciManifestClient).to receive(:lookup) do
        lock_counts << ActiveRecord::Base.connection.select_value(
          "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
        ).to_i
        System::OciManifestClient::Lookup.new(status: :unavailable, manifest: nil)
      end

      dispatch_batch

      expect(lock_counts).not_to be_empty
      expect(lock_counts).to all(eq(0))
    end

    it "is not taken for a module still queued behind the concurrency cap, and is taken when it dispatches" do
      SiteSetting.set("system.module_builds.max_concurrent_builders", "1", setting_type: "integer")
      other = create(:system_node_module, account: account, name: "zz-other")
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer),
                    ref(other, "latest") => manifest(fresh_manifest, fresh_layer))

      batch = dispatch_batch(modules: [ mod, other ])

      expect(batch.metadata.dig("modules", other.name, "state")).to eq("queued")
      expect(batch.metadata.dig("modules", other.name)).not_to have_key("pre_dispatch_latest")
      expect(::System::OciManifestClient).not_to have_received(:lookup).with(hash_including(oci_ref: ref(other, "latest")))

      # The first build finishes (as a failure, to keep this about dispatch), freeing the one slot.
      task = System::Task.find_by(account: account, command: "ci.module_build")
      task.update!(status: "failed", completed_at: Time.current, error_message: "boom")
      SiteSetting.set("system.module_builds.max_attempts", "1", setting_type: "integer")
      seed_pool_member
      described_class.advance!(batch: batch) # resolves the finished build, freeing the slot
      described_class.advance!(batch: batch.reload) # hands the queued module to a builder

      expect(batch.reload.metadata.dig("modules", other.name, "state")).to eq("dispatched")
      expect(batch.metadata.dig("modules", other.name, "pre_dispatch_latest"))
        .to eq("manifest_digest" => fresh_manifest, "layer_digest" => fresh_layer)
    end

    it "is taken once: a later pass neither re-reads nor overwrites it" do
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer))
      batch = dispatch_batch

      stub_registry(ref(mod, "latest") => manifest(fresh_manifest, fresh_layer))
      expect(::System::OciManifestClient).not_to receive(:lookup).with(hash_including(oci_ref: ref(mod, "latest")))
      described_class.dispatch!(batch: batch)
      described_class.advance!(batch: batch.reload)

      expect(batch.reload.metadata.dig("modules", mod.name, "pre_dispatch_latest", "manifest_digest"))
        .to eq(latest_manifest)
    end

    it "never blocks dispatch when unreadable, and reports it once per batch rather than per module" do
      other = create(:system_node_module, account: account, name: "zz-other")
      stub_registry({})
      events = []
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!) { |**kw| events << kw[:kind] }
      seed_pool_member

      batch = dispatch_batch(modules: [ mod, other ])
      described_class.advance!(batch: batch)

      expect(batch.status).to eq("dispatched")
      expect(batch.reload.metadata.dig("modules", mod.name, "pre_dispatch_latest_unresolved")).to be true
      expect(batch.metadata.dig("modules", other.name, "pre_dispatch_latest_unresolved")).to be true
      expect(events.count("system.module_build.latest_snapshot_unresolved")).to eq(1)
    end

    it "is not taken for a package batch" do
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer))
      orchestrator = described_class.new(batch: build_batch(trigger: "package"))

      expect(orchestrator.send(:prefetch_latest_digests)).to eq({})
      expect(::System::OciManifestClient).not_to have_received(:lookup)
    end

    it "records a 404 :latest as a definitive absence and keeps reading the next module" do
      other = create(:system_node_module, account: account, name: "zz-other")
      stub_registry({ ref(other, "latest") => manifest(fresh_manifest, fresh_layer) },
                    not_found: [ ref(mod, "latest") ])
      seed_pool_member

      batch = dispatch_batch(modules: [ mod, other ])

      first = batch.metadata.dig("modules", mod.name)
      expect(first).to include("pre_dispatch_latest" => nil, "pre_dispatch_latest_reason" => "not_found")
      expect(first).not_to have_key("pre_dispatch_latest_unresolved")
      expect(batch.metadata.dig("modules", other.name, "pre_dispatch_latest"))
        .to eq("manifest_digest" => fresh_manifest, "layer_digest" => fresh_layer)
    end

    it "stops the pass at an unavailable registry: later modules are not read, and are recorded unmeasured" do
      other = create(:system_node_module, account: account, name: "zz-other")
      stub_registry({ ref(other, "latest") => manifest(fresh_manifest, fresh_layer) })
      seed_pool_member

      batch = dispatch_batch(modules: [ mod, other ])

      expect(::System::OciManifestClient).not_to have_received(:lookup).with(hash_including(oci_ref: ref(other, "latest")))
      expect(batch.metadata.dig("modules", mod.name, "pre_dispatch_latest_unresolved")).to be true
      expect(batch.metadata.dig("modules", other.name, "pre_dispatch_latest_unresolved")).to be true
    end
  end

  describe "finalize of a promoting publish" do
    def capture_events
      events = []
      allow(::System::Fleet::EventBroadcaster).to receive(:emit!) { |**kw| events << kw }
      events
    end

    it "treats a skip that re-tagged a stale :latest as a NO-OP SUCCESS: nothing signed, published or promoted" do
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer),
                    ref(mod, "abc1234") => manifest(latest_manifest, stale_layer))
      events = capture_events
      batch = dispatch_batch
      complete_with(latest_manifest)
      expect_no_publish

      expect { @result = described_class.advance!(batch: batch) }
        .not_to change { System::NodeModuleVersion.where(node_module: mod).count }

      entry = batch.reload.metadata["modules"][mod.name]
      expect(@result.succeeded).to eq(1)
      expect(@result.failed).to eq(0)
      expect(entry).to include("state" => "succeeded", "outcome" => "skipped_stale_latest", "error" => nil)
      expect(entry["note"]).to include("re-tagged :latest", stale_layer, current_layer, "real input change")
      expect(entry["note"]).not_to include("BUILD_SKIP_UNCHANGED")
      expect(batch.status).to eq("complete")
      expect(mod.reload.current_version_id).to eq(current_version.id)

      refused = events.find { |e| e[:kind] == "system.module_build.stale_retag_refused" }
      expect(refused).to be_present
      expect(refused[:severity]).to eq(:high)
      expect(refused[:payload]).to include("outcome" => "skipped_stale_latest", "artifact_layer" => stale_layer,
                                           "current_layer" => current_layer)
      expect(events.map { |e| e[:kind] }).not_to include("system.module_promotions_held")
      expect(System::ModuleBuildBatchSerializer.new(batch).as_full[:modules].first[:outcome]).to eq("skipped_stale_latest")
    end

    it "treats a held (recorded non-current) version as a no-op success too, even without a snapshot" do
      version_with(stale_layer, number: 19, tag: "0ld0ld0")
      stub_registry(ref(mod, "abc1234") => manifest(fresh_manifest, stale_layer))
      batch = dispatch_batch
      complete_with(fresh_manifest)
      expect_no_publish

      result = described_class.advance!(batch: batch)

      entry = batch.reload.metadata["modules"][mod.name]
      expect(result.succeeded).to eq(1)
      expect(entry).to include("state" => "succeeded", "outcome" => "skipped_held_version")
      expect(entry["note"]).to include("recorded non-current version v19")
    end

    it "resolves a batch whose only success is a no-op and whose other member failed to partial, not stuck" do
      SiteSetting.set("system.module_builds.max_attempts", "1", setting_type: "integer")
      other = create(:system_node_module, account: account, name: "zz-other")
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer),
                    ref(mod, "abc1234") => manifest(latest_manifest, stale_layer))
      seed_pool_member
      batch = dispatch_batch(modules: [ mod, other ])
      complete_with(latest_manifest, slug: mod.name)
      System::Task.where(account: account, command: "ci.module_build").detect { |t| t.options["module"] == other.name }
                  .update!(status: "failed", completed_at: Time.current, error_message: "boom")
      expect_no_publish

      described_class.advance!(batch: batch)

      expect(batch.reload.status).to eq("partial")
    end

    it "in a mixed batch, a no-op HOLDS the fresh siblings' deferred promotions (batch-atomic), yet completes" do
      other = create(:system_node_module, account: account, name: "zz-other")
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer),
                    ref(mod, "abc1234") => manifest(latest_manifest, stale_layer),
                    ref(other, "abc1234") => manifest(fresh_manifest, fresh_layer))
      events = capture_events
      seed_pool_member
      batch = dispatch_batch(modules: [ mod, other ])
      complete_with(latest_manifest, slug: mod.name)
      complete_with(fresh_manifest, slug: other.name)

      # The fresh sibling publishes into the batch's deferred set, as
      # ModulePublicationProcessor does for a multi-module batch.
      fresh_version = nil
      other_previous = other.current_version_id
      expect(System::ModuleSigningService).to receive(:sign!).once
        .and_return(System::ModuleSigningService::Result.new(ok?: true, oci_ref: "x", digest: "d"))
      expect(System::ModulePublicationProcessor).to receive(:process!).once
        .with(hash_including(node_module: other, promote: true)) do
          fresh_version = version_with(fresh_layer, number: 1, tag: "abc1234", node_module: other)
          fresh_version.update_columns(deferred_promotion_batch_id: batch.id)
          System::ModulePublicationProcessor::Result.new(ok?: true, node_module_version: fresh_version)
        end

      result = described_class.advance!(batch: batch)

      expect(result.succeeded).to eq(2)
      expect(batch.reload.status).to eq("complete")
      expect(batch.metadata.dig("modules", mod.name, "outcome")).to eq("skipped_stale_latest")
      # Promoting `other` alone would put it live against `mod`'s old version:
      # exactly the skew batch-atomic promotion exists to prevent.
      expect(other.reload.current_version_id).to eq(other_previous)
      expect(fresh_version.reload.deferred_promotion_batch_id).to eq(batch.id)
      expect(mod.reload.current_version_id).to eq(current_version.id)
      held = events.find { |e| e[:kind] == "system.module_promotions_held" }
      expect(held).to be_present
      expect(held[:payload][:reason]).to include(mod.name, "no-op")
      expect(held[:payload][:modules]).to eq([ other.name ])
    end

    it "a batch whose only entries are no-ops completes with nothing deferred and nothing held, and says so" do
      other = create(:system_node_module, account: account, name: "zz-other")
      version_with(stale_layer, number: 5, tag: "0ld0ld0", node_module: other)
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer),
                    ref(mod, "abc1234") => manifest(latest_manifest, stale_layer),
                    ref(other, "abc1234") => manifest(fresh_manifest, stale_layer))
      events = capture_events
      seed_pool_member
      batch = dispatch_batch(modules: [ mod, other ])
      complete_with(latest_manifest, slug: mod.name)
      complete_with(fresh_manifest, slug: other.name)
      expect_no_publish

      described_class.advance!(batch: batch)

      batch.reload
      expect(batch.status).to eq("complete")
      expect(System::NodeModuleVersion.where(deferred_promotion_batch_id: batch.id)).to be_empty
      expect(events.map { |e| e[:kind] }).not_to include("system.module_promotions_held")
      expect(batch.metadata).to include("noop_count" => 2, "noop_modules" => [ other.name, mod.name ].sort)

      summary = System::ModuleBuildBatchSerializer.new(batch).as_summary
      expect(summary).to include(noop_count: 2, noop_modules: [ other.name, mod.name ].sort)
      tool_payload = Ai::Tools::SystemFleetTool.new(account: account, internal: true)
                                               .send(:serialize_module_build_batch, batch)
      expect(tool_payload).to include(noop_count: 2, noop_modules: [ other.name, mod.name ].sort)
    end

    it "allows a skip whose :latest IS the current version (a byte-identical republish)" do
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, current_layer),
                    ref(mod, "abc1234") => manifest(latest_manifest, current_layer))
      batch = dispatch_batch
      complete_with(latest_manifest)
      expect_publish

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end

    it "allows a fresh build" do
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer),
                    ref(mod, "abc1234") => manifest(fresh_manifest, fresh_layer))
      batch = dispatch_batch
      complete_with(fresh_manifest)
      expect_publish

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end

    it "does not count this build's own version row (a finalize re-run after a partial publish)" do
      version_with(fresh_layer, number: 22, tag: "abc1234")
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer),
                    ref(mod, "abc1234") => manifest(fresh_manifest, fresh_layer))
      batch = dispatch_batch
      complete_with(fresh_manifest)
      expect_publish

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end

    it "falls back to today's behaviour when the built artifact cannot be read" do
      stub_registry({})
      batch = dispatch_batch
      complete_with(fresh_manifest)
      expect_publish

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end
  end

  describe "a publish that will not promote is not guarded" do
    before do
      version_with(stale_layer, number: 19, tag: "0ld0ld0")
      stub_registry(ref(mod, "latest") => manifest(latest_manifest, stale_layer),
                    ref(mod, "abc1234") => manifest(latest_manifest, stale_layer))
    end

    it "a shadow batch publishes the stale re-tag with promote: false" do
      batch = dispatch_batch(shadow: true)
      complete_with(latest_manifest)
      expect_publish(promote: false)

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end

    it "an auto_promote: false module publishes it (the version is held, never promoted)" do
      mod.update_columns(auto_promote: false)
      batch = dispatch_batch
      complete_with(latest_manifest)
      expect_publish

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end

    it "a package batch is exempt" do
      orchestrator = described_class.new(batch: build_batch(trigger: "package"))

      expect(orchestrator.send(:stale_retag, mod, { "tag" => "abc1234",
                                                            "pre_dispatch_latest" => { "manifest_digest" => latest_manifest,
                                                                                       "layer_digest" => stale_layer } }))
        .to be_nil
    end
  end

  describe "a batch dispatched with an allowlist" do
    let(:gitea_provider) { create(:git_provider, :gitea, account: account) }
    let!(:gitea_credential) { create(:git_provider_credential, :gitea, account: account, provider: gitea_provider) }
    let!(:base_os) { create(:system_node_module, account: account, name: "base-os", manifest_yaml: "schema_version: 1") }

    before do
      mod.update_columns(manifest_yaml: "schema_version: 1")
      create(:system_module_dependency, node_module: base_os, dependency: mod)
      fake_client = instance_double(Devops::Git::GiteaApiClient)
      allow(Devops::Git::ApiClient).to receive(:for).and_return(fake_client)
      allow(fake_client).to receive(:compare_commits).and_return(commits: [ { sha: "h" * 40 } ])
      allow(fake_client).to receive(:get_commit).and_return(files: [ { filename: "agent/internal/runtime/reconcile.go" } ])
      allow(fake_client).to receive(:supports_runners?).and_return(false)
      allow_any_instance_of(::Ai::InterventionPolicyService).to receive(:resolve).and_return(
        { policy: "auto_approve", channels: [], conditions: {}, record: nil }
      )
      stub_registry({})
    end

    it "builds only the allowlist and still publishes through the gated path" do
      seed_pool_member
      tool = Ai::Tools::SystemFleetTool.new(account: account, internal: true)
      result = tool.execute(params: { action: "system_dispatch_module_build_batch", base_sha: "a" * 40,
                                      head_sha: "h" * 40, module_slugs: [ mod.name ], expand_dependents: false })
      expect(result[:success]).to be true

      batch = System::ModuleBuildBatch.last
      expect(batch.module_slugs).to eq([ mod.name ])
      expect(batch.metadata.dig("selection", "withheld_dependents")).to eq([ "base-os" ])
      expect(System::Task.where(account: account, command: "ci.module_build").map { |t| t.options["module"] })
        .to eq([ mod.name ])

      complete_with(fresh_manifest)
      expect(System::ModuleSigningService).to receive(:sign!)
        .with(hash_including(expected_digest: fresh_manifest))
        .and_return(System::ModuleSigningService::Result.new(ok?: true, oci_ref: "x", digest: "d"))
      expect(System::ModulePublicationProcessor).to receive(:process!)
        .with(node_module: mod, tag: ("h" * 40)[0, 7], promote: true,
              native_build: hash_including(:expected_core_sha, :fsverity_root))
        .and_return(System::ModulePublicationProcessor::Result.new(ok?: true, node_module_version: nil))

      expect(described_class.advance!(batch: batch).succeeded).to eq(1)
    end
  end
end
