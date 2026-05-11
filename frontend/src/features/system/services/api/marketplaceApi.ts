import { apiClient } from '@/shared/services/apiClient';
import { extractData, extractPaginated } from './helpers';
import type { ApiEnvelope, PaginatedEnvelope, PaginationParams } from './types';

export interface MarketplaceModuleCard {
  id: string;
  name: string;
  description?: string;
  variety: string;
  priority: number;
  trust_tier: 'community' | 'verified-publisher' | 'internal' | string;
  category?: string;
  platform?: string;
  current_version_number: number;
  assignment_count: number;
  updated_at: string;
}

export interface MarketplaceModuleDetail extends MarketplaceModuleCard {
  manifest_yaml?: Record<string, unknown> | null;
  file_spec?: unknown;
  mask?: unknown;
  package_spec?: unknown;
  dependency_spec?: unknown;
  protected_spec?: unknown;
  consent_budget_per_day?: number | null;
  cosign_identity_regexp?: string | null;
  cosign_issuer_regexp?: string | null;
  gitea_repo_full_name?: string | null;
}

export interface MarketplaceVersion {
  id: string;
  version_number: number;
  changelog?: string | null;
  created_at: string;
}

export interface MarketplaceDependency {
  id: string;
  required_module_id: string;
  required_module_name?: string | null;
  required_version?: string | null;
}

export interface MarketplaceFilters extends PaginationParams {
  trust_tier?: string;
  category_id?: string;
  search?: string;
}

export const marketplaceApi = {
  async list(filters: MarketplaceFilters = {}) {
    const params = new URLSearchParams();
    Object.entries(filters).forEach(([k, v]) => {
      if (v !== undefined && v !== null && v !== '') params.set(k, String(v));
    });
    const url = `/system/marketplace?${params.toString()}`;
    const response = await apiClient.get<PaginatedEnvelope<{ modules: MarketplaceModuleCard[] }>>(url);
    return extractPaginated(response);
  },

  async get(id: string) {
    const url = `/system/marketplace/${id}`;
    const response = await apiClient.get<ApiEnvelope<{
      module: MarketplaceModuleDetail;
      recent_versions: MarketplaceVersion[];
      dependencies: MarketplaceDependency[];
    }>>(url);
    return extractData(response);
  },
};
