import { peerCapabilitiesApi } from './peerCapabilitiesApi';
import type { CreateCapabilityRequest, FederationCapability } from '../../types/capability.types';

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
// Fixtures
// =============================================================================

const PEER_ID = 'peer-abc-123';
const CAP_ID = 'cap-xyz-456';
const BASE_URL = `/system/platform/peers/${PEER_ID}/capabilities`;

const CAP_A: FederationCapability = {
  id: CAP_ID,
  federation_peer_id: PEER_ID,
  resource_kind: 'SystemNode',
  direction: 'push_local_to_remote',
  policy: 'manual',
  filter: {},
  conflict_resolution: 'local_wins',
  last_synced_at: null,
  sync_cursor: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CAP_B: FederationCapability = {
  id: 'cap-bbb-789',
  federation_peer_id: PEER_ID,
  resource_kind: 'Ai::Agent',
  direction: 'bidirectional',
  policy: 'auto_on_change',
  filter: { workspace: 'prod' },
  conflict_resolution: 'newer_wins_logical_clock',
  last_synced_at: '2026-05-01T12:00:00Z',
  sync_cursor: { checkpoint: 42 },
  created_at: '2026-02-15T08:00:00Z',
  updated_at: '2026-05-01T12:00:00Z',
};

/** Double-envelope helper: AxiosResponse body = { success: true, data: <payload> } */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// =============================================================================
// Tests
// =============================================================================

describe('peerCapabilitiesApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list
  // ---------------------------------------------------------------------------

  describe('list', () => {
    it('calls GET /system/platform/peers/:peerId/capabilities and returns capabilities + count', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ capabilities: [CAP_A, CAP_B], count: 2 }),
      );

      const result = await peerCapabilitiesApi.list(PEER_ID);

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE_URL);
      expect(result.capabilities).toHaveLength(2);
      expect(result.count).toBe(2);
      expect(result.capabilities[0]).toEqual(CAP_A);
      expect(result.capabilities[1]).toEqual(CAP_B);
    });

    it('returns an empty capabilities array and count 0 when no capabilities exist', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ capabilities: [], count: 0 }),
      );

      const result = await peerCapabilitiesApi.list(PEER_ID);

      expect(result.capabilities).toEqual([]);
      expect(result.count).toBe(0);
    });

    it('uses a different peerId in the URL when called with a different peer', async () => {
      const OTHER_PEER = 'peer-other-999';
      mockGet.mockResolvedValueOnce(
        envelope({ capabilities: [CAP_A], count: 1 }),
      );

      await peerCapabilitiesApi.list(OTHER_PEER);

      expect(mockGet).toHaveBeenCalledWith(
        `/system/platform/peers/${OTHER_PEER}/capabilities`,
      );
    });

    it('propagates errors thrown by apiClient.get', async () => {
      const networkError = new Error('Network Error');
      mockGet.mockRejectedValueOnce(networkError);

      await expect(peerCapabilitiesApi.list(PEER_ID)).rejects.toThrow('Network Error');
    });
  });

  // ---------------------------------------------------------------------------
  // create
  // ---------------------------------------------------------------------------

  describe('create', () => {
    const createReq: CreateCapabilityRequest = {
      resource_kind: 'SystemNode',
      direction: 'push_local_to_remote',
      policy: 'manual',
      conflict_resolution: 'local_wins',
    };

    it('calls POST /system/platform/peers/:peerId/capabilities with the request body and returns the capability', async () => {
      mockPost.mockResolvedValueOnce(
        envelope({ capability: CAP_A }),
      );

      const result = await peerCapabilitiesApi.create(PEER_ID, createReq);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(BASE_URL, createReq);
      expect(result).toEqual(CAP_A);
    });

    it('passes all optional fields (filter, conflict_resolution) through to the POST body', async () => {
      const reqWithFilter: CreateCapabilityRequest = {
        resource_kind: 'Ai::Agent',
        direction: 'bidirectional',
        policy: 'auto_on_change',
        filter: { workspace: 'prod' },
        conflict_resolution: 'newer_wins_logical_clock',
      };
      mockPost.mockResolvedValueOnce(
        envelope({ capability: CAP_B }),
      );

      const result = await peerCapabilitiesApi.create(PEER_ID, reqWithFilter);

      expect(mockPost).toHaveBeenCalledWith(BASE_URL, reqWithFilter);
      expect(result.resource_kind).toBe('Ai::Agent');
      expect(result.direction).toBe('bidirectional');
    });

    it('returns the capability unwrapped from the nested { capability } envelope', async () => {
      mockPost.mockResolvedValueOnce(
        envelope({ capability: CAP_A }),
      );

      const result = await peerCapabilitiesApi.create(PEER_ID, createReq);

      // Must be the FederationCapability directly, NOT { capability: ... }
      expect(result.id).toBe(CAP_A.id);
      expect(result.federation_peer_id).toBe(PEER_ID);
    });

    it('uses a different peerId in the URL when called with a different peer', async () => {
      const OTHER_PEER = 'peer-other-999';
      mockPost.mockResolvedValueOnce(
        envelope({ capability: { ...CAP_A, federation_peer_id: OTHER_PEER } }),
      );

      await peerCapabilitiesApi.create(OTHER_PEER, createReq);

      expect(mockPost).toHaveBeenCalledWith(
        `/system/platform/peers/${OTHER_PEER}/capabilities`,
        createReq,
      );
    });

    it('propagates errors thrown by apiClient.post', async () => {
      const apiError = new Error('Unprocessable Entity');
      mockPost.mockRejectedValueOnce(apiError);

      await expect(peerCapabilitiesApi.create(PEER_ID, createReq)).rejects.toThrow(
        'Unprocessable Entity',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // destroy
  // ---------------------------------------------------------------------------

  describe('destroy', () => {
    it('calls DELETE /system/platform/peers/:peerId/capabilities/:capId', async () => {
      mockDelete.mockResolvedValueOnce(
        envelope({ deleted: true, id: CAP_ID }),
      );

      await peerCapabilitiesApi.destroy(PEER_ID, CAP_ID);

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${BASE_URL}/${CAP_ID}`);
    });

    it('resolves void (returns nothing) on success', async () => {
      mockDelete.mockResolvedValueOnce(
        envelope({ deleted: true, id: CAP_ID }),
      );

      const result = await peerCapabilitiesApi.destroy(PEER_ID, CAP_ID);

      expect(result).toBeUndefined();
    });

    it('uses the correct compound URL with a different peerId and capId', async () => {
      const OTHER_PEER = 'peer-other-999';
      const OTHER_CAP = 'cap-other-111';
      mockDelete.mockResolvedValueOnce(
        envelope({ deleted: true, id: OTHER_CAP }),
      );

      await peerCapabilitiesApi.destroy(OTHER_PEER, OTHER_CAP);

      expect(mockDelete).toHaveBeenCalledWith(
        `/system/platform/peers/${OTHER_PEER}/capabilities/${OTHER_CAP}`,
      );
    });

    it('propagates errors thrown by apiClient.delete', async () => {
      const apiError = new Error('Not Found');
      mockDelete.mockRejectedValueOnce(apiError);

      await expect(peerCapabilitiesApi.destroy(PEER_ID, CAP_ID)).rejects.toThrow('Not Found');
    });
  });
});
