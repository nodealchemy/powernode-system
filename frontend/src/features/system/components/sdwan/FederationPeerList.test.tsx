import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { FederationPeerList } from './FederationPeerList';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

let mockCanManage = true;
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (_perm: string) => mockCanManage,
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

/**
 * Double-envelope: apiClient.get resolves to an AxiosResponse whose .data is
 * the body `{ success: true, data: <payload> }`.
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

const PEER_PROPOSED = {
  id: 'fp-1',
  remote_instance_url: 'https://remote-a.example.com',
  remote_instance_id: 'ri-aabbccdd-1111-2222-3333-444455556666',
  remote_account_id: 'ra-0001',
  remote_prefix_advertisement: '10.200.0.0/24',
  status: 'proposed' as const,
  v1_allowed_transitions: ['accept', 'revoke'],
  signed_at: null,
  expires_at: null,
  has_trust_jwt: false,
  created_at: '2026-01-15T10:00:00Z',
};

const PEER_ACTIVE = {
  id: 'fp-2',
  remote_instance_url: 'https://remote-b.example.com',
  remote_instance_id: null,
  remote_account_id: null,
  remote_prefix_advertisement: null,
  status: 'active' as const,
  v1_allowed_transitions: ['suspend', 'revoke'],
  signed_at: '2026-02-01T08:00:00Z',
  expires_at: '2027-02-01T08:00:00Z',
  has_trust_jwt: true,
  created_at: '2026-02-01T07:00:00Z',
};

const PEER_REVOKED = {
  id: 'fp-3',
  remote_instance_url: 'https://remote-c.example.com',
  remote_instance_id: null,
  remote_account_id: null,
  remote_prefix_advertisement: null,
  status: 'revoked' as const,
  v1_allowed_transitions: [],
  signed_at: null,
  expires_at: null,
  has_trust_jwt: false,
  revocation_reason: 'remote signing key compromised',
  created_at: '2026-01-01T00:00:00Z',
};

function peersResponse(peers: unknown[]) {
  return envelope({ federation_peers: peers, count: peers.length });
}

// =============================================================================
// Tests
// =============================================================================

describe('FederationPeerList', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockCanManage = true;
  });

  // ── Loading state ──────────────────────────────────────────────────────────

  it('shows a loading indicator while fetching peers', () => {
    // Never resolves — keeps component in loading state.
    mockGet.mockReturnValue(new Promise(() => {}));
    render(<FederationPeerList />);
    expect(screen.getByText(/loading federation peers/i)).toBeInTheDocument();
  });

  // ── Error state ────────────────────────────────────────────────────────────

  it('shows an error message when the API call fails', async () => {
    mockGet.mockRejectedValue(new Error('Network error'));
    render(<FederationPeerList />);
    await waitFor(() =>
      expect(screen.getByText('Network error')).toBeInTheDocument(),
    );
  });

  // ── Empty state ────────────────────────────────────────────────────────────

  it('renders the empty state when there are no peers', async () => {
    mockGet.mockResolvedValue(peersResponse([]));
    render(<FederationPeerList />);
    await waitFor(() =>
      expect(screen.getByText('No federation peers')).toBeInTheDocument(),
    );
    expect(screen.getByText(/propose a federation peer/i)).toBeInTheDocument();
  });

  // ── List rendering ─────────────────────────────────────────────────────────

  it('fetches peers from the correct URL', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED]));
    render(<FederationPeerList />);
    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/sdwan/federation_peers'),
    );
  });

  it('renders the table with peer URLs and statuses', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED, PEER_ACTIVE]));
    render(<FederationPeerList />);

    await waitFor(() =>
      expect(
        screen.getByText('https://remote-a.example.com'),
      ).toBeInTheDocument(),
    );
    expect(screen.getByText('https://remote-b.example.com')).toBeInTheDocument();
    expect(screen.getByText('proposed')).toBeInTheDocument();
    expect(screen.getByText('active')).toBeInTheDocument();
  });

  it('renders the remote_prefix_advertisement column (or — when absent)', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED, PEER_ACTIVE]));
    render(<FederationPeerList />);

    await waitFor(() =>
      expect(screen.getByText('10.200.0.0/24')).toBeInTheDocument(),
    );
    // PEER_ACTIVE has null prefix — rendered as em-dash
    // There can be multiple dashes (signed/expires also uses —) so just confirm it's present
    expect(screen.getAllByText('—').length).toBeGreaterThan(0);
  });

  it('shows a truncated remote_instance_id in the table cell', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED]));
    render(<FederationPeerList />);

    // The component renders: id: <first 8 chars>… where first 8 of
    // 'ri-aabbccdd-...' = 'ri-aabbc'
    await waitFor(() =>
      expect(
        screen.getByText((content) => content.includes('id:') && content.includes('ri-aabbc')),
      ).toBeInTheDocument(),
    );
  });

  it('shows signed/expires dates when present', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_ACTIVE]));
    render(<FederationPeerList />);

    await waitFor(() =>
      expect(screen.getByText(/signed:/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/expires:/i)).toBeInTheDocument();
  });

  // ── Expand / collapse row ──────────────────────────────────────────────────

  it('expands a row to show detail when the chevron is clicked', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED]));
    render(<FederationPeerList />);

    await waitFor(() =>
      expect(
        screen.getByTitle('Expand details'),
      ).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Remote instance URL')).toBeInTheDocument(),
    );
    // Full URL repeated in detail panel
    expect(
      screen.getAllByText('https://remote-a.example.com').length,
    ).toBeGreaterThan(1);
  });

  it('collapses an expanded row when the chevron is clicked again', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED]));
    render(<FederationPeerList />);

    await waitFor(() =>
      expect(screen.getByTitle('Expand details')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Expand details'));
    await waitFor(() =>
      expect(screen.getByText('Remote instance URL')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() =>
      expect(screen.queryByText('Remote instance URL')).not.toBeInTheDocument(),
    );
  });

  it('shows has_trust_jwt as "present" / "none" in the expanded detail', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_ACTIVE, PEER_PROPOSED]));
    render(<FederationPeerList />);

    // Expand PEER_ACTIVE (has_trust_jwt: true)
    const expandButtons = await waitFor(() =>
      screen.getAllByTitle('Expand details'),
    );
    fireEvent.click(expandButtons[0]); // PEER_ACTIVE

    await waitFor(() =>
      expect(screen.getByText('present')).toBeInTheDocument(),
    );

    // Collapse PEER_ACTIVE, expand PEER_PROPOSED (has_trust_jwt: false)
    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() =>
      expect(screen.queryByText('present')).not.toBeInTheDocument(),
    );
    fireEvent.click(screen.getAllByTitle('Expand details')[1]);
    await waitFor(() =>
      expect(screen.getByText('none')).toBeInTheDocument(),
    );
  });

  it('shows allowed transitions in the expanded panel', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED]));
    render(<FederationPeerList />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('accept')).toBeInTheDocument(),
    );
    expect(screen.getByText('revoke')).toBeInTheDocument();
  });

  // ── Permission gating ──────────────────────────────────────────────────────

  it('hides action buttons when the user lacks sdwan.federation.manage', async () => {
    mockCanManage = false;
    mockGet.mockResolvedValue(peersResponse([PEER_ACTIVE]));
    render(<FederationPeerList />);

    await waitFor(() =>
      expect(
        screen.getByText('https://remote-b.example.com'),
      ).toBeInTheDocument(),
    );
    expect(
      screen.queryByLabelText(/revoke peer/i),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByLabelText(/delete peer/i),
    ).not.toBeInTheDocument();
  });

  it('hides the Revoke button for already-revoked peers', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_REVOKED]));
    render(<FederationPeerList />);

    await waitFor(() =>
      expect(
        screen.getByText('https://remote-c.example.com'),
      ).toBeInTheDocument(),
    );
    // Delete button still present, Revoke button absent
    expect(
      screen.getByLabelText(/delete peer https:\/\/remote-c\.example\.com/i),
    ).toBeInTheDocument();
    expect(
      screen.queryByLabelText(/revoke peer https:\/\/remote-c\.example\.com/i),
    ).not.toBeInTheDocument();
  });

  // ── Revocation reason display ────────────────────────────────────────────

  it('shows the revocation reason inline for a revoked peer', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_REVOKED]));
    render(<FederationPeerList />);

    await waitFor(() =>
      expect(
        screen.getByText(/remote signing key compromised/i),
      ).toBeInTheDocument(),
    );
  });

  it('shows the revocation reason in the expanded detail panel', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_REVOKED]));
    render(<FederationPeerList />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Revocation reason')).toBeInTheDocument(),
    );
    // The reason text now appears twice: the inline row hint + the detail panel.
    expect(
      screen.getAllByText(/remote signing key compromised/i).length,
    ).toBeGreaterThan(0);
  });

  it('does not show a revocation reason section for a non-revoked peer', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_ACTIVE]));
    render(<FederationPeerList />);

    fireEvent.click(await waitFor(() => screen.getByTitle('Expand details')));
    await waitFor(() =>
      expect(screen.getByText('Trust JWT')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Revocation reason')).not.toBeInTheDocument();
  });

  // ── Revoke flow ────────────────────────────────────────────────────────────

  it('opens the revoke confirm modal when the Revoke button is clicked', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED]));
    render(<FederationPeerList />);

    await waitFor(() =>
      expect(
        screen.getByLabelText(
          'Revoke peer https://remote-a.example.com',
        ),
      ).toBeInTheDocument(),
    );
    fireEvent.click(
      screen.getByLabelText('Revoke peer https://remote-a.example.com'),
    );

    await waitFor(() =>
      expect(
        screen.getByText('Revoke federation peer'),
      ).toBeInTheDocument(),
    );
    // The modal body text confirms context
    expect(
      screen.getByText(/the row stays for audit/i),
    ).toBeInTheDocument();
  });

  it('calls revokeFederationPeer with correct ID and shows success notification', async () => {
    // First call: initial load; second call: after local refresh post-revoke
    mockGet
      .mockResolvedValueOnce(peersResponse([PEER_PROPOSED]))
      .mockResolvedValueOnce(peersResponse([]));
    mockPost.mockResolvedValue(
      envelope({ federation_peer: { ...PEER_PROPOSED, status: 'revoked' } }),
    );

    render(<FederationPeerList />);

    fireEvent.click(
      await waitFor(() =>
        screen.getByLabelText('Revoke peer https://remote-a.example.com'),
      ),
    );
    await waitFor(() =>
      expect(screen.getByText('Revoke federation peer')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /^revoke$/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/sdwan/federation_peers/fp-1/revoke',
        { reason: undefined },
      ),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: 'Peer revoked' }),
      ),
    );
  });

  it('collects an optional reason and sends it with the revoke request', async () => {
    mockGet
      .mockResolvedValueOnce(peersResponse([PEER_PROPOSED]))
      .mockResolvedValueOnce(peersResponse([]));
    mockPost.mockResolvedValue(
      envelope({ federation_peer: { ...PEER_PROPOSED, status: 'revoked', revocation_reason: 'remote signing key compromised' } }),
    );

    render(<FederationPeerList />);

    fireEvent.click(
      await waitFor(() =>
        screen.getByLabelText('Revoke peer https://remote-a.example.com'),
      ),
    );
    await waitFor(() =>
      expect(screen.getByText('Revoke federation peer')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/reason \(optional\)/i), {
      target: { value: 'remote signing key compromised' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^revoke$/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/sdwan/federation_peers/fp-1/revoke',
        { reason: 'remote signing key compromised' },
      ),
    );
  });

  it('resets the reason field between separate revoke attempts', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED]));
    render(<FederationPeerList />);

    fireEvent.click(
      await waitFor(() =>
        screen.getByLabelText('Revoke peer https://remote-a.example.com'),
      ),
    );
    const reasonInput = await waitFor(() => screen.getByLabelText(/reason \(optional\)/i));
    fireEvent.change(reasonInput, { target: { value: 'draft reason' } });
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText('Revoke federation peer')).not.toBeInTheDocument(),
    );

    fireEvent.click(
      screen.getByLabelText('Revoke peer https://remote-a.example.com'),
    );
    await waitFor(() =>
      expect(screen.getByLabelText(/reason \(optional\)/i)).toHaveValue(''),
    );
  });

  it('shows an error notification when the revoke API call fails', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED]));
    mockPost.mockRejectedValue(new Error('Revoke failed'));

    render(<FederationPeerList />);

    fireEvent.click(
      await waitFor(() =>
        screen.getByLabelText('Revoke peer https://remote-a.example.com'),
      ),
    );
    await waitFor(() =>
      expect(screen.getByText('Revoke federation peer')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /^revoke$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Revoke failed' }),
      ),
    );
  });

  it('closes the revoke modal when Cancel is clicked', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED]));
    render(<FederationPeerList />);

    fireEvent.click(
      await waitFor(() =>
        screen.getByLabelText('Revoke peer https://remote-a.example.com'),
      ),
    );
    await waitFor(() =>
      expect(screen.getByText('Revoke federation peer')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(
        screen.queryByText('The row stays for audit'),
      ).not.toBeInTheDocument(),
    );
  });

  // ── Delete flow ────────────────────────────────────────────────────────────

  it('opens the delete confirm modal when the Delete button is clicked', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_ACTIVE]));
    render(<FederationPeerList />);

    await waitFor(() =>
      expect(
        screen.getByLabelText(
          'Delete peer https://remote-b.example.com',
        ),
      ).toBeInTheDocument(),
    );
    fireEvent.click(
      screen.getByLabelText('Delete peer https://remote-b.example.com'),
    );

    await waitFor(() =>
      expect(
        screen.getByText('Delete federation peer'),
      ).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/hard-deletes the row/i),
    ).toBeInTheDocument();
  });

  it('calls deleteFederationPeer with correct ID and shows success notification', async () => {
    // First call: initial load; second call: after local refresh post-delete
    mockGet
      .mockResolvedValueOnce(peersResponse([PEER_ACTIVE]))
      .mockResolvedValueOnce(peersResponse([]));
    mockDelete.mockResolvedValue({ data: { success: true } });

    render(<FederationPeerList />);

    fireEvent.click(
      await waitFor(() =>
        screen.getByLabelText('Delete peer https://remote-b.example.com'),
      ),
    );
    await waitFor(() =>
      expect(screen.getByText('Delete federation peer')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith(
        '/system/sdwan/federation_peers/fp-2',
      ),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: 'Peer deleted' }),
      ),
    );
  });

  it('shows an error notification when the delete API call fails', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_ACTIVE]));
    mockDelete.mockRejectedValue(new Error('Delete failed'));

    render(<FederationPeerList />);

    fireEvent.click(
      await waitFor(() =>
        screen.getByLabelText('Delete peer https://remote-b.example.com'),
      ),
    );
    await waitFor(() =>
      expect(screen.getByText('Delete federation peer')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Delete failed' }),
      ),
    );
  });

  it('closes the delete modal when Cancel is clicked', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_ACTIVE]));
    render(<FederationPeerList />);

    fireEvent.click(
      await waitFor(() =>
        screen.getByLabelText('Delete peer https://remote-b.example.com'),
      ),
    );
    await waitFor(() =>
      expect(screen.getByText('Delete federation peer')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(
        screen.queryByText(/hard-deletes the row/i),
      ).not.toBeInTheDocument(),
    );
  });

  // ── refreshKey prop ────────────────────────────────────────────────────────

  it('re-fetches peers when refreshKey changes', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED]));
    const { rerender } = render(<FederationPeerList refreshKey={0} />);
    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));

    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED, PEER_ACTIVE]));
    rerender(<FederationPeerList refreshKey={1} />);
    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
  });

  // ── Multiple peers, independent expansion ──────────────────────────────────

  it('allows multiple rows to be expanded simultaneously', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_PROPOSED, PEER_ACTIVE]));
    render(<FederationPeerList />);

    const expandButtons = await waitFor(() =>
      screen.getAllByTitle('Expand details'),
    );
    expect(expandButtons).toHaveLength(2);

    // Expand both
    fireEvent.click(expandButtons[0]);
    fireEvent.click(expandButtons[1]);

    // Both detail panels visible (each has "Remote instance URL" label)
    await waitFor(() =>
      expect(
        screen.getAllByText('Remote instance URL').length,
      ).toBe(2),
    );
  });
});
