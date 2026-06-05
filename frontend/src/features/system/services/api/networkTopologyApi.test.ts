// Behavioral tests for networkTopologyApi.
//
// Covers the single exported method getTopology(): exact URL, double-envelope
// unwrapping, full response payload shape, and error propagation.
// Plan reference: Decentralized Federation §K.5 + P4.5.7.

import { networkTopologyApi } from './networkTopologyApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Build a double-envelope AxiosResponse body for a generic success payload. */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

import type {
  NetworkTopologyResponse,
  TopologyNode,
  TopologyEdge,
  TopologyStats,
} from '../../types/network_topology.types';

const SELF_NODE: TopologyNode = {
  id: 'self-node',
  type: 'self',
  position: { x: 0, y: 0 },
  data: {
    label: 'My Platform',
    account_id: 'acct-123',
    handle_counts: {
      source_top: 0,
      source_bottom: 2,
      target_top: 1,
      target_bottom: 0,
    },
  },
};

const PEER_NODE: TopologyNode = {
  id: 'peer-node-1',
  type: 'peer-platform',
  position: { x: 300, y: 0 },
  data: {
    label: 'Remote Platform',
    subtitle: 'partner.example.com',
    peer_kind: 'platform',
    spawn_role: 'child',
    remote_instance_url: 'https://partner.example.com',
    bridge_count: 3,
    active_bridge_count: 2,
    grant_count: 5,
    last_heartbeat_at: '2026-06-01T12:00:00Z',
    handle_counts: {
      source_top: 1,
      source_bottom: 1,
      target_top: 0,
      target_bottom: 1,
    },
  },
};

const NETWORK_NODE: TopologyNode = {
  id: 'net-node-1',
  type: 'network',
  position: { x: 150, y: 200 },
  data: {
    label: 'prod-net',
    slug: 'prod-net',
    cidr_64: 'fd00::/64',
    routing_protocol: 'bgp',
    status: 'active',
    handle_counts: {
      source_top: 0,
      source_bottom: 0,
      target_top: 2,
      target_bottom: 0,
    },
  },
};

const SDWAN_PEER_NODE: TopologyNode = {
  id: 'sdwan-peer-1',
  type: 'peer-sdwan',
  position: { x: 600, y: 100 },
  data: {
    label: 'SDWAN Only Peer',
    peer_kind: 'sdwan_only',
    spawn_role: null,
    bridge_count: 1,
    active_bridge_count: 1,
    grant_count: 0,
    last_heartbeat_at: null,
    handle_counts: {
      source_top: 0,
      source_bottom: 1,
      target_top: 0,
      target_bottom: 0,
    },
  },
};

const BRIDGE_EDGE: TopologyEdge = {
  id: 'bridge-edge-1',
  source: 'self-node',
  target: 'peer-node-1',
  source_handle: 's_bot_0',
  target_handle: 't_top_0',
  type: 'bridge',
  data: {
    label: 'prod-bridge',
    bridge_id: 'bridge-uuid-1',
    state: 'active',
    activated_at: '2026-05-15T08:00:00Z',
    center_y: 100,
  },
  animated: true,
};

const MEMBERSHIP_EDGE: TopologyEdge = {
  id: 'membership-edge-1',
  source: 'self-node',
  target: 'net-node-1',
  source_handle: 's_bot_1',
  target_handle: 't_top_0',
  type: 'membership',
  data: {
    label: 'member',
  },
  animated: false,
};

const GRANT_SUMMARY_EDGE: TopologyEdge = {
  id: 'grant-edge-1',
  source: 'self-node',
  target: 'peer-node-1',
  type: 'grant_summary',
  data: {
    grant_count: 5,
    broad_scope_count: 2,
    unrestricted_count: 1,
    center_y: 150,
  },
};

const STATS: TopologyStats = {
  peer_count: 2,
  platform_peer_count: 1,
  sdwan_only_peer_count: 1,
  network_count: 1,
  bridge_count: 3,
  active_bridge_count: 2,
  grant_count: 5,
  generated_at: '2026-06-05T10:00:00Z',
};

const FULL_TOPOLOGY: NetworkTopologyResponse = {
  self_id: 'self-node',
  self_label: 'My Platform',
  nodes: [SELF_NODE, PEER_NODE, NETWORK_NODE, SDWAN_PEER_NODE],
  edges: [BRIDGE_EDGE, MEMBERSHIP_EDGE, GRANT_SUMMARY_EDGE],
  stats: STATS,
};

const MINIMAL_TOPOLOGY: NetworkTopologyResponse = {
  self_id: 'self-only',
  self_label: 'Isolated Platform',
  nodes: [
    {
      id: 'self-only',
      type: 'self',
      position: { x: 0, y: 0 },
      data: { label: 'Isolated Platform', account_id: 'acct-isolated' },
    },
  ],
  edges: [],
  stats: {
    peer_count: 0,
    platform_peer_count: 0,
    sdwan_only_peer_count: 0,
    network_count: 0,
    bridge_count: 0,
    active_bridge_count: 0,
    grant_count: 0,
    generated_at: '2026-06-05T10:00:00Z',
  },
};

const BASE_URL = '/system/network/topology';

// =============================================================================
// Tests
// =============================================================================

describe('networkTopologyApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // getTopology()
  // ---------------------------------------------------------------------------

  describe('getTopology()', () => {
    it('calls GET /system/network/topology with no additional params', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      await networkTopologyApi.getTopology();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE_URL);
    });

    it('does not pass a params object or request body', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      await networkTopologyApi.getTopology();

      // The call should have exactly one argument (the URL) — no options/params
      expect(mockGet.mock.calls[0]).toHaveLength(1);
    });

    it('returns the unwrapped NetworkTopologyResponse payload', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      expect(result).toEqual(FULL_TOPOLOGY);
    });

    it('unwraps self_id and self_label from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      expect(result.self_id).toBe('self-node');
      expect(result.self_label).toBe('My Platform');
    });

    it('returns the full nodes array with correct types', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      expect(result.nodes).toHaveLength(4);
      expect(result.nodes[0].type).toBe('self');
      expect(result.nodes[1].type).toBe('peer-platform');
      expect(result.nodes[2].type).toBe('network');
      expect(result.nodes[3].type).toBe('peer-sdwan');
    });

    it('preserves node position coordinates', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      expect(result.nodes[0].position).toEqual({ x: 0, y: 0 });
      expect(result.nodes[1].position).toEqual({ x: 300, y: 0 });
      expect(result.nodes[2].position).toEqual({ x: 150, y: 200 });
    });

    it('preserves node data fields including optional ones', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      const peerNode = result.nodes.find((n) => n.id === 'peer-node-1');
      expect(peerNode).toBeDefined();
      expect(peerNode!.data.peer_kind).toBe('platform');
      expect(peerNode!.data.spawn_role).toBe('child');
      expect(peerNode!.data.remote_instance_url).toBe('https://partner.example.com');
      expect(peerNode!.data.bridge_count).toBe(3);
      expect(peerNode!.data.active_bridge_count).toBe(2);
      expect(peerNode!.data.grant_count).toBe(5);
      expect(peerNode!.data.last_heartbeat_at).toBe('2026-06-01T12:00:00Z');
    });

    it('preserves network-type node data including cidr_64 and routing_protocol', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      const networkNode = result.nodes.find((n) => n.id === 'net-node-1');
      expect(networkNode).toBeDefined();
      expect(networkNode!.data.slug).toBe('prod-net');
      expect(networkNode!.data.cidr_64).toBe('fd00::/64');
      expect(networkNode!.data.routing_protocol).toBe('bgp');
      expect(networkNode!.data.status).toBe('active');
    });

    it('preserves handle_counts on nodes', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      const selfNode = result.nodes.find((n) => n.id === 'self-node');
      expect(selfNode!.data.handle_counts).toEqual({
        source_top: 0,
        source_bottom: 2,
        target_top: 1,
        target_bottom: 0,
      });
    });

    it('returns the full edges array with correct types', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      expect(result.edges).toHaveLength(3);
      expect(result.edges[0].type).toBe('bridge');
      expect(result.edges[1].type).toBe('membership');
      expect(result.edges[2].type).toBe('grant_summary');
    });

    it('preserves edge source, target, and handle slots', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      const bridgeEdge = result.edges.find((e) => e.id === 'bridge-edge-1');
      expect(bridgeEdge!.source).toBe('self-node');
      expect(bridgeEdge!.target).toBe('peer-node-1');
      expect(bridgeEdge!.source_handle).toBe('s_bot_0');
      expect(bridgeEdge!.target_handle).toBe('t_top_0');
    });

    it('preserves bridge edge data including state and activated_at', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      const bridgeEdge = result.edges.find((e) => e.type === 'bridge');
      expect(bridgeEdge!.data.bridge_id).toBe('bridge-uuid-1');
      expect(bridgeEdge!.data.state).toBe('active');
      expect(bridgeEdge!.data.activated_at).toBe('2026-05-15T08:00:00Z');
      expect(bridgeEdge!.data.center_y).toBe(100);
      expect(bridgeEdge!.animated).toBe(true);
    });

    it('preserves grant_summary edge data including counts', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      const grantEdge = result.edges.find((e) => e.type === 'grant_summary');
      expect(grantEdge!.data.grant_count).toBe(5);
      expect(grantEdge!.data.broad_scope_count).toBe(2);
      expect(grantEdge!.data.unrestricted_count).toBe(1);
      expect(grantEdge!.data.center_y).toBe(150);
    });

    it('preserves the stats block with all counters', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      expect(result.stats).toEqual(STATS);
      expect(result.stats.peer_count).toBe(2);
      expect(result.stats.platform_peer_count).toBe(1);
      expect(result.stats.sdwan_only_peer_count).toBe(1);
      expect(result.stats.network_count).toBe(1);
      expect(result.stats.bridge_count).toBe(3);
      expect(result.stats.active_bridge_count).toBe(2);
      expect(result.stats.grant_count).toBe(5);
      expect(result.stats.generated_at).toBe('2026-06-05T10:00:00Z');
    });

    it('handles a minimal topology with no peers, edges, or networks (isolated node)', async () => {
      mockGet.mockResolvedValueOnce(envelope(MINIMAL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      expect(result.self_id).toBe('self-only');
      expect(result.nodes).toHaveLength(1);
      expect(result.edges).toHaveLength(0);
      expect(result.stats.peer_count).toBe(0);
      expect(result.stats.bridge_count).toBe(0);
      expect(result.stats.grant_count).toBe(0);
    });

    it('preserves a null last_heartbeat_at on sdwan-only peers', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      const sdwanNode = result.nodes.find((n) => n.type === 'peer-sdwan');
      expect(sdwanNode!.data.last_heartbeat_at).toBeNull();
      expect(sdwanNode!.data.spawn_role).toBeNull();
    });

    it('does NOT return the envelope wrapper keys (success, data wrapping)', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      // The result should be the unwrapped payload — not contain envelope properties
      const cast = result as unknown as Record<string, unknown>;
      expect(cast['success']).toBeUndefined();
      // The payload itself should not have a nested 'data' wrapper key
      expect(cast['data']).toBeUndefined();
    });

    it('propagates network errors from the API client', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(networkTopologyApi.getTopology()).rejects.toThrow('Network error');
    });

    it('propagates HTTP 500 errors from the API client', async () => {
      const serverError = Object.assign(new Error('Internal Server Error'), {
        response: { status: 500, data: { success: false, error: 'Internal Server Error' } },
      });
      mockGet.mockRejectedValueOnce(serverError);

      await expect(networkTopologyApi.getTopology()).rejects.toThrow('Internal Server Error');
    });

    it('propagates HTTP 401 Unauthorized errors', async () => {
      const authError = Object.assign(new Error('Unauthorized'), {
        response: { status: 401, data: { success: false, error: 'Unauthorized' } },
      });
      mockGet.mockRejectedValueOnce(authError);

      await expect(networkTopologyApi.getTopology()).rejects.toThrow('Unauthorized');
    });

    it('can be called multiple times, each hitting the API', async () => {
      const topology1 = { ...FULL_TOPOLOGY, self_id: 'call-1' };
      const topology2 = { ...FULL_TOPOLOGY, self_id: 'call-2' };

      mockGet
        .mockResolvedValueOnce(envelope(topology1))
        .mockResolvedValueOnce(envelope(topology2));

      const result1 = await networkTopologyApi.getTopology();
      const result2 = await networkTopologyApi.getTopology();

      expect(mockGet).toHaveBeenCalledTimes(2);
      expect(result1.self_id).toBe('call-1');
      expect(result2.self_id).toBe('call-2');
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('correctly extracts data from double-envelope { data: { success, data: payload } }', async () => {
      // apiClient.get resolves to an AxiosResponse whose body is
      // { success: true, data: <payload> }. extractData() must reach the inner
      // data, not return the envelope wrapper itself.
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: FULL_TOPOLOGY },
      });

      const result = await networkTopologyApi.getTopology();

      expect(result.self_id).toBe('self-node');
      // Must NOT contain envelope keys on the returned object
      const cast = result as unknown as Record<string, unknown>;
      expect(cast['success']).toBeUndefined();
    });

    it('resolves the NetworkTopologyResponse type contract (all top-level fields present)', async () => {
      mockGet.mockResolvedValueOnce(envelope(FULL_TOPOLOGY));

      const result = await networkTopologyApi.getTopology();

      // All four required top-level fields from NetworkTopologyResponse
      expect(result).toHaveProperty('self_id');
      expect(result).toHaveProperty('self_label');
      expect(result).toHaveProperty('nodes');
      expect(result).toHaveProperty('edges');
      expect(result).toHaveProperty('stats');
      expect(Array.isArray(result.nodes)).toBe(true);
      expect(Array.isArray(result.edges)).toBe(true);
      expect(typeof result.stats).toBe('object');
    });
  });
});
