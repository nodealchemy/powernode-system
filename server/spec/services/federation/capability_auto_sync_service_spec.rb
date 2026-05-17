# frozen_string_literal: true

require "rails_helper"

# P9 — Federation::CapabilityAutoSyncService spec.
#
# Locks the auto-flow dispatch behavior: each capability's policy
# (auto_periodic / on_match_filter / auto_on_change) maps to the
# right transport call, the sync_cursor + last_synced_at are stamped,
# manual capabilities are skipped, peers not in `active` are skipped,
# and per-capability failures don't poison the sweep.
RSpec.describe ::Federation::CapabilityAutoSyncService, type: :service do
  let(:account) { create(:account) }
  let(:peer) do
    ::System::FederationPeer.create!(
      account:             account,
      remote_instance_url: "https://peer.example.com",
      peer_kind:           "platform",
      spawn_role:          "symmetric",
      spawn_mode:          "out_of_band",
      status:              "active"
    )
  end

  def make_cap(policy:, status: "active", direction: "push_local_to_remote",
               kind: "skill", filter: {})
    target_peer = if status == "active"
                    peer
                  else
                    ::System::FederationPeer.create!(
                      account:             account,
                      remote_instance_url: "https://#{status}.example.com",
                      peer_kind:           "platform",
                      spawn_role:          "symmetric",
                      spawn_mode:          "out_of_band",
                      status:              status
                    )
                  end
    ::System::FederationCapability.create!(
      account:             account,
      federation_peer:     target_peer,
      resource_kind:       kind,
      direction:           direction,
      policy:              policy,
      filter:              filter,
      conflict_resolution: "local_wins"
    )
  end

  let(:transport_stub) do
    instance_double(::Federation::ResourceSyncTransport)
  end

  before do
    # Stub the transport so the service test stays in service-layer
    # scope (transport correctness is its own spec).
    allow(::Federation::ResourceSyncTransport).to receive(:new).and_return(transport_stub)
    allow(transport_stub).to receive(:sweep_since!).and_return(
      ::Federation::ResourceSyncTransport::Result.new(count: 0, watermark: ::Time.current, pushed_ids: [], pulled_ids: [])
    )
  end

  describe "#run!" do
    it "skips capabilities with policy=manual" do
      make_cap(policy: "manual")
      result = described_class.run!(account: account)
      expect(result.swept).to eq(0)
      expect(transport_stub).not_to have_received(:sweep_since!)
    end

    it "sweeps auto_periodic capabilities and stamps last_synced_at" do
      cap = make_cap(policy: "auto_periodic")
      now = ::Time.utc(2026, 5, 17, 12, 0, 0)
      result = described_class.run!(account: account, now: now)
      expect(result.swept).to eq(1)
      expect(result.synced).to eq(1)
      expect(transport_stub).to have_received(:sweep_since!).once
      cap.reload
      expect(cap.last_synced_at).to be_within(1.second).of(now)
      expect(cap.sync_cursor["mode"]).to eq("auto_periodic")
      expect(cap.sync_cursor["last_sweep_at"]).to eq(now.iso8601)
    end

    it "sweeps on_match_filter capabilities and records the filter used" do
      filter = { "tags" => [ "public" ] }
      cap = make_cap(policy: "on_match_filter", filter: filter)
      described_class.run!(account: account)
      cap.reload
      expect(cap.sync_cursor["mode"]).to eq("on_match_filter")
      expect(cap.sync_cursor["filter_used"]).to eq(filter)
      expect(transport_stub).to have_received(:sweep_since!).with(
        hash_including(filter: filter)
      )
    end

    it "stamps auto_on_change capabilities without dispatching transport" do
      cap = make_cap(policy: "auto_on_change")
      described_class.run!(account: account)
      cap.reload
      expect(cap.sync_cursor["mode"]).to eq("on_change_passthrough")
      expect(transport_stub).not_to have_received(:sweep_since!)
    end

    it "skips capabilities whose peer is not in `active` state" do
      make_cap(policy: "auto_periodic", status: "degraded")
      result = described_class.run!(account: account)
      expect(result.swept).to eq(1)
      expect(result.synced).to eq(0)
      expect(transport_stub).not_to have_received(:sweep_since!)
    end

    it "isolates failures per-capability (one failure doesn't poison the rest)" do
      cap_a = make_cap(policy: "auto_periodic")
      cap_b = make_cap(policy: "auto_periodic", kind: "trading_strategy")
      # Stub the second transport call to raise
      call_count = 0
      allow(transport_stub).to receive(:sweep_since!) do
        call_count += 1
        raise "boom" if call_count == 1
        ::Federation::ResourceSyncTransport::Result.new(count: 0, watermark: ::Time.current, pushed_ids: [], pulled_ids: [])
      end

      result = described_class.run!(account: account)
      expect(result.swept).to eq(2)
      expect(result.synced).to eq(1)
      expect(result.failed).to eq(1)
      expect(result.failures.size).to eq(1)
      expect(result.failures.first[:error]).to include("RuntimeError: boom")
    end
  end

  describe "scoping" do
    it "scopes by peer when peer: arg is passed" do
      other_peer = ::System::FederationPeer.create!(
        account: account, remote_instance_url: "https://other.example.com",
        peer_kind: "platform", spawn_role: "symmetric", spawn_mode: "out_of_band",
        status: "active"
      )
      ::System::FederationCapability.create!(
        account: account, federation_peer: other_peer, resource_kind: "skill",
        direction: "push_local_to_remote", policy: "auto_periodic",
        conflict_resolution: "local_wins"
      )
      make_cap(policy: "auto_periodic")  # in `peer`
      result = described_class.run!(peer: peer)
      expect(result.swept).to eq(1)
    end
  end
end
