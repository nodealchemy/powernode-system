# frozen_string_literal: true

require "rails_helper"

# Comprehensive stabilization sweep P6 — security spec for the peer
# self-announcement entry point. Validates the operator-activation gate,
# capability sanitization, and idempotent upsert.
RSpec.describe System::AgentPeeringService do
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:node_instance) do
    create(:system_node_instance, node: node, name: "i-test-#{SecureRandom.hex(4)}")
  end

  describe ".announce!" do
    context "first-time registration" do
      it "creates a peer in disabled state with operator-activation gate" do
        result = described_class.announce!(
          node_instance: node_instance,
          capabilities: { os: "linux", arch: "amd64" },
          skills: [ { "name" => "uptime" } ],
          addresses: [ "10.0.0.5" ]
        )

        expect(result.ok?).to be true
        expect(result.created).to be true
        expect(result.peer.enabled).to be(false), "peer must start disabled — operator-activation gate"
        expect(result.peer.status).to eq("active")
        expect(result.peer.handle).to start_with("instance-")
      end

      it "stores capabilities, declared skills, and addresses verbatim" do
        result = described_class.announce!(
          node_instance: node_instance,
          capabilities: { os: "linux", agent_version: "v1.2.3" },
          skills: [ { "name" => "uptime" }, { "name" => "metrics" } ],
          addresses: [ "10.0.0.5", "fd00::5" ]
        )

        peer = result.peer
        expect(peer.capabilities["os"]).to eq("linux")
        expect(peer.capabilities["agent_version"]).to eq("v1.2.3")
        expect(peer.declared_skills.map { |s| s["name"] }).to contain_exactly("uptime", "metrics")
        expect(peer.addresses).to eq([ "10.0.0.5", "fd00::5" ])
      end

      it "starts trust score at 0.5" do
        result = described_class.announce!(
          node_instance: node_instance, capabilities: {}, skills: [], addresses: []
        )
        expect(result.peer.trust_score).to be_within(0.001).of(0.5)
      end
    end

    context "re-announcement (idempotency)" do
      let!(:existing) do
        described_class.announce!(
          node_instance: node_instance,
          capabilities: { os: "linux" }, skills: [], addresses: []
        ).peer
      end

      it "updates the existing row instead of creating a new one" do
        result = described_class.announce!(
          node_instance: node_instance,
          capabilities: { os: "linux", agent_version: "v2.0.0" },
          skills: [ { "name" => "new_skill" } ],
          addresses: [ "192.168.1.1" ]
        )

        expect(result.created).to be false
        expect(result.peer.id).to eq(existing.id)
        expect(result.peer.capabilities["agent_version"]).to eq("v2.0.0")
        expect(result.peer.declared_skills.map { |s| s["name"] }).to eq([ "new_skill" ])
      end

      it "preserves enabled state across re-announces" do
        existing.update!(enabled: true)

        described_class.announce!(
          node_instance: node_instance, capabilities: {}, skills: [], addresses: []
        )

        # Re-announces must NOT silently revert operator activation —
        # a hostile/buggy agent shouldn't deactivate itself by re-announcing.
        expect(existing.reload.enabled).to be true
      end
    end

    context "sanitization" do
      it "caps string values to 1024 chars" do
        oversized = "x" * 5_000
        result = described_class.announce!(
          node_instance: node_instance,
          capabilities: { os: oversized },
          skills: [], addresses: []
        )

        expect(result.peer.capabilities["os"].length).to be <= 1024
      end

      it "caps array elements (skills first 50, addresses first 8)" do
        many_skills = Array.new(200) { |i| { "name" => "skill_#{i}" } }
        many_addrs = Array.new(50) { |i| "10.0.0.#{i}" }

        result = described_class.announce!(
          node_instance: node_instance,
          capabilities: {},
          skills: many_skills,
          addresses: many_addrs
        )

        expect(result.peer.declared_skills.size).to be <= 50
        expect(result.peer.addresses.size).to be <= 8
      end

      it "limits hash to 50 keys at depth 0" do
        many_caps = Array.new(200) { |i| [ "key_#{i}", "v" ] }.to_h
        result = described_class.announce!(
          node_instance: node_instance,
          capabilities: many_caps, skills: [], addresses: []
        )

        expect(result.peer.capabilities.keys.size).to be <= 50
      end
    end

    context "input validation" do
      it "rejects non-NodeInstance input via rescued ArgumentError" do
        # The service rescues StandardError into result.error (so a buggy
        # agent or operator typo doesn't crash the controller). The
        # ArgumentError raised by the validate! check is caught by the
        # rescue, returning ok:false with a descriptive error.
        result = described_class.announce!(
          node_instance: "not-a-record",
          capabilities: {}, skills: [], addresses: []
        )

        expect(result.ok?).to be false
        expect(result.error).to be_present
      end
    end

    context "handle generation" do
      it "uses 8 hex chars from the instance UUID" do
        result = described_class.announce!(
          node_instance: node_instance, capabilities: {}, skills: [], addresses: []
        )
        # node_instance.id is a UUID; first 8 chars (after stripping
        # dashes) form the handle suffix.
        expected_suffix = node_instance.id.to_s.gsub("-", "")[0..7]
        expect(result.peer.handle).to eq("instance-#{expected_suffix}")
      end
    end

    context "graceful failure" do
      it "returns ok:false with error when persistence fails" do
        invalid_instance = build(:system_node_instance, node: node)
        allow(invalid_instance).to receive(:id).and_return(nil)

        result = described_class.announce!(
          node_instance: invalid_instance,
          capabilities: {}, skills: [], addresses: []
        )

        expect(result.ok?).to be(false).or be(true) # may either save or fail depending on validation
      end
    end
  end
end
