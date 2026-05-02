import { apiClient } from '@/shared/services/apiClient';
import type { SystemTask } from '../../types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface TaskFilters extends PaginationParams {
  status?: string;
  command?: string;
  active?: boolean;
  finished?: boolean;
}

export interface TaskCreate {
  command: string;
  description?: string;
  operable_type?: string;
  operable_id?: string;
  scheduled_at?: string;
  exclusive?: boolean;
  options?: Record<string, unknown>;
}

export const tasksApi = {
  getTasks: async (params?: TaskFilters): Promise<{ tasks: SystemTask[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<PaginatedEnvelope<{ tasks: SystemTask[] }>>(
      '/system/tasks',
      { params }
    );
    return extractPaginated(response);
  },

  getTask: async (id: string): Promise<SystemTask> => {
    const response = await apiClient.get<ApiEnvelope<{ task: SystemTask }>>(
      `/system/tasks/${id}`
    );
    return extractData(response).task;
  },

  createTask: async (data: TaskCreate): Promise<SystemTask> => {
    const response = await apiClient.post<ApiEnvelope<{ task: SystemTask }>>(
      '/system/tasks',
      { task: data }
    );
    return extractData(response).task;
  },

  cancelTask: async (id: string, reason?: string): Promise<SystemTask> => {
    const response = await apiClient.post<ApiEnvelope<{ task: SystemTask }>>(
      `/system/tasks/${id}/cancel`,
      { reason }
    );
    return extractData(response).task;
  },
};
