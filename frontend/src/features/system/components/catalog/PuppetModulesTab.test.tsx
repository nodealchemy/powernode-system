import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PuppetModulesTab } from './PuppetModulesTab';

// =============================================================================
// Mocks
//
// PuppetModulesTab delegates list-rendering to PuppetModuleList (which calls
// systemApi.getPuppetModules), detail display to PuppetModuleDetailModal
// (which calls systemApi.getPuppetModule), and create/edit to
// PuppetModuleFormModal. Delete is handled directly by PuppetModulesTab itself
// via systemApi.deletePuppetModule. We stub the entire systemApi facade and all
// three child components so the tab itself can be exercised in isolation.
// =============================================================================

const mockDeletePuppetModule = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    deletePuppetModule: (...args: unknown[]) => mockDeletePuppetModule(...args),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => true }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

jest.mock('@/shared/hooks/BreadcrumbContext', () => ({
  __esModule: true,
  BreadcrumbProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
  useBreadcrumb: () => ({
    breadcrumbs: [],
    setBreadcrumbs: jest.fn(),
    getCurrentBreadcrumbs: () => [],
    setCurrentPage: jest.fn(),
  }),
}));

// --------------------------------------------------------------------------
// Stub child components so the tab can be tested without their internals.
// Each stub exposes trigger buttons for all callbacks the tab passes in.
// --------------------------------------------------------------------------

// Callbacks captured from the most-recent PuppetModuleList render.
let capturedOnView: ((m: unknown) => void) | undefined;
let capturedOnEdit: ((m: unknown) => void) | undefined;
let capturedOnDelete: ((id: string) => void) | undefined;
let capturedOnCreate: (() => void) | undefined;

// Callbacks captured from the most-recent PuppetModuleDetailModal render.
let capturedDetailOnClose: (() => void) | undefined;
let capturedDetailOnEdit: ((m: unknown) => void) | undefined;

// Callbacks captured from the most-recent PuppetModuleFormModal render.
let capturedFormOnClose: (() => void) | undefined;
let capturedFormOnSaved: ((m: unknown) => void) | undefined;
let capturedFormEditModule: unknown;

jest.mock('@system/features/system/components/puppet', () => ({
  PuppetModuleList: ({
    onView,
    onEdit,
    onDelete,
    onCreate,
  }: {
    onView?: (m: unknown) => void;
    onEdit?: (m: unknown) => void;
    onDelete?: (id: string) => void;
    onCreate?: () => void;
  }) => {
    capturedOnView = onView;
    capturedOnEdit = onEdit;
    capturedOnDelete = onDelete;
    capturedOnCreate = onCreate;
    return (
      <div data-testid="puppet-module-list">
        <button data-testid="trigger-view" onClick={() => onView?.(MODULE_A)}>View</button>
        <button data-testid="trigger-edit" onClick={() => onEdit?.(MODULE_A)}>Edit</button>
        <button data-testid="trigger-delete" onClick={() => onDelete?.(MODULE_A.id)}>Delete</button>
        <button data-testid="trigger-create" onClick={() => onCreate?.()}>Create</button>
      </div>
    );
  },

  PuppetModuleDetailModal: ({
    moduleId,
    isOpen,
    onClose,
    onEdit,
  }: {
    moduleId: string | null;
    isOpen: boolean;
    onClose: () => void;
    onEdit?: (m: unknown) => void;
  }) => {
    capturedDetailOnClose = onClose;
    capturedDetailOnEdit = onEdit;
    if (!isOpen) return null;
    return (
      <div data-testid="puppet-detail-modal">
        <span data-testid="detail-module-id">{moduleId}</span>
        <button data-testid="detail-edit" onClick={() => onEdit?.(MODULE_A)}>Edit from detail</button>
        <button data-testid="detail-close" onClick={onClose}>Close</button>
      </div>
    );
  },

  PuppetModuleFormModal: ({
    isOpen,
    onClose,
    onModuleSaved,
    editModule,
  }: {
    isOpen: boolean;
    onClose: () => void;
    onModuleSaved?: (m: unknown) => void;
    editModule?: unknown;
  }) => {
    capturedFormOnClose = onClose;
    capturedFormOnSaved = onModuleSaved;
    capturedFormEditModule = editModule;
    if (!isOpen) return null;
    return (
      <div data-testid="puppet-form-modal">
        <span data-testid="modal-mode">{editModule ? 'edit' : 'create'}</span>
        <button
          data-testid="modal-save"
          onClick={() => { onModuleSaved?.(MODULE_A); onClose(); }}
        >
          Save
        </button>
        <button data-testid="modal-close" onClick={onClose}>Close</button>
      </div>
    );
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const MODULE_A = {
  id: 'mod-a',
  name: 'apache',
  description: 'Apache Puppet module',
  enabled: true,
  public: false,
  version: '1.0.0',
  author: 'puppetlabs',
  license: 'Apache-2.0',
  source_url: '',
  project_url: '',
  forge_name: 'puppetlabs-apache',
  dependencies: [],
  config: {},
  metadata: {},
  resource_count: 5,
  resource_types: ['file', 'package'],
  assigned_modules_count: 2,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

function renderTab(props: React.ComponentProps<typeof PuppetModulesTab> = {}) {
  return render(
    <BrowserRouter>
      <PuppetModulesTab {...props} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PuppetModulesTab', () => {
  beforeEach(() => {
    mockDeletePuppetModule.mockReset();
    mockAddNotification.mockReset();
    capturedOnView = undefined;
    capturedOnEdit = undefined;
    capturedOnDelete = undefined;
    capturedOnCreate = undefined;
    capturedDetailOnClose = undefined;
    capturedDetailOnEdit = undefined;
    capturedFormOnClose = undefined;
    capturedFormOnSaved = undefined;
    capturedFormEditModule = undefined;
  });

  // -------------------------------------------------------------------------
  // Render
  // -------------------------------------------------------------------------

  it('renders the PuppetModuleList child', () => {
    renderTab();
    expect(screen.getByTestId('puppet-module-list')).toBeInTheDocument();
  });

  it('does not render the form modal by default', () => {
    renderTab();
    expect(screen.queryByTestId('puppet-form-modal')).not.toBeInTheDocument();
  });

  it('does not render the detail modal by default', () => {
    renderTab();
    expect(screen.queryByTestId('puppet-detail-modal')).not.toBeInTheDocument();
  });

  it('does not render the delete-confirm dialog by default', () => {
    renderTab();
    expect(screen.queryByText('Delete Puppet Module')).not.toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // onActionsReady — external action-handle callback
  // -------------------------------------------------------------------------

  it('calls onActionsReady with an openCreate handle on mount', () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    expect(onActionsReady).toHaveBeenCalledWith(
      expect.objectContaining({ openCreate: expect.any(Function) }),
    );
  });

  it('opens the create form modal when openCreate is invoked externally', async () => {
    let handle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => { handle = h; });
    renderTab({ onActionsReady });
    act(() => { handle!.openCreate(); });
    await waitFor(() =>
      expect(screen.getByTestId('puppet-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('modal-mode').textContent).toBe('create');
  });

  it('calls onActionsReady(null) on unmount', () => {
    const onActionsReady = jest.fn();
    const { unmount } = renderTab({ onActionsReady });
    unmount();
    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  // -------------------------------------------------------------------------
  // Create flow
  // -------------------------------------------------------------------------

  it('opens the form modal in create mode when onCreate is triggered', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-create'));
    await waitFor(() =>
      expect(screen.getByTestId('puppet-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('modal-mode').textContent).toBe('create');
  });

  it('closes the form modal when onClose is called from within modal', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-create'));
    await waitFor(() => expect(screen.getByTestId('puppet-form-modal')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('modal-close'));
    await waitFor(() =>
      expect(screen.queryByTestId('puppet-form-modal')).not.toBeInTheDocument(),
    );
  });

  it('clears editModule state when form modal is closed after edit', async () => {
    renderTab();
    // Open in edit mode
    fireEvent.click(screen.getByTestId('trigger-edit'));
    await waitFor(() => expect(screen.getByTestId('puppet-form-modal')).toBeInTheDocument());
    expect(screen.getByTestId('modal-mode').textContent).toBe('edit');

    // Close
    fireEvent.click(screen.getByTestId('modal-close'));
    await waitFor(() => expect(screen.queryByTestId('puppet-form-modal')).not.toBeInTheDocument());

    // Re-open via create trigger — should be create mode
    fireEvent.click(screen.getByTestId('trigger-create'));
    await waitFor(() => expect(screen.getByTestId('puppet-form-modal')).toBeInTheDocument());
    expect(screen.getByTestId('modal-mode').textContent).toBe('create');
  });

  // -------------------------------------------------------------------------
  // Edit flow (from list)
  // -------------------------------------------------------------------------

  it('opens the form modal in edit mode when onEdit is triggered from list', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-edit'));
    await waitFor(() =>
      expect(screen.getByTestId('puppet-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('modal-mode').textContent).toBe('edit');
  });

  // -------------------------------------------------------------------------
  // View / Detail modal flow
  // -------------------------------------------------------------------------

  it('opens the detail modal when onView is triggered from list', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-view'));
    await waitFor(() =>
      expect(screen.getByTestId('puppet-detail-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('detail-module-id').textContent).toBe(MODULE_A.id);
  });

  it('closes the detail modal when its onClose is called', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-view'));
    await waitFor(() => expect(screen.getByTestId('puppet-detail-modal')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('detail-close'));
    await waitFor(() =>
      expect(screen.queryByTestId('puppet-detail-modal')).not.toBeInTheDocument(),
    );
  });

  it('transitions from detail modal to edit form when onEdit fires from detail', async () => {
    renderTab();
    // Open detail
    fireEvent.click(screen.getByTestId('trigger-view'));
    await waitFor(() => expect(screen.getByTestId('puppet-detail-modal')).toBeInTheDocument());

    // Fire edit from within the detail modal
    fireEvent.click(screen.getByTestId('detail-edit'));

    await waitFor(() =>
      expect(screen.queryByTestId('puppet-detail-modal')).not.toBeInTheDocument(),
    );
    await waitFor(() =>
      expect(screen.getByTestId('puppet-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('modal-mode').textContent).toBe('edit');
  });

  // -------------------------------------------------------------------------
  // Save (onModuleSaved) — closes modal, triggers list refresh
  // -------------------------------------------------------------------------

  it('closes the form modal after onModuleSaved fires', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-create'));
    await waitFor(() => expect(screen.getByTestId('puppet-form-modal')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('modal-save'));
    await waitFor(() =>
      expect(screen.queryByTestId('puppet-form-modal')).not.toBeInTheDocument(),
    );
  });

  it('clears editModule after onModuleSaved fires (next open is create mode)', async () => {
    let handle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => { handle = h; });
    renderTab({ onActionsReady });

    // Open in edit mode and save
    fireEvent.click(screen.getByTestId('trigger-edit'));
    await waitFor(() => expect(screen.getByTestId('puppet-form-modal')).toBeInTheDocument());
    expect(screen.getByTestId('modal-mode').textContent).toBe('edit');
    fireEvent.click(screen.getByTestId('modal-save'));
    await waitFor(() => expect(screen.queryByTestId('puppet-form-modal')).not.toBeInTheDocument());

    // Re-open via external handle on the SAME component — should be create mode
    act(() => { handle!.openCreate(); });
    await waitFor(() => expect(screen.getByTestId('puppet-form-modal')).toBeInTheDocument());
    expect(screen.getByTestId('modal-mode').textContent).toBe('create');
  });

  // -------------------------------------------------------------------------
  // Permission gating — onDelete and onCreate conditionality
  // -------------------------------------------------------------------------

  it('passes onDelete to PuppetModuleList when user has system.puppet.delete', () => {
    renderTab();
    expect(capturedOnDelete).toBeInstanceOf(Function);
  });

  it('passes onCreate to PuppetModuleList when user has system.puppet.create', () => {
    renderTab();
    expect(capturedOnCreate).toBeInstanceOf(Function);
  });

  // -------------------------------------------------------------------------
  // Delete flow — confirm dialog
  // -------------------------------------------------------------------------

  it('opens delete-confirm dialog when onDelete is triggered from list', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/are you sure you want to delete this puppet module/i),
    ).toBeInTheDocument();
  });

  it('shows the full warning message in the confirm dialog', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument());
    expect(
      screen.getByText(/all resources and node module assignments will also be removed/i),
    ).toBeInTheDocument();
  });

  it('closes delete-confirm dialog when Cancel is clicked', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    await waitFor(() =>
      expect(screen.queryByText('Delete Puppet Module')).not.toBeInTheDocument(),
    );
  });

  it('closes delete-confirm when backdrop is clicked', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument());

    // The shared Modal's outer positioning div closes on a direct click
    // (event.target === event.currentTarget), same as clicking the backdrop.
    const backdrop = screen.getByRole('dialog').firstElementChild as HTMLElement;
    fireEvent.click(backdrop);
    await waitFor(() =>
      expect(screen.queryByText('Delete Puppet Module')).not.toBeInTheDocument(),
    );
  });

  it('calls systemApi.deletePuppetModule with the correct id on confirm', async () => {
    mockDeletePuppetModule.mockResolvedValue(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() =>
      expect(mockDeletePuppetModule).toHaveBeenCalledWith(MODULE_A.id),
    );
  });

  it('shows success notification after successful delete', async () => {
    mockDeletePuppetModule.mockResolvedValue(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'success',
          message: 'Puppet module deleted successfully',
        }),
      ),
    );
  });

  it('closes delete-confirm dialog after successful delete', async () => {
    mockDeletePuppetModule.mockResolvedValue(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() =>
      expect(screen.queryByText('Delete Puppet Module')).not.toBeInTheDocument(),
    );
  });

  it('disables the confirm button while deletion is in progress', async () => {
    let resolveDelete!: () => void;
    mockDeletePuppetModule.mockReturnValue(
      new Promise<void>((res) => { resolveDelete = res; }),
    );

    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    // Button text changes to "Processing..." while in-flight
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /processing\.\.\./i })).toBeDisabled(),
    );

    resolveDelete();
  });

  it('shows error notification when delete fails', async () => {
    mockDeletePuppetModule.mockRejectedValue(new Error('Server error'));
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Failed to delete Puppet module: Server error',
        }),
      ),
    );
  });

  it('closes the delete dialog even when deletion fails', async () => {
    mockDeletePuppetModule.mockRejectedValue(new Error('Oops'));
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() =>
      expect(screen.queryByText('Delete Puppet Module')).not.toBeInTheDocument(),
    );
  });

  it('falls back to generic error message when delete throws a non-Error', async () => {
    mockDeletePuppetModule.mockRejectedValue('string-error');
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete Puppet Module')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Failed to delete Puppet module: An error occurred',
        }),
      ),
    );
  });
});
