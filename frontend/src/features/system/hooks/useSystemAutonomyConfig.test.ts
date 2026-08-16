/**
 * Behavioral tests for useSystemAutonomyConfig hook and
 * systemAutonomyConfigSource configuration object.
 *
 * useSystemAutonomyConfig is a thin wrapper around the shared
 * useAutonomyConfig hook, wired to the /system/autonomy endpoints.
 * Tests cover:
 *
 * 1. systemAutonomyConfigSource — endpoints
 * 2. Hook fetch success (system-API array shape)
 * 3. Hook fetch error — loading clears, state stays empty
 * 4. Local override tracking (isDirty, getPolicy)
 * 5. save() — PATCHes the updates array, each entry carrying its row's identity
 * 6. save() with no overrides — does NOT make any API call
 * 7. reload() — re-fetches and resets overrides
 *
 * The source used to carry a `roleForAgent` name→role mapping, sent as
 * `agent_role` beside a `policies` object. No server code ever read either key
 * and the endpoint 400s without `updates`, so the whole modal's save was a
 * no-op; the examples that pinned the mapping are gone with it
 * (IMP-bef43160636f).
 */

import { renderHook, act, waitFor } from '@testing-library/react';
import {
  useSystemAutonomyConfig,
  systemAutonomyConfigSource,
} from './useSystemAutonomyConfig';

// ---------------------------------------------------------------------------
// API client mock — the shared useAutonomyConfig hook imports apiClient as a
// default export. We mock the entire module with __esModule: true so that
// `import apiClient from '...'` receives the stubbed object.
// ---------------------------------------------------------------------------

const mockGet = jest.fn();
const mockPatch = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  __esModule: true,
  default: {
    get: (...args: unknown[]) => mockGet(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
  },
}));

// ---------------------------------------------------------------------------
// Logger mock — suppress logger.error noise in test output
// ---------------------------------------------------------------------------
jest.mock('@/shared/utils/logger', () => ({
  logger: {
    error: jest.fn(),
    warn: jest.fn(),
    info: jest.fn(),
    debug: jest.fn(),
  },
}));

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Wraps a payload in the double-envelope used by the system API */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

type SeedRow = {
  action_category: string;
  policy: string;
  scope?: string;
  agent_id?: string | null;
};

/** The agent_id these fixtures give a by_agent bucket, derived from its name. */
function agentIdFor(agentName: string): string {
  return `agent-${agentName.toLowerCase().replace(/\s+/g, '-')}`;
}

/**
 * Build a mock GET response in the system API shape.
 *
 * `System::AutonomyActions#serialize_policy` ships EVERY row with its `scope`
 * and `agent_id`, and a by_agent bucket named after an agent is by construction
 * that agent's scope-"agent" rows. Fixtures default to that shape rather than
 * the bare { action_category, policy } pair, because save() now writes a row's
 * identity back and a fixture thinner than the real payload cannot see whether
 * it did.
 */
function systemPoliciesResponse(byAgent: Record<string, SeedRow[]>) {
  const identified = Object.fromEntries(
    Object.entries(byAgent).map(([agentName, rows]) => [
      agentName,
      rows.map((row) => ({ scope: 'agent', agent_id: agentIdFor(agentName), ...row })),
    ]),
  );

  return envelope({ policies: { by_agent: identified } });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('systemAutonomyConfigSource', () => {
  describe('endpoints', () => {
    it('uses /system/autonomy as the fetch endpoint', () => {
      expect(systemAutonomyConfigSource.fetchEndpoint).toBe('/system/autonomy');
    });

    it('uses /system/autonomy as the update endpoint', () => {
      expect(systemAutonomyConfigSource.updateEndpoint).toBe('/system/autonomy');
    });
  });

});

describe('useSystemAutonomyConfig', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPatch.mockReset();
  });

  // -------------------------------------------------------------------------
  // Fetch success
  // -------------------------------------------------------------------------

  it('fetches from /system/autonomy and exposes per-agent policies (system array shape)', async () => {
    mockGet.mockResolvedValue(
      systemPoliciesResponse({
        'Fleet Autonomy': [
          { action_category: 'system.node_enroll', policy: 'notify_and_proceed' },
          { action_category: 'system.cert_rotate', policy: 'auto_approve' },
        ],
        'CVE Responder': [
          { action_category: 'system.cve_patch', policy: 'require_approval' },
        ],
      }),
    );

    const { result } = renderHook(() => useSystemAutonomyConfig());

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(mockGet).toHaveBeenCalledWith('/system/autonomy');
    expect(result.current.agentNames).toEqual(
      expect.arrayContaining(['Fleet Autonomy', 'CVE Responder']),
    );
    expect(result.current.getPolicy('Fleet Autonomy', 'system.node_enroll')).toBe(
      'notify_and_proceed',
    );
    expect(result.current.getPolicy('Fleet Autonomy', 'system.cert_rotate')).toBe('auto_approve');
    expect(result.current.getPolicy('CVE Responder', 'system.cve_patch')).toBe('require_approval');
  });

  it('starts in loading state and resolves to not-loading after fetch', async () => {
    let resolveGet!: (v: unknown) => void;
    mockGet.mockReturnValue(new Promise((res) => { resolveGet = res; }));

    const { result } = renderHook(() => useSystemAutonomyConfig());

    expect(result.current.loading).toBe(true);

    act(() => {
      resolveGet(
        systemPoliciesResponse({ 'SDWAN Manager': [{ action_category: 's.x', policy: 'auto_approve' }] }),
      );
    });

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.agentNames).toContain('SDWAN Manager');
  });

  it('defaults unknown action policies to "require_approval"', async () => {
    mockGet.mockResolvedValue(
      systemPoliciesResponse({
        'Runtime Manager': [{ action_category: 'system.docker_provision', policy: 'auto_approve' }],
      }),
    );

    const { result } = renderHook(() => useSystemAutonomyConfig());
    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.getPolicy('Runtime Manager', 'system.nonexistent_action')).toBe(
      'require_approval',
    );
  });

  it('defaults unknown agent to "require_approval"', async () => {
    mockGet.mockResolvedValue(systemPoliciesResponse({}));

    const { result } = renderHook(() => useSystemAutonomyConfig());
    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.getPolicy('Ghost Agent', 'system.any_action')).toBe('require_approval');
  });

  // -------------------------------------------------------------------------
  // Fetch error
  // -------------------------------------------------------------------------

  it('clears loading on fetch error and leaves policies empty', async () => {
    mockGet.mockRejectedValue(new Error('Network error'));

    const { result } = renderHook(() => useSystemAutonomyConfig());

    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.agentNames).toHaveLength(0);
    expect(result.current.isDirty).toBe(false);
  });

  // -------------------------------------------------------------------------
  // Local overrides / isDirty
  // -------------------------------------------------------------------------

  it('isDirty is false initially', async () => {
    mockGet.mockResolvedValue(systemPoliciesResponse({}));

    const { result } = renderHook(() => useSystemAutonomyConfig());
    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.isDirty).toBe(false);
  });

  it('local override wins over fetched policy and marks isDirty', async () => {
    mockGet.mockResolvedValue(
      systemPoliciesResponse({
        'Fleet Autonomy': [
          { action_category: 'system.node_enroll', policy: 'auto_approve' },
        ],
      }),
    );

    const { result } = renderHook(() => useSystemAutonomyConfig());
    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.updatePolicy('Fleet Autonomy', 'system.node_enroll', 'block');
    });

    expect(result.current.getPolicy('Fleet Autonomy', 'system.node_enroll')).toBe('block');
    expect(result.current.isDirty).toBe(true);
  });

  it('can override multiple agents independently', async () => {
    mockGet.mockResolvedValue(
      systemPoliciesResponse({
        'Fleet Autonomy': [{ action_category: 'system.node_enroll', policy: 'auto_approve' }],
        'CVE Responder': [{ action_category: 'system.cve_patch', policy: 'notify_and_proceed' }],
      }),
    );

    const { result } = renderHook(() => useSystemAutonomyConfig());
    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.updatePolicy('Fleet Autonomy', 'system.node_enroll', 'require_approval');
      result.current.updatePolicy('CVE Responder', 'system.cve_patch', 'block');
    });

    expect(result.current.getPolicy('Fleet Autonomy', 'system.node_enroll')).toBe('require_approval');
    expect(result.current.getPolicy('CVE Responder', 'system.cve_patch')).toBe('block');
    expect(result.current.isDirty).toBe(true);
  });

  // -------------------------------------------------------------------------
  // save()
  // -------------------------------------------------------------------------

  it('save() PATCHes /system/autonomy with an updates array carrying the row identity', async () => {
    mockGet.mockResolvedValue(
      systemPoliciesResponse({
        'Fleet Autonomy': [
          { action_category: 'system.node_enroll', policy: 'auto_approve' },
        ],
      }),
    );
    mockPatch.mockResolvedValue({ data: { success: true } });

    const { result } = renderHook(() => useSystemAutonomyConfig());
    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.updatePolicy('Fleet Autonomy', 'system.node_enroll', 'require_approval');
    });

    await act(async () => {
      await result.current.save();
    });

    expect(mockPatch).toHaveBeenCalledWith('/system/autonomy', {
      updates: [
        {
          action_category: 'system.node_enroll',
          policy: 'require_approval',
          scope: 'agent',
          agent_id: agentIdFor('Fleet Autonomy'),
        },
      ],
    });
  });

  it('save() clears isDirty and commits overrides into fetched policies', async () => {
    mockGet.mockResolvedValue(
      systemPoliciesResponse({
        'SDWAN Manager': [{ action_category: 'system.sdwan_peer', policy: 'notify_and_proceed' }],
      }),
    );
    mockPatch.mockResolvedValue({ data: { success: true } });

    const { result } = renderHook(() => useSystemAutonomyConfig());
    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      result.current.updatePolicy('SDWAN Manager', 'system.sdwan_peer', 'block');
    });

    await act(async () => {
      await result.current.save();
    });

    expect(result.current.isDirty).toBe(false);
    // The committed value should now be returned (not the original fetched value)
    expect(result.current.getPolicy('SDWAN Manager', 'system.sdwan_peer')).toBe('block');
  });

  // Each of the 5 system agents keeps its OWN agent_id through the save. The
  // replaced version asserted a coarse role string per agent — which is exactly
  // what could not identify a row, since several agents map onto one role and
  // no row can be recovered from one.
  it('save() sends every agent in one request, each entry keeping its own agent_id', async () => {
    const agents = [
      { name: 'Fleet Autonomy', action: 'system.a' },
      { name: 'SDWAN Manager', action: 'system.b' },
      { name: 'CVE Responder', action: 'system.c' },
      { name: 'Disk Image Manager', action: 'system.d' },
      { name: 'Runtime Manager', action: 'system.e' },
    ];

    const byAgent = Object.fromEntries(
      agents.map(({ name, action }) => [name, [{ action_category: action, policy: 'auto_approve' }]]),
    );

    mockGet.mockResolvedValue(systemPoliciesResponse(byAgent));
    mockPatch.mockResolvedValue({ data: { success: true } });

    const { result } = renderHook(() => useSystemAutonomyConfig());
    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => {
      agents.forEach(({ name, action }) => {
        result.current.updatePolicy(name, action, 'block');
      });
    });

    await act(async () => {
      await result.current.save();
    });

    expect(mockPatch).toHaveBeenCalledTimes(1);
    expect(mockPatch).toHaveBeenCalledWith('/system/autonomy', {
      updates: agents.map(({ name, action }) => ({
        action_category: action,
        policy: 'block',
        scope: 'agent',
        agent_id: agentIdFor(name),
      })),
    });
  });

  it('save() with no overrides does not call PATCH', async () => {
    mockGet.mockResolvedValue(
      systemPoliciesResponse({
        'Fleet Autonomy': [{ action_category: 'system.node_enroll', policy: 'auto_approve' }],
      }),
    );

    const { result } = renderHook(() => useSystemAutonomyConfig());
    await waitFor(() => expect(result.current.loading).toBe(false));

    await act(async () => {
      await result.current.save();
    });

    expect(mockPatch).not.toHaveBeenCalled();
  });

  // -------------------------------------------------------------------------
  // reload()
  // -------------------------------------------------------------------------

  it('reload() re-fetches policies and resets local overrides', async () => {
    const firstResponse = systemPoliciesResponse({
      'Fleet Autonomy': [{ action_category: 'system.node_enroll', policy: 'auto_approve' }],
    });
    const secondResponse = systemPoliciesResponse({
      'Fleet Autonomy': [{ action_category: 'system.node_enroll', policy: 'require_approval' }],
    });

    mockGet.mockResolvedValueOnce(firstResponse).mockResolvedValueOnce(secondResponse);

    const { result } = renderHook(() => useSystemAutonomyConfig());
    await waitFor(() => expect(result.current.loading).toBe(false));

    // Apply a local override
    act(() => {
      result.current.updatePolicy('Fleet Autonomy', 'system.node_enroll', 'block');
    });
    expect(result.current.isDirty).toBe(true);

    // Reload — should discard override and fetch fresh data
    await act(async () => {
      result.current.reload();
    });
    await waitFor(() => expect(result.current.loading).toBe(false));

    expect(result.current.isDirty).toBe(false);
    expect(result.current.getPolicy('Fleet Autonomy', 'system.node_enroll')).toBe('require_approval');
    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(mockGet).toHaveBeenNthCalledWith(1, '/system/autonomy');
    expect(mockGet).toHaveBeenNthCalledWith(2, '/system/autonomy');
  });
});
