# frozen_string_literal: true

require "rails_helper"

# IMP-43cf1e6b5541: Sdwan::VirtualIp#failover! (before this task) could
# leave a demoted holder stuck in holder_peer_ids on a non-anycast VIP —
# a phantom holder with no Sdwan::VirtualIpAssignment history row.
# VirtualIpPhantomHolderBackfillService is the one-time sweep that gives
# each pre-existing phantom its history row, invoked via
# `rake sdwan:backfill_phantom_vip_holders`.
RSpec.describe Sdwan::VirtualIpPhantomHolderBackfillService, type: :service do
  let(:account) { Account.first || create(:account) }
  let(:network) { Sdwan::Network.create!(account_id: account.id, name: "backfill-net-#{SecureRandom.hex(3)}") }
  let(:primary) { create(:sdwan_peer, account: account, network: network) }
  let(:phantom) { create(:sdwan_peer, account: account, network: network) }

  describe ".call" do
    it "creates a phantom_backfill assignment row for a stray non-primary holder" do
      vip = create(:sdwan_virtual_ip, account: account, network: network, anycast: false,
                   holder_peer_ids: [ primary.id ], state: "active")
      # Simulate pre-existing phantom-holder debris — bypasses the
      # on-change validation this task added, exactly as a legacy write
      # from before that validation existed would have.
      vip.update_columns(holder_peer_ids: [ primary.id, phantom.id ])

      result = described_class.call

      row = Sdwan::VirtualIpAssignment.where(sdwan_virtual_ip_id: vip.id, sdwan_peer_id: phantom.id).first
      expect(row).to be_present
      expect(row.reason).to eq("phantom_backfill")
      expect(row).to be_active
      expect(result.backfilled_count).to eq(1)
      expect(result.errors).to be_empty
    end

    it "does not touch the primary holder (index 0)" do
      vip = create(:sdwan_virtual_ip, account: account, network: network, anycast: false,
                   holder_peer_ids: [ primary.id ], state: "active")
      vip.update_columns(holder_peer_ids: [ primary.id, phantom.id ])

      described_class.call

      expect(Sdwan::VirtualIpAssignment.where(sdwan_virtual_ip_id: vip.id, sdwan_peer_id: primary.id)).not_to exist
    end

    it "is idempotent — re-running after a successful backfill does nothing further" do
      vip = create(:sdwan_virtual_ip, account: account, network: network, anycast: false,
                   holder_peer_ids: [ primary.id ], state: "active")
      vip.update_columns(holder_peer_ids: [ primary.id, phantom.id ])
      described_class.call

      result = described_class.call

      expect(result.backfilled_count).to eq(0)
      expect(Sdwan::VirtualIpAssignment.where(sdwan_virtual_ip_id: vip.id, sdwan_peer_id: phantom.id).count).to eq(1)
    end

    it "skips a VIP with a single holder (nothing stray to backfill)" do
      create(:sdwan_virtual_ip, account: account, network: network, anycast: false,
             holder_peer_ids: [ primary.id ], state: "active")

      result = described_class.call

      expect(result.backfilled_count).to eq(0)
      expect(result.errors).to be_empty
    end

    it "skips anycast VIPs (multiple holders is legitimate there)" do
      other = create(:sdwan_peer, account: account, network: network)
      create(:sdwan_virtual_ip, account: account, network: network, anycast: true,
             holder_peer_ids: [ primary.id, other.id ], state: "active")

      result = described_class.call

      expect(result.backfilled_count).to eq(0)
    end

    it "does not re-open a stray holder that already has an active assignment row" do
      vip = create(:sdwan_virtual_ip, account: account, network: network, anycast: false,
                   holder_peer_ids: [ primary.id ], state: "active")
      vip.update_columns(holder_peer_ids: [ primary.id, phantom.id ])
      existing = vip.assignments.create!(peer: phantom, assumed_at: 1.hour.ago, reason: "holder_changed")

      result = described_class.call

      expect(result.backfilled_count).to eq(0)
      expect(Sdwan::VirtualIpAssignment.where(sdwan_virtual_ip_id: vip.id, sdwan_peer_id: phantom.id).count).to eq(1)
      expect(existing.reload.reason).to eq("holder_changed")
    end

    it "records a per-peer error and keeps going when one peer id no longer resolves" do
      vip_a = create(:sdwan_virtual_ip, account: account, network: network, anycast: false,
                     holder_peer_ids: [ primary.id ], state: "active")
      vip_a.update_columns(holder_peer_ids: [ primary.id, phantom.id ])
      missing_id = SecureRandom.uuid
      vip_b = create(:sdwan_virtual_ip, account: account, network: network, anycast: false,
                     holder_peer_ids: [ primary.id ], state: "active")
      vip_b.update_columns(holder_peer_ids: [ primary.id, missing_id ])

      result = described_class.call

      expect(result.backfilled_count).to eq(1)
      expect(result.errors.size).to eq(1)
      expect(result.errors.first).to include(vip_b.id, missing_id)
      expect(Sdwan::VirtualIpAssignment.where(sdwan_virtual_ip_id: vip_a.id, sdwan_peer_id: phantom.id)).to exist
    end
  end
end
