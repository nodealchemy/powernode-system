import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  DeploymentListResponse,
  DeploymentSummary,
  DeploymentUpdateRequest,
} from '../../types/deployment.types';

// Operator-side admin API client for the Scaling panel.
//
// Plan reference: Decentralized Federation §G + §I + P7.3.

const BASE = '/system/platform/deployments';

export const platformDeploymentsApi = {
  list: async (): Promise<DeploymentListResponse> => {
    const response = await apiClient.get<ApiEnvelope<DeploymentListResponse>>(BASE);
    return extractData(response);
  },

  get: async (id: string): Promise<DeploymentSummary> => {
    const response = await apiClient.get<ApiEnvelope<{ deployment: DeploymentSummary }>>(
      `${BASE}/${id}`,
    );
    return extractData(response).deployment;
  },

  update: async (id: string, patch: DeploymentUpdateRequest): Promise<DeploymentSummary> => {
    const response = await apiClient.patch<ApiEnvelope<{ deployment: DeploymentSummary }>>(
      `${BASE}/${id}`,
      patch,
    );
    return extractData(response).deployment;
  },
};
