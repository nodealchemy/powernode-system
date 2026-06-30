# frozen_string_literal: true

require "rails_helper"

# N+1 regression for vrf_assignments_for on the agent heartbeat config pull
# (GET /node_api/config/sdwan). It looped HostVrfAssignment rows and ran
# net.peers.where(...).pluck per assignment — one peer query per VRF on every
# heartbeat across the fleet. The address lookup must be batched so peer queries
# stay flat as the number of assignments grows.
RSpec.describe "node_api SDWAN show_config — vrf_assignments_for N+1", type: :request do
  # Builds a fresh instance with ONE compiled peer (constant compile cost) plus
  # `hva_count` HostVrfAssignments on separate networks, and returns the number
  # of peer-table queries the show_config pull issues. Only the vrf address
  # lookup varies with hva_count, so the count must be invariant once batched.
  def show_config_peer_queries(hva_count:)
    account  = create(:account)
    template = create(:system_node_template, account: account)
    node     = create(:system_node, account: account, node_template: template)
    instance = create(:system_node_instance, :running, node: node)
    System::NodeCertificate.create!(
      node_instance: instance, serial: SecureRandom.hex(16),
      subject: "CN=#{instance.id}", not_before: 1.hour.ago,
      not_after: 90.days.from_now, issuer_subject: "CN=Powernode Internal CA"
    )
    auth = { "X-Forwarded-Tls-Client-Cert-Info" => CGI.escape(%(Subject="CN=#{instance.id}")) }

    # One peer (with a key, so the MC signer in compile doesn't raise) keeps the
    # compile cost constant across runs.
    net0  = create(:sdwan_network, account: account)
    peer0 = create(:sdwan_peer, account: account, network: net0, node_instance: instance)
    Sdwan::KeyDistributor.ensure_key_for!(peer0)

    hva_count.times do |i|
      net = create(:sdwan_network, account: account)
      Sdwan::HostVrfAssignment.create!(
        account: account, node_instance: instance, network: net,
        table_id: 100 + i, vrf_name: "vrf-#{i}-#{SecureRandom.hex(2)}",
        short_id: 1000 + i, state: "active"
      )
    end

    count = count_queries(/\bsystem_sdwan_peers\b/) do
      get "/api/v1/system/node_api/config/sdwan", headers: auth
    end
    expect(response).to have_http_status(:ok)
    count
  end

  it "issues the same number of peer queries regardless of HostVrfAssignment count" do
    one   = show_config_peer_queries(hva_count: 1)
    three = show_config_peer_queries(hva_count: 3)

    expect(three).to eq(one) # flat — addresses batched, not one pluck per assignment
  end
end
