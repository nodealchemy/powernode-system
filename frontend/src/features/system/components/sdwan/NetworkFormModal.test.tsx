import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworkFormModal } from './NetworkFormModal';
import type { SdwanNetwork } from '../../types/sdwan.types';

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
const mockUpdateNetwork = jest.fn();
jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    createNetwork: (...args: unknown[]) => mockCreateNetwork(...args),
    updateNetwork: (...args: unknown[]) => mockUpdateNetwork(...args),
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
  // network={null} IS create mode — the whole point of the collapse.
  return render(
    <NetworkFormModal
      isOpen={isOpen}
      network={null}
      onClose={onClose}
      onSaved={onCreated}
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
  return screen.getByRole('radio', { name: /accept all/i });
}

function getDropRadio() {
  return screen.getByRole('radio', { name: /drop all/i });
}

// =============================================================================
// Tests
// =============================================================================

const BASE_NETWORK: SdwanNetwork = {
  id: 'net-abc',
  name: 'prod-overlay',
  slug: 'prod-overlay',
  status: 'active',
  cidr_64: 'fd00::/64',
  description: 'Production WireGuard overlay',
  peer_count: 3,
  settings: { firewall_default_policy: 'accept' },
  created_at: '2026-01-01T00:00:00Z',
};

const renderEditModal = (
  props: Partial<React.ComponentProps<typeof NetworkFormModal>> = {}
) => {
  const onClose = jest.fn();
  const onSaved = jest.fn();

  render(
    <BrowserRouter>
      <NetworkFormModal
        isOpen={true}
        network={BASE_NETWORK}
        onClose={onClose}
        onSaved={onSaved}
        {...props}
      />
    </BrowserRouter>
  );

  return { onClose, onSaved };
};

describe('NetworkFormModal — create mode (network=null)', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockCreateNetwork.mockReset();
    mockUpdateNetwork.mockReset();
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

  it('initialises the firewall policy to "accept" (Accept all)', () => {
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

describe('NetworkFormModal — edit mode (network given)', () => {
  beforeEach(() => {
    mockUpdateNetwork.mockReset();
    mockAddNotification.mockReset();
  });

  // ──── Null / closed guard ─────────────────────────────────────────────────

  // network={null} no longer renders nothing — it IS create mode. The create
  // half above covers that path; here we only assert the two modes are the same
  // component and that create mode carries no Status select.
  it('renders create mode, not an empty tree, when the network prop is null', () => {
    render(
      <BrowserRouter>
        <NetworkFormModal
          isOpen={true}
          network={null}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );
    expect(screen.getByTestId('modal-title')).toHaveTextContent('Create SDWAN network');
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
  });

  it('renders nothing when isOpen is false', () => {
    const { container } = render(
      <BrowserRouter>
        <NetworkFormModal
          isOpen={false}
          network={BASE_NETWORK}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );
    expect(container).toBeEmptyDOMElement();
  });

  // ──── Initial render + field population ──────────────────────────────────

  it('shows modal title as "Edit <network name>"', () => {
    renderEditModal();
    expect(screen.getByText('Edit prod-overlay')).toBeInTheDocument();
  });

  it('populates name field from network prop', () => {
    renderEditModal();
    expect(screen.getByDisplayValue('prod-overlay')).toBeInTheDocument();
  });

  it('populates description field from network prop', () => {
    renderEditModal();
    expect(screen.getByDisplayValue('Production WireGuard overlay')).toBeInTheDocument();
  });

  it('populates status select from network prop', () => {
    renderEditModal();
    const statusSelect = screen.getByRole('combobox') as HTMLSelectElement;
    expect(statusSelect.value).toBe('active');
  });

  it('pre-selects "Accept all" firewall policy radio from network settings', () => {
    renderEditModal();
    const acceptRadio = screen.getByRole('radio', { name: /accept all/i }) as HTMLInputElement;
    expect(acceptRadio.checked).toBe(true);
  });

  it('pre-selects "Drop all" radio when network settings has drop policy', () => {
    renderEditModal({
      network: {
        ...BASE_NETWORK,
        settings: { firewall_default_policy: 'drop' },
      },
    });
    const dropRadio = screen.getByRole('radio', { name: /drop all/i }) as HTMLInputElement;
    expect(dropRadio.checked).toBe(true);
  });

  it('defaults firewall policy to "accept" when settings is absent', () => {
    renderEditModal({
      network: { ...BASE_NETWORK, settings: undefined },
    });
    const acceptRadio = screen.getByRole('radio', { name: /accept all/i }) as HTMLInputElement;
    expect(acceptRadio.checked).toBe(true);
  });

  it('renders empty description when network has no description', () => {
    renderEditModal({
      network: { ...BASE_NETWORK, description: undefined },
    });
    // The textarea has no htmlFor/aria-label — query all textboxes and find
    // the one that is a <textarea> element (i.e. the description field).
    const textboxes = screen.getAllByRole('textbox');
    const textarea = textboxes.find(
      (el) => el.tagName.toLowerCase() === 'textarea'
    ) as HTMLTextAreaElement | undefined;
    expect(textarea).toBeTruthy();
    expect(textarea!.value).toBe('');
  });

  // ──── Status select options ───────────────────────────────────────────────

  it('shows all four status options', () => {
    renderEditModal();
    const select = screen.getByRole('combobox') as HTMLSelectElement;
    const optionValues = Array.from(select.options).map((o) => o.value);
    expect(optionValues).toEqual(['registered', 'active', 'suspended', 'archived']);
  });

  it('shows suspended-network hint text', () => {
    renderEditModal();
    expect(
      screen.getByText(/suspended networks compile a default-deny ruleset/i)
    ).toBeInTheDocument();
  });

  // ──── Validation: name required ───────────────────────────────────────────

  it('disables Save button when name is cleared', () => {
    renderEditModal();
    const nameInput = screen.getByDisplayValue('prod-overlay');
    fireEvent.change(nameInput, { target: { value: '' } });
    expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();
  });

  it('disables Save button when name is whitespace only', () => {
    renderEditModal();
    const nameInput = screen.getByDisplayValue('prod-overlay');
    fireEvent.change(nameInput, { target: { value: '   ' } });
    expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();
  });

  it('enables Save button when name is non-empty', () => {
    renderEditModal();
    expect(screen.getByRole('button', { name: /save changes/i })).not.toBeDisabled();
  });

  // ──── Successful submit ───────────────────────────────────────────────────

  it('calls sdwanApi.updateNetwork with the id and payload on submit', async () => {
    mockUpdateNetwork.mockResolvedValueOnce({ ...BASE_NETWORK });

    const { onSaved, onClose } = renderEditModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockUpdateNetwork).toHaveBeenCalledTimes(1));

    expect(mockUpdateNetwork).toHaveBeenCalledWith(BASE_NETWORK.id, {
      name: 'prod-overlay',
      description: 'Production WireGuard overlay',
      status: 'active',
      settings: { firewall_default_policy: 'accept' },
    });

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' })
    );
  });

  it('sends trimmed name in the payload', async () => {
    mockUpdateNetwork.mockResolvedValueOnce(BASE_NETWORK);

    renderEditModal();

    const nameInput = screen.getByDisplayValue('prod-overlay');
    fireEvent.change(nameInput, { target: { value: '  trimmed-name  ' } });

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockUpdateNetwork).toHaveBeenCalledTimes(1));

    const [, payload] = mockUpdateNetwork.mock.calls[0] as [string, { name: string }];
    expect(payload.name).toBe('trimmed-name');
  });

  it('sends description as undefined when textarea is blank', async () => {
    mockUpdateNetwork.mockResolvedValueOnce(BASE_NETWORK);

    renderEditModal({ network: { ...BASE_NETWORK, description: undefined } });

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockUpdateNetwork).toHaveBeenCalledTimes(1));

    const [, payload] = mockUpdateNetwork.mock.calls[0] as [string, { description: unknown }];
    expect(payload.description).toBeUndefined();
  });

  it('sends trimmed description in the payload', async () => {
    mockUpdateNetwork.mockResolvedValueOnce(BASE_NETWORK);

    renderEditModal();

    const descField = screen.getByDisplayValue('Production WireGuard overlay');
    fireEvent.change(descField, { target: { value: '  new description  ' } });

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockUpdateNetwork).toHaveBeenCalledTimes(1));

    const [, payload] = mockUpdateNetwork.mock.calls[0] as [string, { description: string }];
    expect(payload.description).toBe('new description');
  });

  it('sends selected status in the payload', async () => {
    mockUpdateNetwork.mockResolvedValueOnce(BASE_NETWORK);

    renderEditModal();

    const statusSelect = screen.getByRole('combobox');
    fireEvent.change(statusSelect, { target: { value: 'suspended' } });

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockUpdateNetwork).toHaveBeenCalledTimes(1));

    const [, payload] = mockUpdateNetwork.mock.calls[0] as [string, { status: string }];
    expect(payload.status).toBe('suspended');
  });

  it('sends updated firewall policy when "Drop all" is selected', async () => {
    mockUpdateNetwork.mockResolvedValueOnce(BASE_NETWORK);

    renderEditModal();

    const dropRadio = screen.getByRole('radio', { name: /drop all/i });
    fireEvent.click(dropRadio);

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockUpdateNetwork).toHaveBeenCalledTimes(1));

    const [, payload] = mockUpdateNetwork.mock.calls[0] as [string, { settings: { firewall_default_policy: string } }];
    expect(payload.settings.firewall_default_policy).toBe('drop');
  });

  it('merges existing settings keys when updating firewall policy', async () => {
    mockUpdateNetwork.mockResolvedValueOnce(BASE_NETWORK);

    renderEditModal({
      network: {
        ...BASE_NETWORK,
        settings: { firewall_default_policy: 'accept', custom_key: 'preserved' },
      },
    });

    const dropRadio = screen.getByRole('radio', { name: /drop all/i });
    fireEvent.click(dropRadio);

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockUpdateNetwork).toHaveBeenCalledTimes(1));

    const [, payload] = mockUpdateNetwork.mock.calls[0] as [
      string,
      { settings: Record<string, unknown> }
    ];
    expect(payload.settings.custom_key).toBe('preserved');
    expect(payload.settings.firewall_default_policy).toBe('drop');
  });

  it('sends settings: { firewall_default_policy: "accept" } when network has no prior settings', async () => {
    mockUpdateNetwork.mockResolvedValueOnce(BASE_NETWORK);

    renderEditModal({ network: { ...BASE_NETWORK, settings: undefined } });

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockUpdateNetwork).toHaveBeenCalledTimes(1));

    const [, payload] = mockUpdateNetwork.mock.calls[0] as [string, { settings: { firewall_default_policy: string } }];
    expect(payload.settings.firewall_default_policy).toBe('accept');
  });

  // ──── Success notification message content ───────────────────────────────

  it('includes the network name in the success notification', async () => {
    mockUpdateNetwork.mockResolvedValueOnce(BASE_NETWORK);

    renderEditModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'success',
          message: 'Network "prod-overlay" updated',
        })
      )
    );
  });

  // ──── Error handling ──────────────────────────────────────────────────────

  it('shows error notification when API rejects with an Error', async () => {
    mockUpdateNetwork.mockRejectedValueOnce(new Error('Network unreachable'));

    const { onSaved, onClose } = renderEditModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Network unreachable' })
      )
    );

    expect(onSaved).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('shows generic "Update failed" message when API rejects with a non-Error', async () => {
    mockUpdateNetwork.mockRejectedValueOnce('oops');

    renderEditModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Update failed' })
      )
    );
  });

  // ──── Submitting state ────────────────────────────────────────────────────

  it('shows "Saving…" text on the button while submitting', async () => {
    let resolvePut!: (v: unknown) => void;
    mockUpdateNetwork.mockReturnValueOnce(
      new Promise((res) => { resolvePut = res; })
    );

    renderEditModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(screen.getByText(/saving…/i)).toBeInTheDocument()
    );

    // Resolve to avoid act() warnings
    resolvePut(BASE_NETWORK);
    await waitFor(() =>
      expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument()
    );
  });

  it('disables all form controls while submitting', async () => {
    let resolvePut!: (v: unknown) => void;
    mockUpdateNetwork.mockReturnValueOnce(
      new Promise((res) => { resolvePut = res; })
    );

    renderEditModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(screen.getByText(/saving…/i)).toBeInTheDocument()
    );

    // All inputs/selects/textareas should be disabled
    expect(screen.getByDisplayValue('prod-overlay')).toBeDisabled();
    expect(screen.getByRole('combobox')).toBeDisabled();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();
    // Both radios should be disabled
    screen.getAllByRole('radio').forEach((r) => expect(r).toBeDisabled());

    resolvePut(BASE_NETWORK);
    await waitFor(() =>
      expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument()
    );
  });

  it('does not re-submit if form is submitted while already submitting', async () => {
    let resolvePut!: (v: unknown) => void;
    mockUpdateNetwork.mockReturnValue(
      new Promise((res) => { resolvePut = res; })
    );

    renderEditModal();

    const form = screen.getByRole('button', { name: /save changes/i }).closest('form')!;
    fireEvent.submit(form);
    fireEvent.submit(form);
    fireEvent.submit(form);

    await waitFor(() =>
      expect(screen.getByText(/saving…/i)).toBeInTheDocument()
    );

    expect(mockUpdateNetwork).toHaveBeenCalledTimes(1);

    resolvePut(BASE_NETWORK);
    await waitFor(() =>
      expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument()
    );
  });

  // ──── Cancel button ───────────────────────────────────────────────────────

  it('calls onClose when Cancel is clicked and leaves the edit fields seeded', () => {
    const { onClose } = renderEditModal();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
    // handleClose resets only in create mode. Blanking an edit form on close is
    // the regression the collapse had to avoid: the seeding effect keys on the
    // network's identity, so a reopened form would stay empty.
    expect(screen.getByDisplayValue('prod-overlay')).toBeInTheDocument();
    expect(screen.getByDisplayValue('Production WireGuard overlay')).toBeInTheDocument();
  });

  // ──── Re-initialisation when network prop changes ─────────────────────────

  it('updates form fields when network prop changes', () => {
    const { rerender } = render(
      <BrowserRouter>
        <NetworkFormModal
          isOpen={true}
          network={BASE_NETWORK}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );

    expect(screen.getByDisplayValue('prod-overlay')).toBeInTheDocument();

    const newNetwork: SdwanNetwork = {
      ...BASE_NETWORK,
      id: 'net-xyz',
      name: 'dev-overlay',
      description: 'Dev network',
      status: 'registered',
      settings: { firewall_default_policy: 'drop' },
    };

    rerender(
      <BrowserRouter>
        <NetworkFormModal
          isOpen={true}
          network={newNetwork}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );

    expect(screen.getByDisplayValue('dev-overlay')).toBeInTheDocument();
    expect(screen.getByDisplayValue('Dev network')).toBeInTheDocument();
    const statusSelect = screen.getByRole('combobox') as HTMLSelectElement;
    expect(statusSelect.value).toBe('registered');
    const dropRadio = screen.getByRole('radio', { name: /drop all/i }) as HTMLInputElement;
    expect(dropRadio.checked).toBe(true);
  });

  // ──── Pending-approval branch (IMP-87ec6f651f07) ──────────────────────────

  it('shows the pending-approval notification (not success) and skips onSaved when the update is parked', async () => {
    mockUpdateNetwork.mockResolvedValueOnce({
      pending: true,
      deferred_operation_id: 'dop-1',
      action_category: 'sdwan.network_update',
      approval_request_id: 'ar-1',
      message: 'Approval required',
    });

    const { onSaved, onClose } = renderEditModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval required/i),
          link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
        })
      )
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' })
    );
    expect(onSaved).not.toHaveBeenCalled();
    expect(onClose).toHaveBeenCalled();
  });
});
