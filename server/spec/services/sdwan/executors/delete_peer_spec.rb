# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sdwan::Executors::DeletePeer do
  # IMP-b49dd405502a — this spec previously drove plain doubles carrying an
  # `endpoint` reader, and that is precisely what hid the defect: Sdwan::Peer
  # defines no `endpoint` method and system_sdwan_peers has no `endpoint`
  # column, so `peer.respond_to?(:endpoint)` is ALWAYS false against a real
  # peer. The doubles manufactured the only object in the world for which the
  # true arm was reachable, then asserted that arm worked — while in production
  # every peer-delete payload recorded `endpoint: nil` and every approval card
  # read "Delete SDWAN peer <uuid>". Every example below drives a REAL peer, so
  # the oracle is the behaviour an operator and an auditor actually see.

  describe '.execute' do
    it 'records the peer connectivity tuple in the audit payload' do
      peer = create(:sdwan_peer, :hub)

      result = described_class.execute({ peer_id: peer.id }, deferred_operation: nil)

      expect(result[:success]).to be true
      expect(result[:data][:endpoint]).to eq(
        { host: 'fd00:abcd:1::1', port: 51_820, family: :v6 }
      ), 'the audit row cannot say which endpoint was removed'
      expect(result[:data]).to include(peer_id: peer.id, destroyed: true)
      expect(::Sdwan::Peer.find_by(id: peer.id)).to be_nil
    end

    # IMP-ee57d0fbe859 — the contract this executor's payload actually serves is
    # the PERSISTED ai_deferred_operations.result jsonb, not the hash it hands
    # back in-process. Ai::DeferredOperation#execute_now! stores the return value
    # through `complete!`, and jsonb round-trips symbol keys to strings and the
    # :v6 family symbol to "v6". Asserting the in-memory hash certifies a shape
    # no auditor ever reads.
    it 'persists the connectivity tuple on the deferred-operation row an auditor reads' do
      peer = create(:sdwan_peer, :hub)
      operation = ::Ai::DeferredOperation.create!(
        account: peer.account,
        action_category: 'sdwan.peer_delete',
        executor_class: described_class.name,
        params: { peer_id: peer.id }
      )

      operation.execute_now!

      # find_by! rather than reload — a persisted read, independent of the
      # in-memory object the executor just mutated.
      persisted = ::Ai::DeferredOperation.find_by!(id: operation.id)
      expect(persisted.status).to eq('completed')
      expect(persisted.result.dig('data', 'endpoint')).to eq(
        { 'host' => 'fd00:abcd:1::1', 'port' => 51_820, 'family' => 'v6' }
      )
      expect(persisted.result.dig('data', 'destroyed')).to be true
    end

    it 'reports a nil endpoint for a spoke that genuinely has none' do
      # A non-hub peer is not required to carry endpoint data
      # (Sdwan::Peer#hub_must_have_endpoint only binds hubs), so nil here is
      # the truth rather than the old always-nil artefact.
      peer = create(:sdwan_peer)

      result = described_class.execute({ peer_id: peer.id }, deferred_operation: nil)

      expect(result[:data]).to include(endpoint: nil, destroyed: true)
      expect(::Sdwan::Peer.find_by(id: peer.id)).to be_nil
    end
  end

  describe '.preview' do
    # IMP-ee57d0fbe859 — the label is Sdwan::Peer#operator_label, shared with
    # PeersController#destroy's `description:`. Rung coverage lives in the model
    # spec; these examples pin what this executor renders around it.
    let(:network) { create(:sdwan_network, name: 'wan-core') }

    # IMP-8e4674f4d62d — the label resolves through Base#scoped_label_record,
    # so it needs the operation's account to anchor on, exactly as the
    # UpdatePeer twin already did. With no operation there is nobody to
    # establish the peer belongs to, and the card correctly declines to name
    # it — pinned by the last example here, and cross-account in
    # spec/services/system/executors/preview_account_anchor_spec.rb.
    def deferred_for(params, account)
      ::Ai::DeferredOperation.create!(
        account: account,
        action_category: 'sdwan.peer_delete',
        executor_class: described_class.name,
        params: params
      )
    end

    it 'names the peer by its node instance and network, the way an operator recognises it' do
      peer = create(:sdwan_peer, :hub, account: network.account, network: network)
      peer.node_instance.update!(name: 'edge-lon-01')
      params = { peer_id: peer.id }

      preview = described_class.preview(params, deferred_operation: deferred_for(params, network.account))

      expect(preview[:summary]).to eq('Delete SDWAN peer edge-lon-01 on wan-core')
      expect(preview[:impact]).to include('SDWAN connectivity')
    end

    it 'falls back to the endpoint when the instance carries no name at all' do
      peer = create(:sdwan_peer, :hub, account: network.account, network: network)
      peer.node_instance.update_column(:name, '')
      params = { peer_id: peer.id }

      preview = described_class.preview(params, deferred_operation: deferred_for(params, network.account))

      # v6 literal is bracketed so host and port stay unambiguous.
      expect(preview[:summary]).to eq('Delete SDWAN peer [fd00:abcd:1::1]:51820 on wan-core')
    end

    it 'returns a generic summary when the peer is missing' do
      params = { peer_id: 'gone' }

      preview = described_class.preview(params, deferred_operation: deferred_for(params, create(:account)))

      expect(preview[:summary]).to eq('Delete SDWAN peer gone')
    end

    # The pre-gate contract base.rb documents: one positional argument still
    # works and nothing raises. What changes is the posture — no anchor, no
    # name.
    it 'declines to name a real peer when there is no account to anchor on' do
      peer = create(:sdwan_peer, :hub, account: network.account, network: network)
      peer.node_instance.update!(name: 'edge-lon-01')

      preview = described_class.preview({ peer_id: peer.id })

      expect(preview[:summary]).to eq("Delete SDWAN peer #{peer.id}")
    end
  end
end
