// API client for System::ModuleBuildBatch (campaign 019f6084 inc2-A read API
// + inc5 frontend) — the agent-pollable build-completion barrier over both
// platform module builds (trigger push/manual/cve) and on-demand
// package-closure builds (trigger "package"). Read-only: dispatch itself
// stays worker/webhook-gated (system.module_builds.dispatch) — a Phase-2
// "Trigger build" action is out of scope for this client.
//
// Backend: Api::V1::System::ModuleBuildBatchesController
//   index/show → system.module_builds.read
import { apiClient } from '@/shared/services/apiClient';
import type {
  SystemModuleBuildBatch,
  SystemModuleBuildBatchFull,
} from '@system/features/system/types/system.types';
import { extractData, extractPaginated } from './helpers';
import type { ApiEnvelope, PaginatedEnvelope, PaginationMeta } from './types';

export interface ModuleBuildBatchListFilters {
  status?: string;
  trigger?: string;
  shadow?: boolean;
}

export const moduleBuildsApi = {
  list: async (
    filters?: ModuleBuildBatchListFilters
  ): Promise<{ module_build_batches: SystemModuleBuildBatch[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<
      PaginatedEnvelope<{ module_build_batches: SystemModuleBuildBatch[] }>
    >('/system/module_build_batches', { params: filters });
    return extractPaginated(response);
  },

  get: async (id: string): Promise<SystemModuleBuildBatchFull> => {
    const response = await apiClient.get<
      ApiEnvelope<{ module_build_batch: SystemModuleBuildBatchFull }>
    >(`/system/module_build_batches/${id}`);
    return extractData(response).module_build_batch;
  },
};
