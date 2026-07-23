import { apiClient } from '@/shared/services/apiClient';
import type {
  SystemNodeModule,
  SystemNodeModuleCategory,
  SystemNodeModuleVersion,
  SystemModulePromotionState,
  SystemModuleVersionsResponse,
  SystemModuleRollbackResponse,
} from '../../types/system.types';
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
  // Spec fields. Send as scalar newline-joined strings (the form-friendly
  // shape — the model's encode_specs callback base64-encodes each line on
  // save). Already-encoded arrays are also accepted for programmatic
  // clients that already have the wire shape.
  mask?: string | string[];
  file_spec?: string | string[];
  package_spec?: string | string[];
  dependency_spec?: string | string[];
  // protected_spec: paths I CLAIM. The build pipeline folds these into
  // every neighbor's effective_mask, preventing union-mount overrides
  // of paths I own (e.g. /etc/shadow shipped by system-base).
  protected_spec?: string | string[];
  // Lifecycle / lock state
  lock_spec?: boolean;
  init_start?: string;
  init_stop?: string;
  init_restart?: string;
  reboot_required?: boolean;
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
  version_constraint?: string;
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
  // getModuleDependencies stays on the read-only NodeModulesController
  // member action (/dependencies) -- a different, derived view (dependencies
  // + dependents) than the module_dependencies CRUD resource below.
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
    await apiClient.post(`/system/node_modules/${moduleId}/module_dependencies`, {
      dependency: { dependency_id: dependencyId, ...data },
    });
  },

  removeModuleDependency: async (moduleId: string, dependencyId: string): Promise<void> => {
    await apiClient.delete(`/system/node_modules/${moduleId}/module_dependencies/${dependencyId}`);
  },

  // ===== Manifest import =====
  // Posts a manifest.yaml payload to the import endpoint, which parses it
  // and writes the declared spec/lifecycle fields onto the module. Pass
  // create_version: true to also snapshot the parsed state into a new
  // NodeModuleVersion (used by the Gitea push webhook ingest path).
  importManifest: async (
    moduleId: string,
    yaml: string,
    options: { createVersion?: boolean; changelog?: string } = {}
  ): Promise<{
    node_module: SystemNodeModule;
    node_module_version_id: string | null;
    resolved_dependencies: Array<{ repo: string; constraint?: string; status: string }>;
  }> => {
    const response = await apiClient.post<ApiEnvelope<{
      node_module: SystemNodeModule;
      node_module_version_id: string | null;
      resolved_dependencies: Array<{ repo: string; constraint?: string; status: string }>;
    }>>(
      `/system/node_modules/${moduleId}/import_manifest`,
      {
        yaml,
        create_version: options.createVersion ?? false,
        changelog: options.changelog,
      },
    );
    return extractData(response);
  },

  // ===== Honeypot canary toggle =====
  // Backend routes: POST /system/node_modules/:id/{mark,unmark}_canary
  // (System::Honeypot::CanaryModuleService — flips a config flag on the
  // module that HoneypotAccessSensor watches for unexpected reads).
  markModuleAsCanary: async (moduleId: string, lureKind?: string): Promise<SystemNodeModule> => {
    const response = await apiClient.post<ApiEnvelope<{ node_module: SystemNodeModule }>>(
      `/system/node_modules/${moduleId}/mark_canary`,
      lureKind ? { lure_kind: lureKind } : {},
    );
    return extractData(response).node_module;
  },

  unmarkModuleAsCanary: async (moduleId: string): Promise<SystemNodeModule> => {
    const response = await apiClient.post<ApiEnvelope<{ node_module: SystemNodeModule }>>(
      `/system/node_modules/${moduleId}/unmark_canary`,
      {},
    );
    return extractData(response).node_module;
  },

  // ===== Version lifecycle (IMP-c4235dad3779) =====
  // Backend routes: GET /system/node_modules/:id/versions (history +
  // current-version pointer), POST /system/node_module_versions/:id/promote
  // (AASM built → staging → blessed → live → retired), and
  // POST /system/node_modules/:id/rollback (repoint the module spec at a
  // prior version; empty body = previous version).
  getModuleVersions: async (moduleId: string): Promise<SystemModuleVersionsResponse> => {
    const response = await apiClient.get<ApiEnvelope<SystemModuleVersionsResponse>>(
      `/system/node_modules/${moduleId}/versions`
    );
    const data = extractData(response);
    return {
      versions: data.versions ?? [],
      current_version_id: data.current_version_id ?? null,
      current_version_number: data.current_version_number ?? null,
    };
  },

  promoteModuleVersion: async (
    versionId: string,
    targetState: SystemModulePromotionState
  ): Promise<SystemNodeModuleVersion> => {
    const response = await apiClient.post<ApiEnvelope<{
      node_module_version: SystemNodeModuleVersion;
    }>>(
      `/system/node_module_versions/${versionId}/promote`,
      { target_state: targetState },
    );
    return extractData(response).node_module_version;
  },

  rollbackModule: async (
    moduleId: string,
    options: { targetVersionId?: string; changelog?: string } = {}
  ): Promise<SystemModuleRollbackResponse> => {
    const body: Record<string, string> = {};
    if (options.targetVersionId) body.target_version_id = options.targetVersionId;
    if (options.changelog) body.changelog = options.changelog;

    const response = await apiClient.post<ApiEnvelope<SystemModuleRollbackResponse>>(
      `/system/node_modules/${moduleId}/rollback`,
      body,
    );
    return extractData(response);
  },
};
