import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  AcmeDnsCredentialCreateRequest,
  AcmeDnsCredentialDetail,
  AcmeDnsCredentialRotateRequest,
  AcmeDnsCredentialSummary,
  AcmeDnsCredentialTestResponse,
  AcmeDnsCredentialsListResponse,
} from '../../types/acme.types';

// ACME DNS credentials admin API client. Token plaintext flows through
// `credentials` payload field; the API never echoes it back.
//
// Plan reference: Decentralized Federation §J + P2.5.8.

const BASE = '/system/acme_dns_credentials';

export const acmeDnsCredentialsApi = {
  list: async (provider?: string): Promise<AcmeDnsCredentialsListResponse> => {
    const params = provider ? { provider } : undefined;
    const response = await apiClient.get<ApiEnvelope<AcmeDnsCredentialsListResponse>>(BASE, { params });
    return extractData(response);
  },

  get: async (id: string): Promise<AcmeDnsCredentialDetail> => {
    const response = await apiClient.get<ApiEnvelope<{ credential: AcmeDnsCredentialDetail }>>(
      `${BASE}/${id}`,
    );
    return extractData(response).credential;
  },

  create: async (req: AcmeDnsCredentialCreateRequest): Promise<AcmeDnsCredentialDetail> => {
    const response = await apiClient.post<ApiEnvelope<{ credential: AcmeDnsCredentialDetail }>>(
      BASE,
      req,
    );
    return extractData(response).credential;
  },

  updateName: async (id: string, name: string): Promise<AcmeDnsCredentialDetail> => {
    const response = await apiClient.patch<ApiEnvelope<{ credential: AcmeDnsCredentialDetail }>>(
      `${BASE}/${id}`,
      { name },
    );
    return extractData(response).credential;
  },

  destroy: async (id: string): Promise<void> => {
    await apiClient.delete<ApiEnvelope<unknown>>(`${BASE}/${id}`);
  },

  testConnectivity: async (id: string): Promise<AcmeDnsCredentialTestResponse> => {
    const response = await apiClient.post<ApiEnvelope<AcmeDnsCredentialTestResponse>>(
      `${BASE}/${id}/test_connectivity`,
      {},
    );
    return extractData(response);
  },

  rotate: async (
    id: string,
    req: AcmeDnsCredentialRotateRequest,
  ): Promise<AcmeDnsCredentialSummary> => {
    const response = await apiClient.post<ApiEnvelope<{ credential: AcmeDnsCredentialSummary }>>(
      `${BASE}/${id}/rotate`,
      req,
    );
    return extractData(response).credential;
  },
};
