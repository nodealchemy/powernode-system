import { platformPeersApi } from './platformPeersApi';
import type {
  InvitePeerRequest,
  PeerListFilters,
  PeerListResponse,
  PlatformPeerDetail,
  PlatformPeerSummary,
} from '../../types/peer.types';

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

const BASE = '/system/platform/peers';

const PEER_SUMMARY: PlatformPeerSummary = {
  id: 'peer-abc-123',
  remote_instance_url: 'https://peer.example.com',
  remote_instance_id: 'inst-999',
  peer_kind: 'platform',
  spawn_role: 'symmetric',
  spawn_mode: 'autonomous_peer',
  status: 'active',
  created_at: '2026-01-01T00:00:00Z',
  last_heartbeat_at: '2026-01-02T00:00:00Z',
  last_handshake_at: '2026-01-02T00:01:00Z',
  endpoints_count: 2,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

const PEER_DETAIL: PlatformPeerDetail = {
  ...PEER_SUMMARY,
  endpoints: [
    {
      url: 'https://peer.example.com/api',
      scope: 'wan',
      priority: 1,
      cidr_hint: null,
      last_verified_at: '2026-01-02T00:01:00Z',
      last_failure_at: null,
      status: 'reachable',
    },
    {
      url: 'https://10.0.0.50/api',
      scope: 'lan',
      priority: 2,
      cidr_hint: '10.0.0.0/24',
      last_verified_at: null,
      last_failure_at: null,
      status: 'unknown',
    },
  ],
  capabilities: { federation: true, sdwan: false },
  extension_slugs: ['supply-chain'],
  metadata: { region: 'eu-west-1' },
  signed_at: '2026-01-01T00:01:00Z',
  contract_version_agreed: '1.0',
  parent_peer_id: null,
  allowed_transitions: ['suspended', 'revoked'],
  grants_count: 3,
  capabilities_count: 2,
  bridges_count: 1,
};

const PEER_SUMMARY_B: PlatformPeerSummary = {
  id: 'peer-bbb-456',
  remote_instance_url: 'https://peer-b.example.com',
  remote_instance_id: null,
  peer_kind: 'sdwan_only',
  spawn_role: null,
  spawn_mode: null,
  status: 'proposed',
  created_at: '2026-03-10T08:00:00Z',
  last_heartbeat_at: null,
  last_handshake_at: null,
  endpoints_count: 0,
  acceptance_pending: true,
  acceptance_expires_at: '2026-03-11T08:00:00Z',
};

const LIST_RESPONSE: PeerListResponse = {
  peers: [PEER_SUMMARY, PEER_SUMMARY_B],
  count: 2,
};

const INVITE_REQUEST: InvitePeerRequest = {
  remote_instance_url: 'https://new-peer.example.com',
  spawn_role: 'child',
  spawn_mode: 'managed_child',
  endpoints: [{ url: 'https://new-peer.example.com/api', scope: 'wan', priority: 1 }],
  token_ttl_seconds: 3600,
};

// =============================================================================
// Tests
// =============================================================================

describe('platformPeersApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
  });

  // ---------------------------------------------------------------------------
  // listPeers
  // ---------------------------------------------------------------------------

  describe('listPeers', () => {
    it('calls GET /system/platform/peers with no params when filters is omitted', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await platformPeersApi.listPeers();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
      expect(result).toEqual(LIST_RESPONSE);
    });

    it('returns the full peer list with count', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await platformPeersApi.listPeers();

      expect(result.peers).toHaveLength(2);
      expect(result.count).toBe(2);
      expect(result.peers[0]).toEqual(PEER_SUMMARY);
      expect(result.peers[1]).toEqual(PEER_SUMMARY_B);
    });

    it('returns an empty peers array and count 0 when no peers exist', async () => {
      const emptyResponse: PeerListResponse = { peers: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(emptyResponse));

      const result = await platformPeersApi.listPeers();

      expect(result.peers).toHaveLength(0);
      expect(result.count).toBe(0);
    });

    it('passes a single status filter as a string query param', async () => {
      const emptyResponse: PeerListResponse = { peers: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(emptyResponse));

      const filters: PeerListFilters = { status: 'active' };
      await platformPeersApi.listPeers(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { status: 'active' } });
    });

    it('joins multiple status values with a comma when status is an array', async () => {
      const emptyResponse: PeerListResponse = { peers: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(emptyResponse));

      const filters: PeerListFilters = { status: ['active', 'degraded'] };
      await platformPeersApi.listPeers(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { status: 'active,degraded' } });
    });

    it('passes spawn_mode filter as a string query param', async () => {
      const emptyResponse: PeerListResponse = { peers: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(emptyResponse));

      const filters: PeerListFilters = { spawn_mode: 'managed_child' };
      await platformPeersApi.listPeers(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { spawn_mode: 'managed_child' } });
    });

    it('passes combined filters when both status and spawn_mode are set', async () => {
      const emptyResponse: PeerListResponse = { peers: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(emptyResponse));

      const filters: PeerListFilters = { status: ['enrolled', 'active'], spawn_mode: 'cluster_member' };
      await platformPeersApi.listPeers(filters);

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { status: 'enrolled,active', spawn_mode: 'cluster_member' },
      });
    });

    it('omits empty array status values from params', async () => {
      const emptyResponse: PeerListResponse = { peers: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(emptyResponse));

      const filters = { status: [] as never[] };
      await platformPeersApi.listPeers(filters as PeerListFilters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });

    it('omits null and undefined filter values from params', async () => {
      const emptyResponse: PeerListResponse = { peers: [], count: 0 };
      mockGet.mockResolvedValueOnce(envelope(emptyResponse));

      const filters = { status: undefined, spawn_mode: undefined };
      await platformPeersApi.listPeers(filters as PeerListFilters);

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: {} });
    });

    it('propagates errors thrown by apiClient.get', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(platformPeersApi.listPeers()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // getPeer
  // ---------------------------------------------------------------------------

  describe('getPeer', () => {
    it('calls GET /system/platform/peers/:id with the correct URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ peer: PEER_DETAIL }));

      await platformPeersApi.getPeer('peer-abc-123');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/peer-abc-123`);
    });

    it('extracts and returns the peer field from the nested { peer } envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ peer: PEER_DETAIL }));

      const result = await platformPeersApi.getPeer('peer-abc-123');

      expect(result).toEqual(PEER_DETAIL);
      // Must be the PlatformPeerDetail directly — NOT { peer: ... }
      expect(result.id).toBe('peer-abc-123');
      expect(result.endpoints).toHaveLength(2);
      expect(result.capabilities).toEqual({ federation: true, sdwan: false });
      expect(result.extension_slugs).toEqual(['supply-chain']);
      expect(result.metadata).toEqual({ region: 'eu-west-1' });
      expect(result.signed_at).toBe('2026-01-01T00:01:00Z');
      expect(result.grants_count).toBe(3);
      expect(result.capabilities_count).toBe(2);
      expect(result.bridges_count).toBe(1);
    });

    it('uses a different peer id in the URL path', async () => {
      const otherPeer: PlatformPeerDetail = { ...PEER_DETAIL, id: 'peer-other-999' };
      mockGet.mockResolvedValueOnce(envelope({ peer: otherPeer }));

      const result = await platformPeersApi.getPeer('peer-other-999');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/peer-other-999`);
      expect(result.id).toBe('peer-other-999');
    });

    it('returns the full allowed_transitions array from the peer detail', async () => {
      mockGet.mockResolvedValueOnce(envelope({ peer: PEER_DETAIL }));

      const result = await platformPeersApi.getPeer('peer-abc-123');

      expect(result.allowed_transitions).toEqual(['suspended', 'revoked']);
    });

    it('propagates errors thrown by apiClient.get', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(platformPeersApi.getPeer('nonexistent')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // invite
  // ---------------------------------------------------------------------------

  describe('invite', () => {
    const INVITE_RESPONSE = {
      peer: PEER_DETAIL,
      acceptance_token: 'tok-single-use-abc123',
    };

    it('calls POST /system/platform/peers with the full invite request body', async () => {
      mockPost.mockResolvedValueOnce(envelope(INVITE_RESPONSE));

      await platformPeersApi.invite(INVITE_REQUEST);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(BASE, INVITE_REQUEST);
    });

    it('returns the full invite response including peer detail and acceptance_token', async () => {
      mockPost.mockResolvedValueOnce(envelope(INVITE_RESPONSE));

      const result = await platformPeersApi.invite(INVITE_REQUEST);

      expect(result.acceptance_token).toBe('tok-single-use-abc123');
      expect(result.peer).toEqual(PEER_DETAIL);
    });

    it('sends remote_instance_url in the request body', async () => {
      mockPost.mockResolvedValueOnce(envelope(INVITE_RESPONSE));

      await platformPeersApi.invite(INVITE_REQUEST);

      const [, body] = mockPost.mock.calls[0] as [string, InvitePeerRequest];
      expect(body.remote_instance_url).toBe('https://new-peer.example.com');
    });

    it('sends spawn_role and spawn_mode when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(INVITE_RESPONSE));

      await platformPeersApi.invite(INVITE_REQUEST);

      const [, body] = mockPost.mock.calls[0] as [string, InvitePeerRequest];
      expect(body.spawn_role).toBe('child');
      expect(body.spawn_mode).toBe('managed_child');
    });

    it('sends token_ttl_seconds when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(INVITE_RESPONSE));

      await platformPeersApi.invite(INVITE_REQUEST);

      const [, body] = mockPost.mock.calls[0] as [string, InvitePeerRequest];
      expect(body.token_ttl_seconds).toBe(3600);
    });

    it('sends endpoints when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(INVITE_RESPONSE));

      await platformPeersApi.invite(INVITE_REQUEST);

      const [, body] = mockPost.mock.calls[0] as [string, InvitePeerRequest];
      expect(body.endpoints).toEqual([
        { url: 'https://new-peer.example.com/api', scope: 'wan', priority: 1 },
      ]);
    });

    it('sends a minimal invite with only remote_instance_url when optional fields are omitted', async () => {
      const minimalReq: InvitePeerRequest = {
        remote_instance_url: 'https://minimal.example.com',
      };
      mockPost.mockResolvedValueOnce(envelope(INVITE_RESPONSE));

      await platformPeersApi.invite(minimalReq);

      expect(mockPost).toHaveBeenCalledWith(BASE, minimalReq);
      const [, body] = mockPost.mock.calls[0] as [string, InvitePeerRequest];
      expect(body.spawn_role).toBeUndefined();
      expect(body.spawn_mode).toBeUndefined();
      expect(body.endpoints).toBeUndefined();
      expect(body.token_ttl_seconds).toBeUndefined();
    });

    it('propagates errors thrown by apiClient.post', async () => {
      mockPost.mockRejectedValueOnce(new Error('Unprocessable Entity'));

      await expect(platformPeersApi.invite(INVITE_REQUEST)).rejects.toThrow('Unprocessable Entity');
    });
  });

  // ---------------------------------------------------------------------------
  // revoke
  // ---------------------------------------------------------------------------

  describe('revoke', () => {
    const REVOKED_PEER: PlatformPeerDetail = { ...PEER_DETAIL, status: 'revoked' };

    it('calls POST /system/platform/peers/:id/revoke with an empty body when reason is omitted', async () => {
      mockPost.mockResolvedValueOnce(envelope({ peer: REVOKED_PEER }));

      await platformPeersApi.revoke('peer-abc-123');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/peer-abc-123/revoke`, {});
    });

    it('calls POST /system/platform/peers/:id/revoke with { reason } when reason is provided', async () => {
      mockPost.mockResolvedValueOnce(envelope({ peer: REVOKED_PEER }));

      await platformPeersApi.revoke('peer-abc-123', 'Operator decommission');

      expect(mockPost).toHaveBeenCalledWith(
        `${BASE}/peer-abc-123/revoke`,
        { reason: 'Operator decommission' },
      );
    });

    it('extracts and returns the peer field from the nested { peer } envelope', async () => {
      mockPost.mockResolvedValueOnce(envelope({ peer: REVOKED_PEER }));

      const result = await platformPeersApi.revoke('peer-abc-123');

      expect(result).toEqual(REVOKED_PEER);
      // Must be the PlatformPeerDetail directly — NOT { peer: ... }
      expect(result.id).toBe('peer-abc-123');
      expect(result.status).toBe('revoked');
    });

    it('uses the provided id in the URL path', async () => {
      const otherRevoked: PlatformPeerDetail = { ...PEER_DETAIL, id: 'peer-other-999', status: 'revoked' };
      mockPost.mockResolvedValueOnce(envelope({ peer: otherRevoked }));

      await platformPeersApi.revoke('peer-other-999', 'Removed');

      expect(mockPost).toHaveBeenCalledWith(
        `${BASE}/peer-other-999/revoke`,
        { reason: 'Removed' },
      );
    });

    it('sends empty body ({}) when reason is an empty string — falsy string treated as absent', async () => {
      mockPost.mockResolvedValueOnce(envelope({ peer: REVOKED_PEER }));

      await platformPeersApi.revoke('peer-abc-123', '');

      // Empty string is falsy — the source uses `reason ? { reason } : {}`
      expect(mockPost).toHaveBeenCalledWith(
        `${BASE}/peer-abc-123/revoke`,
        {},
      );
    });

    it('returns the full peer detail including endpoints and capabilities after revocation', async () => {
      mockPost.mockResolvedValueOnce(envelope({ peer: REVOKED_PEER }));

      const result = await platformPeersApi.revoke('peer-abc-123');

      expect(result.endpoints).toHaveLength(2);
      expect(result.capabilities).toEqual({ federation: true, sdwan: false });
      expect(result.allowed_transitions).toEqual(['suspended', 'revoked']);
    });

    it('propagates errors thrown by apiClient.post', async () => {
      mockPost.mockRejectedValueOnce(new Error('Revocation failed'));

      await expect(platformPeersApi.revoke('peer-abc-123')).rejects.toThrow('Revocation failed');
    });
  });
});
