import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type { NetworkTopologyResponse } from '../../types/network_topology.types';

/**
 * Client for the unified system topology endpoint.
 * Plan reference: Decentralized Federation §K.5 + P4.5.7.
 */
export const networkTopologyApi = {
  async getTopology(): Promise<NetworkTopologyResponse> {
    // apiClient prepends /api/v1 automatically — paths start at /system/...
    const response = await apiClient.get<ApiEnvelope<NetworkTopologyResponse>>(
      '/system/network/topology'
    );
    return extractData(response);
  },
};
