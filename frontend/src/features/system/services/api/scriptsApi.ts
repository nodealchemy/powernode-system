import { apiClient } from '@/shared/services/apiClient';
import type { SystemNodeScript } from '../../types/system.types';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export interface ScriptCreate {
  name: string;
  description?: string;
  variety: 'build' | 'init' | 'sync' | 'custom';
  data?: string;
  enabled?: boolean;
  public?: boolean;
}

export const scriptsApi = {
  getScripts: async (): Promise<SystemNodeScript[]> => {
    const response = await apiClient.get<ApiEnvelope<{ node_scripts: SystemNodeScript[] }>>(
      '/system/node_scripts'
    );
    return extractData(response).node_scripts ?? [];
  },

  getScript: async (id: string): Promise<SystemNodeScript> => {
    const response = await apiClient.get<ApiEnvelope<{ node_script: SystemNodeScript }>>(
      `/system/node_scripts/${id}`
    );
    return extractData(response).node_script;
  },

  createScript: async (data: ScriptCreate): Promise<SystemNodeScript> => {
    const response = await apiClient.post<ApiEnvelope<{ node_script: SystemNodeScript }>>(
      '/system/node_scripts',
      { node_script: data }
    );
    return extractData(response).node_script;
  },

  updateScript: async (
    id: string,
    data: Partial<ScriptCreate>
  ): Promise<SystemNodeScript> => {
    const response = await apiClient.put<ApiEnvelope<{ node_script: SystemNodeScript }>>(
      `/system/node_scripts/${id}`,
      { node_script: data }
    );
    return extractData(response).node_script;
  },

  deleteScript: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/node_scripts/${id}`);
  },
};
