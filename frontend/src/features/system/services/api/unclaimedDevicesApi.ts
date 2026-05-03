// API client for the physical-device claim flow.
//
// Operators use this surface to:
//   - List devices polling /node_api/claim that haven't been bound yet
//   - Confirm a device's identity by binding it to a NodeInstance
//   - Discard stale unclaimed entries
//
// And to download the generic disk image for a NodePlatform that
// operators will flash onto an SD card / USB stick.
//
// Plan: docs/plans/wondrous-yawning-anchor.md §5 + §8.
import { apiClient } from '@/shared/services/apiClient';
import type {
  SystemUnclaimedDevice,
  SystemDiskImage,
  SystemNodeInstance,
} from '@system/features/system/types/system.types';
import { extractData, extractPaginated } from './helpers';
import type { ApiEnvelope, PaginatedEnvelope, PaginationMeta, PaginationParams } from './types';

export interface UnclaimedDeviceListResponse {
  devices: SystemUnclaimedDevice[];
  meta: PaginationMeta;
}

export interface ClaimResponse {
  unclaimed_device: SystemUnclaimedDevice;
  node_instance_id: string;
  node_instance_name: string;
}

export const unclaimedDevicesApi = {
  // List active unclaimed devices (excludes expired + already-claimed)
  list: async (params?: PaginationParams): Promise<UnclaimedDeviceListResponse> => {
    const response = await apiClient.get<PaginatedEnvelope<{ unclaimed_devices: SystemUnclaimedDevice[] }>>(
      '/system/unclaimed_devices',
      { params },
    );
    const { unclaimed_devices, meta } = extractPaginated(response);
    return { devices: unclaimed_devices ?? [], meta };
  },

  get: async (id: string): Promise<SystemUnclaimedDevice> => {
    const response = await apiClient.get<ApiEnvelope<{ unclaimed_device: SystemUnclaimedDevice }>>(
      `/system/unclaimed_devices/${id}`,
    );
    return extractData(response).unclaimed_device;
  },

  // Operator confirms the device's identity → backend issues bootstrap token
  // on the device's next claim poll. The agent enrolls automatically; the
  // returned NodeInstance is reflected in the next instance refresh.
  claim: async (id: string, nodeInstanceId: string): Promise<ClaimResponse> => {
    const response = await apiClient.post<ApiEnvelope<ClaimResponse>>(
      `/system/unclaimed_devices/${id}/claim`,
      { node_instance_id: nodeInstanceId },
    );
    return extractData(response);
  },

  discard: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/unclaimed_devices/${id}`);
  },

  // Download the generic disk image for a NodePlatform.
  // Returns a signed URL with short TTL — front-end navigates to it
  // directly to trigger the browser download.
  downloadDiskImage: async (platformId: string): Promise<SystemDiskImage> => {
    const response = await apiClient.get<ApiEnvelope<SystemDiskImage>>(
      `/system/node_platforms/${platformId}/disk_image`,
    );
    return extractData(response);
  },
};

// Re-export the NodeInstance type for callers who need the claim-related
// field shape (claimed?, discovered_mac, etc.) — keeps imports cleaner
// in the UnclaimedDevicesPanel + CreateInstanceModal physical branch.
export type { SystemNodeInstance };
