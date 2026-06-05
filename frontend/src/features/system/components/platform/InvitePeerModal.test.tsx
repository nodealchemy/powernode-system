import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { InvitePeerModal } from './InvitePeerModal';
import type { InvitePeerResponse } from '../../types/peer.types';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: (...args: unknown[]) => mockPost(...args),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

// platformPeersApi.invite calls apiClient.post internally via extractData.
// We stub the API facade directly so we don't have to reproduce the
// extractData envelope unwrapping in tests.
jest.mock('../../services/api/platformPeersApi', () => ({
  platformPeersApi: {
    invite: (...args: unknown[]) => mockInvite(...args),
    listPeers: jest.fn(),
    getPeer: jest.fn(),
    revoke: jest.fn(),
  },
}));

// Clipboard API is unavailable in jsdom — polyfill it so copy tests work.
Object.assign(navigator, {
  clipboard: {
    writeText: jest.fn().mockResolvedValue(undefined),
  },
});

// =============================================================================
// Fixtures
// =============================================================================

const mockInvite = jest.fn();

function makePeerDetail(overrides: Partial<InvitePeerResponse['peer']> = {}): InvitePeerResponse['peer'] {
  return {
    id: 'peer-abc',
    remote_instance_url: 'https://hub.remote.tld',
    remote_instance_id: null,
    peer_kind: 'platform',
    spawn_role: 'symmetric',
    spawn_mode: 'out_of_band',
    status: 'proposed',
    created_at: '2026-06-01T00:00:00Z',
    last_heartbeat_at: null,
    last_handshake_at: null,
    endpoints_count: 1,
    acceptance_pending: true,
    acceptance_expires_at: '2026-06-08T00:00:00Z',
    endpoints: [],
    capabilities: {},
    extension_slugs: [],
    metadata: {},
    signed_at: null,
    contract_version_agreed: null,
    parent_peer_id: null,
    allowed_transitions: [],
    grants_count: 0,
    capabilities_count: 0,
    bridges_count: 0,
    ...overrides,
  };
}

const INVITE_RESPONSE: InvitePeerResponse = {
  peer: makePeerDetail(),
  acceptance_token: 'tok_super_secret_abc123',
};

// =============================================================================
// Helpers
// =============================================================================

const defaultProps = {
  isOpen: true,
  onClose: jest.fn(),
  onInvited: jest.fn(),
};

function renderModal(props: Partial<typeof defaultProps> = {}) {
  return render(<InvitePeerModal {...defaultProps} {...props} />);
}

function getRemoteUrlInput() {
  return screen.getByPlaceholderText('https://hub.bob.tld');
}

function getTtlInput() {
  // There's only one number input that isn't a priority field
  return screen.getByDisplayValue('7');
}

function fillRemoteUrl(url: string) {
  fireEvent.change(getRemoteUrlInput(), { target: { value: url } });
}

async function submitForm() {
  fireEvent.click(screen.getByRole('button', { name: /^invite$/i }));
}

// =============================================================================
// Tests
// =============================================================================

describe('InvitePeerModal', () => {
  beforeEach(() => {
    mockInvite.mockReset();
    (defaultProps.onClose as jest.Mock).mockReset();
    (defaultProps.onInvited as jest.Mock).mockReset();
    (navigator.clipboard.writeText as jest.Mock).mockReset();
    (navigator.clipboard.writeText as jest.Mock).mockResolvedValue(undefined);
  });

  // ---------------------------------------------------------------------------
  // Render / closed state
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen=false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Invite Peer')).not.toBeInTheDocument();
  });

  it('renders the form phase with all expected fields when open', () => {
    renderModal();
    expect(screen.getByText('Invite Peer')).toBeInTheDocument();
    expect(getRemoteUrlInput()).toBeInTheDocument();
    // Role select
    expect(screen.getByDisplayValue('Symmetric Peer')).toBeInTheDocument();
    // Mode select
    expect(screen.getByDisplayValue('Out-of-band (manual exchange)')).toBeInTheDocument();
    // TTL field defaults to 7
    expect(screen.getByDisplayValue('7')).toBeInTheDocument();
    // Footer buttons
    expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /^invite$/i })).toBeInTheDocument();
  });

  it('shows the "Invite Peer" title on form phase and "Acceptance Token" on token phase', async () => {
    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    renderModal();

    expect(screen.getByText('Invite Peer')).toBeInTheDocument();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    // "Acceptance Token" appears in both the modal title <span> and as a
    // <label> inside the content — use getAllByText and assert at least one.
    await waitFor(() =>
      expect(screen.getAllByText('Acceptance Token').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  it('disables the Invite button when Remote URL is empty', () => {
    renderModal();
    // No URL entered — button must be disabled
    expect(screen.getByRole('button', { name: /^invite$/i })).toBeDisabled();
  });

  it('disables the Invite button when the URL is not an https URL', () => {
    renderModal();
    fillRemoteUrl('http://hub.remote.tld');
    expect(screen.getByRole('button', { name: /^invite$/i })).toBeDisabled();
  });

  it('enables the Invite button for a valid https URL', () => {
    renderModal();
    fillRemoteUrl('https://hub.remote.tld');
    expect(screen.getByRole('button', { name: /^invite$/i })).not.toBeDisabled();
  });

  it('disables the Invite button when TTL is out of range (0)', () => {
    renderModal();
    fillRemoteUrl('https://hub.remote.tld');
    fireEvent.change(getTtlInput(), { target: { value: '0' } });
    expect(screen.getByRole('button', { name: /^invite$/i })).toBeDisabled();
  });

  it('disables the Invite button when TTL exceeds 30', () => {
    renderModal();
    fillRemoteUrl('https://hub.remote.tld');
    fireEvent.change(getTtlInput(), { target: { value: '31' } });
    expect(screen.getByRole('button', { name: /^invite$/i })).toBeDisabled();
  });

  it('shows an inline error when submitting with a bare invalid URL (via form submit)', async () => {
    renderModal();
    // Bypass the disabled-button guard by submitting the form directly
    const form = screen.getByRole('dialog').querySelector('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(screen.getByText(/remote url is required/i)).toBeInTheDocument(),
    );
  });

  it('clears the error when the X button is clicked', async () => {
    renderModal();
    const form = screen.getByRole('dialog').querySelector('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(screen.getByText(/remote url is required/i)).toBeInTheDocument(),
    );

    // Click the X inside the error banner
    const dismissBtn = screen.getByText(/remote url is required/i)
      .closest('div')!
      .querySelector('button[type="button"]')!;
    fireEvent.click(dismissBtn);

    expect(screen.queryByText(/remote url is required/i)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Endpoint management
  // ---------------------------------------------------------------------------

  it('shows the auto-derive message when no endpoints are added', () => {
    renderModal();
    expect(
      screen.getByText(/one wan endpoint will be auto-derived/i),
    ).toBeInTheDocument();
  });

  it('adds an endpoint row when "Add Endpoint" is clicked', () => {
    renderModal();
    fireEvent.click(screen.getByText(/add endpoint/i));

    // A new url input row with placeholder should appear
    expect(screen.getByPlaceholderText('https://lan-hub.bob.tld')).toBeInTheDocument();
    // Scope select defaults to lan
    expect(screen.getByDisplayValue('lan')).toBeInTheDocument();
  });

  it('removes an endpoint row when Trash2 button is clicked', () => {
    renderModal();
    fireEvent.click(screen.getByText(/add endpoint/i));

    expect(screen.getByPlaceholderText('https://lan-hub.bob.tld')).toBeInTheDocument();

    fireEvent.click(screen.getByTitle(/remove endpoint/i));

    expect(screen.queryByPlaceholderText('https://lan-hub.bob.tld')).not.toBeInTheDocument();
    expect(screen.getByText(/one wan endpoint will be auto-derived/i)).toBeInTheDocument();
  });

  it('updates the endpoint URL when the user types in the endpoint field', () => {
    renderModal();
    fireEvent.click(screen.getByText(/add endpoint/i));

    const epInput = screen.getByPlaceholderText('https://lan-hub.bob.tld');
    fireEvent.change(epInput, { target: { value: 'https://lan.bob.tld' } });

    expect((epInput as HTMLInputElement).value).toBe('https://lan.bob.tld');
  });

  it('changes endpoint scope via the scope select', () => {
    renderModal();
    fireEvent.click(screen.getByText(/add endpoint/i));

    const scopeSelect = screen.getByDisplayValue('lan');
    fireEvent.change(scopeSelect, { target: { value: 'sdwan' } });

    expect((scopeSelect as HTMLSelectElement).value).toBe('sdwan');
  });

  it('validates endpoint URL and disables submit when an added endpoint URL is invalid', () => {
    renderModal();
    fillRemoteUrl('https://hub.remote.tld');

    fireEvent.click(screen.getByText(/add endpoint/i));
    // Leave endpoint URL blank — should invalidate
    expect(screen.getByRole('button', { name: /^invite$/i })).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Role / mode selects
  // ---------------------------------------------------------------------------

  it('renders all role options', () => {
    renderModal();
    const roleSelect = screen.getByDisplayValue('Symmetric Peer');
    expect(roleSelect).toBeInTheDocument();
    // Check both options exist
    expect(screen.getByRole('option', { name: 'Symmetric Peer' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'I am the child' })).toBeInTheDocument();
  });

  it('renders all mode options', () => {
    renderModal();
    expect(screen.getByRole('option', { name: 'Out-of-band (manual exchange)' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Autonomous Peer' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Managed Child' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Cluster Member' })).toBeInTheDocument();
  });

  it('updates the role help text when role is changed', () => {
    renderModal();
    const roleSelect = screen.getByDisplayValue('Symmetric Peer');
    // Default symmetric help text
    expect(
      screen.getByText(/equal peer.*no parent\/child relationship/i),
    ).toBeInTheDocument();

    fireEvent.change(roleSelect, { target: { value: 'child' } });

    expect(
      screen.getByText(/remote platform spawned us/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Form submission — success path
  // ---------------------------------------------------------------------------

  it('calls platformPeersApi.invite with the correct payload on valid submit', async () => {
    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    // Change TTL to 14
    fireEvent.change(getTtlInput(), { target: { value: '14' } });

    await submitForm();

    await waitFor(() => expect(mockInvite).toHaveBeenCalledTimes(1));

    expect(mockInvite).toHaveBeenCalledWith({
      remote_instance_url: 'https://hub.remote.tld',
      spawn_role: 'symmetric',
      spawn_mode: 'out_of_band',
      // No explicit endpoints → effectiveEndpoints seeds from remoteUrl
      endpoints: [{ url: 'https://hub.remote.tld', scope: 'wan', priority: 100 }],
      // 14 days * 86400 seconds
      token_ttl_seconds: 14 * 86_400,
    });
  });

  it('sends explicit endpoints when the user has added them', async () => {
    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');

    // Add a LAN endpoint
    fireEvent.click(screen.getByText(/add endpoint/i));
    const epInput = screen.getByPlaceholderText('https://lan-hub.bob.tld');
    fireEvent.change(epInput, { target: { value: 'https://lan.remote.tld' } });

    await submitForm();

    await waitFor(() => expect(mockInvite).toHaveBeenCalledTimes(1));

    const [payload] = mockInvite.mock.calls[0] as [Parameters<typeof mockInvite>[0]];
    // Explicit endpoint overrides the default WAN seed
    expect(payload.endpoints).toEqual([
      { url: 'https://lan.remote.tld', scope: 'lan', priority: 1 },
    ]);
  });

  it('switches to the token phase and calls onInvited after a successful invite', async () => {
    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    // Verify token phase by the presence of the plaintext token value itself
    await waitFor(() =>
      expect(
        screen.getByDisplayValue('tok_super_secret_abc123'),
      ).toBeInTheDocument(),
    );
    expect(defaultProps.onInvited).toHaveBeenCalledWith(INVITE_RESPONSE);
  });

  // ---------------------------------------------------------------------------
  // Token phase rendering
  // ---------------------------------------------------------------------------

  it('displays the acceptance token in a readonly field on the token phase', async () => {
    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    await waitFor(() =>
      expect(
        screen.getByDisplayValue('tok_super_secret_abc123'),
      ).toBeInTheDocument(),
    );

    const tokenInput = screen.getByDisplayValue(
      'tok_super_secret_abc123',
    ) as HTMLInputElement;
    expect(tokenInput.readOnly).toBe(true);
  });

  it('shows peer id, status, and expiry on the token phase', async () => {
    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    await waitFor(() =>
      expect(screen.getByText('peer-abc')).toBeInTheDocument(),
    );
    expect(screen.getByText('proposed')).toBeInTheDocument();
  });

  it('shows the one-time warning banner on the token phase', async () => {
    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    await waitFor(() =>
      expect(
        screen.getByText(/capture this token now/i),
      ).toBeInTheDocument(),
    );
  });

  it('shows a Done button (not Invite/Cancel) on the token phase', async () => {
    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /done/i })).toBeInTheDocument(),
    );
    expect(screen.queryByRole('button', { name: /^invite$/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /cancel/i })).not.toBeInTheDocument();
  });

  it('calls onClose when Done is clicked on the token phase', async () => {
    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /done/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /done/i }));
    expect(defaultProps.onClose).toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Copy token
  // ---------------------------------------------------------------------------

  it('copies the token to clipboard and shows "Copied" temporarily', async () => {
    jest.useFakeTimers();

    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    await waitFor(() =>
      expect(screen.getByText('Copy')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('Copy'));

    await waitFor(() =>
      expect(navigator.clipboard.writeText).toHaveBeenCalledWith(
        'tok_super_secret_abc123',
      ),
    );

    await waitFor(() =>
      expect(screen.getByText('Copied')).toBeInTheDocument(),
    );

    act(() => {
      jest.advanceTimersByTime(2100);
    });

    await waitFor(() =>
      expect(screen.getByText('Copy')).toBeInTheDocument(),
    );

    jest.useRealTimers();
  });

  // ---------------------------------------------------------------------------
  // API error path
  // ---------------------------------------------------------------------------

  it('shows an inline error and stays on form phase when invite fails', async () => {
    mockInvite.mockRejectedValue(new Error('Network error'));
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    await waitFor(() =>
      expect(screen.getByText('Network error')).toBeInTheDocument(),
    );
    // Must still show the form phase
    expect(screen.getByText('Invite Peer')).toBeInTheDocument();
    expect(screen.queryByText('Acceptance Token')).not.toBeInTheDocument();
  });

  it('shows a fallback error message for non-Error rejections', async () => {
    mockInvite.mockRejectedValue('unexpected');
    renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    await waitFor(() =>
      expect(screen.getByText('Invite failed')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Submitting state
  // ---------------------------------------------------------------------------

  it('disables both Cancel and Invite buttons while submitting', async () => {
    let resolveFn!: (v: InvitePeerResponse) => void;
    mockInvite.mockReturnValue(
      new Promise<InvitePeerResponse>((res) => {
        resolveFn = res;
      }),
    );

    renderModal();
    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    // While the promise is pending, buttons should be disabled
    expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();
    expect(screen.getByRole('button', { name: /inviting…/i })).toBeDisabled();

    // Settle the promise
    await act(async () => {
      resolveFn(INVITE_RESPONSE);
    });
  });

  // ---------------------------------------------------------------------------
  // Reset on re-open
  // ---------------------------------------------------------------------------

  it('resets form state when the modal is closed and re-opened', async () => {
    mockInvite.mockResolvedValue(INVITE_RESPONSE);
    const { rerender } = renderModal();

    fillRemoteUrl('https://hub.remote.tld');
    await submitForm();

    // Wait for the token phase to arrive (the readonly token input is a reliable signal)
    await waitFor(() =>
      expect(
        screen.getByDisplayValue('tok_super_secret_abc123'),
      ).toBeInTheDocument(),
    );

    // Simulate close → re-open
    rerender(
      <InvitePeerModal
        {...defaultProps}
        isOpen={false}
      />,
    );
    rerender(
      <InvitePeerModal
        {...defaultProps}
        isOpen={true}
      />,
    );

    // Back to form phase — remote URL and TTL should be reset
    expect(screen.getByText('Invite Peer')).toBeInTheDocument();
    expect(getRemoteUrlInput()).toHaveValue('');
    expect(screen.getByDisplayValue('7')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel is clicked', () => {
    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(defaultProps.onClose).toHaveBeenCalled();
  });

  it('does not call onInvited when cancel is clicked without submission', () => {
    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(defaultProps.onInvited).not.toHaveBeenCalled();
  });
});
