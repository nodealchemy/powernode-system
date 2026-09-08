import { apiClient } from '@/shared/services/apiClient';
import { extractData, paramsFromFilters } from './helpers';
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
