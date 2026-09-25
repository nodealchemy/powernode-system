// API client for System::ModuleBuildBatch (campaign 019f6084 inc2-A read API
// + inc5 frontend) — the agent-pollable build-completion barrier over both
// platform module builds (trigger push/manual/cve) and on-demand
// package-closure builds (trigger "package"). Dispatch itself stays
// worker/webhook-gated (system.module_builds.dispatch) — no "Trigger build"
// action here.
//
// fc-34: cancel() ported from the deleted core moduleBuildBatchesApi.ts (the
// core Module Builds pages fronted this same extension endpoint by URL string
// only). This is now the one client for System::ModuleBuildBatch.
//
// Backend: Api::V1::System::ModuleBuildBatchesController
//   index/show → system.module_builds.read
//   cancel     → system.module_builds.cancel
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

  cancel: async (id: string, reason?: string): Promise<SystemModuleBuildBatchFull> => {
    const response = await apiClient.post<
      ApiEnvelope<{ module_build_batch: SystemModuleBuildBatchFull }>
    >(`/system/module_build_batches/${id}/cancel`, reason ? { reason } : {});
    return extractData(response).module_build_batch;
  },
};
