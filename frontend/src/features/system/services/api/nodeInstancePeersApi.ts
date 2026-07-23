// API client for NodeInstance-as-Agent peers (operator surface).
// Backend: Api::V1::System::NodeInstancePeersController — operator-side
// list/show + activate/deactivate + delegate (execute). Peers auto-register
// on first heartbeat; operators activate explicitly before delegation.
// See extensions/system/docs/agent-peering.md.
//
// IMP-20c082f9d519 — frontend/backend parity for the peers operator surface.
import { apiClient } from '@/shared/services/apiClient';
import type {
  SystemNodeInstancePeer,
  SystemNodeInstancePeerSearchResult,
  SystemPeerExecuteRequest,
  SystemPeerExecuteResponse,
} from '@system/features/system/types/system.types';
import { extractData, extractPaginated } from './helpers';
import type { ApiEnvelope, PaginationMeta } from './types';

const BASE = '/system/node_instance_peers';

export interface ListPeersParams {
  /** Backend filters on the literal string "true" — sent only when set. */
  enabled?: boolean;
  page?: number;
  per_page?: number;
}

export const nodeInstancePeersApi = {
  list: async (
    params?: ListPeersParams
  ): Promise<{ peers: SystemNodeInstancePeer[]; meta: PaginationMeta }> => {
    const query: Record<string, string | number> = {};
    if (params?.enabled) query.enabled = 'true';
    if (params?.page !== undefined) query.page = params.page;
    if (params?.per_page !== undefined) query.per_page = params.per_page;

    const response = await apiClient.get<{
      success: true;
      data: { peers: SystemNodeInstancePeer[] };
      meta?: PaginationMeta;
    }>(BASE, { params: query });
    return extractPaginated(response);
  },

  get: async (id: string): Promise<SystemNodeInstancePeer> => {
    const response = await apiClient.get<ApiEnvelope<{ peer: SystemNodeInstancePeer }>>(
      `${BASE}/${id}`
    );
    return extractData(response).peer;
  },

  // Enabled peers only, handle-prefix filtered, capped at 50 — built for
  // autocomplete surfaces.
  searchable: async (q?: string): Promise<SystemNodeInstancePeerSearchResult[]> => {
    const response = await apiClient.get<ApiEnvelope<{
      peers: SystemNodeInstancePeerSearchResult[];
      count: number;
    }>>(`${BASE}/searchable`, { params: q ? { q } : {} });
    return extractData(response).peers ?? [];
  },

  activate: async (id: string): Promise<SystemNodeInstancePeer> => {
    const response = await apiClient.post<ApiEnvelope<{ peer: SystemNodeInstancePeer }>>(
      `${BASE}/${id}/activate`,
      {}
    );
    return extractData(response).peer;
  },

  deactivate: async (id: string): Promise<SystemNodeInstancePeer> => {
    const response = await apiClient.post<ApiEnvelope<{ peer: SystemNodeInstancePeer }>>(
      `${BASE}/${id}/deactivate`,
      {}
    );
    return extractData(response).peer;
  },

  // 202 — dispatches an a2a_call System::Task to the peer's instance.
  // Requires the peer to be activated and the skill to be declared;
  // the backend enforces both plus the daily decision budget.
  execute: async (
    id: string,
    request: SystemPeerExecuteRequest
  ): Promise<SystemPeerExecuteResponse> => {
    const body: Record<string, unknown> = { skill: request.skill };
    if (request.input !== undefined) body.input = request.input;

    const response = await apiClient.post<ApiEnvelope<SystemPeerExecuteResponse>>(
      `${BASE}/${id}/execute`,
      body
    );
    return extractData(response);
  },
};
