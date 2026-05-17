import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  CapabilitiesListResponse,
  CreateCapabilityRequest,
  FederationCapability,
} from '../../types/capability.types';

// Operator-side API client for per-peer FederationCapability CRUD.
//
// Plan reference: Decentralized Federation §D + §I + P4 + P7.6.

const base = (peerId: string) => `/system/platform/peers/${peerId}/capabilities`;

export const peerCapabilitiesApi = {
  list: async (peerId: string): Promise<CapabilitiesListResponse> => {
    const response = await apiClient.get<ApiEnvelope<CapabilitiesListResponse>>(base(peerId));
    return extractData(response);
  },

  create: async (peerId: string, req: CreateCapabilityRequest): Promise<FederationCapability> => {
    const response = await apiClient.post<ApiEnvelope<{ capability: FederationCapability }>>(
      base(peerId),
      req,
    );
    return extractData(response).capability;
  },

  destroy: async (peerId: string, capId: string): Promise<void> => {
    await apiClient.delete<ApiEnvelope<{ deleted: true; id: string }>>(
      `${base(peerId)}/${capId}`,
    );
  },
};
