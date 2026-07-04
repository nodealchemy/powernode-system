import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ModulesTab } from './ModulesTab';

// =============================================================================
// Mocks
//
// ModulesTab orchestrates: systemApi.getModuleCategories + deleteModule +
// deleteModuleCategory, and renders four child modals. We mock all of those
// surfaces so we can verify the orchestration logic in isolation.
// =============================================================================

const mockGetModuleCategories = jest.fn();
const mockDeleteModule = jest.fn();
const mockDeleteModuleCategory = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getModuleCategories: (...args: unknown[]) => mockGetModuleCategories(...args),
    deleteModule: (...args: unknown[]) => mockDeleteModule(...args),
    deleteModuleCategory: (...args: unknown[]) => mockDeleteModuleCategory(...args),
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
// Child component stubs — surface only the props ModulesTab cares about.
// ---------------------------------------------------------------------------

// ModuleList — capture callbacks so tests can trigger them directly.
let capturedOnView: ((m: { id: string; name: string }) => void) | undefined;
let capturedOnEdit: ((m: { id: string; name: string }) => void) | undefined;
let capturedOnDelete: ((id: string) => void) | undefined;
let capturedOnCreate: (() => void) | undefined;
let capturedOnCategoryCreate: (() => void) | undefined;
let capturedOnCategoryEdit: ((c: { id: string; name: string }) => void) | undefined;
let capturedOnCategoryDelete: ((id: string) => void) | undefined;

jest.mock('@system/features/system/components/modules', () => ({
  ModuleList: (props: {
    onView?: (m: { id: string; name: string }) => void;
    onEdit?: (m: { id: string; name: string }) => void;
    onDelete?: (id: string) => void;
    onCreate?: () => void;
    onCategoryCreate?: () => void;
    onCategoryEdit?: (c: { id: string; name: string }) => void;
    onCategoryDelete?: (id: string) => void;
  }) => {
    capturedOnView = props.onView;
    capturedOnEdit = props.onEdit;
    capturedOnDelete = props.onDelete;
    capturedOnCreate = props.onCreate;
    capturedOnCategoryCreate = props.onCategoryCreate;
    capturedOnCategoryEdit = props.onCategoryEdit;
    capturedOnCategoryDelete = props.onCategoryDelete;
    return <div data-testid="module-list">ModuleList</div>;
  },

  ModuleDetailModal: (props: {
    moduleId: string | null;
    isOpen: boolean;
    onClose: () => void;
    onEdit: (m: { id: string; name: string }) => void;
  }) =>
    props.isOpen ? (
      <div data-testid="module-detail-modal">
        <span data-testid="detail-module-id">{props.moduleId}</span>
        <button onClick={props.onClose} data-testid="detail-close">Close</button>
        <button
          onClick={() => props.onEdit({ id: props.moduleId ?? 'x', name: 'Module X' })}
          data-testid="detail-edit"
        >
          Edit from detail
        </button>
      </div>
    ) : null,

  ModuleFormModal: (props: {
    isOpen: boolean;
    onClose: () => void;
    onModuleSaved: () => void;
    editModule: { id: string; name: string } | null;
  }) =>
    props.isOpen ? (
      <div data-testid="module-form-modal">
        <span data-testid="form-edit-module-id">{props.editModule?.id ?? 'new'}</span>
        <button onClick={props.onClose} data-testid="form-close">Close</button>
        <button onClick={props.onModuleSaved} data-testid="form-saved">Save</button>
      </div>
    ) : null,

  ModuleCategoryFormModal: (props: {
    category: { id: string; name: string } | null;
    categories: unknown[];
    isOpen: boolean;
    onClose: () => void;
    onCategorySaved: () => void;
  }) =>
    props.isOpen ? (
      <div data-testid="category-form-modal">
        <span data-testid="cat-form-edit-id">{props.category?.id ?? 'new-cat'}</span>
        <button onClick={props.onClose} data-testid="cat-form-close">Close</button>
        <button onClick={props.onCategorySaved} data-testid="cat-form-saved">Save</button>
      </div>
    ) : null,
}));

// =============================================================================
// Fixtures
// =============================================================================

const CATEGORY_A = {
  id: 'cat-a',
  name: 'Networking',
  depth: 0,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const MODULE_A = {
  id: 'mod-a',
  name: 'nginx-base',
  variety: 'config' as const,
  enabled: true,
  public: true,
  priority: 10,
  mask: [],
  file_spec: [],
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

const renderTab = (onActionsReady?: jest.Mock) =>
  render(
    <BrowserRouter>
      <ModulesTab onActionsReady={onActionsReady} />
    </BrowserRouter>,
  );

// Helper: wait until the delete module dialog heading is visible
const findModuleDeleteHeading = () =>
  screen.findByRole('heading', { name: 'Delete Module' });

// Helper: wait until the delete category dialog heading is visible
const findCategoryDeleteHeading = () =>
  screen.findByRole('heading', { name: 'Delete Category' });

// =============================================================================
// Tests
// =============================================================================

describe('ModulesTab', () => {
  beforeEach(() => {
    mockGetModuleCategories.mockReset();
    mockDeleteModule.mockReset();
    mockDeleteModuleCategory.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);

    // Reset captured callbacks before each test
    capturedOnView = undefined;
    capturedOnEdit = undefined;
    capturedOnDelete = undefined;
    capturedOnCreate = undefined;
    capturedOnCategoryCreate = undefined;
    capturedOnCategoryEdit = undefined;
    capturedOnCategoryDelete = undefined;

    mockGetModuleCategories.mockResolvedValue([CATEGORY_A]);
  });

  // ---------------------------------------------------------------------------
  // Render / mount
  // ---------------------------------------------------------------------------

  it('renders the ModuleList and fetches module categories on mount', async () => {
    renderTab();

    expect(screen.getByTestId('module-list')).toBeInTheDocument();

    await waitFor(() =>
      expect(mockGetModuleCategories).toHaveBeenCalledWith(),
    );
  });

  it('calls onActionsReady with openCreate and openCreateCategory handles on mount', () => {
    const onActionsReady = jest.fn();
    renderTab(onActionsReady);

    expect(onActionsReady).toHaveBeenCalledWith(
      expect.objectContaining({
        openCreate: expect.any(Function),
        openCreateCategory: expect.any(Function),
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
  // Module create / form modal
  // ---------------------------------------------------------------------------

  it('opens ModuleFormModal for create when openCreate handle is called', async () => {
    const onActionsReady = jest.fn();
    renderTab(onActionsReady);

    const handle = onActionsReady.mock.calls[0][0];
    handle.openCreate();

    expect(await screen.findByTestId('module-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-module-id').textContent).toBe('new');
  });

  it('opens ModuleFormModal for create when ModuleList onCreate callback fires', async () => {
    renderTab();

    // capturedOnCreate is set synchronously during render
    expect(capturedOnCreate).toBeDefined();
    capturedOnCreate!();

    expect(await screen.findByTestId('module-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-module-id').textContent).toBe('new');
  });

  it('closes ModuleFormModal when form onClose fires', async () => {
    renderTab();
    expect(capturedOnCreate).toBeDefined();

    capturedOnCreate!();
    await screen.findByTestId('module-form-modal');

    fireEvent.click(screen.getByTestId('form-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('module-form-modal')).not.toBeInTheDocument(),
    );
  });

  it('re-fetches categories (refreshKey increments) after onModuleSaved without closing form', async () => {
    // handleModuleSaved resets editModule + increments refreshKey but does NOT close the form
    // (the modal owns its own close behavior via onClose).
    renderTab();
    expect(capturedOnCreate).toBeDefined();
    capturedOnCreate!();
    await screen.findByTestId('module-form-modal');

    fireEvent.click(screen.getByTestId('form-saved'));

    // The form stays open (the component never calls setShowFormModal(false) on save)
    await waitFor(() =>
      expect(screen.getByTestId('module-form-modal')).toBeInTheDocument(),
    );
    // refreshKey increment causes categories to re-fetch
    await waitFor(() => expect(mockGetModuleCategories).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Module edit (from list and from detail)
  // ---------------------------------------------------------------------------

  it('opens ModuleFormModal in edit mode when ModuleList onEdit fires', async () => {
    renderTab();
    expect(capturedOnEdit).toBeDefined();

    capturedOnEdit!(MODULE_A);

    expect(await screen.findByTestId('module-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('form-edit-module-id').textContent).toBe('mod-a');
  });

  it('opens ModuleDetailModal when ModuleList onView fires', async () => {
    renderTab();
    expect(capturedOnView).toBeDefined();

    capturedOnView!(MODULE_A);

    const modal = await screen.findByTestId('module-detail-modal');
    expect(modal).toBeInTheDocument();
    expect(screen.getByTestId('detail-module-id').textContent).toBe('mod-a');
  });

  it('closes ModuleDetailModal when its onClose fires', async () => {
    renderTab();
    expect(capturedOnView).toBeDefined();
    capturedOnView!(MODULE_A);
    await screen.findByTestId('module-detail-modal');

    fireEvent.click(screen.getByTestId('detail-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('module-detail-modal')).not.toBeInTheDocument(),
    );
  });

  it('transitions from detail to edit form when onEdit fires inside ModuleDetailModal', async () => {
    renderTab();
    expect(capturedOnView).toBeDefined();
    capturedOnView!(MODULE_A);
    await screen.findByTestId('module-detail-modal');

    fireEvent.click(screen.getByTestId('detail-edit'));

    await waitFor(() =>
      expect(screen.queryByTestId('module-detail-modal')).not.toBeInTheDocument(),
    );
    expect(await screen.findByTestId('module-form-modal')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Module delete — confirm dialog + API call
  // ---------------------------------------------------------------------------

  it('shows module delete confirmation dialog when onDelete fires (with canDelete=true)', async () => {
    renderTab();
    expect(capturedOnDelete).toBeDefined();

    capturedOnDelete!('mod-a');

    await findModuleDeleteHeading();
    expect(
      screen.getByText(/Are you sure you want to delete this module/i),
    ).toBeInTheDocument();
  });

  it('does not pass onDelete to ModuleList when system.modules.delete permission is denied', () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.modules.delete');
    renderTab();
    expect(capturedOnDelete).toBeUndefined();
  });

  it('calls systemApi.deleteModule and shows success notification after confirming delete', async () => {
    mockDeleteModule.mockResolvedValue(undefined);
    renderTab();
    expect(capturedOnDelete).toBeDefined();

    capturedOnDelete!('mod-a');
    await findModuleDeleteHeading();

    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() =>
      expect(mockDeleteModule).toHaveBeenCalledWith('mod-a'),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Module deleted successfully',
      }),
    );
    // Dialog should close after success
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Module' })).not.toBeInTheDocument(),
    );
  });

  it('shows error notification when deleteModule rejects with an Error', async () => {
    mockDeleteModule.mockRejectedValue(new Error('Network error'));
    renderTab();
    expect(capturedOnDelete).toBeDefined();

    capturedOnDelete!('mod-a');
    await findModuleDeleteHeading();

    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete module: Network error',
      }),
    );
  });

  it('shows "An error occurred" for non-Error rejection when deleting module', async () => {
    mockDeleteModule.mockRejectedValue('unknown failure');
    renderTab();
    expect(capturedOnDelete).toBeDefined();

    capturedOnDelete!('mod-a');
    await findModuleDeleteHeading();

    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete module: An error occurred',
      }),
    );
  });

  it('dismisses module delete dialog without API call when Cancel is clicked', async () => {
    renderTab();
    expect(capturedOnDelete).toBeDefined();

    capturedOnDelete!('mod-a');
    await findModuleDeleteHeading();

    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Module' })).not.toBeInTheDocument(),
    );
    expect(mockDeleteModule).not.toHaveBeenCalled();
  });

  it('shows "Deleting..." label while deleteModule is in-flight', async () => {
    let resolve!: () => void;
    mockDeleteModule.mockImplementation(
      () => new Promise<void>((res) => { resolve = res; }),
    );
    renderTab();
    expect(capturedOnDelete).toBeDefined();

    capturedOnDelete!('mod-a');
    await findModuleDeleteHeading();

    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /processing\.\.\./i })).toBeDisabled(),
    );

    resolve();
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Module' })).not.toBeInTheDocument(),
    );
  });

  it('increments refreshKey after a successful module delete (re-fetches categories)', async () => {
    mockDeleteModule.mockResolvedValue(undefined);
    renderTab();
    expect(capturedOnDelete).toBeDefined();

    capturedOnDelete!('mod-a');
    await findModuleDeleteHeading();
    fireEvent.click(screen.getByRole('button', { name: /delete module/i }));

    await waitFor(() => expect(mockDeleteModule).toHaveBeenCalled());
    await waitFor(() => expect(mockGetModuleCategories).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Category create modal
  // ---------------------------------------------------------------------------

  it('opens ModuleCategoryFormModal for create when openCreateCategory handle is called', async () => {
    const onActionsReady = jest.fn();
    renderTab(onActionsReady);

    const handle = onActionsReady.mock.calls[0][0];
    handle.openCreateCategory();

    expect(await screen.findByTestId('category-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('cat-form-edit-id').textContent).toBe('new-cat');
  });

  it('opens ModuleCategoryFormModal when ModuleList onCategoryCreate fires', async () => {
    renderTab();
    expect(capturedOnCategoryCreate).toBeDefined();

    capturedOnCategoryCreate!();

    expect(await screen.findByTestId('category-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('cat-form-edit-id').textContent).toBe('new-cat');
  });

  it('closes ModuleCategoryFormModal when onClose fires', async () => {
    renderTab();
    expect(capturedOnCategoryCreate).toBeDefined();

    capturedOnCategoryCreate!();
    await screen.findByTestId('category-form-modal');

    fireEvent.click(screen.getByTestId('cat-form-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('category-form-modal')).not.toBeInTheDocument(),
    );
  });

  it('re-fetches categories after onCategorySaved (form stays open; modal owns close)', async () => {
    // handleCategorySaved increments refreshKey + clears editCategory but does NOT
    // call setShowCategoryFormModal(false) — symmetrical with handleModuleSaved.
    renderTab();
    expect(capturedOnCategoryCreate).toBeDefined();

    capturedOnCategoryCreate!();
    await screen.findByTestId('category-form-modal');
    fireEvent.click(screen.getByTestId('cat-form-saved'));

    // form stays open
    await waitFor(() =>
      expect(screen.getByTestId('category-form-modal')).toBeInTheDocument(),
    );
    // refreshKey increment re-fetches categories
    await waitFor(() => expect(mockGetModuleCategories).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Category edit
  // ---------------------------------------------------------------------------

  it('opens ModuleCategoryFormModal in edit mode when ModuleList onCategoryEdit fires', async () => {
    renderTab();
    expect(capturedOnCategoryEdit).toBeDefined();

    capturedOnCategoryEdit!(CATEGORY_A);

    expect(await screen.findByTestId('category-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('cat-form-edit-id').textContent).toBe('cat-a');
  });

  // ---------------------------------------------------------------------------
  // Category delete — confirm dialog + API call
  // ---------------------------------------------------------------------------

  it('shows category delete confirmation dialog when onCategoryDelete fires', async () => {
    renderTab();
    expect(capturedOnCategoryDelete).toBeDefined();

    capturedOnCategoryDelete!('cat-a');

    await findCategoryDeleteHeading();
    expect(
      screen.getByText(/Are you sure you want to delete this category/i),
    ).toBeInTheDocument();
  });

  it('calls systemApi.deleteModuleCategory and shows success notification after confirming', async () => {
    mockDeleteModuleCategory.mockResolvedValue(undefined);
    renderTab();
    expect(capturedOnCategoryDelete).toBeDefined();

    capturedOnCategoryDelete!('cat-a');
    await findCategoryDeleteHeading();

    fireEvent.click(screen.getByRole('button', { name: /delete category/i }));

    await waitFor(() =>
      expect(mockDeleteModuleCategory).toHaveBeenCalledWith('cat-a'),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Category deleted successfully',
      }),
    );
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Category' })).not.toBeInTheDocument(),
    );
  });

  it('shows error notification when deleteModuleCategory rejects with an Error', async () => {
    mockDeleteModuleCategory.mockRejectedValue(new Error('Server error'));
    renderTab();
    expect(capturedOnCategoryDelete).toBeDefined();

    capturedOnCategoryDelete!('cat-a');
    await findCategoryDeleteHeading();

    fireEvent.click(screen.getByRole('button', { name: /delete category/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete category: Server error',
      }),
    );
  });

  it('shows "An error occurred" for non-Error rejection when deleting category', async () => {
    mockDeleteModuleCategory.mockRejectedValue('oops');
    renderTab();
    expect(capturedOnCategoryDelete).toBeDefined();

    capturedOnCategoryDelete!('cat-a');
    await findCategoryDeleteHeading();

    fireEvent.click(screen.getByRole('button', { name: /delete category/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete category: An error occurred',
      }),
    );
  });

  it('dismisses category delete dialog without API call when Cancel is clicked', async () => {
    renderTab();
    expect(capturedOnCategoryDelete).toBeDefined();

    capturedOnCategoryDelete!('cat-a');
    await findCategoryDeleteHeading();

    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Category' })).not.toBeInTheDocument(),
    );
    expect(mockDeleteModuleCategory).not.toHaveBeenCalled();
  });

  it('shows "Deleting..." label while deleteModuleCategory is in-flight', async () => {
    let resolve!: () => void;
    mockDeleteModuleCategory.mockImplementation(
      () => new Promise<void>((res) => { resolve = res; }),
    );
    renderTab();
    expect(capturedOnCategoryDelete).toBeDefined();

    capturedOnCategoryDelete!('cat-a');
    await findCategoryDeleteHeading();

    fireEvent.click(screen.getByRole('button', { name: /delete category/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /processing\.\.\./i })).toBeDisabled(),
    );

    resolve();
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Category' })).not.toBeInTheDocument(),
    );
  });

  it('increments refreshKey after a successful category delete (re-fetches categories)', async () => {
    mockDeleteModuleCategory.mockResolvedValue(undefined);
    renderTab();
    expect(capturedOnCategoryDelete).toBeDefined();

    capturedOnCategoryDelete!('cat-a');
    await findCategoryDeleteHeading();
    fireEvent.click(screen.getByRole('button', { name: /delete category/i }));

    await waitFor(() => expect(mockDeleteModuleCategory).toHaveBeenCalled());
    await waitFor(() => expect(mockGetModuleCategories).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  it('passes undefined onDelete to ModuleList when system.modules.delete is denied', () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.modules.delete');
    renderTab();
    expect(capturedOnDelete).toBeUndefined();
  });

  it('passes undefined onCreate and onCategoryCreate to ModuleList when system.modules.create is denied', () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.modules.create');
    renderTab();
    expect(capturedOnCreate).toBeUndefined();
    expect(capturedOnCategoryCreate).toBeUndefined();
  });

  // ---------------------------------------------------------------------------
  // Overlay click dismisses delete dialogs
  // ---------------------------------------------------------------------------

  it('dismisses module delete dialog when the backdrop overlay is clicked', async () => {
    renderTab();
    expect(capturedOnDelete).toBeDefined();

    capturedOnDelete!('mod-a');
    await findModuleDeleteHeading();

    // The shared Modal's outer positioning div closes on a direct click
    // (event.target === event.currentTarget), same as clicking the backdrop.
    const overlay = screen.getByRole('dialog').firstElementChild as HTMLElement;
    fireEvent.click(overlay);

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Module' })).not.toBeInTheDocument(),
    );
    expect(mockDeleteModule).not.toHaveBeenCalled();
  });

  it('dismisses category delete dialog when the backdrop overlay is clicked', async () => {
    renderTab();
    expect(capturedOnCategoryDelete).toBeDefined();

    capturedOnCategoryDelete!('cat-a');
    await findCategoryDeleteHeading();

    const overlay = screen.getByRole('dialog').firstElementChild as HTMLElement;
    fireEvent.click(overlay);

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Category' })).not.toBeInTheDocument(),
    );
    expect(mockDeleteModuleCategory).not.toHaveBeenCalled();
  });
});
