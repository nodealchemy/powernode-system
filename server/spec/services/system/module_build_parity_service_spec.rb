# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc10 — System::ModuleBuildParityService. Structurally
# compares the Gitea-authoritative `:<sha>` artifact against the shadow
# native `:native-<sha>` artifact for every module in a shadow batch, using
# a stubbable LocalParityAdapter so no real registry/oras/fsck.erofs is
# needed in the suite.
RSpec.describe System::ModuleBuildParityService do
  let(:account) { create(:account) }

  let(:local_adapter) { System::ModuleBuildParityService::LocalParityAdapter.new }

  before do
    allow(::System::DiskImageRegistryConfig).to receive(:registry_host).and_return("registry.example.com")
    System::ModuleBuildParityService.adapter = local_adapter
  end

  after { System::ModuleBuildParityService.reset! }

  def create_module(name)
    create(:system_node_module, account: account, name: name, gitea_repo_full_name: "powernode/#{name}")
  end

  def shadow_batch(modules:, head_sha: "headsha1234567")
    plan = modules.map { |m| { module: m.name, oci_ref: "native-#{head_sha[0, 7]}" } }
    System::ModuleBuildBatch.create_for(
      account: account, plan: plan, trigger: "push", base_sha: "base0000", head_sha: head_sha, shadow: true
    )
  end

  def refs_for(mod, head_sha: "headsha1234567")
    gitea_tag  = head_sha[0, 7]
    native_tag = "native-#{gitea_tag}"
    [
      "registry.example.com/powernode/#{mod.name}:#{gitea_tag}",
      "registry.example.com/powernode/#{mod.name}:#{native_tag}"
    ]
  end

  describe "#compare! / .compare!" do
    it "rejects a non-shadow batch" do
      mod = create_module("mod-a")
      plan = [ { module: mod.name, oci_ref: "abc1234" } ]
      batch = System::ModuleBuildBatch.create_for(account: account, plan: plan, trigger: "push",
                                                   base_sha: "b", head_sha: "headsha1234567", shadow: false)

      result = described_class.compare!(batch: batch)

      expect(result.ok?).to be false
      expect(result.error).to include("not a shadow batch")
    end

    it "marks a module ok and emits system.module_build_parity_ok when artifacts are identical" do
      mod = create_module("mod-identical")
      batch = shadow_batch(modules: [ mod ])
      gitea_ref, native_ref = refs_for(mod)
      local_adapter.stub!(ref_a: gitea_ref, ref_b: native_ref,
                           result: { identical: true, added: [], removed: [], changed: [] })

      expect {
        result = described_class.compare!(batch: batch)
        @result = result
      }.to change { System::FleetEvent.where(account: account, kind: "system.module_build_parity_ok").count }.by(1)

      expect(@result.ok?).to be true
      mod_result = @result.results.find { |r| r.module == mod.name }
      expect(mod_result.status).to eq("ok")
      expect(mod_result.identical).to be true

      event = System::FleetEvent.where(kind: "system.module_build_parity_ok").last
      expect(event.severity).to eq("low")
      expect(event.payload["module"]).to eq(mod.name)
      expect(event.payload["batch_id"]).to eq(batch.id)
    end

    it "marks a module failed and emits system.module_build_parity_failed (severity high) on divergence" do
      mod = create_module("mod-diverges")
      batch = shadow_batch(modules: [ mod ])
      gitea_ref, native_ref = refs_for(mod)
      local_adapter.stub!(ref_a: gitea_ref, ref_b: native_ref,
                           result: { identical: false, added: [ "/etc/new.conf" ], removed: [], changed: [ "/etc/x.conf" ] })

      expect {
        @result = described_class.compare!(batch: batch)
      }.to change { System::FleetEvent.where(account: account, kind: "system.module_build_parity_failed").count }.by(1)

      mod_result = @result.results.find { |r| r.module == mod.name }
      expect(mod_result.status).to eq("failed")
      expect(mod_result.identical).to be false
      expect(mod_result.diff_summary).to eq("added" => [ "/etc/new.conf" ], "removed" => [], "changed" => [ "/etc/x.conf" ])

      event = System::FleetEvent.where(kind: "system.module_build_parity_failed").last
      expect(event.severity).to eq("high")
      expect(event.payload["added"]).to eq([ "/etc/new.conf" ])
    end

    it "skips a waivered module — no adapter call, no event, status waived" do
      mod = create_module("vector")
      batch = shadow_batch(modules: [ mod ])
      # Default waiver list includes "vector" (inc5 live-repo-hook module).
      expect(local_adapter).not_to receive(:diff)

      result = described_class.compare!(batch: batch)

      mod_result = result.results.find { |r| r.module == "vector" }
      expect(mod_result.status).to eq("waived")
      expect(System::FleetEvent.where(kind: %w[system.module_build_parity_ok system.module_build_parity_failed]).count).to eq(0)
    end

    it "honors an operator-configured waiver list (SiteSetting overrides the default)" do
      mod = create_module("some-custom-module")
      SiteSetting.set("system.module_builds.parity_waivers", [ "some-custom-module" ].to_json, setting_type: "json")
      batch = shadow_batch(modules: [ mod ])
      expect(local_adapter).not_to receive(:diff)

      result = described_class.compare!(batch: batch)

      expect(result.results.first.status).to eq("waived")
    end

    it "a SiteSetting-configured waiver list no longer waives modules it excludes" do
      mod = create_module("vector") # in the DEFAULT waiver list
      SiteSetting.set("system.module_builds.parity_waivers", [ "some-other-module" ].to_json, setting_type: "json")
      batch = shadow_batch(modules: [ mod ])
      gitea_ref, native_ref = refs_for(mod)
      local_adapter.stub!(ref_a: gitea_ref, ref_b: native_ref, result: { identical: true, added: [], removed: [], changed: [] })

      result = described_class.compare!(batch: batch)

      expect(result.results.first.status).to eq("ok") # not waived — the operator's list won
    end

    it "records an error result (no event) when the adapter reports an error" do
      mod = create_module("mod-broken")
      batch = shadow_batch(modules: [ mod ])
      gitea_ref, native_ref = refs_for(mod)
      local_adapter.stub!(ref_a: gitea_ref, ref_b: native_ref, result: { error: "oras pull 404" })

      result = described_class.compare!(batch: batch)

      mod_result = result.results.first
      expect(mod_result.status).to eq("error")
      expect(mod_result.error).to eq("oras pull 404")
      expect(System::FleetEvent.where(kind: %w[system.module_build_parity_ok system.module_build_parity_failed]).count).to eq(0)
    end

    it "records an error result when the NodeModule can no longer be resolved" do
      batch = System::ModuleBuildBatch.create_for(
        account: account, plan: [ { module: "ghost-module", oci_ref: "native-abc1234" } ],
        trigger: "push", base_sha: "b", head_sha: "headsha1234567", shadow: true
      )

      result = described_class.compare!(batch: batch)

      expect(result.results.first.status).to eq("error")
      expect(result.results.first.error).to include("not found")
    end

    it "persists per-module results onto batch.metadata['parity']" do
      good = create_module("mod-good")
      bad  = create_module("mod-bad")
      batch = shadow_batch(modules: [ good, bad ])
      good_refs = refs_for(good)
      bad_refs  = refs_for(bad)
      local_adapter.stub!(ref_a: good_refs[0], ref_b: good_refs[1],
                           result: { identical: true, added: [], removed: [], changed: [] })
      local_adapter.stub!(ref_a: bad_refs[0], ref_b: bad_refs[1],
                           result: { identical: false, added: [ "/x" ], removed: [], changed: [] })

      described_class.compare!(batch: batch)

      parity = batch.reload.metadata["parity"]
      expect(parity["mod-good"]["status"]).to eq("ok")
      expect(parity["mod-bad"]["status"]).to eq("failed")
      expect(parity["mod-bad"]["diff_summary"]).to eq("added" => [ "/x" ], "removed" => [], "changed" => [])
    end

    it "never touches NativeModuleBuildOrchestrator's own metadata['plan']/metadata['modules'] bookkeeping" do
      mod = create_module("mod-a")
      batch = shadow_batch(modules: [ mod ])
      original_plan = batch.metadata["plan"]

      described_class.compare!(batch: batch)

      expect(batch.reload.metadata["plan"]).to eq(original_plan)
    end
  end

  describe System::ModuleBuildParityService::LocalParityAdapter do
    it "returns an identical result by default when nothing is stubbed" do
      adapter = described_class.new
      expect(adapter.diff(ref_a: "a", ref_b: "b")).to eq(identical: true, added: [], removed: [], changed: [])
    end
  end
end
