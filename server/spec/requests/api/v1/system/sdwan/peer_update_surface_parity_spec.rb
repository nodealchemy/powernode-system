# frozen_string_literal: true

require "rails_helper"

# IMP-4ed94eef2971 — one writable list, two update surfaces.
#
# PeersController#update gates the WHOLE peer field set through
# Sdwan::Executors::UpdatePeer. The MCP surface exposed only two single-field
# setters (update_peer_lan_subnets, set_peer_tags), so an agent remediating a
# wrong endpoint, or correcting a peer's hub election, had no MCP path at all —
# the parity gap was seven fields wide.
#
# WHY THIS FILE EXISTS given that both surfaces now read one constant
# (Sdwan::Peer::UPDATE_*_ATTRIBUTES). "Reads the constant" is not the property
# that matters; "every attribute in the list actually REACHES the executor from
# BOTH surfaces, and nothing outside the list does" is, and that stays forgeable
# — an arm can re-inline a literal, drop a key between the slice and the gate,
# or permit a shape the twin refuses. Every example below drives a real call and
# reads the ATTRIBUTES THE GATE PARKED, so it fails on any of those without
# knowing which happened. Same construction as
# port_mapping_surface_parity_spec.rb (IMP-2c531ddb5a0c).
#
# The NAMES are pinned LITERALLY below rather than derived from the constant.
# Deriving them would move the oracle with the production list: emptying or
# renaming the constant would move both together and every example would still
# pass, which is exactly the mutant this file has to catch.
RSpec.describe "SDWAN peer update surface parity", type: :request do
  let(:account)    { create(:account) }
  let(:manager)    { user_with_permissions("system.sdwan.peers.manage", "system.sdwan.peers.read", account: account) }
  let(:network)    { create(:sdwan_network, account: account) }
  let!(:peer)      { create(:sdwan_peer, account: account, network: network, tags: []) }
  let(:tool)       { ::Ai::Tools::SdwanTool.new(account: account, internal: true) }

  def member_path = "/api/v1/system/sdwan/networks/#{network.id}/peers/#{peer.id}"

  # THE CONTRACT, stated independently of the code under test. This is the
  # field set PeersController#peer_update_params has permitted since slice 7a,
  # and it is what the MCP arm must accept — no more (a widened permit list is
  # a widened attack surface, and publicly_reachable in particular is the
  # hub-election flag) and no less (a missing field re-creates the parity gap
  # one field smaller).
  let(:expected_option_names) do
    %i[
      publicly_reachable
      endpoint_host
      endpoint_host_v6
      endpoint_host_v4
      endpoint_port
      listen_port
      bgp_route_reflector_client
      lan_subnets
      tags
      capabilities
    ]
  end

  # Every writable field in ONE payload, with values that survive validation
  # together. publicly_reachable: true drags the hub_must_have_endpoint
  # validation in, which the endpoint fields satisfy.
  let(:full_attributes) do
    {
      publicly_reachable: true,
      endpoint_host: "hub.example.test",
      endpoint_host_v6: "fd00:abcd:1::9",
      endpoint_host_v4: "203.0.113.9",
      endpoint_port: 51_821,
      listen_port: 51_822,
      bgp_route_reflector_client: true,
      lan_subnets: [ "10.10.0.0/16" ],
      tags: [ "edge" ],
      capabilities: { "wireguard" => "1.0" }
    }
  end

  # Keys no surface may accept. Tenancy and parentage are resolved from the
  # route/account by the executor, never from caller input; the rest are
  # platform-written.
  let(:forbidden_attributes) do
    {
      id: SecureRandom.uuid,
      account_id: create(:account).id,
      sdwan_network_id: create(:sdwan_network).id,
      node_instance_id: create(:system_node_instance).id,
      assigned_address: "fd00:dead:beef::1",
      status: "active",
      last_handshake_at: 1.day.ago.iso8601,
      metadata: { "injected" => true }
    }
  end

  def parked_attributes(deferred_id = nil)
    deferred = deferred_id ? ::Ai::DeferredOperation.find_by(id: deferred_id)
                           : ::Ai::DeferredOperation.order(created_at: :desc).first
    expect(deferred).to be_present, "the write did not route through the autonomy gate"
    expect(deferred.action_category).to eq(::Sdwan::Executors::UpdatePeer::ACTION_CATEGORY)
    expect(deferred.executor_class).to eq("Sdwan::Executors::UpdatePeer")
    deferred.params.fetch("attributes")
  end

  def mcp_update(options)
    tool.execute(params: { action: "system_sdwan_update_peer", peer_id: peer.id, options: options })
  end

  def rest_update(attrs, as: manager)
    patch member_path, params: { peer: attrs }.to_json,
          headers: auth_headers_for(as).merge("Content-Type" => "application/json")
  end

  it "exercises every field the contract names" do
    expect(full_attributes.keys).to match_array(expected_option_names),
                                    "a field was added to the contract without a value here, so no " \
                                    "example below proves it reaches either surface"
  end

  describe "REST update (the twin being mirrored)" do
    it "carries exactly the contract to the executor and drops everything else" do
      rest_update(full_attributes.merge(forbidden_attributes))

      expect(response).to have_http_status(:accepted)
      attrs = parked_attributes
      expect(attrs.keys.map(&:to_sym)).to match_array(expected_option_names)
      expect(attrs.keys).not_to include(*forbidden_attributes.keys.map(&:to_s))
    end
  end

  describe "MCP update" do
    it "carries exactly the contract to the executor and drops everything else" do
      result = mcp_update(full_attributes.merge(forbidden_attributes))

      expect(result[:success]).to be(true), "MCP update refused the full writable payload: #{result[:error]}"
      attrs = parked_attributes(result.dig(:data, :deferred_operation_id))
      expect(attrs.keys.map(&:to_sym)).to match_array(expected_option_names)
      expect(attrs.keys).not_to include(*forbidden_attributes.keys.map(&:to_s))
    end

    # The both-directions comparison, on the PARKED attributes rather than on
    # the permit lists — the parked hash is what the executor replays, so this
    # is the only place the two surfaces can be observed agreeing.
    it "parks the same attribute set REST parks for the same payload" do
      rest_update(full_attributes)
      expect(response).to have_http_status(:accepted)
      rest_attrs = parked_attributes

      result = mcp_update(full_attributes)
      mcp_attrs = parked_attributes(result.dig(:data, :deferred_operation_id))

      expect(mcp_attrs.keys).to match_array(rest_attrs.keys),
                                "the MCP arm and peer_update_params disagree about the field set"
      expected_option_names.each do |field|
        expect(mcp_attrs[field.to_s]).to eq(rest_attrs[field.to_s]),
                                         "#{field} reached the executor differently from the two surfaces"
      end
    end

    # The joined list is parsed back out rather than substring-matched:
    # `include("endpoint_host")` passes on `endpoint_host_v6` alone, and no
    # substring assertion can fail on a WIDENED list, which is the mutant that
    # matters most for a field set containing the hub-election flag.
    it "advertises exactly the contract in its tool schema" do
      described = ::Ai::Tools::SdwanTool.action_definitions
                                        .fetch("system_sdwan_update_peer")
                                        .dig(:parameters, :options, :description)

      advertised = described[/fields to update: ([^.]+)\./, 1].to_s
                   .split(",").map { |f| f.strip.to_sym }
      expect(advertised).to match_array(expected_option_names)
    end

    # The REST twin's permission. An arm that gates a field set on a LOWER
    # permission than the surface it mirrors is a privilege-escalation path
    # around that surface.
    it "requires the same permission REST requires" do
      expect(::Ai::Tools::SdwanTool::ACTION_PERMISSIONS.fetch("system_sdwan_update_peer"))
        .to eq("system.sdwan.peers.manage")
    end

    # Swapping account_peers.find for a bare Sdwan::Peer.find would still be
    # fenced at WRITE time by the executor's resolve_scoped — but the pre-gate
    # valid? and the parked `description:` would run against a foreign
    # account's peer, naming it on this account's approval card. That is the
    # IMP-4a5094b22df0 defect, and only an example that crosses the account
    # boundary can see it.
    it "refuses a peer belonging to another account" do
      foreign = create(:sdwan_peer)

      expect {
        result = tool.execute(params: { action: "system_sdwan_update_peer",
                                        peer_id: foreign.id, options: full_attributes })
        expect(result[:success]).to be false
      }.not_to change(::Ai::DeferredOperation, :count)

      expect(foreign.reload.publicly_reachable).to be(false)
    end

    # normalize_tags is a before_validation, so the value the executor
    # persists is not the value the caller sent. The approval card renders the
    # PARKED attributes, so parking the raw input shows an approver something
    # other than what approving it writes. set_peer_tags has parked normalized
    # since it was gated; this pins that the general arm agrees.
    it "parks the tags the executor will actually persist, not the raw input" do
      result = mcp_update(full_attributes.merge(tags: [ "  Edge  ", "Edge", "" ]))

      expect(result[:success]).to be(true), result[:error].to_s
      expect(parked_attributes(result.dig(:data, :deferred_operation_id))["tags"]).to eq([ "Edge" ])

      approve_latest_deferred!
      expect(peer.reload.tags).to eq([ "Edge" ])
    end

    # A `type: "object"` parameter routinely arrives as a JSON string from a
    # model that guessed the encoding. Unguarded, to_h raises past every
    # rescue and the caller gets a 500 rather than a field error.
    [ %q({"publicly_reachable":true}), [ "publicly_reachable" ], 7 ].each do |bad|
      it "refuses a non-object options (#{bad.class}) with an error, not an exception" do
        result = nil
        expect { result = mcp_update(bad) }.not_to raise_error
        expect(result[:success]).to be false
        expect(result[:error]).to include("object")
      end
    end

    it "names exactly the accepted set when a payload has no recognized field" do
      result = mcp_update(forbidden_attributes)

      expect(result[:success]).to be false
      named = result[:error].split("permitted (options):").last.split(",").map { |s| s.strip.to_sym }
      expect(named).to match_array(expected_option_names)
    end

    it "applies the whole set once the parked operation is approved" do
      result = mcp_update(full_attributes)
      expect(result[:success]).to be(true), result[:error].to_s
      expect(peer.reload.publicly_reachable).to be(false), "the peer changed without an approval gate"

      approve_latest_deferred!

      peer.reload
      expect(peer.publicly_reachable).to be(true)
      expect(peer.endpoint_host).to eq("hub.example.test")
      expect(peer.endpoint_host_v6).to eq("fd00:abcd:1::9")
      expect(peer.endpoint_host_v4).to eq("203.0.113.9")
      expect(peer.endpoint_port).to eq(51_821)
      expect(peer.listen_port).to eq(51_822)
      expect(peer.bgp_route_reflector_client).to be(true)
      expect(peer.lan_subnets).to eq([ "10.10.0.0/16" ])
      expect(peer.tags).to eq([ "edge" ])
      expect(peer.capabilities).to eq({ "wireguard" => "1.0" })
    end
  end

  # publicly_reachable is the HUB-ELECTION flag: NodeApi::SdwanController
  # derives hubbed_network_ids from Sdwan::Peer.where(node_instance_id:,
  # publicly_reachable: true), and the topology strategies partition hubs from
  # spokes on it. This arm can flip it on an already-enrolled peer, which no
  # MCP arm could before — attach_peer accepts the flag but the network+
  # instance unique index means it only ever reaches a peer that does not yet
  # exist.
  #
  # BOTH policy tiers are driven deliberately, because the honest answer
  # differs between them and only one of them is what a seeded install runs.
  # A spec that asserted `pending: true` alone would read as "hub election is
  # behind human review" while describing only the unseeded TEST default.
  describe "hub election" do
    let(:hub_attrs) { { publicly_reachable: true, endpoint_host_v6: "fd00:abcd:1::9", endpoint_port: 51_820 } }

    it "parks the election where the operator has tiered the category up" do
      result = mcp_update(hub_attrs)

      expect(result[:success]).to be(true), result[:error].to_s
      expect(result.dig(:data, :pending)).to be(true)
      expect(::Sdwan::Peer.where(node_instance_id: peer.node_instance_id, publicly_reachable: true))
        .to be_empty, "the peer was elected a hub with no approval under require_approval"
    end

    # THE STATED CONSEQUENCE. PolicyDeclarations::SDWAN_OPERATOR_POLICIES declares
    # sdwan.peer_update notify_and_proceed for the agent-less
    # scope-"action_type" audience — the one an operator or MCP caller
    # resolves against — so on a seeded install this arm elects a hub
    # IMMEDIATELY, with a notification and no approval. That is the existing
    # tier for the category (REST peers#update has always had it), not
    # something this arm chose, and it is pinned here so re-tiering the
    # category is a deliberate, visible change rather than a silent one.
    it "elects the hub IMMEDIATELY under the tier a seeded install actually runs" do
      seed_operator_policy!(::Sdwan::Executors::UpdatePeer::ACTION_CATEGORY)

      result = mcp_update(hub_attrs)

      expect(result[:success]).to be(true), result[:error].to_s
      expect(result.dig(:data, :pending)).to be_falsey
      expect(peer.reload.publicly_reachable).to be(true)
      expect(::Sdwan::Peer.where(node_instance_id: peer.node_instance_id, publicly_reachable: true))
        .to include(peer), "hubbed_network_ids now resolves this network for the peer's instance"
    end
  end

  # IMP-785d60f5ec3e's invariant, applied to this arm: a payload that could
  # only ever fail must not park a deferred operation an operator has to
  # dispose of, and the verdict must track the REQUEST, not the account's
  # policy tier. Ai::AutonomyGate#evaluate creates the DeferredOperation row
  # BEFORE it branches on policy, so `not_to change` proves the gate was never
  # reached rather than merely that nothing happened.
  describe "an invalid payload" do
    # endpoint_port is out of range for the model's numericality check and
    # involves no fixture, so the identical bytes go to both policy tiers.
    let(:invalid_attrs) { { endpoint_port: 99_999 } }

    it "opens no deferred operation under a PARKING policy" do
      expect { mcp_update(invalid_attrs) }.not_to change(::Ai::DeferredOperation, :count)
    end

    it "opens no deferred operation under a PROCEEDING policy" do
      seed_operator_policy!(::Sdwan::Executors::UpdatePeer::ACTION_CATEGORY)

      expect { mcp_update(invalid_attrs) }.not_to change(::Ai::DeferredOperation, :count)
    end

    it "mints no approval request for an operation that could never run" do
      expect { mcp_update(invalid_attrs) }.not_to change(::Ai::ApprovalRequest, :count)
    end

    it "answers the SAME verdict under both policy tiers" do
      parked = mcp_update(invalid_attrs)

      seed_operator_policy!(::Sdwan::Executors::UpdatePeer::ACTION_CATEGORY)
      proceeding = mcp_update(invalid_attrs)

      expect(parked[:success]).to eq(proceeding[:success]),
                                  "the same payload answered differently under a parking policy and a " \
                                  "proceeding one — the verdict tracked the policy, not the request"
      expect(parked[:success]).to be false
    end

    it "names the field the caller has to fix, rather than the gate" do
      result = mcp_update(invalid_attrs)

      expect(result[:error]).to match(/endpoint port/i)
      expect(result[:error]).not_to include("Gate evaluation failed")
    end

    it "leaves the row untouched" do
      expect { mcp_update(invalid_attrs) }.not_to(change { peer.reload.updated_at })
    end
  end

  # The pending offer on the port-mapping arms: a mis-shaped value for a
  # non-scalar field must be refused by the permit layer rather than reaching
  # a NOT NULL column (tags, capabilities and publicly_reachable are all
  # `null: false`). REST's strong parameters drops a non-array for an
  # array-declared key and a non-hash for a hash-declared one; the MCP arm has
  # to do the same, which is what makes the two surfaces one contract.
  describe "mis-shaped non-scalar values" do
    [
      { tags: "edge" },
      { tags: nil },
      { lan_subnets: "10.0.0.0/8" },
      { lan_subnets: nil },
      { capabilities: [ "wireguard" ] },
      { capabilities: nil }
    ].each do |bad|
      field = bad.keys.first
      it "drops #{field} when it arrives as #{bad[field].inspect} rather than parking it" do
        result = mcp_update(full_attributes.merge(bad))

        if result[:success]
          attrs = parked_attributes(result.dig(:data, :deferred_operation_id))
          expect(attrs).not_to have_key(field.to_s),
                               "a mis-shaped #{field} was parked and will reach a NOT NULL column at " \
                               "approval time"
          # The parked operation must survive approval. Executing it is the
          # only assertion here that can actually red — the row cannot be nil
          # before approval whatever the permit layer did, because no path in
          # this arm saves.
          expect { approve_latest_deferred! }.not_to raise_error
        else
          expect(result[:error]).not_to include("Gate evaluation failed")
        end
        expect(::Sdwan::Peer.find(peer.id).public_send(field)).not_to be_nil
      end
    end

    # publicly_reachable and bgp_route_reflector_client are `null: false`
    # scalars, so strong parameters keeps an explicit nil (it is a permitted
    # scalar) and only the model can refuse it. Both surfaces are driven here:
    # this was open on REST too, and a fix that closed only the new arm would
    # leave the identical payload parking a doomed approval over HTTP.
    %i[publicly_reachable bgp_route_reflector_client].each do |field|
      it "refuses a NULL #{field} from MCP rather than parking it" do
        expect { mcp_update(field => nil) }.not_to change(::Ai::DeferredOperation, :count)
      end

      it "refuses a NULL #{field} from REST rather than parking it" do
        expect { rest_update({ field => nil }) }.not_to change(::Ai::DeferredOperation, :count)

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  # Two paths to one field is how the SDWAN CRUD triplication started, so the
  # overlap is deliberate and stated. The single-field setters are KEPT: they
  # gate on system.sdwan.routing.manage (lan_subnets) and answer routing-shaped
  # payloads (advertisement_count / normalized tags) that this general arm does
  # not, and they are a published contract existing agents call. What must hold
  # is that all three land on ONE action category and ONE executor, so no path
  # is a policy bypass of another.
  describe "overlap with the single-field setters" do
    it "routes all three arms through one category and one executor" do
      subnets = tool.execute(params: { action: "system_sdwan_update_peer_lan_subnets",
                                       peer_id: peer.id, lan_subnets: [ "10.9.0.0/16" ] })
      expect(parked_attributes(subnets.dig(:data, :deferred_operation_id)).keys).to eq([ "lan_subnets" ])

      tagged = tool.execute(params: { action: "system_sdwan_set_peer_tags",
                                      peer_id: peer.id, tags: [ "edge" ] })
      expect(parked_attributes(tagged.dig(:data, :deferred_operation_id)).keys).to eq([ "tags" ])

      general = mcp_update(full_attributes)
      expect(parked_attributes(general.dig(:data, :deferred_operation_id)).keys.map(&:to_sym))
        .to match_array(expected_option_names)
    end

    it "keeps the routing setter on the routing permission" do
      expect(::Ai::Tools::SdwanTool::ACTION_PERMISSIONS.fetch("system_sdwan_update_peer_lan_subnets"))
        .to eq("system.sdwan.routing.manage")
    end
  end
end
