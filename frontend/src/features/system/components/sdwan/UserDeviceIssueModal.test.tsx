import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { UserDeviceIssueModal } from './UserDeviceIssueModal';

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

// Mock Modal: render children only when isOpen; skip the portal so jsdom can
// query the elements normally.
jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({
    isOpen,
    children,
    title,
    onClose,
  }: {
    isOpen: boolean;
    children: React.ReactNode;
    title?: string;
    onClose: () => void;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="modal">
        <span data-testid="modal-title">{title}</span>
        <button data-testid="modal-close" onClick={onClose}>
          ×
        </button>
        {children}
      </div>
    );
  },
}));

// Mock Button: render a real <button> so role queries + disabled work.
jest.mock('@/shared/components/ui/Button', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    variant,
    type,
  }: {
    children: React.ReactNode;
    onClick?: (e: React.MouseEvent) => void;
    disabled?: boolean;
    variant?: string;
    type?: 'button' | 'submit' | 'reset';
  }) => (
    <button
      onClick={onClick}
      disabled={disabled}
      data-variant={variant}
      type={type ?? 'button'}
    >
      {children}
    </button>
  ),
}));

// sdwanApi is the direct import the component uses.
const mockIssueUserDevice = jest.fn();
jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    issueUserDevice: (...args: unknown[]) => mockIssueUserDevice(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_ID = 'net-abc-123';
const GRANT_ID = 'grant-xyz-789';

const ISSUED_DEVICE = {
  id: 'dev-001',
  access_grant_id: GRANT_ID,
  network_id: NETWORK_ID,
  label: 'macbook',
  public_key: 'wg-public-key-abc',
  assigned_address: '10.0.0.2/32',
  downloadable: true,
  last_downloaded_at: null,
  last_seen_at: null,
  revoked_at: null,
  created_at: '2026-06-05T00:00:00Z',
};

const ISSUED_RESPONSE = {
  user_device: ISSUED_DEVICE,
  bootstrap: {
    token: 'tok-abc',
    url: 'https://vpn.example.com/bootstrap/tok-abc',
    expires_at: '2026-06-05T01:00:00Z',
  },
};

// sdwanApi resolves to the unwrapped value (extractData already strips the HTTP
// envelope). Double-envelope is only needed when mocking apiClient directly;
// here we mock at the facade boundary.
function resolvedResponse(response = ISSUED_RESPONSE) {
  return Promise.resolve(response);
}

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  networkId?: string;
  grantId?: string;
  onClose?: () => void;
  onIssued?: (result: typeof ISSUED_RESPONSE) => void;
}

function renderModal({
  isOpen = true,
  networkId = NETWORK_ID,
  grantId = GRANT_ID,
  onClose = jest.fn(),
  onIssued = jest.fn(),
}: RenderProps = {}) {
  return render(
    <UserDeviceIssueModal
      isOpen={isOpen}
      networkId={networkId}
      grantId={grantId}
      onClose={onClose}
      onIssued={onIssued}
    />,
  );
}

function getLabelInput() {
  return screen.getByPlaceholderText('e.g. macbook, phone, work-laptop');
}

function getIssueButton() {
  return screen.getByRole('button', { name: /^issue$/i });
}

function getCancelButton() {
  return screen.getByRole('button', { name: /cancel/i });
}

// =============================================================================
// Tests
// =============================================================================

describe('UserDeviceIssueModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockIssueUserDevice.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Visibility
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
  });

  it('renders the modal with the correct title when isOpen is true', () => {
    renderModal();
    expect(screen.getByTestId('modal')).toBeInTheDocument();
    expect(screen.getByTestId('modal-title')).toHaveTextContent('Issue VPN device');
  });

  // ---------------------------------------------------------------------------
  // Field rendering
  // ---------------------------------------------------------------------------

  it('renders the Device label field with a visible label', () => {
    renderModal();
    expect(screen.getByText('Device label')).toBeInTheDocument();
    expect(getLabelInput()).toBeInTheDocument();
  });

  it('renders the help text about keypair generation and single-use URL', () => {
    renderModal();
    expect(
      screen.getByText(/keypair is generated server-side/i),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/single-use url on the next screen/i),
    ).toBeInTheDocument();
  });

  it('renders the Cancel and Issue buttons', () => {
    renderModal();
    expect(getCancelButton()).toBeInTheDocument();
    expect(getIssueButton()).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Initial field state
  // ---------------------------------------------------------------------------

  it('initialises the label field as empty', () => {
    renderModal();
    expect(getLabelInput()).toHaveValue('');
  });

  it('renders the Issue button disabled when the label field is empty', () => {
    renderModal();
    expect(getIssueButton()).toBeDisabled();
  });

  it('enables the Issue button once the label field has non-whitespace content', () => {
    renderModal();
    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    expect(getIssueButton()).not.toBeDisabled();
  });

  it('keeps the Issue button disabled when the label contains only whitespace', () => {
    renderModal();
    fireEvent.change(getLabelInput(), { target: { value: '   ' } });
    expect(getIssueButton()).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Successful submission
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.issueUserDevice with networkId, grantId, and trimmed label', async () => {
    mockIssueUserDevice.mockReturnValue(resolvedResponse());

    renderModal({ networkId: NETWORK_ID, grantId: GRANT_ID });

    fireEvent.change(getLabelInput(), { target: { value: '  macbook  ' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(mockIssueUserDevice).toHaveBeenCalledWith(
        NETWORK_ID,
        GRANT_ID,
        { label: 'macbook' },
      ),
    );
  });

  it('calls sdwanApi.issueUserDevice exactly once per submission', async () => {
    mockIssueUserDevice.mockReturnValue(resolvedResponse());

    renderModal();

    fireEvent.change(getLabelInput(), { target: { value: 'phone' } });
    fireEvent.click(getIssueButton());

    await waitFor(() => expect(mockIssueUserDevice).toHaveBeenCalledTimes(1));
  });

  it('shows a success notification with the device label after successful submission', async () => {
    mockIssueUserDevice.mockReturnValue(resolvedResponse());

    renderModal();

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Device "macbook" issued',
      }),
    );
  });

  it('calls onIssued with the API result after successful submission', async () => {
    mockIssueUserDevice.mockReturnValue(resolvedResponse());
    const onIssued = jest.fn();

    renderModal({ onIssued });

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(onIssued).toHaveBeenCalledWith(ISSUED_RESPONSE),
    );
  });

  it('calls onClose after successful submission', async () => {
    mockIssueUserDevice.mockReturnValue(resolvedResponse());
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
  });

  it('resets the label field to empty after successful submission', async () => {
    mockIssueUserDevice.mockReturnValue(resolvedResponse());
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(getLabelInput()).toHaveValue('');
  });

  // ---------------------------------------------------------------------------
  // In-flight / submitting state
  // ---------------------------------------------------------------------------

  it('shows "Generating keypair…" on the submit button while the request is in-flight', async () => {
    let resolveFn!: (v: unknown) => void;
    mockIssueUserDevice.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(
        screen.getByRole('button', { name: /generating keypair/i }),
      ).toBeInTheDocument(),
    );

    // Resolve to flush the promise chain; the component calls onClose() on
    // success (the parent unmounts the modal). Verify that pathway.
    resolveFn(ISSUED_RESPONSE);
    await waitFor(() => expect(onClose).toHaveBeenCalled());
  });

  it('disables the Cancel button while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockIssueUserDevice.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() => expect(getCancelButton()).toBeDisabled());

    // Resolve; success path calls onClose so parent would close the modal.
    resolveFn(ISSUED_RESPONSE);
    await waitFor(() => expect(onClose).toHaveBeenCalled());
  });

  it('disables the label input while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockIssueUserDevice.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() => expect(getLabelInput()).toBeDisabled());

    // Resolve; success path calls onClose so parent would close the modal.
    resolveFn(ISSUED_RESPONSE);
    await waitFor(() => expect(onClose).toHaveBeenCalled());
  });

  // ---------------------------------------------------------------------------
  // Validation — empty / whitespace label
  // ---------------------------------------------------------------------------

  it('does not call sdwanApi.issueUserDevice when the label is whitespace-only', async () => {
    renderModal();

    // The button is disabled for whitespace-only input; submit via form directly.
    fireEvent.change(getLabelInput(), { target: { value: '   ' } });

    const form = screen.getByTestId('modal').querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    // Allow microtask queue to flush.
    await waitFor(() => expect(mockIssueUserDevice).not.toHaveBeenCalled());
  });

  // ---------------------------------------------------------------------------
  // Error path
  // ---------------------------------------------------------------------------

  it('shows an error notification with the Error message when issuance fails', async () => {
    mockIssueUserDevice.mockRejectedValue(new Error('Quota exceeded'));

    renderModal();

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Quota exceeded',
      }),
    );
  });

  it('shows "Issue failed" when issuance throws a non-Error value', async () => {
    mockIssueUserDevice.mockRejectedValue('something bad');

    renderModal();

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Issue failed',
      }),
    );
  });

  it('does not call onIssued or onClose when issuance fails', async () => {
    mockIssueUserDevice.mockRejectedValue(new Error('server error'));
    const onIssued = jest.fn();
    const onClose = jest.fn();

    renderModal({ onIssued, onClose });

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onIssued).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('re-enables the Issue button after a failed submission (label still populated)', async () => {
    mockIssueUserDevice.mockRejectedValue(new Error('server error'));

    renderModal();

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    // submitting is false again; label is still "macbook" so button is enabled.
    expect(getIssueButton()).not.toBeDisabled();
  });

  it('re-enables the label input after a failed submission', async () => {
    mockIssueUserDevice.mockRejectedValue(new Error('network error'));

    renderModal();

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(getLabelInput()).not.toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Cancel button / handleClose
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel is clicked and not submitting', () => {
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.click(getCancelButton());

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(mockIssueUserDevice).not.toHaveBeenCalled();
  });

  it('resets the label field when Cancel is clicked', () => {
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getLabelInput(), { target: { value: 'work-laptop' } });
    fireEvent.click(getCancelButton());

    expect(getLabelInput()).toHaveValue('');
  });

  it('calls onClose via the modal X button (handleClose proxy)', () => {
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getLabelInput(), { target: { value: 'phone' } });
    fireEvent.click(screen.getByTestId('modal-close'));

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Form submit via native onSubmit
  // ---------------------------------------------------------------------------

  it('submitting the form element directly triggers the same flow as the button', async () => {
    mockIssueUserDevice.mockReturnValue(resolvedResponse());
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getLabelInput(), { target: { value: 'macbook' } });

    const form = screen.getByTestId('modal').querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(mockIssueUserDevice).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Exact API URL / payload shape
  // ---------------------------------------------------------------------------

  it('passes the label trimmed inside the { label } payload key', async () => {
    mockIssueUserDevice.mockReturnValue(resolvedResponse());

    renderModal();

    fireEvent.change(getLabelInput(), { target: { value: '  phone  ' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(mockIssueUserDevice).toHaveBeenCalledWith(
        expect.any(String),
        expect.any(String),
        { label: 'phone' },
      ),
    );
  });

  it('uses the exact networkId and grantId props when calling issueUserDevice', async () => {
    mockIssueUserDevice.mockReturnValue(resolvedResponse());

    const customNetworkId = 'net-custom-999';
    const customGrantId = 'grant-custom-888';

    renderModal({ networkId: customNetworkId, grantId: customGrantId });

    fireEvent.change(getLabelInput(), { target: { value: 'tablet' } });
    fireEvent.click(getIssueButton());

    await waitFor(() =>
      expect(mockIssueUserDevice).toHaveBeenCalledWith(
        customNetworkId,
        customGrantId,
        { label: 'tablet' },
      ),
    );
  });
});
