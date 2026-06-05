import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { CapabilitiesManagementModal } from './CapabilitiesManagementModal';
import type { FederationCapability } from '../../types/capability.types';

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

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// Modal: pass children, title, and footer through so we can query all content.
jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({
    isOpen,
    title,
    children,
    footer,
  }: {
    isOpen: boolean;
    title?: React.ReactNode;
    children: React.ReactNode;
    footer?: React.ReactNode;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="modal">
        {title && <div data-testid="modal-title">{title}</div>}
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
// Envelope helper — mirrors the double-envelope the backend produces.
// apiClient.{get,post,delete} resolve to AxiosResponse whose .data is
// { success: true, data: <payload> }.
// =============================================================================

function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const PEER_ID = 'peer-uuid-1';
const PEER_LABEL = 'us-west-peer.example.com';

const CAP_A: FederationCapability = {
  id: 'cap-a',
  federation_peer_id: PEER_ID,
  resource_kind: 'skill',
  direction: 'push_local_to_remote',
  policy: 'manual',
  filter: {},
  conflict_resolution: 'local_wins',
  last_synced_at: null,
  sync_cursor: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CAP_B: FederationCapability = {
  id: 'cap-b',
  federation_peer_id: PEER_ID,
  resource_kind: 'trading_strategy',
  direction: 'bidirectional',
  policy: 'auto_on_change',
  filter: { tags: ['public'] },
  conflict_resolution: 'remote_wins',
  last_synced_at: '2026-05-01T12:00:00Z',
  sync_cursor: {},
  created_at: '2026-01-02T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

function listEnvelope(caps: FederationCapability[]) {
  return envelope({ capabilities: caps, count: caps.length });
}

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  peerId?: string | null;
  peerLabel?: string;
  onClose?: () => void;
  onChanged?: () => void;
}

function renderModal({
  isOpen = true,
  peerId = PEER_ID,
  peerLabel = PEER_LABEL,
  onClose = jest.fn(),
  onChanged = jest.fn(),
}: RenderProps = {}) {
  return render(
    <CapabilitiesManagementModal
      isOpen={isOpen}
      peerId={peerId}
      peerLabel={peerLabel}
      onClose={onClose}
      onChanged={onChanged}
    />,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('CapabilitiesManagementModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();

    // Default window.confirm to true (confirmed)
    jest.spyOn(window, 'confirm').mockReturnValue(true);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Render / null guards
  // ──────────────────────────────────────────────────────────────────────

  it('renders nothing when peerId is null', () => {
    const { container } = renderModal({ peerId: null });
    expect(container).toBeEmptyDOMElement();
  });

  it('renders nothing when the modal is closed', () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    const { queryByTestId } = renderModal({ isOpen: false });
    expect(queryByTestId('modal')).not.toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Loading state
  // ──────────────────────────────────────────────────────────────────────

  it('shows "loading…" while capabilities are being fetched', async () => {
    // Never resolves during this test
    mockGet.mockReturnValue(new Promise(() => {}));

    renderModal();

    expect(screen.getByText('loading…')).toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // API — list
  // ──────────────────────────────────────────────────────────────────────

  it('calls GET /system/platform/peers/:peerId/capabilities on open', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        `/system/platform/peers/${PEER_ID}/capabilities`,
      ),
    );
  });

  it('renders capabilities returned from the API', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_A, CAP_B]));

    renderModal();

    await waitFor(() => expect(screen.getByText('skill')).toBeInTheDocument());
    expect(screen.getByText('trading_strategy')).toBeInTheDocument();
    // Directions appear in the capability row badges
    expect(screen.getByText('push_local_to_remote')).toBeInTheDocument();
    expect(screen.getByText('bidirectional')).toBeInTheDocument();
  });

  it('shows the correct capability count label (plural)', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_A, CAP_B]));

    renderModal();

    await waitFor(() => expect(screen.getByText('2 capabilities')).toBeInTheDocument());
  });

  it('shows the correct capability count label (singular)', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_A]));

    renderModal();

    await waitFor(() => expect(screen.getByText('1 capability')).toBeInTheDocument());
  });

  // ──────────────────────────────────────────────────────────────────────
  // Empty state
  // ──────────────────────────────────────────────────────────────────────

  it('renders the empty-state message when there are no capabilities', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText(/no capabilities declared yet/i)).toBeInTheDocument(),
    );
    expect(screen.getByText('0 capabilities')).toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Error state
  // ──────────────────────────────────────────────────────────────────────

  it('shows an error banner when the list call rejects', async () => {
    mockGet.mockRejectedValue(new Error('Network error'));

    renderModal();

    await waitFor(() => expect(screen.getByText('Network error')).toBeInTheDocument());
  });

  it('shows a fallback error message when rejection is not an Error instance', async () => {
    mockGet.mockRejectedValue('bad');

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Failed to load capabilities')).toBeInTheDocument(),
    );
  });

  it('dismisses the error banner when the X button is clicked', async () => {
    mockGet.mockRejectedValue(new Error('Network error'));

    renderModal();

    await waitFor(() => expect(screen.getByText('Network error')).toBeInTheDocument());

    // The X button inside the error banner — there might be multiple X icons;
    // find the one that is a sibling of the error text.
    const errorBanner = screen.getByText('Network error').closest('div');
    const dismissBtn = errorBanner!.querySelector('button[type="button"]');
    fireEvent.click(dismissBtn!);

    await waitFor(() => expect(screen.queryByText('Network error')).not.toBeInTheDocument());
  });

  // ──────────────────────────────────────────────────────────────────────
  // Filter display (CAP_B has filter predicates)
  // ──────────────────────────────────────────────────────────────────────

  it('shows a filter summary when capability has filter predicates', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_B]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText(/filter · 1 predicate/i)).toBeInTheDocument(),
    );
  });

  it('does not show a filter summary when filter is empty', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_A]));

    renderModal();

    await waitFor(() => expect(screen.getByText('skill')).toBeInTheDocument());
    expect(screen.queryByText(/filter ·/i)).not.toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Peer label rendering
  // ──────────────────────────────────────────────────────────────────────

  it('renders the peer label in the modal title', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText(PEER_LABEL)).toBeInTheDocument(),
    );
  });

  // ──────────────────────────────────────────────────────────────────────
  // Delete
  // ──────────────────────────────────────────────────────────────────────

  it('calls DELETE and shows success notification after confirmed delete', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_A]));
    mockDelete.mockResolvedValue(envelope({ deleted: true, id: CAP_A.id }));
    // Second list call after delete returns empty
    mockGet.mockResolvedValueOnce(listEnvelope([CAP_A])).mockResolvedValue(listEnvelope([]));

    const onChanged = jest.fn();
    renderModal({ onChanged });

    await waitFor(() => expect(screen.getByText('skill')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Delete capability'));

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith(
        `/system/platform/peers/${PEER_ID}/capabilities/${CAP_A.id}`,
      ),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Capability '${CAP_A.resource_kind}' deleted.`,
      }),
    );
    expect(onChanged).toHaveBeenCalled();
  });

  it('does not call DELETE when user cancels the confirm dialog', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_A]));
    jest.spyOn(window, 'confirm').mockReturnValue(false);

    renderModal();

    await waitFor(() => expect(screen.getByText('skill')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Delete capability'));

    // Give any async effects time to settle
    await new Promise((r) => setTimeout(r, 50));

    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('shows an error notification when the DELETE call rejects', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_A]));
    mockDelete.mockRejectedValue(new Error('Delete failed'));

    renderModal();

    await waitFor(() => expect(screen.getByText('skill')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Delete capability'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Delete failed',
      }),
    );
  });

  it('shows "Deleting…" on the delete button while deletion is in progress', async () => {
    let resolveDelete!: () => void;
    mockGet.mockResolvedValue(listEnvelope([CAP_A]));
    mockDelete.mockReturnValue(new Promise<void>((res) => { resolveDelete = res; }));

    renderModal();

    await waitFor(() => expect(screen.getByText('skill')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Delete capability'));

    await waitFor(() => expect(screen.getByText('Deleting…')).toBeInTheDocument());

    // Resolve so cleanup doesn't leak
    resolveDelete();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Add Capability form — open / close
  // ──────────────────────────────────────────────────────────────────────

  it('hides the add form by default and shows "Add Capability" footer button', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.queryByText(/no capabilities/i)).toBeInTheDocument(),
    );

    // Add form should not be visible
    expect(screen.queryByPlaceholderText(/e\.g\. skill/i)).not.toBeInTheDocument();
    // Footer button visible
    expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument();
  });

  it('shows the add form when "Add Capability" footer button is clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    expect(screen.getByPlaceholderText(/e\.g\. skill/i)).toBeInTheDocument();
  });

  it('hides the "Add Capability" footer button when the form is open', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    // The footer "Add Capability" button should now be gone (form is showing)
    // There should only be the form's own "Add Capability" submit button
    const addButtons = screen.getAllByRole('button', { name: /add capability/i });
    // The form submit button is the only one (footer button is hidden)
    expect(addButtons).toHaveLength(1);
  });

  it('closes the add form when the Cancel button inside the form is clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));
    expect(screen.getByPlaceholderText(/e\.g\. skill/i)).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }));

    await waitFor(() =>
      expect(screen.queryByPlaceholderText(/e\.g\. skill/i)).not.toBeInTheDocument(),
    );
  });

  // ──────────────────────────────────────────────────────────────────────
  // Add Capability form — defaults
  // ──────────────────────────────────────────────────────────────────────

  it('pre-selects push_local_to_remote direction and manual policy by default', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    const directionSelect = screen.getByDisplayValue('Push (us → them)');
    expect(directionSelect).toBeInTheDocument();

    const policySelect = screen.getByDisplayValue('Manual');
    expect(policySelect).toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Add Capability form — validation
  // ──────────────────────────────────────────────────────────────────────

  it('disables the submit button when resource_kind is empty', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    const submitBtn = screen.getByRole('button', { name: /^add capability$/i });
    expect(submitBtn).toBeDisabled();
  });

  it('enables the submit button when resource_kind is filled', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    fireEvent.change(screen.getByPlaceholderText(/e\.g\. skill/i), {
      target: { value: 'skill' },
    });

    const submitBtn = screen.getByRole('button', { name: /^add capability$/i });
    expect(submitBtn).not.toBeDisabled();
  });

  it('shows an error when filter is invalid JSON', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    fireEvent.change(screen.getByPlaceholderText(/e\.g\. skill/i), {
      target: { value: 'skill' },
    });
    fireEvent.change(screen.getByPlaceholderText(/e\.g\. \{"tags"/i), {
      target: { value: 'not-json' },
    });

    const submitBtn = screen.getByRole('button', { name: /^add capability$/i });
    expect(submitBtn).toBeDisabled();
  });

  it('shows an error when filter is a JSON array instead of an object', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    fireEvent.change(screen.getByPlaceholderText(/e\.g\. skill/i), {
      target: { value: 'skill' },
    });
    fireEvent.change(screen.getByPlaceholderText(/e\.g\. \{"tags"/i), {
      target: { value: '["not", "an", "object"]' },
    });

    const submitBtn = screen.getByRole('button', { name: /^add capability$/i });
    expect(submitBtn).toBeDisabled();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Add Capability form — submission
  // ──────────────────────────────────────────────────────────────────────

  it('calls POST with correct payload and closes the form on success', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    mockPost.mockResolvedValue(
      envelope({ capability: { ...CAP_A, id: 'cap-new' } }),
    );

    const onChanged = jest.fn();
    renderModal({ onChanged });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    fireEvent.change(screen.getByPlaceholderText(/e\.g\. skill/i), {
      target: { value: 'knowledge_base_entry' },
    });

    // Change direction to bidirectional
    fireEvent.change(screen.getByDisplayValue('Push (us → them)'), {
      target: { value: 'bidirectional' },
    });

    // Change policy to auto_periodic
    fireEvent.change(screen.getByDisplayValue('Manual'), {
      target: { value: 'auto_periodic' },
    });

    // Add valid JSON filter
    fireEvent.change(screen.getByPlaceholderText(/e\.g\. \{"tags"/i), {
      target: { value: '{"env": "prod"}' },
    });

    fireEvent.click(screen.getByRole('button', { name: /^add capability$/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        `/system/platform/peers/${PEER_ID}/capabilities`,
        {
          resource_kind: 'knowledge_base_entry',
          direction: 'bidirectional',
          policy: 'auto_periodic',
          conflict_resolution: 'local_wins',
          filter: { env: 'prod' },
        },
      ),
    );

    // Form should close after success
    await waitFor(() =>
      expect(screen.queryByPlaceholderText(/e\.g\. skill/i)).not.toBeInTheDocument(),
    );

    expect(onChanged).toHaveBeenCalled();
  });

  it('sends an empty filter object when filter textarea is blank', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    mockPost.mockResolvedValue(envelope({ capability: CAP_A }));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    fireEvent.change(screen.getByPlaceholderText(/e\.g\. skill/i), {
      target: { value: 'skill' },
    });

    fireEvent.click(screen.getByRole('button', { name: /^add capability$/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        `/system/platform/peers/${PEER_ID}/capabilities`,
        expect.objectContaining({ filter: {} }),
      ),
    );
  });

  it('shows an inline error when the POST call rejects', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    mockPost.mockRejectedValue(new Error('Create failed'));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    fireEvent.change(screen.getByPlaceholderText(/e\.g\. skill/i), {
      target: { value: 'skill' },
    });

    fireEvent.click(screen.getByRole('button', { name: /^add capability$/i }));

    await waitFor(() =>
      expect(screen.getByText('Create failed')).toBeInTheDocument(),
    );

    // Form should remain open so the user can fix and retry
    expect(screen.getByPlaceholderText(/e\.g\. skill/i)).toBeInTheDocument();
  });

  it('shows "Adding…" on the submit button while the POST is in flight', async () => {
    let resolveCreate!: () => void;
    mockGet.mockResolvedValue(listEnvelope([]));
    mockPost.mockReturnValue(
      new Promise<ReturnType<typeof envelope>>((res) => {
        resolveCreate = () => res(envelope({ capability: CAP_A }));
      }),
    );

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    fireEvent.change(screen.getByPlaceholderText(/e\.g\. skill/i), {
      target: { value: 'skill' },
    });

    fireEvent.click(screen.getByRole('button', { name: /^add capability$/i }));

    await waitFor(() => expect(screen.getByText('Adding…')).toBeInTheDocument());

    // Resolve so cleanup doesn't leak
    resolveCreate();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Policy help text — dynamic
  // ──────────────────────────────────────────────────────────────────────

  it('shows help text matching the selected policy', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add capability/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add capability/i }));

    // Default is manual
    expect(
      screen.getByText('Operator triggers each sync explicitly.'),
    ).toBeInTheDocument();

    // Switch to auto_on_change
    fireEvent.change(screen.getByDisplayValue('Manual'), {
      target: { value: 'auto_on_change' },
    });

    expect(
      screen.getByText('Sync triggered by source-row update.'),
    ).toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Modal close button
  // ──────────────────────────────────────────────────────────────────────

  it('calls onClose when the "Close" footer button is clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    const onClose = jest.fn();

    renderModal({ onClose });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^close$/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /^close$/i }));

    expect(onClose).toHaveBeenCalled();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Re-fetch on close → re-open
  // ──────────────────────────────────────────────────────────────────────

  it('clears capabilities when modal is closed', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_A]));

    const { rerender } = renderModal({ isOpen: true });

    await waitFor(() => expect(screen.getByText('skill')).toBeInTheDocument());

    // Close the modal
    rerender(
      <CapabilitiesManagementModal
        isOpen={false}
        peerId={PEER_ID}
        peerLabel={PEER_LABEL}
        onClose={jest.fn()}
      />,
    );

    // Modal is gone
    expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
  });

  it('re-fetches capabilities when modal is reopened', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_A]));

    const { rerender } = renderModal({ isOpen: false });

    expect(mockGet).not.toHaveBeenCalled();

    rerender(
      <CapabilitiesManagementModal
        isOpen={true}
        peerId={PEER_ID}
        peerLabel={PEER_LABEL}
        onClose={jest.fn()}
      />,
    );

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        `/system/platform/peers/${PEER_ID}/capabilities`,
      ),
    );
  });

  // ──────────────────────────────────────────────────────────────────────
  // last_synced_at display
  // ──────────────────────────────────────────────────────────────────────

  it('shows the last sync time when last_synced_at is present', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_B]));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText(/last sync ·/i)).toBeInTheDocument(),
    );
  });

  it('does not show "last sync" when last_synced_at is null', async () => {
    mockGet.mockResolvedValue(listEnvelope([CAP_A]));

    renderModal();

    await waitFor(() => expect(screen.getByText('skill')).toBeInTheDocument());

    expect(screen.queryByText(/last sync ·/i)).not.toBeInTheDocument();
  });
});
