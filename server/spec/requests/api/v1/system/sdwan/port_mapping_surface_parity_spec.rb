# frozen_string_literal: true

require "rails_helper"

# IMP-2c531ddb5a0c — one writable list, four arms.
#
# Sdwan::PortMapping is written from two surfaces, each with a create and an
# update arm, all four landing on the same two action categories and the same
# two executors. They used to carry four literal field lists, and the lists had
# drifted in BOTH directions: PortMappingsController#mapping_params permitted
# sdwan_peer_id and none of the hardened DNAT tier; SdwanTool's update arm
# permitted the tier and not the hub. So an operator could not set a mapping's
# hardening at all, an agent could not move one to a different hub, and the
# gating comments on both surfaces described them as enforcing one policy.
#
# WHY THIS FILE EXISTS AT ALL, given the shared constant. Making both surfaces
# read Sdwan::PortMapping::WRITABLE_ATTRIBUTES means they cannot disagree *by
# construction*, so no perturbation of one permit list can reproduce the
# original defect — but "reads the constant" is not the property that matters.
# The property is "every attribute in the list actually REACHES the executor
# from every arm", and that stays forgeable: an arm can re-inline a literal,
# translate a key wrongly, or drop a value between the slice and the gate. Each
# example below drives a real request end to end and reads the ATTRIBUTES THE
# GATE PARKED, so it fails on any of those without knowing which happened.
#
# The list-coverage guard is the addition case: `full_attributes` must name
# every writable attribute, so adding one to the model's list without proving
# it reaches both surfaces reds here rather than shipping half-wired. The
# column-classification floor beneath it (a new COLUMN reachable from neither
# surface) lives in spec/models/sdwan/port_mapping_spec.rb.
RSpec.describe "SDWAN port-mapping surface parity", type: :request do
  let(:account)   { create(:account) }
  let(:manager)   { user_with_permissions("system.sdwan.port_mappings.manage", account: account) }
  let(:network)   { create(:sdwan_network, account: account) }
  let(:hub)       { create(:sdwan_peer, :hub, account: account, network: network) }
  let(:other_hub) { create(:sdwan_peer, :hub, account: account, network: network) }
  let(:target)    { create(:sdwan_peer, account: account, network: network) }
  let(:tool)      { ::Ai::Tools::SdwanTool.new(account: account, internal: true) }

  def collection_path = "/api/v1/system/sdwan/networks/#{network.id}/port_mappings"

  # Every caller-writable attribute, with a value that survives validation
  # together with all the others. target_virtual_ip_id is explicitly nil rather
  # than omitted: exactly_one_target forbids naming both targets, so nil is the
  # only way an example can carry the key at all — and strong parameters keeps
  # a nil scalar, so it still proves the key is permitted.
  let(:full_attributes) do
    {
      name: "parity-mapping",
      description: "every writable field in one request",
      sdwan_peer_id: other_hub.id,
      target_peer_id: target.id,
      target_virtual_ip_id: nil,
      listen_port: 31_100,
      target_port: 5432,
      protocol: "udp",
      enabled: false,
      metadata: { "tier" => "gold" },
      rate_limit: 100,
      max_connections: 25,
      source_cidrs: [ "203.0.113.0/24" ]
    }
  end

  # Keys no surface may accept. Tenancy and parentage are resolved by the
  # executor from the route/account, never from caller input; the rest are
  # platform-written.
  let(:forbidden_attributes) do
    {
      id: SecureRandom.uuid,
      account_id: create(:account).id,
      sdwan_network_id: create(:sdwan_network).id,
      last_compiled_at: 1.day.ago.iso8601
    }
  end

  # The MCP arms call the hub column by the name their schema, their
  # serializers and their list filter have always used.
  #
  # PINNED LITERALLY, and that is the point. The first version of this file
  # derived the mapping by inverting Ai::Tools::SdwanTool::
  # PORT_MAPPING_OPTION_ALIASES — which made every example here blind to the
  # alias table itself: emptying the constant moved the production arm and the
  # oracle together, so a mutant that renamed the published `hub_peer_id`
  # parameter to the raw column name passed the whole file. `hub_peer_id` is a
  # CONTRACT (create's schema parameter, both serializers' key, list's filter),
  # not an implementation detail, so the spec has to state it independently.
  let(:caller_name_for) { { sdwan_peer_id: :hub_peer_id }.freeze }

  # Field SET follows the model's writable list — that coupling is intended,
  # it is what makes a new writable attribute reach these examples. Only the
  # NAMES are pinned.
  let(:expected_option_names) do
    ::Sdwan::PortMapping::WRITABLE_ATTRIBUTES.map { |a| caller_name_for.fetch(a, a) }
  end

  def under_caller_names(attrs)
    attrs.transform_keys { |k| caller_name_for.fetch(k, k) }
  end

  def parked_attributes
    deferred = ::Ai::DeferredOperation.order(created_at: :desc).first
    expect(deferred).to be_present, "the write did not route through the autonomy gate"
    deferred.params.fetch("attributes")
  end

  it "exercises every attribute the model declares writable" do
    expect(full_attributes.keys).to match_array(::Sdwan::PortMapping::WRITABLE_ATTRIBUTES),
                                    "an attribute was added to Sdwan::PortMapping::WRITABLE_ATTRIBUTES " \
                                    "without a value here, so no example below proves it reaches either surface"
  end

  describe "REST create" do
    it "carries the whole writable list to the executor and drops everything else" do
      post collection_path,
           params: { port_mapping: full_attributes.merge(forbidden_attributes) },
           headers: auth_headers_for(manager), as: :json

      expect(response).to have_http_status(:accepted)
      attrs = parked_attributes
      expect(attrs.keys.map(&:to_sym)).to match_array(::Sdwan::PortMapping::WRITABLE_ATTRIBUTES)
      expect(attrs.keys).not_to include(*forbidden_attributes.keys.map(&:to_s))
      expect(attrs["rate_limit"]).to eq(100)
      expect(attrs["sdwan_peer_id"]).to eq(other_hub.id)
    end

    # A write the caller cannot read back is the same shape as a dropped key,
    # so the serializer has to move with the permit list. serialize_full is a
    # literal: without this, adding a writable attribute leaves it unanswered
    # and nothing reds.
    it "answers every writable attribute it just accepted" do
      seed_operator_policy!("sdwan.port_mapping_create")

      post collection_path, params: { port_mapping: full_attributes },
           headers: auth_headers_for(manager), as: :json

      expect(response).to have_http_status(:created)
      body = response.parsed_body.dig("data", "port_mapping")
      expect(body.keys).to include(*expected_option_names.map(&:to_s))
    end
  end

  describe "REST update" do
    let!(:mapping) do
      create(:sdwan_port_mapping, account: account, network: network,
                                  hub_peer: hub, target_peer: target, listen_port: 31_000)
    end

    it "carries the whole writable list to the executor and drops everything else" do
      patch "#{collection_path}/#{mapping.id}",
            params: { port_mapping: full_attributes.merge(forbidden_attributes) },
            headers: auth_headers_for(manager), as: :json

      expect(response).to have_http_status(:accepted)
      attrs = parked_attributes
      expect(attrs.keys.map(&:to_sym)).to match_array(::Sdwan::PortMapping::WRITABLE_ATTRIBUTES)
      expect(attrs.keys).not_to include(*forbidden_attributes.keys.map(&:to_s))
    end
  end

  describe "MCP update" do
    let!(:mapping) do
      create(:sdwan_port_mapping, account: account, network: network,
                                  hub_peer: hub, target_peer: target, listen_port: 31_000)
    end

    it "carries the whole writable list to the executor and drops everything else" do
      result = tool.execute(params: {
        action: "system_sdwan_update_port_mapping",
        port_mapping_id: mapping.id,
        options: under_caller_names(full_attributes).merge(forbidden_attributes)
      })

      expect(result[:success]).to be(true), "MCP update refused the full writable payload: #{result[:error]}"
      attrs = parked_attributes
      expect(attrs.keys.map(&:to_sym)).to match_array(::Sdwan::PortMapping::WRITABLE_ATTRIBUTES)
      expect(attrs.keys).not_to include(*forbidden_attributes.keys.map(&:to_s))
      expect(attrs["sdwan_peer_id"]).to eq(other_hub.id),
                                        "hub_peer_id did not translate to the sdwan_peer_id column"
    end

    it "names exactly the accepted set when a payload has no recognized field" do
      result = tool.execute(params: {
        action: "system_sdwan_update_port_mapping",
        port_mapping_id: mapping.id,
        options: forbidden_attributes
      })

      expect(result[:success]).to be false
      named = result[:error].split("permitted (options):").last.split(",").map { |s| s.strip.to_sym }
      expect(named).to match_array(expected_option_names)
    end

    it "advertises the same set in its tool schema" do
      described = ::Ai::Tools::SdwanTool.action_definitions
                                        .fetch("system_sdwan_update_port_mapping")
                                        .dig(:parameters, :options, :description)

      expected_option_names.each do |field|
        expect(described).to include(field.to_s), "the schema does not advertise #{field}"
      end
      expect(described).not_to include("sdwan_peer_id"),
                               "the schema advertises the raw column name instead of hub_peer_id"
    end
  end

  describe "MCP create" do
    # This arm writes inline, so the assertion is against the persisted row
    # rather than a parked attributes hash.
    it "persists every writable attribute and ignores everything else" do
      result = tool.execute(params: {
        action: "system_sdwan_create_port_mapping",
        network_id: network.id
      }.merge(under_caller_names(full_attributes)).merge(forbidden_attributes))

      expect(result[:success]).to be(true), "MCP create refused the full writable payload: #{result[:error]}"
      payload = result[:data][:port_mapping]
      row = ::Sdwan::PortMapping.find(payload[:id])

      full_attributes.each do |column, value|
        expect(row.public_send(column)).to eq(value), "#{column} did not reach the row"
      end

      # Same reason as the REST twin above: the response has to name what it
      # accepted, and serialize_port_mapping_full is a literal.
      expect(payload.keys).to include(*expected_option_names)

      expect(row.account_id).to eq(account.id)
      expect(row.sdwan_network_id).to eq(network.id)
      expect(row.id).not_to eq(forbidden_attributes[:id])
      expect(row.last_compiled_at).to be_nil
    end

    # create's schema is hand-written where update's is interpolated, so it is
    # the one place an accepted field can go unadvertised.
    it "advertises every accepted field in its tool schema" do
      declared = ::Ai::Tools::SdwanTool.action_definitions
                                       .fetch("system_sdwan_create_port_mapping")
                                       .fetch(:parameters).keys

      expect(declared).to include(*expected_option_names)
      expect(declared).not_to include(:sdwan_peer_id)
    end
  end
end
