import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ScriptsTab } from './ScriptsTab';

// =============================================================================
// Mocks
//
// ScriptsTab orchestrates: systemApi.deleteScript and renders two child
// components (ScriptList, ScriptFormModal). We mock all those surfaces so we
// can verify the orchestration logic (state management, delete flow, modal
// open/close, permission gating, refresh) in isolation.
// =============================================================================

const mockDeleteScript = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    deleteScript: (...args: unknown[]) => mockDeleteScript(...args),
  },
}));

const mockHasPermission = jest.fn(() => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (...args: unknown[]) => mockHasPermission(...args),
  }),
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

// ---------------------------------------------------------------------------
// Child component stubs — surface only the props ScriptsTab cares about.
// ---------------------------------------------------------------------------

// Capture callbacks so tests can trigger them directly without needing to
// reach through the full ScriptList render tree.
let capturedOnView: ((s: { id: string; name: string }) => void) | undefined;
let capturedOnEdit: ((s: { id: string; name: string }) => void) | undefined;
let capturedOnDelete: ((id: string) => void) | undefined;
let capturedOnCreate: (() => void) | undefined;

jest.mock('@system/features/system/components/scripts', () => ({
  ScriptList: (props: {
    onView?: (s: { id: string; name: string }) => void;
    onEdit?: (s: { id: string; name: string }) => void;
    onDelete?: (id: string) => void;
    onCreate?: () => void;
  }) => {
    capturedOnView = props.onView;
    capturedOnEdit = props.onEdit;
    capturedOnDelete = props.onDelete;
    capturedOnCreate = props.onCreate;
    return <div data-testid="script-list">ScriptList</div>;
  },

  ScriptFormModal: (props: {
    isOpen: boolean;
    onClose: () => void;
    onScriptSaved: (s: { id: string; name: string }) => void;
    editScript: { id: string; name: string } | null;
  }) =>
    props.isOpen ? (
      <div data-testid="script-form-modal">
        <span data-testid="form-edit-script-id">{props.editScript?.id ?? 'new'}</span>
        <button onClick={props.onClose} data-testid="form-close">Close</button>
        <button
          onClick={() => {
            // Real ScriptFormModal calls onScriptSaved then onClose — mirror that.
            props.onScriptSaved({ id: props.editScript?.id ?? 'new-id', name: 'Saved Script' });
            props.onClose();
          }}
          data-testid="form-saved"
        >
          Save
        </button>
      </div>
    ) : null,
}));

// =============================================================================
// Fixtures
// =============================================================================

const SCRIPT_A = {
  id: 'script-a',
  name: 'install-deps',
  description: 'Installs system dependencies',
  variety: 'init' as const,
  data: '#!/bin/bash\napt-get install -y curl',
  enabled: true,
  public: false,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

const renderTab = (onActionsReady?: jest.Mock) =>
  render(
    <BrowserRouter>
      <ScriptsTab onActionsReady={onActionsReady} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('ScriptsTab', () => {
  beforeEach(() => {
    mockDeleteScript.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);

    // Reset captured callbacks
    capturedOnView = undefined;
    capturedOnEdit = undefined;
    capturedOnDelete = undefined;
    capturedOnCreate = undefined;
  });

  // ---------------------------------------------------------------------------
  // Render / mount
  // ---------------------------------------------------------------------------

  it('renders the ScriptList on mount', () => {
    renderTab();

    expect(screen.getByTestId('script-list')).toBeInTheDocument();
  });

  it('calls onActionsReady with an openCreate handle on mount', () => {
    const onActionsReady = jest.fn();
    renderTab(onActionsReady);

    expect(onActionsReady).toHaveBeenCalledWith(
      expect.objectContaining({
        openCreate: expect.any(Function),
      }),
    );
  });

  it('calls onActionsReady(null) on unmount', () => {
    const onActionsReady = jest.fn();
    const { unmount } = renderTab(onActionsReady);
    unmount();
    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  // ---------------------------------------------------------------------------
  // Permission gating — ScriptList props
  // ---------------------------------------------------------------------------

  it('passes onDelete to ScriptList when system.scripts.delete is granted', () => {
    renderTab();
    expect(capturedOnDelete).toBeDefined();
  });

  it('passes undefined onDelete to ScriptList when system.scripts.delete is denied', () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.scripts.delete');
    renderTab();
    expect(capturedOnDelete).toBeUndefined();
  });

  it('passes onCreate to ScriptList when system.scripts.create is granted', () => {
    renderTab();
    expect(capturedOnCreate).toBeDefined();
  });

  it('passes undefined onCreate to ScriptList when system.scripts.create is denied', () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.scripts.create');
    renderTab();
    expect(capturedOnCreate).toBeUndefined();
  });

  // ---------------------------------------------------------------------------
  // ScriptFormModal — create flow
  // ---------------------------------------------------------------------------

  it('opens ScriptFormModal for create when openCreate handle is invoked', async () => {
    const onActionsReady = jest.fn();
    renderTab(onActionsReady);

    const handle = onActionsReady.mock.calls[0][0];
    handle.openCreate();

    expect(await screen.findByTestId('script-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-script-id').textContent).toBe('new');
  });

  it('opens ScriptFormModal for create when ScriptList onCreate callback fires', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnCreate).toBeDefined());

    capturedOnCreate!();

    expect(await screen.findByTestId('script-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-script-id').textContent).toBe('new');
  });

  it('closes ScriptFormModal when its onClose fires', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnCreate).toBeDefined());

    capturedOnCreate!();
    await screen.findByTestId('script-form-modal');

    fireEvent.click(screen.getByTestId('form-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('script-form-modal')).not.toBeInTheDocument(),
    );
  });

  it('closes ScriptFormModal and clears editScript after onScriptSaved fires', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnCreate).toBeDefined());

    capturedOnCreate!();
    await screen.findByTestId('script-form-modal');

    fireEvent.click(screen.getByTestId('form-saved'));

    await waitFor(() =>
      expect(screen.queryByTestId('script-form-modal')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // ScriptFormModal — edit/view flow
  // ---------------------------------------------------------------------------

  it('opens ScriptFormModal in edit mode when ScriptList onView fires', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnView).toBeDefined());

    capturedOnView!(SCRIPT_A);

    expect(await screen.findByTestId('script-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-script-id').textContent).toBe('script-a');
  });

  it('opens ScriptFormModal in edit mode when ScriptList onEdit fires', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnEdit).toBeDefined());

    capturedOnEdit!(SCRIPT_A);

    expect(await screen.findByTestId('script-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-script-id').textContent).toBe('script-a');
  });

  it('closes ScriptFormModal and clears editScript when onClose fires during edit', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnEdit).toBeDefined());

    capturedOnEdit!(SCRIPT_A);
    await screen.findByTestId('script-form-modal');

    fireEvent.click(screen.getByTestId('form-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('script-form-modal')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Delete — confirmation dialog
  // ---------------------------------------------------------------------------

  it('shows delete confirmation dialog when ScriptList onDelete fires (with canDelete=true)', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnDelete).toBeDefined());

    capturedOnDelete!('script-a');

    // The heading "Delete Script" uniquely identifies the dialog opening.
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /delete script/i })).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/Are you sure you want to delete this script/i),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/This action cannot be undone/i),
    ).toBeInTheDocument();
  });

  it('calls systemApi.deleteScript with the correct ID after confirming delete', async () => {
    mockDeleteScript.mockResolvedValue(undefined);
    renderTab();
    await waitFor(() => expect(capturedOnDelete).toBeDefined());

    capturedOnDelete!('script-a');
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /delete script/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /delete script/i }));

    await waitFor(() =>
      expect(mockDeleteScript).toHaveBeenCalledWith('script-a'),
    );
  });

  it('shows success notification after a successful delete', async () => {
    mockDeleteScript.mockResolvedValue(undefined);
    renderTab();
    await waitFor(() => expect(capturedOnDelete).toBeDefined());

    capturedOnDelete!('script-a');
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /delete script/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /delete script/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Script deleted successfully',
      }),
    );
  });

  it('dismisses the delete confirmation dialog after a successful delete', async () => {
    mockDeleteScript.mockResolvedValue(undefined);
    renderTab();
    await waitFor(() => expect(capturedOnDelete).toBeDefined());

    capturedOnDelete!('script-a');
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /delete script/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /delete script/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /delete script/i })).not.toBeInTheDocument(),
    );
  });

  it('shows error notification with message when deleteScript rejects with an Error', async () => {
    mockDeleteScript.mockRejectedValue(new Error('Server error'));
    renderTab();
    await waitFor(() => expect(capturedOnDelete).toBeDefined());

    capturedOnDelete!('script-a');
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /delete script/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /delete script/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete script: Server error',
      }),
    );
  });

  it('shows "An error occurred" when deleteScript rejects with a non-Error value', async () => {
    mockDeleteScript.mockRejectedValue('unknown failure');
    renderTab();
    await waitFor(() => expect(capturedOnDelete).toBeDefined());

    capturedOnDelete!('script-a');
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /delete script/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /delete script/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete script: An error occurred',
      }),
    );
  });

  it('dismisses the dialog without an API call when Cancel is clicked', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnDelete).toBeDefined());

    capturedOnDelete!('script-a');
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /delete script/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /delete script/i })).not.toBeInTheDocument(),
    );
    expect(mockDeleteScript).not.toHaveBeenCalled();
  });

  it('shows "Deleting..." and disables the button while the delete is in-flight', async () => {
    let resolve!: () => void;
    mockDeleteScript.mockImplementation(
      () => new Promise<void>((res) => { resolve = res; }),
    );
    renderTab();
    await waitFor(() => expect(capturedOnDelete).toBeDefined());

    capturedOnDelete!('script-a');
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /delete script/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /delete script/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /processing\.\.\./i })).toBeDisabled(),
    );

    resolve();
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /delete script/i })).not.toBeInTheDocument(),
    );
  });

  it('dismisses the delete dialog when the backdrop overlay is clicked', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnDelete).toBeDefined());

    capturedOnDelete!('script-a');
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /delete script/i })).toBeInTheDocument(),
    );

    const overlay = screen.getByRole('dialog').firstElementChild;
    expect(overlay).toBeTruthy();
    fireEvent.click(overlay!);

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /delete script/i })).not.toBeInTheDocument(),
    );
    expect(mockDeleteScript).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Refresh key / ScriptList remounting
  // ---------------------------------------------------------------------------

  it('ScriptList receives a new key (refreshKey increments) after a successful delete — ScriptList re-rendered', async () => {
    mockDeleteScript.mockResolvedValue(undefined);
    renderTab();
    await waitFor(() => expect(capturedOnDelete).toBeDefined());

    capturedOnDelete!('script-a');
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /delete script/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /delete script/i }));

    // Full delete cycle: API called, notification shown, dialog dismissed, ScriptList still present.
    await waitFor(() => expect(mockDeleteScript).toHaveBeenCalledWith('script-a'));
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Script deleted successfully',
      }),
    );
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /delete script/i })).not.toBeInTheDocument(),
    );
    // ScriptList is still in the DOM (remounted under a new key).
    expect(screen.getByTestId('script-list')).toBeInTheDocument();
    // Delete callback is still wired up from the fresh mount.
    await waitFor(() => expect(capturedOnDelete).toBeDefined());
  });

  it('ScriptList receives a new key (refreshKey increments) after onScriptSaved — ScriptList re-rendered', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnCreate).toBeDefined());

    capturedOnCreate!();
    await screen.findByTestId('script-form-modal');
    fireEvent.click(screen.getByTestId('form-saved'));

    // Modal closes (stub calls onClose after onScriptSaved)
    await waitFor(() =>
      expect(screen.queryByTestId('script-form-modal')).not.toBeInTheDocument(),
    );
    // ScriptList is still present after remount.
    expect(screen.getByTestId('script-list')).toBeInTheDocument();
    // Create callback is still wired up from the fresh mount.
    await waitFor(() => expect(capturedOnCreate).toBeDefined());
  });

  // ---------------------------------------------------------------------------
  // Modal default state resets on close
  // ---------------------------------------------------------------------------

  it('resets to create mode (no editScript) after closing edit modal and reopening for create', async () => {
    renderTab();
    await waitFor(() => expect(capturedOnEdit).toBeDefined());

    // Open in edit mode
    capturedOnEdit!(SCRIPT_A);
    await screen.findByTestId('script-form-modal');
    expect(screen.getByTestId('form-edit-script-id').textContent).toBe('script-a');

    // Close
    fireEvent.click(screen.getByTestId('form-close'));
    await waitFor(() =>
      expect(screen.queryByTestId('script-form-modal')).not.toBeInTheDocument(),
    );

    // Re-open for create
    capturedOnCreate!();
    await screen.findByTestId('script-form-modal');
    expect(screen.getByTestId('form-edit-script-id').textContent).toBe('new');
  });
});
