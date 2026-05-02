import { apiClient } from '@/shared/services/apiClient';
import type { SystemNodePlatform } from '../../types/system.types';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export interface PlatformCreate {
  name: string;
  description?: string;
  node_architecture_id?: string;
  build_script?: string;
  init_script?: string;
  sync_script?: string;
  enabled?: boolean;
  public?: boolean;
}

export const platformsApi = {
  getPlatforms: async (): Promise<SystemNodePlatform[]> => {
    const response = await apiClient.get<ApiEnvelope<{ node_platforms: SystemNodePlatform[] }>>(
      '/system/node_platforms'
    );
    return extractData(response).node_platforms ?? [];
  },

  getPlatform: async (id: string): Promise<SystemNodePlatform> => {
    const response = await apiClient.get<ApiEnvelope<{ node_platform: SystemNodePlatform }>>(
      `/system/node_platforms/${id}`
    );
    return extractData(response).node_platform;
  },

  createPlatform: async (data: PlatformCreate): Promise<SystemNodePlatform> => {
    const response = await apiClient.post<ApiEnvelope<{ node_platform: SystemNodePlatform }>>(
      '/system/node_platforms',
      { node_platform: data }
    );
    return extractData(response).node_platform;
  },

  updatePlatform: async (
    id: string,
    data: Partial<PlatformCreate>
  ): Promise<SystemNodePlatform> => {
    const response = await apiClient.put<ApiEnvelope<{ node_platform: SystemNodePlatform }>>(
      `/system/node_platforms/${id}`,
      { node_platform: data }
    );
    return extractData(response).node_platform;
  },

  deletePlatform: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/node_platforms/${id}`);
  },
};
