import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  CreateStorageMigrationParams,
  StorageMigrationDetail,
  StorageMigrationListFilters,
  StorageMigrationListResponse,
  StorageMigrationSummary,
} from '../../types/storageMigration.types';

// Operator-side API client for the StorageMigrations panel.
// Plan reference: E8 follow-on (operator UI).

const BASE = '/system/platform/storage_migrations';

function paramsFromFilters<T extends Record<string, unknown>>(filters?: T): Record<string, string> {
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
};
