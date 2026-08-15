import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { NetworksTab } from './NetworksTab';
import type { SdwanNetwork } from '@system/features/system/types/sdwan.types';

// =============================================================================
// Mocks
//
// NetworksTab imports:
//   - usePermissions from '@/shared/hooks/usePermissions'
//   - useNotifications from '@/shared/hooks/useNotifications'
//   - NetworkList, NetworkCreateModal, NetworkDetailModal from '@system/features/system/components/sdwan'
//   - sdwanApi from '@system/features/system/services/api/sdwanApi'
//   - Modal from '@/shared/components/ui/Modal'  (real — delete confirm dialog)
//   - Button from '@/shared/components/ui/Button'  (real)
//
// We mock the three heavy child components so this test focuses on the
// NetworksTab orchestration logic (state, callbacks, delete flow).
// =============================================================================

const mockDeleteNetwork = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    deleteNetwork: (...args: unknown[]) => mockDeleteNetwork(...args),
  },
}));

// `mockHasPermission` is reassigned per-test; must be declared before the factory
// with the `mock` prefix so jest hoisting allows access inside jest.mock().
let mockHasPermission: (perm: string) => boolean = () => true;

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (perm: string) => mockHasPermission(perm),
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// Captured props from the mocked child components — reassigned on each render.
// Prefixed with `mock` so they can be referenced inside jest.mock() factories.
let mockCapturedNetworkListProps: Record<string, unknown> = {};
let mockCapturedCreateModalProps: Record<string, unknown> = {};
let mockCapturedDetailModalProps: Record<string, unknown> = {};

// Inline fixtures inside the factory — jest.mock() cannot reference out-of-scope
// variables unless they are prefixed with `mock`. These tiny objects duplicate the
// test fixtures so the mock buttons can call the right callbacks.
const mockNetworkAId = 'net-aaa';
const mockNetworkAName = 'prod-overlay';
const mockNetworkBId = 'net-bbb';
const mockNetworkBName = 'staging-net';

jest.mock('@system/features/system/components/sdwan', () => ({
  NetworkList: (props: Record<string, unknown>) => {
    mockCapturedNetworkListProps = props;

    const networkA = {
      id: mockNetworkAId,
      name: mockNetworkAName,
      slug: mockNetworkAName,
      status: 'active' as const,
      cidr_64: 'fd00:aabb::/64',
      peer_count: 4,
      hub_count: 2,
      spoke_count: 2,
      created_at: '2026-01-10T08:00:00Z',
    };
    const networkB = {
      id: mockNetworkBId,
      name: mockNetworkBName,
      slug: mockNetworkBName,
      status: 'registered' as const,
      cidr_64: 'fd00:ccdd::/64',
      peer_count: 1,
      hub_count: 1,
      spoke_count: 0,
      created_at: '2026-02-01T00:00:00Z',
    };

    return (
      <div data-testid="network-list">
        {/* Use unambiguous button labels so they never collide with the
            delete-confirmation modal's own "Delete" / "Cancel" buttons */}
        <button
          data-testid="trigger-open-details"
          onClick={() => {
            if (typeof props.onOpenDetails === 'function') {
              // eslint-disable-next-line @typescript-eslint/no-unsafe-function-type
              (props.onOpenDetails as Function)(networkA);
            }
          }}
        >
          Trigger Open Details
        </button>
        <button
          data-testid="trigger-delete-a"
          onClick={() => {
            if (typeof props.onDelete === 'function') {
              // eslint-disable-next-line @typescript-eslint/no-unsafe-function-type
              (props.onDelete as Function)(networkA);
            }
          }}
        >
          Trigger Delete A
        </button>
        <button
          data-testid="trigger-delete-b"
          onClick={() => {
            if (typeof props.onDelete === 'function') {
              // eslint-disable-next-line @typescript-eslint/no-unsafe-function-type
              (props.onDelete as Function)(networkB);
            }
          }}
        >
          Trigger Delete B
        </button>
        <span data-testid="refresh-key">{String(props.refreshKey)}</span>
      </div>
    );
  },

  NetworkCreateModal: (props: Record<string, unknown>) => {
    mockCapturedCreateModalProps = props;
    return props.isOpen ? (
      <div data-testid="create-modal">
        <button
          data-testid="trigger-created"
          onClick={() => {
            if (typeof props.onCreated === 'function') {
              // eslint-disable-next-line @typescript-eslint/no-unsafe-function-type
              (props.onCreated as Function)();
            }
          }}
        >
          Simulate Created
        </button>
        <button
          data-testid="trigger-close-create"
          onClick={() => {
            if (typeof props.onClose === 'function') {
              // eslint-disable-next-line @typescript-eslint/no-unsafe-function-type
              (props.onClose as Function)();
            }
          }}
        >
          Simulate Close Create
        </button>
      </div>
    ) : null;
  },

  NetworkDetailModal: (props: Record<string, unknown>) => {
    mockCapturedDetailModalProps = props;
    return props.isOpen ? (
      <div data-testid="detail-modal">
        <button
          data-testid="trigger-close-detail"
          onClick={() => {
            if (typeof props.onClose === 'function') {
              // eslint-disable-next-line @typescript-eslint/no-unsafe-function-type
              (props.onClose as Function)();
            }
          }}
        >
          Simulate Close Detail
        </button>
      </div>
    ) : null;
  },
}));

// =============================================================================
// Fixtures (used in test assertions — not inside mock factories)
// =============================================================================

const NETWORK_A: SdwanNetwork = {
  id: 'net-aaa',
  name: 'prod-overlay',
  slug: 'prod-overlay',
  status: 'active',
  cidr_64: 'fd00:aabb::/64',
  peer_count: 4,
  hub_count: 2,
  spoke_count: 2,
  created_at: '2026-01-10T08:00:00Z',
};

const NETWORK_B: SdwanNetwork = {
  id: 'net-bbb',
  name: 'staging-net',
  slug: 'staging-net',
  status: 'registered',
  cidr_64: 'fd00:ccdd::/64',
  peer_count: 1,
  hub_count: 1,
  spoke_count: 0,
  created_at: '2026-02-01T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

function renderTab(props: Partial<{ onActionsReady: jest.Mock }> = {}) {
  return render(<NetworksTab {...props} />);
}

/**
 * Open the delete confirmation modal for the given network (a or b) and
 * wait for the modal title to appear.
 */
async function openDeleteModal(network: 'a' | 'b' = 'a') {
  fireEvent.click(screen.getByTestId(`trigger-delete-${network}`));
  await waitFor(() =>
    expect(screen.getByText('Delete SDWAN network')).toBeInTheDocument(),
  );
}

/**
 * Click the danger "Delete" button inside the confirmation modal.
 *
 * The mock NetworkList renders buttons with labels "Trigger Delete A" and
 * "Trigger Delete B" — none labelled just "Delete". The confirmation modal's
 * danger button has exactly that text, so `getAllByRole('button', { name: /^Delete$/i })`
 * returns exactly one element.
 */
function clickConfirmDelete() {
  const btn = screen.getByRole('button', { name: /^Delete$/i });
  fireEvent.click(btn);
}

// =============================================================================
// Tests
// =============================================================================

describe('NetworksTab', () => {
  beforeEach(() => {
    mockDeleteNetwork.mockReset();
    mockAddNotification.mockReset();
    mockCapturedNetworkListProps = {};
    mockCapturedCreateModalProps = {};
    mockCapturedDetailModalProps = {};
    mockHasPermission = () => true;
  });

  // ---------------------------------------------------------------------------
  // Basic render
  // ---------------------------------------------------------------------------

  it('renders the NetworkList component', () => {
    renderTab();
    expect(screen.getByTestId('network-list')).toBeInTheDocument();
  });

  it('does NOT render NetworkCreateModal initially', () => {
    renderTab();
    expect(screen.queryByTestId('create-modal')).not.toBeInTheDocument();
  });

  it('does NOT render NetworkDetailModal initially', () => {
    renderTab();
    expect(screen.queryByTestId('detail-modal')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onActionsReady callback
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with a handle containing openCreate on mount', () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    expect(onActionsReady).toHaveBeenCalledTimes(1);
    const handle = onActionsReady.mock.calls[0][0];
    expect(handle).not.toBeNull();
    expect(typeof handle.openCreate).toBe('function');
  });

  it('calls onActionsReady(null) on unmount', () => {
    const onActionsReady = jest.fn();
    const { unmount } = renderTab({ onActionsReady });
    onActionsReady.mockClear();
    unmount();
    expect(onActionsReady).toHaveBeenCalledWith(null);
  });

  it('does not crash when no onActionsReady prop is provided', () => {
    expect(() => renderTab()).not.toThrow();
  });

  // ---------------------------------------------------------------------------
  // NetworkCreateModal open / close
  // ---------------------------------------------------------------------------

  it('openCreate handle opens the NetworkCreateModal', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    act(() => {
      onActionsReady.mock.calls[0][0].openCreate();
    });

    await waitFor(() =>
      expect(screen.getByTestId('create-modal')).toBeInTheDocument(),
    );
    expect(mockCapturedCreateModalProps.isOpen).toBe(true);
  });

  it('closes NetworkCreateModal when the modal fires onClose', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    act(() => {
      onActionsReady.mock.calls[0][0].openCreate();
    });
    await waitFor(() =>
      expect(screen.getByTestId('create-modal')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('trigger-close-create'));

    await waitFor(() =>
      expect(screen.queryByTestId('create-modal')).not.toBeInTheDocument(),
    );
  });

  it('increments refreshKey when NetworkCreateModal fires onCreated', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    const initialKey = Number(screen.getByTestId('refresh-key').textContent);

    act(() => {
      onActionsReady.mock.calls[0][0].openCreate();
    });
    await waitFor(() =>
      expect(screen.getByTestId('create-modal')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('trigger-created'));

    await waitFor(() => {
      expect(Number(screen.getByTestId('refresh-key').textContent)).toBeGreaterThan(initialKey);
    });
  });

  // ---------------------------------------------------------------------------
  // NetworkDetailModal open / close
  // ---------------------------------------------------------------------------

  it('opens NetworkDetailModal with the correct network when onOpenDetails fires', async () => {
    renderTab();

    fireEvent.click(screen.getByTestId('trigger-open-details'));

    await waitFor(() =>
      expect(screen.getByTestId('detail-modal')).toBeInTheDocument(),
    );
    expect(mockCapturedDetailModalProps.isOpen).toBe(true);
    expect(mockCapturedDetailModalProps.network).toEqual(NETWORK_A);
  });

  it('closes NetworkDetailModal when the modal fires onClose', async () => {
    renderTab();

    fireEvent.click(screen.getByTestId('trigger-open-details'));
    await waitFor(() =>
      expect(screen.getByTestId('detail-modal')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('trigger-close-detail'));

    await waitFor(() =>
      expect(screen.queryByTestId('detail-modal')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Permission gating for delete
  // ---------------------------------------------------------------------------

  it('passes onDelete to NetworkList when user has sdwan.networks.manage', () => {
    mockHasPermission = () => true;
    renderTab();
    expect(typeof mockCapturedNetworkListProps.onDelete).toBe('function');
  });

  it('passes undefined as onDelete when user lacks sdwan.networks.manage', () => {
    mockHasPermission = (perm: string) => perm !== 'system.sdwan.networks.manage';
    renderTab();
    expect(mockCapturedNetworkListProps.onDelete).toBeUndefined();
  });

  // ---------------------------------------------------------------------------
  // Delete confirmation modal — appearance
  // ---------------------------------------------------------------------------

  it('opens the delete confirmation modal when NetworkList calls onDelete', async () => {
    renderTab();

    await openDeleteModal('a');

    expect(screen.getByText(/Permanently delete/)).toBeInTheDocument();
    // Network name appears inside the <strong> element.
    expect(screen.getByText('prod-overlay')).toBeInTheDocument();
  });

  it('shows the agent teardown warning in the confirmation modal', async () => {
    renderTab();

    await openDeleteModal('a');

    expect(
      screen.getByText(/destroys all peers \+ firewall rules/i),
    ).toBeInTheDocument();
  });

  it('renders Cancel and Delete buttons in the confirmation modal', async () => {
    renderTab();

    await openDeleteModal('a');

    expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /^Delete$/i })).toBeInTheDocument();
  });

  it('closes the confirmation modal when Cancel is clicked', async () => {
    renderTab();

    await openDeleteModal('a');

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText('Delete SDWAN network')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Delete flow — successful deletion
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.deleteNetwork with the correct network id on confirm', async () => {
    mockDeleteNetwork.mockResolvedValueOnce(undefined);
    renderTab();

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() =>
      expect(mockDeleteNetwork).toHaveBeenCalledWith(NETWORK_A.id),
    );
  });

  it('shows a success notification after successful deletion', async () => {
    mockDeleteNetwork.mockResolvedValueOnce(undefined);
    renderTab();

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Network "${NETWORK_A.name}" deleted`,
      }),
    );
  });

  it('dismisses the confirmation modal after successful deletion', async () => {
    mockDeleteNetwork.mockResolvedValueOnce(undefined);
    renderTab();

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() =>
      expect(screen.queryByText('Delete SDWAN network')).not.toBeInTheDocument(),
    );
  });

  it('increments refreshKey after successful deletion so NetworkList reloads', async () => {
    mockDeleteNetwork.mockResolvedValueOnce(undefined);
    renderTab();

    const initialKey = Number(screen.getByTestId('refresh-key').textContent);

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() => {
      expect(Number(screen.getByTestId('refresh-key').textContent)).toBeGreaterThan(initialKey);
    });
  });

  // ---------------------------------------------------------------------------
  // Delete flow — error handling
  // ---------------------------------------------------------------------------

  it('shows an error notification when deletion fails with an Error instance', async () => {
    mockDeleteNetwork.mockRejectedValueOnce(new Error('Server unavailable'));
    renderTab();

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Server unavailable',
      }),
    );
  });

  it('shows a generic error message when deletion fails with a non-Error value', async () => {
    mockDeleteNetwork.mockRejectedValueOnce('boom');
    renderTab();

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete network',
      }),
    );
  });

  it('keeps the confirmation modal open after a failed deletion', async () => {
    mockDeleteNetwork.mockRejectedValueOnce(new Error('Server error'));
    renderTab();

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());

    // Modal stays open so the operator can see which network failed.
    expect(screen.getByText('Delete SDWAN network')).toBeInTheDocument();
  });

  it('does NOT increment refreshKey after a failed deletion', async () => {
    mockDeleteNetwork.mockRejectedValueOnce(new Error('Network error'));
    renderTab();

    const initialKey = Number(screen.getByTestId('refresh-key').textContent);

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());

    expect(Number(screen.getByTestId('refresh-key').textContent)).toBe(initialKey);
  });

  // ---------------------------------------------------------------------------
  // Delete button loading state
  // ---------------------------------------------------------------------------

  it('shows "Deleting…" on the danger button while the API call is in flight', async () => {
    mockDeleteNetwork.mockReturnValueOnce(new Promise(() => {}));
    renderTab();

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() => {
      const buttons = screen.getAllByRole('button');
      expect(buttons.some((b) => /Deleting/i.test(b.textContent ?? ''))).toBe(true);
    });
  });

  it('disables the Cancel button while deletion is in progress', async () => {
    mockDeleteNetwork.mockReturnValueOnce(new Promise(() => {}));
    renderTab();

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled(),
    );
  });

  it('disables the Deleting… button while deletion is in progress', async () => {
    mockDeleteNetwork.mockReturnValueOnce(new Promise(() => {}));
    renderTab();

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() => {
      const dangerBtn = screen.getAllByRole('button').find(
        (b) => /Deleting/i.test(b.textContent ?? ''),
      );
      expect(dangerBtn).toBeDisabled();
    });
  });

  // ---------------------------------------------------------------------------
  // refreshKey initial value
  // ---------------------------------------------------------------------------

  it('passes initial refreshKey=0 to NetworkList', () => {
    renderTab();
    expect(screen.getByTestId('refresh-key').textContent).toBe('0');
  });

  // ---------------------------------------------------------------------------
  // Multiple sequential deletions
  // ---------------------------------------------------------------------------

  it('shows the second network name in a subsequent delete confirmation', async () => {
    renderTab();

    await openDeleteModal('b');

    // Staging-net should appear; prod-overlay should not.
    expect(screen.getByText('staging-net')).toBeInTheDocument();
    expect(screen.queryByText('prod-overlay')).not.toBeInTheDocument();
  });

  it('can delete a second network after the first deletion succeeds', async () => {
    mockDeleteNetwork
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce(undefined);

    renderTab();

    // First deletion.
    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() =>
      expect(screen.queryByText('Delete SDWAN network')).not.toBeInTheDocument(),
    );
    expect(mockDeleteNetwork).toHaveBeenCalledTimes(1);
    expect(mockDeleteNetwork).toHaveBeenCalledWith(NETWORK_A.id);

    // Second deletion.
    await openDeleteModal('b');
    expect(screen.getByText('staging-net')).toBeInTheDocument();

    clickConfirmDelete();

    await waitFor(() =>
      expect(mockDeleteNetwork).toHaveBeenCalledWith(NETWORK_B.id),
    );
    expect(mockDeleteNetwork).toHaveBeenCalledTimes(2);
  });

  // ---------------------------------------------------------------------------
  // Pending-approval branch (IMP-87ec6f651f07)
  // ---------------------------------------------------------------------------

  it('shows the pending-approval notification (not success) when the network delete is parked', async () => {
    mockDeleteNetwork.mockResolvedValueOnce({
      pending: true,
      deferred_operation_id: 'dop-1',
      action_category: 'sdwan.network_delete',
      approval_request_id: 'ar-1',
      message: 'Approval required',
    });
    renderTab();

    await openDeleteModal('a');
    clickConfirmDelete();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval required/i),
          link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
        }),
      ),
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' }),
    );
  });
});
