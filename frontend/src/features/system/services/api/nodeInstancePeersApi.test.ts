// Behavioral tests for nodeInstancePeersApi — request-shaping / response-
// extraction tests for the NodeInstance-as-Agent peer operator surface
// (IMP-20c082f9d519: list/show/searchable/activate/deactivate/execute).
//
// API double-envelope: apiClient.{get,post} resolve to an AxiosResponse
// whose body is { success: true, data: <payload>, meta?: <pagination> } —
// a mocked resolve is therefore { data: { success: true, data: <payload> } }
// with the pagination meta at the BODY root (not inside data).

import { nodeInstancePeersApi } from './nodeInstancePeersApi';
import type {
  SystemNodeInstancePeer,
  SystemNodeInstancePeerSearchResult,
} from '@system/features/system/types/system.types';

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
// Fixtures
// =============================================================================

const PEER_A: SystemNodeInstancePeer = {
  id: 'peer-aaa',
  handle: 'relay-echo',
  node_instance_id: 'inst-001',
  enabled: true,
  status: 'active',
  capabilities: { transports: ['sdwan'] },
  declared_skills: [{ name: 'echo' }, { name: 'deploy' }],
  addresses: ['10.10.0.5'],
  trust_score: 0.8,
  daily_decision_budget: 50,
  daily_decision_used: 3,
  execution_count: 12,
  execution_failure_count: 1,
  first_announced_at: '2026-06-01T00:00:00Z',
  last_announced_at: '2026-07-20T10:00:00Z',
  last_executed_at: '2026-07-19T09:00:00Z',
};

const PEER_B: SystemNodeInstancePeer = {
  ...PEER_A,
  id: 'peer-bbb',
  handle: 'builder-arm',
  node_instance_id: 'inst-002',
  enabled: false,
  status: 'registered',
  declared_skills: [],
};

const META = {
  current_page: 1,
  per_page: 25,
  total_count: 2,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

beforeEach(() => {
  jest.clearAllMocks();
});

// =============================================================================
// list
// =============================================================================

describe('nodeInstancePeersApi.list', () => {
  it('GETs /system/node_instance_peers and unwraps peers + root meta', async () => {
    mockGet.mockResolvedValue({
      data: { success: true, data: { peers: [PEER_A, PEER_B] }, meta: META },
    });

    const result = await nodeInstancePeersApi.list();

    expect(mockGet).toHaveBeenCalledWith('/system/node_instance_peers', { params: {} });
    expect(result.peers).toEqual([PEER_A, PEER_B]);
    expect(result.meta).toEqual(META);
  });

  it('passes enabled filter as the string "true" plus pagination params', async () => {
    mockGet.mockResolvedValue({
      data: { success: true, data: { peers: [PEER_A] }, meta: META },
    });

    await nodeInstancePeersApi.list({ enabled: true, page: 2, per_page: 10 });

    expect(mockGet).toHaveBeenCalledWith('/system/node_instance_peers', {
      params: { enabled: 'true', page: 2, per_page: 10 },
    });
  });

  it('synthesizes meta when the response omits it', async () => {
    mockGet.mockResolvedValue({
      data: { success: true, data: { peers: [PEER_A] } },
    });

    const result = await nodeInstancePeersApi.list();

    expect(result.peers).toEqual([PEER_A]);
    expect(result.meta.total_count).toBe(1);
    expect(result.meta.total_pages).toBe(1);
  });
});

// =============================================================================
// get
// =============================================================================

describe('nodeInstancePeersApi.get', () => {
  it('GETs /system/node_instance_peers/:id and unwraps data.peer', async () => {
    mockGet.mockResolvedValue({
      data: { success: true, data: { peer: PEER_A } },
    });

    const result = await nodeInstancePeersApi.get('peer-aaa');

    expect(mockGet).toHaveBeenCalledWith('/system/node_instance_peers/peer-aaa');
    expect(result).toEqual(PEER_A);
  });
});

// =============================================================================
// searchable
// =============================================================================

describe('nodeInstancePeersApi.searchable', () => {
  const SEARCH_ROW: SystemNodeInstancePeerSearchResult = {
    id: 'peer-aaa',
    handle: 'relay-echo',
    status: 'active',
    node_instance_id: 'inst-001',
    node_name: 'edge-01',
    addresses: ['10.10.0.5'],
  };

  it('GETs the searchable collection without q by default', async () => {
    mockGet.mockResolvedValue({
      data: { success: true, data: { peers: [SEARCH_ROW], count: 1 } },
    });

    const result = await nodeInstancePeersApi.searchable();

    expect(mockGet).toHaveBeenCalledWith('/system/node_instance_peers/searchable', {
      params: {},
    });
    expect(result).toEqual([SEARCH_ROW]);
  });

  it('passes the q prefix filter through', async () => {
    mockGet.mockResolvedValue({
      data: { success: true, data: { peers: [], count: 0 } },
    });

    const result = await nodeInstancePeersApi.searchable('rel');

    expect(mockGet).toHaveBeenCalledWith('/system/node_instance_peers/searchable', {
      params: { q: 'rel' },
    });
    expect(result).toEqual([]);
  });
});

// =============================================================================
// activate / deactivate
// =============================================================================

describe('nodeInstancePeersApi.activate', () => {
  it('POSTs /:id/activate with an empty body and unwraps data.peer', async () => {
    mockPost.mockResolvedValue({
      data: { success: true, data: { peer: PEER_A }, message: 'Peer activated' },
    });

    const result = await nodeInstancePeersApi.activate('peer-aaa');

    expect(mockPost).toHaveBeenCalledWith('/system/node_instance_peers/peer-aaa/activate', {});
    expect(result).toEqual(PEER_A);
  });
});

describe('nodeInstancePeersApi.deactivate', () => {
  it('POSTs /:id/deactivate with an empty body and unwraps data.peer', async () => {
    mockPost.mockResolvedValue({
      data: { success: true, data: { peer: PEER_B }, message: 'Peer deactivated' },
    });

    const result = await nodeInstancePeersApi.deactivate('peer-bbb');

    expect(mockPost).toHaveBeenCalledWith('/system/node_instance_peers/peer-bbb/deactivate', {});
    expect(result).toEqual(PEER_B);
  });
});

// =============================================================================
// execute
// =============================================================================

describe('nodeInstancePeersApi.execute', () => {
  it('POSTs /:id/execute with skill + input and returns the 202 payload', async () => {
    const payload = {
      peer: PEER_A,
      task_id: 'task-123',
      dispatched_task: { skill: 'echo', input: { msg: 'hi' } },
      message: 'Task dispatched; result will arrive via /node_api/peer/execute_result',
    };
    mockPost.mockResolvedValue({ data: { success: true, data: payload } });

    const result = await nodeInstancePeersApi.execute('peer-aaa', {
      skill: 'echo',
      input: { msg: 'hi' },
    });

    expect(mockPost).toHaveBeenCalledWith('/system/node_instance_peers/peer-aaa/execute', {
      skill: 'echo',
      input: { msg: 'hi' },
    });
    expect(result).toEqual(payload);
  });

  it('omits input from the body when not provided', async () => {
    mockPost.mockResolvedValue({
      data: {
        success: true,
        data: { peer: PEER_A, task_id: 'task-456', dispatched_task: { skill: 'echo' }, message: 'ok' },
      },
    });

    await nodeInstancePeersApi.execute('peer-aaa', { skill: 'echo' });

    expect(mockPost).toHaveBeenCalledWith('/system/node_instance_peers/peer-aaa/execute', {
      skill: 'echo',
    });
  });
});
