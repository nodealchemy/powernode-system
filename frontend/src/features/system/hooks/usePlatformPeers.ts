import { useCallback, useEffect, useState } from 'react';
import { platformPeersApi } from '../services/api/platformPeersApi';
import type { PlatformPeerSummary, PeerListFilters } from '../types/peer.types';

/**
 * usePlatformPeers — shared fetch + state machine for the platform federation
 * peer list. Extracted to remove the byte-identical fetchPeers /
 * loading / error / platformPeersApi.listPeers state machine that was
 * copy-pasted across PeersPanel, PeerControlPanel, and PeerLivenessMonitor.
 *
 * `setPeers` is exposed for consumers that mutate rows in place without a
 * refetch (PeerLivenessMonitor bumps last_heartbeat_at / status from live
 * SystemFleetChannel events). `setError` is exposed for consumers that render
 * a dismissible error banner (PeersPanel / PeerControlPanel).
 *
 * Plan reference: Decentralized Federation §I + P7.1 / Phase 3.
 */
export interface UsePlatformPeersResult {
  peers: PlatformPeerSummary[];
  setPeers: React.Dispatch<React.SetStateAction<PlatformPeerSummary[]>>;
  loading: boolean;
  error: string | null;
  setError: React.Dispatch<React.SetStateAction<string | null>>;
  refetch: () => Promise<void>;
}

export function usePlatformPeers(filters?: PeerListFilters): UsePlatformPeersResult {
  const [peers, setPeers] = useState<PlatformPeerSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Serialize filters so the fetch callback only changes when the actual
  // filter values change (not on every render's fresh object identity).
  const filterKey = filters ? JSON.stringify(filters) : '';

  const refetch = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const parsed: PeerListFilters | undefined = filterKey ? JSON.parse(filterKey) : undefined;
      const result = await platformPeersApi.listPeers(parsed);
      setPeers(result.peers);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load peers');
    } finally {
      setLoading(false);
    }
  }, [filterKey]);

  useEffect(() => {
    void refetch();
  }, [refetch]);

  return { peers, setPeers, loading, error, setError, refetch };
}

export default usePlatformPeers;
