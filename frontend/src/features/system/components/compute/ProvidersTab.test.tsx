import React, { act } from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ProvidersTab } from './ProvidersTab';
import type { SystemProvider } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
//
// ProvidersTab orchestrates three heavy child components (ProviderList,
// ProviderDetailModal, ProviderFormModal) and calls systemApi.deleteProvider
// directly. We mock the child components as lightweight stubs that expose
// their props as data-testids / test-friendly handles so we can simulate
// user events without running those components' full logic.
// =============================================================================

// --- systemApi (delete is the only direct call in ProvidersTab) ---

const mockDeleteProvider = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    deleteProvider: (...args: unknown[]) => mockDeleteProvider(...args),
  },
}));

// --- Child components (providers barrel) ---
//
// Each stub captures the subset of props that ProvidersTab logic depends on
// and exposes them via data-testid buttons so tests can drive the parent.

let capturedOnView: ((p: SystemProvider) => void) | undefined;
let capturedOnEdit: ((p: SystemProvider) => void) | undefined;
let capturedOnDelete: ((id: string) => void) | undefined;
let capturedOnCreate: (() => void) | undefined;

let capturedDetailOnClose: (() => void) | undefined;
let capturedDetailOnEdit: ((p: SystemProvider) => void) | undefined;

let capturedFormOnClose: (() => void) | undefined;
let capturedFormOnProviderSaved: (() => void) | undefined;
let capturedFormOnCredentialSaved: (() => void) | undefined;

jest.mock('@system/features/system/components/providers', () => ({
  ProviderList: ({
    onView,
    onEdit,
    onDelete,
    onCreate,
  }: {
    onView?: (p: SystemProvider) => void;
    onEdit?: (p: SystemProvider) => void;
    onDelete?: (id: string) => void;
    onCreate?: () => void;
  }) => {
    capturedOnView = onView;
    capturedOnEdit = onEdit;
    capturedOnDelete = onDelete;
    capturedOnCreate = onCreate;
    return (
      <div data-testid="provider-list">
        <button
          data-testid="trigger-view"
          onClick={() => onView?.({ id: 'p-1', name: 'AWS Prod', provider_type: 'aws', enabled: true, public: false, config: {}, capabilities: {}, created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z' })}
        >
          View
        </button>
        <button
          data-testid="trigger-edit"
          onClick={() => onEdit?.({ id: 'p-1', name: 'AWS Prod', provider_type: 'aws', enabled: true, public: false, config: {}, capabilities: {}, created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z' })}
        >
          Edit
        </button>
        {onDelete && (
          <button
            data-testid="trigger-delete"
            onClick={() => onDelete('p-1')}
          >
            Delete
          </button>
        )}
        {onCreate && (
          <button
            data-testid="trigger-create"
            onClick={() => onCreate()}
          >
            Create
          </button>
        )}
      </div>
    );
  },

  ProviderDetailModal: ({
    providerId,
    isOpen,
    onClose,
    onEdit,
  }: {
    providerId: string | null;
    isOpen: boolean;
    onClose: () => void;
    onEdit?: (p: SystemProvider) => void;
  }) => {
    capturedDetailOnClose = onClose;
    capturedDetailOnEdit = onEdit;
    if (!isOpen) return null;
    return (
      <div data-testid="provider-detail-modal">
        <span data-testid="detail-provider-id">{providerId}</span>
        <button data-testid="detail-close" onClick={onClose}>Close</button>
        <button
          data-testid="detail-edit"
          onClick={() => onEdit?.({ id: providerId ?? 'p-1', name: 'AWS Prod', provider_type: 'aws', enabled: true, public: false, config: {}, capabilities: {}, created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z' })}
        >
          Edit from detail
        </button>
      </div>
    );
  },

  ProviderFormModal: ({
    isOpen,
    onClose,
    onProviderSaved,
    onCredentialSaved,
    editProvider,
  }: {
    isOpen: boolean;
    onClose: () => void;
    onProviderSaved?: () => void;
    onCredentialSaved?: () => void;
    editProvider?: SystemProvider | null;
  }) => {
    capturedFormOnClose = onClose;
    capturedFormOnProviderSaved = onProviderSaved;
    capturedFormOnCredentialSaved = onCredentialSaved;
    if (!isOpen) return null;
    return (
      <div data-testid="provider-form-modal">
        <span data-testid="form-edit-provider-id">{editProvider?.id ?? 'null'}</span>
        <button data-testid="form-close" onClick={onClose}>Close</button>
        <button data-testid="form-saved" onClick={() => onProviderSaved?.()}>Saved</button>
        <button
          data-testid="form-credential-saved"
          onClick={() => onCredentialSaved?.()}
        >
          Credential saved
        </button>
      </div>
    );
  },

  ProviderCredentialsPanel: ({ refreshKey }: { refreshKey?: number }) => (
    <div data-testid="provider-credentials-panel">
      <span data-testid="credentials-refresh-key">{String(refreshKey ?? 0)}</span>
    </div>
  ),
}));

// --- Permissions ---

let mockHasPermission = jest.fn(() => true);

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (...args: unknown[]) => mockHasPermission(...args),
  }),
}));

// --- Notifications ---

const mockAddNotification = jest.fn();

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// =============================================================================
// Fixtures
// =============================================================================

const PROVIDER_A: SystemProvider = {
  id: 'p-1',
  name: 'AWS Prod',
  provider_type: 'aws',
  enabled: true,
  public: false,
  config: {},
  capabilities: {},
  region_count: 3,
  connection_count: 1,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-15T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

const renderTab = (props: { onActionsReady?: (handle: { openCreate: () => void } | null) => void } = {}) =>
  render(
    <BrowserRouter>
      <ProvidersTab {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('ProvidersTab', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    capturedOnView = undefined;
    capturedOnEdit = undefined;
    capturedOnDelete = undefined;
    capturedOnCreate = undefined;
    capturedDetailOnClose = undefined;
    capturedDetailOnEdit = undefined;
    capturedFormOnClose = undefined;
    capturedFormOnProviderSaved = undefined;
    mockHasPermission = jest.fn(() => true);
    mockDeleteProvider.mockReset();
  });

  // ===== Render =====

  it('renders the ProviderList', () => {
    renderTab();
    expect(screen.getByTestId('provider-list')).toBeInTheDocument();
  });

  it('does not show ProviderDetailModal when nothing is selected', () => {
    renderTab();
    expect(screen.queryByTestId('provider-detail-modal')).not.toBeInTheDocument();
  });

  it('does not show ProviderFormModal initially', () => {
    renderTab();
    expect(screen.queryByTestId('provider-form-modal')).not.toBeInTheDocument();
  });

  it('does not show the delete confirmation initially', () => {
    renderTab();
    expect(screen.queryByText('Delete Provider')).not.toBeInTheDocument();
  });

  // ===== Permission gating =====

  it('passes onDelete to ProviderList when user has system.providers.delete', () => {
    mockHasPermission = jest.fn(() => true);
    renderTab();
    expect(screen.getByTestId('trigger-delete')).toBeInTheDocument();
  });

  it('does NOT pass onDelete to ProviderList when user lacks system.providers.delete', () => {
    mockHasPermission = jest.fn((perm: string) => perm !== 'system.providers.delete');
    renderTab();
    expect(screen.queryByTestId('trigger-delete')).not.toBeInTheDocument();
  });

  it('passes onCreate to ProviderList when user has system.providers.create', () => {
    mockHasPermission = jest.fn(() => true);
    renderTab();
    expect(screen.getByTestId('trigger-create')).toBeInTheDocument();
  });

  it('does NOT pass onCreate to ProviderList when user lacks system.providers.create', () => {
    mockHasPermission = jest.fn((perm: string) => perm !== 'system.providers.create');
    renderTab();
    expect(screen.queryByTestId('trigger-create')).not.toBeInTheDocument();
  });

  // ===== onActionsReady callback =====

  it('calls onActionsReady with openCreate handle on mount', () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    expect(onActionsReady).toHaveBeenCalledWith(
      expect.objectContaining({ openCreate: expect.any(Function) }),
    );
  });

  it('calls onActionsReady(null) on unmount', () => {
    const onActionsReady = jest.fn();
    const { unmount } = renderTab({ onActionsReady });
    unmount();
    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  it('opening via onActionsReady.openCreate shows ProviderFormModal in create mode', () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    const handle = onActionsReady.mock.calls[0][0] as { openCreate: () => void };
    act(() => { handle.openCreate(); });

    expect(screen.getByTestId('provider-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-provider-id').textContent).toBe('null');
  });

  // ===== View interaction =====

  it('shows ProviderDetailModal with correct providerId when onView fires', () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-view'));

    expect(screen.getByTestId('provider-detail-modal')).toBeInTheDocument();
    expect(screen.getByTestId('detail-provider-id').textContent).toBe('p-1');
  });

  it('closes ProviderDetailModal when its onClose fires', () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-view'));
    expect(screen.getByTestId('provider-detail-modal')).toBeInTheDocument();

    fireEvent.click(screen.getByTestId('detail-close'));
    expect(screen.queryByTestId('provider-detail-modal')).not.toBeInTheDocument();
  });

  // ===== Edit interaction =====

  it('shows ProviderFormModal with the provider when onEdit fires', () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-edit'));

    expect(screen.getByTestId('provider-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-provider-id').textContent).toBe('p-1');
  });

  it('closes ProviderFormModal when its onClose fires', () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-edit'));
    fireEvent.click(screen.getByTestId('form-close'));

    expect(screen.queryByTestId('provider-form-modal')).not.toBeInTheDocument();
  });

  // ===== Edit from detail modal =====

  it('closes detail modal and opens form modal in edit mode when onEdit fires from detail', () => {
    renderTab();

    // Open detail modal
    fireEvent.click(screen.getByTestId('trigger-view'));
    expect(screen.getByTestId('provider-detail-modal')).toBeInTheDocument();

    // Trigger edit from inside detail
    fireEvent.click(screen.getByTestId('detail-edit'));

    // Detail modal closed, form modal open with the provider
    expect(screen.queryByTestId('provider-detail-modal')).not.toBeInTheDocument();
    expect(screen.getByTestId('provider-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-provider-id').textContent).toBe('p-1');
  });

  // ===== Create interaction =====

  it('shows ProviderFormModal in create mode when onCreate fires from ProviderList', () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-create'));

    expect(screen.getByTestId('provider-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-provider-id').textContent).toBe('null');
  });

  // ===== onProviderSaved (refresh) =====

  it('increments refreshKey (remounts ProviderList) when onProviderSaved fires', () => {
    renderTab();

    // Open the form and fire saved
    fireEvent.click(screen.getByTestId('trigger-create'));
    expect(screen.getByTestId('provider-form-modal')).toBeInTheDocument();

    fireEvent.click(screen.getByTestId('form-saved'));

    // Modal stays open (create flow keeps it open) but ProviderList is still present
    expect(screen.getByTestId('provider-list')).toBeInTheDocument();
  });

  // ===== Delete flow =====

  it('shows the delete confirmation dialog when onDelete fires', () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));

    expect(screen.getByRole('heading', { name: 'Delete Provider' })).toBeInTheDocument();
    expect(screen.getByText(/Are you sure you want to delete this provider/)).toBeInTheDocument();
  });

  it('dismisses the delete confirmation when Cancel is clicked', () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    expect(screen.getByRole('heading', { name: 'Delete Provider' })).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(screen.queryByRole('heading', { name: 'Delete Provider' })).not.toBeInTheDocument();
  });

  it('calls systemApi.deleteProvider with the correct id on confirm', async () => {
    mockDeleteProvider.mockResolvedValueOnce(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));

    // The "Delete Provider" button is the danger button in the confirm dialog
    const deleteBtn = screen.getByRole('button', { name: 'Delete Provider' });
    fireEvent.click(deleteBtn);

    await waitFor(() => expect(mockDeleteProvider).toHaveBeenCalledWith('p-1'));
  });

  it('shows success notification after a successful delete', async () => {
    mockDeleteProvider.mockResolvedValueOnce(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    fireEvent.click(screen.getByRole('button', { name: 'Delete Provider' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: 'Provider deleted successfully' }),
      ),
    );
  });

  it('closes the confirmation dialog after a successful delete', async () => {
    mockDeleteProvider.mockResolvedValueOnce(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    fireEvent.click(screen.getByRole('button', { name: 'Delete Provider' }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Provider' })).not.toBeInTheDocument(),
    );
  });

  it('shows error notification when delete API call fails', async () => {
    mockDeleteProvider.mockRejectedValueOnce(new Error('Network error'));
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    fireEvent.click(screen.getByRole('button', { name: 'Delete Provider' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Failed to delete provider: Network error',
        }),
      ),
    );
  });

  it('closes the confirmation dialog even after a failed delete', async () => {
    mockDeleteProvider.mockRejectedValueOnce(new Error('Server error'));
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    fireEvent.click(screen.getByRole('button', { name: 'Delete Provider' }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Provider' })).not.toBeInTheDocument(),
    );
  });

  it('shows "Deleting..." on the confirm button while the delete is in flight', async () => {
    let resolveDelete!: () => void;
    mockDeleteProvider.mockReturnValueOnce(
      new Promise<void>((res) => { resolveDelete = res; }),
    );

    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    fireEvent.click(screen.getByRole('button', { name: 'Delete Provider' }));

    await waitFor(() => expect(screen.getByRole('button', { name: 'Processing...' })).toBeDisabled());

    resolveDelete();
    await waitFor(() => expect(screen.queryByText('Processing...')).not.toBeInTheDocument());
  });

  it('dismisses the delete confirmation when the backdrop is clicked', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    expect(screen.getByRole('heading', { name: 'Delete Provider' })).toBeInTheDocument();

    // The shared Modal's outer positioning div closes on a direct click
    // (event.target === event.currentTarget), same as clicking the backdrop.
    const backdrop = screen.getByRole('dialog').firstElementChild as HTMLElement;
    fireEvent.click(backdrop);

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Provider' })).not.toBeInTheDocument(),
    );
  });

  // ===== Warning text =====

  it('renders the correct warning text in the delete dialog', () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));

    expect(screen.getByRole('heading', { name: 'Delete Provider' })).toBeInTheDocument();
    expect(
      screen.getByText(/All regions and connections associated with this provider will also be removed/),
    ).toBeInTheDocument();
  });
});

// =============================================================================
// Configured credentials (IMP-18832c3c6128)
//
// The screen that CREATES a cloud credential had no surface that lists or
// removes one: provider_credentials #index and #destroy had no caller in
// either frontend tree, so a credential typed wrong could only be corrected
// with database access. These pin the surface onto this screen, where
// creation already lives.
// =============================================================================

describe('ProvidersTab configured credentials', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockHasPermission = jest.fn(() => true);
    capturedFormOnProviderSaved = undefined;
    capturedFormOnCredentialSaved = undefined;
  });

  it('renders the configured-credentials panel', () => {
    renderTab();

    expect(screen.getByTestId('provider-credentials-panel')).toBeInTheDocument();
  });

  it('re-reads the credential list when a credential is stored', async () => {
    renderTab();

    const before = screen.getByTestId('credentials-refresh-key').textContent;

    // The write this panel exists to show is its OWN button on its own tab of
    // the provider form. Leaning on the provider-saved signal would leave the
    // list stale after exactly that action — and an operator storing their
    // first credential would be looking at an empty state, which renders no
    // refresh button to recover with.
    await act(async () => {
      capturedFormOnCredentialSaved?.();
    });

    expect(screen.getByTestId('credentials-refresh-key').textContent).not.toBe(before);
  });

  it('re-reads the credential list when the provider itself is saved', async () => {
    renderTab();

    const before = screen.getByTestId('credentials-refresh-key').textContent;

    await act(async () => {
      capturedFormOnProviderSaved?.();
    });

    expect(screen.getByTestId('credentials-refresh-key').textContent).not.toBe(before);
  });
});
