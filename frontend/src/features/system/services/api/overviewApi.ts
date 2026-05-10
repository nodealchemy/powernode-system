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
import type {
  SdwanNetwork,
  SdwanHostBridge,
  SdwanOvnDeploymentSummary,
  SdwanIpfixCollector,
} from '../../types/sdwan.types';
import { extractData } from './helpers';
import type { ApiEnvelope, PaginatedEnvelope } from './types';

// Promise wrapper that swallows API errors and returns the supplied
// default. Used for SDWAN endpoints in the overview aggregator so a
// missing permission (operator without sdwan.*.read) returns 0 counts
// rather than blowing up the whole overview page.
async function softFetch<T>(promise: Promise<T>, fallback: T): Promise<T> {
  try {
    return await promise;
  } catch {
    return fallback;
  }
}

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
      sdwanNetworksRes,
      sdwanHostBridgesRes,
      sdwanOvnDeploymentsRes,
      sdwanIpfixCollectorsRes,
    ] = await Promise.all([
      apiClient.get<PaginatedEnvelope<{ nodes: SystemNode[] }>>('/system/nodes'),
      apiClient.get<PaginatedEnvelope<{ node_templates: SystemNodeTemplate[] }>>('/system/node_templates'),
      apiClient.get<ApiEnvelope<{ node_platforms: SystemNodePlatform[] }>>('/system/node_platforms'),
      apiClient.get<ApiEnvelope<{ providers: SystemProvider[] }>>('/system/providers'),
      apiClient.get<PaginatedEnvelope<{ node_modules: SystemNodeModule[] }>>('/system/node_modules'),
      apiClient.get<PaginatedEnvelope<{ tasks: SystemTask[] }>>('/system/tasks'),
      apiClient.get<PaginatedEnvelope<{ puppet_modules: SystemPuppetModule[] }>>('/system/puppet_modules'),
      // SDWAN endpoints — permission-gated. softFetch swallows 403s so an
      // operator who can see the rest of the system but lacks SDWAN
      // permissions still gets a working overview (SDWAN counts read 0).
      softFetch(
        apiClient.get<PaginatedEnvelope<{ networks: SdwanNetwork[] }>>('/system/sdwan/networks'),
        { data: { data: { networks: [] }, meta: { total_count: 0, total_pages: 0, current_page: 1, per_page: 0 } } } as never
      ),
      softFetch(
        apiClient.get<ApiEnvelope<{ host_bridges: SdwanHostBridge[] }>>('/system/sdwan/host_bridges'),
        { data: { data: { host_bridges: [] } } } as never
      ),
      softFetch(
        apiClient.get<ApiEnvelope<{ ovn_deployments: SdwanOvnDeploymentSummary[] }>>('/system/sdwan/ovn_deployments'),
        { data: { data: { ovn_deployments: [] } } } as never
      ),
      softFetch(
        apiClient.get<ApiEnvelope<{ ipfix_collectors: SdwanIpfixCollector[] }>>('/system/sdwan/ipfix_collectors'),
        { data: { data: { ipfix_collectors: [] } } } as never
      ),
    ]);

    const nodes = extractData(nodesRes).nodes ?? [];
    const templates = extractData(templatesRes).node_templates ?? [];
    const platforms = extractData(platformsRes).node_platforms ?? [];
    const providers = extractData(providersRes).providers ?? [];
    const modules = extractData(modulesRes).node_modules ?? [];
    const operations = extractData(operationsRes).tasks ?? [];
    const puppetModules = extractData(puppetModulesRes).puppet_modules ?? [];

    const sdwanNetworks = extractData(sdwanNetworksRes).networks ?? [];
    const sdwanHostBridges = extractData(sdwanHostBridgesRes).host_bridges ?? [];
    const sdwanOvnDeployments = extractData(sdwanOvnDeploymentsRes).ovn_deployments ?? [];
    const sdwanIpfixCollectors = extractData(sdwanIpfixCollectorsRes).ipfix_collectors ?? [];

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
      sdwan: {
        networks: sdwanNetworks.length,
        host_bridges: sdwanHostBridges.length,
        bridges_by_kind: {
          linux: sdwanHostBridges.filter(b => b.kind === 'linux').length,
          ovs: sdwanHostBridges.filter(b => b.kind === 'ovs').length,
        },
        ovn_deployments: sdwanOvnDeployments.length,
        ovn_active: sdwanOvnDeployments.filter(d => d.status === 'active').length,
        ipfix_collectors: sdwanIpfixCollectors.length,
        ipfix_active: sdwanIpfixCollectors.filter(c => c.state === 'active').length,
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
