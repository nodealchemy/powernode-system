import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PlatformsTab } from './PlatformsTab';

// =============================================================================
// Mocks
//
// PlatformsTab delegates list-rendering to PlatformList (which calls
// systemApi.getPlatforms) and form/edit to PlatformFormModal (which calls
// systemApi.createPlatform / updatePlatform). Delete is handled directly by
// PlatformsTab itself via systemApi.deletePlatform.
// We stub the entire systemApi facade and both child components so the tab
// itself can be exercised in isolation.
// =============================================================================

const mockGetPlatforms = jest.fn();
const mockCreatePlatform = jest.fn();
const mockUpdatePlatform = jest.fn();
const mockDeletePlatform = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getPlatforms: (...args: unknown[]) => mockGetPlatforms(...args),
    createPlatform: (...args: unknown[]) => mockCreatePlatform(...args),
    updatePlatform: (...args: unknown[]) => mockUpdatePlatform(...args),
    deletePlatform: (...args: unknown[]) => mockDeletePlatform(...args),
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
// Each stub exposes enough surface for the tab's integration points.
// --------------------------------------------------------------------------

// Callbacks captured from the most-recent PlatformList render.
let capturedOnView: ((p: unknown) => void) | undefined;
let capturedOnEdit: ((p: unknown) => void) | undefined;
let capturedOnDelete: ((id: string) => void) | undefined;
let capturedOnCreate: (() => void) | undefined;

// Platform fixture used inside mock factories — must be defined inside the
// factory scope (or use a `mock`-prefixed variable) to satisfy Jest's
// out-of-scope variable restriction.
const mockPlatformFixture = {
  id: 'plat-a',
  name: 'Ubuntu 22.04 LTS',
  description: 'Standard Ubuntu server image',
  enabled: true,
  public: true,
  template_count: 3,
  module_count: 5,
  disk_image_publication_status: 'none' as const,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

jest.mock('@system/features/system/components/platforms', () => ({
  PlatformList: ({
    onView,
    onEdit,
    onDelete,
    onCreate,
  }: {
    onView?: (p: unknown) => void;
    onEdit?: (p: unknown) => void;
    onDelete?: (id: string) => void;
    onCreate?: () => void;
  }) => {
    capturedOnView = onView;
    capturedOnEdit = onEdit;
    capturedOnDelete = onDelete;
    capturedOnCreate = onCreate;
    return (
      <div data-testid="platform-list">
        <button
          data-testid="trigger-view"
          onClick={() => onView?.(mockPlatformFixture)}
        >
          View
        </button>
        <button
          data-testid="trigger-edit"
          onClick={() => onEdit?.(mockPlatformFixture)}
        >
          Edit
        </button>
        <button
          data-testid="trigger-delete"
          onClick={() => onDelete?.(mockPlatformFixture.id)}
        >
          Delete
        </button>
        <button
          data-testid="trigger-create"
          onClick={() => onCreate?.()}
        >
          Create
        </button>
      </div>
    );
  },

  PlatformFormModal: ({
    isOpen,
    onClose,
    onPlatformSaved,
    editPlatform,
  }: {
    isOpen: boolean;
    onClose: () => void;
    onPlatformSaved?: (p: unknown) => void;
    editPlatform?: unknown;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="platform-form-modal">
        <span data-testid="modal-mode">
          {editPlatform ? 'edit' : 'create'}
        </span>
        {/* Mirrors real PlatformFormModal: calls onPlatformSaved then onClose */}
        <button data-testid="modal-save" onClick={() => { onPlatformSaved?.(mockPlatformFixture); onClose(); }}>
          Save
        </button>
        <button data-testid="modal-close" onClick={onClose}>
          Close
        </button>
      </div>
    );
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

// Re-export the fixture for test body use (mock factories use mockPlatformFixture above).
const PLATFORM_A = mockPlatformFixture;

// =============================================================================
// Helpers
// =============================================================================

function renderTab(props: React.ComponentProps<typeof PlatformsTab> = {}) {
  return render(
    <BrowserRouter>
      <PlatformsTab {...props} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PlatformsTab', () => {
  beforeEach(() => {
    mockGetPlatforms.mockReset();
    mockCreatePlatform.mockReset();
    mockUpdatePlatform.mockReset();
    mockDeletePlatform.mockReset();
    mockAddNotification.mockReset();
    capturedOnView = undefined;
    capturedOnEdit = undefined;
    capturedOnDelete = undefined;
    capturedOnCreate = undefined;

    // Default: empty list (most tests drive interaction explicitly)
    mockGetPlatforms.mockResolvedValue([]);
  });

  // -------------------------------------------------------------------------
  // Render
  // -------------------------------------------------------------------------

  it('renders the PlatformList child', () => {
    renderTab();
    expect(screen.getByTestId('platform-list')).toBeInTheDocument();
  });

  it('does not render the form modal by default', () => {
    renderTab();
    expect(screen.queryByTestId('platform-form-modal')).not.toBeInTheDocument();
  });

  it('does not render the delete-confirm dialog by default', () => {
    renderTab();
    expect(screen.queryByText('Delete Platform')).not.toBeInTheDocument();
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

  it('opens the create modal when openCreate is invoked externally', async () => {
    let handle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => { handle = h; });
    renderTab({ onActionsReady });
    act(() => { handle!.openCreate(); });
    await waitFor(() =>
      expect(screen.getByTestId('platform-form-modal')).toBeInTheDocument(),
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
      expect(screen.getByTestId('platform-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('modal-mode').textContent).toBe('create');
  });

  it('closes the form modal when onClose is called from within modal', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-create'));
    await waitFor(() => expect(screen.getByTestId('platform-form-modal')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('modal-close'));
    await waitFor(() =>
      expect(screen.queryByTestId('platform-form-modal')).not.toBeInTheDocument(),
    );
  });

  // -------------------------------------------------------------------------
  // View / Edit flow
  // -------------------------------------------------------------------------

  it('opens the form modal in edit mode when onView is triggered', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-view'));
    await waitFor(() =>
      expect(screen.getByTestId('platform-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('modal-mode').textContent).toBe('edit');
  });

  it('opens the form modal in edit mode when onEdit is triggered', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-edit'));
    await waitFor(() =>
      expect(screen.getByTestId('platform-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('modal-mode').textContent).toBe('edit');
  });

  it('reverts to create mode after form modal is closed following an edit', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    // Edit → close
    fireEvent.click(screen.getByTestId('trigger-edit'));
    await waitFor(() => expect(screen.getByTestId('platform-form-modal')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('modal-close'));
    await waitFor(() => expect(screen.queryByTestId('platform-form-modal')).not.toBeInTheDocument());

    // Now open via the external handle — should be create (no editPlatform)
    const handle = onActionsReady.mock.calls[0][0] as { openCreate: () => void };
    handle.openCreate();
    await waitFor(() => expect(screen.getByTestId('platform-form-modal')).toBeInTheDocument());
    expect(screen.getByTestId('modal-mode').textContent).toBe('create');
  });

  // -------------------------------------------------------------------------
  // Save (onPlatformSaved) — closes modal, triggers list refresh
  // -------------------------------------------------------------------------

  it('closes the form modal after onPlatformSaved fires', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-create'));
    await waitFor(() => expect(screen.getByTestId('platform-form-modal')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('modal-save'));
    await waitFor(() =>
      expect(screen.queryByTestId('platform-form-modal')).not.toBeInTheDocument(),
    );
  });

  // -------------------------------------------------------------------------
  // Permission gating — onDelete is undefined when canDelete is false
  // -------------------------------------------------------------------------

  it('passes onDelete to PlatformList when user has system.platforms.delete', () => {
    renderTab();
    // capturedOnDelete was set during render by the stub
    expect(capturedOnDelete).toBeInstanceOf(Function);
  });

  it('passes onCreate to PlatformList when user has system.platforms.create', () => {
    renderTab();
    expect(capturedOnCreate).toBeInstanceOf(Function);
  });

  // -------------------------------------------------------------------------
  // Delete flow — confirm dialog
  // -------------------------------------------------------------------------

  it('opens delete-confirm dialog when onDelete is triggered', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/are you sure you want to delete this platform/i),
    ).toBeInTheDocument();
  });

  it('closes delete-confirm dialog when Cancel is clicked', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Platform' })).not.toBeInTheDocument(),
    );
  });

  it('closes delete-confirm when backdrop is clicked', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );

    // The backdrop is the fixed inset-0 div with the onClick handler
    const backdrop = document.querySelector('.fixed.inset-0.bg-black\\/50') as HTMLElement;
    fireEvent.click(backdrop);
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Platform' })).not.toBeInTheDocument(),
    );
  });

  it('calls systemApi.deletePlatform with the correct id on confirm', async () => {
    mockDeletePlatform.mockResolvedValue(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /delete platform/i }));

    await waitFor(() =>
      expect(mockDeletePlatform).toHaveBeenCalledWith(PLATFORM_A.id),
    );
  });

  it('shows success notification after successful delete', async () => {
    mockDeletePlatform.mockResolvedValue(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /delete platform/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: 'Platform deleted successfully' }),
      ),
    );
  });

  it('closes delete-confirm dialog after successful delete', async () => {
    mockDeletePlatform.mockResolvedValue(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /delete platform/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Platform' })).not.toBeInTheDocument(),
    );
  });

  it('disables the confirm button while deletion is in progress', async () => {
    // Resolve only after we check the disabled state
    let resolveDelete!: () => void;
    mockDeletePlatform.mockReturnValue(
      new Promise<void>((res) => { resolveDelete = res; }),
    );

    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );

    const confirmBtn = screen.getByRole('button', { name: /delete platform/i });
    fireEvent.click(confirmBtn);

    // Button text changes to "Deleting..." while in-flight
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /deleting\.\.\./i })).toBeDisabled(),
    );

    resolveDelete();
  });

  it('shows error notification when delete fails', async () => {
    mockDeletePlatform.mockRejectedValue(new Error('Server error'));
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /delete platform/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Failed to delete platform: Server error',
        }),
      ),
    );
  });

  it('closes the delete dialog even when deletion fails', async () => {
    mockDeletePlatform.mockRejectedValue(new Error('Oops'));
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /delete platform/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Platform' })).not.toBeInTheDocument(),
    );
  });

  it('falls back to generic error message when delete throws a non-Error', async () => {
    mockDeletePlatform.mockRejectedValue('string-error');
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /delete platform/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Failed to delete platform: An error occurred',
        }),
      ),
    );
  });

  // -------------------------------------------------------------------------
  // Delete dialog — warning message about templates
  // -------------------------------------------------------------------------

  it('shows template-impact warning in the delete dialog', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Platform' })).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/templates using this platform will need to be updated/i),
    ).toBeInTheDocument();
  });
});
