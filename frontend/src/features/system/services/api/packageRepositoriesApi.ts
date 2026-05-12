import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope, PaginationParams } from './types';

export type PackageRepositoryKind = 'apt' | 'rpm' | 'dnf';
export type PackageRepositoryVisibility = 'account' | 'shared';
export type SyncStatus = 'idle' | 'syncing' | 'failed';

export interface SystemPackageRepository {
  id: string;
  name: string;
  description?: string;
  kind: PackageRepositoryKind;
  visibility: PackageRepositoryVisibility;
  base_url: string;
  architectures: string[];
  priority: number;
  enabled: boolean;
  sync_status: SyncStatus;
  last_synced_at?: string;
  last_sync_error?: string;
  package_count: number;
  shared: boolean;
  // M:N to NodePlatform via system_package_repository_platforms.
  // Always returned as an array (possibly empty for platform-agnostic
  // shared repos like Debian stable / Ubuntu noble).
  node_platform_ids: string[];
  // Detail-only: full {id, name} for each linked platform.
  node_platforms?: Array<{ id: string; name: string }>;
  apt_config?: Record<string, unknown>;
  rpm_config?: Record<string, unknown>;
  has_signing_key?: boolean;
  created_at: string;
  updated_at: string;
}

export interface SystemPackage {
  id: string;
  name: string;
  version: string;
  architecture: string;
  section?: string;
  summary?: string;
  description?: string;
  installed_size_bytes?: number;
  download_size_bytes?: number;
  homepage?: string;
  license?: string;
  package_repository_id: string;
  depends?: Array<Array<{ name: string; op?: string; version?: string }>>;
  recommends?: Array<Array<{ name: string; op?: string; version?: string }>>;
  provides?: Array<Array<{ name: string; op?: string; version?: string }>>;
}

export interface PackageRepositoryCreate {
  name: string;
  description?: string;
  kind: PackageRepositoryKind;
  visibility?: PackageRepositoryVisibility;
  base_url: string;
  architectures?: string[];
  apt_config?: { suite?: string; components?: string[] };
  rpm_config?: { releasever?: string; gpgcheck?: boolean; metalink?: string };
  signing_key_armor?: string;
  // Optional pre-linked platforms for M:N. Empty/omitted = platform-
  // agnostic; cross-account validation enforced server-side.
  node_platform_ids?: string[];
  priority?: number;
  enabled?: boolean;
}

export interface ResolveDependenciesPreview {
  required_packages: Array<{ name: string; version: string; architecture: string; summary?: string; installed_size_bytes?: number }>;
  required_edges: Array<{ from: string; to: string; type: string; constraint?: string }>;
  recommends_candidates: Array<{
    from: string;
    to: string;
    summary?: string;
    installed_size_bytes: number;
    transitive_required_if_chosen: string[];
  }>;
  suggests_candidates: Array<{ from: string; to: string; summary?: string }>;
  alternatives_chosen: Record<string, string>;
  warnings: string[];
  conflicts?: unknown[];
  errors: string[];
}

export interface CreateModuleResult {
  top_level_module: { id: string; name: string; auto_generated: boolean; public: boolean };
  dependency_modules: Array<{ id: string; name: string }>;
  recommends_modules: Array<{ id: string; name: string }>;
  dependencies_created: number;
  build_dispatches: Array<{ dispatch_id: string; architecture: string; ok: boolean; error?: string }>;
  warnings: string[];
}

export const packageRepositoriesApi = {
  list: async (params?: {
    kind?: PackageRepositoryKind;
    node_platform_ids?: string[];
  }): Promise<SystemPackageRepository[]> => {
    const response = await apiClient.get<ApiEnvelope<{ package_repositories: SystemPackageRepository[] }>>(
      '/system/package_repositories',
      { params },
    );
    return extractData(response).package_repositories;
  },

  get: async (id: string): Promise<SystemPackageRepository> => {
    const response = await apiClient.get<ApiEnvelope<{ package_repository: SystemPackageRepository }>>(
      `/system/package_repositories/${id}`,
    );
    return extractData(response).package_repository;
  },

  create: async (data: PackageRepositoryCreate): Promise<SystemPackageRepository> => {
    const response = await apiClient.post<ApiEnvelope<{ package_repository: SystemPackageRepository }>>(
      '/system/package_repositories',
      { package_repository: data },
    );
    return extractData(response).package_repository;
  },

  update: async (id: string, data: Partial<PackageRepositoryCreate>): Promise<SystemPackageRepository> => {
    const response = await apiClient.put<ApiEnvelope<{ package_repository: SystemPackageRepository }>>(
      `/system/package_repositories/${id}`,
      { package_repository: data },
    );
    return extractData(response).package_repository;
  },

  delete: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/package_repositories/${id}`);
  },

  sync: async (id: string): Promise<{ ok: boolean; upserted: number; obsoleted: number; package_count: number; error?: string }> => {
    const response = await apiClient.post<ApiEnvelope<{ ok: boolean; upserted: number; obsoleted: number; package_count: number; error?: string }>>(
      `/system/package_repositories/${id}/sync`,
      {},
    );
    return extractData(response);
  },

  // M:N — link a NodePlatform to this repository. Server enforces
  // cross-account integrity (account-scoped repos can only link
  // platforms in the same account; shared repos can link anywhere).
  linkPlatform: async (
    id: string,
    nodePlatformId: string,
  ): Promise<{ package_repository_id: string; node_platform_id: string; linked: boolean }> => {
    const response = await apiClient.post<
      ApiEnvelope<{ package_repository_id: string; node_platform_id: string; linked: boolean }>
    >(`/system/package_repositories/${id}/link_platform`, { node_platform_id: nodePlatformId });
    return extractData(response);
  },

  unlinkPlatform: async (
    id: string,
    nodePlatformId: string,
  ): Promise<{ package_repository_id: string; node_platform_id: string; linked: boolean }> => {
    const response = await apiClient.delete<
      ApiEnvelope<{ package_repository_id: string; node_platform_id: string; linked: boolean }>
    >(`/system/package_repositories/${id}/unlink_platform`, {
      data: { node_platform_id: nodePlatformId },
    });
    return extractData(response);
  },
};

export const packagesApi = {
  search: async (params: {
    q?: string;
    repository_id?: string;
    section?: string;
    architecture?: string;
    page?: number;
    per_page?: number;
  }): Promise<{ packages: SystemPackage[]; total: number; page: number; per_page: number }> => {
    const response = await apiClient.get<ApiEnvelope<{ packages: SystemPackage[]; meta: { total: number; page: number; per_page: number } }>>(
      '/system/packages',
      { params },
    );
    const data = extractData(response);
    return { packages: data.packages, ...data.meta };
  },

  get: async (id: string): Promise<SystemPackage> => {
    const response = await apiClient.get<ApiEnvelope<{ package: SystemPackage }>>(`/system/packages/${id}`);
    return extractData(response).package;
  },

  resolveDependencies: async (params: {
    repository_id: string;
    package_name: string;
    architecture: string;
  }): Promise<ResolveDependenciesPreview> => {
    const response = await apiClient.post<ApiEnvelope<ResolveDependenciesPreview>>(
      '/system/packages/resolve_dependencies',
      params,
    );
    return extractData(response);
  },

  createModuleFromPackage: async (params: {
    repository_id: string;
    package_name: string;
    architectures: string[];
    recommends_selected?: string[];
    category_id?: string;
    dispatch_build?: boolean;
  }): Promise<CreateModuleResult> => {
    const response = await apiClient.post<ApiEnvelope<CreateModuleResult>>(
      '/system/packages/create_module',
      params,
    );
    return extractData(response);
  },

  // T2.B — fleet-aware architecture suggestion. Returns canonical arch
  // names ranked by NodePlatform coverage intersected with repo support.
  // Used by CreateModuleFromPackageModal to pre-populate the materialize
  // form so operators don't manually pick arches when the fleet's shape
  // already implies the answer.
  suggestArchitectures: async (params: {
    repository_id: string;
    max_suggestions?: number;
  }): Promise<SuggestArchitecturesResult> => {
    const response = await apiClient.post<ApiEnvelope<SuggestArchitecturesResult>>(
      '/system/packages/suggest_architectures',
      params,
    );
    return extractData(response);
  },
};

export interface SuggestArchitecturesResult {
  repository_id: string;
  suggested: string[];
  rationale: Array<{
    arch?: string;
    node_platforms?: number;
    packages?: number;
    reason: string;
  }>;
  fallback: boolean;
  confidence: 'high' | 'medium' | 'low';
}
