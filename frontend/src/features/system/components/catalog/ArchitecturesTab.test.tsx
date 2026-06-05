import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ArchitecturesTab } from './ArchitecturesTab';

// =============================================================================
// Mocks
//
// ArchitecturesTab delegates list-rendering to ArchitectureList (which calls
// systemApi.getArchitectures) and form/edit to ArchitectureFormModal (which
// calls systemApi.createArchitecture / updateArchitecture). Delete is handled
// directly by ArchitecturesTab via systemApi.deleteArchitecture.
//
// We stub the entire systemApi facade and both child components so the tab
// itself can be exercised in isolation.
// =============================================================================

const mockGetArchitectures = jest.fn();
const mockCreateArchitecture = jest.fn();
const mockUpdateArchitecture = jest.fn();
const mockDeleteArchitecture = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getArchitectures: (...args: unknown[]) => mockGetArchitectures(...args),
    createArchitecture: (...args: unknown[]) => mockCreateArchitecture(...args),
    updateArchitecture: (...args: unknown[]) => mockUpdateArchitecture(...args),
    deleteArchitecture: (...args: unknown[]) => mockDeleteArchitecture(...args),
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
// Stub child components.
//
// jest.mock factories are hoisted before any module-scope declarations.
// Fixtures referenced inside the factory must be defined inline — they
// cannot reach module-level consts. We expose captured callbacks via the
// global object so individual tests can introspect them.
// --------------------------------------------------------------------------

jest.mock('@system/features/system/components/architectures', () => {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const React = require('react');

  // Fixture used inside the factory (avoids hoisting restriction).
  const ARCH_FIXTURE = {
    id: 'arch-a',
    name: 'loongarch64',
    family: 'other',
    enabled: true,
    public: false,
    is_canonical: false,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
  };

  return {
    ArchitectureList: ({
      onView,
      onEdit,
      onDelete,
      onCreate,
    }: {
      onView?: (a: unknown) => void;
      onEdit?: (a: unknown) => void;
      onDelete?: (id: string) => void;
      onCreate?: () => void;
    }) => {
      // Write callbacks to global so tests outside the factory can read them.
      (global as Record<string, unknown>).__archListCallbacks__ = {
        onView,
        onEdit,
        onDelete,
        onCreate,
      };
      return React.createElement(
        'div',
        { 'data-testid': 'architecture-list' },
        React.createElement(
          'button',
          { 'data-testid': 'trigger-view', onClick: () => onView?.(ARCH_FIXTURE) },
          'View',
        ),
        React.createElement(
          'button',
          { 'data-testid': 'trigger-edit', onClick: () => onEdit?.(ARCH_FIXTURE) },
          'Edit',
        ),
        React.createElement(
          'button',
          { 'data-testid': 'trigger-delete', onClick: () => onDelete?.(ARCH_FIXTURE.id) },
          'Delete',
        ),
        React.createElement(
          'button',
          { 'data-testid': 'trigger-create', onClick: () => onCreate?.() },
          'Create',
        ),
      );
    },

    ArchitectureFormModal: ({
      isOpen,
      onClose,
      onArchitectureSaved,
      editArchitecture,
    }: {
      isOpen: boolean;
      onClose: () => void;
      onArchitectureSaved?: (a: unknown) => void;
      editArchitecture?: unknown;
    }) => {
      if (!isOpen) return null;
      return React.createElement(
        'div',
        { 'data-testid': 'architecture-form-modal' },
        React.createElement(
          'span',
          { 'data-testid': 'modal-mode' },
          editArchitecture ? 'edit' : 'create',
        ),
        React.createElement(
          'button',
          {
            'data-testid': 'modal-save',
            onClick: () => {
              // Mirror real modal: calls onArchitectureSaved then onClose.
              onArchitectureSaved?.(ARCH_FIXTURE);
              onClose();
            },
          },
          'Save',
        ),
        React.createElement(
          'button',
          { 'data-testid': 'modal-close', onClick: onClose },
          'Close',
        ),
      );
    },
  };
});

// =============================================================================
// Helpers
// =============================================================================

type ArchListCallbacks = {
  onView?: (a: unknown) => void;
  onEdit?: (a: unknown) => void;
  onDelete?: (id: string) => void;
  onCreate?: () => void;
};

function getArchListCallbacks(): ArchListCallbacks {
  return ((global as Record<string, unknown>).__archListCallbacks__ ?? {}) as ArchListCallbacks;
}

function renderTab(props: React.ComponentProps<typeof ArchitecturesTab> = {}) {
  return render(
    <BrowserRouter>
      <ArchitecturesTab {...props} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('ArchitecturesTab', () => {
  beforeEach(() => {
    mockGetArchitectures.mockReset();
    mockCreateArchitecture.mockReset();
    mockUpdateArchitecture.mockReset();
    mockDeleteArchitecture.mockReset();
    mockAddNotification.mockReset();
    delete (global as Record<string, unknown>).__archListCallbacks__;

    // Default: return an empty list
    mockGetArchitectures.mockResolvedValue([]);
  });

  // -------------------------------------------------------------------------
  // Render
  // -------------------------------------------------------------------------

  it('renders the ArchitectureList child', () => {
    renderTab();
    expect(screen.getByTestId('architecture-list')).toBeInTheDocument();
  });

  it('does not render the form modal by default', () => {
    renderTab();
    expect(screen.queryByTestId('architecture-form-modal')).not.toBeInTheDocument();
  });

  it('does not render the delete-confirm dialog by default', () => {
    renderTab();
    expect(screen.queryByRole('heading', { name: 'Delete Architecture' })).not.toBeInTheDocument();
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
    // Wait for the effect to have fired and handle to be set
    await waitFor(() => expect(handle).not.toBeNull());
    act(() => { handle!.openCreate(); });
    expect(screen.getByTestId('architecture-form-modal')).toBeInTheDocument();
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

  it('opens the form modal in create mode when onCreate is triggered via ArchitectureList', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-create'));
    await waitFor(() =>
      expect(screen.getByTestId('architecture-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('modal-mode').textContent).toBe('create');
  });

  it('closes the form modal when onClose is called from within the modal', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-create'));
    await waitFor(() => expect(screen.getByTestId('architecture-form-modal')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('modal-close'));
    await waitFor(() =>
      expect(screen.queryByTestId('architecture-form-modal')).not.toBeInTheDocument(),
    );
  });

  // -------------------------------------------------------------------------
  // View / Edit flow
  // -------------------------------------------------------------------------

  it('opens the form modal in edit mode when onView is triggered via ArchitectureList', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-view'));
    await waitFor(() =>
      expect(screen.getByTestId('architecture-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('modal-mode').textContent).toBe('edit');
  });

  it('opens the form modal in edit mode when onEdit is triggered via ArchitectureList', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-edit'));
    await waitFor(() =>
      expect(screen.getByTestId('architecture-form-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('modal-mode').textContent).toBe('edit');
  });

  it('reverts to create mode (no editArchitecture) after closing an edit session', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    // Open edit
    fireEvent.click(screen.getByTestId('trigger-edit'));
    await waitFor(() => expect(screen.getByTestId('architecture-form-modal')).toBeInTheDocument());
    // Close
    fireEvent.click(screen.getByTestId('modal-close'));
    await waitFor(() => expect(screen.queryByTestId('architecture-form-modal')).not.toBeInTheDocument());

    // Now open via the external handle — should be create (editArchitecture is null)
    const handle = onActionsReady.mock.calls[0][0] as { openCreate: () => void };
    handle.openCreate();
    await waitFor(() => expect(screen.getByTestId('architecture-form-modal')).toBeInTheDocument());
    expect(screen.getByTestId('modal-mode').textContent).toBe('create');
  });

  // -------------------------------------------------------------------------
  // Save (onArchitectureSaved) — closes modal
  // -------------------------------------------------------------------------

  it('closes the form modal after onArchitectureSaved fires', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-create'));
    await waitFor(() => expect(screen.getByTestId('architecture-form-modal')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('modal-save'));
    await waitFor(() =>
      expect(screen.queryByTestId('architecture-form-modal')).not.toBeInTheDocument(),
    );
  });

  // -------------------------------------------------------------------------
  // Permission gating
  // -------------------------------------------------------------------------

  it('passes onDelete to ArchitectureList when user has system.architectures.delete', () => {
    renderTab();
    expect(getArchListCallbacks().onDelete).toBeInstanceOf(Function);
  });

  it('passes onCreate to ArchitectureList when user has system.architectures.create', () => {
    renderTab();
    expect(getArchListCallbacks().onCreate).toBeInstanceOf(Function);
  });

  // -------------------------------------------------------------------------
  // Delete flow — confirm dialog
  // -------------------------------------------------------------------------

  it('opens the delete-confirm dialog when onDelete is triggered', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Architecture' })).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/are you sure you want to delete this architecture/i),
    ).toBeInTheDocument();
  });

  it('closes the delete-confirm dialog when Cancel is clicked', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Delete Architecture' })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Architecture' })).not.toBeInTheDocument(),
    );
  });

  it('closes the delete-confirm dialog when the backdrop is clicked', async () => {
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Delete Architecture' })).toBeInTheDocument());

    // The semi-transparent backdrop overlay
    const backdrop = document.querySelector('.bg-black\\/50') as HTMLElement;
    fireEvent.click(backdrop);
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Architecture' })).not.toBeInTheDocument(),
    );
  });

  it('calls systemApi.deleteArchitecture with the correct id when confirmed', async () => {
    mockDeleteArchitecture.mockResolvedValue(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Delete Architecture' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /delete architecture/i }));

    await waitFor(() =>
      expect(mockDeleteArchitecture).toHaveBeenCalledWith('arch-a'),
    );
  });

  it('shows a success notification after a successful delete', async () => {
    mockDeleteArchitecture.mockResolvedValue(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Delete Architecture' })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /delete architecture/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'success',
          message: 'Architecture deleted successfully',
        }),
      ),
    );
  });

  it('closes the delete-confirm dialog after a successful delete', async () => {
    mockDeleteArchitecture.mockResolvedValue(undefined);
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Delete Architecture' })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /delete architecture/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Architecture' })).not.toBeInTheDocument(),
    );
  });

  it('disables the confirm button while deletion is in progress', async () => {
    let resolveDelete!: () => void;
    mockDeleteArchitecture.mockReturnValue(
      new Promise<void>((res) => { resolveDelete = res; }),
    );

    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Delete Architecture' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /delete architecture/i }));

    // Button text changes to "Deleting..." while the promise is pending
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /deleting\.\.\./i })).toBeDisabled(),
    );

    resolveDelete();
  });

  it('shows an error notification when deletion fails', async () => {
    mockDeleteArchitecture.mockRejectedValue(new Error('Server error'));
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Delete Architecture' })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /delete architecture/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Failed to delete architecture: Server error',
        }),
      ),
    );
  });

  it('closes the delete dialog even when deletion fails', async () => {
    mockDeleteArchitecture.mockRejectedValue(new Error('Oops'));
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Delete Architecture' })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /delete architecture/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Architecture' })).not.toBeInTheDocument(),
    );
  });

  it('falls back to a generic error message when delete throws a non-Error value', async () => {
    mockDeleteArchitecture.mockRejectedValue('string-error');
    renderTab();
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Delete Architecture' })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /delete architecture/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Failed to delete architecture: An error occurred',
        }),
      ),
    );
  });
});
