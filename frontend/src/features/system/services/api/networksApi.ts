import { apiClient } from '@/shared/services/apiClient';
import type { SystemProviderNetwork, SystemProviderNetworkSubnet } from '../../types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface NetworkFilters extends PaginationParams {
  provider_region_id?: string;
  search?: string;
}

export interface NetworkCreate {
  name: string;
  description?: string;
  provider_region_id: string;
  cidr_block?: string;
  is_public?: boolean;
  enabled?: boolean;
  config?: Record<string, unknown>;
}

export interface NetworkUpdate {
  name?: string;
  description?: string;
  cidr_block?: string;
  is_public?: boolean;
  enabled?: boolean;
  config?: Record<string, unknown>;
}

export const networksApi = {
  getNetworks: async (
    params?: NetworkFilters
  ): Promise<{ networks: SystemProviderNetwork[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<PaginatedEnvelope<{ networks: SystemProviderNetwork[] }>>(
      '/system/provider_networks',
      { params }
    );
    return extractPaginated(response);
  },

  getNetwork: async (id: string): Promise<SystemProviderNetwork> => {
    const response = await apiClient.get<ApiEnvelope<{ network: SystemProviderNetwork }>>(
      `/system/provider_networks/${id}`
    );
    return extractData(response).network;
  },

  createNetwork: async (data: NetworkCreate): Promise<SystemProviderNetwork> => {
    const response = await apiClient.post<ApiEnvelope<{ network: SystemProviderNetwork }>>(
      '/system/provider_networks',
      { network: data }
    );
    return extractData(response).network;
  },

  updateNetwork: async (id: string, data: NetworkUpdate): Promise<SystemProviderNetwork> => {
    const response = await apiClient.put<ApiEnvelope<{ network: SystemProviderNetwork }>>(
      `/system/provider_networks/${id}`,
      { network: data }
    );
    return extractData(response).network;
  },

  deleteNetwork: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/provider_networks/${id}`);
  },

  // Network Subnets — read-only catalog rows synced from cloud SDKs.
  getNetworkSubnets: async (
    networkId: string,
    availabilityZoneId?: string
  ): Promise<SystemProviderNetworkSubnet[]> => {
    const params = availabilityZoneId ? { availability_zone_id: availabilityZoneId } : {};
    const response = await apiClient.get<ApiEnvelope<{ subnets: SystemProviderNetworkSubnet[] }>>(
      `/system/provider_networks/${networkId}/subnets`,
      { params }
    );
    return extractData(response).subnets ?? [];
  },

  getNetworkSubnet: async (
    networkId: string,
    subnetId: string
  ): Promise<SystemProviderNetworkSubnet> => {
    const response = await apiClient.get<ApiEnvelope<{ subnet: SystemProviderNetworkSubnet }>>(
      `/system/provider_networks/${networkId}/subnets/${subnetId}`
    );
    return extractData(response).subnet;
  },
};
