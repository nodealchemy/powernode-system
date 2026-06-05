import { childrenApi } from './childrenApi';
import type {
  ChildPeerDetail,
  ChildPeerSummary,
  ChildrenFilters,
  ChildrenListResponse,
  SpawnRequest,
  SpawnResponse,
} from '../../types/spawn.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/**
 * Construct a double-envelope AxiosResponse for the given payload.
 * Mirrors the backend's `render_success` shape:
 *   { data: { success: true, data: <payload> } }
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const CHILD_SUMMARY: ChildPeerSummary = {
  id: 'child-1',
  remote_instance_url: 'https://child.example.com',
  spawn_mode: 'managed_child',
  status: 'active',
  created_at: '2026-01-01T00:00:00Z',
  last_heartbeat_at: '2026-01-02T00:00:00Z',
  acceptance_pending: false,
  acceptance_expires_at: null,
};

const CHILD_DETAIL: ChildPeerDetail = {
  ...CHILD_SUMMARY,
  endpoints: [{ url: 'https://child.example.com/api' }],
  capabilities: { federation: true },
  metadata: { region: 'us-east-1' },
  signed_at: '2026-01-01T00:01:00Z',
};

const SPAWN_REQUEST: SpawnRequest = {
  spawn_mode: 'managed_child',
  parent_url: 'https://parent.example.com',
  spawn_target: {
    template_id: 'tpl-1',
    region: 'us-east-1',
    instance_size: 'medium',
  },
  token_ttl_seconds: 3600,
};

const SPAWN_RESPONSE: SpawnResponse = {
  child: CHILD_DETAIL,
  acceptance_token: 'tok-abc123',
  spawn_payload: { signed: true },
};

// =============================================================================
// Tests
// =============================================================================

describe('childrenApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
  });

  // ---------------------------------------------------------------------------
  // listChildren
  // ---------------------------------------------------------------------------

  describe('listChildren', () => {
    it('calls GET /system/federation/children with no params when filters is omitted', async () => {
      const listResponse: ChildrenListResponse = {
        children: [CHILD_SUMMARY],
        count: 1,
      };
      mockGet.mockResolvedValueOnce(envelope(listResponse));

      const result = await childrenApi.listChildren();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/federation/children', { params: {} });
      expect(result).toEqual(listResponse);
    });

    it('returns the full children list with count', async () => {
      const listResponse: ChildrenListResponse = {
        children: [CHILD_SUMMARY],
        count: 1,
      };
      mockGet.mockResolvedValueOnce(envelope(listResponse));

      const result = await childrenApi.listChildren();

      expect(result.children).toHaveLength(1);
      expect(result.children[0]).toEqual(CHILD_SUMMARY);
      expect(result.count).toBe(1);
    });

    it('returns an empty children list when no children exist', async () => {
      const listResponse: ChildrenListResponse = { children: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(listResponse));

      const result = await childrenApi.listChildren();

      expect(result.children).toHaveLength(0);
      expect(result.count).toBe(0);
    });

    it('passes spawn_mode filter as a query param', async () => {
      const listResponse: ChildrenListResponse = { children: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(listResponse));

      const filters: ChildrenFilters = { spawn_mode: 'autonomous_peer' };
      await childrenApi.listChildren(filters);

      expect(mockGet).toHaveBeenCalledWith('/system/federation/children', {
        params: { spawn_mode: 'autonomous_peer' },
      });
    });

    it('passes status as a string param when a single status is provided', async () => {
      const listResponse: ChildrenListResponse = { children: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(listResponse));

      const filters: ChildrenFilters = { status: 'active' };
      await childrenApi.listChildren(filters);

      expect(mockGet).toHaveBeenCalledWith('/system/federation/children', {
        params: { status: 'active' },
      });
    });

    it('joins multiple status values with a comma when status is an array', async () => {
      const listResponse: ChildrenListResponse = { children: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(listResponse));

      const filters: ChildrenFilters = { status: ['active', 'degraded'] };
      await childrenApi.listChildren(filters);

      expect(mockGet).toHaveBeenCalledWith('/system/federation/children', {
        params: { status: 'active,degraded' },
      });
    });

    it('omits empty array values from the params', async () => {
      const listResponse: ChildrenListResponse = { children: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(listResponse));

      // status as empty array should be omitted
      const filters = { status: [] as never[] };
      await childrenApi.listChildren(filters as ChildrenFilters);

      expect(mockGet).toHaveBeenCalledWith('/system/federation/children', {
        params: {},
      });
    });

    it('omits null and undefined filter values', async () => {
      const listResponse: ChildrenListResponse = { children: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(listResponse));

      // Filter with undefined spawn_mode — should not appear in params
      const filters = { spawn_mode: undefined };
      await childrenApi.listChildren(filters as ChildrenFilters);

      expect(mockGet).toHaveBeenCalledWith('/system/federation/children', {
        params: {},
      });
    });

    it('passes combined filters when both spawn_mode and status are set', async () => {
      const listResponse: ChildrenListResponse = { children: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(listResponse));

      const filters: ChildrenFilters = {
        spawn_mode: 'cluster_member',
        status: ['enrolled', 'active'],
      };
      await childrenApi.listChildren(filters);

      expect(mockGet).toHaveBeenCalledWith('/system/federation/children', {
        params: { spawn_mode: 'cluster_member', status: 'enrolled,active' },
      });
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(childrenApi.listChildren()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // getChild
  // ---------------------------------------------------------------------------

  describe('getChild', () => {
    it('calls GET /system/federation/children/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ child: CHILD_DETAIL }));

      await childrenApi.getChild('child-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/federation/children/child-1');
    });

    it('extracts and returns the child field from the response envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ child: CHILD_DETAIL }));

      const result = await childrenApi.getChild('child-1');

      expect(result).toEqual(CHILD_DETAIL);
      expect(result.id).toBe('child-1');
      expect(result.endpoints).toEqual([{ url: 'https://child.example.com/api' }]);
      expect(result.capabilities).toEqual({ federation: true });
      expect(result.metadata).toEqual({ region: 'us-east-1' });
      expect(result.signed_at).toBe('2026-01-01T00:01:00Z');
    });

    it('uses the provided id in the URL path', async () => {
      const anotherChild: ChildPeerDetail = {
        ...CHILD_DETAIL,
        id: 'child-42',
        remote_instance_url: 'https://other-child.example.com',
      };
      mockGet.mockResolvedValueOnce(envelope({ child: anotherChild }));

      const result = await childrenApi.getChild('child-42');

      expect(mockGet).toHaveBeenCalledWith('/system/federation/children/child-42');
      expect(result.id).toBe('child-42');
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(childrenApi.getChild('nonexistent')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // spawn
  // ---------------------------------------------------------------------------

  describe('spawn', () => {
    it('calls POST /system/federation/children/spawn with the full request body', async () => {
      mockPost.mockResolvedValueOnce(envelope(SPAWN_RESPONSE));

      await childrenApi.spawn(SPAWN_REQUEST);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        '/system/federation/children/spawn',
        SPAWN_REQUEST,
      );
    });

    it('returns the full spawn response including child, acceptance_token, and spawn_payload', async () => {
      mockPost.mockResolvedValueOnce(envelope(SPAWN_RESPONSE));

      const result = await childrenApi.spawn(SPAWN_REQUEST);

      expect(result).toEqual(SPAWN_RESPONSE);
      expect(result.acceptance_token).toBe('tok-abc123');
      expect(result.child).toEqual(CHILD_DETAIL);
      expect(result.spawn_payload).toEqual({ signed: true });
    });

    it('sends the spawn_mode in the request body', async () => {
      mockPost.mockResolvedValueOnce(envelope(SPAWN_RESPONSE));

      const req: SpawnRequest = {
        spawn_mode: 'autonomous_peer',
        parent_url: 'https://parent.example.com',
        spawn_target: { template_id: 'tpl-2' },
      };
      await childrenApi.spawn(req);

      const [, body] = mockPost.mock.calls[0] as [string, SpawnRequest];
      expect(body.spawn_mode).toBe('autonomous_peer');
    });

    it('sends token_ttl_seconds when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(SPAWN_RESPONSE));

      const req: SpawnRequest = {
        ...SPAWN_REQUEST,
        token_ttl_seconds: 7200,
      };
      await childrenApi.spawn(req);

      const [, body] = mockPost.mock.calls[0] as [string, SpawnRequest];
      expect(body.token_ttl_seconds).toBe(7200);
    });

    it('omits token_ttl_seconds when not provided (undefined)', async () => {
      mockPost.mockResolvedValueOnce(envelope(SPAWN_RESPONSE));

      const { token_ttl_seconds: _omit, ...reqWithoutTtl } = SPAWN_REQUEST;
      await childrenApi.spawn(reqWithoutTtl);

      const [, body] = mockPost.mock.calls[0] as [string, SpawnRequest];
      expect(body.token_ttl_seconds).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Spawn failed'));

      await expect(childrenApi.spawn(SPAWN_REQUEST)).rejects.toThrow('Spawn failed');
    });
  });

  // ---------------------------------------------------------------------------
  // revoke
  // ---------------------------------------------------------------------------

  describe('revoke', () => {
    it('calls POST /system/federation/children/:id/revoke with an empty body when reason is omitted', async () => {
      const revokedSummary: ChildPeerSummary = { ...CHILD_SUMMARY, status: 'revoked' };
      mockPost.mockResolvedValueOnce(envelope({ child: revokedSummary }));

      await childrenApi.revoke('child-1');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        '/system/federation/children/child-1/revoke',
        {},
      );
    });

    it('calls POST /system/federation/children/:id/revoke with { reason } when reason is provided', async () => {
      const revokedSummary: ChildPeerSummary = { ...CHILD_SUMMARY, status: 'revoked' };
      mockPost.mockResolvedValueOnce(envelope({ child: revokedSummary }));

      await childrenApi.revoke('child-1', 'Decommissioned by operator');

      expect(mockPost).toHaveBeenCalledWith(
        '/system/federation/children/child-1/revoke',
        { reason: 'Decommissioned by operator' },
      );
    });

    it('extracts and returns the child field from the response envelope', async () => {
      const revokedSummary: ChildPeerSummary = { ...CHILD_SUMMARY, status: 'revoked' };
      mockPost.mockResolvedValueOnce(envelope({ child: revokedSummary }));

      const result = await childrenApi.revoke('child-1');

      expect(result).toEqual(revokedSummary);
      expect(result.status).toBe('revoked');
      expect(result.id).toBe('child-1');
    });

    it('uses the provided id in the URL path', async () => {
      const revokedSummary: ChildPeerSummary = { ...CHILD_SUMMARY, id: 'child-99', status: 'revoked' };
      mockPost.mockResolvedValueOnce(envelope({ child: revokedSummary }));

      await childrenApi.revoke('child-99', 'Removed');

      expect(mockPost).toHaveBeenCalledWith(
        '/system/federation/children/child-99/revoke',
        { reason: 'Removed' },
      );
    });

    it('sends empty body ({}) when reason is an empty string — falsy string treated as absent', async () => {
      const revokedSummary: ChildPeerSummary = { ...CHILD_SUMMARY, status: 'revoked' };
      mockPost.mockResolvedValueOnce(envelope({ child: revokedSummary }));

      await childrenApi.revoke('child-1', '');

      // Empty string is falsy — the source uses `reason ? { reason } : {}`
      expect(mockPost).toHaveBeenCalledWith(
        '/system/federation/children/child-1/revoke',
        {},
      );
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Revocation failed'));

      await expect(childrenApi.revoke('child-1')).rejects.toThrow('Revocation failed');
    });
  });
});
