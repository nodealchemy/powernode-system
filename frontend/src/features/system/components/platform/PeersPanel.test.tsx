import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PeersPanel } from './PeersPanel';
import type { PlatformPeerSummary } from '../../types/peer.types';

// =============================================================================
// Mocks
//
// PeersPanel uses:
//   - usePlatformPeers hook  →  platformPeersApi.listPeers  →  apiClient.get
//   - platformPeersApi.revoke  →  apiClient.post (called directly in handleRevoke)
//   - useNotifications
//   - window.prompt (for the revoke reason dialog)
//   - InvitePeerModal, PeerDetailDrawer (child modals — stubbed)
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

// Stub InvitePeerModal so it doesn't run its own API calls.
// Expose a testid and a way to trigger onInvited so we can assert refetch.
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
        <button type="button" onClick={onClose} data-testid="invite-modal-close">
          Close
        </button>
        <button type="button" onClick={() => onInvited?.()} data-testid="invite-modal-invited">
          Invited
        </button>
      </div>
    ) : null,
}));

// Stub PeerDetailDrawer so it doesn't run its own API calls.
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
        <button type="button" onClick={onClose} data-testid="detail-drawer-close">
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

function peersListResponse(peers: PlatformPeerSummary[]) {
  return envelope({ peers, count: peers.length });
}

const PEER_ACTIVE: PlatformPeerSummary = {
  id: 'peer-active-1',
  remote_instance_url: 'https://alpha.example.com',
  remote_instance_id: 'rid-001',
  peer_kind: 'platform',
  spawn_role: 'symmetric',
  spawn_mode: 'out_of_band',
  status: 'active',
  created_at: '2026-01-01T00:00:00Z',
  last_heartbeat_at: '2026-06-01T12:00:00Z',
  last_handshake_at: '2026-05-01T12:00:00Z',
  endpoints_count: 3,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

const PEER_PROPOSED: PlatformPeerSummary = {
  id: 'peer-proposed-2',
  remote_instance_url: 'https://beta.example.com',
  remote_instance_id: null,
  peer_kind: 'platform',
  spawn_role: 'child',
  spawn_mode: 'managed_child',
  status: 'proposed',
  created_at: '2026-03-01T00:00:00Z',
  last_heartbeat_at: null,
  last_handshake_at: null,
  endpoints_count: 1,
  acceptance_pending: true,
  acceptance_expires_at: '2026-06-12T00:00:00Z',
};

const PEER_REVOKED: PlatformPeerSummary = {
  id: 'peer-revoked-3',
  remote_instance_url: 'https://old.example.com',
  remote_instance_id: 'rid-003',
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

const PEER_NO_ROLE: PlatformPeerSummary = {
  id: 'peer-norole-4',
  remote_instance_url: 'https://norole.example.com',
  remote_instance_id: null,
  peer_kind: 'platform',
  spawn_role: null,
  spawn_mode: null,
  status: 'enrolled',
  created_at: '2026-04-01T00:00:00Z',
  last_heartbeat_at: null,
  last_handshake_at: null,
  endpoints_count: 0,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

// =============================================================================
// Helpers
// =============================================================================

function renderPanel() {
  return render(
    <BrowserRouter>
      <PeersPanel />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PeersPanel', () => {
  let promptSpy: jest.SpyInstance;

  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockAddNotification.mockReset();
    promptSpy = jest.spyOn(window, 'prompt');
  });

  afterEach(() => {
    promptSpy.mockRestore();
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  describe('render states', () => {
    it('renders the panel header with the Peers title', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      expect(screen.getByText('Peers')).toBeInTheDocument();
    });

    it('shows "loading…" while the fetch is in flight', () => {
      // Never resolves — keeps the component in loading state
      mockGet.mockReturnValue(new Promise(() => {}));
      renderPanel();
      expect(screen.getByText('loading…')).toBeInTheDocument();
    });

    it('shows empty-state message when no peers exist', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() =>
        expect(
          screen.getByText(/No federation peers yet/),
        ).toBeInTheDocument(),
      );
      expect(screen.getByText(/Click "Invite Peer" to propose one/)).toBeInTheDocument();
    });

    it('renders peer rows when peers are returned', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE, PEER_PROPOSED]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://alpha.example.com')).toBeInTheDocument(),
      );
      expect(screen.getByText('https://beta.example.com')).toBeInTheDocument();
    });

    it('does not show the empty-state when peers exist', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://alpha.example.com')).toBeInTheDocument(),
      );
      expect(
        screen.queryByText(/No federation peers yet/),
      ).not.toBeInTheDocument();
    });

    it('shows error banner when the API call fails', async () => {
      mockGet.mockRejectedValue(new Error('Connection refused'));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('Connection refused')).toBeInTheDocument(),
      );
    });

    it('dismisses the error banner when the X button inside it is clicked', async () => {
      mockGet.mockRejectedValue(new Error('Connection refused'));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('Connection refused')).toBeInTheDocument(),
      );
      const errorBanner = screen.getByText('Connection refused').closest('div')!;
      const closeBtn = errorBanner.querySelector('button[type="button"]')!;
      fireEvent.click(closeBtn);
      await waitFor(() =>
        expect(screen.queryByText('Connection refused')).not.toBeInTheDocument(),
      );
    });

    it('does not show the empty-state when there is an active error', async () => {
      mockGet.mockRejectedValue(new Error('fail'));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('fail')).toBeInTheDocument(),
      );
      expect(
        screen.queryByText(/No federation peers yet/),
      ).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Peer count label
  // ---------------------------------------------------------------------------

  describe('peer count label', () => {
    it('shows "0 peers" when list is empty', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() => expect(screen.getByText('0 peers')).toBeInTheDocument());
    });

    it('shows "1 peer" (singular) when there is exactly one peer', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      renderPanel();
      await waitFor(() => expect(screen.getByText('1 peer')).toBeInTheDocument());
    });

    it('shows "2 peers" (plural) when there are two peers', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE, PEER_PROPOSED]));
      renderPanel();
      await waitFor(() => expect(screen.getByText('2 peers')).toBeInTheDocument());
    });
  });

  // ---------------------------------------------------------------------------
  // API calls
  // ---------------------------------------------------------------------------

  describe('API calls', () => {
    it('calls GET /system/platform/peers on mount with no filters', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() =>
        expect(mockGet).toHaveBeenCalledWith(
          '/system/platform/peers',
          expect.objectContaining({ params: {} }),
        ),
      );
    });

    it('refetches when the Refresh button is clicked', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));

      fireEvent.click(screen.getByTitle('Refresh'));

      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
    });

    it('disables the Refresh button while loading', () => {
      mockGet.mockReturnValue(new Promise(() => {}));
      renderPanel();
      expect(screen.getByTitle('Refresh')).toBeDisabled();
    });
  });

  // ---------------------------------------------------------------------------
  // Column headers
  // ---------------------------------------------------------------------------

  describe('column headers', () => {
    it('renders all expected column headers when peers exist', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://alpha.example.com')).toBeInTheDocument(),
      );
      expect(screen.getByText('Remote URL')).toBeInTheDocument();
      expect(screen.getByText('Role')).toBeInTheDocument();
      expect(screen.getByText('Mode')).toBeInTheDocument();
      expect(screen.getByText('Status')).toBeInTheDocument();
      expect(screen.getByText('Endpoints')).toBeInTheDocument();
      expect(screen.getByText('Last Heartbeat')).toBeInTheDocument();
      expect(screen.getByText('Actions')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Role and Mode badges
  // ---------------------------------------------------------------------------

  describe('role and mode badges', () => {
    it('renders the role badge for a peer with a spawn_role', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://alpha.example.com')).toBeInTheDocument(),
      );
      expect(screen.getByText('symmetric')).toBeInTheDocument();
    });

    it('renders the mode badge for a peer with a spawn_mode', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://alpha.example.com')).toBeInTheDocument(),
      );
      expect(screen.getByText('out-of-band')).toBeInTheDocument();
    });

    it('renders "—" placeholder when spawn_role is null', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_NO_ROLE]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://norole.example.com')).toBeInTheDocument(),
      );
      // Two "—" spans for role and mode
      const dashes = screen.getAllByText('—');
      expect(dashes.length).toBeGreaterThanOrEqual(2);
    });

    it('renders "managed" for managed_child mode', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_PROPOSED]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://beta.example.com')).toBeInTheDocument(),
      );
      expect(screen.getByText('managed')).toBeInTheDocument();
    });

    it('renders the endpoints count in the row', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://alpha.example.com')).toBeInTheDocument(),
      );
      // PEER_ACTIVE.endpoints_count = 3
      expect(screen.getByText('3')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Status filter bar
  // ---------------------------------------------------------------------------

  describe('status filter bar', () => {
    it('renders all status filter buttons', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() => expect(screen.getByText('0 peers')).toBeInTheDocument());

      for (const label of [
        'All', 'Proposed', 'Accepted', 'Enrolled',
        'Active', 'Degraded', 'Suspended', 'Revoked',
      ]) {
        expect(screen.getByRole('button', { name: label })).toBeInTheDocument();
      }
    });

    it('applies the status filter when a filter button is clicked', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));

      fireEvent.click(screen.getByRole('button', { name: 'Active' }));

      await waitFor(() =>
        expect(mockGet).toHaveBeenCalledWith(
          '/system/platform/peers',
          expect.objectContaining({ params: { status: 'active' } }),
        ),
      );
    });

    it('clears the filter when "All" is clicked after a filter was set', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));

      // Set a filter first
      fireEvent.click(screen.getByRole('button', { name: 'Active' }));
      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));

      // Clear the filter
      fireEvent.click(screen.getByRole('button', { name: 'All' }));

      await waitFor(() =>
        expect(mockGet).toHaveBeenCalledWith(
          '/system/platform/peers',
          expect.objectContaining({ params: {} }),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Invite Peer modal
  // ---------------------------------------------------------------------------

  describe('Invite Peer modal', () => {
    it('renders the "Invite Peer" button', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /invite peer/i })).toBeInTheDocument(),
      );
    });

    it('opens InvitePeerModal when "Invite Peer" is clicked', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /invite peer/i })).toBeInTheDocument(),
      );
      fireEvent.click(screen.getByRole('button', { name: /invite peer/i }));
      expect(screen.getByTestId('invite-peer-modal')).toBeInTheDocument();
    });

    it('closes InvitePeerModal when onClose is triggered', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /invite peer/i })).toBeInTheDocument(),
      );
      fireEvent.click(screen.getByRole('button', { name: /invite peer/i }));
      expect(screen.getByTestId('invite-peer-modal')).toBeInTheDocument();

      fireEvent.click(screen.getByTestId('invite-modal-close'));
      expect(screen.queryByTestId('invite-peer-modal')).not.toBeInTheDocument();
    });

    it('triggers a refetch when onInvited fires from the modal', async () => {
      mockGet.mockResolvedValue(peersListResponse([]));
      renderPanel();
      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));

      fireEvent.click(screen.getByRole('button', { name: /invite peer/i }));
      fireEvent.click(screen.getByTestId('invite-modal-invited'));

      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
    });
  });

  // ---------------------------------------------------------------------------
  // PeerDetailDrawer — open on row click
  // ---------------------------------------------------------------------------

  describe('PeerDetailDrawer', () => {
    it('opens PeerDetailDrawer with the correct peerId when a row is clicked', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://alpha.example.com')).toBeInTheDocument(),
      );

      // Click the row (the <tr> itself)
      fireEvent.click(screen.getByText('https://alpha.example.com'));

      const drawer = screen.getByTestId('peer-detail-drawer');
      expect(drawer).toBeInTheDocument();
      expect(drawer).toHaveAttribute('data-peer-id', 'peer-active-1');
    });

    it('closes PeerDetailDrawer when its onClose fires', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://alpha.example.com')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByText('https://alpha.example.com'));
      expect(screen.getByTestId('peer-detail-drawer')).toBeInTheDocument();

      fireEvent.click(screen.getByTestId('detail-drawer-close'));
      expect(screen.queryByTestId('peer-detail-drawer')).not.toBeInTheDocument();
    });

    it('opens the drawer for the correct peer when multiple peers are shown', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE, PEER_PROPOSED]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://beta.example.com')).toBeInTheDocument(),
      );

      // Click the second peer's URL
      fireEvent.click(screen.getByText('https://beta.example.com'));

      const drawer = screen.getByTestId('peer-detail-drawer');
      expect(drawer).toHaveAttribute('data-peer-id', 'peer-proposed-2');
    });
  });

  // ---------------------------------------------------------------------------
  // Revoke action
  // ---------------------------------------------------------------------------

  describe('revoke action', () => {
    it('shows the Revoke button for a non-terminal (active) peer', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://alpha.example.com')).toBeInTheDocument(),
      );
      expect(screen.getByTitle('Revoke peer')).toBeInTheDocument();
      expect(screen.getByTitle('Revoke peer')).toHaveTextContent('Revoke');
    });

    it('hides the Revoke button for a revoked (terminal) peer', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_REVOKED]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://old.example.com')).toBeInTheDocument(),
      );
      expect(screen.queryByTitle('Revoke peer')).not.toBeInTheDocument();
    });

    it('shows Revoke for active and hides it for revoked when both peers are listed', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE, PEER_REVOKED]));
      renderPanel();
      await waitFor(() =>
        expect(screen.getByText('https://old.example.com')).toBeInTheDocument(),
      );
      // Only one Revoke button — for the active peer
      expect(screen.getAllByTitle('Revoke peer').length).toBe(1);
    });

    it('calls window.prompt with the peer URL when Revoke is clicked', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      promptSpy.mockReturnValue(null); // operator cancels
      renderPanel();
      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByTitle('Revoke peer'));

      expect(promptSpy).toHaveBeenCalledWith(
        expect.stringContaining('https://alpha.example.com'),
        '',
      );
    });

    it('does NOT call the API when the operator cancels the prompt (returns null)', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      promptSpy.mockReturnValue(null);
      renderPanel();
      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByTitle('Revoke peer'));

      // Give any async activity a tick to settle
      await new Promise((r) => setTimeout(r, 0));
      expect(mockPost).not.toHaveBeenCalled();
    });

    it('calls POST /system/platform/peers/:id/revoke with empty body when reason is blank', async () => {
      mockGet
        .mockResolvedValueOnce(peersListResponse([PEER_ACTIVE]))
        .mockResolvedValueOnce(peersListResponse([]));
      mockPost.mockResolvedValue(
        envelope({ peer: { ...PEER_ACTIVE, status: 'revoked' } }),
      );
      promptSpy.mockReturnValue(''); // operator submits empty reason

      renderPanel();
      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByTitle('Revoke peer'));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          '/system/platform/peers/peer-active-1/revoke',
          {},
        ),
      );
    });

    it('calls POST /system/platform/peers/:id/revoke with reason body when reason is provided', async () => {
      mockGet
        .mockResolvedValueOnce(peersListResponse([PEER_ACTIVE]))
        .mockResolvedValueOnce(peersListResponse([]));
      mockPost.mockResolvedValue(
        envelope({ peer: { ...PEER_ACTIVE, status: 'revoked' } }),
      );
      promptSpy.mockReturnValue('security incident');

      renderPanel();
      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByTitle('Revoke peer'));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          '/system/platform/peers/peer-active-1/revoke',
          { reason: 'security incident' },
        ),
      );
    });

    it('shows a success notification and refetches after a successful revoke', async () => {
      mockGet
        .mockResolvedValueOnce(peersListResponse([PEER_ACTIVE]))
        .mockResolvedValueOnce(peersListResponse([]));
      mockPost.mockResolvedValue(
        envelope({ peer: { ...PEER_ACTIVE, status: 'revoked' } }),
      );
      promptSpy.mockReturnValue('');

      renderPanel();
      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByTitle('Revoke peer'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('https://alpha.example.com'),
          }),
        ),
      );

      // refetch called → second GET
      await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
    });

    it('shows an error notification when the revoke API call fails', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      mockPost.mockRejectedValue(new Error('Revoke failed: unauthorized'));
      promptSpy.mockReturnValue('');

      renderPanel();
      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByTitle('Revoke peer'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: 'Revoke failed: unauthorized',
          }),
        ),
      );
    });

    it('shows a fallback error message for non-Error revoke rejections', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      mockPost.mockRejectedValue('unexpected');
      promptSpy.mockReturnValue('');

      renderPanel();
      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByTitle('Revoke peer'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: 'Failed to revoke peer',
          }),
        ),
      );
    });

    it('shows "Revoking…" in the button while the API call is in flight', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      // Never resolves — holds the loading state
      mockPost.mockReturnValue(new Promise(() => {}));
      promptSpy.mockReturnValue('');

      renderPanel();
      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByTitle('Revoke peer'));

      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toHaveTextContent('Revoking…'),
      );
    });

    it('disables the Revoke button while the API call is in flight', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      mockPost.mockReturnValue(new Promise(() => {}));
      promptSpy.mockReturnValue('');

      renderPanel();
      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByTitle('Revoke peer'));

      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeDisabled(),
      );
    });

    it('revoke action cell click does not propagate to the row (drawer does not open)', async () => {
      mockGet.mockResolvedValue(peersListResponse([PEER_ACTIVE]));
      promptSpy.mockReturnValue(null); // cancel prompt immediately

      renderPanel();
      await waitFor(() =>
        expect(screen.getByTitle('Revoke peer')).toBeInTheDocument(),
      );

      // Click the Revoke button (stopPropagation should prevent row click)
      fireEvent.click(screen.getByTitle('Revoke peer'));

      // PeerDetailDrawer should NOT open
      expect(screen.queryByTestId('peer-detail-drawer')).not.toBeInTheDocument();
    });
  });
});
