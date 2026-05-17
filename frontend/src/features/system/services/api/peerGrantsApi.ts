import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  FederationGrant,
  GrantLifecycle,
  GrantsListResponse,
  IssueGrantRequest,
} from '../../types/grant.types';

// Operator-side API client for per-peer FederationGrant CRUD.
//
// Plan reference: Decentralized Federation §E + §I + P4 + P7.5.

const base = (peerId: string) => `/system/platform/peers/${peerId}/grants`;

export const peerGrantsApi = {
  list: async (peerId: string, state?: GrantLifecycle): Promise<GrantsListResponse> => {
    const response = await apiClient.get<ApiEnvelope<GrantsListResponse>>(base(peerId), {
      params: state ? { state } : {},
    });
    return extractData(response);
  },

  issue: async (peerId: string, req: IssueGrantRequest): Promise<FederationGrant> => {
    const response = await apiClient.post<ApiEnvelope<{ grant: FederationGrant }>>(
      base(peerId),
      req,
    );
    return extractData(response).grant;
  },

  revoke: async (peerId: string, grantId: string, reason?: string): Promise<FederationGrant> => {
    const response = await apiClient.post<ApiEnvelope<{ grant: FederationGrant }>>(
      `${base(peerId)}/${grantId}/revoke`,
      reason ? { reason } : {},
    );
    return extractData(response).grant;
  },
};
