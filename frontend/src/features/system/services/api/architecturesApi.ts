import { apiClient } from '@/shared/services/apiClient';
import type { ArchitectureFamily, SystemNodeArchitecture } from '../../types/system.types';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export interface ArchitectureCreate {
  name: string;
  family: ArchitectureFamily;
  apt_name?: string;
  rpm_name?: string;
  display_name?: string;
  description?: string;
  kernel_options?: string;
  // Vendor-specific tags. Backend lowercases + dedupes; safe to submit
  // mixed case + duplicates.
  aliases?: string[];
  enabled?: boolean;
  public?: boolean;
}

export interface ArchitectureListFilters {
  family?: ArchitectureFamily;
  is_canonical?: boolean;
  enabled?: boolean;
}

export const architecturesApi = {
  getArchitectures: async (filters?: ArchitectureListFilters): Promise<SystemNodeArchitecture[]> => {
    const params: Record<string, string> = {};
    if (filters?.family) params.family = filters.family;
    if (typeof filters?.is_canonical === 'boolean') params.is_canonical = String(filters.is_canonical);
    if (typeof filters?.enabled === 'boolean') params.enabled = String(filters.enabled);

    const response = await apiClient.get<ApiEnvelope<{ node_architectures: SystemNodeArchitecture[] }>>(
      '/system/node_architectures',
      { params }
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
