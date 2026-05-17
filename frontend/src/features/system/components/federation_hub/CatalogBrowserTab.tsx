import React, { useEffect, useState } from 'react';
import { Server, AlertTriangle } from 'lucide-react';
import { apiClient } from '@/shared/services/apiClient';
import type { ApiEnvelope } from '../../services/api/types';
import { extractData } from '../../services/api/helpers';
import { PeerCatalogBrowser } from '../federation/PeerCatalogBrowser';

/**
 * Federation Hub > Catalog Browser tab. Lets the operator pick one
 * of their federated peers + browse that peer's published service
 * offerings, then subscribe.
 *
 * Plan reference: Decentralized Federation §L.7 + P4.6.8e.
 */

interface PeerSummary {
  id: string;
  name?: string | null;
  remote_instance_url?: string | null;
  peer_kind?: string;
  status?: string;
}

interface FederationPeersResponse {
  federation_peers: PeerSummary[];
}

export const CatalogBrowserTab: React.FC = () => {
  const [peers, setPeers] = useState<PeerSummary[]>([]);
  const [selectedPeerId, setSelectedPeerId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    apiClient
      .get<ApiEnvelope<FederationPeersResponse>>('/system/sdwan/federation_peers', {
        params: { peer_kind: 'platform', status: 'active,enrolled,degraded' },
      })
      .then((resp) => {
        if (cancelled) return;
        const list = extractData(resp).federation_peers ?? [];
        setPeers(list);
        if (list.length > 0) setSelectedPeerId(list[0].id);
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'Failed to load peers');
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (loading) {
    return <div className="p-4 text-theme-secondary text-sm">Loading peers…</div>;
  }

  if (error) {
    return (
      <div className="p-3 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm rounded">
        <AlertTriangle className="w-4 h-4" />
        <span>{error}</span>
      </div>
    );
  }

  if (peers.length === 0) {
    return (
      <div className="p-12 text-center text-theme-secondary text-sm">
        No active platform peers. Federate with a peer first (SDWAN hub → Federation tab) to
        browse their service catalog.
      </div>
    );
  }

  const selectedPeer = peers.find((p) => p.id === selectedPeerId);

  return (
    <div className="space-y-4">
      <div className="bg-theme-surface border border-theme rounded-lg p-3 flex items-center gap-3">
        <Server className="w-4 h-4 text-theme-secondary" />
        <label className="text-sm text-theme-secondary">Peer:</label>
        <select
          value={selectedPeerId ?? ''}
          onChange={(e) => setSelectedPeerId(e.target.value)}
          className="flex-1 px-2 py-1 border border-theme rounded bg-theme-background-secondary text-theme-primary text-sm"
        >
          {peers.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name ?? p.remote_instance_url ?? p.id.slice(0, 8)}
              {p.status ? ` (${p.status})` : ''}
            </option>
          ))}
        </select>
      </div>

      {selectedPeerId && (
        <PeerCatalogBrowser
          peerId={selectedPeerId}
          peerLabel={selectedPeer?.name ?? selectedPeer?.remote_instance_url ?? undefined}
        />
      )}
    </div>
  );
};
