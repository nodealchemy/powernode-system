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
    it 'names the peer by its node instance, the way an operator recognises it' do
      peer = create(:sdwan_peer, :hub)
      peer.node_instance.update!(name: 'edge-lon-01')

      preview = described_class.preview({ peer_id: peer.id })

      expect(preview[:summary]).to eq('Delete SDWAN peer edge-lon-01')
      expect(preview[:impact]).to include('SDWAN connectivity')
    end

    it 'falls back to the discovered hostname when the instance is unnamed' do
      peer = create(:sdwan_peer, :hub)
      # name is NOT NULL, so blank it at the column level rather than through
      # validation — this is the shape a partially-enrolled instance presents.
      peer.node_instance.update_column(:name, '')
      peer.node_instance.update_column(:discovered_hostname, 'edge-lon-01.local')

      preview = described_class.preview({ peer_id: peer.id })

      expect(preview[:summary]).to eq('Delete SDWAN peer edge-lon-01.local')
    end

    it 'falls back to the endpoint when the instance carries no name at all' do
      peer = create(:sdwan_peer, :hub)
      peer.node_instance.update_column(:name, '')

      preview = described_class.preview({ peer_id: peer.id })

      # v6 literal is bracketed so host and port stay unambiguous.
      expect(preview[:summary]).to eq('Delete SDWAN peer [fd00:abcd:1::1]:51820')
    end

    it 'falls back to the bare id only when nothing else identifies the peer' do
      peer = create(:sdwan_peer)
      peer.node_instance.update_column(:name, '')

      preview = described_class.preview({ peer_id: peer.id })

      expect(preview[:summary]).to eq("Delete SDWAN peer #{peer.id}")
    end

    it 'returns a generic summary when the peer is missing' do
      preview = described_class.preview({ peer_id: 'gone' })

      expect(preview[:summary]).to eq('Delete SDWAN peer gone')
    end
  end
end
