import { apiClient } from '@/shared/services/apiClient';
import type { SystemNodeTemplate, SystemNodeModule } from '../../types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface TemplateCreate {
  name: string;
  description?: string;
  node_platform_id?: string;
  admin_user?: string;
  enabled?: boolean;
  public?: boolean;
  config?: Record<string, unknown>;
}

// TemplateModule join row returned by `assignModuleToTemplate`.
export interface TemplateModuleAssignment {
  id: string;
  node_template_id: string;
  node_module_id: string;
  enabled: boolean;
  priority: number;
}

// Backend `index` response wraps the collection in `node_templates`, but the
// platform-facing key in the result is `templates` for caller convenience.
// Inline the rename so callers stay terse.
export const templatesApi = {
  getTemplates: async (params?: PaginationParams): Promise<{ templates: SystemNodeTemplate[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<PaginatedEnvelope<{ node_templates: SystemNodeTemplate[] }>>(
      '/system/node_templates',
      { params }
    );
    const { node_templates, meta } = extractPaginated(response);
    return { templates: node_templates ?? [], meta };
  },

  getTemplate: async (id: string): Promise<SystemNodeTemplate> => {
    const response = await apiClient.get<ApiEnvelope<{ node_template: SystemNodeTemplate }>>(
      `/system/node_templates/${id}`
    );
    return extractData(response).node_template;
  },

  createTemplate: async (data: TemplateCreate): Promise<SystemNodeTemplate> => {
    const response = await apiClient.post<ApiEnvelope<{ node_template: SystemNodeTemplate }>>(
      '/system/node_templates',
      { node_template: data }
    );
    return extractData(response).node_template;
  },

  updateTemplate: async (id: string, data: Partial<TemplateCreate>): Promise<SystemNodeTemplate> => {
    const response = await apiClient.put<ApiEnvelope<{ node_template: SystemNodeTemplate }>>(
      `/system/node_templates/${id}`,
      { node_template: data }
    );
    return extractData(response).node_template;
  },

  deleteTemplate: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/node_templates/${id}`);
  },

  // Download a portable template bundle. Triggers a browser save dialog using
  // the filename provided by the backend's Content-Disposition header.
  exportTemplate: async (id: string): Promise<void> => {
    const response = await apiClient.get<Blob>(`/system/node_templates/${id}/export`, {
      responseType: 'blob'
    });

    const disposition = response.headers?.['content-disposition'] || '';
    const match = disposition.match(/filename="?([^";]+)"?/i);
    const filename = match?.[1] || `system-template-${id}.json`;

    const blob = response.data instanceof Blob
      ? response.data
      : new Blob([JSON.stringify(response.data, null, 2)], { type: 'application/json' });

    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  },

  getTemplateModules: async (templateId: string): Promise<{ modules: SystemNodeModule[] }> => {
    const response = await apiClient.get<ApiEnvelope<{ node_modules: SystemNodeModule[] }>>(
      `/system/node_templates/${templateId}/modules`
    );
    return { modules: extractData(response).node_modules ?? [] };
  },

  // Attach a module to a template (creates a TemplateModule join row). Posts to
  // the same /modules path as the GET above (routed by verb server-side).
  // Reachable via `systemApi.assignModuleToTemplate(...)` through the aggregator
  // spread — the Visual Template Composer's SaveTemplateModal calls it once per
  // chosen module.
  assignModuleToTemplate: async (
    templateId: string,
    moduleId: string
  ): Promise<TemplateModuleAssignment> => {
    const response = await apiClient.post<ApiEnvelope<{ template_module: TemplateModuleAssignment }>>(
      `/system/node_templates/${templateId}/modules`,
      { node_module_id: moduleId }
    );
    return extractData(response).template_module;
  },

  // Detach a module from a template (destroys its TemplateModule join row).
  // The member id in the path is the NODE_MODULE id — symmetric with
  // `assignModuleToTemplate`, which keys off the module id. Reachable via
  // `systemApi.unassignModuleFromTemplate(...)` through the aggregator spread;
  // the TemplateDetailModal's Modules tab calls it per-module to remove.
  unassignModuleFromTemplate: async (templateId: string, moduleId: string): Promise<void> => {
    await apiClient.delete(`/system/node_templates/${templateId}/modules/${moduleId}`);
  },

  // Visual Template Composer (M-FE-1) — preview a composition without persisting.
  // Returns conflicts, footprint, and dependency graph so the canvas can
  // render warnings before the operator hits Save.
  composePreview: async (moduleIds: string[]): Promise<TemplateComposePreview> => {
    const response = await apiClient.post<ApiEnvelope<TemplateComposePreview>>(
      '/system/node_templates/compose_preview',
      { module_ids: moduleIds }
    );
    return extractData(response);
  },
};

export interface TemplateComposePreviewModule {
  id: string;
  name: string;
  variety: string;
  priority: number;
  effective_priority: number;
  category_id: string | null;
  current_version: { id: string; version_number: number; oci_digest?: string | null } | null;
}

export interface TemplateComposeConflict {
  kind: 'instance_variety_collision' | 'mount_path_collision' | string;
  category_id?: string;
  module_ids?: string[];
  path?: string;
  detail: string;
}

export interface TemplateComposePreview {
  modules: TemplateComposePreviewModule[];
  conflicts: TemplateComposeConflict[];
  footprint: {
    module_count: number;
    estimated_package_count: number;
    architectures: string[];
  };
  dependency_graph: {
    nodes: { id: string; name: string; variety: string }[];
    edges: { source: string; target: string; type: string }[];
  };
}
