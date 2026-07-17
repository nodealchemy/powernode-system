# frozen_string_literal: true

require "rails_helper"

# Campaign 019f5885 inc10 — the promote: option on
# System::ModulePublicationProcessor#process!. Default (promote: true)
# preserves every pre-inc10 caller's behavior exactly (Gitea webhook,
# CI-direct publish, native authoritative dispatch); promote: false is the
# new no-promote path a SHADOW native build (mode == "dual") uses so it can
# ingest + record a version without ever moving NodeModule#current_version_id
# off whatever the Gitea build published.
#
# Uses the same LocalOciAdapter/LocalManifestFetch test-mode adapters as
# spec/requests/api/v1/system/webhooks/gitea_module_spec.rb — no real
# registry/oras/cosign needed.
RSpec.describe System::ModulePublicationProcessor do
  before do
    System::ModuleOciIngestService.reset!
    System::ManifestFetchService.reset!
  end

  let(:account) { create(:account) }
  let!(:node_module) do
    create(:system_node_module, account: account, name: "nginx-mod",
                                 gitea_repo_full_name: "ipnode-acme/nginx-mod")
  end

  describe "#process! promote: option" do
    it "defaults to promote: true — preserves current_version promotion for every existing caller" do
      expect(node_module.current_version_id).to be_nil

      result = described_class.process!(node_module: node_module, tag: "abc1234")

      expect(result.ok?).to be true
      expect(node_module.reload.current_version_id).to eq(result.node_module_version.id)
    end

    # Regression (imp 019f6d9a): a promoting publish must advance BOTH the FK and
    # the denormalized current_version_number together — the old id-only write
    # drifted the number the drift sensor / fleet reconciler / UI read.
    it "promote: true advances current_version_number in lockstep with current_version_id" do
      result = described_class.process!(node_module: node_module, tag: "abc1234")
      node_module.reload

      expect(node_module.current_version_id).to eq(result.node_module_version.id)
      expect(node_module.current_version_number).to eq(result.node_module_version.version_number)
      expect(node_module.current_version_number).to be_positive
    end

    it "promote: false ingests + records a version WITHOUT advancing current_version_id" do
      result = described_class.process!(node_module: node_module, tag: "native-abc1234", promote: false)

      expect(result.ok?).to be true
      expect(result.node_module_version).to be_present
      expect(result.artifacts).to be_present
      expect(node_module.reload.current_version_id).to be_nil
    end

    it "promote: false never clobbers an already-promoted (Gitea-authoritative) current_version" do
      gitea_result = described_class.process!(node_module: node_module, tag: "abc1234")
      expect(node_module.reload.current_version_id).to eq(gitea_result.node_module_version.id)

      described_class.process!(node_module: node_module, tag: "native-abc1234", promote: false)

      expect(node_module.reload.current_version_id).to eq(gitea_result.node_module_version.id)
    end

    it "still creates the NodeModuleVersion + ModuleArtifact rows a shadow parity comparison needs" do
      result = described_class.process!(node_module: node_module, tag: "native-abc1234", promote: false)

      expect(result.node_module_version.module_artifacts.count).to eq(2) # amd64 + arm64
      expect(result.node_module_version.config["git_tag"]).to eq("native-abc1234")
    end

    it "still registers skills on a no-promote publish" do
      registrar_double = double(ok?: true, registered: 1, removed: 0, proposed: 0, error: nil)
      expect(System::ModuleSkillRegistrar)
        .to receive(:register_for_module!)
        .with(hash_including(node_module: node_module))
        .and_return(registrar_double)

      described_class.process!(node_module: node_module, tag: "native-abc1234", promote: false)
    end

    it "emits system.module_published with promoted: false in the payload on a no-promote publish" do
      expect {
        described_class.process!(node_module: node_module, tag: "native-abc1234", promote: false)
      }.to change { System::FleetEvent.where(account: account, kind: "system.module_published").count }.by(1)

      event = System::FleetEvent.where(kind: "system.module_published").last
      expect(event.payload["promoted"]).to eq(false)
    end

    it "emits system.module_published with promoted: true in the payload on a normal (promoting) publish" do
      described_class.process!(node_module: node_module, tag: "abc1234")

      event = System::FleetEvent.where(kind: "system.module_published").last
      expect(event.payload["promoted"]).to eq(true)
    end

    it "does not promote when ingest fails, regardless of the promote: flag" do
      System::ModuleOciIngestService.adapter.stub_manifest = { error: "registry returned 500" }

      result = described_class.process!(node_module: node_module, tag: "abc1234", promote: true)

      expect(result.ok?).to be false
      expect(node_module.reload.current_version_id).to be_nil
    end
  end
end
