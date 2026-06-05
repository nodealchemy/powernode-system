import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { AccessGrantCreateModal } from './AccessGrantCreateModal';

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
const mockCreateAccessGrant = jest.fn();
jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    createAccessGrant: (...args: unknown[]) => mockCreateAccessGrant(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_ID = 'net-abc-123';

const GRANT = {
  id: 'grant-001',
  network_id: NETWORK_ID,
  user_id: '019d1111-2222-7000-a000-000000000001',
  status: 'active',
  tags: [],
  created_at: '2026-06-05T00:00:00Z',
};

// The sdwanApi facade resolves to the unwrapped value (extractData already
// strips the HTTP envelope). Double-envelope is only needed when mocking
// apiClient.post directly; here we mock at the facade boundary.
function resolvedGrant(grant = GRANT) {
  return Promise.resolve(grant);
}

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  networkId?: string;
  onClose?: () => void;
  onCreated?: () => void;
}

function renderModal({
  isOpen = true,
  networkId = NETWORK_ID,
  onClose = jest.fn(),
  onCreated = jest.fn(),
}: RenderProps = {}) {
  return render(
    <AccessGrantCreateModal
      isOpen={isOpen}
      networkId={networkId}
      onClose={onClose}
      onCreated={onCreated}
    />,
  );
}

function getUserIdInput() {
  return screen.getByPlaceholderText('019d…');
}

function getTagsInput() {
  return screen.getByPlaceholderText('vpn-pilot, contractor');
}

function getGrantButton() {
  return screen.getByRole('button', { name: /grant access/i });
}

function getCancelButton() {
  return screen.getByRole('button', { name: /cancel/i });
}

// =============================================================================
// Tests
// =============================================================================

describe('AccessGrantCreateModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockCreateAccessGrant.mockReset();
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
      'Grant network access to user',
    );
  });

  it('renders the User ID field with a label and placeholder', () => {
    renderModal();
    expect(
      screen.getByText(/user id \(uuid\)/i),
    ).toBeInTheDocument();
    expect(getUserIdInput()).toBeInTheDocument();
  });

  it('renders the Tags field with a label and placeholder', () => {
    renderModal();
    expect(
      screen.getByText(/tags \(comma-separated, optional\)/i),
    ).toBeInTheDocument();
    expect(getTagsInput()).toBeInTheDocument();
  });

  it('renders the help text about finding user IDs', () => {
    renderModal();
    expect(
      screen.getByText(/find user ids in the users panel/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Initial field state
  // ---------------------------------------------------------------------------

  it('initialises the User ID field as empty', () => {
    renderModal();
    expect(getUserIdInput()).toHaveValue('');
  });

  it('initialises the Tags field as empty', () => {
    renderModal();
    expect(getTagsInput()).toHaveValue('');
  });

  it('renders the Grant access button disabled when User ID is empty', () => {
    renderModal();
    expect(getGrantButton()).toBeDisabled();
  });

  it('enables the Grant access button once the User ID field has content', () => {
    renderModal();
    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    expect(getGrantButton()).not.toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Validation — empty User ID
  // ---------------------------------------------------------------------------

  it('shows "User ID is required" notification when submitting with only whitespace in the User ID field', async () => {
    renderModal();

    // The Grant access button is disabled for empty userId, so we force the
    // value to whitespace-only which passes the disabled check but still
    // fails the trim guard.
    fireEvent.change(getUserIdInput(), { target: { value: '   ' } });

    // The button is enabled now (value.trim() in disabled check differs from
    // the component logic: `disabled={submitting || !userId.trim()}` — since
    // '   '.trim() === '' the button stays disabled. So we submit via form.
    const form = screen.getByTestId('modal').querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'User ID is required',
      }),
    );
    expect(mockCreateAccessGrant).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Successful submission
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.createAccessGrant with networkId, trimmed userId, and empty tags on submit', async () => {
    mockCreateAccessGrant.mockReturnValue(resolvedGrant());

    renderModal({ networkId: NETWORK_ID });

    fireEvent.change(getUserIdInput(), {
      target: { value: '  019d1111-2222-7000-a000-000000000001  ' },
    });

    fireEvent.click(getGrantButton());

    await waitFor(() =>
      expect(mockCreateAccessGrant).toHaveBeenCalledWith(NETWORK_ID, {
        user_id: '019d1111-2222-7000-a000-000000000001',
        tags: [],
      }),
    );
  });

  it('parses comma-separated tags into a trimmed string array', async () => {
    mockCreateAccessGrant.mockReturnValue(resolvedGrant());

    renderModal();

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.change(getTagsInput(), {
      target: { value: ' vpn-pilot , contractor , ' },
    });

    fireEvent.click(getGrantButton());

    await waitFor(() =>
      expect(mockCreateAccessGrant).toHaveBeenCalledWith(NETWORK_ID, {
        user_id: '019d1111-2222-7000-a000-000000000001',
        tags: ['vpn-pilot', 'contractor'],
      }),
    );
  });

  it('sends an empty tags array when the tags field is blank', async () => {
    mockCreateAccessGrant.mockReturnValue(resolvedGrant());

    renderModal();

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });

    fireEvent.click(getGrantButton());

    await waitFor(() =>
      expect(mockCreateAccessGrant).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({ tags: [] }),
      ),
    );
  });

  it('fires onCreated after a successful submission', async () => {
    mockCreateAccessGrant.mockReturnValue(resolvedGrant());
    const onCreated = jest.fn();

    renderModal({ onCreated });

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.click(getGrantButton());

    await waitFor(() => expect(onCreated).toHaveBeenCalledTimes(1));
  });

  it('fires onClose after a successful submission', async () => {
    mockCreateAccessGrant.mockReturnValue(resolvedGrant());
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.click(getGrantButton());

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
  });

  it('shows a success notification after a successful submission', async () => {
    mockCreateAccessGrant.mockReturnValue(resolvedGrant());

    renderModal();

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.click(getGrantButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Access grant created',
      }),
    );
  });

  it('resets User ID and Tags fields after a successful submission', async () => {
    mockCreateAccessGrant.mockReturnValue(resolvedGrant());
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.change(getTagsInput(), {
      target: { value: 'vpn-pilot' },
    });

    fireEvent.click(getGrantButton());

    await waitFor(() => expect(onClose).toHaveBeenCalled());

    // After reset, the inputs are cleared (component re-renders with fresh state).
    expect(getUserIdInput()).toHaveValue('');
    expect(getTagsInput()).toHaveValue('');
  });

  // ---------------------------------------------------------------------------
  // Submission — in-flight state
  // ---------------------------------------------------------------------------

  it('shows "Granting…" on the submit button while the request is in-flight', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateAccessGrant.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    renderModal();

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.click(getGrantButton());

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /granting/i })).toBeInTheDocument(),
    );

    // Resolve to avoid act() warning
    resolveFn(GRANT);
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /granting/i })).not.toBeInTheDocument(),
    );
  });

  it('disables the Cancel button while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateAccessGrant.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    renderModal();

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.click(getGrantButton());

    await waitFor(() => expect(getCancelButton()).toBeDisabled());

    resolveFn(GRANT);
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /granting/i })).not.toBeInTheDocument(),
    );
  });

  it('disables the User ID and Tags inputs while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateAccessGrant.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    renderModal();

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.click(getGrantButton());

    await waitFor(() => expect(getUserIdInput()).toBeDisabled());
    expect(getTagsInput()).toBeDisabled();

    resolveFn(GRANT);
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /granting/i })).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Error path
  // ---------------------------------------------------------------------------

  it('shows an error notification with the Error message when creation fails', async () => {
    mockCreateAccessGrant.mockRejectedValue(new Error('Conflict: grant already exists'));

    renderModal();

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.click(getGrantButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Conflict: grant already exists',
      }),
    );
  });

  it('shows "Failed" when creation throws a non-Error value', async () => {
    mockCreateAccessGrant.mockRejectedValue('something went wrong');

    renderModal();

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.click(getGrantButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed',
      }),
    );
  });

  it('does not call onCreated or onClose when creation fails', async () => {
    mockCreateAccessGrant.mockRejectedValue(new Error('oops'));
    const onCreated = jest.fn();
    const onClose = jest.fn();

    renderModal({ onCreated, onClose });

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.click(getGrantButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onCreated).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('re-enables the submit button after a failed submission', async () => {
    mockCreateAccessGrant.mockRejectedValue(new Error('server error'));

    renderModal();

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });
    fireEvent.click(getGrantButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    // After failure, submitting should be false again, so the button is
    // enabled (userId is still populated so disabled={false}).
    expect(getGrantButton()).not.toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel is clicked and not submitting', () => {
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.click(getCancelButton());

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(mockCreateAccessGrant).not.toHaveBeenCalled();
  });

  it('resets the form fields when Cancel is clicked', () => {
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getUserIdInput(), {
      target: { value: 'some-uuid' },
    });
    fireEvent.change(getTagsInput(), {
      target: { value: 'tag-a' },
    });

    fireEvent.click(getCancelButton());

    // After reset + close, state is cleared.
    expect(getUserIdInput()).toHaveValue('');
    expect(getTagsInput()).toHaveValue('');
  });

  // ---------------------------------------------------------------------------
  // Form submit via native onSubmit
  // ---------------------------------------------------------------------------

  it('submitting the form element directly triggers the same flow as the button', async () => {
    mockCreateAccessGrant.mockReturnValue(resolvedGrant());
    const onClose = jest.fn();

    renderModal({ onClose });

    fireEvent.change(getUserIdInput(), {
      target: { value: '019d1111-2222-7000-a000-000000000001' },
    });

    const form = screen.getByTestId('modal').querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(mockCreateAccessGrant).toHaveBeenCalledTimes(1);
  });
});
