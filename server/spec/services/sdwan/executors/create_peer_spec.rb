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
            # STRING form on purpose: real dispatch is JSON, so the port
            # arrives as "51820". AR typecasts on assignment — the integer
            # port in the audit-tuple assertion below is the pin.
            endpoint_port: "51820",
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

  # IMP-2d26f7289c38 PHASE 0 — the tenancy anchor for a record the executor
  # resolves ITSELF. #perform did an unscoped `Sdwan::Network.find`, so a
  # dispatched create naming a foreign network_id wrote a peer straight into
  # another account's overlay. There is no source_type/source_id pair on a
  # create for the central assertion to catch (no row exists yet), and no HTTP
  # caller today — the HTTP path goes through Sdwan::PeerEnroller and never
  # opens the gate — so this is exactly the agent/MCP-dispatch surface the
  # wiring is about to widen.
  describe "account anchoring" do
    let(:account)   { create(:account) }
    let(:operation) do
      ::Ai::DeferredOperation.create!(
        account: account, action_category: "sdwan.peer_create",
        executor_class: described_class.name, params: {}
      )
    end

    it "refuses to add a peer to a network belonging to another account" do
      foreign = create(:sdwan_network)
      instance = create(:system_node_instance, account: account)

      # Effect first, error identity second: `raise_error` leading would abort
      # the example on the un-fixed code and never report the planted peer.
      raised = begin
        described_class.execute(
          { network_id: foreign.id,
            attributes: { account_id: account.id, node_instance_id: instance.id,
                          listen_port: 51_820 } },
          deferred_operation: operation
        )
        nil
      rescue StandardError => e
        e
      end

      expect(foreign.peers.count).to eq(0),
                                     "a dispatched create planted a peer in another account's network"
      expect(raised).to be_a(::Ai::DeferredOperation::CrossAccountError)
    end

    # The account comes from the resolved network, never from the request: the
    # attributes are replayed verbatim from a stored row and must not be able to
    # name somebody else's account.
    it "takes the peer's account from the network, not from the request attributes" do
      network = create(:sdwan_network, account: account)
      instance = create(:system_node_instance, account: account)

      result = described_class.execute(
        { network_id: network.id,
          attributes: { account_id: create(:account).id,
                        node_instance_id: instance.id, listen_port: 51_820 } },
        deferred_operation: operation
      )

      expect(::Sdwan::Peer.find(result[:data][:peer_id]).account_id).to eq(account.id)
    end
  end

  # IMP-1eba7d50d24c — #summarize is the approval/notification BODY:
  # Ai::DeferredOperationApprovalContent.title and .message both render
  # preview[:summary]. It read "Add SDWAN peer to network <uuid>" — a bare
  # network UUID, and no mention of the peer being added at all — while the
  # matching delete card reads "Delete SDWAN peer edge-lon-01 on wan-core".
  # An auditor holding both rows could not tell they concern the same network.
  describe ".preview" do
    let(:account)  { create(:account) }
    let(:network)  { create(:sdwan_network, account: account, name: "wan-core") }
    let(:instance) { create(:system_node_instance, account: account) }

    def preview_for(attributes = {})
      described_class.preview(
        {
          network_id: network.id,
          attributes: {
            account_id: account.id,
            node_instance_id: instance.id
          }.merge(attributes)
        }
      )
    end

    it "names the node instance and the network an operator recognises, not a bare UUID" do
      instance.update!(name: "edge-lon-01")

      preview = preview_for

      expect(preview[:summary]).to eq("Add SDWAN peer edge-lon-01 on wan-core")
      expect(preview[:impact]).to include("overlay network")
    end

    # The endpoint rung must be rendered by Sdwan::Peer#endpoint_display — the
    # bracketing of a v6 literal included — rather than a second formatter.
    it "falls back to the endpoint the peer will use when the instance carries no name" do
      instance.update_column(:name, "")

      # STRING port on purpose — the JSON-dispatch form (AR typecasts on
      # assignment inside prospective_endpoint_display's Sdwan::Peer.new).
      preview = preview_for(endpoint_host_v6: "fd00:abcd:9::1", endpoint_port: "51820")

      expect(preview[:summary]).to eq("Add SDWAN peer [fd00:abcd:9::1]:51820 on wan-core")
    end

    # A shared ladder only constrains the fragment both surfaces share, so the
    # oracle asserts the equality itself. It holds for every rung that resolves
    # a name or an endpoint — and deliberately NOT for the bare-id floor, which
    # cannot agree: no peer row exists when the create card is composed, so it
    # falls back to the node instance's id where the delete card, holding the
    # row, falls back to the peer's.
    it "renders the same identity fragment the delete card renders for the same peer" do
      instance.update!(name: "edge-lon-01")
      peer = create(:sdwan_peer, account: account, network: network, node_instance: instance)

      create_summary = preview_for[:summary]
      delete_summary = ::Sdwan::Executors::DeletePeer.preview({ peer_id: peer.id })[:summary]

      expect(create_summary.delete_prefix("Add SDWAN peer "))
        .to eq(delete_summary.delete_prefix("Delete SDWAN peer ")),
            "create/delete cards must name a resolvable peer identity identically"
    end

    # The label is built on the preview path, where Base.preview supplies
    # deferred_operation: nil — so the create attributes are the only account
    # the lookups can be scoped by, and a foreign network must not be named.
    it "does not name a network belonging to another account" do
      instance.update!(name: "edge-lon-01")
      foreign = create(:sdwan_network, name: "someone-elses")

      preview = described_class.preview(
        {
          network_id: foreign.id,
          attributes: { account_id: account.id, node_instance_id: instance.id }
        }
      )

      expect(preview[:summary]).to eq("Add SDWAN peer edge-lon-01 on #{foreign.id}")
      expect(preview[:summary]).not_to include("someone-elses")
    end

    it "degrades to the network alone rather than raising on a malformed request" do
      expect(described_class.preview({})[:summary]).to eq("Add SDWAN peer")
      expect(described_class.preview({ network_id: network.id })[:summary])
        .to eq("Add SDWAN peer to network #{network.id}")
    end
  end
end
