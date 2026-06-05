import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { GrantsManagementModal } from './GrantsManagementModal';
import type { FederationGrant } from '@system/features/system/types/grant.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({
    isOpen,
    children,
    footer,
  }: {
    isOpen: boolean;
    children: React.ReactNode;
    footer?: React.ReactNode;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="modal">
        {children}
        {footer}
      </div>
    );
  },
}));

jest.mock('@/shared/components/ui/Button', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    variant,
  }: {
    children: React.ReactNode;
    onClick?: (e: React.MouseEvent) => void;
    disabled?: boolean;
    variant?: string;
  }) => (
    <button onClick={onClick} disabled={disabled} data-variant={variant}>
      {children}
    </button>
  ),
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const GRANT_ACTIVE: FederationGrant = {
  id: 'grant-1',
  federation_peer_id: 'peer-abc',
  remote_subject: 'alice@remote.example.org',
  resource_kind: 'skill',
  resource_id: null,
  permission_scopes: ['read'],
  lifecycle: 'active',
  issued_at: '2026-01-01T00:00:00Z',
  expires_at: '2026-12-31T00:00:00Z',
  revoked_at: null,
  revocation_reason: null,
  archived_at: null,
  node_instance_ids: [],
  sdwan_network_ids: [],
  source_cidrs: [],
  unrestricted: true,
  grantor_user_id: 'user-1',
  bearer_token_preview: null,
};

const GRANT_REVOKED: FederationGrant = {
  ...GRANT_ACTIVE,
  id: 'grant-2',
  remote_subject: 'bob@remote.example.org',
  lifecycle: 'revoked',
  revoked_at: '2026-06-01T00:00:00Z',
  revocation_reason: 'no longer needed',
};

const GRANT_WITH_RESTRICTIONS: FederationGrant = {
  ...GRANT_ACTIVE,
  id: 'grant-3',
  remote_subject: 'carol@remote.example.org',
  resource_kind: 'node',
  resource_id: 'abcdef12-3456-7890-abcd-ef1234567890',
  permission_scopes: ['read', 'write'],
  unrestricted: false,
  node_instance_ids: ['inst-1', 'inst-2'],
  sdwan_network_ids: ['net-1'],
  source_cidrs: ['10.0.0.0/8', '192.168.1.0/24'],
};

function grantsEnvelope(grants: FederationGrant[]) {
  return envelope({ grants, count: grants.length });
}

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  peerId?: string | null;
  peerLabel?: string;
  onClose?: jest.Mock;
  onChanged?: jest.Mock;
}

const renderModal = ({
  isOpen = true,
  peerId = 'peer-abc',
  peerLabel = 'remote-platform.example.org',
  onClose = jest.fn(),
  onChanged = jest.fn(),
}: RenderProps = {}) =>
  render(
    <BrowserRouter>
      <GrantsManagementModal
        isOpen={isOpen}
        peerId={peerId}
        peerLabel={peerLabel}
        onClose={onClose}
        onChanged={onChanged}
      />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('GrantsManagementModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockAddNotification.mockReset();
    // Suppress window.prompt — will be mocked per-test where needed
    jest.spyOn(window, 'prompt').mockReturnValue(null);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  // ---------------------------------------------------------------------------
  // Render / mount
  // ---------------------------------------------------------------------------

  it('renders nothing when peerId is null', () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));
    renderModal({ peerId: null });
    expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
  });

  it('does not render the modal when isOpen is false', () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));
    renderModal({ isOpen: false });
    expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
  });

  it('renders the modal when open with a valid peerId', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));
    renderModal();
    expect(screen.getByTestId('modal')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // API fetching
  // ---------------------------------------------------------------------------

  it('fetches grants for the given peerId on open', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));

    renderModal({ peerId: 'peer-abc' });

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        '/system/platform/peers/peer-abc/grants',
        { params: {} },
      ),
    );
  });

  it('renders the list of fetched grants', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE, GRANT_REVOKED]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('alice@remote.example.org')).toBeInTheDocument(),
    );
    expect(screen.getByText('bob@remote.example.org')).toBeInTheDocument();
  });

  it('shows grant count when loaded', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE, GRANT_REVOKED]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('2 grants')).toBeInTheDocument(),
    );
  });

  it('shows "1 grant" (singular) when exactly one grant', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('1 grant')).toBeInTheDocument(),
    );
  });

  it('shows loading indicator while fetching', async () => {
    let resolve: (v: unknown) => void = () => {};
    mockGet.mockReturnValue(new Promise((r) => { resolve = r; }));

    renderModal();

    expect(screen.getByText('loading…')).toBeInTheDocument();

    resolve(grantsEnvelope([]));
    await waitFor(() =>
      expect(screen.queryByText('loading…')).not.toBeInTheDocument(),
    );
  });

  it('shows empty state when no grants are returned', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(
        screen.getByText('No grants matching the current filter.'),
      ).toBeInTheDocument(),
    );
  });

  it('shows an error message when the fetch fails', async () => {
    mockGet.mockRejectedValue(new Error('Network timeout'));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
  });

  it('shows fallback error when fetch rejects with non-Error', async () => {
    mockGet.mockRejectedValue('bad stuff');

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Failed to load grants')).toBeInTheDocument(),
    );
  });

  it('dismisses the error banner when the X button is clicked', async () => {
    mockGet.mockRejectedValue(new Error('fetch error'));

    renderModal();

    await waitFor(() => expect(screen.getByText('fetch error')).toBeInTheDocument());

    const dismissButtons = screen.getAllByRole('button').filter(
      (b) => b.querySelector('svg') && !b.textContent?.trim(),
    );
    // The X button inside the error banner is a type="button" with only an SVG child
    fireEvent.click(dismissButtons[0]);

    await waitFor(() =>
      expect(screen.queryByText('fetch error')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Lifecycle filter
  // ---------------------------------------------------------------------------

  it('renders all lifecycle filter buttons', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('0 grants')).toBeInTheDocument(),
    );

    expect(screen.getByRole('button', { name: 'All' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Active' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Expired' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Revoked' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Archived' })).toBeInTheDocument();
  });

  it('passes lifecycle state param when a filter is selected', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
    mockGet.mockReset();
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));

    fireEvent.click(screen.getByRole('button', { name: 'Active' }));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        '/system/platform/peers/peer-abc/grants',
        { params: { state: 'active' } },
      ),
    );
  });

  it('passes no state param when "All" filter is selected', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
    mockGet.mockReset();
    mockGet.mockResolvedValue(grantsEnvelope([]));

    // First click Active to set a filter, then click All to clear it
    fireEvent.click(screen.getByRole('button', { name: 'Active' }));
    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
    mockGet.mockReset();
    mockGet.mockResolvedValue(grantsEnvelope([]));

    fireEvent.click(screen.getByRole('button', { name: 'All' }));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        '/system/platform/peers/peer-abc/grants',
        { params: {} },
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Grant row rendering
  // ---------------------------------------------------------------------------

  it('renders the remote_subject, resource_kind, and lifecycle pill for a grant', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('alice@remote.example.org')).toBeInTheDocument(),
    );
    expect(screen.getByText('skill')).toBeInTheDocument();
    expect(screen.getByText('active')).toBeInTheDocument();
  });

  it('renders permission scopes for a grant', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('alice@remote.example.org')).toBeInTheDocument(),
    );
    // scopes are joined: "read"
    expect(screen.getByText('read')).toBeInTheDocument();
  });

  it('renders a resource_id snippet when resource_id is set', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_WITH_RESTRICTIONS]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('carol@remote.example.org')).toBeInTheDocument(),
    );
    // First 8 chars of the resource_id UUID + ellipsis
    expect(screen.getByText('(abcdef12…)')).toBeInTheDocument();
  });

  it('renders restriction details (instances, networks, CIDRs) when not unrestricted', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_WITH_RESTRICTIONS]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('carol@remote.example.org')).toBeInTheDocument(),
    );

    expect(screen.getByText('2 instances')).toBeInTheDocument();
    expect(screen.getByText('1 network')).toBeInTheDocument();
    expect(screen.getByText('10.0.0.0/8, 192.168.1.0/24')).toBeInTheDocument();
  });

  it('renders the revocation reason for a revoked grant', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_REVOKED]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('bob@remote.example.org')).toBeInTheDocument(),
    );
    expect(screen.getByText('revoke reason: no longer needed')).toBeInTheDocument();
  });

  it('does not show a Revoke button for a revoked grant', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_REVOKED]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('bob@remote.example.org')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Revoke')).not.toBeInTheDocument();
  });

  it('shows a Revoke button for an active grant', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('alice@remote.example.org')).toBeInTheDocument(),
    );
    expect(screen.getByText('Revoke')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Revoke flow
  // ---------------------------------------------------------------------------

  it('calls peerGrantsApi.revoke with peerId, grantId, and reason when confirmed', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));
    mockPost.mockResolvedValue(envelope({ grant: { ...GRANT_ACTIVE, lifecycle: 'revoked' } }));

    jest.spyOn(window, 'prompt').mockReturnValue('test revoke reason');

    const onChanged = jest.fn();
    renderModal({ onChanged });

    await waitFor(() =>
      expect(screen.getByText('Revoke')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('Revoke'));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/peers/peer-abc/grants/grant-1/revoke',
        { reason: 'test revoke reason' },
      ),
    );
  });

  it('calls peerGrantsApi.revoke with no reason when prompt returns empty string', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));
    mockPost.mockResolvedValue(envelope({ grant: { ...GRANT_ACTIVE, lifecycle: 'revoked' } }));

    jest.spyOn(window, 'prompt').mockReturnValue('');

    renderModal();

    await waitFor(() => expect(screen.getByText('Revoke')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Revoke'));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/peers/peer-abc/grants/grant-1/revoke',
        {},
      ),
    );
  });

  it('does not call revoke when user cancels the prompt', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));

    jest.spyOn(window, 'prompt').mockReturnValue(null);

    renderModal();

    await waitFor(() => expect(screen.getByText('Revoke')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Revoke'));

    // Give async ops time to settle
    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
    expect(mockPost).not.toHaveBeenCalled();
  });

  it('shows a success notification after a successful revoke', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));
    mockPost.mockResolvedValue(envelope({ grant: { ...GRANT_ACTIVE, lifecycle: 'revoked' } }));

    jest.spyOn(window, 'prompt').mockReturnValue('reason');

    renderModal();

    await waitFor(() => expect(screen.getByText('Revoke')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Revoke'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: "Grant for 'alice@remote.example.org' revoked.",
      }),
    );
  });

  it('calls onChanged after a successful revoke', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));
    mockPost.mockResolvedValue(envelope({ grant: { ...GRANT_ACTIVE, lifecycle: 'revoked' } }));

    jest.spyOn(window, 'prompt').mockReturnValue('reason');

    const onChanged = jest.fn();
    renderModal({ onChanged });

    await waitFor(() => expect(screen.getByText('Revoke')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Revoke'));

    await waitFor(() => expect(onChanged).toHaveBeenCalled());
  });

  it('shows an error notification when revoke fails', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));
    mockPost.mockRejectedValue(new Error('Revoke request failed'));

    jest.spyOn(window, 'prompt').mockReturnValue('reason');

    renderModal();

    await waitFor(() => expect(screen.getByText('Revoke')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Revoke'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Revoke request failed',
      }),
    );
  });

  it('shows Revoking… while revoke is in-flight', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));

    let resolveRevoke: (v: unknown) => void = () => {};
    mockPost.mockReturnValue(new Promise((r) => { resolveRevoke = r; }));

    jest.spyOn(window, 'prompt').mockReturnValue('reason');

    renderModal();

    await waitFor(() => expect(screen.getByText('Revoke')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Revoke'));

    await waitFor(() =>
      expect(screen.getByText('Revoking…')).toBeInTheDocument(),
    );

    resolveRevoke(envelope({ grant: { ...GRANT_ACTIVE, lifecycle: 'revoked' } }));
    await waitFor(() =>
      expect(screen.queryByText('Revoking…')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Footer buttons
  // ---------------------------------------------------------------------------

  it('shows the Close button in the footer', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('0 grants')).toBeInTheDocument(),
    );

    expect(screen.getByText('Close')).toBeInTheDocument();
  });

  it('calls onClose when the Close button is clicked', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() =>
      expect(screen.getByText('0 grants')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('Close'));
    expect(onClose).toHaveBeenCalled();
  });

  it('shows Issue Grant button when the form is not open', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('0 grants')).toBeInTheDocument(),
    );

    expect(screen.getByText('Issue Grant')).toBeInTheDocument();
  });

  it('hides the footer Issue Grant button when the issue form is visible', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    // Before clicking — footer has an enabled primary "Issue Grant" button
    await waitFor(() => {
      const btns = screen.getAllByText('Issue Grant').map((el) => el.closest('button'));
      const enabledPrimary = btns.find(
        (b) => b?.getAttribute('data-variant') === 'primary' && !b.disabled,
      );
      expect(enabledPrimary).toBeInTheDocument();
    });

    const footerIssueBtn = screen.getAllByText('Issue Grant').reduce<HTMLButtonElement | null>(
      (found, el) => {
        const btn = el.closest('button') as HTMLButtonElement | null;
        return btn && btn.getAttribute('data-variant') === 'primary' && !btn.disabled
          ? btn
          : found;
      },
      null,
    );
    if (footerIssueBtn) fireEvent.click(footerIssueBtn);

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    // After opening the form, there should be NO enabled primary "Issue Grant" button
    // (the form's own submit button is disabled because fields are empty)
    const allIssueGrantButtons = screen.getAllByText('Issue Grant').map(
      (el) => el.closest('button') as HTMLButtonElement | null,
    );
    const enabledPrimaryBtn = allIssueGrantButtons.find(
      (b) => b?.getAttribute('data-variant') === 'primary' && !b?.disabled,
    );
    expect(enabledPrimaryBtn).toBeUndefined();
  });

  // ---------------------------------------------------------------------------
  // Issue Grant form — open / cancel
  // ---------------------------------------------------------------------------

  it('shows the IssueGrantForm when Issue Grant is clicked', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );
  });

  it('hides the IssueGrantForm when Cancel is clicked inside the form', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('Cancel'));

    await waitFor(() =>
      expect(screen.queryByText('Issue New Grant')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Issue Grant form — validation
  // ---------------------------------------------------------------------------

  it('disables the Issue Grant submit button when resource_kind is empty', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    // Submit button: there are multiple buttons; get the one inside the form
    const submitBtn = screen.getAllByText('Issue Grant').find(
      (el) => el.tagName === 'BUTTON' || el.closest('button') !== null,
    );
    const btn = submitBtn?.closest('button') ?? submitBtn as HTMLElement;
    // resource_kind is empty by default → form is invalid → button disabled
    expect(btn).toBeDisabled();
  });

  it('shows validation error when form is submitted with empty resource_kind', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    // Fill only remote_subject but leave resource_kind blank
    const inputs = screen.getAllByRole('textbox');
    const remoteSubjectInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('alice@remote'),
    );
    if (remoteSubjectInput) {
      fireEvent.change(remoteSubjectInput, { target: { value: 'bob@remote.example.org' } });
    }

    // Submit the form directly (button is disabled by validation, but the form onSubmit still fires)
    const form = document.querySelector('form');
    if (form) {
      fireEvent.submit(form);
    }

    await waitFor(() =>
      expect(screen.getByText('resource_kind is required.')).toBeInTheDocument(),
    );
  });

  it('shows TTL validation error for an out-of-range value', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal();

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    // Fill resource_kind and remote_subject so those pass
    const inputs = screen.getAllByRole('textbox');
    const resourceKindInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('e.g. skill'),
    );
    const remoteSubjectInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('alice@remote'),
    );
    if (resourceKindInput) {
      fireEvent.change(resourceKindInput, { target: { value: 'skill' } });
    }
    if (remoteSubjectInput) {
      fireEvent.change(remoteSubjectInput, { target: { value: 'bob@remote.example.org' } });
    }

    // Set TTL out of range
    const ttlInput = screen.getByRole('spinbutton');
    fireEvent.change(ttlInput, { target: { value: '400' } });

    // Submit the form directly (button is disabled, but onSubmit still runs validation)
    const form = document.querySelector('form');
    if (form) {
      fireEvent.submit(form);
    }

    await waitFor(() =>
      expect(screen.getByText('TTL must be 7–365 days.')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Issue Grant form — successful submission
  // ---------------------------------------------------------------------------

  it('calls peerGrantsApi.issue with correct payload on valid submission', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));
    mockPost.mockResolvedValue(
      envelope({ grant: { ...GRANT_ACTIVE, id: 'grant-new' } }),
    );

    renderModal({ peerId: 'peer-abc' });

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    const inputs = screen.getAllByRole('textbox');
    const resourceKindInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('e.g. skill'),
    );
    const remoteSubjectInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('alice@remote'),
    );

    if (resourceKindInput) {
      fireEvent.change(resourceKindInput, { target: { value: 'skill' } });
    }
    if (remoteSubjectInput) {
      fireEvent.change(remoteSubjectInput, { target: { value: 'alice@remote.example.org' } });
    }

    // TTL is already 30 days by default — valid

    const issueButtons = screen.getAllByText('Issue Grant');
    const submitBtn = issueButtons[issueButtons.length - 1];
    fireEvent.click(submitBtn);

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/peers/peer-abc/grants',
        expect.objectContaining({
          resource_kind: 'skill',
          remote_subject: 'alice@remote.example.org',
          permission_scopes: ['read'],
          ttl_days: 30,
          node_instance_ids: [],
          sdwan_network_ids: [],
          source_cidrs: [],
        }),
      ),
    );
  });

  it('closes the issue form and refetches grants after a successful issue', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));
    mockPost.mockResolvedValue(
      envelope({ grant: { ...GRANT_ACTIVE, id: 'grant-new' } }),
    );

    const onChanged = jest.fn();
    renderModal({ peerId: 'peer-abc', onChanged });

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    const inputs = screen.getAllByRole('textbox');
    const resourceKindInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('e.g. skill'),
    );
    const remoteSubjectInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('alice@remote'),
    );

    if (resourceKindInput) {
      fireEvent.change(resourceKindInput, { target: { value: 'skill' } });
    }
    if (remoteSubjectInput) {
      fireEvent.change(remoteSubjectInput, { target: { value: 'alice@remote.example.org' } });
    }

    const issueButtons = screen.getAllByText('Issue Grant');
    const submitBtn = issueButtons[issueButtons.length - 1];
    fireEvent.click(submitBtn);

    await waitFor(() => expect(onChanged).toHaveBeenCalled());
    await waitFor(() =>
      expect(screen.queryByText('Issue New Grant')).not.toBeInTheDocument(),
    );
  });

  it('shows Issuing… on the submit button while in-flight', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    let resolveIssue: (v: unknown) => void = () => {};
    mockPost.mockReturnValue(new Promise((r) => { resolveIssue = r; }));

    renderModal({ peerId: 'peer-abc' });

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    const inputs = screen.getAllByRole('textbox');
    const resourceKindInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('e.g. skill'),
    );
    const remoteSubjectInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('alice@remote'),
    );

    if (resourceKindInput) {
      fireEvent.change(resourceKindInput, { target: { value: 'skill' } });
    }
    if (remoteSubjectInput) {
      fireEvent.change(remoteSubjectInput, { target: { value: 'alice@remote.example.org' } });
    }

    const issueButtons = screen.getAllByText('Issue Grant');
    const submitBtn = issueButtons[issueButtons.length - 1];
    fireEvent.click(submitBtn);

    await waitFor(() =>
      expect(screen.getByText('Issuing…')).toBeInTheDocument(),
    );

    resolveIssue(envelope({ grant: GRANT_ACTIVE }));
    await waitFor(() =>
      expect(screen.queryByText('Issuing…')).not.toBeInTheDocument(),
    );
  });

  it('shows an error in the issue form when the API call fails', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));
    mockPost.mockRejectedValue(new Error('Issue failed on server'));

    renderModal({ peerId: 'peer-abc' });

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    const inputs = screen.getAllByRole('textbox');
    const resourceKindInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('e.g. skill'),
    );
    const remoteSubjectInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('alice@remote'),
    );

    if (resourceKindInput) {
      fireEvent.change(resourceKindInput, { target: { value: 'skill' } });
    }
    if (remoteSubjectInput) {
      fireEvent.change(remoteSubjectInput, { target: { value: 'alice@remote.example.org' } });
    }

    const issueButtons = screen.getAllByText('Issue Grant');
    const submitBtn = issueButtons[issueButtons.length - 1];
    fireEvent.click(submitBtn);

    await waitFor(() =>
      expect(screen.getByText('Issue failed on server')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Scope toggles in IssueGrantForm
  // ---------------------------------------------------------------------------

  it('toggles scopes in the issue form', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));
    mockPost.mockResolvedValue(envelope({ grant: GRANT_ACTIVE }));

    renderModal({ peerId: 'peer-abc' });

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    // 'read' is selected by default; click 'write' to add it
    const writeBtn = screen.getByRole('button', { name: 'write' });
    fireEvent.click(writeBtn);

    // Fill required fields and submit
    const inputs = screen.getAllByRole('textbox');
    const resourceKindInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('e.g. skill'),
    );
    const remoteSubjectInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('alice@remote'),
    );

    if (resourceKindInput) {
      fireEvent.change(resourceKindInput, { target: { value: 'skill' } });
    }
    if (remoteSubjectInput) {
      fireEvent.change(remoteSubjectInput, { target: { value: 'alice@remote.example.org' } });
    }

    const issueButtons = screen.getAllByText('Issue Grant');
    const submitBtn = issueButtons[issueButtons.length - 1];
    fireEvent.click(submitBtn);

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/peers/peer-abc/grants',
        expect.objectContaining({
          permission_scopes: expect.arrayContaining(['read', 'write']),
        }),
      ),
    );
  });

  it('sends no scopes and shows validation error when all scopes are deselected', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    renderModal({ peerId: 'peer-abc' });

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    // Deselect 'read' (the default)
    const readBtn = screen.getByRole('button', { name: 'read' });
    fireEvent.click(readBtn);

    // Fill required fields
    const inputs = screen.getAllByRole('textbox');
    const resourceKindInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('e.g. skill'),
    );
    const remoteSubjectInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('alice@remote'),
    );
    if (resourceKindInput) {
      fireEvent.change(resourceKindInput, { target: { value: 'skill' } });
    }
    if (remoteSubjectInput) {
      fireEvent.change(remoteSubjectInput, { target: { value: 'alice@remote.example.org' } });
    }

    // Submit the form directly (button is disabled by validation, but onSubmit fires)
    const form = document.querySelector('form');
    if (form) {
      fireEvent.submit(form);
    }

    await waitFor(() =>
      expect(screen.getByText('Select at least one scope.')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Pessimistic scope fields (CSV parsing)
  // ---------------------------------------------------------------------------

  it('passes parsed comma-separated node instance IDs in the issue payload', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));
    mockPost.mockResolvedValue(envelope({ grant: GRANT_ACTIVE }));

    renderModal({ peerId: 'peer-abc' });

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    // Expand pessimistic scope section
    const summary = screen.getByText(/Pessimistic scope/);
    fireEvent.click(summary);

    const inputs = screen.getAllByRole('textbox');
    const resourceKindInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('e.g. skill'),
    );
    const remoteSubjectInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('alice@remote'),
    );
    const nodeInstanceInput = inputs.find(
      (i) => (i as HTMLInputElement).placeholder?.includes('empty = any instance'),
    );

    if (resourceKindInput) {
      fireEvent.change(resourceKindInput, { target: { value: 'skill' } });
    }
    if (remoteSubjectInput) {
      fireEvent.change(remoteSubjectInput, { target: { value: 'alice@remote.example.org' } });
    }
    if (nodeInstanceInput) {
      fireEvent.change(nodeInstanceInput, { target: { value: 'inst-a, inst-b, inst-c' } });
    }

    const issueButtons = screen.getAllByText('Issue Grant');
    const submitBtn = issueButtons[issueButtons.length - 1];
    fireEvent.click(submitBtn);

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/platform/peers/peer-abc/grants',
        expect.objectContaining({
          node_instance_ids: ['inst-a', 'inst-b', 'inst-c'],
        }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Reset on close/reopen
  // ---------------------------------------------------------------------------

  it('clears grants and error when modal is closed', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([GRANT_ACTIVE]));

    const { rerender } = renderModal({ isOpen: true });

    await waitFor(() =>
      expect(screen.getByText('alice@remote.example.org')).toBeInTheDocument(),
    );

    rerender(
      <BrowserRouter>
        <GrantsManagementModal
          isOpen={false}
          peerId="peer-abc"
          peerLabel="remote-platform.example.org"
          onClose={jest.fn()}
          onChanged={jest.fn()}
        />
      </BrowserRouter>,
    );

    expect(screen.queryByText('alice@remote.example.org')).not.toBeInTheDocument();
  });

  it('hides the issue form when reopened', async () => {
    mockGet.mockResolvedValue(grantsEnvelope([]));

    const { rerender } = renderModal({ isOpen: true });

    await waitFor(() => expect(screen.getByText('Issue Grant')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Issue Grant'));

    await waitFor(() =>
      expect(screen.getByText('Issue New Grant')).toBeInTheDocument(),
    );

    // Close
    rerender(
      <BrowserRouter>
        <GrantsManagementModal
          isOpen={false}
          peerId="peer-abc"
          peerLabel="remote-platform.example.org"
          onClose={jest.fn()}
          onChanged={jest.fn()}
        />
      </BrowserRouter>,
    );

    // Re-open
    mockGet.mockResolvedValue(grantsEnvelope([]));
    rerender(
      <BrowserRouter>
        <GrantsManagementModal
          isOpen={true}
          peerId="peer-abc"
          peerLabel="remote-platform.example.org"
          onClose={jest.fn()}
          onChanged={jest.fn()}
        />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(screen.queryByText('Issue New Grant')).not.toBeInTheDocument(),
    );
    expect(screen.getByText('Issue Grant')).toBeInTheDocument();
  });
});
