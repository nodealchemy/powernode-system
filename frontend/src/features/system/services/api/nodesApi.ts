import { apiClient } from '@/shared/services/apiClient';
import type { SystemNode, SystemNodeInstance } from '../../types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface NodeFilters extends PaginationParams {
  enabled?: boolean;
}

export interface NodeCreate {
  name: string;
  description?: string;
  enabled?: boolean;
  allocate_public_ip?: boolean;
  node_template_id?: string;
  config?: Record<string, unknown>;
}

export interface NodeInstanceCreate {
  name: string;
  description?: string;
  variety?: 'cloud' | 'physical' | 'dynamic';
  status?: string;
  private_ip_address?: string;
  public_ip_address?: string;
  vpn_ip_address?: string;
  config?: Record<string, unknown>;
}

export const nodesApi = {
  getNodes: async (params?: NodeFilters): Promise<{ nodes: SystemNode[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<PaginatedEnvelope<{ nodes: SystemNode[] }>>(
      '/system/nodes',
      { params }
    );
    return extractPaginated(response);
  },

  getNode: async (id: string): Promise<SystemNode> => {
    const response = await apiClient.get<ApiEnvelope<{ node: SystemNode }>>(
      `/system/nodes/${id}`
    );
    return extractData(response).node;
  },

  createNode: async (data: NodeCreate): Promise<SystemNode> => {
    const response = await apiClient.post<ApiEnvelope<{ node: SystemNode }>>(
      '/system/nodes',
      { node: data }
    );
    return extractData(response).node;
  },

  updateNode: async (id: string, data: Partial<NodeCreate>): Promise<SystemNode> => {
    const response = await apiClient.put<ApiEnvelope<{ node: SystemNode }>>(
      `/system/nodes/${id}`,
      { node: data }
    );
    return extractData(response).node;
  },

  deleteNode: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/nodes/${id}`);
  },

  getNodeInstances: async (nodeId: string): Promise<{ node_instances: SystemNodeInstance[] }> => {
    const response = await apiClient.get<ApiEnvelope<{ node_instances: SystemNodeInstance[] }>>(
      `/system/nodes/${nodeId}/node_instances`
    );
    return { node_instances: extractData(response).node_instances ?? [] };
  },

  getNodeInstance: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.get<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}`
    );
    return extractData(response).node_instance;
  },

  createNodeInstance: async (nodeId: string, data: NodeInstanceCreate): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances`,
      { node_instance: data }
    );
    return extractData(response).node_instance;
  },

  updateNodeInstance: async (
    nodeId: string,
    instanceId: string,
    data: Partial<NodeInstanceCreate>
  ): Promise<SystemNodeInstance> => {
    const response = await apiClient.put<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}`,
      { node_instance: data }
    );
    return extractData(response).node_instance;
  },

  deleteNodeInstance: async (nodeId: string, instanceId: string): Promise<void> => {
    await apiClient.delete(`/system/nodes/${nodeId}/node_instances/${instanceId}`);
  },

  startInstance: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/start`
    );
    return extractData(response).node_instance;
  },

  stopInstance: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/stop`
    );
    return extractData(response).node_instance;
  },

  rebootInstance: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/reboot`
    );
    return extractData(response).node_instance;
  },

  terminateInstance: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/terminate`
    );
    return extractData(response).node_instance;
  },

  associatePublicIp: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/associate_public_ip`
    );
    return extractData(response).node_instance;
  },

  disassociatePublicIp: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/disassociate_public_ip`
    );
    return extractData(response).node_instance;
  },
};
