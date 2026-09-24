import { apiClient } from '@/shared/services/apiClient';

/**
 * Volume and deployment calls behind the platform deployment wizard card.
 * The card and these calls live here because the routes do: core renders the
 * card only through the chat-card slot this extension registers.
 */

/** Volume registered via the platform deployment wizard's inline create form. */
export interface CreatedVolume {
  id: string;
  name: string;
  size_gb: number;
  provider_region_id?: string | null;
  created_at?: string;
  transport?: string;
}

/**
 * A volume already on the account, as the list shim serialises it. Wider than
 * CreatedVolume because listing is where an operator judges whether an
 * existing volume is the one they want — status and attachment decide that,
 * and they are also what decides whether it can be attached at all.
 */
export interface ExistingVolume {
  id: string;
  name: string;
  size_gb: number;
  status?: string;
  transport?: string;
  attached_to?: string | null;
}

/**
 * One page of volumes plus the envelope that says whether it is the whole set.
 *
 * The shim paginates (default 100, operator-configurable lower), and a list an
 * operator uses to decide "does this already exist?" is actively harmful when
 * it is silently partial. `count` is the uncapped total, so the caller can say
 * so rather than implying completeness.
 */
export interface VolumePage {
  volumes: ExistingVolume[];
  count: number;
  hasMore: boolean;
}

/** Request body for creating a platform volume. */
export interface CreateVolumeRequest {
  name: string;
  size_gb: number;
  transport: 'nfs' | 'block';
  nfs_server?: string;
  nfs_export_path?: string;
}

/**
 * Raw `response.data` body from the platform deployment endpoint. Returned
 * verbatim so the caller keeps owning its `data?.data || data` unwrapping
 * (and the exact undefined-handling that implies).
 */
export type PlatformDeploymentResponse = Record<string, unknown> | undefined;

export const platformDeploymentApi = {
  /**
   * Create a platform volume from the deployment wizard's inline form. Returns
   * the created volume (or null), matching the prior `response.data?.data?.volume`
   * derivation.
   */
  createPlatformVolume: async (
    body: CreateVolumeRequest
  ): Promise<CreatedVolume | null> => {
    const response = await apiClient.post<{ data?: { volume?: CreatedVolume } }>(
      '/system/platform/volumes',
      body
    );
    return (response.data?.data?.volume ?? null) as CreatedVolume | null;
  },

  /**
   * Volumes already registered on this account, for the wizard's storage step.
   *
   * The wizard's card payload carries a snapshot of the account's volumes taken
   * when the card was rendered; this is the live read. Without it the operator
   * cannot see a volume created after the card appeared — including one they
   * created themselves minutes earlier in another card — which is how a
   * duplicate gets minted.
   */
  listPlatformVolumes: async (): Promise<VolumePage> => {
    const response = await apiClient.get<{
      data?: { volumes?: ExistingVolume[]; count?: number; has_more?: boolean };
    }>('/system/platform/volumes');
    const payload = response.data?.data;
    // A missing key is shape drift, not an empty account. Returning [] here
    // would make the wizard state positively that an account full of volumes
    // has none, which is the one answer that causes the duplicate this list
    // exists to prevent.
    if (!payload || !Array.isArray(payload.volumes)) {
      throw new Error('Unexpected volumes response shape');
    }
    return {
      volumes: payload.volumes,
      count: typeof payload.count === 'number' ? payload.count : payload.volumes.length,
      hasMore: payload.has_more === true,
    };
  },

  /**
   * Queue a platform deployment. Returns the raw `response.data` so the caller
   * keeps its existing `data?.data || data` unwrapping untouched.
   */
  createPlatformDeployment: async (
    body: Record<string, unknown>
  ): Promise<PlatformDeploymentResponse> => {
    const response = await apiClient.post('/system/platform/deployments', body);
    return response.data as PlatformDeploymentResponse;
  },
};
