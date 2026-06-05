import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { TemplatesTab } from './TemplatesTab';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

// systemApi — only deleteTemplate is called by TemplatesTab directly.
// getTemplates / getPlatforms are called by the child components (TemplateList
// and CreateTemplateModal) which are mocked below.
const mockDeleteTemplate = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    deleteTemplate: (...args: unknown[]) => mockDeleteTemplate(...args),
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

// ---------------------------------------------------------------------------
// Child-component stubs
//
// TemplatesTab renders three compound children that each own their own API
// surface. We stub them with thin test-friendly stand-ins so TemplatesTab
// can exercise its own state machine (modal open/close, refreshKey, delete
// confirmation) without needing a full jsdom + network stack for each child.
// ---------------------------------------------------------------------------

// Captured callbacks that tests can call to simulate child-driven events.
let capturedOnView: ((t: SystemNodeTemplate) => void) | undefined;
let capturedOnEdit: ((t: SystemNodeTemplate) => void) | undefined;
let capturedOnDelete: ((id: string) => void) | undefined;
let capturedOnCreate: (() => void) | undefined;
let capturedOnDuplicate: ((t: SystemNodeTemplate) => void) | undefined;

jest.mock('@system/features/system/components/templates', () => ({
  // TemplateList: renders a minimal sentinel; captures callbacks so tests
  // can invoke them directly (wrapped in act() for state flush).
  TemplateList: ({
    onView,
    onEdit,
    onDelete,
    onCreate,
    onDuplicate,
  }: {
    onView?: (t: SystemNodeTemplate) => void;
    onEdit?: (t: SystemNodeTemplate) => void;
    onDelete?: (id: string) => void;
    onCreate?: () => void;
    onDuplicate?: (t: SystemNodeTemplate) => void;
  }) => {
    capturedOnView = onView;
    capturedOnEdit = onEdit;
    capturedOnDelete = onDelete;
    capturedOnCreate = onCreate;
    capturedOnDuplicate = onDuplicate;
    return <div data-testid="template-list" />;
  },

  // TemplateDetailModal: controlled by isOpen; triggers onEdit when its
  // "trigger-edit" button is clicked, onClose when "close-detail" is clicked.
  TemplateDetailModal: ({
    isOpen,
    templateId,
    onClose,
    onEdit,
    onTemplateUpdated,
  }: {
    isOpen: boolean;
    templateId: string | null;
    onClose: () => void;
    onEdit?: (t: SystemNodeTemplate) => void;
    onTemplateUpdated?: () => void;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="template-detail-modal" data-template-id={templateId ?? ''}>
        <button onClick={onClose}>close-detail</button>
        <button
          onClick={() =>
            onEdit?.({
              id: templateId ?? 'tpl-1',
              name: 'My Template',
              enabled: true,
              public: false,
              config: {},
              created_at: '2026-01-01T00:00:00Z',
              updated_at: '2026-01-01T00:00:00Z',
            })
          }
        >
          trigger-edit-from-detail
        </button>
        <button onClick={() => onTemplateUpdated?.()}>trigger-update</button>
      </div>
    );
  },

  // CreateTemplateModal: controlled by isOpen; triggers onTemplateCreated when
  // "trigger-created" is clicked. The real modal calls onClose after a
  // successful create/update; we mirror that behavior so TemplatesTab's state
  // machine is exercised correctly (modal closes after creation).
  CreateTemplateModal: ({
    isOpen,
    onClose,
    onTemplateCreated,
    editTemplate,
    duplicateFrom,
  }: {
    isOpen: boolean;
    onClose: () => void;
    onTemplateCreated?: (t: SystemNodeTemplate) => void;
    editTemplate?: SystemNodeTemplate | null;
    duplicateFrom?: SystemNodeTemplate | null;
  }) => {
    if (!isOpen) return null;
    const mode = editTemplate ? 'edit' : duplicateFrom ? 'duplicate' : 'create';
    return (
      <div data-testid="create-template-modal" data-mode={mode}>
        <button onClick={onClose}>close-create</button>
        <button
          onClick={() => {
            onTemplateCreated?.({
              id: 'tpl-new',
              name: 'New Template',
              enabled: true,
              public: false,
              config: {},
              created_at: '2026-01-01T00:00:00Z',
              updated_at: '2026-01-01T00:00:00Z',
            });
            // Real modal calls onClose after success
            onClose();
          }}
        >
          trigger-created
        </button>
      </div>
    );
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const TEMPLATE_A: SystemNodeTemplate = {
  id: 'tpl-a',
  name: 'Template A',
  enabled: true,
  public: true,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TEMPLATE_B: SystemNodeTemplate = {
  id: 'tpl-b',
  name: 'Template B',
  enabled: false,
  public: false,
  config: {},
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

const renderTab = (props: Partial<React.ComponentProps<typeof TemplatesTab>> = {}) =>
  render(
    <BrowserRouter>
      <TemplatesTab {...props} />
    </BrowserRouter>,
  );

// Invoke a captured TemplateList callback inside act() so React flushes state.
function fireListCallback(cb: (() => void) | undefined): void {
  act(() => {
    cb?.();
  });
}

// Overload for callbacks that accept a template argument.
function fireListCallbackWith<T>(cb: ((arg: T) => void) | undefined, arg: T): void {
  act(() => {
    cb?.(arg);
  });
}

// =============================================================================
// Tests
// =============================================================================

describe('TemplatesTab', () => {
  beforeEach(() => {
    mockDeleteTemplate.mockReset();
    mockAddNotification.mockReset();
    capturedOnView = undefined;
    capturedOnEdit = undefined;
    capturedOnDelete = undefined;
    capturedOnCreate = undefined;
    capturedOnDuplicate = undefined;
  });

  // ---------------------------------------------------------------------------
  // Initial render
  // ---------------------------------------------------------------------------

  it('renders the TemplateList sentinel on mount', () => {
    renderTab();
    expect(screen.getByTestId('template-list')).toBeInTheDocument();
  });

  it('does not render any modal before interaction', () => {
    renderTab();
    expect(screen.queryByTestId('create-template-modal')).not.toBeInTheDocument();
    expect(screen.queryByTestId('template-detail-modal')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onActionsReady callback
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with an openCreate handle on mount', () => {
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

  it('openCreate handle from onActionsReady opens the create modal', () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    const handle = onActionsReady.mock.calls[0][0] as { openCreate: () => void };
    act(() => {
      handle.openCreate();
    });

    expect(screen.getByTestId('create-template-modal')).toBeInTheDocument();
    expect(screen.getByTestId('create-template-modal')).toHaveAttribute('data-mode', 'create');
  });

  // ---------------------------------------------------------------------------
  // Create modal — opened via TemplateList onCreate callback
  // ---------------------------------------------------------------------------

  it('opens the create modal in create mode when TemplateList fires onCreate', () => {
    renderTab();
    fireListCallback(capturedOnCreate);
    expect(screen.getByTestId('create-template-modal')).toBeInTheDocument();
    expect(screen.getByTestId('create-template-modal')).toHaveAttribute('data-mode', 'create');
  });

  it('closes the create modal when onClose fires inside it', () => {
    renderTab();
    fireListCallback(capturedOnCreate);
    expect(screen.getByTestId('create-template-modal')).toBeInTheDocument();
    fireEvent.click(screen.getByText('close-create'));
    expect(screen.queryByTestId('create-template-modal')).not.toBeInTheDocument();
  });

  it('closes the create modal when onTemplateCreated fires', () => {
    renderTab();
    fireListCallback(capturedOnCreate);
    expect(screen.getByTestId('create-template-modal')).toBeInTheDocument();
    fireEvent.click(screen.getByText('trigger-created'));
    // Modal should close
    expect(screen.queryByTestId('create-template-modal')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Edit modal — opened via TemplateList onEdit callback
  // ---------------------------------------------------------------------------

  it('opens the create modal in edit mode when TemplateList fires onEdit', () => {
    renderTab();
    fireListCallbackWith(capturedOnEdit, TEMPLATE_A);
    expect(screen.getByTestId('create-template-modal')).toBeInTheDocument();
    expect(screen.getByTestId('create-template-modal')).toHaveAttribute('data-mode', 'edit');
  });

  // ---------------------------------------------------------------------------
  // Duplicate modal — opened via TemplateList onDuplicate callback
  // ---------------------------------------------------------------------------

  it('opens the create modal in duplicate mode when TemplateList fires onDuplicate', () => {
    renderTab();
    fireListCallbackWith(capturedOnDuplicate, TEMPLATE_A);
    expect(screen.getByTestId('create-template-modal')).toBeInTheDocument();
    expect(screen.getByTestId('create-template-modal')).toHaveAttribute('data-mode', 'duplicate');
  });

  // ---------------------------------------------------------------------------
  // View → Detail modal
  // ---------------------------------------------------------------------------

  it('opens the detail modal with the correct template id when TemplateList fires onView', () => {
    renderTab();
    fireListCallbackWith(capturedOnView, TEMPLATE_A);
    const modal = screen.getByTestId('template-detail-modal');
    expect(modal).toBeInTheDocument();
    expect(modal).toHaveAttribute('data-template-id', 'tpl-a');
  });

  it('closes the detail modal when its onClose fires', () => {
    renderTab();
    fireListCallbackWith(capturedOnView, TEMPLATE_B);
    expect(screen.getByTestId('template-detail-modal')).toBeInTheDocument();
    fireEvent.click(screen.getByText('close-detail'));
    expect(screen.queryByTestId('template-detail-modal')).not.toBeInTheDocument();
  });

  it('transitions from detail to edit modal when onEdit fires from within the detail modal', () => {
    renderTab();
    // Open detail first
    fireListCallbackWith(capturedOnView, TEMPLATE_A);
    expect(screen.getByTestId('template-detail-modal')).toBeInTheDocument();

    // Trigger edit from within the detail modal
    fireEvent.click(screen.getByText('trigger-edit-from-detail'));

    // Detail closes, create modal opens in edit mode
    expect(screen.queryByTestId('template-detail-modal')).not.toBeInTheDocument();
    expect(screen.getByTestId('create-template-modal')).toBeInTheDocument();
    expect(screen.getByTestId('create-template-modal')).toHaveAttribute('data-mode', 'edit');
  });

  // ---------------------------------------------------------------------------
  // Delete confirmation dialog
  // ---------------------------------------------------------------------------

  it('shows the delete confirmation dialog when TemplateList fires onDelete', () => {
    renderTab();
    fireListCallbackWith(capturedOnDelete, 'tpl-a');
    // The heading "Delete Template" and a button "Delete Template" are both present;
    // query the heading specifically.
    expect(screen.getByRole('heading', { name: /delete template/i })).toBeInTheDocument();
    expect(
      screen.getByText(/are you sure you want to delete this template/i),
    ).toBeInTheDocument();
  });

  it('hides the delete confirmation when Cancel is clicked', () => {
    renderTab();
    fireListCallbackWith(capturedOnDelete, 'tpl-a');
    expect(screen.getByRole('heading', { name: /delete template/i })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(screen.queryByText(/are you sure you want to delete/i)).not.toBeInTheDocument();
  });

  it('dismisses delete dialog on backdrop click', () => {
    renderTab();
    fireListCallbackWith(capturedOnDelete, 'tpl-a');
    expect(screen.getByText(/are you sure you want to delete/i)).toBeInTheDocument();

    // The semi-transparent overlay element that closes the dialog on click
    const overlay = document.querySelector('.bg-black\\/50') as HTMLElement;
    expect(overlay).not.toBeNull();
    fireEvent.click(overlay);

    expect(screen.queryByText(/are you sure you want to delete/i)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Delete — confirm → API call → success notification
  // ---------------------------------------------------------------------------

  it('calls systemApi.deleteTemplate with the correct id and shows success notification', async () => {
    mockDeleteTemplate.mockResolvedValueOnce(undefined);
    renderTab();

    fireListCallbackWith(capturedOnDelete, 'tpl-a');
    fireEvent.click(screen.getByRole('button', { name: /delete template/i }));

    await waitFor(() =>
      expect(mockDeleteTemplate).toHaveBeenCalledWith('tpl-a'),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Template deleted successfully',
      }),
    );
  });

  it('dismisses the delete dialog after a successful delete', async () => {
    mockDeleteTemplate.mockResolvedValueOnce(undefined);
    renderTab();

    fireListCallbackWith(capturedOnDelete, 'tpl-b');
    fireEvent.click(screen.getByRole('button', { name: /delete template/i }));

    await waitFor(() =>
      expect(screen.queryByText(/are you sure you want to delete/i)).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Delete — API failure → error notification, dialog closes
  // ---------------------------------------------------------------------------

  it('shows an error notification when deleteTemplate rejects', async () => {
    mockDeleteTemplate.mockRejectedValueOnce(new Error('not found'));
    renderTab();

    fireListCallbackWith(capturedOnDelete, 'tpl-a');
    fireEvent.click(screen.getByRole('button', { name: /delete template/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete template: not found',
      }),
    );
    // Dialog should still close on failure
    await waitFor(() =>
      expect(screen.queryByText(/are you sure you want to delete/i)).not.toBeInTheDocument(),
    );
  });

  it('shows generic error text when rejection is not an Error instance', async () => {
    mockDeleteTemplate.mockRejectedValueOnce('something went wrong');
    renderTab();

    fireListCallbackWith(capturedOnDelete, 'tpl-a');
    fireEvent.click(screen.getByRole('button', { name: /delete template/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete template: An error occurred',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Delete button disabled while deleting
  // ---------------------------------------------------------------------------

  it('disables the Delete Template button while the API call is in flight', async () => {
    let resolveDelete!: () => void;
    mockDeleteTemplate.mockReturnValueOnce(
      new Promise<void>((res) => {
        resolveDelete = res;
      }),
    );

    renderTab();
    fireListCallbackWith(capturedOnDelete, 'tpl-a');
    const deleteBtn = screen.getByRole('button', { name: /delete template/i });
    fireEvent.click(deleteBtn);

    // While in-flight the button text changes and it's disabled
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /deleting/i })).toBeDisabled(),
    );

    // Resolve so the component can settle
    resolveDelete();
    await waitFor(() =>
      expect(screen.queryByText(/are you sure you want to delete/i)).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Permission gating — onDelete/onCreate/onDuplicate omitted when no perms
  // ---------------------------------------------------------------------------

  it('does not pass onDelete to TemplateList when user lacks system.templates.delete', () => {
    const perm = require('@/shared/hooks/usePermissions');
    const original = perm.usePermissions;
    perm.usePermissions = () => ({
      hasPermission: (p: string) => p !== 'system.templates.delete',
    });

    renderTab();
    expect(capturedOnDelete).toBeUndefined();

    // Restore
    perm.usePermissions = original;
  });

  it('does not pass onCreate/onDuplicate to TemplateList when user lacks system.templates.create', () => {
    const perm = require('@/shared/hooks/usePermissions');
    const original = perm.usePermissions;
    perm.usePermissions = () => ({
      hasPermission: (p: string) => p !== 'system.templates.create',
    });

    renderTab();
    expect(capturedOnCreate).toBeUndefined();
    expect(capturedOnDuplicate).toBeUndefined();

    // Restore
    perm.usePermissions = original;
  });

  // ---------------------------------------------------------------------------
  // Multiple sequential operations
  // ---------------------------------------------------------------------------

  it('can open and close the create modal twice in a row without leftover state', () => {
    renderTab();

    // First open
    fireListCallback(capturedOnCreate);
    expect(screen.getByTestId('create-template-modal')).toBeInTheDocument();
    fireEvent.click(screen.getByText('close-create'));
    expect(screen.queryByTestId('create-template-modal')).not.toBeInTheDocument();

    // Second open — should still work and be in create mode
    fireListCallback(capturedOnCreate);
    expect(screen.getByTestId('create-template-modal')).toBeInTheDocument();
    expect(screen.getByTestId('create-template-modal')).toHaveAttribute('data-mode', 'create');
  });

  it('resets duplicate/edit state when switching from edit back to create', () => {
    renderTab();

    // Edit flow
    fireListCallbackWith(capturedOnEdit, TEMPLATE_A);
    expect(screen.getByTestId('create-template-modal')).toHaveAttribute('data-mode', 'edit');
    fireEvent.click(screen.getByText('close-create'));

    // Fresh create should have no editTemplate / duplicateFrom
    fireListCallback(capturedOnCreate);
    expect(screen.getByTestId('create-template-modal')).toHaveAttribute('data-mode', 'create');
  });
});
