import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  AcmeCertificateActionResponse,
  AcmeCertificateCreateRequest,
  AcmeCertificateDetail,
  AcmeCertificateStatus,
  AcmeCertificatesListResponse,
} from '../../types/acme.types';

// ACME certificate admin API client.
// Plan reference: Decentralized Federation §J + P2.5.9.

const BASE = '/system/acme_certificates';

export const acmeCertificatesApi = {
  list: async (status?: AcmeCertificateStatus): Promise<AcmeCertificatesListResponse> => {
    const params = status ? { status } : undefined;
    const response = await apiClient.get<ApiEnvelope<AcmeCertificatesListResponse>>(BASE, { params });
    return extractData(response);
  },

  get: async (id: string): Promise<AcmeCertificateDetail> => {
    const response = await apiClient.get<ApiEnvelope<{ certificate: AcmeCertificateDetail }>>(
      `${BASE}/${id}`,
    );
    return extractData(response).certificate;
  },

  create: async (req: AcmeCertificateCreateRequest): Promise<AcmeCertificateDetail> => {
    const response = await apiClient.post<ApiEnvelope<{ certificate: AcmeCertificateDetail }>>(
      BASE,
      req,
    );
    return extractData(response).certificate;
  },

  // Inline issuance — server holds the connection open while ACME flow runs.
  // Typical: 60-180s. Caller should set a long timeout on the apiClient
  // request OR show a busy state and not retry on perceived timeout.
  requestIssue: async (id: string): Promise<AcmeCertificateActionResponse> => {
    const response = await apiClient.post<ApiEnvelope<AcmeCertificateActionResponse>>(
      `${BASE}/${id}/request_issue`,
      {},
      // Long timeout — DNS propagation + LE polling can take a while.
      { timeout: 240_000 },
    );
    return extractData(response);
  },

  renew: async (id: string): Promise<AcmeCertificateActionResponse> => {
    const response = await apiClient.post<ApiEnvelope<AcmeCertificateActionResponse>>(
      `${BASE}/${id}/renew`,
      {},
      // Renewal is the same ACME ceremony as issuance — same 240s timeout.
      { timeout: 240_000 },
    );
    return extractData(response);
  },

  revoke: async (id: string, reason?: string): Promise<AcmeCertificateActionResponse> => {
    const response = await apiClient.post<ApiEnvelope<AcmeCertificateActionResponse>>(
      `${BASE}/${id}/revoke`,
      reason ? { reason } : {},
    );
    return extractData(response);
  },

  destroy: async (id: string): Promise<void> => {
    await apiClient.delete<ApiEnvelope<unknown>>(`${BASE}/${id}`);
  },
};
