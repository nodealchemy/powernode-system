import type { AxiosResponse } from 'axios';
import { extractData, extractPaginated, defaultMeta } from './helpers';
import type { PaginationMeta } from './types';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Build a minimal AxiosResponse-shaped object with a given body. */
function axiosResp<T>(body: T): AxiosResponse<T> {
  return {
    data: body,
    status: 200,
    statusText: 'OK',
    headers: {},
    config: {} as AxiosResponse['config'],
  };
}

// ---------------------------------------------------------------------------
// defaultMeta
// ---------------------------------------------------------------------------

describe('defaultMeta', () => {
  it('returns a PaginationMeta with count items on page 1', () => {
    const meta = defaultMeta(7);
    expect(meta).toEqual<PaginationMeta>({
      current_page: 1,
      per_page: 7,
      total_count: 7,
      total_pages: 1,
      next_page: null,
      prev_page: null,
    });
  });

  it('returns per_page = 0 and total_count = 0 when count is 0', () => {
    const meta = defaultMeta(0);
    expect(meta.total_count).toBe(0);
    expect(meta.per_page).toBe(0);
    expect(meta.total_pages).toBe(1);
    expect(meta.current_page).toBe(1);
    expect(meta.next_page).toBeNull();
    expect(meta.prev_page).toBeNull();
  });

  it('always sets total_pages to 1 regardless of count', () => {
    expect(defaultMeta(1000).total_pages).toBe(1);
    expect(defaultMeta(1).total_pages).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// extractData
// ---------------------------------------------------------------------------

describe('extractData', () => {
  it('unwraps the nested data payload from a double-envelope response', () => {
    interface NodePayload { nodes: string[] }
    const payload: NodePayload = { nodes: ['node-1', 'node-2'] };
    const resp = axiosResp({ success: true, data: payload });

    const result = extractData<NodePayload>(resp);
    expect(result).toEqual({ nodes: ['node-1', 'node-2'] });
  });

  it('returns the body itself when there is no nested data key (bare response)', () => {
    interface BarePayload { id: string; name: string }
    const payload: BarePayload = { id: 'abc', name: 'test' };
    const resp = axiosResp<BarePayload>(payload);

    const result = extractData<BarePayload>(resp);
    expect(result).toEqual({ id: 'abc', name: 'test' });
  });

  it('prefers data over the body fields when data is explicitly set', () => {
    // Envelope has both a top-level field and an inner data payload.
    const inner = { message: 'from inner' };
    const resp = axiosResp({ message: 'from outer', data: inner });

    const result = extractData<{ message: string }>(resp);
    expect(result.message).toBe('from inner');
  });

  it('unwraps data even when success flag is absent', () => {
    const resp = axiosResp({ data: { count: 42 } });
    const result = extractData<{ count: number }>(resp);
    expect(result.count).toBe(42);
  });

  it('handles a single resource record envelope', () => {
    interface Node { id: string; status: string }
    const node: Node = { id: 'n-1', status: 'ready' };
    const resp = axiosResp({ success: true, data: { node } });

    const result = extractData<{ node: Node }>(resp);
    expect(result.node).toEqual(node);
  });
});

// ---------------------------------------------------------------------------
// extractPaginated
// ---------------------------------------------------------------------------

const META: PaginationMeta = {
  current_page: 2,
  per_page: 10,
  total_count: 25,
  total_pages: 3,
  next_page: 3,
  prev_page: 1,
};

describe('extractPaginated', () => {
  it('merges the data payload with the response-root meta', () => {
    const nodes = [{ id: 'n-1' }, { id: 'n-2' }];
    const resp = axiosResp({
      success: true,
      data: { nodes },
      meta: META,
    });

    const result = extractPaginated<{ nodes: { id: string }[] }>(resp);
    expect(result.nodes).toEqual(nodes);
    expect(result.meta).toEqual(META);
  });

  it('synthesizes a defaultMeta when the backend omits meta (non-paginated list)', () => {
    const items = [{ id: 'a' }, { id: 'b' }, { id: 'c' }];
    const resp = axiosResp({ success: true, data: { items } });

    const result = extractPaginated<{ items: { id: string }[] }>(resp);
    expect(result.items).toEqual(items);
    expect(result.meta.total_count).toBe(3);
    expect(result.meta.total_pages).toBe(1);
    expect(result.meta.current_page).toBe(1);
    expect(result.meta.per_page).toBe(3);
    expect(result.meta.next_page).toBeNull();
    expect(result.meta.prev_page).toBeNull();
  });

  it('counts items across multiple array fields when synthesizing meta', () => {
    const resp = axiosResp({
      success: true,
      data: { nodes: ['n-1', 'n-2'], pools: ['p-1'] },
    });

    const result = extractPaginated<{ nodes: string[]; pools: string[] }>(resp);
    // 2 nodes + 1 pool = 3 total items
    expect(result.meta.total_count).toBe(3);
    expect(result.meta.per_page).toBe(3);
  });

  it('does NOT count non-array fields when synthesizing meta', () => {
    const resp = axiosResp({
      success: true,
      data: { nodes: ['n-1'], count: 99, label: 'test' },
    });

    const result = extractPaginated<{ nodes: string[]; count: number; label: string }>(resp);
    // Only the array field (nodes with 1 item) is counted
    expect(result.meta.total_count).toBe(1);
  });

  it('yields an empty data payload and zero-item meta when data is missing', () => {
    const resp = axiosResp({ success: true } as { success: boolean; data?: Record<string, unknown>; meta?: PaginationMeta });

    const result = extractPaginated<Record<string, unknown>>(resp);
    expect(result.meta.total_count).toBe(0);
    expect(result.meta.total_pages).toBe(1);
  });

  it('does not pollute the data payload with a nested meta key', () => {
    const resp = axiosResp({
      success: true,
      data: { nodes: [{ id: 'n-1' }] },
      meta: META,
    });

    const result = extractPaginated<{ nodes: { id: string }[] }>(resp);
    // meta must be the response-root meta, not an artifact inside nodes
    expect(result.meta).toBe(result.meta); // trivially true — but below checks the shape
    expect(result.meta.total_pages).toBe(META.total_pages);
    // The nodes array must not contain a meta property
    expect(Object.prototype.hasOwnProperty.call(result.nodes[0], 'meta')).toBe(false);
  });

  it('prefers the explicit backend meta over the synthesized meta', () => {
    // Even a one-item list should use the real meta when provided
    const resp = axiosResp({
      success: true,
      data: { nodes: [{ id: 'n-1' }] },
      meta: {
        current_page: 5,
        per_page: 1,
        total_count: 100,
        total_pages: 100,
        next_page: 6,
        prev_page: 4,
      },
    });

    const result = extractPaginated<{ nodes: { id: string }[] }>(resp);
    expect(result.meta.total_count).toBe(100);
    expect(result.meta.total_pages).toBe(100);
    expect(result.meta.next_page).toBe(6);
    expect(result.meta.prev_page).toBe(4);
  });

  it('passes through zero-item arrays with a synthesized meta of count=0', () => {
    const resp = axiosResp({ success: true, data: { nodes: [] as string[] } });

    const result = extractPaginated<{ nodes: string[] }>(resp);
    expect(result.nodes).toEqual([]);
    expect(result.meta.total_count).toBe(0);
    expect(result.meta.per_page).toBe(0);
    expect(result.meta.total_pages).toBe(1);
  });
});
