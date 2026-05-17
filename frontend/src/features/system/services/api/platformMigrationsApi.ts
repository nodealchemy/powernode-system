import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  MigrationDetail,
  MigrationListFilters,
  MigrationListResponse,
} from '../../types/migration.types';

// Operator-side read-only API client for the Migrations panel.
//
// Plan reference: Decentralized Federation §F + §I + P5 + P7.4.

const BASE = '/system/platform/migrations';

function paramsFromFilters<T extends Record<string, unknown>>(filters?: T): Record<string, string> {
  if (!filters) return {};
  const out: Record<string, string> = {};
  Object.entries(filters).forEach(([key, value]) => {
    if (value === undefined || value === null) return;
    if (Array.isArray(value)) {
      if (value.length > 0) out[key] = value.join(',');
    } else {
      out[key] = String(value);
    }
  });
  return out;
}

export const platformMigrationsApi = {
  list: async (filters?: MigrationListFilters): Promise<MigrationListResponse> => {
    const response = await apiClient.get<ApiEnvelope<MigrationListResponse>>(BASE, {
      params: paramsFromFilters(filters),
    });
    return extractData(response);
  },

  get: async (id: string): Promise<MigrationDetail> => {
    const response = await apiClient.get<ApiEnvelope<{ migration: MigrationDetail }>>(
      `${BASE}/${id}`,
    );
    return extractData(response).migration;
  },
};
