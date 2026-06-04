// API client for the GitOps reconciler (M-D2-3). Each GitopsRepository
// describes a desired fleet state in git; a reconciler ticks every 5 minutes
// per enabled repo, diffs desired vs. live state, and opens AgentProposal
// rows. `syncNow` fires an off-schedule tick ("I just pushed a fix; reconcile
// now") and `syncRuns` returns the per-tick audit log.
//
// Backend: Api::V1::System::GitopsRepositoriesController
//   index/show/sync_runs → system.gitops.read
//   create/update/destroy → system.gitops.write
//   sync_now              → system.gitops.sync
import { apiClient } from '@/shared/services/apiClient';
import type {
  SystemGitopsRepository,
  SystemGitopsSyncRun,
  SystemGitopsSyncResult,
} from '@system/features/system/types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface GitopsRepositoryFilters extends PaginationParams {
  enabled?: boolean;
}

export interface GitopsRepositoryCreate {
  name: string;
  repo_url: string;
  branch?: string;
  path_prefix?: string;
  vault_credential_path?: string;
  enabled?: boolean;
  auto_apply?: boolean;
  metadata?: Record<string, unknown>;
}

export type GitopsRepositoryUpdate = Partial<GitopsRepositoryCreate>;

export const gitopsApi = {
  list: async (
    params?: GitopsRepositoryFilters
  ): Promise<{ gitops_repositories: SystemGitopsRepository[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<
      PaginatedEnvelope<{ gitops_repositories: SystemGitopsRepository[] }>
    >('/system/gitops_repositories', { params });
    return extractPaginated(response);
  },

  get: async (
    id: string
  ): Promise<{ gitops_repository: SystemGitopsRepository; recent_runs: SystemGitopsSyncRun[] }> => {
    const response = await apiClient.get<
      ApiEnvelope<{ gitops_repository: SystemGitopsRepository; recent_runs: SystemGitopsSyncRun[] }>
    >(`/system/gitops_repositories/${id}`);
    return extractData(response);
  },

  create: async (data: GitopsRepositoryCreate): Promise<SystemGitopsRepository> => {
    const response = await apiClient.post<ApiEnvelope<{ gitops_repository: SystemGitopsRepository }>>(
      '/system/gitops_repositories',
      { gitops_repository: data }
    );
    return extractData(response).gitops_repository;
  },

  update: async (id: string, data: GitopsRepositoryUpdate): Promise<SystemGitopsRepository> => {
    const response = await apiClient.patch<ApiEnvelope<{ gitops_repository: SystemGitopsRepository }>>(
      `/system/gitops_repositories/${id}`,
      { gitops_repository: data }
    );
    return extractData(response).gitops_repository;
  },

  destroy: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/gitops_repositories/${id}`);
  },

  // Fires an off-schedule reconciliation tick (member route). Returns the
  // completed sync run plus the diff/proposal summary.
  syncNow: async (id: string): Promise<SystemGitopsSyncResult> => {
    const response = await apiClient.post<ApiEnvelope<SystemGitopsSyncResult>>(
      `/system/gitops_repositories/${id}/sync_now`,
      {}
    );
    return extractData(response);
  },

  // Per-tick audit log (most recent 50). Member route.
  syncRuns: async (id: string): Promise<SystemGitopsSyncRun[]> => {
    const response = await apiClient.get<ApiEnvelope<{ sync_runs: SystemGitopsSyncRun[] }>>(
      `/system/gitops_repositories/${id}/sync_runs`
    );
    return extractData(response).sync_runs ?? [];
  },
};
