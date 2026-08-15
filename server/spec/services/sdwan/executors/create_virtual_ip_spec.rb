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

    # IMP-6c482005db87 gated the operator surfaces (REST + MCP) — the gate
    # lives at those call sites, NOT inside this executor. Internal
    # composition (ServiceDiscoveryComposerExecutor, and the MTI executor for
    # the firewall sibling) keeps calling .execute synchronously, ungated:
    # the executor itself must never open an approval or deferred-operation
    # row.
    it "performs immediately for the composer and opens no approval-gate rows" do
      network = create(:sdwan_network)
      peer = create(:sdwan_peer, account: network.account, network: network)

      result = described_class.execute(
        { network_id: network.id,
          attributes: vip_attributes.merge(cidr: "fd00:beef::7/128", holder_peer_ids: [ peer.id ]) },
        deferred_operation: nil
      )

      expect(result[:success]).to be true
      expect(::Ai::DeferredOperation.count).to eq(0),
                                               "the executor itself opened a deferred-operation row — gating belongs to the surfaces"
      expect(::Ai::ApprovalRequest.count).to eq(0)
      # The create primitive is the same on every path: the composer's VIP
      # gets the assignment audit row too, attributed to no user.
      vip = ::Sdwan::VirtualIp.find(result[:data][:vip_id])
      expect(vip.assignments.count).to eq(1)
      expect(vip.assignments.first.triggered_by_user_id).to be_nil
    end
  end

  # IMP-6c482005db87 — the create ceremony travels WITH the write. The two
  # surfaces used to activate a holder-bearing VIP and open the slice-9b
  # initial assignment row inline AFTER save; on the gate's :pending branch
  # the executor is the only writer, so both belong here — otherwise an
  # approved create yields a phantom holder with no history row and a VIP
  # stuck "pending".
  describe "state activation + initial assignment bootstrap" do
    let(:network) { create(:sdwan_network, account: account) }
    let(:peer_a)  { create(:sdwan_peer, account: account, network: network) }
    let(:peer_b)  { create(:sdwan_peer, account: account, network: network) }
    let(:requester) { create(:user, account: account) }
    let(:operation) do
      ::Ai::DeferredOperation.create!(
        account: account, action_category: "sdwan.virtual_ip_create",
        executor_class: described_class.name, params: {}, requested_by: requester
      )
    end

    def execute!(attributes)
      described_class.execute(
        { network_id: network.id, attributes: attributes },
        deferred_operation: operation
      )
    end

    it "activates a holder-bearing VIP and opens the primary holder's assignment row" do
      result = execute!(
        { name: "held-vip", cidr: "fd00:beef::2/128", anycast: false,
          holder_peer_ids: [ peer_a.id, peer_b.id ],
          advertised_med: 0, advertised_local_pref: 100 }
      )

      expect(result[:success]).to be true
      vip = ::Sdwan::VirtualIp.find(result[:data][:vip_id])
      expect(vip.state).to eq("active")
      expect(vip.assignments.count).to eq(1),
                                       "a static VIP opens ONE assignment row — the primary holder, not every listed holder"
      assignment = vip.assignments.first
      expect(assignment.sdwan_peer_id).to eq(peer_a.id)
      expect(assignment.reason).to eq("initial")
      expect(assignment.released_at).to be_nil
      expect(assignment.triggered_by_user_id).to eq(requester.id),
                                                 "attribution must survive the approval window via deferred_operation.requested_by"
    end

    it "opens one assignment row per holder for an anycast VIP" do
      result = execute!(
        { name: "anycast-vip", cidr: "fd00:beef::3/128", anycast: true,
          holder_peer_ids: [ peer_a.id, peer_b.id ],
          advertised_med: 0, advertised_local_pref: 100 }
      )

      expect(result[:success]).to be true
      vip = ::Sdwan::VirtualIp.find(result[:data][:vip_id])
      expect(vip.state).to eq("active")
      expect(vip.assignments.count).to eq(2)
      expect(vip.assignments.map(&:sdwan_peer_id)).to contain_exactly(peer_a.id, peer_b.id)
      expect(vip.assignments.map(&:reason).uniq).to eq([ "initial" ])
    end

    # Negative control: activation and assignment are HOLDER-triggered — a
    # holderless VIP must keep the column-default "pending" state and an
    # empty history, exactly as both inline surfaces behaved.
    it "leaves a holderless VIP pending with no assignment rows" do
      result = execute!(
        { name: "parked-vip", cidr: "fd00:beef::4/128", anycast: false,
          advertised_med: 0, advertised_local_pref: 100 }
      )

      expect(result[:success]).to be true
      vip = ::Sdwan::VirtualIp.find(result[:data][:vip_id])
      expect(vip.state).to eq("pending")
      expect(vip.assignments.count).to eq(0)
    end
  end

  # IMP-3a563becb7d7 — #summarize is the approval/notification body
  # (Ai::DeferredOperationApprovalContent.title and .message both render
  # preview[:summary]). It read "Allocate SDWAN VIP on network <uuid>" — a
  # bare network UUID, naming neither the VIP nor a network the operator
  # recognises. The VIP does not exist yet, so the card is composed from what
  # the request already names, mirroring CreatePeer (IMP-1eba7d50d24c).
  #
  # IMP-4a5094b22df0 changed WHAT the network lookup is scoped by: from the
  # account_id the CALLER put in the create attributes to the account of the
  # operation the gate opened. Same rationale as the CreateFirewallRule spec,
  # which carries it in full.
  describe ".preview" do
    let(:network) { create(:sdwan_network, account: account, name: "wan-core") }

    def preview_for(params)
      operation = ::Ai::DeferredOperation.create!(
        account: account, action_category: "sdwan.virtual_ip_create",
        executor_class: described_class.name, params: params
      )
      described_class.preview(params, deferred_operation: operation)
    end

    it "names the VIP and the network an operator recognises, not a bare UUID" do
      preview = preview_for({ network_id: network.id, attributes: vip_attributes })

      expect(preview[:summary]).to eq("Allocate SDWAN VIP 'svc-vip' on network wan-core")
    end

    it "does not name a network belonging to another account" do
      foreign = create(:sdwan_network, name: "someone-elses")

      # Caller-supplied account_id still asserted — the old anchor — so this
      # stays evidence that naming it no longer buys anything.
      preview = preview_for(
        { network_id: foreign.id, attributes: vip_attributes.merge(account_id: foreign.account_id) }
      )

      expect(preview[:summary]).to eq("Allocate SDWAN VIP 'svc-vip' on network #{foreign.id}")
      expect(preview[:summary]).not_to include("someone-elses")
    end

    it "degrades stepwise on a malformed request rather than raising" do
      unknown = SecureRandom.uuid

      expect(preview_for({})[:summary]).to eq("Allocate SDWAN VIP")
      # Named, in-account, no VIP name yet — the middle rung. Before
      # IMP-4a5094b22df0 this rendered the bare id, because nothing in an
      # honest request carried an account to scope the lookup by.
      expect(preview_for({ network_id: network.id })[:summary])
        .to eq("Allocate SDWAN VIP on network wan-core")
      # The id is the floor, for a network this account cannot resolve.
      expect(preview_for({ network_id: unknown })[:summary])
        .to eq("Allocate SDWAN VIP on network #{unknown}")
    end
  end
end
