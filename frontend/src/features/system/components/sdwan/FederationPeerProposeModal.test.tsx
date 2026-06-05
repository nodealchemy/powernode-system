import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { FederationPeerProposeModal } from './FederationPeerProposeModal';

// =============================================================================
// Mocks
// =============================================================================

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

const mockProposeFederationPeer = jest.fn();
jest.mock('../../services/api/sdwanApi', () => ({
  sdwanApi: {
    proposeFederationPeer: (...args: unknown[]) => mockProposeFederationPeer(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Wrap an API payload in the standard double-envelope shape. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const PEER_FIXTURE = {
  id: 'peer-abc',
  remote_instance_url: 'https://other.powernode.example.org',
  remote_instance_id: '019d-1234-5678',
  remote_account_id: 'acc-5678',
  remote_prefix_advertisement: 'fdab:cdef:1234::/48',
  status: 'proposed' as const,
  created_at: '2026-06-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

interface RenderOptions {
  isOpen?: boolean;
  onClose?: jest.Mock;
  onProposed?: jest.Mock;
}

function renderModal(options: RenderOptions = {}) {
  const {
    isOpen = true,
    onClose = jest.fn(),
    onProposed = jest.fn(),
  } = options;

  return render(
    <FederationPeerProposeModal
      isOpen={isOpen}
      onClose={onClose}
      onProposed={onProposed}
    />,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('FederationPeerProposeModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockProposeFederationPeer.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render / closed state
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Propose federation peer')).not.toBeInTheDocument();
  });

  it('renders the modal title and all fields when open', () => {
    renderModal();
    expect(screen.getByText('Propose federation peer')).toBeInTheDocument();
    expect(screen.getByLabelText(/remote instance url/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/remote instance id/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/remote account id/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/remote prefix advertisement/i)).toBeInTheDocument();
  });

  it('renders the v1 informational notice', () => {
    renderModal();
    expect(
      screen.getByText(/v1 stores the proposal as data only/i),
    ).toBeInTheDocument();
  });

  it('renders the ULA helper text beneath the prefix field', () => {
    renderModal();
    expect(screen.getByText(/\/48, \/56, or \/64 ULA prefix/i)).toBeInTheDocument();
  });

  it('marks the URL field as required', () => {
    renderModal();
    const urlInput = screen.getByLabelText(/remote instance url/i);
    expect(urlInput).toBeRequired();
  });

  it('marks optional fields as not required', () => {
    renderModal();
    expect(screen.getByLabelText(/remote instance id/i)).not.toBeRequired();
    expect(screen.getByLabelText(/remote account id/i)).not.toBeRequired();
    expect(screen.getByLabelText(/remote prefix advertisement/i)).not.toBeRequired();
  });

  it('disables the Propose button when URL field is empty', () => {
    renderModal();
    expect(screen.getByRole('button', { name: /^propose$/i })).toBeDisabled();
  });

  it('enables the Propose button once URL is entered', async () => {
    renderModal();
    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^propose$/i })).not.toBeDisabled(),
    );
  });

  // ---------------------------------------------------------------------------
  // Validation — empty URL
  // ---------------------------------------------------------------------------

  it('shows an error notification when submitting with an empty URL', async () => {
    renderModal();
    // Trigger via form submit so the required check fires (no URL typed)
    fireEvent.submit(screen.getByRole('button', { name: /^propose$/i }).closest('form')!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Remote instance URL is required',
      }),
    );
    expect(mockProposeFederationPeer).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Successful submission — all fields filled
  // ---------------------------------------------------------------------------

  it('calls proposeFederationPeer with the correct payload on success', async () => {
    const onClose = jest.fn();
    const onProposed = jest.fn();
    mockProposeFederationPeer.mockResolvedValue(envelope({ federation_peer: PEER_FIXTURE }));

    renderModal({ onClose, onProposed });

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.change(screen.getByLabelText(/remote instance id/i), {
      target: { value: '019d-1234-5678' },
    });
    fireEvent.change(screen.getByLabelText(/remote account id/i), {
      target: { value: 'acc-5678' },
    });
    fireEvent.change(screen.getByLabelText(/remote prefix advertisement/i), {
      target: { value: 'fdab:cdef:1234::/48' },
    });

    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() =>
      expect(mockProposeFederationPeer).toHaveBeenCalledWith({
        remote_instance_url: 'https://other.powernode.example.org',
        remote_instance_id: '019d-1234-5678',
        remote_account_id: 'acc-5678',
        remote_prefix_advertisement: 'fdab:cdef:1234::/48',
      }),
    );
  });

  it('shows a success notification after proposing', async () => {
    mockProposeFederationPeer.mockResolvedValue(envelope({ federation_peer: PEER_FIXTURE }));
    renderModal();

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Federation peer proposed',
      }),
    );
  });

  it('calls onProposed and onClose after a successful submission', async () => {
    const onClose = jest.fn();
    const onProposed = jest.fn();
    mockProposeFederationPeer.mockResolvedValue(envelope({ federation_peer: PEER_FIXTURE }));

    renderModal({ onClose, onProposed });

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() => expect(onProposed).toHaveBeenCalledTimes(1));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Successful submission — optional fields omitted (undefined, not empty string)
  // ---------------------------------------------------------------------------

  it('omits empty optional fields from the payload (sends undefined, not empty string)', async () => {
    mockProposeFederationPeer.mockResolvedValue(envelope({ federation_peer: PEER_FIXTURE }));
    renderModal();

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    // Leave instance ID, account ID, and prefix blank

    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() =>
      expect(mockProposeFederationPeer).toHaveBeenCalledWith({
        remote_instance_url: 'https://other.powernode.example.org',
        remote_instance_id: undefined,
        remote_account_id: undefined,
        remote_prefix_advertisement: undefined,
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Submission — whitespace trimming
  // ---------------------------------------------------------------------------

  it('trims whitespace from the URL before sending', async () => {
    mockProposeFederationPeer.mockResolvedValue(envelope({ federation_peer: PEER_FIXTURE }));
    renderModal();

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: '  https://other.powernode.example.org  ' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() =>
      expect(mockProposeFederationPeer).toHaveBeenCalledWith(
        expect.objectContaining({
          remote_instance_url: 'https://other.powernode.example.org',
        }),
      ),
    );
  });

  it('treats whitespace-only optional fields as undefined', async () => {
    mockProposeFederationPeer.mockResolvedValue(envelope({ federation_peer: PEER_FIXTURE }));
    renderModal();

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.change(screen.getByLabelText(/remote instance id/i), {
      target: { value: '   ' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() =>
      expect(mockProposeFederationPeer).toHaveBeenCalledWith(
        expect.objectContaining({
          remote_instance_id: undefined,
        }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Loading state during submission
  // ---------------------------------------------------------------------------

  it('shows "Proposing…" and disables buttons while submitting', async () => {
    let resolvePropose!: (v: unknown) => void;
    mockProposeFederationPeer.mockReturnValue(new Promise((res) => { resolvePropose = res; }));

    renderModal();

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /proposing…/i })).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: /proposing…/i })).toBeDisabled();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();

    // Release the promise so the component can clean up
    resolvePropose(envelope({ federation_peer: PEER_FIXTURE }));
    await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
  });

  it('disables form inputs while submitting', async () => {
    let resolvePropose!: (v: unknown) => void;
    mockProposeFederationPeer.mockReturnValue(new Promise((res) => { resolvePropose = res; }));

    renderModal();

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /proposing…/i })).toBeInTheDocument(),
    );

    expect(screen.getByLabelText(/remote instance url/i)).toBeDisabled();
    expect(screen.getByLabelText(/remote instance id/i)).toBeDisabled();
    expect(screen.getByLabelText(/remote account id/i)).toBeDisabled();
    expect(screen.getByLabelText(/remote prefix advertisement/i)).toBeDisabled();

    resolvePropose(envelope({ federation_peer: PEER_FIXTURE }));
    await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  it('shows an error notification when the API call fails with an Error', async () => {
    mockProposeFederationPeer.mockRejectedValue(new Error('Network error'));
    renderModal();

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network error',
      }),
    );
  });

  it('shows a generic "Failed" error when a non-Error is thrown', async () => {
    mockProposeFederationPeer.mockRejectedValue('something went wrong');
    renderModal();

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed',
      }),
    );
  });

  it('re-enables the Propose button after a failed submission', async () => {
    mockProposeFederationPeer.mockRejectedValue(new Error('Conflict'));
    renderModal();

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    // Wait for the error to be surfaced
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    // Button should go back to "Propose" and be enabled
    expect(screen.getByRole('button', { name: /^propose$/i })).not.toBeDisabled();
  });

  it('does not call onProposed or onClose on failure', async () => {
    const onClose = jest.fn();
    const onProposed = jest.fn();
    mockProposeFederationPeer.mockRejectedValue(new Error('Server error'));

    renderModal({ onClose, onProposed });

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onProposed).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Cancel / close behaviour
  // ---------------------------------------------------------------------------

  it('calls onClose when the Cancel button is clicked', () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('resets all fields when Cancel is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.change(screen.getByLabelText(/remote instance id/i), {
      target: { value: '019d-1234' },
    });

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    // After close + reopen, inputs should be empty
    expect(screen.getByLabelText(/remote instance url/i)).toHaveValue('');
    expect(screen.getByLabelText(/remote instance id/i)).toHaveValue('');
  });

  it('resets all fields after a successful submission', async () => {
    const onClose = jest.fn();
    const onProposed = jest.fn();
    mockProposeFederationPeer.mockResolvedValue(envelope({ federation_peer: PEER_FIXTURE }));

    const { rerender } = renderModal({ onClose, onProposed });

    fireEvent.change(screen.getByLabelText(/remote instance url/i), {
      target: { value: 'https://other.powernode.example.org' },
    });
    fireEvent.change(screen.getByLabelText(/remote instance id/i), {
      target: { value: '019d-1234-5678' },
    });
    fireEvent.click(screen.getByRole('button', { name: /^propose$/i }));

    await waitFor(() => expect(onProposed).toHaveBeenCalled());

    // Re-open the modal
    rerender(
      <FederationPeerProposeModal
        isOpen={true}
        onClose={onClose}
        onProposed={onProposed}
      />,
    );

    expect(screen.getByLabelText(/remote instance url/i)).toHaveValue('');
    expect(screen.getByLabelText(/remote instance id/i)).toHaveValue('');
  });
});
