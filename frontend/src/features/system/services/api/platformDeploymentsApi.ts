import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  DeploymentListResponse,
  DeploymentSummary,
  DeploymentUpdateRequest,
  DeploymentUpdateResponse,
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

  // Returns the WHOLE envelope, not just the row: a target_replicas change
  // now drives System::Platform::ReplicaReconciler server-side and the
  // outcome rides back in `reconciled`. Callers that drop it report a save as
  // a scale. (IMP-f4fe1ed1ec1e.)
  update: async (id: string, patch: DeploymentUpdateRequest): Promise<DeploymentUpdateResponse> => {
    const response = await apiClient.patch<ApiEnvelope<DeploymentUpdateResponse>>(
      `${BASE}/${id}`,
      patch,
    );
    return extractData(response);
  },
};
