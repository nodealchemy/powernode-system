// Behavioral tests for serviceApi (admin services management).
//
// Covers every exported method of ServiceAPI: exact URL construction,
// request payloads (including nested { service: data } wrapping), query
// param forwarding, response unwrapping, optional-argument defaults, and
// error propagation.

import { service_api } from './serviceApi';
import type {
  Service,
  ServiceListResponse,
  ServiceDetailsResponse,
  CreateServiceData,
  UpdateServiceData,
  ActivityListResponse,
  ServiceActivity,
} from './serviceApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPatch = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/api', () => ({
  api: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/**
 * Wrap a payload in an AxiosResponse shape.
 * `api.get/post/patch/delete` return `Promise<AxiosResponse<T>>` where
 * `response.data` is the raw backend payload.  The serviceApi methods
 * return `response.data` verbatim — there is NO double-envelope here.
 */
function axiosWrap<T>(payload: T) {
  return { data: payload };
}

// =============================================================================
// Fixtures
// =============================================================================

const SERVICE_A: Service = {
  id: 'svc-aaa-111',
  name: 'CI Runner Token',
  description: 'Used by CI pipelines',
  permissions: 'standard',
  status: 'active',
  account_name: 'Acme Corp',
  masked_token: 'tok_****abcd',
  request_count: 42,
  last_seen_at: '2026-06-01T10:00:00Z',
  active_recently: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-06-01T10:00:00Z',
};

const SERVICE_B: Service = {
  id: 'svc-bbb-222',
  name: 'Read-Only Monitor',
  permissions: 'readonly',
  status: 'suspended',
  account_name: 'Acme Corp',
  masked_token: 'tok_****wxyz',
  request_count: 0,
  last_seen_at: null,
  active_recently: false,
  created_at: '2026-02-15T00:00:00Z',
  updated_at: '2026-05-01T00:00:00Z',
};

const ACTIVITY_A: ServiceActivity = {
  id: 'act-1',
  action: 'agents.list',
  performed_at: '2026-06-01T09:00:00Z',
  ip_address: '10.0.0.1',
  user_agent: 'curl/7.88.0',
  successful: true,
  failed: false,
  duration: 45,
  response_status: 200,
  request_path: '/api/v1/agents',
};

const ACTIVITY_B: ServiceActivity = {
  id: 'act-2',
  action: 'nodes.create',
  performed_at: '2026-06-01T09:05:00Z',
  successful: false,
  failed: true,
  response_status: 403,
  error_message: 'Insufficient permissions',
};

const LIST_RESPONSE: ServiceListResponse = {
  services: [SERVICE_A, SERVICE_B],
  total: 2,
  account_services: 2,
};

const DETAILS_RESPONSE: ServiceDetailsResponse = {
  service: { ...SERVICE_A, token: 'tok_plaintext_abc123' },
  activity_summary: {
    total_requests: 42,
    successful_requests: 40,
    failed_requests: 2,
    unique_actions: ['agents.list', 'nodes.list'],
    last_activity: '2026-06-01T10:00:00Z',
    requests_by_hour: { '2026-06-01T09:00:00Z': 10 },
  },
  recent_activities: [ACTIVITY_A],
};

const ACTIVITY_LIST: ActivityListResponse = {
  activities: [ACTIVITY_A, ACTIVITY_B],
  pagination: {
    page: 1,
    per_page: 25,
    total: 2,
    total_pages: 1,
  },
  summary: {
    total_recent: 2,
    successful_recent: 1,
    failed_recent: 1,
    actions: { 'agents.list': 1, 'nodes.create': 1 },
    last_activity_at: '2026-06-01T09:05:00Z',
  },
  service: {
    id: 'svc-aaa-111',
    name: 'CI Runner Token',
    permissions: 'standard',
  },
};

const BASE = '/admin/services';

// =============================================================================
// Tests
// =============================================================================

describe('service_api', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPatch.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // getServices()
  // ---------------------------------------------------------------------------

  describe('getServices()', () => {
    it('calls GET /admin/services with no params', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(LIST_RESPONSE));

      await service_api.getServices();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE);
    });

    it('returns the full ServiceListResponse including services, total, and account_services', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(LIST_RESPONSE));

      const result = await service_api.getServices();

      expect(result).toEqual(LIST_RESPONSE);
      expect(result.services).toHaveLength(2);
      expect(result.total).toBe(2);
      expect(result.account_services).toBe(2);
    });

    it('returns an empty services array when the API returns none', async () => {
      const empty: ServiceListResponse = { services: [], total: 0, account_services: 0 };
      mockGet.mockResolvedValueOnce(axiosWrap(empty));

      const result = await service_api.getServices();

      expect(result.services).toHaveLength(0);
      expect(result.total).toBe(0);
    });

    it('returns service records verbatim including optional and nullable fields', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(LIST_RESPONSE));

      const result = await service_api.getServices();

      expect(result.services[0].description).toBe('Used by CI pipelines');
      expect(result.services[1].description).toBeUndefined();
      expect(result.services[1].last_seen_at).toBeNull();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Unauthorized'));

      await expect(service_api.getServices()).rejects.toThrow('Unauthorized');
    });
  });

  // ---------------------------------------------------------------------------
  // getService()
  // ---------------------------------------------------------------------------

  describe('getService()', () => {
    it('calls GET /admin/services/:id', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(DETAILS_RESPONSE));

      await service_api.getService('svc-aaa-111');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111`);
    });

    it('interpolates the service id into the URL', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(DETAILS_RESPONSE));

      await service_api.getService('svc-bbb-222');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-bbb-222`);
    });

    it('returns the full ServiceDetailsResponse including service, activity_summary, and recent_activities', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(DETAILS_RESPONSE));

      const result = await service_api.getService('svc-aaa-111');

      expect(result).toEqual(DETAILS_RESPONSE);
      expect(result.service.token).toBe('tok_plaintext_abc123');
      expect(result.activity_summary.total_requests).toBe(42);
      expect(result.recent_activities).toHaveLength(1);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not Found'));

      await expect(service_api.getService('no-such-id')).rejects.toThrow('Not Found');
    });
  });

  // ---------------------------------------------------------------------------
  // createService()
  // ---------------------------------------------------------------------------

  describe('createService()', () => {
    const CREATE_DATA: CreateServiceData = {
      name: 'New CI Token',
      description: 'Pipeline access',
      permissions: 'standard',
    };

    it('calls POST /admin/services with { service: data } nested body', async () => {
      mockPost.mockResolvedValueOnce(
        axiosWrap({ service: SERVICE_A, message: 'Service created successfully' }),
      );

      await service_api.createService(CREATE_DATA);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(BASE, { service: CREATE_DATA });
    });

    it('nests the data under a "service" key in the request body', async () => {
      mockPost.mockResolvedValueOnce(
        axiosWrap({ service: SERVICE_A, message: 'Service created successfully' }),
      );

      await service_api.createService(CREATE_DATA);

      const [, body] = mockPost.mock.calls[0] as [string, { service: CreateServiceData }];
      expect(body.service).toEqual(CREATE_DATA);
      expect((body as unknown as Record<string, unknown>)['name']).toBeUndefined();
    });

    it('returns the { service, message } response object', async () => {
      mockPost.mockResolvedValueOnce(
        axiosWrap({ service: SERVICE_A, message: 'Service created successfully' }),
      );

      const result = await service_api.createService(CREATE_DATA);

      expect(result.service).toEqual(SERVICE_A);
      expect(result.message).toBe('Service created successfully');
    });

    it('works with a minimal payload (name only)', async () => {
      const minimal: CreateServiceData = { name: 'Minimal Token' };
      mockPost.mockResolvedValueOnce(
        axiosWrap({ service: SERVICE_B, message: 'Created' }),
      );

      await service_api.createService(minimal);

      const [, body] = mockPost.mock.calls[0] as [string, { service: CreateServiceData }];
      expect(body.service.name).toBe('Minimal Token');
      expect(body.service.description).toBeUndefined();
      expect(body.service.permissions).toBeUndefined();
    });

    it('sends all optional fields when provided', async () => {
      mockPost.mockResolvedValueOnce(
        axiosWrap({ service: SERVICE_A, message: 'Created' }),
      );

      await service_api.createService(CREATE_DATA);

      const [, body] = mockPost.mock.calls[0] as [string, { service: CreateServiceData }];
      expect(body.service.description).toBe('Pipeline access');
      expect(body.service.permissions).toBe('standard');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Unprocessable Entity'));

      await expect(service_api.createService(CREATE_DATA)).rejects.toThrow('Unprocessable Entity');
    });
  });

  // ---------------------------------------------------------------------------
  // updateService()
  // ---------------------------------------------------------------------------

  describe('updateService()', () => {
    const UPDATE_DATA: UpdateServiceData = { name: 'Renamed Token' };

    it('calls PATCH /admin/services/:id with { service: data } nested body', async () => {
      mockPatch.mockResolvedValueOnce(
        axiosWrap({ service: SERVICE_A, message: 'Service updated' }),
      );

      await service_api.updateService('svc-aaa-111', UPDATE_DATA);

      expect(mockPatch).toHaveBeenCalledTimes(1);
      expect(mockPatch).toHaveBeenCalledWith(`${BASE}/svc-aaa-111`, { service: UPDATE_DATA });
    });

    it('interpolates the service id into the URL', async () => {
      mockPatch.mockResolvedValueOnce(
        axiosWrap({ service: SERVICE_B, message: 'Service updated' }),
      );

      await service_api.updateService('svc-bbb-222', { permissions: 'admin' });

      expect(mockPatch).toHaveBeenCalledWith(`${BASE}/svc-bbb-222`, {
        service: { permissions: 'admin' },
      });
    });

    it('nests the update data under a "service" key', async () => {
      mockPatch.mockResolvedValueOnce(
        axiosWrap({ service: SERVICE_A, message: 'Service updated' }),
      );

      await service_api.updateService('svc-aaa-111', UPDATE_DATA);

      const [, body] = mockPatch.mock.calls[0] as [string, { service: UpdateServiceData }];
      expect(body.service).toEqual(UPDATE_DATA);
      expect((body as unknown as Record<string, unknown>)['name']).toBeUndefined();
    });

    it('returns the { service, message } response object', async () => {
      const updated: Service = { ...SERVICE_A, name: 'Renamed Token' };
      mockPatch.mockResolvedValueOnce(
        axiosWrap({ service: updated, message: 'Service updated' }),
      );

      const result = await service_api.updateService('svc-aaa-111', UPDATE_DATA);

      expect(result.service.name).toBe('Renamed Token');
      expect(result.message).toBe('Service updated');
    });

    it('supports partial updates (only name)', async () => {
      mockPatch.mockResolvedValueOnce(
        axiosWrap({ service: SERVICE_A, message: 'Updated' }),
      );

      await service_api.updateService('svc-aaa-111', { name: 'New Name Only' });

      const [, body] = mockPatch.mock.calls[0] as [string, { service: UpdateServiceData }];
      expect(body.service.name).toBe('New Name Only');
      expect(body.service.description).toBeUndefined();
      expect(body.service.permissions).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPatch.mockRejectedValueOnce(new Error('Conflict'));

      await expect(service_api.updateService('svc-aaa-111', {})).rejects.toThrow('Conflict');
    });
  });

  // ---------------------------------------------------------------------------
  // deleteService()
  // ---------------------------------------------------------------------------

  describe('deleteService()', () => {
    it('calls DELETE /admin/services/:id', async () => {
      mockDelete.mockResolvedValueOnce(axiosWrap({ message: 'Service deleted' }));

      await service_api.deleteService('svc-aaa-111');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/svc-aaa-111`);
    });

    it('interpolates the service id into the URL', async () => {
      mockDelete.mockResolvedValueOnce(axiosWrap({ message: 'Service deleted' }));

      await service_api.deleteService('svc-bbb-222');

      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/svc-bbb-222`);
    });

    it('returns the { message } response object', async () => {
      mockDelete.mockResolvedValueOnce(axiosWrap({ message: 'Service deleted successfully' }));

      const result = await service_api.deleteService('svc-aaa-111');

      expect(result.message).toBe('Service deleted successfully');
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Not Found'));

      await expect(service_api.deleteService('no-such-id')).rejects.toThrow('Not Found');
    });
  });

  // ---------------------------------------------------------------------------
  // regenerateToken()
  // ---------------------------------------------------------------------------

  describe('regenerateToken()', () => {
    it('calls POST /admin/services/:id/regenerate_token with no body', async () => {
      mockPost.mockResolvedValueOnce(
        axiosWrap({
          service: SERVICE_A,
          new_token: 'tok_new_xyz789',
          message: 'Token regenerated',
        }),
      );

      await service_api.regenerateToken('svc-aaa-111');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/regenerate_token`);
    });

    it('interpolates the service id into the URL', async () => {
      mockPost.mockResolvedValueOnce(
        axiosWrap({ service: SERVICE_B, new_token: 'tok_new_qqq', message: 'Regenerated' }),
      );

      await service_api.regenerateToken('svc-bbb-222');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/svc-bbb-222/regenerate_token`);
    });

    it('returns service, new_token, and message in the response', async () => {
      mockPost.mockResolvedValueOnce(
        axiosWrap({
          service: SERVICE_A,
          new_token: 'tok_new_xyz789',
          message: 'Token regenerated successfully',
        }),
      );

      const result = await service_api.regenerateToken('svc-aaa-111');

      expect(result.service).toEqual(SERVICE_A);
      expect(result.new_token).toBe('tok_new_xyz789');
      expect(result.message).toBe('Token regenerated successfully');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Service not found'));

      await expect(service_api.regenerateToken('no-such')).rejects.toThrow('Service not found');
    });
  });

  // ---------------------------------------------------------------------------
  // suspendService()
  // ---------------------------------------------------------------------------

  describe('suspendService()', () => {
    it('calls POST /admin/services/:id/suspend with no body', async () => {
      const suspended: Service = { ...SERVICE_A, status: 'suspended' };
      mockPost.mockResolvedValueOnce(axiosWrap({ service: suspended, message: 'Service suspended' }));

      await service_api.suspendService('svc-aaa-111');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/suspend`);
    });

    it('interpolates the service id into the URL', async () => {
      const suspended: Service = { ...SERVICE_A, status: 'suspended' };
      mockPost.mockResolvedValueOnce(axiosWrap({ service: suspended, message: 'Suspended' }));

      await service_api.suspendService('svc-bbb-222');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/svc-bbb-222/suspend`);
    });

    it('returns service with suspended status and message', async () => {
      const suspended: Service = { ...SERVICE_A, status: 'suspended' };
      mockPost.mockResolvedValueOnce(axiosWrap({ service: suspended, message: 'Service suspended' }));

      const result = await service_api.suspendService('svc-aaa-111');

      expect(result.service.status).toBe('suspended');
      expect(result.message).toBe('Service suspended');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Already suspended'));

      await expect(service_api.suspendService('svc-aaa-111')).rejects.toThrow('Already suspended');
    });
  });

  // ---------------------------------------------------------------------------
  // activateService()
  // ---------------------------------------------------------------------------

  describe('activateService()', () => {
    it('calls POST /admin/services/:id/activate with no body', async () => {
      const activated: Service = { ...SERVICE_B, status: 'active' };
      mockPost.mockResolvedValueOnce(axiosWrap({ service: activated, message: 'Service activated' }));

      await service_api.activateService('svc-bbb-222');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/svc-bbb-222/activate`);
    });

    it('interpolates the service id into the URL', async () => {
      const activated: Service = { ...SERVICE_A, status: 'active' };
      mockPost.mockResolvedValueOnce(axiosWrap({ service: activated, message: 'Activated' }));

      await service_api.activateService('svc-aaa-111');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activate`);
    });

    it('returns service with active status and message', async () => {
      const activated: Service = { ...SERVICE_B, status: 'active' };
      mockPost.mockResolvedValueOnce(axiosWrap({ service: activated, message: 'Service activated' }));

      const result = await service_api.activateService('svc-bbb-222');

      expect(result.service.status).toBe('active');
      expect(result.message).toBe('Service activated');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('State transition not allowed'));

      await expect(service_api.activateService('svc-aaa-111')).rejects.toThrow(
        'State transition not allowed',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // revokeService()
  // ---------------------------------------------------------------------------

  describe('revokeService()', () => {
    it('calls POST /admin/services/:id/revoke with no body', async () => {
      const revoked: Service = { ...SERVICE_A, status: 'revoked' };
      mockPost.mockResolvedValueOnce(axiosWrap({ service: revoked, message: 'Service revoked' }));

      await service_api.revokeService('svc-aaa-111');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/revoke`);
    });

    it('interpolates the service id into the URL', async () => {
      const revoked: Service = { ...SERVICE_B, status: 'revoked' };
      mockPost.mockResolvedValueOnce(axiosWrap({ service: revoked, message: 'Revoked' }));

      await service_api.revokeService('svc-bbb-222');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/svc-bbb-222/revoke`);
    });

    it('returns service with revoked status and message', async () => {
      const revoked: Service = { ...SERVICE_A, status: 'revoked' };
      mockPost.mockResolvedValueOnce(axiosWrap({ service: revoked, message: 'Service revoked' }));

      const result = await service_api.revokeService('svc-aaa-111');

      expect(result.service.status).toBe('revoked');
      expect(result.message).toBe('Service revoked');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Cannot revoke — service has active subscriptions'));

      await expect(service_api.revokeService('svc-aaa-111')).rejects.toThrow(
        'Cannot revoke — service has active subscriptions',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // getServiceActivities()
  // ---------------------------------------------------------------------------

  describe('getServiceActivities()', () => {
    it('calls GET /admin/services/:serviceId/activities with no params when none provided', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(ACTIVITY_LIST));

      await service_api.getServiceActivities('svc-aaa-111');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities`, { params: undefined });
    });

    it('interpolates the service id into the URL', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(ACTIVITY_LIST));

      await service_api.getServiceActivities('svc-bbb-222');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-bbb-222/activities`, { params: undefined });
    });

    it('passes page and per_page params when provided', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(ACTIVITY_LIST));

      await service_api.getServiceActivities('svc-aaa-111', { page: 2, per_page: 50 });

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities`, {
        params: { page: 2, per_page: 50 },
      });
    });

    it('passes action filter param when provided', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(ACTIVITY_LIST));

      await service_api.getServiceActivities('svc-aaa-111', { action: 'agents.list' });

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities`, {
        params: { action: 'agents.list' },
      });
    });

    it('passes status filter param when provided', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(ACTIVITY_LIST));

      await service_api.getServiceActivities('svc-aaa-111', { status: 'failed' });

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities`, {
        params: { status: 'failed' },
      });
    });

    it('passes from/to date range params when provided', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(ACTIVITY_LIST));

      await service_api.getServiceActivities('svc-aaa-111', {
        from: '2026-06-01T00:00:00Z',
        to: '2026-06-01T23:59:59Z',
      });

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities`, {
        params: {
          from: '2026-06-01T00:00:00Z',
          to: '2026-06-01T23:59:59Z',
        },
      });
    });

    it('passes all params together when all are provided', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(ACTIVITY_LIST));

      await service_api.getServiceActivities('svc-aaa-111', {
        page: 1,
        per_page: 25,
        action: 'nodes.create',
        status: 'success',
        from: '2026-06-01T00:00:00Z',
        to: '2026-06-01T23:59:59Z',
      });

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities`, {
        params: {
          page: 1,
          per_page: 25,
          action: 'nodes.create',
          status: 'success',
          from: '2026-06-01T00:00:00Z',
          to: '2026-06-01T23:59:59Z',
        },
      });
    });

    it('returns the full ActivityListResponse including activities, pagination, summary, and service info', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(ACTIVITY_LIST));

      const result = await service_api.getServiceActivities('svc-aaa-111');

      expect(result).toEqual(ACTIVITY_LIST);
      expect(result.activities).toHaveLength(2);
      expect(result.pagination.total).toBe(2);
      expect(result.summary.total_recent).toBe(2);
      expect(result.service.name).toBe('CI Runner Token');
    });

    it('returns activity records with optional nullable fields intact', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(ACTIVITY_LIST));

      const result = await service_api.getServiceActivities('svc-aaa-111');

      expect(result.activities[0].ip_address).toBe('10.0.0.1');
      expect(result.activities[0].duration).toBe(45);
      expect(result.activities[1].ip_address).toBeUndefined();
      expect(result.activities[1].error_message).toBe('Insufficient permissions');
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Forbidden'));

      await expect(service_api.getServiceActivities('svc-aaa-111')).rejects.toThrow('Forbidden');
    });
  });

  // ---------------------------------------------------------------------------
  // getServiceActivity()
  // ---------------------------------------------------------------------------

  describe('getServiceActivity()', () => {
    it('calls GET /admin/services/:serviceId/activities/:activityId', async () => {
      mockGet.mockResolvedValueOnce(
        axiosWrap({ activity: ACTIVITY_A, service: { id: 'svc-aaa-111', name: 'CI Runner Token' } }),
      );

      await service_api.getServiceActivity('svc-aaa-111', 'act-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities/act-1`);
    });

    it('interpolates both service id and activity id into the URL', async () => {
      mockGet.mockResolvedValueOnce(
        axiosWrap({ activity: ACTIVITY_B, service: { id: 'svc-bbb-222', name: 'Read-Only Monitor' } }),
      );

      await service_api.getServiceActivity('svc-bbb-222', 'act-2');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-bbb-222/activities/act-2`);
    });

    it('returns the { activity, service } wrapper object', async () => {
      mockGet.mockResolvedValueOnce(
        axiosWrap({ activity: ACTIVITY_A, service: { id: 'svc-aaa-111', name: 'CI Runner Token' } }),
      );

      const result = await service_api.getServiceActivity('svc-aaa-111', 'act-1');

      expect(result.activity).toEqual(ACTIVITY_A);
      expect(result.service.id).toBe('svc-aaa-111');
      expect(result.service.name).toBe('CI Runner Token');
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not Found'));

      await expect(service_api.getServiceActivity('svc-aaa-111', 'no-such')).rejects.toThrow(
        'Not Found',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // getServiceActivitySummary()
  // ---------------------------------------------------------------------------

  describe('getServiceActivitySummary()', () => {
    const SUMMARY_RESPONSE = {
      service: { id: 'svc-aaa-111', name: 'CI Runner Token', permissions: 'standard' },
      time_range: { hours: 24, from: '2026-06-04T10:00:00Z', to: '2026-06-05T10:00:00Z' },
      summary: {
        total_requests: 100,
        successful_requests: 95,
        failed_requests: 5,
        unique_actions: ['agents.list', 'nodes.list', 'nodes.create'],
        last_activity: '2026-06-05T09:30:00Z',
        requests_by_hour: { '2026-06-05T09:00:00Z': 15 },
        actions_breakdown: { 'agents.list': 60, 'nodes.list': 30, 'nodes.create': 10 },
        hourly_breakdown: { '2026-06-05T09:00:00Z': 15 },
        success_rate: 95.0,
        average_response_time: 42,
      },
    };

    it('calls GET /admin/services/:serviceId/activities/summary with default hours=24', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(SUMMARY_RESPONSE));

      await service_api.getServiceActivitySummary('svc-aaa-111');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities/summary`, {
        params: { hours: 24 },
      });
    });

    it('passes the provided hours value as a query param', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(SUMMARY_RESPONSE));

      await service_api.getServiceActivitySummary('svc-aaa-111', 48);

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities/summary`, {
        params: { hours: 48 },
      });
    });

    it('interpolates the service id into the URL', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(SUMMARY_RESPONSE));

      await service_api.getServiceActivitySummary('svc-bbb-222');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-bbb-222/activities/summary`, {
        params: { hours: 24 },
      });
    });

    it('passes hours=0 correctly when explicitly provided', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(SUMMARY_RESPONSE));

      await service_api.getServiceActivitySummary('svc-aaa-111', 0);

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities/summary`, {
        params: { hours: 0 },
      });
    });

    it('returns the full summary response object', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(SUMMARY_RESPONSE));

      const result = await service_api.getServiceActivitySummary('svc-aaa-111');

      expect(result).toEqual(SUMMARY_RESPONSE);
      expect(result.service.name).toBe('CI Runner Token');
      expect(result.time_range.hours).toBe(24);
      expect(result.summary.total_requests).toBe(100);
      expect(result.summary.success_rate).toBe(95.0);
    });

    it('returns summary with optional average_response_time when present', async () => {
      mockGet.mockResolvedValueOnce(axiosWrap(SUMMARY_RESPONSE));

      const result = await service_api.getServiceActivitySummary('svc-aaa-111');

      expect(result.summary.average_response_time).toBe(42);
    });

    it('returns summary without average_response_time when absent', async () => {
      const responseWithoutAvg = {
        ...SUMMARY_RESPONSE,
        summary: { ...SUMMARY_RESPONSE.summary, average_response_time: undefined },
      };
      mockGet.mockResolvedValueOnce(axiosWrap(responseWithoutAvg));

      const result = await service_api.getServiceActivitySummary('svc-aaa-111');

      expect(result.summary.average_response_time).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Service not found'));

      await expect(service_api.getServiceActivitySummary('no-such-id')).rejects.toThrow(
        'Service not found',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // cleanupServiceActivities()
  // ---------------------------------------------------------------------------

  describe('cleanupServiceActivities()', () => {
    it('calls DELETE /admin/services/:serviceId/activities/cleanup with default days=30', async () => {
      mockDelete.mockResolvedValueOnce(
        axiosWrap({ message: 'Cleaned up', deleted_count: 150, cutoff_date: '2026-05-06T00:00:00Z' }),
      );

      await service_api.cleanupServiceActivities('svc-aaa-111');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities/cleanup`, {
        params: { days: 30 },
      });
    });

    it('passes the provided days value as a query param', async () => {
      mockDelete.mockResolvedValueOnce(
        axiosWrap({ message: 'Cleaned', deleted_count: 50, cutoff_date: '2026-05-21T00:00:00Z' }),
      );

      await service_api.cleanupServiceActivities('svc-aaa-111', 14);

      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities/cleanup`, {
        params: { days: 14 },
      });
    });

    it('interpolates the service id into the URL', async () => {
      mockDelete.mockResolvedValueOnce(
        axiosWrap({ message: 'Cleaned', deleted_count: 0, cutoff_date: '2026-05-06T00:00:00Z' }),
      );

      await service_api.cleanupServiceActivities('svc-bbb-222');

      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/svc-bbb-222/activities/cleanup`, {
        params: { days: 30 },
      });
    });

    it('passes days=0 correctly when explicitly provided', async () => {
      mockDelete.mockResolvedValueOnce(
        axiosWrap({ message: 'Cleaned', deleted_count: 999, cutoff_date: '2026-06-05T00:00:00Z' }),
      );

      await service_api.cleanupServiceActivities('svc-aaa-111', 0);

      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/svc-aaa-111/activities/cleanup`, {
        params: { days: 0 },
      });
    });

    it('returns message, deleted_count, and cutoff_date', async () => {
      mockDelete.mockResolvedValueOnce(
        axiosWrap({
          message: 'Cleaned up 150 activities',
          deleted_count: 150,
          cutoff_date: '2026-05-06T00:00:00Z',
        }),
      );

      const result = await service_api.cleanupServiceActivities('svc-aaa-111');

      expect(result.message).toBe('Cleaned up 150 activities');
      expect(result.deleted_count).toBe(150);
      expect(result.cutoff_date).toBe('2026-05-06T00:00:00Z');
    });

    it('returns deleted_count=0 when no activities were cleaned up', async () => {
      mockDelete.mockResolvedValueOnce(
        axiosWrap({ message: 'Nothing to clean', deleted_count: 0, cutoff_date: '2026-05-06T00:00:00Z' }),
      );

      const result = await service_api.cleanupServiceActivities('svc-aaa-111');

      expect(result.deleted_count).toBe(0);
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Service not found'));

      await expect(service_api.cleanupServiceActivities('no-such-id')).rejects.toThrow(
        'Service not found',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Exported singleton — identity check
  // ---------------------------------------------------------------------------

  describe('exported singleton', () => {
    it('exports service_api as a non-null object', () => {
      expect(service_api).toBeDefined();
      expect(typeof service_api).toBe('object');
    });

    it('exposes all expected method names', () => {
      const methods = [
        'getServices',
        'getService',
        'createService',
        'updateService',
        'deleteService',
        'regenerateToken',
        'suspendService',
        'activateService',
        'revokeService',
        'getServiceActivities',
        'getServiceActivity',
        'getServiceActivitySummary',
        'cleanupServiceActivities',
      ];
      for (const method of methods) {
        expect(typeof (service_api as unknown as Record<string, unknown>)[method]).toBe('function');
      }
    });
  });
});
