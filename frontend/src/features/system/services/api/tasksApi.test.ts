import { tasksApi } from './tasksApi';
import type { TaskCreate, TaskFilters } from './tasksApi';
import type { SystemTask } from '../../types/system.types';
import type { PaginationMeta } from './types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/**
 * Wrap a payload in the double-envelope that apiClient resolves to.
 * Backend: { success: true, data: <payload> }
 * AxiosResponse: { data: <above body> }
 */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

/**
 * Wrap a paginated payload — meta lives at the root of the body, never
 * inside data. See helpers.ts comment for the distinction.
 */
function paginatedEnvelope<T>(data: T, meta: PaginationMeta) {
  return { data: { success: true, data, meta } };
}

const DEFAULT_META: PaginationMeta = {
  current_page: 1,
  per_page: 20,
  total_count: 2,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

// =============================================================================
// Fixtures
// =============================================================================

const TASK_A: SystemTask = {
  id: 'task-a',
  command: 'system.provision_instance',
  status: 'running',
  description: 'Provision new node instance',
  progress: 42,
  exclusive: false,
  scheduled_at: undefined,
  started_at: '2026-06-01T10:00:00Z',
  completed_at: undefined,
  error_message: undefined,
  events: [{ type: 'started', at: '2026-06-01T10:00:00Z' }],
  options: { region: 'us-east-1' },
  operable_type: 'System::NodeInstance',
  operable_id: 'instance-42',
  initiated_by_id: 'user-1',
  initiated_by_name: 'admin@example.com',
  created_at: '2026-06-01T09:59:00Z',
  updated_at: '2026-06-01T10:01:00Z',
};

const TASK_B: SystemTask = {
  id: 'task-b',
  command: 'system.rolling_upgrade',
  status: 'complete',
  description: 'Rolling module upgrade',
  progress: 100,
  exclusive: true,
  scheduled_at: '2026-06-01T08:00:00Z',
  started_at: '2026-06-01T08:00:05Z',
  completed_at: '2026-06-01T08:15:30Z',
  error_message: undefined,
  events: [],
  options: {},
  operable_type: undefined,
  operable_id: undefined,
  initiated_by_id: undefined,
  initiated_by_name: undefined,
  created_at: '2026-06-01T07:55:00Z',
  updated_at: '2026-06-01T08:15:30Z',
};

const TASK_FAILED: SystemTask = {
  id: 'task-c',
  command: 'system.deploy_container',
  status: 'failed',
  description: 'Deploy container agent',
  progress: 0,
  exclusive: false,
  scheduled_at: undefined,
  started_at: '2026-06-01T11:00:00Z',
  completed_at: '2026-06-01T11:00:05Z',
  error_message: 'Connection refused: could not reach target node',
  events: [{ type: 'error', message: 'Connection refused' }],
  options: {},
  operable_type: 'System::NodeInstance',
  operable_id: 'instance-99',
  initiated_by_id: 'user-2',
  initiated_by_name: 'operator@example.com',
  created_at: '2026-06-01T10:59:00Z',
  updated_at: '2026-06-01T11:00:05Z',
};

// =============================================================================
// Tests
// =============================================================================

describe('tasksApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // getTasks
  // ---------------------------------------------------------------------------

  describe('getTasks', () => {
    it('fetches the task list from /system/tasks with no params', async () => {
      mockGet.mockResolvedValue(
        paginatedEnvelope({ tasks: [TASK_A, TASK_B] }, DEFAULT_META)
      );

      const result = await tasksApi.getTasks();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/tasks', { params: undefined });
      expect(result.tasks).toHaveLength(2);
      expect(result.tasks[0]).toEqual(TASK_A);
      expect(result.tasks[1]).toEqual(TASK_B);
    });

    it('returns the pagination meta from the root envelope body', async () => {
      const meta: PaginationMeta = {
        current_page: 2,
        per_page: 10,
        total_count: 25,
        total_pages: 3,
        next_page: 3,
        prev_page: 1,
      };

      mockGet.mockResolvedValue(
        paginatedEnvelope({ tasks: [TASK_A] }, meta)
      );

      const result = await tasksApi.getTasks({ page: 2, per_page: 10 });

      expect(result.meta).toEqual(meta);
      expect(result.meta.total_pages).toBe(3);
      expect(result.meta.current_page).toBe(2);
    });

    it('forwards filter params to the API request', async () => {
      mockGet.mockResolvedValue(
        paginatedEnvelope({ tasks: [TASK_A] }, DEFAULT_META)
      );

      const filters: TaskFilters = {
        status: 'running',
        command: 'system.provision_instance',
        active: true,
        page: 1,
        per_page: 25,
      };

      await tasksApi.getTasks(filters);

      expect(mockGet).toHaveBeenCalledWith('/system/tasks', { params: filters });
    });

    it('forwards the finished filter param to the API request', async () => {
      mockGet.mockResolvedValue(
        paginatedEnvelope({ tasks: [TASK_B] }, DEFAULT_META)
      );

      const filters: TaskFilters = { finished: true };

      await tasksApi.getTasks(filters);

      expect(mockGet).toHaveBeenCalledWith('/system/tasks', { params: { finished: true } });
    });

    it('returns an empty tasks array when the API returns no results', async () => {
      const emptyMeta: PaginationMeta = {
        current_page: 1,
        per_page: 20,
        total_count: 0,
        total_pages: 0,
        next_page: null,
        prev_page: null,
      };

      mockGet.mockResolvedValue(
        paginatedEnvelope({ tasks: [] }, emptyMeta)
      );

      const result = await tasksApi.getTasks();

      expect(result.tasks).toEqual([]);
      expect(result.meta.total_count).toBe(0);
    });

    it('surfaces the error when the API rejects', async () => {
      const apiError = new Error('Network Error');
      mockGet.mockRejectedValue(apiError);

      await expect(tasksApi.getTasks()).rejects.toThrow('Network Error');
    });
  });

  // ---------------------------------------------------------------------------
  // getTask
  // ---------------------------------------------------------------------------

  describe('getTask', () => {
    it('fetches a single task from /system/tasks/:id', async () => {
      mockGet.mockResolvedValue(envelope({ task: TASK_A }));

      const result = await tasksApi.getTask('task-a');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/tasks/task-a');
      expect(result).toEqual(TASK_A);
      expect(result.id).toBe('task-a');
    });

    it('extracts the task from the data envelope (not data.data.task)', async () => {
      mockGet.mockResolvedValue(envelope({ task: TASK_B }));

      const result = await tasksApi.getTask('task-b');

      expect(result.command).toBe('system.rolling_upgrade');
      expect(result.status).toBe('complete');
      expect(result.progress).toBe(100);
    });

    it('exposes task fields including optional ones', async () => {
      mockGet.mockResolvedValue(envelope({ task: TASK_FAILED }));

      const result = await tasksApi.getTask('task-c');

      expect(result.status).toBe('failed');
      expect(result.error_message).toBe('Connection refused: could not reach target node');
      expect(result.operable_type).toBe('System::NodeInstance');
      expect(result.operable_id).toBe('instance-99');
    });

    it('uses the provided id in the URL path', async () => {
      mockGet.mockResolvedValue(envelope({ task: TASK_A }));

      await tasksApi.getTask('some-uuid-abc-123');

      expect(mockGet).toHaveBeenCalledWith('/system/tasks/some-uuid-abc-123');
    });

    it('surfaces the error when the API rejects', async () => {
      mockGet.mockRejectedValue(new Error('Not Found'));

      await expect(tasksApi.getTask('nonexistent')).rejects.toThrow('Not Found');
    });
  });

  // ---------------------------------------------------------------------------
  // createTask
  // ---------------------------------------------------------------------------

  describe('createTask', () => {
    it('POSTs to /system/tasks with a task-wrapped payload', async () => {
      mockPost.mockResolvedValue(envelope({ task: TASK_A }));

      const payload: TaskCreate = {
        command: 'system.provision_instance',
        description: 'Provision new node instance',
        operable_type: 'System::NodeInstance',
        operable_id: 'instance-42',
      };

      const result = await tasksApi.createTask(payload);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith('/system/tasks', { task: payload });
      expect(result).toEqual(TASK_A);
    });

    it('wraps the payload under the task key in the request body', async () => {
      mockPost.mockResolvedValue(envelope({ task: TASK_B }));

      const payload: TaskCreate = {
        command: 'system.rolling_upgrade',
        exclusive: true,
        scheduled_at: '2026-06-01T08:00:00Z',
      };

      await tasksApi.createTask(payload);

      const [url, body] = mockPost.mock.calls[0] as [string, unknown];
      expect(url).toBe('/system/tasks');
      expect(body).toEqual({ task: payload });
    });

    it('forwards all optional TaskCreate fields in the wrapped body', async () => {
      mockPost.mockResolvedValue(envelope({ task: TASK_A }));

      const payload: TaskCreate = {
        command: 'system.deploy_container',
        description: 'Deploy with options',
        operable_type: 'System::NodeInstance',
        operable_id: 'instance-1',
        scheduled_at: '2026-06-05T12:00:00Z',
        exclusive: false,
        options: { image: 'ubuntu:22.04', tag: 'latest' },
      };

      await tasksApi.createTask(payload);

      expect(mockPost).toHaveBeenCalledWith('/system/tasks', { task: payload });
    });

    it('works with the minimal required fields only (command)', async () => {
      mockPost.mockResolvedValue(envelope({ task: TASK_A }));

      const minimalPayload: TaskCreate = { command: 'system.check_health' };

      await tasksApi.createTask(minimalPayload);

      expect(mockPost).toHaveBeenCalledWith('/system/tasks', { task: minimalPayload });
    });

    it('returns the created task from the response envelope', async () => {
      mockPost.mockResolvedValue(envelope({ task: TASK_A }));

      const result = await tasksApi.createTask({ command: 'system.provision_instance' });

      expect(result.id).toBe('task-a');
      expect(result.status).toBe('running');
    });

    it('surfaces the error when the API rejects', async () => {
      mockPost.mockRejectedValue(new Error('Unprocessable Entity'));

      await expect(
        tasksApi.createTask({ command: 'system.invalid_command' })
      ).rejects.toThrow('Unprocessable Entity');
    });
  });

  // ---------------------------------------------------------------------------
  // cancelTask
  // ---------------------------------------------------------------------------

  describe('cancelTask', () => {
    it('POSTs to /system/tasks/:id/cancel with the reason', async () => {
      const cancelledTask: SystemTask = { ...TASK_A, status: 'cancelled' };
      mockPost.mockResolvedValue(envelope({ task: cancelledTask }));

      const result = await tasksApi.cancelTask('task-a', 'Operator aborted the run');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith('/system/tasks/task-a/cancel', {
        reason: 'Operator aborted the run',
      });
      expect(result.status).toBe('cancelled');
    });

    it('uses the provided id in the cancel URL path', async () => {
      const cancelledTask: SystemTask = { ...TASK_B, status: 'cancelled' };
      mockPost.mockResolvedValue(envelope({ task: cancelledTask }));

      await tasksApi.cancelTask('task-b', 'No longer needed');

      expect(mockPost).toHaveBeenCalledWith('/system/tasks/task-b/cancel', {
        reason: 'No longer needed',
      });
    });

    it('sends undefined reason when none is provided', async () => {
      const cancelledTask: SystemTask = { ...TASK_A, status: 'cancelled' };
      mockPost.mockResolvedValue(envelope({ task: cancelledTask }));

      await tasksApi.cancelTask('task-a');

      expect(mockPost).toHaveBeenCalledWith('/system/tasks/task-a/cancel', {
        reason: undefined,
      });
    });

    it('returns the cancelled task from the response envelope', async () => {
      const cancelledTask: SystemTask = { ...TASK_FAILED, status: 'cancelled' };
      mockPost.mockResolvedValue(envelope({ task: cancelledTask }));

      const result = await tasksApi.cancelTask('task-c', 'Superseded by retry');

      expect(result).toEqual(cancelledTask);
      expect(result.id).toBe('task-c');
      expect(result.status).toBe('cancelled');
    });

    it('surfaces the error when the API rejects', async () => {
      mockPost.mockRejectedValue(new Error('Task is already terminal'));

      await expect(
        tasksApi.cancelTask('task-b', 'Too late')
      ).rejects.toThrow('Task is already terminal');
    });

    it('does not call GET or DELETE — cancel is always a POST', async () => {
      const cancelledTask: SystemTask = { ...TASK_A, status: 'cancelled' };
      mockPost.mockResolvedValue(envelope({ task: cancelledTask }));

      await tasksApi.cancelTask('task-a', 'reason');

      expect(mockGet).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope integrity (cross-cutting)
  // ---------------------------------------------------------------------------

  describe('envelope extraction integrity', () => {
    it('getTasks: meta comes from root body, not from inside data', async () => {
      const meta: PaginationMeta = {
        current_page: 1,
        per_page: 50,
        total_count: 1,
        total_pages: 1,
        next_page: null,
        prev_page: null,
      };

      // Simulate the real backend double-envelope shape exactly:
      // AxiosResponse.data = { success: true, data: { tasks: [...] }, meta: { ... } }
      mockGet.mockResolvedValue({
        data: { success: true, data: { tasks: [TASK_A] }, meta },
      });

      const result = await tasksApi.getTasks();

      // meta must be accessible at result.meta, not result.tasks[0].meta or undefined
      expect(result.meta).toBeDefined();
      expect(result.meta.total_count).toBe(1);
      expect(result.meta.per_page).toBe(50);
    });

    it('getTask: extracts the task from data.task, not from data.data.task', async () => {
      // The backend sends: { success: true, data: { task: <SystemTask> } }
      // AxiosResponse wraps that as response.data = { success: true, data: { task: ... } }
      mockGet.mockResolvedValue({
        data: { success: true, data: { task: TASK_A } },
      });

      const result = await tasksApi.getTask('task-a');

      expect(result).toEqual(TASK_A);
      // Confirm it isn't wrapped further
      expect((result as unknown as { task: SystemTask }).task).toBeUndefined();
    });
  });
});
