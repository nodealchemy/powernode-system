import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  ChildPeerDetail,
  ChildPeerSummary,
  ChildrenFilters,
  ChildrenListResponse,
  SpawnRequest,
  SpawnResponse,
} from '../../types/spawn.types';

// Operator-side admin API client for spawned-child management.
// Plan reference: Decentralized Federation §H + P6.

const BASE = '/system/federation/children';

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

export const childrenApi = {
  listChildren: async (filters?: ChildrenFilters): Promise<ChildrenListResponse> => {
    const response = await apiClient.get<ApiEnvelope<ChildrenListResponse>>(BASE, {
      params: paramsFromFilters(filters),
    });
    return extractData(response);
  },

  getChild: async (id: string): Promise<ChildPeerDetail> => {
    const response = await apiClient.get<ApiEnvelope<{ child: ChildPeerDetail }>>(
      `${BASE}/${id}`,
    );
    return extractData(response).child;
  },

  spawn: async (req: SpawnRequest): Promise<SpawnResponse> => {
    const response = await apiClient.post<ApiEnvelope<SpawnResponse>>(`${BASE}/spawn`, req);
    return extractData(response);
  },

  revoke: async (id: string, reason?: string): Promise<ChildPeerSummary> => {
    const response = await apiClient.post<ApiEnvelope<{ child: ChildPeerSummary }>>(
      `${BASE}/${id}/revoke`,
      reason ? { reason } : {},
    );
    return extractData(response).child;
  },
};
