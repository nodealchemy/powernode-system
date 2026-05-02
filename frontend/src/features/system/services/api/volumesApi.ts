import { apiClient } from '@/shared/services/apiClient';
import type { SystemProviderVolume } from '../../types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface VolumeFilters extends PaginationParams {
  status?: string;
  attached?: boolean;
  encrypted?: boolean;
  search?: string;
}

export interface VolumeCreate {
  name: string;
  description?: string;
  size_gb: number;
  volume_type_id?: string;
  provider_region_id?: string;
  availability_zone_id?: string;
  iops?: number;
  throughput?: number;
  encrypted?: boolean;
  delete_on_termination?: boolean;
  config?: Record<string, unknown>;
}

export interface VolumeUpdate {
  name?: string;
  description?: string;
  size_gb?: number;
  iops?: number;
  throughput?: number;
  delete_on_termination?: boolean;
  config?: Record<string, unknown>;
}

// Snapshot is the platform-internal representation; cloud-side raw shape
// varies per provider, so this is a permissive type.
export type VolumeSnapshot = {
  id: string;
  name?: string;
  description?: string;
  status?: string;
  created_at?: string;
} & Record<string, unknown>;

export const volumesApi = {
  getVolumes: async (
    params?: VolumeFilters
  ): Promise<{ volumes: SystemProviderVolume[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<PaginatedEnvelope<{ volumes: SystemProviderVolume[] }>>(
      '/system/provider_volumes',
      { params }
    );
    return extractPaginated(response);
  },

  getVolume: async (id: string): Promise<SystemProviderVolume> => {
    const response = await apiClient.get<ApiEnvelope<{ volume: SystemProviderVolume }>>(
      `/system/provider_volumes/${id}`
    );
    return extractData(response).volume;
  },

  createVolume: async (data: VolumeCreate): Promise<SystemProviderVolume> => {
    const response = await apiClient.post<ApiEnvelope<{ volume: SystemProviderVolume }>>(
      '/system/provider_volumes',
      { volume: data }
    );
    return extractData(response).volume;
  },

  updateVolume: async (id: string, data: VolumeUpdate): Promise<SystemProviderVolume> => {
    const response = await apiClient.put<ApiEnvelope<{ volume: SystemProviderVolume }>>(
      `/system/provider_volumes/${id}`,
      { volume: data }
    );
    return extractData(response).volume;
  },

  deleteVolume: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/provider_volumes/${id}`);
  },

  attachVolume: async (
    id: string,
    nodeInstanceId: string,
    deviceName?: string
  ): Promise<SystemProviderVolume> => {
    const response = await apiClient.post<ApiEnvelope<{ volume: SystemProviderVolume }>>(
      `/system/provider_volumes/${id}/attach`,
      { node_instance_id: nodeInstanceId, device_name: deviceName }
    );
    return extractData(response).volume;
  },

  detachVolume: async (id: string): Promise<SystemProviderVolume> => {
    const response = await apiClient.post<ApiEnvelope<{ volume: SystemProviderVolume }>>(
      `/system/provider_volumes/${id}/detach`
    );
    return extractData(response).volume;
  },

  createVolumeSnapshot: async (
    id: string,
    name?: string,
    description?: string
  ): Promise<VolumeSnapshot> => {
    const response = await apiClient.post<ApiEnvelope<{ snapshot: VolumeSnapshot }>>(
      `/system/provider_volumes/${id}/snapshot`,
      { name, description }
    );
    return extractData(response).snapshot;
  },
};
