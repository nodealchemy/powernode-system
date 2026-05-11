# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sdwan::Executors::DeletePeer do
  # Plain doubles (not instance_double) — Sdwan::Peer doesn't expose a bare
  # `endpoint` reader (the model uses endpoint_host_v4/v6 columns). The
  # executor's contract is `respond_to?(:endpoint) ? peer.endpoint : nil`,
  # so the spec exercises the both-paths behavior without locking us to the
  # model's evolving column set.

  describe '.execute' do
    it 'destroys the peer and returns the destroy result' do
      peer = double('Sdwan::Peer', id: 'peer-uuid', destroy!: true, endpoint: '10.0.0.5')
      allow(::Sdwan::Peer).to receive(:find).with('peer-uuid').and_return(peer)

      result = described_class.execute({ peer_id: 'peer-uuid' }, deferred_operation: nil)
      expect(result[:success]).to be true
      expect(result[:data]).to include(peer_id: 'peer-uuid', endpoint: '10.0.0.5', destroyed: true)
      expect(peer).to have_received(:destroy!)
    end

    it 'tolerates a peer model without #endpoint' do
      # No `endpoint:` stub — `respond_to?(:endpoint)` returns false, executor
      # captures nil per its `respond_to?` guard.
      peer = double('Sdwan::Peer', id: 'peer-uuid', destroy!: true)
      allow(::Sdwan::Peer).to receive(:find).with('peer-uuid').and_return(peer)

      result = described_class.execute({ peer_id: 'peer-uuid' }, deferred_operation: nil)
      expect(result[:data]).to include(endpoint: nil, destroyed: true)
    end
  end

  describe '.preview' do
    it 'renders a human-readable summary + impact' do
      peer = double('Sdwan::Peer', id: 'peer-uuid')
      allow(peer).to receive(:try).with(:endpoint).and_return('10.0.0.5')
      allow(peer).to receive(:try).with(:id).and_return('peer-uuid')
      allow(::Sdwan::Peer).to receive(:find_by).with(id: 'peer-uuid').and_return(peer)

      preview = described_class.preview({ peer_id: 'peer-uuid' })
      expect(preview[:summary]).to include('10.0.0.5')
      expect(preview[:impact]).to include('SDWAN connectivity')
    end

    it 'returns a generic summary when peer is missing' do
      allow(::Sdwan::Peer).to receive(:find_by).with(id: 'gone').and_return(nil)
      preview = described_class.preview({ peer_id: 'gone' })
      expect(preview[:summary]).to eq('Delete SDWAN peer gone')
    end
  end
end
