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

  # 2026-08-07 incident: runtime-go v2 and gitleaks v4 published erofs blobs
  # containing ZERO files. Both cleared cosign AND OCI ingest — neither gate
  # looks at whether the artifact contains anything — so both auto-promoted,
  # agents pulled them, and hot-prune correctly concluded no surviving layer
  # provided the old paths and whiteout-deleted /usr/local/go and
  # /usr/local/bin/gitleaks off a live node's root. Every platform signal read
  # healthy throughout.
  #
  # From the agent's side an empty artifact is indistinguishable from a
  # legitimate "this module now ships nothing", so the floor has to live here,
  # at publish time. The version is still RECORDED (so the bad build can be
  # inspected); what is withheld is PROMOTION, which is the step that reaches
  # the fleet.
  describe "empty-artifact promotion floor" do
    def stub_erofs_of_size(bytes)
      System::ModuleOciIngestService.adapter.stub_manifest = {
        per_arch_descriptors: [ {
          architecture:       "amd64",
          oci_digest:         "sha256:#{'0' * 64}",
          media_type:         ::System::ModuleArtifact::DEFAULT_MEDIA_TYPE,
          size_bytes:         bytes,
          fsverity_root_hash: "fsv-empty",
          built_at:           Time.current
        } ]
      }
    end

    it "does NOT promote a module whose artifact is below the non-empty floor" do
      stub_erofs_of_size(1_024) # an empty erofs is a few KiB of superblock

      result = described_class.process!(node_module: node_module, tag: "empty01")

      # The version is still recorded — only promotion is withheld.
      expect(result.node_module_version).to be_present
      expect(node_module.reload.current_version_id).to be_nil
    end

    it "does not DEMOTE an already-good current version when a later empty build lands" do
      described_class.process!(node_module: node_module, tag: "good001")
      good_version_id = node_module.reload.current_version_id
      expect(good_version_id).to be_present

      stub_erofs_of_size(1_024)
      described_class.process!(node_module: node_module, tag: "empty02")

      # The whole point: the fleet keeps running the last good version.
      expect(node_module.reload.current_version_id).to eq(good_version_id)
    end

    # Review finding: emit_published_event was handed the REQUESTED promote
    # flag, not the outcome, so a withheld promotion still announced
    # promoted: true — anything reading the fleet event stream believed the bad
    # version was live while current_version_id still pointed at the previous
    # one. That is the same "audit trail asserts something that did not happen"
    # shape the withhold exists to prevent.
    it "reports promoted: false in the event when the promotion was withheld" do
      stub_erofs_of_size(1_024)

      described_class.process!(node_module: node_module, tag: "evt001")

      event = System::FleetEvent.where(account: account, kind: "system.module_published").last
      expect(event.payload["promoted"]).to eq(false)
      expect(node_module.reload.current_version_id).to be_nil
    end

    it "reports promoted: false in the event when the module is held back by policy" do
      node_module.update!(auto_promote: false)

      described_class.process!(node_module: node_module, tag: "evt002")

      event = System::FleetEvent.where(account: account, kind: "system.module_published").last
      expect(event.payload["promoted"]).to eq(false)
    end

    # FAIL CLOSED on an unmeasured artifact. Ingest writes
    # `fetch(:size_bytes, 0)`, so a failed layer-descriptor read is
    # indistinguishable from a real 0 — and the pipeline that fails to measure
    # a blob is plausibly the same one that emitted the empty blob on
    # 2026-08-07. Withholding costs a recoverable "fleet stays on the old
    # version"; promoting costs files deleted off live roots.
    it "does NOT promote an artifact whose size ingest never determined" do
      System::ModuleOciIngestService.adapter.stub_manifest = {
        per_arch_descriptors: [ {
          architecture: "amd64", oci_digest: "sha256:#{'c' * 64}",
          media_type: ::System::ModuleArtifact::DEFAULT_MEDIA_TYPE,
          size_bytes: 0, fsverity_root_hash: "fsv-unknown", built_at: Time.current
        } ]
      }

      result = described_class.process!(node_module: node_module, tag: "unk001")

      expect(result.node_module_version).to be_present
      expect(node_module.reload.current_version_id).to be_nil
    end

    it "still promotes an artifact comfortably above the floor" do
      result = described_class.process!(node_module: node_module, tag: "fine001")

      expect(node_module.reload.current_version_id).to eq(result.node_module_version.id)
    end

    it "does not promote when ingest produced no canonical artifact at all" do
      System::ModuleOciIngestService.adapter.stub_manifest = { per_arch_descriptors: [] }

      described_class.process!(node_module: node_module, tag: "noart01")

      expect(node_module.reload.current_version_id).to be_nil
    end

    # The empty-artifact floor catches only the degenerate case. A non-empty
    # but BROKEN artifact — wrong arch, truncated tree, a missing binary the
    # units need — still reaches every node running the module the instant it
    # publishes. Full canary/dwell automation is an operator policy decision
    # (see the task report); this is the piece that needs no decision: a
    # per-module holdback an operator can set on a high-risk module so its
    # publishes land as versions WITHOUT becoming what the fleet runs.
    #
    # Defaults to ON, so a module that says nothing behaves exactly as before.
    describe "per-module auto_promote holdback" do
      it "still promotes by default, so existing modules are unaffected" do
        result = described_class.process!(node_module: node_module, tag: "dflt001")

        expect(node_module.reload.current_version_id).to eq(result.node_module_version.id)
      end

      it "publishes but does NOT promote when the module opts out" do
        node_module.update!(auto_promote: false)

        result = described_class.process!(node_module: node_module, tag: "held001")

        expect(result.node_module_version).to be_present
        expect(node_module.reload.current_version_id).to be_nil
      end

      it "leaves an existing good version current when a later publish is held" do
        described_class.process!(node_module: node_module, tag: "good002")
        good_id = node_module.reload.current_version_id
        expect(good_id).to be_present

        node_module.update!(auto_promote: false)
        described_class.process!(node_module: node_module, tag: "held002")

        expect(node_module.reload.current_version_id).to eq(good_id)
      end
    end

    it "honours a configured floor rather than a hardcoded constant" do
      SiteSetting.set("system.module_publish.min_artifact_bytes", "50000000", setting_type: "integer")
      # The default stub artifact is ~12MB — fine normally, below a 50MB floor.

      described_class.process!(node_module: node_module, tag: "cfg0001")

      expect(node_module.reload.current_version_id).to be_nil
    end
  end
end
