import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  InvitePeerRequest,
  InvitePeerResponse,
  PeerListFilters,
  PeerListResponse,
  PlatformPeerDetail,
} from '../../types/peer.types';

// Operator-side admin API client for the Platform Peers panel.
// Distinct from sdwan/federation_peers (legacy SDWAN-peering surface)
// and from federation/children (spawned-child management).
//
// Plan reference: Decentralized Federation §I + P7.1.

const BASE = '/system/platform/peers';

function paramsFromFilters<T extends Record<string, unknown>>(filters?: T): Record<string, string> {
  if (!filters) return {};
  const out: Record<string, string> = {};
  Object.entries(filters).forEach(([key, value]) => {
    if (value === undefined || value === null) return;
    if (Array.isArray(value)) {
      if (value.length > 0) out[key] = value.join(',');
    } else {
      out[key] = String(value);
    }
  });
  return out;
}

export const platformPeersApi = {
  listPeers: async (filters?: PeerListFilters): Promise<PeerListResponse> => {
    const response = await apiClient.get<ApiEnvelope<PeerListResponse>>(BASE, {
      params: paramsFromFilters(filters),
    });
    return extractData(response);
  },

  getPeer: async (id: string): Promise<PlatformPeerDetail> => {
    const response = await apiClient.get<ApiEnvelope<{ peer: PlatformPeerDetail }>>(
      `${BASE}/${id}`,
    );
    return extractData(response).peer;
  },

  invite: async (req: InvitePeerRequest): Promise<InvitePeerResponse> => {
    const response = await apiClient.post<ApiEnvelope<InvitePeerResponse>>(BASE, req);
    return extractData(response);
  },

  revoke: async (id: string, reason?: string): Promise<PlatformPeerDetail> => {
    const response = await apiClient.post<ApiEnvelope<{ peer: PlatformPeerDetail }>>(
      `${BASE}/${id}/revoke`,
      reason ? { reason } : {},
    );
    return extractData(response).peer;
  },
};
