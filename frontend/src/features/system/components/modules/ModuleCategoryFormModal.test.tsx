import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ModuleCategoryFormModal } from './ModuleCategoryFormModal';
import type { SystemNodeModuleCategory } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();
const mockPut = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: jest.fn(),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
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

// systemApi facade — mock only the two category methods the component calls.
const mockCreateModuleCategory = jest.fn();
const mockUpdateModuleCategory = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    createModuleCategory: (...args: unknown[]) => mockCreateModuleCategory(...args),
    updateModuleCategory: (...args: unknown[]) => mockUpdateModuleCategory(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

function makeCategory(overrides: Partial<SystemNodeModuleCategory> = {}): SystemNodeModuleCategory {
  return {
    id: 'cat-1',
    name: 'Networking',
    description: 'Network modules',
    parent_id: undefined,
    parent_name: undefined,
    depth: 0,
    children_count: 2,
    module_count: 5,
    created_at: '2026-01-01T10:00:00Z',
    updated_at: '2026-01-15T12:00:00Z',
    ...overrides,
  };
}

const PARENT_CAT = makeCategory({ id: 'parent-1', name: 'Infrastructure', depth: 0 });
const CHILD_CAT = makeCategory({ id: 'child-1', name: 'SDN', depth: 1, parent_id: 'parent-1' });
const EDIT_CAT = makeCategory({ id: 'cat-edit', name: 'Security', description: 'Security tools', depth: 0 });

const ALL_CATS = [PARENT_CAT, CHILD_CAT, EDIT_CAT];

/** Wraps the returned category in the double-envelope the facade resolves to */
function resolveCategory(cat: SystemNodeModuleCategory): SystemNodeModuleCategory {
  return cat;
}

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  category?: SystemNodeModuleCategory | null;
  categories?: SystemNodeModuleCategory[];
  isOpen?: boolean;
  onClose?: () => void;
  onCategorySaved?: (cat: SystemNodeModuleCategory) => void;
}

function renderModal({
  category = null,
  categories = ALL_CATS,
  isOpen = true,
  onClose = jest.fn(),
  onCategorySaved = jest.fn(),
}: RenderProps = {}) {
  const closeFn = onClose;
  const savedFn = onCategorySaved;

  render(
    <BrowserRouter>
      <ModuleCategoryFormModal
        category={category}
        categories={categories}
        isOpen={isOpen}
        onClose={closeFn}
        onCategorySaved={savedFn}
      />
    </BrowserRouter>,
  );

  return { closeFn, savedFn };
}

// =============================================================================
// Tests
// =============================================================================

describe('ModuleCategoryFormModal', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockPut.mockReset();
    mockAddNotification.mockReset();
    mockCreateModuleCategory.mockReset();
    mockUpdateModuleCategory.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render / open state
  // ---------------------------------------------------------------------------

  describe('Create mode rendering', () => {
    it('renders the create title and subtitle when no category is passed', () => {
      renderModal({ category: null });

      // The title "Create Category" appears both in the modal header and on the
      // submit button — use getAllByText and assert at least one match.
      expect(screen.getAllByText('Create Category').length).toBeGreaterThan(0);
      expect(screen.getByText('Add a new module category')).toBeInTheDocument();
    });

    it('renders the Name, Description, and Parent Category fields', () => {
      renderModal();

      expect(screen.getByLabelText(/name/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/description/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/parent category/i)).toBeInTheDocument();
    });

    it('shows "Create Category" on the submit button in create mode', () => {
      renderModal();
      expect(screen.getByRole('button', { name: /create category/i })).toBeInTheDocument();
    });

    it('name field starts empty in create mode', () => {
      renderModal();
      const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
      expect(nameInput.value).toBe('');
    });

    it('does not show metadata section in create mode', () => {
      renderModal({ category: null });
      expect(screen.queryByText(/modules:/i)).not.toBeInTheDocument();
    });
  });

  describe('Edit mode rendering', () => {
    it('renders the edit title and subtitle when a category is passed', () => {
      renderModal({ category: EDIT_CAT });

      expect(screen.getByText('Edit Category')).toBeInTheDocument();
      expect(screen.getByText(`Editing: ${EDIT_CAT.name}`)).toBeInTheDocument();
    });

    it('shows "Save Changes" on the submit button in edit mode', () => {
      renderModal({ category: EDIT_CAT });
      expect(screen.getByRole('button', { name: /save changes/i })).toBeInTheDocument();
    });

    it('pre-populates the name field with the category name', () => {
      renderModal({ category: EDIT_CAT });
      const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
      expect(nameInput.value).toBe(EDIT_CAT.name);
    });

    it('pre-populates the description field', () => {
      renderModal({ category: EDIT_CAT });
      const descArea = screen.getByLabelText(/description/i) as HTMLTextAreaElement;
      expect(descArea.value).toBe(EDIT_CAT.description);
    });

    it('displays metadata (module count, subcategories, dates) in edit mode', () => {
      renderModal({ category: EDIT_CAT });

      expect(screen.getByText(/modules:/i)).toBeInTheDocument();
      expect(screen.getByText(/subcategories:/i)).toBeInTheDocument();
      expect(screen.getByText(/created:/i)).toBeInTheDocument();
      expect(screen.getByText(/updated:/i)).toBeInTheDocument();
    });
  });

  describe('Closed state', () => {
    it('renders nothing visible when isOpen=false', () => {
      renderModal({ isOpen: false });
      // The modal title should not appear at all when closed
      expect(screen.queryByText('Create Category')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Parent category select
  // ---------------------------------------------------------------------------

  describe('Parent category select', () => {
    it('lists all categories as parent options in create mode', () => {
      renderModal({ category: null, categories: ALL_CATS });

      const select = screen.getByLabelText(/parent category/i) as HTMLSelectElement;
      // Includes the "No parent" default + all categories
      const options = Array.from(select.options).map(o => o.text);
      expect(options).toContain('No parent (Top level)');
      expect(options).toContain('Infrastructure');
      expect(options.some(t => t.includes('SDN'))).toBe(true);
    });

    it('excludes self from parent options in edit mode', () => {
      renderModal({ category: EDIT_CAT, categories: ALL_CATS });

      const select = screen.getByLabelText(/parent category/i) as HTMLSelectElement;
      const optionValues = Array.from(select.options).map(o => o.value);
      expect(optionValues).not.toContain(EDIT_CAT.id);
    });

    it('excludes direct children from parent options in edit mode', () => {
      const parentCat = makeCategory({ id: 'par-1', name: 'Parent', depth: 0 });
      const directChild = makeCategory({ id: 'ch-1', name: 'ChildOfParent', depth: 1, parent_id: 'par-1' });
      // editing parentCat: directChild should be excluded since its parent_id === parentCat.id
      renderModal({ category: parentCat, categories: [parentCat, directChild] });

      const select = screen.getByLabelText(/parent category/i) as HTMLSelectElement;
      const optionValues = Array.from(select.options).map(o => o.value);
      expect(optionValues).not.toContain(directChild.id);
    });

    it('shows depth indentation prefix in select options', () => {
      renderModal({ category: null, categories: [PARENT_CAT, CHILD_CAT] });

      const select = screen.getByLabelText(/parent category/i) as HTMLSelectElement;
      const childOption = Array.from(select.options).find(o => o.value === CHILD_CAT.id);
      // CHILD_CAT has depth: 1 so its text should start with '— '
      expect(childOption?.text).toMatch(/^—\s/);
    });
  });

  // ---------------------------------------------------------------------------
  // Preview section
  // ---------------------------------------------------------------------------

  describe('Preview', () => {
    it('shows the preview section when a name is typed', () => {
      renderModal();

      expect(screen.queryByText('Preview:')).not.toBeInTheDocument();

      fireEvent.change(screen.getByLabelText(/name/i), {
        target: { value: 'MyCategory' },
      });

      expect(screen.getByText('Preview:')).toBeInTheDocument();
      expect(screen.getByText('MyCategory')).toBeInTheDocument();
    });

    it('does not show the preview section when name is empty', () => {
      renderModal();
      expect(screen.queryByText('Preview:')).not.toBeInTheDocument();
    });

    it('shows parent name slash-separated in preview when a parent is selected', async () => {
      renderModal({ category: null, categories: [PARENT_CAT] });

      fireEvent.change(screen.getByLabelText(/name/i), {
        target: { value: 'Sub' },
      });

      // select the parent
      fireEvent.change(screen.getByLabelText(/parent category/i), {
        target: { value: PARENT_CAT.id },
      });

      await waitFor(() => {
        expect(screen.getByText(`${PARENT_CAT.name} /`).textContent).toContain(PARENT_CAT.name);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  describe('Validation', () => {
    it('shows "Name is required" when submitting with an empty name', async () => {
      renderModal();

      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() => {
        expect(screen.getByText('Name is required')).toBeInTheDocument();
      });
      expect(mockCreateModuleCategory).not.toHaveBeenCalled();
    });

    it('shows "Name must be at least 2 characters" for single-character name', async () => {
      renderModal();

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'A' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() => {
        expect(screen.getByText('Name must be at least 2 characters')).toBeInTheDocument();
      });
      expect(mockCreateModuleCategory).not.toHaveBeenCalled();
    });

    it('shows "Name must be less than 100 characters" for long names', async () => {
      renderModal();

      const longName = 'A'.repeat(101);
      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: longName } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() => {
        expect(screen.getByText('Name must be less than 100 characters')).toBeInTheDocument();
      });
      expect(mockCreateModuleCategory).not.toHaveBeenCalled();
    });

    it('clears the name error when user types a valid name after validation failure', async () => {
      renderModal();

      fireEvent.click(screen.getByRole('button', { name: /create category/i }));
      await waitFor(() => expect(screen.getByText('Name is required')).toBeInTheDocument());

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'ValidName' } });
      expect(screen.queryByText('Name is required')).not.toBeInTheDocument();
    });

    it('accepts a name with exactly 2 characters (boundary)', async () => {
      const savedCat = makeCategory({ name: 'OK' });
      mockCreateModuleCategory.mockResolvedValue(resolveCategory(savedCat));

      renderModal();

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'OK' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() => expect(mockCreateModuleCategory).toHaveBeenCalled());
      expect(screen.queryByText(/name must be at least/i)).not.toBeInTheDocument();
    });

    it('accepts a name with exactly 100 characters (boundary)', async () => {
      const name100 = 'B'.repeat(100);
      const savedCat = makeCategory({ name: name100 });
      mockCreateModuleCategory.mockResolvedValue(resolveCategory(savedCat));

      renderModal();

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: name100 } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() => expect(mockCreateModuleCategory).toHaveBeenCalled());
      expect(screen.queryByText(/name must be less than/i)).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Create flow
  // ---------------------------------------------------------------------------

  describe('Create flow', () => {
    it('calls systemApi.createModuleCategory with correct payload on submit', async () => {
      const newCat = makeCategory({ id: 'new-1', name: 'Storage' });
      mockCreateModuleCategory.mockResolvedValue(resolveCategory(newCat));

      renderModal({ category: null, categories: [PARENT_CAT] });

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: '  Storage  ' } });
      fireEvent.change(screen.getByLabelText(/description/i), {
        target: { value: 'Disk and block storage' },
      });
      fireEvent.change(screen.getByLabelText(/parent category/i), {
        target: { value: PARENT_CAT.id },
      });

      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() => {
        expect(mockCreateModuleCategory).toHaveBeenCalledWith({
          name: 'Storage', // trimmed
          description: 'Disk and block storage',
          parent_id: PARENT_CAT.id,
          enabled: true,
        });
      });
    });

    it('trims whitespace from name before sending', async () => {
      const newCat = makeCategory({ name: 'Trimmed' });
      mockCreateModuleCategory.mockResolvedValue(resolveCategory(newCat));

      renderModal();

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: '  Trimmed  ' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() =>
        expect(mockCreateModuleCategory).toHaveBeenCalledWith(
          expect.objectContaining({ name: 'Trimmed' }),
        ),
      );
    });

    it('sends parent_id as undefined when no parent is selected', async () => {
      const newCat = makeCategory({ name: 'TopLevel' });
      mockCreateModuleCategory.mockResolvedValue(resolveCategory(newCat));

      renderModal();

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'TopLevel' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() =>
        expect(mockCreateModuleCategory).toHaveBeenCalledWith(
          expect.objectContaining({ parent_id: undefined }),
        ),
      );
    });

    it('sends description as undefined when left empty', async () => {
      const newCat = makeCategory({ name: 'NoDesc' });
      mockCreateModuleCategory.mockResolvedValue(resolveCategory(newCat));

      renderModal();

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'NoDesc' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() =>
        expect(mockCreateModuleCategory).toHaveBeenCalledWith(
          expect.objectContaining({ description: undefined }),
        ),
      );
    });

    it('shows a success notification after creation', async () => {
      const newCat = makeCategory({ name: 'Compute' });
      mockCreateModuleCategory.mockResolvedValue(resolveCategory(newCat));

      renderModal();

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'Compute' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Category "Compute" created successfully`,
        }),
      );
    });

    it('calls onCategorySaved with the created category', async () => {
      const newCat = makeCategory({ id: 'saved-1', name: 'Events' });
      mockCreateModuleCategory.mockResolvedValue(resolveCategory(newCat));
      const onCategorySaved = jest.fn();

      renderModal({ onCategorySaved });

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'Events' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() =>
        expect(onCategorySaved).toHaveBeenCalledWith(expect.objectContaining({ id: 'saved-1' })),
      );
    });

    it('calls onClose after successful creation', async () => {
      const newCat = makeCategory({ name: 'Logs' });
      mockCreateModuleCategory.mockResolvedValue(resolveCategory(newCat));
      const onClose = jest.fn();

      renderModal({ onClose });

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'Logs' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() => expect(onClose).toHaveBeenCalled());
    });
  });

  // ---------------------------------------------------------------------------
  // Edit flow
  // ---------------------------------------------------------------------------

  describe('Edit flow', () => {
    it('calls systemApi.updateModuleCategory with correct id and payload on submit', async () => {
      const updatedCat = makeCategory({ ...EDIT_CAT, name: 'Security Revised' });
      mockUpdateModuleCategory.mockResolvedValue(resolveCategory(updatedCat));

      renderModal({ category: EDIT_CAT });

      // Clear and retype name
      const nameInput = screen.getByLabelText(/name/i);
      fireEvent.change(nameInput, { target: { value: 'Security Revised' } });

      fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

      await waitFor(() => {
        expect(mockUpdateModuleCategory).toHaveBeenCalledWith(
          EDIT_CAT.id,
          expect.objectContaining({ name: 'Security Revised' }),
        );
      });
      expect(mockCreateModuleCategory).not.toHaveBeenCalled();
    });

    it('shows a success notification after update', async () => {
      const updatedCat = makeCategory({ ...EDIT_CAT, name: 'Security Revised' });
      mockUpdateModuleCategory.mockResolvedValue(resolveCategory(updatedCat));

      renderModal({ category: EDIT_CAT });

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'Security Revised' } });
      fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Category "Security Revised" updated successfully`,
        }),
      );
    });

    it('calls onCategorySaved with the updated category', async () => {
      const updatedCat = makeCategory({ ...EDIT_CAT, name: 'Updated' });
      mockUpdateModuleCategory.mockResolvedValue(resolveCategory(updatedCat));
      const onCategorySaved = jest.fn();

      renderModal({ category: EDIT_CAT, onCategorySaved });

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'Updated' } });
      fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

      await waitFor(() =>
        expect(onCategorySaved).toHaveBeenCalledWith(expect.objectContaining({ id: EDIT_CAT.id })),
      );
    });

    it('calls onClose after successful update', async () => {
      const updatedCat = makeCategory({ ...EDIT_CAT });
      mockUpdateModuleCategory.mockResolvedValue(resolveCategory(updatedCat));
      const onClose = jest.fn();

      renderModal({ category: EDIT_CAT, onClose });

      fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

      await waitFor(() => expect(onClose).toHaveBeenCalled());
    });

    it('pre-selects the parent category if the category has a parent_id', () => {
      const catWithParent = makeCategory({
        id: 'cat-child',
        name: 'Child',
        parent_id: PARENT_CAT.id,
        depth: 1,
      });

      renderModal({ category: catWithParent, categories: [PARENT_CAT, catWithParent] });

      const select = screen.getByLabelText(/parent category/i) as HTMLSelectElement;
      expect(select.value).toBe(PARENT_CAT.id);
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  describe('Error handling', () => {
    it('shows an error notification when createModuleCategory rejects with Error', async () => {
      mockCreateModuleCategory.mockRejectedValue(new Error('Server error'));

      renderModal();

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'Failing' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Server error',
        }),
      );
    });

    it('shows a generic error message when createModuleCategory rejects without Error instance', async () => {
      mockCreateModuleCategory.mockRejectedValue('oops');

      renderModal();

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'Bad' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to create category',
        }),
      );
    });

    it('shows a generic error message when updateModuleCategory rejects without Error instance', async () => {
      mockUpdateModuleCategory.mockRejectedValue('db fail');

      renderModal({ category: EDIT_CAT });

      fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to update category',
        }),
      );
    });

    it('does not call onCategorySaved on API error', async () => {
      mockCreateModuleCategory.mockRejectedValue(new Error('fail'));
      const onCategorySaved = jest.fn();

      renderModal({ onCategorySaved });

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'TestCat' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(expect.objectContaining({ type: 'error' })),
      );

      expect(onCategorySaved).not.toHaveBeenCalled();
    });

    it('does not call onClose on API error', async () => {
      mockCreateModuleCategory.mockRejectedValue(new Error('fail'));
      const onClose = jest.fn();

      renderModal({ onClose });

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'TestCat' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(expect.objectContaining({ type: 'error' })),
      );

      expect(onClose).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Submitting state (button labels)
  // ---------------------------------------------------------------------------

  describe('Submitting state', () => {
    it('shows "Saving..." on the submit button while the request is in-flight', async () => {
      let resolve!: (value: SystemNodeModuleCategory) => void;
      const pending = new Promise<SystemNodeModuleCategory>(r => {
        resolve = r;
      });
      mockCreateModuleCategory.mockReturnValue(pending);

      renderModal();

      fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'InFlight' } });
      fireEvent.click(screen.getByRole('button', { name: /create category/i }));

      await waitFor(() => expect(screen.getByText('Saving...')).toBeInTheDocument());

      // Resolve to clean up
      resolve(makeCategory({ name: 'InFlight' }));
      await waitFor(() => expect(screen.queryByText('Saving...')).not.toBeInTheDocument());
    });
  });

  // ---------------------------------------------------------------------------
  // Cancel / close
  // ---------------------------------------------------------------------------

  describe('Cancel button', () => {
    it('calls onClose when the Cancel button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });

      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(onClose).toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Form reset on re-open
  // ---------------------------------------------------------------------------

  describe('Form reset', () => {
    it('resets form to empty state when modal is opened in create mode after edit mode', () => {
      const { rerender } = render(
        <BrowserRouter>
          <ModuleCategoryFormModal
            category={EDIT_CAT}
            categories={ALL_CATS}
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      // Verify edit mode shows the category's name
      expect((screen.getByLabelText(/name/i) as HTMLInputElement).value).toBe(EDIT_CAT.name);

      // Switch to create mode
      rerender(
        <BrowserRouter>
          <ModuleCategoryFormModal
            category={null}
            categories={ALL_CATS}
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      expect((screen.getByLabelText(/name/i) as HTMLInputElement).value).toBe('');
    });
  });
});
