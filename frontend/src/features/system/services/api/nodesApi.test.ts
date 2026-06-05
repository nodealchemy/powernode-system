/**
 * Behavioral tests for nodesApi.
 *
 * Covers every exported function: request shaping (URLs, payloads, query
 * params), response unwrapping, pagination meta extraction, void deletes,
 * edge cases (missing fields, empty collections, error propagation), and the
 * downloadInstanceBootConfig browser-side download flow.
 *
 * API double-envelope: apiClient.{get,post,put,delete} resolve to an
 * AxiosResponse whose body is { success: true, data: <payload>, meta?: ... }.
 * A mocked resolve is therefore { data: { success: true, data: <payload> } } —
 * the outer `data` key is the AxiosResponse body, inner `data` is the API
 * envelope. Pagination `meta` sits at the response root alongside `data`.
 */

import { nodesApi } from './nodesApi';
import type { NodeCreate, NodeFilters, NodeInstanceCreate } from './nodesApi';
import type { SystemNode, SystemNodeInstance } from '../../types/system.types';
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
// Helpers & Fixtures
// =============================================================================

/**
 * Build the double-envelope AxiosResponse mock value for single-record
 * endpoints: { data: { success: true, data: <payload> } }
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

/**
 * Build a paginated envelope — meta sits at the root of the response body,
 * NOT inside data: { data: { success: true, data: <payload>, meta: <meta> } }
 */
function paginatedEnvelope<T>(payload: T, meta?: Partial<PaginationMeta>) {
  const fullMeta: PaginationMeta = {
    current_page: 1,
    per_page: 20,
    total_count: 1,
    total_pages: 1,
    next_page: null,
    prev_page: null,
    ...meta,
  };
  return { data: { success: true, data: payload, meta: fullMeta } };
}

function makeNode(overrides: Partial<SystemNode> = {}): SystemNode {
  return {
    id: 'node-1',
    name: 'web-node',
    enabled: true,
    allocate_public_ip: false,
    config: {},
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}

function makeInstance(overrides: Partial<SystemNodeInstance> = {}): SystemNodeInstance {
  return {
    id: 'inst-1',
    name: 'web-instance-1',
    variety: 'cloud',
    status: 'running',
    config: {},
    node_id: 'node-1',
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}

const NODE_A = makeNode({ id: 'node-a', name: 'node-alpha' });
const NODE_B = makeNode({ id: 'node-b', name: 'node-beta', enabled: false });
const INST_A = makeInstance({ id: 'inst-a', node_id: 'node-a', name: 'instance-alpha' });
const INST_B = makeInstance({ id: 'inst-b', node_id: 'node-a', name: 'instance-beta', status: 'stopped' });

// =============================================================================
// Test Setup
// =============================================================================

beforeEach(() => {
  mockGet.mockReset();
  mockPost.mockReset();
  mockPut.mockReset();
  mockDelete.mockReset();
});

// =============================================================================
// getNodes
// =============================================================================

describe('nodesApi.getNodes', () => {
  it('calls GET /system/nodes without params when called with no arguments', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ nodes: [NODE_A, NODE_B] }, { total_count: 2, total_pages: 1 })
    );

    const result = await nodesApi.getNodes();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/nodes', { params: undefined });
    expect(result.nodes).toHaveLength(2);
    expect(result.nodes[0]).toEqual(NODE_A);
    expect(result.nodes[1]).toEqual(NODE_B);
  });

  it('passes pagination params when provided', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ nodes: [NODE_A] }, { current_page: 2, per_page: 10, total_count: 15 })
    );

    const params: NodeFilters = { page: 2, per_page: 10 };
    await nodesApi.getNodes(params);

    expect(mockGet).toHaveBeenCalledWith('/system/nodes', { params });
  });

  it('passes enabled filter when provided', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ nodes: [NODE_A] })
    );

    const params: NodeFilters = { enabled: true };
    await nodesApi.getNodes(params);

    expect(mockGet).toHaveBeenCalledWith('/system/nodes', { params: { enabled: true } });
  });

  it('passes enabled=false filter', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ nodes: [NODE_B] })
    );

    await nodesApi.getNodes({ enabled: false });

    expect(mockGet).toHaveBeenCalledWith('/system/nodes', { params: { enabled: false } });
  });

  it('passes combined enabled + pagination filters', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ nodes: [] })
    );

    await nodesApi.getNodes({ enabled: true, page: 3, per_page: 25 });

    expect(mockGet).toHaveBeenCalledWith('/system/nodes', {
      params: { enabled: true, page: 3, per_page: 25 },
    });
  });

  it('returns meta at the top level alongside nodes', async () => {
    const meta: PaginationMeta = {
      current_page: 1,
      per_page: 20,
      total_count: 42,
      total_pages: 3,
      next_page: 2,
      prev_page: null,
    };
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ nodes: [NODE_A] }, meta)
    );

    const result = await nodesApi.getNodes();

    expect(result.meta).toEqual(meta);
    expect(result.meta.total_count).toBe(42);
    expect(result.meta.total_pages).toBe(3);
    expect(result.meta.next_page).toBe(2);
  });

  it('returns an empty nodes array when the collection is empty', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ nodes: [] }, { total_count: 0, total_pages: 1 })
    );

    const result = await nodesApi.getNodes();

    expect(result.nodes).toEqual([]);
    expect(result.meta.total_count).toBe(0);
  });

  it('synthesizes a default meta when the backend omits the meta block', async () => {
    // Simulate a backend that returns data without meta
    mockGet.mockResolvedValueOnce({
      data: { success: true, data: { nodes: [NODE_A] } },
    });

    const result = await nodesApi.getNodes();

    expect(result.nodes).toHaveLength(1);
    // defaultMeta synthesized from item count
    expect(result.meta.total_count).toBe(1);
    expect(result.meta.current_page).toBe(1);
    expect(result.meta.total_pages).toBe(1);
  });

  it('propagates network errors to the caller', async () => {
    mockGet.mockRejectedValueOnce(new Error('Network failure'));

    await expect(nodesApi.getNodes()).rejects.toThrow('Network failure');
  });
});

// =============================================================================
// getNode
// =============================================================================

describe('nodesApi.getNode', () => {
  it('calls GET /system/nodes/:id and returns the node', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node: NODE_A }));

    const result = await nodesApi.getNode('node-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/nodes/node-a');
    expect(result).toEqual(NODE_A);
  });

  it('interpolates the id correctly into the URL', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node: NODE_B }));

    await nodesApi.getNode('node-b');

    expect(mockGet).toHaveBeenCalledWith('/system/nodes/node-b');
  });

  it('unwraps the node field from the envelope', async () => {
    const node = makeNode({ id: 'node-xyz', name: 'custom-node', description: 'desc', enabled: false });
    mockGet.mockResolvedValueOnce(envelope({ node }));

    const result = await nodesApi.getNode('node-xyz');

    expect(result.id).toBe('node-xyz');
    expect(result.name).toBe('custom-node');
    expect(result.description).toBe('desc');
    expect(result.enabled).toBe(false);
  });

  it('propagates API errors to the caller', async () => {
    mockGet.mockRejectedValueOnce(new Error('Not found'));

    await expect(nodesApi.getNode('nonexistent')).rejects.toThrow('Not found');
  });
});

// =============================================================================
// createNode
// =============================================================================

describe('nodesApi.createNode', () => {
  it('calls POST /system/nodes with node wrapper and returns the created node', async () => {
    const payload: NodeCreate = { name: 'new-node' };
    const created = makeNode({ id: 'new-id', name: 'new-node' });
    mockPost.mockResolvedValueOnce(envelope({ node: created }));

    const result = await nodesApi.createNode(payload);

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith('/system/nodes', { node: payload });
    expect(result).toEqual(created);
  });

  it('wraps the full optional payload inside the node key', async () => {
    const payload: NodeCreate = {
      name: 'full-node',
      description: 'A full node',
      enabled: true,
      allocate_public_ip: true,
      node_template_id: 'tpl-123',
      config: { region: 'us-east-1' },
    };
    const created = makeNode({ id: 'full-id', ...payload, config: { region: 'us-east-1' } });
    mockPost.mockResolvedValueOnce(envelope({ node: created }));

    await nodesApi.createNode(payload);

    expect(mockPost).toHaveBeenCalledWith('/system/nodes', { node: payload });
  });

  it('returns the unwrapped created node', async () => {
    const created = makeNode({ id: 'created-node-id', name: 'created-node' });
    mockPost.mockResolvedValueOnce(envelope({ node: created }));

    const result = await nodesApi.createNode({ name: 'created-node' });

    expect(result.id).toBe('created-node-id');
    expect(result.name).toBe('created-node');
  });

  it('propagates API errors to the caller', async () => {
    mockPost.mockRejectedValueOnce(new Error('Validation error'));

    await expect(nodesApi.createNode({ name: '' })).rejects.toThrow('Validation error');
  });
});

// =============================================================================
// updateNode
// =============================================================================

describe('nodesApi.updateNode', () => {
  it('calls PUT /system/nodes/:id with the partial data wrapped in node key', async () => {
    const updated = makeNode({ id: 'node-a', name: 'updated-name' });
    mockPut.mockResolvedValueOnce(envelope({ node: updated }));

    const patch: Partial<NodeCreate> = { name: 'updated-name' };
    const result = await nodesApi.updateNode('node-a', patch);

    expect(mockPut).toHaveBeenCalledTimes(1);
    expect(mockPut).toHaveBeenCalledWith('/system/nodes/node-a', { node: patch });
    expect(result).toEqual(updated);
  });

  it('interpolates the id into the URL', async () => {
    const updated = makeNode({ id: 'target-uuid' });
    mockPut.mockResolvedValueOnce(envelope({ node: updated }));

    await nodesApi.updateNode('target-uuid', { description: 'Updated desc' });

    expect(mockPut).toHaveBeenCalledWith('/system/nodes/target-uuid', {
      node: { description: 'Updated desc' },
    });
  });

  it('accepts an empty patch object', async () => {
    const node = makeNode({ id: 'node-a' });
    mockPut.mockResolvedValueOnce(envelope({ node }));

    const result = await nodesApi.updateNode('node-a', {});

    expect(mockPut).toHaveBeenCalledWith('/system/nodes/node-a', { node: {} });
    expect(result).toEqual(node);
  });

  it('accepts enabled=false patch', async () => {
    const updated = makeNode({ id: 'node-b', enabled: false });
    mockPut.mockResolvedValueOnce(envelope({ node: updated }));

    await nodesApi.updateNode('node-b', { enabled: false });

    expect(mockPut).toHaveBeenCalledWith('/system/nodes/node-b', { node: { enabled: false } });
  });

  it('accepts config patch', async () => {
    const updated = makeNode({ id: 'node-a', config: { key: 'value' } });
    mockPut.mockResolvedValueOnce(envelope({ node: updated }));

    await nodesApi.updateNode('node-a', { config: { key: 'value' } });

    expect(mockPut).toHaveBeenCalledWith('/system/nodes/node-a', {
      node: { config: { key: 'value' } },
    });
  });

  it('returns the unwrapped updated node', async () => {
    const updated = makeNode({ id: 'node-a', name: 'patched', enabled: false });
    mockPut.mockResolvedValueOnce(envelope({ node: updated }));

    const result = await nodesApi.updateNode('node-a', { name: 'patched', enabled: false });

    expect(result.name).toBe('patched');
    expect(result.enabled).toBe(false);
  });

  it('propagates API errors to the caller', async () => {
    mockPut.mockRejectedValueOnce(new Error('Conflict'));

    await expect(nodesApi.updateNode('node-a', {})).rejects.toThrow('Conflict');
  });
});

// =============================================================================
// deleteNode
// =============================================================================

describe('nodesApi.deleteNode', () => {
  it('calls DELETE /system/nodes/:id', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await nodesApi.deleteNode('node-a');

    expect(mockDelete).toHaveBeenCalledTimes(1);
    expect(mockDelete).toHaveBeenCalledWith('/system/nodes/node-a');
  });

  it('interpolates arbitrary IDs into the delete URL', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await nodesApi.deleteNode('some-other-uuid');

    expect(mockDelete).toHaveBeenCalledWith('/system/nodes/some-other-uuid');
  });

  it('resolves to void (returns undefined)', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    const result = await nodesApi.deleteNode('node-a');

    expect(result).toBeUndefined();
  });

  it('propagates API errors to the caller', async () => {
    mockDelete.mockRejectedValueOnce(new Error('Forbidden'));

    await expect(nodesApi.deleteNode('node-a')).rejects.toThrow('Forbidden');
  });
});

// =============================================================================
// getNodeInstances
// =============================================================================

describe('nodesApi.getNodeInstances', () => {
  it('calls GET /system/nodes/:nodeId/node_instances and returns the instances', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_instances: [INST_A, INST_B] })
    );

    const result = await nodesApi.getNodeInstances('node-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/nodes/node-a/node_instances');
    expect(result.node_instances).toHaveLength(2);
    expect(result.node_instances[0]).toEqual(INST_A);
    expect(result.node_instances[1]).toEqual(INST_B);
  });

  it('interpolates the nodeId into the URL', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node_instances: [INST_B] }));

    await nodesApi.getNodeInstances('node-b');

    expect(mockGet).toHaveBeenCalledWith('/system/nodes/node-b/node_instances');
  });

  it('returns an empty array when node_instances is missing from the payload', async () => {
    mockGet.mockResolvedValueOnce(envelope({}));

    const result = await nodesApi.getNodeInstances('node-a');

    expect(result.node_instances).toEqual([]);
  });

  it('returns an empty array when node_instances is explicitly null', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node_instances: null }));

    const result = await nodesApi.getNodeInstances('node-a');

    expect(result.node_instances).toEqual([]);
  });

  it('returns an empty array when node_instances is an empty list', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node_instances: [] }));

    const result = await nodesApi.getNodeInstances('node-a');

    expect(result.node_instances).toEqual([]);
  });

  it('propagates API errors to the caller', async () => {
    mockGet.mockRejectedValueOnce(new Error('Node not found'));

    await expect(nodesApi.getNodeInstances('nonexistent')).rejects.toThrow('Node not found');
  });
});

// =============================================================================
// getNodeInstance
// =============================================================================

describe('nodesApi.getNodeInstance', () => {
  it('calls GET /system/nodes/:nodeId/node_instances/:instanceId and returns the instance', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node_instance: INST_A }));

    const result = await nodesApi.getNodeInstance('node-a', 'inst-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/nodes/node-a/node_instances/inst-a');
    expect(result).toEqual(INST_A);
  });

  it('interpolates both nodeId and instanceId into the URL', async () => {
    mockGet.mockResolvedValueOnce(envelope({ node_instance: INST_B }));

    await nodesApi.getNodeInstance('node-b', 'inst-b');

    expect(mockGet).toHaveBeenCalledWith('/system/nodes/node-b/node_instances/inst-b');
  });

  it('unwraps the node_instance field from the envelope', async () => {
    const inst = makeInstance({
      id: 'inst-xyz',
      node_id: 'node-a',
      name: 'custom-inst',
      variety: 'physical',
      status: 'stopped',
    });
    mockGet.mockResolvedValueOnce(envelope({ node_instance: inst }));

    const result = await nodesApi.getNodeInstance('node-a', 'inst-xyz');

    expect(result.id).toBe('inst-xyz');
    expect(result.variety).toBe('physical');
    expect(result.status).toBe('stopped');
  });

  it('propagates API errors to the caller', async () => {
    mockGet.mockRejectedValueOnce(new Error('Instance not found'));

    await expect(nodesApi.getNodeInstance('node-a', 'nonexistent')).rejects.toThrow('Instance not found');
  });
});

// =============================================================================
// createNodeInstance
// =============================================================================

describe('nodesApi.createNodeInstance', () => {
  it('calls POST /system/nodes/:nodeId/node_instances with node_instance wrapper', async () => {
    const payload: NodeInstanceCreate = { name: 'new-instance' };
    const created = makeInstance({ id: 'new-inst-id', name: 'new-instance', node_id: 'node-a' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: created }));

    const result = await nodesApi.createNodeInstance('node-a', payload);

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-a/node_instances', {
      node_instance: payload,
    });
    expect(result).toEqual(created);
  });

  it('wraps the full optional payload inside node_instance key', async () => {
    const payload: NodeInstanceCreate = {
      name: 'physical-node',
      description: 'A physical instance',
      variety: 'physical',
      status: 'pending',
      private_ip_address: '10.0.0.1',
      public_ip_address: '1.2.3.4',
      vpn_ip_address: '172.16.0.1',
      config: { rack: 'A1' },
    };
    const created = makeInstance({ id: 'phys-id', name: 'physical-node', node_id: 'node-a' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: created }));

    await nodesApi.createNodeInstance('node-a', payload);

    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-a/node_instances', {
      node_instance: payload,
    });
  });

  it('interpolates the nodeId into the POST URL', async () => {
    const payload: NodeInstanceCreate = { name: 'inst-for-b' };
    const created = makeInstance({ id: 'inst-id', node_id: 'node-b', name: 'inst-for-b' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: created }));

    await nodesApi.createNodeInstance('node-b', payload);

    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-b/node_instances', {
      node_instance: payload,
    });
  });

  it('returns the unwrapped created instance', async () => {
    const created = makeInstance({ id: 'created-inst', node_id: 'node-a', variety: 'dynamic' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: created }));

    const result = await nodesApi.createNodeInstance('node-a', { name: 'dynamic-inst', variety: 'dynamic' });

    expect(result.id).toBe('created-inst');
    expect(result.variety).toBe('dynamic');
  });

  it('propagates API errors to the caller', async () => {
    mockPost.mockRejectedValueOnce(new Error('Unprocessable'));

    await expect(nodesApi.createNodeInstance('node-a', { name: '' })).rejects.toThrow('Unprocessable');
  });
});

// =============================================================================
// updateNodeInstance
// =============================================================================

describe('nodesApi.updateNodeInstance', () => {
  it('calls PUT /system/nodes/:nodeId/node_instances/:instanceId with the patch', async () => {
    const updated = makeInstance({ id: 'inst-a', node_id: 'node-a', status: 'stopped' });
    mockPut.mockResolvedValueOnce(envelope({ node_instance: updated }));

    const patch: Partial<NodeInstanceCreate> = { status: 'stopped' };
    const result = await nodesApi.updateNodeInstance('node-a', 'inst-a', patch);

    expect(mockPut).toHaveBeenCalledTimes(1);
    expect(mockPut).toHaveBeenCalledWith('/system/nodes/node-a/node_instances/inst-a', {
      node_instance: patch,
    });
    expect(result).toEqual(updated);
  });

  it('interpolates both nodeId and instanceId into the URL', async () => {
    const updated = makeInstance({ id: 'inst-b', node_id: 'node-b' });
    mockPut.mockResolvedValueOnce(envelope({ node_instance: updated }));

    await nodesApi.updateNodeInstance('node-b', 'inst-b', { name: 'new-name' });

    expect(mockPut).toHaveBeenCalledWith('/system/nodes/node-b/node_instances/inst-b', {
      node_instance: { name: 'new-name' },
    });
  });

  it('accepts an empty patch object', async () => {
    const inst = makeInstance({ id: 'inst-a', node_id: 'node-a' });
    mockPut.mockResolvedValueOnce(envelope({ node_instance: inst }));

    const result = await nodesApi.updateNodeInstance('node-a', 'inst-a', {});

    expect(mockPut).toHaveBeenCalledWith('/system/nodes/node-a/node_instances/inst-a', {
      node_instance: {},
    });
    expect(result).toEqual(inst);
  });

  it('accepts variety patch for dynamic instances', async () => {
    const updated = makeInstance({ id: 'inst-a', node_id: 'node-a', variety: 'dynamic' });
    mockPut.mockResolvedValueOnce(envelope({ node_instance: updated }));

    await nodesApi.updateNodeInstance('node-a', 'inst-a', { variety: 'dynamic' });

    expect(mockPut).toHaveBeenCalledWith('/system/nodes/node-a/node_instances/inst-a', {
      node_instance: { variety: 'dynamic' },
    });
  });

  it('propagates API errors to the caller', async () => {
    mockPut.mockRejectedValueOnce(new Error('Not found'));

    await expect(
      nodesApi.updateNodeInstance('node-a', 'nonexistent', {})
    ).rejects.toThrow('Not found');
  });
});

// =============================================================================
// deleteNodeInstance
// =============================================================================

describe('nodesApi.deleteNodeInstance', () => {
  it('calls DELETE /system/nodes/:nodeId/node_instances/:instanceId', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await nodesApi.deleteNodeInstance('node-a', 'inst-a');

    expect(mockDelete).toHaveBeenCalledTimes(1);
    expect(mockDelete).toHaveBeenCalledWith('/system/nodes/node-a/node_instances/inst-a');
  });

  it('interpolates both nodeId and instanceId into the delete URL', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await nodesApi.deleteNodeInstance('node-b', 'inst-b');

    expect(mockDelete).toHaveBeenCalledWith('/system/nodes/node-b/node_instances/inst-b');
  });

  it('resolves to void (returns undefined)', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    const result = await nodesApi.deleteNodeInstance('node-a', 'inst-a');

    expect(result).toBeUndefined();
  });

  it('propagates API errors to the caller', async () => {
    mockDelete.mockRejectedValueOnce(new Error('Forbidden'));

    await expect(nodesApi.deleteNodeInstance('node-a', 'inst-a')).rejects.toThrow('Forbidden');
  });
});

// =============================================================================
// Instance lifecycle actions: startInstance, stopInstance, rebootInstance, terminateInstance
// =============================================================================

describe('nodesApi.startInstance', () => {
  it('calls POST /system/nodes/:nodeId/node_instances/:instanceId/start', async () => {
    const running = makeInstance({ id: 'inst-a', node_id: 'node-a', status: 'running' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: running }));

    const result = await nodesApi.startInstance('node-a', 'inst-a');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-a/node_instances/inst-a/start');
    expect(result).toEqual(running);
  });

  it('interpolates nodeId and instanceId into the start URL', async () => {
    const inst = makeInstance({ id: 'inst-b', node_id: 'node-b', status: 'running' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    await nodesApi.startInstance('node-b', 'inst-b');

    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-b/node_instances/inst-b/start');
  });

  it('returns the updated instance with running status', async () => {
    const inst = makeInstance({ id: 'inst-a', node_id: 'node-a', status: 'running' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    const result = await nodesApi.startInstance('node-a', 'inst-a');

    expect(result.status).toBe('running');
  });

  it('propagates API errors to the caller', async () => {
    mockPost.mockRejectedValueOnce(new Error('Instance already running'));

    await expect(nodesApi.startInstance('node-a', 'inst-a')).rejects.toThrow('Instance already running');
  });
});

describe('nodesApi.stopInstance', () => {
  it('calls POST /system/nodes/:nodeId/node_instances/:instanceId/stop', async () => {
    const stopped = makeInstance({ id: 'inst-a', node_id: 'node-a', status: 'stopped' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: stopped }));

    const result = await nodesApi.stopInstance('node-a', 'inst-a');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-a/node_instances/inst-a/stop');
    expect(result.status).toBe('stopped');
  });

  it('interpolates nodeId and instanceId into the stop URL', async () => {
    const inst = makeInstance({ id: 'inst-b', node_id: 'node-b', status: 'stopped' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    await nodesApi.stopInstance('node-b', 'inst-b');

    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-b/node_instances/inst-b/stop');
  });

  it('propagates API errors to the caller', async () => {
    mockPost.mockRejectedValueOnce(new Error('Cannot stop'));

    await expect(nodesApi.stopInstance('node-a', 'inst-a')).rejects.toThrow('Cannot stop');
  });
});

describe('nodesApi.rebootInstance', () => {
  it('calls POST /system/nodes/:nodeId/node_instances/:instanceId/reboot', async () => {
    const inst = makeInstance({ id: 'inst-a', node_id: 'node-a', status: 'rebooting' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    const result = await nodesApi.rebootInstance('node-a', 'inst-a');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-a/node_instances/inst-a/reboot');
    expect(result.status).toBe('rebooting');
  });

  it('interpolates nodeId and instanceId into the reboot URL', async () => {
    const inst = makeInstance({ id: 'inst-b', node_id: 'node-b', status: 'rebooting' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    await nodesApi.rebootInstance('node-b', 'inst-b');

    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-b/node_instances/inst-b/reboot');
  });

  it('propagates API errors to the caller', async () => {
    mockPost.mockRejectedValueOnce(new Error('Reboot not supported'));

    await expect(nodesApi.rebootInstance('node-a', 'inst-a')).rejects.toThrow('Reboot not supported');
  });
});

describe('nodesApi.terminateInstance', () => {
  it('calls POST /system/nodes/:nodeId/node_instances/:instanceId/terminate', async () => {
    const inst = makeInstance({ id: 'inst-a', node_id: 'node-a', status: 'terminating' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    const result = await nodesApi.terminateInstance('node-a', 'inst-a');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-a/node_instances/inst-a/terminate');
    expect(result.status).toBe('terminating');
  });

  it('interpolates nodeId and instanceId into the terminate URL', async () => {
    const inst = makeInstance({ id: 'inst-b', node_id: 'node-b', status: 'terminating' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    await nodesApi.terminateInstance('node-b', 'inst-b');

    expect(mockPost).toHaveBeenCalledWith('/system/nodes/node-b/node_instances/inst-b/terminate');
  });

  it('propagates API errors to the caller', async () => {
    mockPost.mockRejectedValueOnce(new Error('Already terminated'));

    await expect(nodesApi.terminateInstance('node-a', 'inst-a')).rejects.toThrow('Already terminated');
  });
});

// =============================================================================
// IP association actions: associatePublicIp, disassociatePublicIp
// =============================================================================

describe('nodesApi.associatePublicIp', () => {
  it('calls POST /system/nodes/:nodeId/node_instances/:instanceId/associate_public_ip', async () => {
    const inst = makeInstance({
      id: 'inst-a',
      node_id: 'node-a',
      public_ip_address: '203.0.113.1',
    });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    const result = await nodesApi.associatePublicIp('node-a', 'inst-a');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/nodes/node-a/node_instances/inst-a/associate_public_ip'
    );
    expect(result.public_ip_address).toBe('203.0.113.1');
  });

  it('interpolates nodeId and instanceId into the associate_public_ip URL', async () => {
    const inst = makeInstance({ id: 'inst-b', node_id: 'node-b', public_ip_address: '1.2.3.4' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    await nodesApi.associatePublicIp('node-b', 'inst-b');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/nodes/node-b/node_instances/inst-b/associate_public_ip'
    );
  });

  it('propagates API errors to the caller', async () => {
    mockPost.mockRejectedValueOnce(new Error('No IPs available'));

    await expect(nodesApi.associatePublicIp('node-a', 'inst-a')).rejects.toThrow('No IPs available');
  });
});

describe('nodesApi.disassociatePublicIp', () => {
  it('calls POST /system/nodes/:nodeId/node_instances/:instanceId/disassociate_public_ip', async () => {
    const inst = makeInstance({
      id: 'inst-a',
      node_id: 'node-a',
      public_ip_address: undefined,
    });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    const result = await nodesApi.disassociatePublicIp('node-a', 'inst-a');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/nodes/node-a/node_instances/inst-a/disassociate_public_ip'
    );
    expect(result.public_ip_address).toBeUndefined();
  });

  it('interpolates nodeId and instanceId into the disassociate_public_ip URL', async () => {
    const inst = makeInstance({ id: 'inst-b', node_id: 'node-b' });
    mockPost.mockResolvedValueOnce(envelope({ node_instance: inst }));

    await nodesApi.disassociatePublicIp('node-b', 'inst-b');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/nodes/node-b/node_instances/inst-b/disassociate_public_ip'
    );
  });

  it('propagates API errors to the caller', async () => {
    mockPost.mockRejectedValueOnce(new Error('Instance has no public IP'));

    await expect(nodesApi.disassociatePublicIp('node-a', 'inst-a')).rejects.toThrow(
      'Instance has no public IP'
    );
  });
});

// =============================================================================
// downloadInstanceBootConfig
// =============================================================================

describe('nodesApi.downloadInstanceBootConfig', () => {
  let appendChildSpy: jest.SpyInstance;
  let removeChildSpy: jest.SpyInstance;
  let clickSpy: jest.Mock;
  let createObjectURLMock: jest.Mock;
  let revokeObjectURLMock: jest.Mock;
  let createElementSpy: jest.SpyInstance;
  let mockAnchor: { href: string; download: string; click: jest.Mock };

  beforeEach(() => {
    clickSpy = jest.fn();
    mockAnchor = { href: '', download: '', click: clickSpy };

    // Stub document.createElement to return a mock anchor for 'a' tags
    createElementSpy = jest.spyOn(document, 'createElement').mockImplementation((tag: string) => {
      if (tag === 'a') {
        return mockAnchor as unknown as HTMLElement;
      }
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return (document.createElement as any).__proto__.call(document, tag);
    });

    appendChildSpy = jest.spyOn(document.body, 'appendChild').mockImplementation((node) => node);
    removeChildSpy = jest.spyOn(document.body, 'removeChild').mockImplementation((node) => node);

    // jsdom doesn't implement URL.createObjectURL — assign mocks to global.URL directly
    createObjectURLMock = jest.fn().mockReturnValue('blob:http://localhost/mock-object-url');
    revokeObjectURLMock = jest.fn();
    global.URL.createObjectURL = createObjectURLMock;
    global.URL.revokeObjectURL = revokeObjectURLMock;
  });

  afterEach(() => {
    createElementSpy.mockRestore();
    appendChildSpy.mockRestore();
    removeChildSpy.mockRestore();
    // Restore URL methods (delete our test assignments)
    delete (global.URL as { createObjectURL?: unknown }).createObjectURL;
    delete (global.URL as { revokeObjectURL?: unknown }).revokeObjectURL;
  });

  it('calls GET /system/nodes/:nodeId/node_instances/:instanceId/boot_config with responseType blob', async () => {
    const blob = new Blob(['config content'], { type: 'text/plain' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: { 'content-disposition': 'attachment; filename="identity-inst-a.cfg"' },
    });

    await nodesApi.downloadInstanceBootConfig('node-a', 'inst-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith(
      '/system/nodes/node-a/node_instances/inst-a/boot_config',
      { responseType: 'blob' }
    );
  });

  it('interpolates nodeId and instanceId into the boot_config URL', async () => {
    const blob = new Blob(['cfg'], { type: 'text/plain' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: { 'content-disposition': 'attachment; filename="identity-inst-b.cfg"' },
    });

    await nodesApi.downloadInstanceBootConfig('node-b', 'inst-b');

    expect(mockGet).toHaveBeenCalledWith(
      '/system/nodes/node-b/node_instances/inst-b/boot_config',
      { responseType: 'blob' }
    );
  });

  it('extracts filename from Content-Disposition header and sets it as download attribute', async () => {
    const blob = new Blob(['config'], { type: 'text/plain' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: { 'content-disposition': 'attachment; filename="custom-name.cfg"' },
    });

    await nodesApi.downloadInstanceBootConfig('node-a', 'inst-a');

    expect(mockAnchor.download).toBe('custom-name.cfg');
  });

  it('falls back to identity-<instanceId>.cfg when Content-Disposition header is absent', async () => {
    const blob = new Blob(['config'], { type: 'text/plain' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: {},
    });

    await nodesApi.downloadInstanceBootConfig('node-a', 'inst-fallback');

    expect(mockAnchor.download).toBe('identity-inst-fallback.cfg');
  });

  it('falls back when Content-Disposition has no filename match', async () => {
    const blob = new Blob(['config'], { type: 'text/plain' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: { 'content-disposition': 'attachment' },
    });

    await nodesApi.downloadInstanceBootConfig('node-a', 'inst-nofname');

    expect(mockAnchor.download).toBe('identity-inst-nofname.cfg');
  });

  it('creates an object URL, clicks the link, appends+removes the anchor, and revokes the URL', async () => {
    const blob = new Blob(['config'], { type: 'text/plain' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: { 'content-disposition': 'attachment; filename="identity-inst-a.cfg"' },
    });

    await nodesApi.downloadInstanceBootConfig('node-a', 'inst-a');

    expect(createObjectURLMock).toHaveBeenCalledTimes(1);
    expect(clickSpy).toHaveBeenCalledTimes(1);
    expect(appendChildSpy).toHaveBeenCalledTimes(1);
    expect(removeChildSpy).toHaveBeenCalledTimes(1);
    expect(revokeObjectURLMock).toHaveBeenCalledWith('blob:http://localhost/mock-object-url');
  });

  it('wraps non-Blob response data in a Blob before creating the object URL', async () => {
    // Backend returns a string instead of a Blob (happens in some test environments)
    mockGet.mockResolvedValueOnce({
      data: 'raw config text',
      headers: { 'content-disposition': 'attachment; filename="identity-inst-a.cfg"' },
    });

    await nodesApi.downloadInstanceBootConfig('node-a', 'inst-a');

    // createObjectURL should still be called (with a Blob wrapping the string)
    expect(createObjectURLMock).toHaveBeenCalledTimes(1);
    const blobArg = createObjectURLMock.mock.calls[0][0] as Blob;
    expect(blobArg).toBeInstanceOf(Blob);
    expect(blobArg.type).toBe('text/plain');
  });

  it('resolves to void on success', async () => {
    const blob = new Blob(['config'], { type: 'text/plain' });
    mockGet.mockResolvedValueOnce({
      data: blob,
      headers: { 'content-disposition': 'attachment; filename="identity-inst-a.cfg"' },
    });

    const result = await nodesApi.downloadInstanceBootConfig('node-a', 'inst-a');

    expect(result).toBeUndefined();
  });

  it('propagates API errors to the caller', async () => {
    mockGet.mockRejectedValueOnce(new Error('409 Conflict — device already claimed'));

    await expect(
      nodesApi.downloadInstanceBootConfig('node-a', 'inst-a')
    ).rejects.toThrow('409 Conflict — device already claimed');
  });
});
