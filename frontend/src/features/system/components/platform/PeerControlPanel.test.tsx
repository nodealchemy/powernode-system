import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PeerControlPanel } from './PeerControlPanel';
import type { PlatformPeerSummary } from '../../types/peer.types';

// =============================================================================
// Mocks
//
// PeerControlPanel uses:
//   - platformPeersApi (via usePlatformPeers hook and direct .revoke call)
//   - useNotifications
//   - InvitePeerModal, PeerDetailDrawer, GrantsManagementModal (child modals)
//   - useArmedConfirm (from shared hooks)
//
// We mock the API and notifications, and stub the child modals so
// their own API calls don't bleed into PeerControlPanel's test surface.
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

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

jest.mock('@/shared/hooks/BreadcrumbContext', () => ({
  __esModule: true,
  BreadcrumbProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
  useBreadcrumb: () => ({
    breadcrumbs: [],
    setBreadcrumbs: jest.fn(),
    getCurrentBreadcrumbs: () => [],
    setCurrentPage: jest.fn(),
  }),
}));

// Stub the child modals so they don't do their own API calls.
// We verify they open/close via their props in the parent.
jest.mock('./InvitePeerModal', () => ({
  InvitePeerModal: ({
    isOpen,
    onClose,
    onInvited,
  }: {
    isOpen: boolean;
    onClose: () => void;
    onInvited?: () => void;
  }) =>
    isOpen ? (
      <div data-testid="invite-peer-modal">
        <button onClick={onClose} data-testid="invite-modal-close">
          Close
        </button>
        <button onClick={() => onInvited?.()} data-testid="invite-modal-invited">
          Invited
        </button>
      </div>
    ) : null,
}));

jest.mock('./PeerDetailDrawer', () => ({
  PeerDetailDrawer: ({
    peerId,
    onClose,
  }: {
    peerId: string | null;
    onClose: () => void;
  }) =>
    peerId ? (
      <div data-testid="peer-detail-drawer" data-peer-id={peerId}>
        <button onClick={onClose} data-testid="detail-drawer-close">
          Close
        </button>
      </div>
    ) : null,
}));

jest.mock('./GrantsManagementModal', () => ({
  GrantsManagementModal: ({
    isOpen,
    peerId,
    peerLabel,
    onClose,
  }: {
    isOpen: boolean;
    peerId: string | null;
    peerLabel: string;
    onClose: () => void;
    onChanged?: () => void;
  }) =>
    isOpen && peerId ? (
      <div
        data-testid="grants-management-modal"
        data-peer-id={peerId}
        data-peer-label={peerLabel}
      >
        <button onClick={onClose} data-testid="grants-modal-close">
          Close
        </button>
      </div>
    ) : null,
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const PEER_ACTIVE: PlatformPeerSummary = {
  id: 'peer-active-1',
  remote_instance_url: 'https://remote.example.com',
  remote_instance_id: 'rid-001',
  peer_kind: 'platform',
  spawn_role: 'symmetric',
  spawn_mode: 'out_of_band',
  status: 'active',
  created_at: '2026-01-01T00:00:00Z',
  last_heartbeat_at: '2026-06-01T12:00:00Z',
  last_handshake_at: '2026-05-01T12:00:00Z',
  endpoints_count: 2,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

const PEER_REVOKED: PlatformPeerSummary = {
  id: 'peer-revoked-2',
  remote_instance_url: 'https://old.example.com',
  remote_instance_id: 'rid-002',
  peer_kind: 'platform',
  spawn_role: null,
  spawn_mode: null,
  status: 'revoked',
  created_at: '2026-01-01T00:00:00Z',
  last_heartbeat_at: null,
  last_handshake_at: null,
  endpoints_count: 0,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

function peersListResponse(peers: PlatformPeerSummary[]) {
  return envelope({ peers, count: peers.length });
}

// =============================================================================
// Helper
// =============================================================================

function renderPanel(props: Partial<React.ComponentProps<typeof PeerControlPanel>> = {}) {
  const defaults = { canManage: true };
  return render(
    <BrowserRouter>
      <PeerControlPanel {...defaults} {...props} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PeerControlPanel', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  describe('render states', () => {
    it('renders the panel container and header', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      renderPanel();

      expect(screen.getByTestId('peer-control-panel')).toBeInTheDocument();
      expect(screen.getByText('Peers')).toBeInTheDocument();
    });

    it('shows loading indicator while fetch is in flight', () => {
      // Never resolve so we catch the loading state
      mockGet.mockReturnValue(new Promise(() => {}));

      renderPanel();

      expect(screen.getByText('loading…')).toBeInTheDocument();
    });

    it('shows empty-state message with invite hint when canManage=true and no peers', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(
          screen.getByText(/No federation peers yet/),
        ).toBeInTheDocument();
      });
      expect(
        screen.getByText(/Click "Invite Peer" to propose one/),
      ).toBeInTheDocument();
    });

    it('shows empty-state without invite hint when canManage=false', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      renderPanel({ canManage: false });

      await waitFor(() => {
        expect(screen.getByText(/No federation peers yet/)).toBeInTheDocument();
      });
      expect(
        screen.queryByText(/Click "Invite Peer" to propose one/),
      ).not.toBeInTheDocument();
    });

    it('renders peer rows when peers are returned', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE, PEER_REVOKED]));

      renderPanel();

      await waitFor(() => {
        expect(screen.getByTestId('control-row-peer-active-1')).toBeInTheDocument();
      });
      expect(screen.getByTestId('control-row-peer-revoked-2')).toBeInTheDocument();
    });

    it('displays the correct peer count in the header', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE, PEER_REVOKED]));

      renderPanel();

      await waitFor(() => {
        expect(screen.getByText('2 peers')).toBeInTheDocument();
      });
    });

    it('uses singular "peer" for a count of 1', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel();

      await waitFor(() => {
        expect(screen.getByText('1 peer')).toBeInTheDocument();
      });
    });

    it('shows error banner when the API call fails', async () => {
      mockGet.mockRejectedValue(new Error('Network error'));

      renderPanel();

      await waitFor(() => {
        expect(screen.getByText('Network error')).toBeInTheDocument();
      });
    });

    it('dismisses the error banner when the X button is clicked', async () => {
      mockGet.mockRejectedValue(new Error('Network error'));

      renderPanel();

      await waitFor(() => {
        expect(screen.getByText('Network error')).toBeInTheDocument();
      });

      // Find the X button within the error banner
      const errorBanner = screen.getByText('Network error').closest('div.p-3');
      const closeBtn = errorBanner?.querySelector('button[type="button"]');
      expect(closeBtn).toBeTruthy();
      fireEvent.click(closeBtn!);

      await waitFor(() => {
        expect(screen.queryByText('Network error')).not.toBeInTheDocument();
      });
    });
  });

  // ---------------------------------------------------------------------------
  // API calls
  //
  // The component fires two GET calls on mount: the usePlatformPeers hook
  // calls refetch() from its own useEffect, and PeerControlPanel's own
  // useEffect([refetch, refreshKey]) also runs immediately. Both are
  // intentional — the component always syncs with its parent's refreshKey.
  // ---------------------------------------------------------------------------

  describe('API calls', () => {
    it('calls GET /system/platform/peers on mount', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      renderPanel();

      await waitFor(() => {
        expect(mockGet).toHaveBeenCalledWith(
          '/system/platform/peers',
          expect.objectContaining({ params: {} }),
        );
      });
    });

    it('refetches when the refresh button is clicked', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      renderPanel();

      // Wait for initial fetches to settle (2 calls on mount)
      await waitFor(() => {
        expect(mockGet).toHaveBeenCalledTimes(2);
      });

      fireEvent.click(screen.getByTitle('Refresh'));

      await waitFor(() => {
        expect(mockGet).toHaveBeenCalledTimes(3);
      });
    });

    it('refetches when refreshKey prop changes', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      const { rerender } = renderPanel({ refreshKey: 0 });

      // Wait for initial fetches to settle
      await waitFor(() => {
        expect(mockGet).toHaveBeenCalledTimes(2);
      });

      rerender(
        <BrowserRouter>
          <PeerControlPanel canManage={true} refreshKey={1} />
        </BrowserRouter>,
      );

      await waitFor(() => {
        expect(mockGet).toHaveBeenCalledTimes(3);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Invite Peer modal
  // ---------------------------------------------------------------------------

  describe('Invite Peer modal', () => {
    it('shows Invite Peer button when canManage=true', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getByRole('button', { name: /invite peer/i })).toBeInTheDocument();
      });
    });

    it('hides Invite Peer button when canManage=false', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      renderPanel({ canManage: false });

      await waitFor(() => {
        expect(screen.queryByRole('button', { name: /invite peer/i })).not.toBeInTheDocument();
      });
    });

    it('opens InvitePeerModal when Invite Peer is clicked', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getByRole('button', { name: /invite peer/i })).toBeInTheDocument();
      });

      fireEvent.click(screen.getByRole('button', { name: /invite peer/i }));

      expect(screen.getByTestId('invite-peer-modal')).toBeInTheDocument();
    });

    it('closes InvitePeerModal when onClose is called', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getByRole('button', { name: /invite peer/i })).toBeInTheDocument();
      });

      fireEvent.click(screen.getByRole('button', { name: /invite peer/i }));
      expect(screen.getByTestId('invite-peer-modal')).toBeInTheDocument();

      fireEvent.click(screen.getByTestId('invite-modal-close'));

      expect(screen.queryByTestId('invite-peer-modal')).not.toBeInTheDocument();
    });

    it('triggers refetch after a successful invite', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));

      renderPanel({ canManage: true });

      // Wait for initial fetches to settle (2 calls on mount)
      await waitFor(() => {
        expect(mockGet).toHaveBeenCalledTimes(2);
      });

      fireEvent.click(screen.getByRole('button', { name: /invite peer/i }));
      fireEvent.click(screen.getByTestId('invite-modal-invited'));

      await waitFor(() => {
        expect(mockGet).toHaveBeenCalledTimes(3);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Column headers
  // ---------------------------------------------------------------------------

  describe('column headers', () => {
    it('renders correct column headers when peers exist', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel();

      await waitFor(() => {
        expect(screen.getByTestId('control-row-peer-active-1')).toBeInTheDocument();
      });

      expect(screen.getByText('Remote URL')).toBeInTheDocument();
      expect(screen.getByText('Status')).toBeInTheDocument();
      expect(screen.getByText('Last Heartbeat')).toBeInTheDocument();
      expect(screen.getByText('Actions')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Row actions — Detail view
  // ---------------------------------------------------------------------------

  describe('row actions: Detail', () => {
    it('shows Detail button for every peer', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel();

      await waitFor(() => {
        expect(screen.getByTestId('control-row-peer-active-1')).toBeInTheDocument();
      });

      expect(screen.getByTitle('View detail')).toBeInTheDocument();
    });

    it('opens PeerDetailDrawer with correct peerId when Detail is clicked', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel();

      await waitFor(() => {
        expect(screen.getByTitle('View detail')).toBeInTheDocument();
      });

      fireEvent.click(screen.getByTitle('View detail'));

      const drawer = screen.getByTestId('peer-detail-drawer');
      expect(drawer).toBeInTheDocument();
      expect(drawer).toHaveAttribute('data-peer-id', 'peer-active-1');
    });

    it('closes PeerDetailDrawer when onClose is called', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel();

      await waitFor(() => {
        expect(screen.getByTitle('View detail')).toBeInTheDocument();
      });

      fireEvent.click(screen.getByTitle('View detail'));
      expect(screen.getByTestId('peer-detail-drawer')).toBeInTheDocument();

      fireEvent.click(screen.getByTestId('detail-drawer-close'));

      expect(screen.queryByTestId('peer-detail-drawer')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Row actions — Grants (canManage only)
  // ---------------------------------------------------------------------------

  describe('row actions: Grants', () => {
    it('shows Grants button when canManage=true', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getByTitle('Manage grants')).toBeInTheDocument();
      });
    });

    it('hides Grants button when canManage=false', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel({ canManage: false });

      await waitFor(() => {
        expect(screen.getByTestId('control-row-peer-active-1')).toBeInTheDocument();
      });

      expect(screen.queryByTitle('Manage grants')).not.toBeInTheDocument();
    });

    it('opens GrantsManagementModal with correct peer data when Grants is clicked', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getByTitle('Manage grants')).toBeInTheDocument();
      });

      fireEvent.click(screen.getByTitle('Manage grants'));

      const modal = screen.getByTestId('grants-management-modal');
      expect(modal).toBeInTheDocument();
      expect(modal).toHaveAttribute('data-peer-id', 'peer-active-1');
      expect(modal).toHaveAttribute('data-peer-label', 'https://remote.example.com');
    });

    it('closes GrantsManagementModal when onClose is called', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getByTitle('Manage grants')).toBeInTheDocument();
      });

      fireEvent.click(screen.getByTitle('Manage grants'));
      expect(screen.getByTestId('grants-management-modal')).toBeInTheDocument();

      fireEvent.click(screen.getByTestId('grants-modal-close'));

      expect(screen.queryByTestId('grants-management-modal')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Row actions — Revoke (arm-and-confirm pattern)
  // ---------------------------------------------------------------------------

  describe('row actions: Revoke (arm-and-confirm)', () => {
    it('shows Revoke button for non-terminal active peer when canManage=true', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getByTestId('revoke-peer-active-1')).toBeInTheDocument();
      });

      expect(screen.getByTestId('revoke-peer-active-1')).toHaveTextContent('Revoke');
    });

    it('hides Revoke button when canManage=false', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel({ canManage: false });

      await waitFor(() => {
        expect(screen.getByTestId('control-row-peer-active-1')).toBeInTheDocument();
      });

      expect(screen.queryByTestId('revoke-peer-active-1')).not.toBeInTheDocument();
    });

    it('hides Revoke button for revoked (terminal) peer', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_REVOKED]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getByTestId('control-row-peer-revoked-2')).toBeInTheDocument();
      });

      expect(screen.queryByTestId('revoke-peer-revoked-2')).not.toBeInTheDocument();
    });

    it('arms the revoke button on first click (shows "Confirm revoke")', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel({ canManage: true });

      const revokeBtn = await waitFor(() => screen.getByTestId('revoke-peer-active-1'));

      fireEvent.click(revokeBtn);

      await waitFor(() => {
        expect(screen.getByTestId('revoke-peer-active-1')).toHaveTextContent('Confirm revoke');
      });
    });

    it('shows reason input when armed', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));

      renderPanel({ canManage: true });

      const revokeBtn = await waitFor(() => screen.getByTestId('revoke-peer-active-1'));
      fireEvent.click(revokeBtn);

      await waitFor(() => {
        expect(screen.getByPlaceholderText('reason (optional)')).toBeInTheDocument();
      });
    });

    it('calls POST /system/platform/peers/:id/revoke with empty body on confirm without reason', async () => {
      // Both initial fetches return the active peer list
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      mockPost.mockResolvedValue(
        envelope({ peer: { ...PEER_ACTIVE, status: 'revoked' } }),
      );

      renderPanel({ canManage: true });

      const revokeBtn = await waitFor(() => screen.getByTestId('revoke-peer-active-1'));

      // First click — arm
      fireEvent.click(revokeBtn);
      await waitFor(() => {
        expect(screen.getByTestId('revoke-peer-active-1')).toHaveTextContent('Confirm revoke');
      });

      // Second click — confirm
      fireEvent.click(screen.getByTestId('revoke-peer-active-1'));

      await waitFor(() => {
        expect(mockPost).toHaveBeenCalledWith(
          '/system/platform/peers/peer-active-1/revoke',
          {},
        );
      });
    });

    it('calls POST /system/platform/peers/:id/revoke with reason body when reason is typed', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      mockPost.mockResolvedValue(
        envelope({ peer: { ...PEER_ACTIVE, status: 'revoked' } }),
      );

      renderPanel({ canManage: true });

      const revokeBtn = await waitFor(() => screen.getByTestId('revoke-peer-active-1'));

      // Arm
      fireEvent.click(revokeBtn);

      const reasonInput = await waitFor(() =>
        screen.getByPlaceholderText('reason (optional)'),
      );
      fireEvent.change(reasonInput, { target: { value: 'security incident' } });

      // Confirm
      fireEvent.click(screen.getByTestId('revoke-peer-active-1'));

      await waitFor(() => {
        expect(mockPost).toHaveBeenCalledWith(
          '/system/platform/peers/peer-active-1/revoke',
          { reason: 'security incident' },
        );
      });
    });

    it('shows success notification and refetches after successful revoke', async () => {
      // All fetches return the active peer (so the row stays rendered during the test)
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      mockPost.mockResolvedValue(
        envelope({ peer: { ...PEER_ACTIVE, status: 'revoked' } }),
      );

      renderPanel({ canManage: true });

      // Wait for mount fetches to settle (2 on mount)
      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));

      const revokeBtn = await waitFor(() => screen.getByTestId('revoke-peer-active-1'));

      fireEvent.click(revokeBtn);
      await waitFor(() => {
        expect(screen.getByTestId('revoke-peer-active-1')).toHaveTextContent('Confirm revoke');
      });
      fireEvent.click(screen.getByTestId('revoke-peer-active-1'));

      await waitFor(() => {
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('https://remote.example.com'),
          }),
        );
      });

      // A third GET call should happen after the successful revoke
      await waitFor(() => {
        expect(mockGet).toHaveBeenCalledTimes(3);
      });
    });

    it('shows error notification when revoke API call fails', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      mockPost.mockRejectedValue(new Error('Revoke failed: peer not found'));

      renderPanel({ canManage: true });

      const revokeBtn = await waitFor(() => screen.getByTestId('revoke-peer-active-1'));

      // Arm
      fireEvent.click(revokeBtn);
      await waitFor(() => {
        expect(screen.getByTestId('revoke-peer-active-1')).toHaveTextContent('Confirm revoke');
      });

      // Confirm
      fireEvent.click(screen.getByTestId('revoke-peer-active-1'));

      await waitFor(() => {
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: 'Revoke failed: peer not found',
          }),
        );
      });
    });

    it('shows "Revoking…" in button while revoke is in flight', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      // Never resolve so we catch the in-flight state
      mockPost.mockReturnValue(new Promise(() => {}));

      renderPanel({ canManage: true });

      const revokeBtn = await waitFor(() => screen.getByTestId('revoke-peer-active-1'));

      fireEvent.click(revokeBtn);
      await waitFor(() => {
        expect(screen.getByTestId('revoke-peer-active-1')).toHaveTextContent('Confirm revoke');
      });
      fireEvent.click(screen.getByTestId('revoke-peer-active-1'));

      await waitFor(() => {
        expect(screen.getByTestId('revoke-peer-active-1')).toHaveTextContent('Revoking…');
      });
    });

    it('disables revoke button while revoking after confirm', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      mockPost.mockReturnValue(new Promise(() => {}));

      renderPanel({ canManage: true });

      const revokeBtn = await waitFor(() => screen.getByTestId('revoke-peer-active-1'));

      // Arm
      fireEvent.click(revokeBtn);
      await waitFor(() =>
        screen.getByPlaceholderText('reason (optional)'),
      );

      // Confirm — armed flips to false (reason input unmounts), isRevoking flips to true
      fireEvent.click(screen.getByTestId('revoke-peer-active-1'));

      await waitFor(() => {
        expect(screen.getByTestId('revoke-peer-active-1')).toBeDisabled();
      });

      // Reason input is hidden once armed=false after confirm
      expect(screen.queryByPlaceholderText('reason (optional)')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Multiple peers — both management actions present for each
  // ---------------------------------------------------------------------------

  describe('multiple peers', () => {
    it('renders a row for each peer with correct testids', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE, PEER_REVOKED]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getByTestId('control-row-peer-active-1')).toBeInTheDocument();
        expect(screen.getByTestId('control-row-peer-revoked-2')).toBeInTheDocument();
      });
    });

    it('active peer has Revoke button; revoked peer does not', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE, PEER_REVOKED]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getByTestId('control-row-peer-active-1')).toBeInTheDocument();
      });

      expect(screen.getByTestId('revoke-peer-active-1')).toBeInTheDocument();
      expect(screen.queryByTestId('revoke-peer-revoked-2')).not.toBeInTheDocument();
    });

    it('only the correct peer detail drawer opens per row', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE, PEER_REVOKED]));

      renderPanel({ canManage: true });

      await waitFor(() => {
        expect(screen.getAllByTitle('View detail').length).toBe(2);
      });

      // Click the Detail button of the first row (PEER_ACTIVE)
      fireEvent.click(screen.getAllByTitle('View detail')[0]);

      const drawer = screen.getByTestId('peer-detail-drawer');
      expect(drawer).toHaveAttribute('data-peer-id', 'peer-active-1');
    });
  });
});
