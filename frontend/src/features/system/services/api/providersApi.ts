import { apiClient } from '@/shared/services/apiClient';
import type {
  SystemProvider,
  SystemProviderRegion,
  SystemProviderConnection,
  SystemProviderInstanceType,
  SystemProviderAvailabilityZone,
} from '../../types/system.types';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export interface ProviderCreate {
  name: string;
  description?: string;
  provider_type: string;
  enabled?: boolean;
  public?: boolean;
  config?: Record<string, unknown>;
  capabilities?: Record<string, unknown>;
}

export interface ProviderRegionCreate {
  name: string;
  description?: string;
  region_code?: string;
  endpoint_url?: string;
  kernel_image?: string;
  machine_image?: string;
  ramdisk_image?: string;
  capabilities?: Record<string, unknown>;
}

export interface ProviderConnectionCreate {
  name: string;
  description?: string;
  provider_id: string;
  access_key?: string;
  secret_key?: string;
  tenant?: string;
  endpoint_url?: string;
  config?: Record<string, unknown>;
}

// Provider catalog: providers, their regions, AAA-encrypted connections, and
// the read-only catalog rows (instance types, availability zones) the
// platform syncs from cloud SDKs.
export const providersApi = {
  // ===== Providers =====
  getProviders: async (): Promise<SystemProvider[]> => {
    const response = await apiClient.get<ApiEnvelope<{ providers: SystemProvider[] }>>('/system/providers');
    return extractData(response).providers ?? [];
  },

  getProvider: async (id: string): Promise<SystemProvider> => {
    const response = await apiClient.get<ApiEnvelope<{ provider: SystemProvider }>>(
      `/system/providers/${id}`
    );
    return extractData(response).provider;
  },

  createProvider: async (data: ProviderCreate): Promise<SystemProvider> => {
    const response = await apiClient.post<ApiEnvelope<{ provider: SystemProvider }>>(
      '/system/providers',
      { provider: data }
    );
    return extractData(response).provider;
  },

  updateProvider: async (id: string, data: Partial<ProviderCreate>): Promise<SystemProvider> => {
    const response = await apiClient.put<ApiEnvelope<{ provider: SystemProvider }>>(
      `/system/providers/${id}`,
      { provider: data }
    );
    return extractData(response).provider;
  },

  deleteProvider: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/providers/${id}`);
  },

  testProvider: async (id: string): Promise<{ success: boolean; message: string }> => {
    const response = await apiClient.post<ApiEnvelope<{ success: boolean; message: string }>>(
      `/system/providers/${id}/test`
    );
    return extractData(response);
  },

  // ===== Provider Regions =====
  getProviderRegions: async (providerId: string): Promise<SystemProviderRegion[]> => {
    const response = await apiClient.get<ApiEnvelope<{ regions: SystemProviderRegion[] }>>(
      `/system/providers/${providerId}/regions`
    );
    return extractData(response).regions ?? [];
  },

  getProviderRegion: async (
    providerId: string,
    regionId: string
  ): Promise<SystemProviderRegion> => {
    const response = await apiClient.get<ApiEnvelope<{ region: SystemProviderRegion }>>(
      `/system/providers/${providerId}/regions/${regionId}`
    );
    return extractData(response).region;
  },

  createProviderRegion: async (
    providerId: string,
    data: ProviderRegionCreate
  ): Promise<SystemProviderRegion> => {
    const response = await apiClient.post<ApiEnvelope<{ region: SystemProviderRegion }>>(
      `/system/providers/${providerId}/regions`,
      { region: data }
    );
    return extractData(response).region;
  },

  updateProviderRegion: async (
    providerId: string,
    regionId: string,
    data: Partial<ProviderRegionCreate>
  ): Promise<SystemProviderRegion> => {
    const response = await apiClient.put<ApiEnvelope<{ region: SystemProviderRegion }>>(
      `/system/providers/${providerId}/regions/${regionId}`,
      { region: data }
    );
    return extractData(response).region;
  },

  deleteProviderRegion: async (providerId: string, regionId: string): Promise<void> => {
    await apiClient.delete(`/system/providers/${providerId}/regions/${regionId}`);
  },

  // ===== Provider Connections =====
  getProviderConnections: async (): Promise<SystemProviderConnection[]> => {
    const response = await apiClient.get<ApiEnvelope<{ provider_connections: SystemProviderConnection[] }>>(
      '/system/provider_connections'
    );
    return extractData(response).provider_connections ?? [];
  },

  getProviderConnection: async (id: string): Promise<SystemProviderConnection> => {
    const response = await apiClient.get<ApiEnvelope<{ provider_connection: SystemProviderConnection }>>(
      `/system/provider_connections/${id}`
    );
    return extractData(response).provider_connection;
  },

  createProviderConnection: async (
    data: ProviderConnectionCreate
  ): Promise<SystemProviderConnection> => {
    const response = await apiClient.post<ApiEnvelope<{ provider_connection: SystemProviderConnection }>>(
      '/system/provider_connections',
      { provider_connection: data }
    );
    return extractData(response).provider_connection;
  },

  updateProviderConnection: async (
    id: string,
    data: Partial<ProviderConnectionCreate>
  ): Promise<SystemProviderConnection> => {
    const response = await apiClient.put<ApiEnvelope<{ provider_connection: SystemProviderConnection }>>(
      `/system/provider_connections/${id}`,
      { provider_connection: data }
    );
    return extractData(response).provider_connection;
  },

  deleteProviderConnection: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/provider_connections/${id}`);
  },

  testProviderConnection: async (id: string): Promise<{ success: boolean; message: string }> => {
    const response = await apiClient.post<ApiEnvelope<{ success: boolean; message: string }>>(
      `/system/provider_connections/${id}/test`
    );
    return extractData(response);
  },

  // ===== Provider Instance Types =====
  getProviderInstanceTypes: async (
    providerId?: string
  ): Promise<SystemProviderInstanceType[]> => {
    const url = providerId
      ? `/system/providers/${providerId}/instance_types`
      : '/system/provider_instance_types';
    const response = await apiClient.get<ApiEnvelope<{ instance_types: SystemProviderInstanceType[] }>>(url);
    return extractData(response).instance_types ?? [];
  },

  getProviderInstanceType: async (
    providerId: string,
    instanceTypeId: string
  ): Promise<SystemProviderInstanceType> => {
    const response = await apiClient.get<ApiEnvelope<{ instance_type: SystemProviderInstanceType }>>(
      `/system/providers/${providerId}/instance_types/${instanceTypeId}`
    );
    return extractData(response).instance_type;
  },

  getInstanceTypesForRegion: async (
    regionId: string
  ): Promise<SystemProviderInstanceType[]> => {
    const response = await apiClient.get<ApiEnvelope<{ instance_types: SystemProviderInstanceType[] }>>(
      '/system/provider_instance_types/for_region',
      { params: { region_id: regionId } }
    );
    return extractData(response).instance_types ?? [];
  },

  // ===== Provider Availability Zones =====
  getProviderAvailabilityZones: async (
    providerId: string,
    regionId: string
  ): Promise<SystemProviderAvailabilityZone[]> => {
    const response = await apiClient.get<ApiEnvelope<{ availability_zones: SystemProviderAvailabilityZone[] }>>(
      `/system/providers/${providerId}/regions/${regionId}/availability_zones`
    );
    return extractData(response).availability_zones ?? [];
  },

  getProviderAvailabilityZone: async (
    providerId: string,
    regionId: string,
    zoneId: string
  ): Promise<SystemProviderAvailabilityZone> => {
    const response = await apiClient.get<ApiEnvelope<{ availability_zone: SystemProviderAvailabilityZone }>>(
      `/system/providers/${providerId}/regions/${regionId}/availability_zones/${zoneId}`
    );
    return extractData(response).availability_zone;
  },
};
