import { apiClient } from '@/shared/services/apiClient';
import type { SystemNodeArchitecture } from '../../types/system.types';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export interface ArchitectureCreate {
  name: string;
  description?: string;
  kernel_options?: string;
  enabled?: boolean;
  public?: boolean;
}

export const architecturesApi = {
  getArchitectures: async (): Promise<SystemNodeArchitecture[]> => {
    const response = await apiClient.get<ApiEnvelope<{ node_architectures: SystemNodeArchitecture[] }>>(
      '/system/node_architectures'
    );
    return extractData(response).node_architectures ?? [];
  },

  getArchitecture: async (id: string): Promise<SystemNodeArchitecture> => {
    const response = await apiClient.get<ApiEnvelope<{ node_architecture: SystemNodeArchitecture }>>(
      `/system/node_architectures/${id}`
    );
    return extractData(response).node_architecture;
  },

  createArchitecture: async (data: ArchitectureCreate): Promise<SystemNodeArchitecture> => {
    const response = await apiClient.post<ApiEnvelope<{ node_architecture: SystemNodeArchitecture }>>(
      '/system/node_architectures',
      { node_architecture: data }
    );
    return extractData(response).node_architecture;
  },

  updateArchitecture: async (
    id: string,
    data: Partial<ArchitectureCreate>
  ): Promise<SystemNodeArchitecture> => {
    const response = await apiClient.put<ApiEnvelope<{ node_architecture: SystemNodeArchitecture }>>(
      `/system/node_architectures/${id}`,
      { node_architecture: data }
    );
    return extractData(response).node_architecture;
  },

  deleteArchitecture: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/node_architectures/${id}`);
  },
};
