import { apiClient } from '@/shared/services/apiClient';
import type {
  SystemNode,
  SystemNodeTemplate,
  SystemNodePlatform,
  SystemProvider,
  SystemNodeModule,
  SystemTask,
  SystemPuppetModule,
  SystemOverviewStats,
  SystemRecentActivity,
} from '../../types/system.types';
import { extractData } from './helpers';
import type { ApiEnvelope, PaginatedEnvelope } from './types';

// Aggregator endpoint: parallel fetch the catalog summaries to populate the
// overview dashboard. Each individual call uses the typed envelope so the
// shape narrowing flows into the reducers below.
export const overviewApi = {
  getOverviewStats: async (): Promise<SystemOverviewStats> => {
    const [
      nodesRes,
      templatesRes,
      platformsRes,
      providersRes,
      modulesRes,
      operationsRes,
      puppetModulesRes,
    ] = await Promise.all([
      apiClient.get<PaginatedEnvelope<{ nodes: SystemNode[] }>>('/system/nodes'),
      apiClient.get<PaginatedEnvelope<{ node_templates: SystemNodeTemplate[] }>>('/system/node_templates'),
      apiClient.get<ApiEnvelope<{ node_platforms: SystemNodePlatform[] }>>('/system/node_platforms'),
      apiClient.get<ApiEnvelope<{ providers: SystemProvider[] }>>('/system/providers'),
      apiClient.get<PaginatedEnvelope<{ node_modules: SystemNodeModule[] }>>('/system/node_modules'),
      apiClient.get<PaginatedEnvelope<{ tasks: SystemTask[] }>>('/system/tasks'),
      apiClient.get<PaginatedEnvelope<{ puppet_modules: SystemPuppetModule[] }>>('/system/puppet_modules'),
    ]);

    const nodes = extractData(nodesRes).nodes ?? [];
    const templates = extractData(templatesRes).node_templates ?? [];
    const platforms = extractData(platformsRes).node_platforms ?? [];
    const providers = extractData(providersRes).providers ?? [];
    const modules = extractData(modulesRes).node_modules ?? [];
    const operations = extractData(operationsRes).tasks ?? [];
    const puppetModules = extractData(puppetModulesRes).puppet_modules ?? [];

    return {
      nodes: {
        total: nodes.length,
        enabled: nodes.filter(n => n.enabled).length,
        disabled: nodes.filter(n => !n.enabled).length,
      },
      instances: {
        total: nodes.reduce((sum, n) => sum + (n.instance_count ?? 0), 0),
        running: nodes.reduce((sum, n) => sum + (n.running_instances_count ?? 0), 0),
        stopped: 0,
        pending: 0,
      },
      templates: {
        total: templates.length,
        public: templates.filter(t => t.public).length,
        private: templates.filter(t => !t.public).length,
      },
      platforms: {
        total: platforms.length,
        enabled: platforms.filter(p => p.enabled).length,
      },
      providers: {
        total: providers.length,
        enabled: providers.filter(p => p.enabled).length,
        types: [...new Set(providers.map(p => p.provider_type))],
      },
      regions: {
        total: providers.reduce((sum, p) => sum + (p.region_count ?? 0), 0),
      },
      modules: {
        total: modules.length,
        enabled: modules.filter(m => m.enabled).length,
        by_variety: {
          config: modules.filter(m => m.variety === 'config').length,
          instance: modules.filter(m => m.variety === 'instance').length,
          subscription: modules.filter(m => m.variety === 'subscription').length,
        },
      },
      operations: {
        total: operations.length,
        pending: operations.filter(o => o.status === 'pending' || o.status === 'scheduled').length,
        running: operations.filter(o => o.status === 'running').length,
        completed: operations.filter(o => o.status === 'complete').length,
        failed: operations.filter(o => o.status === 'failed' || o.status === 'aborted').length,
      },
      puppet: {
        modules: puppetModules.length,
        resources: puppetModules.reduce((sum, p) => sum + (p.resource_count ?? 0), 0),
        assignments: puppetModules.reduce((sum, p) => sum + (p.assigned_modules_count ?? 0), 0),
      },
      volumes: {
        total: 0,
        total_size_gb: 0,
      },
      networks: {
        total: 0,
      },
    };
  },

  getRecentActivity: async (limit: number = 10): Promise<SystemRecentActivity[]> => {
    const response = await apiClient.get<PaginatedEnvelope<{ tasks: SystemTask[] }>>('/system/tasks', {
      params: { per_page: limit },
    });
    const operations = extractData(response).tasks ?? [];

    return operations.map(op => ({
      id: op.id,
      type: 'operation' as const,
      action: op.command,
      description: op.description || `Operation: ${op.command}`,
      status: op.status,
      entity_name: op.operable_type || 'System',
      entity_id: op.operable_id || op.id,
      initiated_by: op.initiated_by_name,
      timestamp: op.created_at,
    }));
  },
};
