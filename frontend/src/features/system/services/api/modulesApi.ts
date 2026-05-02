import { apiClient } from '@/shared/services/apiClient';
import type { SystemNodeModule, SystemNodeModuleCategory } from '../../types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface ModuleFilters extends PaginationParams {
  variety?: 'config' | 'instance' | 'subscription';
  enabled?: boolean;
}

export interface NodeModuleScopedFilters extends PaginationParams {
  node_id?: string;
}

export interface ModuleCreate {
  name: string;
  description?: string;
  variety: 'config' | 'instance' | 'subscription';
  node_platform_id?: string;
  category_id?: string;
  priority?: number;
  enabled?: boolean;
  public?: boolean;
  // Per-module autonomy controls (Golden Eclipse Block R consent budget).
  // Null disables enforcement; integer caps decisions per 24-hour window.
  consent_budget_per_day?: number | null;
  consent_budget_used_count?: number;
  consent_budget_window_start_at?: string | null;
  mask?: Record<string, unknown>;
  file_spec?: Record<string, unknown>;
  config?: Record<string, unknown>;
}

export interface ModuleCategoryCreate {
  name: string;
  description?: string;
  parent_id?: string;
  enabled?: boolean;
}

export interface ModuleDependencyOptions {
  dependency_type?: string;
  required?: boolean;
  version_requirement?: string;
}

// Backend collection key is `node_modules`; expose under the shorter
// `modules` key for caller ergonomics.
export const modulesApi = {
  // ===== Node Modules =====
  getModules: async (
    params?: ModuleFilters
  ): Promise<{ modules: SystemNodeModule[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<PaginatedEnvelope<{ node_modules: SystemNodeModule[] }>>(
      '/system/node_modules',
      { params }
    );
    const { node_modules, meta } = extractPaginated(response);
    return { modules: node_modules ?? [], meta };
  },

  getNodeModules: async (
    params?: NodeModuleScopedFilters
  ): Promise<{ node_modules: SystemNodeModule[] }> => {
    const response = await apiClient.get<ApiEnvelope<{ node_modules: SystemNodeModule[] }>>(
      '/system/node_modules',
      { params }
    );
    return { node_modules: extractData(response).node_modules ?? [] };
  },

  getModule: async (id: string): Promise<SystemNodeModule> => {
    const response = await apiClient.get<ApiEnvelope<{ node_module: SystemNodeModule }>>(
      `/system/node_modules/${id}`
    );
    return extractData(response).node_module;
  },

  createModule: async (data: ModuleCreate): Promise<SystemNodeModule> => {
    const response = await apiClient.post<ApiEnvelope<{ node_module: SystemNodeModule }>>(
      '/system/node_modules',
      { node_module: data }
    );
    return extractData(response).node_module;
  },

  updateModule: async (id: string, data: Partial<ModuleCreate>): Promise<SystemNodeModule> => {
    const response = await apiClient.put<ApiEnvelope<{ node_module: SystemNodeModule }>>(
      `/system/node_modules/${id}`,
      { node_module: data }
    );
    return extractData(response).node_module;
  },

  deleteModule: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/node_modules/${id}`);
  },

  // ===== Module Categories =====
  getModuleCategories: async (): Promise<SystemNodeModuleCategory[]> => {
    const response = await apiClient.get<ApiEnvelope<{ node_module_categories: SystemNodeModuleCategory[] }>>(
      '/system/node_module_categories'
    );
    return extractData(response).node_module_categories ?? [];
  },

  getModuleCategory: async (id: string): Promise<SystemNodeModuleCategory> => {
    const response = await apiClient.get<ApiEnvelope<{ node_module_category: SystemNodeModuleCategory }>>(
      `/system/node_module_categories/${id}`
    );
    return extractData(response).node_module_category;
  },

  createModuleCategory: async (data: ModuleCategoryCreate): Promise<SystemNodeModuleCategory> => {
    const response = await apiClient.post<ApiEnvelope<{ node_module_category: SystemNodeModuleCategory }>>(
      '/system/node_module_categories',
      { node_module_category: data }
    );
    return extractData(response).node_module_category;
  },

  updateModuleCategory: async (
    id: string,
    data: Partial<ModuleCategoryCreate>
  ): Promise<SystemNodeModuleCategory> => {
    const response = await apiClient.put<ApiEnvelope<{ node_module_category: SystemNodeModuleCategory }>>(
      `/system/node_module_categories/${id}`,
      { node_module_category: data }
    );
    return extractData(response).node_module_category;
  },

  deleteModuleCategory: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/node_module_categories/${id}`);
  },

  // ===== Module Dependencies =====
  getModuleDependencies: async (moduleId: string): Promise<SystemNodeModule[]> => {
    const response = await apiClient.get<ApiEnvelope<{ dependencies: SystemNodeModule[] }>>(
      `/system/node_modules/${moduleId}/dependencies`
    );
    return extractData(response).dependencies ?? [];
  },

  addModuleDependency: async (
    moduleId: string,
    dependencyId: string,
    data?: ModuleDependencyOptions
  ): Promise<void> => {
    await apiClient.post(`/system/node_modules/${moduleId}/dependencies`, {
      module_dependency: { dependency_id: dependencyId, ...data },
    });
  },

  removeModuleDependency: async (moduleId: string, dependencyId: string): Promise<void> => {
    await apiClient.delete(`/system/node_modules/${moduleId}/dependencies/${dependencyId}`);
  },
};
