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

/**
 * Writable subnet fields. Mirrors
 * ProviderNetworkSubnetsController#subnet_params exactly — anything else is
 * dropped by strong parameters.
 */
export interface NetworkSubnetCreate {
  name: string;
  /** `null` clears the column; an omitted key leaves it untouched on update. */
  description?: string | null;
  cidr_block?: string;
  status?: string;
  is_public?: boolean;
  enabled?: boolean;
  provider_availability_zone_id?: string;
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

  // Network Subnets. Rows are synced from the cloud SDK for a connected
  // provider; the write methods below exist for manual/physical providers that
  // have no catalog sync to populate them.

  getNetworkSubnets: async (
    networkId: string,
    availabilityZoneId?: string
  ): Promise<SystemProviderNetworkSubnet[]> => {
    const params = availabilityZoneId ? { availability_zone_id: availabilityZoneId } : {};
    const response = await apiClient.get<ApiEnvelope<{ subnets: SystemProviderNetworkSubnet[] }>>(
      `/system/provider_networks/${networkId}/provider_network_subnets`,
      { params }
    );
    return extractData(response).subnets ?? [];
  },

  getNetworkSubnet: async (
    networkId: string,
    subnetId: string
  ): Promise<SystemProviderNetworkSubnet> => {
    const response = await apiClient.get<ApiEnvelope<{ subnet: SystemProviderNetworkSubnet }>>(
      `/system/provider_networks/${networkId}/provider_network_subnets/${subnetId}`
    );
    return extractData(response).subnet;
  },

  /** Subnets with the page total. Same pagination reasoning as instance types. */
  getNetworkSubnetsPage: async (
    networkId: string
  ): Promise<{ subnets: SystemProviderNetworkSubnet[]; total: number }> => {
    const response = await apiClient.get<
      ApiEnvelope<{
        subnets: SystemProviderNetworkSubnet[];
        meta?: { total_count?: number };
      }>
    >(`/system/provider_networks/${networkId}/provider_network_subnets`, {
      params: { per_page: 100 }
    });
    const data = extractData(response);
    const subnets = data.subnets ?? [];
    return { subnets, total: data.meta?.total_count ?? subnets.length };
  },

  createNetworkSubnet: async (
    networkId: string,
    data: NetworkSubnetCreate
  ): Promise<SystemProviderNetworkSubnet> => {
    const response = await apiClient.post<ApiEnvelope<{ subnet: SystemProviderNetworkSubnet }>>(
      `/system/provider_networks/${networkId}/provider_network_subnets`,
      { subnet: data }
    );
    return extractData(response).subnet;
  },

  updateNetworkSubnet: async (
    networkId: string,
    subnetId: string,
    data: Partial<NetworkSubnetCreate>
  ): Promise<SystemProviderNetworkSubnet> => {
    const response = await apiClient.put<ApiEnvelope<{ subnet: SystemProviderNetworkSubnet }>>(
      `/system/provider_networks/${networkId}/provider_network_subnets/${subnetId}`,
      { subnet: data }
    );
    return extractData(response).subnet;
  },

  deleteNetworkSubnet: async (networkId: string, subnetId: string): Promise<void> => {
    await apiClient.delete(
      `/system/provider_networks/${networkId}/provider_network_subnets/${subnetId}`
    );
  },
};
