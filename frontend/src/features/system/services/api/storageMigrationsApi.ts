import { apiClient } from '@/shared/services/apiClient';
import { extractData, extractGated } from './helpers';
import type { Gated } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  CreateStorageMigrationParams,
  StorageMigrationActionResult,
  StorageMigrationDetail,
  StorageMigrationListFilters,
  StorageMigrationListResponse,
  StorageMigrationSummary,
} from '../../types/storageMigration.types';

// Operator-side API client for the StorageMigrations panel.
// Plan reference: E8 follow-on (operator UI).

const BASE = '/system/platform/storage_migrations';

function paramsFromFilters(filters?: object): Record<string, string> {
  if (!filters) return {};
  const out: Record<string, string> = {};
  Object.entries(filters).forEach(([key, value]) => {
    if (value === undefined || value === null) return;
    if (Array.isArray(value)) {
      if (value.length > 0) out[key] = value.join(',');
    } else if (typeof value === 'boolean') {
      out[key] = value ? 'true' : 'false';
    } else {
      out[key] = String(value);
    }
  });
  return out;
}

export const storageMigrationsApi = {
  list: async (filters?: StorageMigrationListFilters): Promise<StorageMigrationListResponse> => {
    const response = await apiClient.get<ApiEnvelope<StorageMigrationListResponse>>(BASE, {
      params: paramsFromFilters(filters),
    });
    return extractData(response);
  },

  get: async (id: string): Promise<StorageMigrationDetail> => {
    const response = await apiClient.get<ApiEnvelope<{ storage_migration: StorageMigrationDetail }>>(
      `${BASE}/${id}`,
    );
    return extractData(response).storage_migration;
  },

  create: async (
    params: CreateStorageMigrationParams,
  ): Promise<StorageMigrationSummary> => {
    const response = await apiClient.post<ApiEnvelope<{ storage_migration: StorageMigrationSummary }>>(
      BASE,
      params,
    );
    return extractData(response).storage_migration;
  },

  approve: async (id: string): Promise<StorageMigrationDetail> => {
    const response = await apiClient.post<ApiEnvelope<{ storage_migration: StorageMigrationDetail }>>(
      `${BASE}/${id}/approve`,
      {},
    );
    return extractData(response).storage_migration;
  },

  cancel: async (id: string, reason?: string): Promise<StorageMigrationDetail> => {
    const response = await apiClient.post<ApiEnvelope<{ storage_migration: StorageMigrationDetail }>>(
      `${BASE}/${id}/cancel`,
      { reason },
    );
    return extractData(response).storage_migration;
  },

  // ─── Recovery actions (Increment 9) ──────────────────────────────────────
  //
  // Both are gated on system.platform.scale and both route through an MCP
  // action server-side. Gated<T> is DEFENSIVE, not currently load-bearing:
  // neither `system_revert_storage_migration_binding` nor
  // `system_cleanup_storage_migration` declares the action_category /
  // executor_class / gate_context / on_proceed quartet that makes an action
  // gateable, so the autonomy gate is not consulted today and the 202 pending
  // branch cannot fire. Callers still branch on isPendingApproval, because the
  // alternative — reading `.status` off a parked result — reports a revert that
  // has not happened, and the day either action is made gateable that is the
  // failure it becomes. (Making it reachable also needs a controller fix: both
  // actions render `result[:storage_migration]`, which would flatten a pending
  // payload to null rather than passing the marker through.)

  /**
   * Ask the on-node agent to re-point the canonical mount back to source.
   * Reachable from `failed`, or from `completed` when promote_target_binding!
   * was swallowed (metadata.promote_failed).
   */
  revert: async (
    id: string,
    reason?: string,
  ): Promise<Gated<StorageMigrationActionResult>> => {
    const response = await apiClient.post<
      ApiEnvelope<{ storage_migration: StorageMigrationActionResult }>
    >(`${BASE}/${id}/revert`, { reason });
    return extractGated(response, (d) => d.storage_migration);
  },

  /**
   * DESTRUCTIVE, target-side, subpath-scoped. Deletes the target-side scratch
   * artifacts. Explicit operator action — the backend never auto-runs it on
   * failure.
   *
   * `immediate` skips the account's cleanup grace window (24h by default,
   * measured from failed_at/cancelled_at). Without it the backend 422s for the
   * whole window, so a caller that never offers the override has a button that
   * is dead for a day after the failure it exists to clean up after.
   */
  cleanup: async (
    id: string,
    params: { reason: string; immediate?: boolean },
  ): Promise<Gated<StorageMigrationActionResult>> => {
    const response = await apiClient.post<
      ApiEnvelope<{ storage_migration: StorageMigrationActionResult }>
    >(`${BASE}/${id}/cleanup`, { reason: params.reason, immediate: params.immediate });
    return extractGated(response, (d) => d.storage_migration);
  },
};
