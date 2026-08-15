import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { NetworkCreateModal } from './NetworkCreateModal';

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
// query elements normally.
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
const mockCreateNetwork = jest.fn();
jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    createNetwork: (...args: unknown[]) => mockCreateNetwork(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK = {
  id: 'net-001',
  name: 'edge-overlay',
  description: 'An overlay network',
  status: 'active',
  cidr: 'fd00::/64',
  created_at: '2026-06-05T00:00:00Z',
};

// The sdwanApi facade resolves to the unwrapped value (extractData strips the
// HTTP envelope). Double-envelope is only needed when mocking apiClient.post
// directly; here we mock at the facade boundary.
function resolvedNetwork(network = NETWORK) {
  return Promise.resolve(network);
}

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  onClose?: () => void;
  onCreated?: () => void;
}

function renderModal({
  isOpen = true,
  onClose = jest.fn(),
  onCreated = jest.fn(),
}: RenderProps = {}) {
  return render(
    <NetworkCreateModal
      isOpen={isOpen}
      onClose={onClose}
      onCreated={onCreated}
    />,
  );
}

function getNameInput() {
  return screen.getByPlaceholderText('e.g. edge-overlay');
}

function getDescriptionTextarea() {
  return screen.getByPlaceholderText('What is this network for?');
}

function getCreateButton() {
  return screen.getByRole('button', { name: /^create$/i });
}

function getCancelButton() {
  return screen.getByRole('button', { name: /cancel/i });
}

function getAcceptRadio() {
  return screen.getByRole('radio', { name: /allow all by default/i });
}

function getDropRadio() {
  return screen.getByRole('radio', { name: /drop all by default/i });
}

// =============================================================================
// Tests
// =============================================================================

describe('NetworkCreateModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockCreateNetwork.mockReset();
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
    expect(screen.getByTestId('modal-title')).toHaveTextContent(
      'Create SDWAN network',
    );
  });

  // ---------------------------------------------------------------------------
  // Form fields rendering
  // ---------------------------------------------------------------------------

  it('renders the Name field with a label and placeholder', () => {
    renderModal();
    expect(screen.getByText('Name')).toBeInTheDocument();
    expect(getNameInput()).toBeInTheDocument();
  });

  it('renders the Description field with a label and placeholder', () => {
    renderModal();
    expect(screen.getByText('Description (optional)')).toBeInTheDocument();
    expect(getDescriptionTextarea()).toBeInTheDocument();
  });

  it('renders the Default firewall policy label and help text', () => {
    renderModal();
    expect(screen.getByText('Default firewall policy')).toBeInTheDocument();
    expect(
      screen.getByText(/The \/64 CIDR is auto-allocated/i),
    ).toBeInTheDocument();
  });

  it('renders two firewall policy radio buttons', () => {
    renderModal();
    expect(getAcceptRadio()).toBeInTheDocument();
    expect(getDropRadio()).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Initial state
  // ---------------------------------------------------------------------------

  it('initialises the Name field as empty', () => {
    renderModal();
    expect(getNameInput()).toHaveValue('');
  });

  it('initialises the Description field as empty', () => {
    renderModal();
    expect(getDescriptionTextarea()).toHaveValue('');
  });

  it('initialises the firewall policy to "accept" (Allow all)', () => {
    renderModal();
    expect(getAcceptRadio()).toBeChecked();
    expect(getDropRadio()).not.toBeChecked();
  });

  it('renders the Create button disabled when Name is empty', () => {
    renderModal();
    expect(getCreateButton()).toBeDisabled();
  });

  it('enables the Create button once the Name field has content', () => {
    renderModal();
    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    expect(getCreateButton()).not.toBeDisabled();
  });

  it('disables Create again when name is cleared back to empty', () => {
    renderModal();
    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    expect(getCreateButton()).not.toBeDisabled();
    fireEvent.change(getNameInput(), { target: { value: '' } });
    expect(getCreateButton()).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Validation — empty / whitespace-only name
  // ---------------------------------------------------------------------------

  it('shows "Name is required" notification when submitting with a whitespace-only name', async () => {
    renderModal();

    // Whitespace-only name keeps button disabled (name.trim() === ''), so we
    // submit via the form element directly to exercise the guard.
    fireEvent.change(getNameInput(), { target: { value: '   ' } });

    const form = screen.getByTestId('modal').querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Name is required',
      }),
    );
    expect(mockCreateNetwork).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Successful submission — accept policy (default)
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.createNetwork with trimmed name, no description, and no settings when policy is accept', async () => {
    mockCreateNetwork.mockReturnValue(resolvedNetwork());

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: '  edge-overlay  ' } });

    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockCreateNetwork).toHaveBeenCalledWith({
        name: 'edge-overlay',
        description: undefined,
        settings: undefined,
      }),
    );
  });

  it('includes trimmed description when provided', async () => {
    mockCreateNetwork.mockReturnValue(resolvedNetwork());

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.change(getDescriptionTextarea(), {
      target: { value: '  An overlay network  ' },
    });

    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockCreateNetwork).toHaveBeenCalledWith({
        name: 'edge-overlay',
        description: 'An overlay network',
        settings: undefined,
      }),
    );
  });

  it('sends description as undefined when description field is left blank', async () => {
    mockCreateNetwork.mockReturnValue(resolvedNetwork());

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });

    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockCreateNetwork).toHaveBeenCalledWith(
        expect.objectContaining({ description: undefined }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Successful submission — drop policy
  // ---------------------------------------------------------------------------

  it('sends settings.firewall_default_policy="drop" when drop radio is selected', async () => {
    mockCreateNetwork.mockReturnValue(resolvedNetwork());

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'secure-net' } });
    fireEvent.click(getDropRadio());

    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockCreateNetwork).toHaveBeenCalledWith({
        name: 'secure-net',
        description: undefined,
        settings: { firewall_default_policy: 'drop' },
      }),
    );
  });

  it('sends settings as undefined when accept policy is selected', async () => {
    mockCreateNetwork.mockReturnValue(resolvedNetwork());

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'open-net' } });
    // accept is the default; ensure it sends undefined
    expect(getAcceptRadio()).toBeChecked();

    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockCreateNetwork).toHaveBeenCalledWith(
        expect.objectContaining({ settings: undefined }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Callbacks after success
  // ---------------------------------------------------------------------------

  it('fires onCreated after a successful submission', async () => {
    mockCreateNetwork.mockReturnValue(resolvedNetwork());
    const onCreated = jest.fn();

    renderModal({ onCreated });

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() => expect(onCreated).toHaveBeenCalledTimes(1));
  });

  it('fires onClose after a successful submission', async () => {
    mockCreateNetwork.mockReturnValue(resolvedNetwork());
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
  });

  it('shows a success notification with the network name after successful creation', async () => {
    mockCreateNetwork.mockReturnValue(resolvedNetwork());

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Network "edge-overlay" created',
      }),
    );
  });

  it('resets all fields after a successful submission', async () => {
    mockCreateNetwork.mockReturnValue(resolvedNetwork());
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.change(getDescriptionTextarea(), {
      target: { value: 'A description' },
    });
    fireEvent.click(getDropRadio());

    fireEvent.click(getCreateButton());

    await waitFor(() => expect(onClose).toHaveBeenCalled());

    // State is cleared after reset() + onClose() runs.
    expect(getNameInput()).toHaveValue('');
    expect(getDescriptionTextarea()).toHaveValue('');
    expect(getAcceptRadio()).toBeChecked();
    expect(getDropRadio()).not.toBeChecked();
  });

  // ---------------------------------------------------------------------------
  // Submission — in-flight state
  // ---------------------------------------------------------------------------

  it('shows "Creating…" on the submit button while the request is in-flight', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateNetwork.mockReturnValue(
      new Promise((r) => {
        resolveFn = r;
      }),
    );

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(
        screen.getByRole('button', { name: /creating/i }),
      ).toBeInTheDocument(),
    );

    // Resolve to avoid act() warning
    resolveFn(NETWORK);
    await waitFor(() =>
      expect(
        screen.queryByRole('button', { name: /creating/i }),
      ).not.toBeInTheDocument(),
    );
  });

  it('disables the Cancel button while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateNetwork.mockReturnValue(
      new Promise((r) => {
        resolveFn = r;
      }),
    );

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() => expect(getCancelButton()).toBeDisabled());

    resolveFn(NETWORK);
    await waitFor(() =>
      expect(
        screen.queryByRole('button', { name: /creating/i }),
      ).not.toBeInTheDocument(),
    );
  });

  it('disables the Name and Description inputs while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateNetwork.mockReturnValue(
      new Promise((r) => {
        resolveFn = r;
      }),
    );

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() => expect(getNameInput()).toBeDisabled());
    expect(getDescriptionTextarea()).toBeDisabled();

    resolveFn(NETWORK);
    await waitFor(() =>
      expect(
        screen.queryByRole('button', { name: /creating/i }),
      ).not.toBeInTheDocument(),
    );
  });

  it('disables the firewall policy radios while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateNetwork.mockReturnValue(
      new Promise((r) => {
        resolveFn = r;
      }),
    );

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() => expect(getAcceptRadio()).toBeDisabled());
    expect(getDropRadio()).toBeDisabled();

    resolveFn(NETWORK);
    await waitFor(() =>
      expect(
        screen.queryByRole('button', { name: /creating/i }),
      ).not.toBeInTheDocument(),
    );
  });

  it('does not call createNetwork a second time if clicked again while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateNetwork.mockReturnValue(
      new Promise((r) => {
        resolveFn = r;
      }),
    );

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    // Button is now disabled (submitting=true), click again has no effect
    await waitFor(() =>
      expect(
        screen.getByRole('button', { name: /creating/i }),
      ).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /creating/i }));

    resolveFn(NETWORK);
    await waitFor(() =>
      expect(mockCreateNetwork).toHaveBeenCalledTimes(1),
    );
  });

  // ---------------------------------------------------------------------------
  // Error path
  // ---------------------------------------------------------------------------

  it('shows an error notification with the Error message when creation fails', async () => {
    mockCreateNetwork.mockRejectedValue(new Error('Network name already taken'));

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network name already taken',
      }),
    );
  });

  it('shows "Failed to create network" when creation throws a non-Error value', async () => {
    mockCreateNetwork.mockRejectedValue('something went wrong');

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create network',
      }),
    );
  });

  it('does not call onCreated or onClose when creation fails', async () => {
    mockCreateNetwork.mockRejectedValue(new Error('server error'));
    const onCreated = jest.fn();
    const onClose = jest.fn();

    renderModal({ onCreated, onClose });

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onCreated).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('re-enables the submit button after a failed submission', async () => {
    mockCreateNetwork.mockRejectedValue(new Error('server error'));

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    // After failure, submitting resets to false; button is enabled because
    // name is still populated.
    expect(getCreateButton()).not.toBeDisabled();
  });

  it('preserves the entered name and description after a failed submission', async () => {
    mockCreateNetwork.mockRejectedValue(new Error('server error'));

    renderModal();

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.change(getDescriptionTextarea(), {
      target: { value: 'my description' },
    });
    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(getNameInput()).toHaveValue('edge-overlay');
    expect(getDescriptionTextarea()).toHaveValue('my description');
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel is clicked and not submitting', () => {
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.click(getCancelButton());

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(mockCreateNetwork).not.toHaveBeenCalled();
  });

  it('resets the form fields when Cancel is clicked', () => {
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getNameInput(), { target: { value: 'my-net' } });
    fireEvent.change(getDescriptionTextarea(), {
      target: { value: 'some desc' },
    });
    fireEvent.click(getDropRadio());

    fireEvent.click(getCancelButton());

    expect(getNameInput()).toHaveValue('');
    expect(getDescriptionTextarea()).toHaveValue('');
    expect(getAcceptRadio()).toBeChecked();
    expect(getDropRadio()).not.toBeChecked();
  });

  it('does not call onClose when Cancel is clicked while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateNetwork.mockReturnValue(
      new Promise((r) => {
        resolveFn = r;
      }),
    );
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

    await waitFor(() =>
      expect(
        screen.getByRole('button', { name: /creating/i }),
      ).toBeInTheDocument(),
    );

    // Cancel is disabled while submitting; the handleClose guard also prevents it
    fireEvent.click(getCancelButton());
    expect(onClose).not.toHaveBeenCalled();

    resolveFn(NETWORK);
    // onClose is called after successful resolution (not from cancel)
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
  });

  // ---------------------------------------------------------------------------
  // Firewall policy toggle
  // ---------------------------------------------------------------------------

  it('switches policy to drop when the Drop radio is clicked', () => {
    renderModal();

    expect(getAcceptRadio()).toBeChecked();
    fireEvent.click(getDropRadio());
    expect(getDropRadio()).toBeChecked();
    expect(getAcceptRadio()).not.toBeChecked();
  });

  it('switches policy back to accept from drop', () => {
    renderModal();

    fireEvent.click(getDropRadio());
    expect(getDropRadio()).toBeChecked();

    fireEvent.click(getAcceptRadio());
    expect(getAcceptRadio()).toBeChecked();
    expect(getDropRadio()).not.toBeChecked();
  });

  // ---------------------------------------------------------------------------
  // Form submit via native onSubmit
  // ---------------------------------------------------------------------------

  it('submitting the form element directly triggers the same flow as the button', async () => {
    mockCreateNetwork.mockReturnValue(resolvedNetwork());
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });

    const form = screen.getByTestId('modal').querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(mockCreateNetwork).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Pending-approval branch (IMP-87ec6f651f07)
  // ---------------------------------------------------------------------------

  it('shows the pending-approval notification (not success) and skips onCreated when the create is parked', async () => {
    mockCreateNetwork.mockResolvedValue({
      pending: true,
      deferred_operation_id: 'dop-1',
      action_category: 'sdwan.network_create',
      approval_request_id: 'ar-1',
      message: 'Approval required',
    });
    const onCreated = jest.fn();
    const onClose = jest.fn();

    renderModal({ onCreated, onClose });

    fireEvent.change(getNameInput(), { target: { value: 'edge-overlay' } });
    fireEvent.click(getCreateButton());

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
    expect(onCreated).not.toHaveBeenCalled();
    expect(onClose).toHaveBeenCalled();
  });
});
