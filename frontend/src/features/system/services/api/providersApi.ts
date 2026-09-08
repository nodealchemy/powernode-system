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

/**
 * Per-resource upsert tallies returned by System::Providers::CatalogSyncService.
 * `total` is optional because the availability-zone phase reports only
 * created/updated — zones are synced per region, so there is no single row
 * count to report. Callers derive it as created + updated when it is absent.
 */
export interface ProviderCatalogCounts {
  created: number;
  updated: number;
  total?: number;
}

export interface ProviderCatalogSummary {
  regions: ProviderCatalogCounts;
  availability_zones: ProviderCatalogCounts;
  instance_types: ProviderCatalogCounts;
  volume_types: ProviderCatalogCounts;
}

/**
 * Writable instance-type fields. Mirrors
 * ProviderInstanceTypesController#instance_type_params exactly — sending
 * anything else is silently dropped by strong parameters.
 */
export interface ProviderInstanceTypeCreate {
  name: string;
  /**
   * `null` clears the column. An omitted key leaves it untouched on update, so
   * a form that blanks a field must send null rather than dropping the key —
   * otherwise the edit is discarded behind a success toast.
   */
  description?: string | null;
  instance_type_code: string;
  vcpus?: number | null;
  memory_mb?: number | null;
  storage_gb?: number | null;
  hourly_price?: number | null;
  enabled?: boolean;
  specs?: Record<string, unknown>;
}

/** Mirrors ProviderAvailabilityZonesController#zone_params. */
export interface ProviderAvailabilityZoneCreate {
  name: string;
  zone_code: string;
  status?: 'available' | 'impaired' | 'unavailable';
  enabled?: boolean;
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

  // Connection testing lives on testProviderConnection (below) — the
  // /system/providers/:id/test route was removed in audit P0.1 cleanup
  // (the matching backend action was a stub with no router entry, and the
  // working test endpoint is on ProviderConnections).

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

  // Pulls regions, availability zones, instance types and volume types from the
  // provider through this connection's adapter and upserts them into the local
  // catalog. Gated on system.connections.update server-side.
  syncProviderConnectionCatalog: async (
    id: string
  ): Promise<{ connection: SystemProviderConnection; catalog: ProviderCatalogSummary }> => {
    const response = await apiClient.post<
      ApiEnvelope<{ provider_connection: SystemProviderConnection; catalog: ProviderCatalogSummary }>
    >(`/system/provider_connections/${id}/sync_catalog`);
    const data = extractData(response);
    return { connection: data.provider_connection, catalog: data.catalog };
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

  /**
   * Instance types with the page total, for the management surface. The index
   * action paginates at 20 by default (Paginatable#paginate), so a plain read
   * silently truncates a populated catalog; ask for the server maximum and
   * carry `total` so a still-truncated list can say so instead of pretending
   * to be complete. Kept separate from getProviderInstanceTypes so existing
   * callers keep their array return.
   */
  getProviderInstanceTypesPage: async (
    providerId: string
  ): Promise<{ instanceTypes: SystemProviderInstanceType[]; total: number }> => {
    const response = await apiClient.get<
      ApiEnvelope<{ instance_types: SystemProviderInstanceType[]; meta?: { total_count?: number } }>
    >(`/system/providers/${providerId}/instance_types`, { params: { per_page: 100 } });
    const data = extractData(response);
    const instanceTypes = data.instance_types ?? [];
    return { instanceTypes, total: data.meta?.total_count ?? instanceTypes.length };
  },

  createProviderInstanceType: async (
    providerId: string,
    data: ProviderInstanceTypeCreate
  ): Promise<SystemProviderInstanceType> => {
    const response = await apiClient.post<ApiEnvelope<{ instance_type: SystemProviderInstanceType }>>(
      `/system/providers/${providerId}/instance_types`,
      { instance_type: data }
    );
    return extractData(response).instance_type;
  },

  updateProviderInstanceType: async (
    providerId: string,
    instanceTypeId: string,
    data: Partial<ProviderInstanceTypeCreate>
  ): Promise<SystemProviderInstanceType> => {
    const response = await apiClient.put<ApiEnvelope<{ instance_type: SystemProviderInstanceType }>>(
      `/system/providers/${providerId}/instance_types/${instanceTypeId}`,
      { instance_type: data }
    );
    return extractData(response).instance_type;
  },

  deleteProviderInstanceType: async (
    providerId: string,
    instanceTypeId: string
  ): Promise<void> => {
    await apiClient.delete(`/system/providers/${providerId}/instance_types/${instanceTypeId}`);
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

  /** Zones with the page total. Same pagination reasoning as instance types. */
  getProviderAvailabilityZonesPage: async (
    providerId: string,
    regionId: string
  ): Promise<{ zones: SystemProviderAvailabilityZone[]; total: number }> => {
    const response = await apiClient.get<
      ApiEnvelope<{
        availability_zones: SystemProviderAvailabilityZone[];
        meta?: { total_count?: number };
      }>
    >(`/system/providers/${providerId}/regions/${regionId}/availability_zones`, {
      params: { per_page: 100 }
    });
    const data = extractData(response);
    const zones = data.availability_zones ?? [];
    return { zones, total: data.meta?.total_count ?? zones.length };
  },

  createProviderAvailabilityZone: async (
    providerId: string,
    regionId: string,
    data: ProviderAvailabilityZoneCreate
  ): Promise<SystemProviderAvailabilityZone> => {
    const response = await apiClient.post<ApiEnvelope<{ availability_zone: SystemProviderAvailabilityZone }>>(
      `/system/providers/${providerId}/regions/${regionId}/availability_zones`,
      { availability_zone: data }
    );
    return extractData(response).availability_zone;
  },

  updateProviderAvailabilityZone: async (
    providerId: string,
    regionId: string,
    zoneId: string,
    data: Partial<ProviderAvailabilityZoneCreate>
  ): Promise<SystemProviderAvailabilityZone> => {
    const response = await apiClient.put<ApiEnvelope<{ availability_zone: SystemProviderAvailabilityZone }>>(
      `/system/providers/${providerId}/regions/${regionId}/availability_zones/${zoneId}`,
      { availability_zone: data }
    );
    return extractData(response).availability_zone;
  },

  deleteProviderAvailabilityZone: async (
    providerId: string,
    regionId: string,
    zoneId: string
  ): Promise<void> => {
    await apiClient.delete(
      `/system/providers/${providerId}/regions/${regionId}/availability_zones/${zoneId}`
    );
  },
};
