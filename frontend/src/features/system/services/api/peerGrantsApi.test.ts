// Behavioral tests for peerGrantsApi.
//
// Covers every exported method: exact URL construction, query params,
// request payloads, envelope unwrapping, and optional-argument edge cases.
//
// Plan reference: Decentralized Federation §E + §I + P4 + P7.5.

import { peerGrantsApi } from './peerGrantsApi';
import type {
  FederationGrant,
  GrantLifecycle,
  GrantsListResponse,
  IssueGrantRequest,
} from '../../types/grant.types';

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
 * Build a double-envelope AxiosResponse body for a generic success.
 * Mirrors the backend's `render_success` shape:
 *   { data: { success: true, data: <payload> } }
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const PEER_ID = 'peer-abc-123';
const BASE = `/system/platform/peers/${PEER_ID}/grants`;

const GRANT: FederationGrant = {
  id: 'grant-1',
  federation_peer_id: PEER_ID,
  remote_subject: 'agent:fleet-operator',
  resource_kind: 'node_instance',
  resource_id: 'inst-001',
  permission_scopes: ['read', 'write'],
  lifecycle: 'active',
  issued_at: '2026-01-01T00:00:00Z',
  expires_at: '2026-04-01T00:00:00Z',
  revoked_at: null,
  revocation_reason: null,
  archived_at: null,
  node_instance_ids: ['inst-001', 'inst-002'],
  sdwan_network_ids: ['net-001'],
  source_cidrs: ['10.0.0.0/8'],
  unrestricted: false,
  grantor_user_id: 'user-99',
};

// IMP-27cc7dceb97b — `bearer_token` is present ONLY on the POST /grants
// issuance response. GET /grants and POST .../revoke omit it entirely, so the
// list fixture above must not carry it: a list fixture that does would assert,
// as the frontend's only statement about the list shape, the very disclosure
// the server removed. Not a real credential.
const GRANT_ISSUED: FederationGrant = {
  ...GRANT,
  bearer_token: 'fgs.fixture.notarealtoken',
};

const GRANT_2: FederationGrant = {
  ...GRANT,
  id: 'grant-2',
  lifecycle: 'revoked',
  revoked_at: '2026-02-01T00:00:00Z',
  revocation_reason: 'decommissioned',
  permission_scopes: ['read'],
};

const LIST_RESPONSE: GrantsListResponse = {
  grants: [GRANT, GRANT_2],
  count: 2,
};

const ISSUE_REQUEST: IssueGrantRequest = {
  resource_kind: 'node_instance',
  resource_id: 'inst-001',
  remote_subject: 'agent:fleet-operator',
  permission_scopes: ['read', 'write'],
  ttl_days: 90,
  node_instance_ids: ['inst-001'],
  sdwan_network_ids: ['net-001'],
  source_cidrs: ['10.0.0.0/8'],
};

// =============================================================================
// Tests
// =============================================================================

describe('peerGrantsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list()
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('calls GET /system/platform/peers/:peerId/grants with empty params when no state is provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await peerGrantsApi.list(PEER_ID);

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
      expect(result).toEqual(LIST_RESPONSE);
    });

    it('interpolates peerId correctly into the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ grants: [], count: 0 }));

      await peerGrantsApi.list('peer-xyz-999');

      expect(mockGet).toHaveBeenCalledWith(
        '/system/platform/peers/peer-xyz-999/grants',
        { params: {} },
      );
    });

    it('passes state as a query param when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      await peerGrantsApi.list(PEER_ID, 'active');

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { state: 'active' } });
    });

    it('passes "revoked" state correctly', async () => {
      mockGet.mockResolvedValueOnce(envelope({ grants: [GRANT_2], count: 1 }));

      await peerGrantsApi.list(PEER_ID, 'revoked');

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { state: 'revoked' } });
    });

    it('passes "expired" state correctly', async () => {
      mockGet.mockResolvedValueOnce(envelope({ grants: [], count: 0 }));

      await peerGrantsApi.list(PEER_ID, 'expired');

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { state: 'expired' } });
    });

    it('passes "archived" state correctly', async () => {
      mockGet.mockResolvedValueOnce(envelope({ grants: [], count: 0 }));

      const state: GrantLifecycle = 'archived';
      await peerGrantsApi.list(PEER_ID, state);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { state: 'archived' } });
    });

    it('returns the unwrapped grants list with count', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await peerGrantsApi.list(PEER_ID);

      expect(result.grants).toHaveLength(2);
      expect(result.grants[0]).toEqual(GRANT);
      expect(result.grants[1]).toEqual(GRANT_2);
      expect(result.count).toBe(2);
    });

    it('returns an empty grants array when no grants exist', async () => {
      mockGet.mockResolvedValueOnce(envelope({ grants: [], count: 0 }));

      const result = await peerGrantsApi.list(PEER_ID);

      expect(result.grants).toHaveLength(0);
      expect(result.count).toBe(0);
    });

    it('does NOT include a state param when state is undefined', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      await peerGrantsApi.list(PEER_ID, undefined);

      const [, options] = mockGet.mock.calls[0] as [string, { params: Record<string, unknown> }];
      expect(options.params).toEqual({});
      expect(options.params['state']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(peerGrantsApi.list(PEER_ID)).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // issue()
  // ---------------------------------------------------------------------------

  describe('issue()', () => {
    it('calls POST /system/platform/peers/:peerId/grants with the full request body', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT_ISSUED }));

      await peerGrantsApi.issue(PEER_ID, ISSUE_REQUEST);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(BASE, ISSUE_REQUEST);
    });

    it('interpolates peerId correctly into the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT_ISSUED }));

      await peerGrantsApi.issue('peer-different-456', ISSUE_REQUEST);

      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/peers/peer-different-456/grants',
        ISSUE_REQUEST,
      );
    });

    it('returns the unwrapped grant (extracts .grant from envelope)', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT_ISSUED }));

      const result = await peerGrantsApi.issue(PEER_ID, ISSUE_REQUEST);

      expect(result).toEqual(GRANT_ISSUED);
      expect(result.bearer_token).toBe('fgs.fixture.notarealtoken');
      expect(result.id).toBe('grant-1');
      expect(result.lifecycle).toBe('active');
    });

    it('sends the resource_kind and remote_subject in the request body', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT_ISSUED }));

      await peerGrantsApi.issue(PEER_ID, ISSUE_REQUEST);

      const [, body] = mockPost.mock.calls[0] as [string, IssueGrantRequest];
      expect(body.resource_kind).toBe('node_instance');
      expect(body.remote_subject).toBe('agent:fleet-operator');
    });

    it('sends permission_scopes in the request body', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT_ISSUED }));

      await peerGrantsApi.issue(PEER_ID, ISSUE_REQUEST);

      const [, body] = mockPost.mock.calls[0] as [string, IssueGrantRequest];
      expect(body.permission_scopes).toEqual(['read', 'write']);
    });

    it('sends ttl_days when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT }));

      await peerGrantsApi.issue(PEER_ID, { ...ISSUE_REQUEST, ttl_days: 30 });

      const [, body] = mockPost.mock.calls[0] as [string, IssueGrantRequest];
      expect(body.ttl_days).toBe(30);
    });

    it('works without optional ttl_days — omits it from request when not provided', async () => {
      const minimalRequest: IssueGrantRequest = {
        resource_kind: 'node_instance',
        remote_subject: 'service:billing',
        permission_scopes: ['read'],
      };
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT }));

      await peerGrantsApi.issue(PEER_ID, minimalRequest);

      const [, body] = mockPost.mock.calls[0] as [string, IssueGrantRequest];
      expect(body.ttl_days).toBeUndefined();
      expect(body.resource_id).toBeUndefined();
      expect(body.node_instance_ids).toBeUndefined();
      expect(body.sdwan_network_ids).toBeUndefined();
      expect(body.source_cidrs).toBeUndefined();
    });

    it('sends node_instance_ids when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT }));

      await peerGrantsApi.issue(PEER_ID, { ...ISSUE_REQUEST, node_instance_ids: ['inst-A', 'inst-B'] });

      const [, body] = mockPost.mock.calls[0] as [string, IssueGrantRequest];
      expect(body.node_instance_ids).toEqual(['inst-A', 'inst-B']);
    });

    it('sends sdwan_network_ids when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT }));

      await peerGrantsApi.issue(PEER_ID, { ...ISSUE_REQUEST, sdwan_network_ids: ['net-X', 'net-Y'] });

      const [, body] = mockPost.mock.calls[0] as [string, IssueGrantRequest];
      expect(body.sdwan_network_ids).toEqual(['net-X', 'net-Y']);
    });

    it('sends source_cidrs when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT }));

      await peerGrantsApi.issue(PEER_ID, { ...ISSUE_REQUEST, source_cidrs: ['192.168.0.0/16'] });

      const [, body] = mockPost.mock.calls[0] as [string, IssueGrantRequest];
      expect(body.source_cidrs).toEqual(['192.168.0.0/16']);
    });

    it('does NOT include a wrapper object — returns the FederationGrant directly', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT }));

      const result = await peerGrantsApi.issue(PEER_ID, ISSUE_REQUEST);

      // Must NOT be the { grant: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['grant']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(peerGrantsApi.issue(PEER_ID, ISSUE_REQUEST)).rejects.toThrow('Validation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // revoke()
  // ---------------------------------------------------------------------------

  describe('revoke()', () => {
    it('calls POST /system/platform/peers/:peerId/grants/:grantId/revoke with empty body when no reason', async () => {
      const revokedGrant: FederationGrant = {
        ...GRANT,
        lifecycle: 'revoked',
        revoked_at: '2026-03-01T00:00:00Z',
      };
      mockPost.mockResolvedValueOnce(envelope({ grant: revokedGrant }));

      await peerGrantsApi.revoke(PEER_ID, 'grant-1');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/grant-1/revoke`, {});
    });

    it('interpolates both peerId and grantId correctly into the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT }));

      await peerGrantsApi.revoke('peer-xyz', 'grant-abc');

      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/peers/peer-xyz/grants/grant-abc/revoke',
        {},
      );
    });

    it('includes the reason in the body when provided', async () => {
      const revokedGrant: FederationGrant = {
        ...GRANT,
        lifecycle: 'revoked',
        revoked_at: '2026-03-01T00:00:00Z',
        revocation_reason: 'key-compromise',
      };
      mockPost.mockResolvedValueOnce(envelope({ grant: revokedGrant }));

      await peerGrantsApi.revoke(PEER_ID, 'grant-1', 'key-compromise');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/grant-1/revoke`, { reason: 'key-compromise' });
    });

    it('sends empty body ({}) when reason is an empty string — falsy string treated as absent', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT }));

      await peerGrantsApi.revoke(PEER_ID, 'grant-1', '');

      // Empty string is falsy — source uses `reason ? { reason } : {}`
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/grant-1/revoke`, {});
    });

    it('returns the unwrapped grant (extracts .grant from envelope)', async () => {
      const revokedGrant: FederationGrant = {
        ...GRANT,
        lifecycle: 'revoked',
        revoked_at: '2026-03-01T00:00:00Z',
        revocation_reason: 'superseded',
      };
      mockPost.mockResolvedValueOnce(envelope({ grant: revokedGrant }));

      const result = await peerGrantsApi.revoke(PEER_ID, 'grant-1', 'superseded');

      expect(result).toEqual(revokedGrant);
      expect(result.lifecycle).toBe('revoked');
      expect(result.revocation_reason).toBe('superseded');
      expect(result.revoked_at).toBe('2026-03-01T00:00:00Z');
    });

    it('does NOT include a wrapper object — returns the FederationGrant directly', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT }));

      const result = await peerGrantsApi.revoke(PEER_ID, 'grant-1');

      // Must NOT be the { grant: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['grant']).toBeUndefined();
    });

    it('uses the supplied grantId in the URL path', async () => {
      mockPost.mockResolvedValueOnce(envelope({ grant: GRANT }));

      await peerGrantsApi.revoke(PEER_ID, 'grant-99');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/grant-99/revoke`, {});
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Revocation failed'));

      await expect(peerGrantsApi.revoke(PEER_ID, 'grant-1')).rejects.toThrow('Revocation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('correctly extracts data from double-envelope { data: { success, data: payload } } in list()', async () => {
      const payload: GrantsListResponse = { grants: [GRANT], count: 1 };
      mockGet.mockResolvedValueOnce({ data: { success: true, data: payload } });

      const result = await peerGrantsApi.list(PEER_ID);

      expect(result).toEqual(payload);
      // Must NOT contain envelope keys
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('correctly extracts the nested .grant from issue() envelope', async () => {
      // issue() envelope shape: { success: true, data: { grant: FederationGrant } }
      // The method must unwrap data.grant, not return the wrapper object.
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: { grant: GRANT } },
      });

      const result = await peerGrantsApi.issue(PEER_ID, ISSUE_REQUEST);

      expect(result.id).toBe('grant-1');
      // Must NOT be the { grant: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['grant']).toBeUndefined();
    });

    it('correctly extracts the nested .grant from revoke() envelope', async () => {
      // revoke() envelope shape: { success: true, data: { grant: FederationGrant } }
      const revokedGrant: FederationGrant = { ...GRANT, lifecycle: 'revoked' };
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: { grant: revokedGrant } },
      });

      const result = await peerGrantsApi.revoke(PEER_ID, 'grant-1');

      expect(result.lifecycle).toBe('revoked');
      expect((result as unknown as Record<string, unknown>)['grant']).toBeUndefined();
    });
  });

  // ---------------------------------------------------------------------------
  // URL construction — base helper
  // ---------------------------------------------------------------------------

  describe('URL construction', () => {
    it('uses the correct base path template for all three methods', async () => {
      mockGet.mockResolvedValue(envelope({ grants: [], count: 0 }));
      mockPost.mockResolvedValue(envelope({ grant: GRANT }));

      const peerId = 'peer-url-test';
      const expectedBase = `/system/platform/peers/${peerId}/grants`;

      await peerGrantsApi.list(peerId);
      expect(mockGet).toHaveBeenCalledWith(expectedBase, expect.any(Object));

      await peerGrantsApi.issue(peerId, ISSUE_REQUEST);
      expect(mockPost).toHaveBeenCalledWith(expectedBase, expect.any(Object));

      await peerGrantsApi.revoke(peerId, 'g-1');
      expect(mockPost).toHaveBeenCalledWith(`${expectedBase}/g-1/revoke`, expect.any(Object));
    });
  });
});
