# frozen_string_literal: true

require "rails_helper"

# IMP-134062908364 (Part A) — the account anchor for a record CreateVirtualIp
# resolves ITSELF. #perform did an unscoped `Sdwan::Network.find`, so a
# dispatched create naming a foreign network_id allocated a VIP straight into
# another account's overlay. `attrs` strips account_id (Base::TENANCY_ATTRIBUTE_KEYS),
# so account_id is nil at validation time and Sdwan::VirtualIp's
# `before_validation :inherit_account_from_network` stamps the FOREIGN network's
# account — the row is created fully owned by the victim, inside the victim's
# network, and Sdwan::TopologyCompiler advertises it in the victim's iBGP. A
# create has no source_type/source_id pair for
# Ai::DeferredOperation#assert_source_within_account! to catch. The live caller
# System::Ai::Skills::ServiceDiscoveryComposerExecutor passes
# deferred_operation: nil, where resolve_scoped's documented unscoped passthrough
# applies; the sharp caller is MultiTenantIsolationExecutor, which passes a
# CompositionContext carrying its account — the anchor the bare .find discarded.
RSpec.describe Sdwan::Executors::CreateVirtualIp do
  let(:account) { create(:account) }

  # Minimal VALID VIP attributes: advertised_med/advertised_local_pref carry
  # numericality validations with no attribute default on this path, so they
  # must be present for the UN-fixed code to actually persist the row — a
  # validation error would make the red test pass for the wrong reason.
  # holder_peer_ids is omitted so the holder-belongs-to-network validation stays
  # out of the picture.
  let(:vip_attributes) do
    { name: "svc-vip", cidr: "fd00:beef::1/128", state: "active",
      anycast: false, advertised_med: 100, advertised_local_pref: 100 }
  end

  describe "account anchoring" do
    let(:operation) do
      ::Ai::DeferredOperation.create!(
        account: account, action_category: "sdwan.virtual_ip_create",
        executor_class: described_class.name, params: {}
      )
    end

    it "refuses to allocate a VIP in a network belonging to another account" do
      foreign = create(:sdwan_network)

      # Effect first, error identity second: a leading raise_error matcher would
      # abort on the un-fixed code and never report the planted VIP.
      raised = begin
        described_class.execute(
          { network_id: foreign.id, attributes: vip_attributes },
          deferred_operation: operation
        )
        nil
      rescue StandardError => e
        e
      end

      expect(foreign.virtual_ips.count).to eq(0),
                                           "a dispatched create allocated a VIP in another account's network"
      expect(raised).to be_a(::Ai::DeferredOperation::CrossAccountError)
      expect(raised.message).to include(account.id),
                                "the refusal must name the caller's OWN account"
      expect(raised.message).not_to include(foreign.account_id),
                                    "the refusal must not name the victim's account"
    end

    it "allocates the VIP when the network belongs to the operation's account" do
      network = create(:sdwan_network, account: account)

      result = described_class.execute(
        { network_id: network.id, attributes: vip_attributes },
        deferred_operation: operation
      )

      expect(result[:success]).to be true
      vip = ::Sdwan::VirtualIp.find(result[:data][:vip_id])
      expect(vip.sdwan_network_id).to eq(network.id)
      expect(vip.account_id).to eq(account.id)
    end
  end

  # ServiceDiscoveryComposerExecutor:306 reaches this executor with
  # deferred_operation: nil — a legitimately account-less caller (the composer
  # runs unscoped). resolve_scoped passes through unscoped when there is no
  # account to anchor on, so the fix must NOT change that path.
  describe "unscoped composer path (deferred_operation: nil)" do
    it "honors the intentional passthrough and does not refuse on account" do
      network = create(:sdwan_network)

      result = described_class.execute(
        { network_id: network.id, attributes: vip_attributes },
        deferred_operation: nil
      )

      expect(result[:success]).to be true
      expect(::Sdwan::VirtualIp.find(result[:data][:vip_id]).sdwan_network_id).to eq(network.id)
    end
  end
end
