# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::SpawnPlatformService, type: :service do
  let(:account) { create(:account) }
  let(:user)    { create(:user, account: account) }

  let(:target) { { template_id: "powernode-hub", region: "us-west" } }
  let(:parent_url) { "https://parent.alice.tld" }

  describe ".spawn!" do
    context "managed_child mode" do
      it "creates a FederationPeer in proposed status with spawn_role=parent" do
        result = described_class.spawn!(
          account: account, spawn_mode: "managed_child",
          spawn_target: target, parent_url: parent_url,
          initiated_by_user: user
        )
        expect(result.ok?).to be true
        peer = result.federation_peer
        expect(peer).to be_persisted
        expect(peer.status).to eq("proposed")
        expect(peer.spawn_role).to eq("parent")
        expect(peer.spawn_mode).to eq("managed_child")
        expect(peer.peer_kind).to eq("platform")
        expect(peer.remote_instance_url).to eq(parent_url)
      end

      it "generates a single-use acceptance token + stores its digest" do
        result = described_class.spawn!(
          account: account, spawn_mode: "managed_child",
          spawn_target: target, parent_url: parent_url
        )
        expect(result.acceptance_token).to be_present
        peer = result.federation_peer.reload
        expect(peer.acceptance_token_digest).to be_present
        expect(peer.acceptance_token_expires_at).to be > Time.current
      end

      it "honors token_ttl_seconds when supplied" do
        ttl = 2.hours.to_i
        result = described_class.spawn!(
          account: account, spawn_mode: "managed_child",
          spawn_target: target, parent_url: parent_url,
          token_ttl_seconds: ttl
        )
        peer = result.federation_peer.reload
        expect(peer.acceptance_token_expires_at).to be_within(60).of(ttl.seconds.from_now)
      end

      it "builds a spawn_payload with parent_url + token + mode + parent_peer_id" do
        result = described_class.spawn!(
          account: account, spawn_mode: "managed_child",
          spawn_target: target, parent_url: parent_url,
          initiated_by_user: user
        )
        payload = result.spawn_payload
        expect(payload["parent_url"]).to eq(parent_url)
        expect(payload["acceptance_token"]).to eq(result.acceptance_token)
        expect(payload["spawn_mode"]).to eq("managed_child")
        expect(payload["parent_peer_id"]).to eq(result.federation_peer.id)
        expect(payload["initiated_by_user_id"]).to eq(user.id)
        expect(payload["contract_version"]).to eq("v1")
        expect(payload["region"]).to eq("us-west")
        expect(payload["child_template_id"]).to eq("powernode-hub")
      end
    end

    context "autonomous_peer mode" do
      it "creates a peer in autonomous_peer mode" do
        result = described_class.spawn!(
          account: account, spawn_mode: "autonomous_peer",
          spawn_target: target, parent_url: parent_url
        )
        expect(result.ok?).to be true
        expect(result.federation_peer.spawn_mode).to eq("autonomous_peer")
      end
    end

    context "cluster_member mode" do
      it "creates a peer in cluster_member mode" do
        result = described_class.spawn!(
          account: account, spawn_mode: "cluster_member",
          spawn_target: target, parent_url: parent_url
        )
        expect(result.ok?).to be true
        expect(result.federation_peer.spawn_mode).to eq("cluster_member")
      end
    end

    context "validation failures" do
      it "rejects unknown spawn_mode" do
        result = described_class.spawn!(
          account: account, spawn_mode: "fanciful",
          spawn_target: target, parent_url: parent_url
        )
        expect(result.ok?).to be false
        expect(result.error).to match(/Unknown spawn_mode/)
      end

      it "rejects spawn_target without template_id" do
        result = described_class.spawn!(
          account: account, spawn_mode: "managed_child",
          spawn_target: {}, parent_url: parent_url
        )
        expect(result.ok?).to be false
        expect(result.error).to match(/template_id/)
      end
    end

    context "with no provisioner injected" do
      it "records manual_attach_required in the peer metadata" do
        result = described_class.spawn!(
          account: account, spawn_mode: "autonomous_peer",
          spawn_target: target, parent_url: parent_url
        )
        peer = result.federation_peer.reload
        expect(peer.metadata.dig("provisioner_response", "manual_attach_required")).to be true
      end
    end

    context "with a provisioner injected" do
      let(:provisioner_response) { { "instance_id" => "abc-123", "status" => "provisioning" } }
      let(:fake_provisioner) do
        double("Provisioner").tap do |p|
          allow(p).to receive(:provision!).and_return(provisioner_response)
        end
      end

      it "calls the provisioner with payload + spawn_target" do
        described_class.spawn!(
          account: account, spawn_mode: "managed_child",
          spawn_target: target, parent_url: parent_url,
          provisioner: fake_provisioner
        )
        expect(fake_provisioner).to have_received(:provision!).with(
          payload: hash_including("spawn_mode" => "managed_child"),
          spawn_target: target
        )
      end

      it "records the provisioner response in peer metadata" do
        result = described_class.spawn!(
          account: account, spawn_mode: "managed_child",
          spawn_target: target, parent_url: parent_url,
          provisioner: fake_provisioner
        )
        expect(result.federation_peer.reload.metadata["provisioner_response"])
          .to include("instance_id" => "abc-123")
      end

      it "captures provisioner errors without losing the peer row" do
        broken_provisioner = double("BrokenProvisioner")
        allow(broken_provisioner).to receive(:provision!)
          .and_raise(StandardError, "provider quota exceeded")

        result = described_class.spawn!(
          account: account, spawn_mode: "managed_child",
          spawn_target: target, parent_url: parent_url,
          provisioner: broken_provisioner
        )
        expect(result.ok?).to be false
        expect(result.error).to match(/quota exceeded/)
        # FederationPeer row was created before the provisioner call,
        # so it persists (operator can investigate + retry).
        expect(::System::FederationPeer.where(account: account, status: "proposed").count).to eq(1)
      end
    end
  end
end
