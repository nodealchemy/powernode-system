import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { MigrationChainsPanel } from './MigrationChainsPanel';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

let mockPermissionGranted = (_perm: string) => true;
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (perm: string) => mockPermissionGranted(perm),
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// =============================================================================
// Fixtures & helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

/**
 * What axios ACTUALLY rejects with: a generic `.message` plus the server's own
 * sentence in response.data.error. The chain executor's refusals are the only
 * explanation the operator gets, so the specs reject in this shape rather than
 * with a bare Error, which would pass whether or not the body is read.
 */
function axiosError(serverMessage: string, status = 422) {
  return Object.assign(new Error(`Request failed with status code ${status}`), {
    response: { status, data: { error: serverMessage } },
  });
}

const CHAIN_IN_FLIGHT = {
  id: 'chain-0001',
  operation: 'migrate' as const,
  status: 'in_flight' as const,
  root_resource_kind: 'Skill',
  root_resource_id: 'aaaabbbb-1111-2222-3333-444444444444',
  current_hop_index: 1,
  total_hops: 3,
  terminal: false,
  error_message: null,
  created_at: '2026-05-01T10:00:00Z',
  started_at: '2026-05-01T10:01:00Z',
  completed_at: null,
  failed_at: null,
};

const CHAIN_COMPLETED = {
  ...CHAIN_IN_FLIGHT,
  id: 'chain-0002',
  status: 'completed' as const,
  current_hop_index: 3,
  terminal: true,
  completed_at: '2026-05-01T11:00:00Z',
};

/**
 * A REAL chain shape, matching ChainComposer: N peers give N-1 hops, the first
 * peer is the implicit origin (serialized null), and hop at chain_position P
 * carries destination hop_peer_ids[P + 1]. The earlier fixture here had 3 peers
 * AND 3 hops, which the composer cannot produce — and it made a wrong hop-to-
 * peer mapping look correct.
 *
 * self → peer-b → peer-c → peer-d : 4 peers, 3 hops, positions 0..2.
 */
const CHAIN_DETAIL = {
  ...CHAIN_IN_FLIGHT,
  hop_peer_ids: [null, 'peer-b', 'peer-c', 'peer-d'],
  hops: [
    {
      id: 'hop-0',
      chain_position: 0,
      status: 'completed' as const,
      destination_peer_id: 'peer-b',
      started_at: '2026-05-01T10:01:00Z',
      completed_at: '2026-05-01T10:02:00Z',
      failed_at: null,
      error_message: null,
    },
    {
      id: 'hop-1',
      chain_position: 1,
      status: 'transferring' as const,
      destination_peer_id: 'peer-c',
      started_at: '2026-05-01T10:02:00Z',
      completed_at: null,
      failed_at: null,
      error_message: null,
    },
    {
      id: 'hop-2',
      chain_position: 2,
      status: 'planned' as const,
      destination_peer_id: 'peer-d',
      started_at: null,
      completed_at: null,
      failed_at: null,
      error_message: null,
    },
  ],
  audit_log: [
    { at: '2026-05-01T10:01:00Z', event: 'chain_started', message: 'Chain started' },
  ],
  metadata: {},
  initiated_by_user_id: 'user-1',
};

/** planned: nothing applied yet, and the one state cancel is legal from. */
const CHAIN_PLANNED = {
  ...CHAIN_IN_FLIGHT,
  id: 'chain-0004',
  status: 'planned' as const,
  current_hop_index: 0,
  started_at: null,
};

const CHAIN_DETAIL_PLANNED = {
  ...CHAIN_PLANNED,
  hop_peer_ids: CHAIN_DETAIL.hop_peer_ids,
  hops: CHAIN_DETAIL.hops.map((h) => ({ ...h, status: 'planned' as const })),
  audit_log: [],
  metadata: {},
  initiated_by_user_id: 'user-1',
};

const CHAIN_DETAIL_COMPLETED = {
  ...CHAIN_COMPLETED,
  hop_peer_ids: CHAIN_DETAIL.hop_peer_ids,
  hops: CHAIN_DETAIL.hops.map((h) => ({ ...h, status: 'completed' as const })),
  audit_log: [],
  metadata: {},
  initiated_by_user_id: 'user-1',
};

const renderPanel = () =>
  render(
    <BrowserRouter>
      <MigrationChainsPanel />
    </BrowserRouter>,
  );

/**
 * Route GETs by URL. The panel's list call and the drawer's detail call share
 * one axios mock, so a flat mockResolvedValue chain silently hands a detail
 * payload to the list (or vice versa) the moment an action triggers a refetch.
 */
function routeGet(opts: {
  list: () => unknown;
  detail: (id: string) => unknown;
}) {
  mockGet.mockImplementation((url: string) => {
    const m = /\/migration_chains\/(.+)$/.exec(url);
    return Promise.resolve(m ? opts.detail(m[1]) : opts.list());
  });
}

/** Load the list, open the first chain's drawer, and wait for its detail. */
async function openDrawer(id = 'chain-0001') {
  await waitFor(() => expect(screen.getByTestId(`chain-row-${id}`)).toBeInTheDocument());
  fireEvent.click(screen.getByTestId(`chain-row-${id}`));
  await screen.findByText('Migration Chain');
}

// =============================================================================
// Tests
// =============================================================================

describe('MigrationChainsPanel', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockAddNotification.mockReset();
    mockPermissionGranted = (_perm: string) => true;
  });

  // ---------------------------------------------------------------------------
  // List
  // ---------------------------------------------------------------------------

  it('lists chains from the migration_chains endpoint', async () => {
    mockGet.mockResolvedValue(
      envelope({ migration_chains: [CHAIN_IN_FLIGHT, CHAIN_COMPLETED], count: 2 }),
    );

    renderPanel();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/platform/migration_chains', { params: {} }),
    );
    expect(await screen.findByText('2 chains')).toBeInTheDocument();
    expect(screen.getByTestId('chain-row-chain-0001')).toBeInTheDocument();
    expect(screen.getByTestId('chain-row-chain-0002')).toBeInTheDocument();
  });

  it('renders the chain status and hop progress', async () => {
    mockGet.mockResolvedValue(envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }));

    renderPanel();

    const row = await screen.findByTestId('chain-row-chain-0001');
    expect(within(row).getByText('in_flight')).toBeInTheDocument();
    expect(within(row).getByText('1 / 3 hops')).toBeInTheDocument();
  });

  it('counts hops APPLIED, not the position the chain sits at', async () => {
    // current_hop_index is bumped only after a hop succeeds, so it doubles as
    // the applied count: a chain partway through reads fewer than total, and a
    // completed one reads all of them.
    mockGet.mockResolvedValue(
      envelope({ migration_chains: [CHAIN_IN_FLIGHT, CHAIN_COMPLETED], count: 2 }),
    );

    renderPanel();

    const inFlight = await screen.findByTestId('chain-row-chain-0001');
    expect(within(inFlight).getByText('1 / 3 hops')).toBeInTheDocument();
    expect(within(inFlight).getByTestId('hop-progress-bar')).toHaveStyle('width: 33%');

    const completed = screen.getByTestId('chain-row-chain-0002');
    expect(within(completed).getByText('3 / 3 hops')).toBeInTheDocument();
    expect(within(completed).getByTestId('hop-progress-bar')).toHaveStyle('width: 100%');
  });

  it('shows a failed chain as stuck at the hop that did not apply', async () => {
    // Per the model: hop K succeeded, K+1 failed, so current_hop_index is K+1
    // and the resource lives on hop K's destination. The count is what tells
    // the operator whether to retry the hop or abandon the chain there.
    mockGet.mockResolvedValue(
      envelope({
        migration_chains: [
          {
            ...CHAIN_IN_FLIGHT,
            id: 'chain-0003',
            status: 'failed' as const,
            current_hop_index: 2,
            terminal: true,
            failed_at: '2026-05-01T10:30:00Z',
            error_message: 'peer-c refused the transfer',
          },
        ],
        count: 1,
      }),
    );

    renderPanel();

    const row = await screen.findByTestId('chain-row-chain-0003');
    expect(within(row).getByText('2 / 3 hops')).toBeInTheDocument();
    expect(within(row).getByText('failed')).toBeInTheDocument();
    expect(within(row).getByTestId('hop-progress-bar')).toHaveClass('bg-theme-danger-bg');
  });

  it('shows the empty state when there are no chains', async () => {
    mockGet.mockResolvedValue(envelope({ migration_chains: [], count: 0 }));

    renderPanel();

    expect(await screen.findByText('No migration chains yet.')).toBeInTheDocument();
  });

  it('surfaces the server sentence when the list fails', async () => {
    mockGet.mockRejectedValue(axiosError('Forbidden', 403));

    renderPanel();

    expect(await screen.findByText('Forbidden')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Detail drawer
  // ---------------------------------------------------------------------------

  it('opens a detail drawer with the hops and the audit log', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }))
      .mockResolvedValueOnce(envelope({ migration_chain: CHAIN_DETAIL }));

    renderPanel();
    await openDrawer();

    expect(mockGet).toHaveBeenCalledWith('/system/platform/migration_chains/chain-0001');
    expect(await screen.findByText('Hops (3)')).toBeInTheDocument();
    expect(screen.getByText('Chain started')).toBeInTheDocument();
  });

  it('names each hop DESTINATION, which is offset from its position', async () => {
    // ChainComposer writes chain_position: idx - 1 against
    // destination_peer_id: hop_peer_ids[idx], so hop P goes to
    // hop_peer_ids[P + 1]. Indexing hop_peer_ids by position instead would
    // label every hop with its SOURCE and never show the final destination.
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }))
      .mockResolvedValueOnce(envelope({ migration_chain: CHAIN_DETAIL }));

    renderPanel();
    await openDrawer();

    const hop0 = await screen.findByTestId('chain-hop-0');
    expect(within(hop0).getByText('peer-b')).toBeInTheDocument();
    expect(within(screen.getByTestId('chain-hop-1')).getByText('peer-c')).toBeInTheDocument();
    // The last destination exists and is reachable — the off-by-one dropped it.
    expect(within(screen.getByTestId('chain-hop-2')).getByText('peer-d')).toBeInTheDocument();
    // And no hop is labelled with the origin, which has no row of its own.
    expect(screen.queryByText('self (origin)')).not.toBeInTheDocument();
  });

  it('marks the hop the chain is currently at', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }))
      .mockResolvedValueOnce(envelope({ migration_chain: CHAIN_DETAIL }));

    renderPanel();
    await openDrawer();

    const current = await screen.findByTestId('chain-hop-1');
    expect(within(current).getByText('current')).toBeInTheDocument();
    expect(within(screen.getByTestId('chain-hop-0')).queryByText('current')).not.toBeInTheDocument();
  });

  it('renders each hop with the migration status pill, not the chain one', async () => {
    // A hop is an ordinary Migration, so it carries the migration lifecycle —
    // `transferring` has no equivalent in the chain enum.
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }))
      .mockResolvedValueOnce(envelope({ migration_chain: CHAIN_DETAIL }));

    renderPanel();
    await openDrawer();

    const hop = await screen.findByTestId('chain-hop-1');
    const pill = within(hop).getByText('transferring');
    expect(pill).toBeInTheDocument();
    // The chain enum has no `transferring`, so swapping in the chain pill would
    // still render the text with an undefined class — assert the class instead.
    expect(pill).toHaveClass('bg-theme-info-bg');
  });

  // ---------------------------------------------------------------------------
  // Advance / Run
  // ---------------------------------------------------------------------------

  it('advances the chain by one hop and refreshes', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }))
      .mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL }));
    mockPost.mockResolvedValue(
      envelope({ migration_chain: CHAIN_DETAIL, advanced_to: 2 }),
    );

    renderPanel();
    await openDrawer();

    fireEvent.click(await screen.findByRole('button', { name: /advance one hop/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/migration_chains/chain-0001/advance',
        {},
      ),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Chain advanced one hop.',
      }),
    );
  });

  it('runs the chain to completion', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }))
      .mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL }));
    mockPost.mockResolvedValue(
      envelope({ migration_chain: CHAIN_DETAIL_COMPLETED, advanced_to: 3 }),
    );

    renderPanel();
    await openDrawer();

    fireEvent.click(await screen.findByRole('button', { name: /run to completion/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/migration_chains/chain-0001/run',
        {},
      ),
    );
  });

  it('surfaces the executor refusal rather than the axios status line', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }))
      .mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL }));
    mockPost.mockRejectedValue(axiosError('chain is completed and cannot be advanced'));

    renderPanel();
    await openDrawer();

    fireEvent.click(await screen.findByRole('button', { name: /advance one hop/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'chain is completed and cannot be advanced',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Cancel (confirmed)
  // ---------------------------------------------------------------------------

  it('confirms before cancelling, and does not call the API if the operator declines', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_PLANNED], count: 1 }))
      .mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL_PLANNED }));

    renderPanel();
    await openDrawer('chain-0004');

    fireEvent.click(await screen.findByRole('button', { name: /^cancel chain$/i }));

    await screen.findByRole('heading', { name: /cancel migration chain/i });
    // The dialog says what cancelling costs.
    expect(screen.getByText(/NOT rolled back/i)).toBeInTheDocument();

    fireEvent.click(
      within(screen.getByRole('dialog')).getByRole('button', { name: /^keep chain$/i }),
    );

    expect(mockPost).not.toHaveBeenCalled();
  });

  it('cancels the chain once the operator confirms', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_PLANNED], count: 1 }))
      .mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL_PLANNED }));
    mockPost.mockResolvedValue(
      envelope({ migration_chain: { ...CHAIN_DETAIL_PLANNED, status: 'cancelled' } }),
    );

    renderPanel();
    await openDrawer('chain-0004');

    fireEvent.click(await screen.findByRole('button', { name: /^cancel chain$/i }));
    await screen.findByRole('heading', { name: /cancel migration chain/i });
    fireEvent.click(
      within(screen.getByRole('dialog')).getByRole('button', { name: /^cancel chain$/i }),
    );

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/migration_chains/chain-0004/cancel',
        {},
      ),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Chain cancelled.',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Permission + lifecycle gating
  // ---------------------------------------------------------------------------

  it('hides Advance and Run without system.migrations.apply', async () => {
    mockPermissionGranted = (perm: string) => perm !== 'system.migrations.apply';
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_PLANNED], count: 1 }))
      .mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL_PLANNED }));

    renderPanel();
    await openDrawer('chain-0004');

    await screen.findByText('Hops (3)');
    expect(screen.queryByRole('button', { name: /advance one hop/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /run to completion/i })).not.toBeInTheDocument();
    // cancel is a different permission and stays.
    expect(screen.getByRole('button', { name: /^cancel chain$/i })).toBeInTheDocument();
  });

  it('hides Cancel without system.migrations.cancel', async () => {
    mockPermissionGranted = (perm: string) => perm !== 'system.migrations.cancel';
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_PLANNED], count: 1 }))
      .mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL_PLANNED }));

    renderPanel();
    await openDrawer('chain-0004');

    await screen.findByText('Hops (3)');
    expect(screen.queryByRole('button', { name: /^cancel chain$/i })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /advance one hop/i })).toBeInTheDocument();
  });

  it('does not offer Cancel on an in-flight chain, and says why', async () => {
    // MigrationChain::TRANSITIONS gives in_flight only completed|failed. The
    // controller's own header comment claims planned/in_flight → cancelled and
    // is wrong; the cancel action guards on can_transition_to? and 422s.
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }))
      .mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL }));

    renderPanel();
    await openDrawer();

    await screen.findByRole('button', { name: /advance one hop/i });
    expect(screen.queryByRole('button', { name: /^cancel chain$/i })).not.toBeInTheDocument();
    expect(screen.getByText(/cannot be cancelled/i)).toBeInTheDocument();
  });

  it('refreshes the drawer AND the list after a failed advance', async () => {
    // A failed advance is not a no-op: ChainExecutor#fail_chain! writes
    // error_message and moves the chain to `failed`. Leaving the old detail up
    // would show live Advance/Run buttons on a chain that is already terminal.
    const FAILED_DETAIL = {
      ...CHAIN_DETAIL,
      status: 'failed' as const,
      terminal: true,
      current_hop_index: 2,
      error_message: 'peer-c refused the transfer',
    };
    let detailPayload: unknown = envelope({ migration_chain: CHAIN_DETAIL });
    routeGet({
      list: () => envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }),
      detail: () => detailPayload,
    });
    mockPost.mockImplementation(() => {
      detailPayload = envelope({ migration_chain: FAILED_DETAIL });
      return Promise.reject(axiosError('hop apply failed'));
    });

    renderPanel();
    await openDrawer();

    fireEvent.click(await screen.findByRole('button', { name: /advance one hop/i }));

    await waitFor(() =>
      expect(screen.getByText('peer-c refused the transfer')).toBeInTheDocument(),
    );
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /advance one hop/i })).not.toBeInTheDocument(),
    );
  });

  it('refreshes both the drawer and the list after a successful advance', async () => {
    routeGet({
      list: () => envelope({ migration_chains: [CHAIN_IN_FLIGHT], count: 1 }),
      detail: () => envelope({ migration_chain: CHAIN_DETAIL }),
    });
    mockPost.mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL, advanced_to: 2 }));

    renderPanel();
    await openDrawer();
    const listCalls = () =>
      mockGet.mock.calls.filter((c) => c[0] === '/system/platform/migration_chains').length;
    const detailCalls = () =>
      mockGet.mock.calls.filter((c) => String(c[0]).endsWith('/chain-0001')).length;
    const listBefore = listCalls();
    const detailBefore = detailCalls();

    fireEvent.click(await screen.findByRole('button', { name: /advance one hop/i }));

    await waitFor(() => expect(detailCalls()).toBeGreaterThan(detailBefore));
    await waitFor(() => expect(listCalls()).toBeGreaterThan(listBefore));
  });

  it('does not leave the previous chain body up while the next one loads', async () => {
    // The Actions section is gated on the CHAIN'S status while the handlers
    // already target the new id, so a body that outlives its subject would let
    // one click fire the previous chain's affordance at the new one.
    let resolveSecond!: (v: unknown) => void;
    mockGet
      .mockResolvedValueOnce(
        envelope({ migration_chains: [CHAIN_IN_FLIGHT, CHAIN_COMPLETED], count: 2 }),
      )
      .mockResolvedValueOnce(envelope({ migration_chain: CHAIN_DETAIL }))
      .mockReturnValueOnce(new Promise((res) => { resolveSecond = res; }));

    renderPanel();
    await openDrawer();
    await screen.findByRole('button', { name: /advance one hop/i });

    fireEvent.click(screen.getByTestId('chain-row-chain-0002'));

    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /advance one hop/i })).not.toBeInTheDocument(),
    );
    expect(screen.getByText('Loading…')).toBeInTheDocument();

    resolveSecond(envelope({ migration_chain: CHAIN_DETAIL_COMPLETED }));
  });

  it('shows a planned chain as nothing applied yet', async () => {
    mockGet.mockResolvedValue(envelope({ migration_chains: [CHAIN_PLANNED], count: 1 }));

    renderPanel();

    const row = await screen.findByTestId('chain-row-chain-0004');
    expect(within(row).getByText('0 / 3 hops')).toBeInTheDocument();
    expect(within(row).getByTestId('hop-progress-bar')).toHaveStyle('width: 0%');
  });

  it('offers no actions on a terminal chain', async () => {
    // MigrationChain::TRANSITIONS gives completed / failed / cancelled no
    // outgoing edges, so every control would 422.
    mockGet
      .mockResolvedValueOnce(envelope({ migration_chains: [CHAIN_COMPLETED], count: 1 }))
      .mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL_COMPLETED }));

    renderPanel();
    await openDrawer('chain-0002');

    await screen.findByText('Hops (3)');
    expect(screen.queryByRole('button', { name: /advance one hop/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /run to completion/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /^cancel chain$/i })).not.toBeInTheDocument();
  });

  it('drops an open cancel confirmation when the drawer switches to another chain', async () => {
    mockGet
      .mockResolvedValueOnce(
        envelope({ migration_chains: [CHAIN_PLANNED, CHAIN_COMPLETED], count: 2 }),
      )
      .mockResolvedValue(envelope({ migration_chain: CHAIN_DETAIL_PLANNED }));

    renderPanel();
    await openDrawer('chain-0004');

    fireEvent.click(await screen.findByRole('button', { name: /^cancel chain$/i }));
    await screen.findByRole('heading', { name: /cancel migration chain/i });

    // Switch subject while the confirmation is open. Its onConfirm closed over
    // the PREVIOUS chain id, so it must not survive.
    fireEvent.click(screen.getByTestId('chain-row-chain-0002'));

    await waitFor(() =>
      expect(
        screen.queryByRole('heading', { name: /cancel migration chain/i }),
      ).not.toBeInTheDocument(),
    );
    expect(mockPost).not.toHaveBeenCalled();
  });
});
