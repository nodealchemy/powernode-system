import { apiClient } from '@/shared/services/apiClient';
import type { SystemProviderVolume } from '../../types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  ApiErrorEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface VolumeFilters extends PaginationParams {
  status?: string;
  attached?: boolean;
  encrypted?: boolean;
  search?: string;
  // Caller-overridable page size for the PlanStorageMigrationModal
  // (volume picker needs a higher cap than the default list page).
  page_size?: number;
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
// varies per provider, so this is a permissive type. The named fields are the
// ones ProviderVolumeSnapshotSerializer always emits.
export type VolumeSnapshot = {
  id: string;
  name?: string;
  description?: string;
  status?: string;
  size_gb?: number;
  /** The server's own answer to "may this snapshot be restored from?" — the
   *  UI must not re-derive it from `status`. */
  can_restore?: boolean;
  created_at?: string;
} & Record<string, unknown>;

/**
 * Result of POST /system/provider_volumes/:id/restore.
 *
 * `restored_in_place` is the field a caller MUST read before telling an
 * operator anything. TRUE: this volume was rolled back and every write since
 * the snapshot is discarded. FALSE: the provider copied the snapshot into a
 * NEW volume, returned as `restored_volume`, and THIS volume is unchanged —
 * reporting "restored" on that branch would tell an operator their data is
 * somewhere it is not.
 *
 * `swapped` is present on every success path (false when nothing was swapped);
 * `swap_skipped` names the reason only when a swap was asked for and did not
 * happen.
 */
/**
 * A restore that failed AFTER the provider made a copy.
 *
 * The controller's `render_restore_error` keeps the copy's id in the error
 * envelope's `details` precisely because losing it leaves the operator holding
 * a billable, unattached disk they cannot find. Axios rejects with a raw
 * AxiosError whose `message` is "Request failed with status code 422", so
 * without this the caller would surface a status line and drop the one field
 * that matters.
 */
export class VolumeRestoreError extends Error {
  readonly details?: Record<string, unknown>;

  constructor(message: string, details?: Record<string, unknown>) {
    super(message);
    this.name = 'VolumeRestoreError';
    this.details = details;
  }
}

export interface VolumeRestoreResult {
  volume?: SystemProviderVolume;
  restored_in_place: boolean;
  restored_volume: SystemProviderVolume | null;
  restored_from?: VolumeSnapshot;
  swapped: boolean;
  swap_skipped?: string | null;
  swapped_instance_id?: string | null;
  swapped_device?: string | null;
}

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

  // Snapshots are a sub-resource of the volume, not a verb on it, and the
  // listing is paginated (system.volumes.read).
  getVolumeSnapshots: async (
    id: string,
    params?: PaginationParams
  ): Promise<{ snapshots: VolumeSnapshot[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<PaginatedEnvelope<{ snapshots: VolumeSnapshot[] }>>(
      `/system/provider_volumes/${id}/snapshots`,
      { params }
    );
    return extractPaginated(response);
  },

  // Restore this volume FROM one of its snapshots (system.volumes.manage — the
  // broadest thing that can be done to a volume's contents). `swapIntoPlace`
  // asks the server to detach the source from its instance and attach the copy
  // at the same device; see VolumeRestoreResult for how to read the answer.
  restoreVolumeSnapshot: async (
    id: string,
    snapshotId: string,
    swapIntoPlace = false
  ): Promise<VolumeRestoreResult> => {
    try {
      const response = await apiClient.post<ApiEnvelope<VolumeRestoreResult>>(
        `/system/provider_volumes/${id}/restore`,
        { snapshot_id: snapshotId, swap_into_place: swapIntoPlace }
      );
      return extractData(response);
    } catch (error) {
      const body = (error as { response?: { data?: ApiErrorEnvelope } }).response?.data;
      if (body && body.success === false) {
        throw new VolumeRestoreError(body.error, body.details);
      }
      throw error;
    }
  },
};
