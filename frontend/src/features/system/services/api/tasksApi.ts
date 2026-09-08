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

  // Legal only from pending/scheduled — the AASM `cancel` event refuses any
  // other state with a 422. Use abortTask for a running task.
  cancelTask: async (id: string, reason?: string): Promise<SystemTask> => {
    const response = await apiClient.post<ApiEnvelope<{ task: SystemTask }>>(
      `/system/tasks/${id}/cancel`,
      { reason }
    );
    return extractData(response).task;
  },

  // Legal only from running — the operator's recourse for a wedged task that
  // `cancel` cannot touch. The AASM `abort` event transitions running ->
  // aborted; the endpoint is
  // extensions/system/server/app/controllers/api/v1/system/tasks_controller.rb:170,
  // behind the same `system.infra_tasks.control` permission as cancel.
  abortTask: async (id: string, reason?: string): Promise<SystemTask> => {
    const response = await apiClient.post<ApiEnvelope<{ task: SystemTask }>>(
      `/system/tasks/${id}/abort`,
      { reason }
    );
    return extractData(response).task;
  },
};
