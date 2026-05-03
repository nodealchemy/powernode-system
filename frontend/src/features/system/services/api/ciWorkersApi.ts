// API client for per-account CI workers (narrowly-scoped Worker rows
// holding the ci_worker role). The plaintext token is returned
// EXACTLY ONCE on create + rotate — UI must capture and display it
// for the operator to store in their CI's secret manager
// (POWERNODE_CI_WORKER_TOKEN env var convention).
//
// Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 4).
import { apiClient } from '@/shared/services/apiClient';
import type {
  SystemCiWorker,
  SystemCiWorkerCreatedResponse,
} from '@system/features/system/types/system.types';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export const ciWorkersApi = {
  list: async (): Promise<SystemCiWorker[]> => {
    const response = await apiClient.get<ApiEnvelope<{
      ci_workers: SystemCiWorker[];
    }>>('/system/ci_workers');
    return extractData(response).ci_workers ?? [];
  },

  get: async (id: string): Promise<SystemCiWorker> => {
    const response = await apiClient.get<ApiEnvelope<{
      ci_worker: SystemCiWorker;
    }>>(`/system/ci_workers/${id}`);
    return extractData(response).ci_worker;
  },

  // Returns plaintext token EXACTLY ONCE.
  create: async (name: string, description?: string): Promise<SystemCiWorkerCreatedResponse> => {
    const response = await apiClient.post<ApiEnvelope<SystemCiWorkerCreatedResponse>>(
      '/system/ci_workers',
      { name, description },
    );
    return extractData(response);
  },

  destroy: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/ci_workers/${id}`);
  },

  // Returns NEW plaintext token EXACTLY ONCE. Old token is revoked
  // immediately — operator must update CI before the next CI run.
  rotateToken: async (id: string): Promise<SystemCiWorkerCreatedResponse> => {
    const response = await apiClient.post<ApiEnvelope<SystemCiWorkerCreatedResponse>>(
      `/system/ci_workers/${id}/rotate_token`,
      {},
    );
    return extractData(response);
  },
};
