# frozen_string_literal: true

require "rails_helper"

# IMP-ee57d0fbe859 — create/delete audit symmetry. Sdwan::Executors::DeletePeer
# records the connectivity tuple it removed (`peer.primary_endpoint`); CreatePeer
# recorded `peer.try(:endpoint)`, which is always nil because Sdwan::Peer has no
# `endpoint` method or column. An auditor holding both rows could not correlate
# "which endpoint was added" with "which endpoint was removed" — the create row
# reported nothing at all.
RSpec.describe Sdwan::Executors::CreatePeer do
  describe ".execute" do
    let(:account)  { create(:account) }
    let(:network)  { create(:sdwan_network, account: account) }
    let(:instance) { create(:system_node_instance) }

    it "records the peer connectivity tuple in the audit payload" do
      result = described_class.execute(
        {
          network_id: network.id,
          attributes: {
            account_id: account.id,
            node_instance_id: instance.id,
            publicly_reachable: true,
            endpoint_host_v6: "fd00:abcd:9::1",
            endpoint_port: 51_820,
            listen_port: 51_820
          }
        },
        deferred_operation: nil
      )

      expect(result[:success]).to be true
      expect(result[:data][:endpoint]).to eq(
        { host: "fd00:abcd:9::1", port: 51_820, family: :v6 }
      ), "the create audit row cannot be correlated with the delete row"
      expect(result[:data]).to include(network_id: network.id)
      expect(::Sdwan::Peer.find(result[:data][:peer_id]).sdwan_network_id).to eq(network.id)
    end

    it "reports a nil endpoint for a spoke that genuinely has none" do
      result = described_class.execute(
        {
          network_id: network.id,
          attributes: {
            account_id: account.id,
            node_instance_id: instance.id,
            publicly_reachable: false,
            listen_port: 51_820
          }
        },
        deferred_operation: nil
      )

      expect(result[:data]).to include(endpoint: nil)
    end
  end
end
