import { apiClient } from '@/shared/services/apiClient';
import type { SystemPuppetModule, SystemPuppetResource } from '../../types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface PuppetModuleCreate {
  name: string;
  description?: string;
  version?: string;
  author?: string;
  license?: string;
  source_url?: string;
  project_url?: string;
  forge_name?: string;
  enabled?: boolean;
  public?: boolean;
  dependencies?: Array<{ name: string; version_requirement?: string }>;
  config?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
}

export interface PuppetResourceCreate {
  name: string;
  description?: string;
  resource_type: string;
  title?: string;
  path?: string;
  data?: string;
  enabled?: boolean;
  exported?: boolean;
  parameters?: Record<string, unknown>;
  config?: Record<string, unknown>;
}

// Assignment shape varies (cross-references node_modules / puppet_modules)
// — leave permissive until a dedicated PuppetAssignment type is defined.
export type PuppetAssignment = {
  id: string;
  puppet_module_id: string;
} & Record<string, unknown>;

export const puppetApi = {
  // ===== Puppet Modules =====
  getPuppetModules: async (
    params?: PaginationParams
  ): Promise<{ puppetModules: SystemPuppetModule[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<PaginatedEnvelope<{ puppet_modules: SystemPuppetModule[] }>>(
      '/system/puppet_modules',
      { params }
    );
    const { puppet_modules, meta } = extractPaginated(response);
    return { puppetModules: puppet_modules ?? [], meta };
  },

  getPuppetModule: async (id: string): Promise<SystemPuppetModule> => {
    const response = await apiClient.get<ApiEnvelope<{ puppet_module: SystemPuppetModule }>>(
      `/system/puppet_modules/${id}`
    );
    return extractData(response).puppet_module;
  },

  createPuppetModule: async (data: PuppetModuleCreate): Promise<SystemPuppetModule> => {
    const response = await apiClient.post<ApiEnvelope<{ puppet_module: SystemPuppetModule }>>(
      '/system/puppet_modules',
      { puppet_module: data }
    );
    return extractData(response).puppet_module;
  },

  updatePuppetModule: async (
    id: string,
    data: Partial<PuppetModuleCreate>
  ): Promise<SystemPuppetModule> => {
    const response = await apiClient.put<ApiEnvelope<{ puppet_module: SystemPuppetModule }>>(
      `/system/puppet_modules/${id}`,
      { puppet_module: data }
    );
    return extractData(response).puppet_module;
  },

  deletePuppetModule: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/puppet_modules/${id}`);
  },

  // ===== Puppet Resources =====
  getPuppetResources: async (puppetModuleId: string): Promise<SystemPuppetResource[]> => {
    const response = await apiClient.get<ApiEnvelope<{ puppet_resources: SystemPuppetResource[] }>>(
      `/system/puppet_modules/${puppetModuleId}/puppet_resources`
    );
    return extractData(response).puppet_resources ?? [];
  },

  getPuppetResource: async (
    puppetModuleId: string,
    resourceId: string
  ): Promise<SystemPuppetResource> => {
    const response = await apiClient.get<ApiEnvelope<{ puppet_resource: SystemPuppetResource }>>(
      `/system/puppet_modules/${puppetModuleId}/puppet_resources/${resourceId}`
    );
    return extractData(response).puppet_resource;
  },

  createPuppetResource: async (
    puppetModuleId: string,
    data: PuppetResourceCreate
  ): Promise<SystemPuppetResource> => {
    const response = await apiClient.post<ApiEnvelope<{ puppet_resource: SystemPuppetResource }>>(
      `/system/puppet_modules/${puppetModuleId}/puppet_resources`,
      { puppet_resource: data }
    );
    return extractData(response).puppet_resource;
  },

  updatePuppetResource: async (
    puppetModuleId: string,
    resourceId: string,
    data: Partial<PuppetResourceCreate>
  ): Promise<SystemPuppetResource> => {
    const response = await apiClient.put<ApiEnvelope<{ puppet_resource: SystemPuppetResource }>>(
      `/system/puppet_modules/${puppetModuleId}/puppet_resources/${resourceId}`,
      { puppet_resource: data }
    );
    return extractData(response).puppet_resource;
  },

  deletePuppetResource: async (puppetModuleId: string, resourceId: string): Promise<void> => {
    await apiClient.delete(`/system/puppet_modules/${puppetModuleId}/puppet_resources/${resourceId}`);
  },

  getPuppetResourceDsl: async (puppetModuleId: string, resourceId: string): Promise<string> => {
    const response = await apiClient.get<ApiEnvelope<{ puppet_dsl: string }>>(
      `/system/puppet_modules/${puppetModuleId}/puppet_resources/${resourceId}/puppet_dsl`
    );
    return extractData(response).puppet_dsl ?? '';
  },

  // ===== Puppet Module Assignments =====
  getPuppetModuleAssignments: async (puppetModuleId: string): Promise<PuppetAssignment[]> => {
    const response = await apiClient.get<ApiEnvelope<{ assignments: PuppetAssignment[] }>>(
      `/system/puppet_modules/${puppetModuleId}/assignments`
    );
    return extractData(response).assignments ?? [];
  },
};
