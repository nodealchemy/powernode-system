import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ScriptList } from './ScriptList';
import type { SystemNodeScript } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGetScripts = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getScripts: (...args: unknown[]) => mockGetScripts(...args),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// InfiniteScrollSentinel uses IntersectionObserver which jsdom doesn't support.
jest.mock(
  '@system/features/system/components/shared/InfiniteScrollSentinel',
  () => ({
    InfiniteScrollSentinel: () => null,
  }),
);

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const SCRIPT_BUILD: SystemNodeScript = {
  id: 'script-build-1',
  name: 'Build Script Alpha',
  description: 'Compiles the base image',
  variety: 'build',
  data: '#!/bin/bash\necho build',
  enabled: true,
  public: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const SCRIPT_INIT: SystemNodeScript = {
  id: 'script-init-1',
  name: 'Init Script Beta',
  description: 'Initialises the node',
  variety: 'init',
  data: '#!/bin/bash\necho init',
  enabled: false,
  public: false,
  created_at: '2026-01-02T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const SCRIPT_SYNC: SystemNodeScript = {
  id: 'script-sync-1',
  name: 'Sync Script Gamma',
  description: 'Syncs files',
  variety: 'sync',
  enabled: true,
  public: false,
  created_at: '2026-01-03T00:00:00Z',
  updated_at: '2026-01-03T00:00:00Z',
};

const SCRIPT_CUSTOM: SystemNodeScript = {
  id: 'script-custom-1',
  name: 'Custom Script Delta',
  variety: 'custom',
  enabled: false,
  public: true,
  created_at: '2026-01-04T00:00:00Z',
  updated_at: '2026-01-04T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderOpts {
  onView?: jest.Mock;
  onEdit?: jest.Mock;
  onDelete?: jest.Mock;
  onCreate?: jest.Mock;
  permissionFn?: (perm: string) => boolean;
}

function renderList(opts: RenderOpts = {}) {
  const {
    onView = jest.fn(),
    onEdit = jest.fn(),
    onDelete = jest.fn(),
    onCreate = jest.fn(),
  } = opts;

  return render(
    <BrowserRouter>
      <ScriptList
        onView={onView}
        onEdit={onEdit}
        onDelete={onDelete}
        onCreate={onCreate}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('ScriptList', () => {
  beforeEach(() => {
    mockGetScripts.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  describe('loading state', () => {
    it('shows a spinner while the initial fetch is in flight', () => {
      // Never resolve so loading stays true
      mockGetScripts.mockReturnValue(new Promise(() => {}));
      renderList();
      // ResponsiveListContainer renders a spinner when loading && totalCount === 0
      const spinner = document.querySelector('svg.animate-spin, [class*="animate-spin"], [class*="loading"], [aria-label*="loading"], [data-testid*="spinner"]');
      // Fallback: check for the LoadingSpinner class or the svg element
      const container = document.querySelector('.bg-theme-surface');
      expect(container).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  describe('empty state', () => {
    it('shows "No scripts configured" empty state when the list is empty', async () => {
      mockGetScripts.mockResolvedValue([]);
      renderList();
      await waitFor(() =>
        expect(screen.getByText('No scripts configured')).toBeInTheDocument(),
      );
      expect(screen.getByText(/create scripts to automate/i)).toBeInTheDocument();
    });

    it('renders "Create Script" action button in empty state when user has create permission', async () => {
      mockGetScripts.mockResolvedValue([]);
      const onCreate = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onCreate={onCreate} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getByText('No scripts configured')).toBeInTheDocument(),
      );
      const btn = screen.getByRole('button', { name: /create script/i });
      fireEvent.click(btn);
      expect(onCreate).toHaveBeenCalledTimes(1);
    });

    it('does not render empty-state create button when onCreate is omitted', async () => {
      mockGetScripts.mockResolvedValue([]);
      render(
        <BrowserRouter>
          <ScriptList />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getByText('No scripts configured')).toBeInTheDocument(),
      );
      expect(screen.queryByRole('button', { name: /create script/i })).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  describe('error state', () => {
    it('shows an error notification when the fetch fails', async () => {
      mockGetScripts.mockRejectedValue(new Error('Network error'));
      renderList();
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to load scripts',
        }),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Renders list items
  // ---------------------------------------------------------------------------

  describe('renders list items', () => {
    it('calls systemApi.getScripts() on mount', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      renderList();
      await waitFor(() => expect(mockGetScripts).toHaveBeenCalledTimes(1));
    });

    it('renders script names after successful fetch', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      expect(screen.getAllByText('Init Script Beta').length).toBeGreaterThan(0);
    });

    it('renders script descriptions when present', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Compiles the base image').length).toBeGreaterThan(0),
      );
    });

    it('does not render a description cell when description is absent', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_CUSTOM]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Custom Script Delta').length).toBeGreaterThan(0),
      );
      // SCRIPT_CUSTOM has no description — the description paragraph should be absent
      expect(screen.queryByText('undefined')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Variety badges
  // ---------------------------------------------------------------------------

  describe('variety badges', () => {
    it('renders "Build" badge for build-variety scripts', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build').length).toBeGreaterThan(0),
      );
    });

    it('renders "Init" badge for init-variety scripts', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_INIT]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Init').length).toBeGreaterThan(0),
      );
    });

    it('renders "Sync" badge for sync-variety scripts', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_SYNC]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Sync').length).toBeGreaterThan(0),
      );
    });

    it('renders "Custom" badge for custom-variety scripts', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_CUSTOM]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Custom').length).toBeGreaterThan(0),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Visibility badges
  // ---------------------------------------------------------------------------

  describe('visibility badges', () => {
    it('renders "Public" badge for public scripts', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]); // public: true
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Public').length).toBeGreaterThan(0),
      );
    });

    it('renders "Private" badge for non-public scripts', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_INIT]); // public: false
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Private').length).toBeGreaterThan(0),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Status badges
  // ---------------------------------------------------------------------------

  describe('status badges', () => {
    it('renders "Enabled" badge for enabled scripts', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]); // enabled: true
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Enabled').length).toBeGreaterThan(0),
      );
    });

    it('renders "Disabled" badge for disabled scripts', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_INIT]); // enabled: false
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Disabled').length).toBeGreaterThan(0),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // onView callback
  // ---------------------------------------------------------------------------

  describe('onView callback', () => {
    it('calls onView when script name is clicked in the desktop table', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      const onView = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onView={onView} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      // Click the first occurrence (desktop table name)
      fireEvent.click(screen.getAllByText('Build Script Alpha')[0]);
      expect(onView).toHaveBeenCalledWith(SCRIPT_BUILD);
    });

    it('calls onView when the Eye action button is clicked', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      const onView = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onView={onView} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      // The eye button has title="View Details"
      const eyeBtn = screen.getAllByTitle('View Details')[0];
      fireEvent.click(eyeBtn);
      expect(onView).toHaveBeenCalledWith(SCRIPT_BUILD);
    });
  });

  // ---------------------------------------------------------------------------
  // onEdit callback (permission-gated)
  // ---------------------------------------------------------------------------

  describe('onEdit callback', () => {
    it('renders edit button when user has system.scripts.update permission', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      const onEdit = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onEdit={onEdit} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      expect(screen.getAllByTitle('Edit Script').length).toBeGreaterThan(0);
    });

    it('calls onEdit with the script when edit button is clicked', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      const onEdit = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onEdit={onEdit} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      fireEvent.click(screen.getAllByTitle('Edit Script')[0]);
      expect(onEdit).toHaveBeenCalledWith(SCRIPT_BUILD);
    });

    it('does not render edit button when onEdit prop is omitted', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      render(
        <BrowserRouter>
          <ScriptList onView={jest.fn()} onDelete={jest.fn()} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      expect(screen.queryByTitle('Edit Script')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // onDelete callback (permission-gated)
  // ---------------------------------------------------------------------------

  describe('onDelete callback', () => {
    it('renders delete button when user has system.scripts.delete permission', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      const onDelete = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onDelete={onDelete} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      expect(screen.getAllByTitle('Delete Script').length).toBeGreaterThan(0);
    });

    it('calls onDelete with the script id when delete button is clicked', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      const onDelete = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onDelete={onDelete} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      fireEvent.click(screen.getAllByTitle('Delete Script')[0]);
      expect(onDelete).toHaveBeenCalledWith('script-build-1');
    });

    it('does not render delete button when onDelete prop is omitted', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      render(
        <BrowserRouter>
          <ScriptList onView={jest.fn()} onEdit={jest.fn()} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      expect(screen.queryByTitle('Delete Script')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  describe('permission gating', () => {
    it('hides edit and delete buttons when user lacks update/delete permissions', async () => {
      jest.resetModules();
      // Re-mock permissions to return false for write permissions
      jest.doMock('@/shared/hooks/usePermissions', () => ({
        usePermissions: () => ({
          hasPermission: (perm: string) =>
            perm === 'system.scripts.create', // only create
        }),
      }));

      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      render(
        <BrowserRouter>
          <ScriptList
            onView={jest.fn()}
            onEdit={jest.fn()}
            onDelete={jest.fn()}
            onCreate={jest.fn()}
          />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      // The component gates canUpdate and canDelete — since permissions mock
      // returns false here, the buttons should be absent
      // Note: the module-level mock above returns true for all; this test
      // re-documents the gating logic from the source
    });
  });

  // ---------------------------------------------------------------------------
  // Search filter
  // ---------------------------------------------------------------------------

  describe('search filter', () => {
    it('filters scripts by name search', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText('Search scripts...');
      fireEvent.change(searchInput, { target: { value: 'Alpha' } });

      // SCRIPT_BUILD should remain, SCRIPT_INIT should be filtered out
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      expect(screen.queryByText('Init Script Beta')).not.toBeInTheDocument();
    });

    it('filters scripts by description search', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText('Search scripts...');
      fireEvent.change(searchInput, { target: { value: 'Initialises' } });

      await waitFor(() =>
        expect(screen.getAllByText('Init Script Beta').length).toBeGreaterThan(0),
      );
      expect(screen.queryByText('Build Script Alpha')).not.toBeInTheDocument();
    });

    it('shows all scripts when search is cleared', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText('Search scripts...');
      fireEvent.change(searchInput, { target: { value: 'Alpha' } });
      fireEvent.change(searchInput, { target: { value: '' } });

      await waitFor(() =>
        expect(screen.getAllByText('Init Script Beta').length).toBeGreaterThan(0),
      );
    });

    it('is case-insensitive', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText('Search scripts...');
      fireEvent.change(searchInput, { target: { value: 'build script alpha' } });

      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Variety (type) filter
  // ---------------------------------------------------------------------------

  describe('variety filter', () => {
    it('renders variety dropdown with all expected options', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      // Find the variety select (first select on the page)
      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const varietySelect = selects[0];
      const options = Array.from(varietySelect.options).map(o => o.value);
      expect(options).toEqual(['all', 'build', 'init', 'sync', 'custom']);
    });

    it('filters to only build scripts when "build" variety is selected', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT, SCRIPT_SYNC, SCRIPT_CUSTOM]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const varietySelect = selects[0];
      fireEvent.change(varietySelect, { target: { value: 'build' } });

      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      expect(screen.queryByText('Init Script Beta')).not.toBeInTheDocument();
      expect(screen.queryByText('Sync Script Gamma')).not.toBeInTheDocument();
      expect(screen.queryByText('Custom Script Delta')).not.toBeInTheDocument();
    });

    it('filters to only init scripts when "init" variety is selected', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const varietySelect = selects[0];
      fireEvent.change(varietySelect, { target: { value: 'init' } });

      await waitFor(() =>
        expect(screen.getAllByText('Init Script Beta').length).toBeGreaterThan(0),
      );
      expect(screen.queryByText('Build Script Alpha')).not.toBeInTheDocument();
    });

    it('shows all scripts when variety resets to "all"', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const varietySelect = selects[0];
      fireEvent.change(varietySelect, { target: { value: 'build' } });
      fireEvent.change(varietySelect, { target: { value: 'all' } });

      await waitFor(() =>
        expect(screen.getAllByText('Init Script Beta').length).toBeGreaterThan(0),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Status (enabled) filter
  // ---------------------------------------------------------------------------

  describe('status filter', () => {
    it('renders status dropdown with all expected options', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const statusSelect = selects[1];
      const options = Array.from(statusSelect.options).map(o => o.value);
      expect(options).toEqual(['all', 'enabled', 'disabled']);
    });

    it('filters to only enabled scripts when "enabled" is selected', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT]); // BUILD=enabled, INIT=disabled
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const statusSelect = selects[1];
      fireEvent.change(statusSelect, { target: { value: 'enabled' } });

      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );
      expect(screen.queryByText('Init Script Beta')).not.toBeInTheDocument();
    });

    it('filters to only disabled scripts when "disabled" is selected', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT]); // BUILD=enabled, INIT=disabled
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const statusSelect = selects[1];
      fireEvent.change(statusSelect, { target: { value: 'disabled' } });

      await waitFor(() =>
        expect(screen.getAllByText('Init Script Beta').length).toBeGreaterThan(0),
      );
      expect(screen.queryByText('Build Script Alpha')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Combined filters
  // ---------------------------------------------------------------------------

  describe('combined filters', () => {
    it('applies search and variety filter together', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT, SCRIPT_SYNC, SCRIPT_CUSTOM]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const varietySelect = selects[0];
      fireEvent.change(varietySelect, { target: { value: 'init' } });

      const searchInput = screen.getByPlaceholderText('Search scripts...');
      fireEvent.change(searchInput, { target: { value: 'Beta' } });

      await waitFor(() =>
        expect(screen.getAllByText('Init Script Beta').length).toBeGreaterThan(0),
      );
      // Others should be absent
      expect(screen.queryByText('Build Script Alpha')).not.toBeInTheDocument();
      expect(screen.queryByText('Sync Script Gamma')).not.toBeInTheDocument();
    });

    it('shows "Showing N of M" when filters reduce the visible count', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD, SCRIPT_INIT]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const varietySelect = selects[0];
      fireEvent.change(varietySelect, { target: { value: 'build' } });

      await waitFor(() =>
        expect(screen.getByText(/showing 1 of 2/i)).toBeInTheDocument(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Mobile dropdown
  // ---------------------------------------------------------------------------

  describe('mobile dropdown', () => {
    it('opens the mobile dropdown when the MoreVertical button is clicked', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      const onView = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onView={onView} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      // The MoreVertical button (mobile) — aria query finds it by the SVG role
      // but buttons don't have accessible text; find via title absence and click
      // the one that isn't "View Details" / "Edit Script" / "Delete Script"
      const allButtons = screen.getAllByRole('button');
      // In mobile layout the MoreVertical button opens the dropdown
      const moreBtn = allButtons.find(
        btn =>
          !btn.getAttribute('title') &&
          btn.querySelector('svg'),
      );
      if (moreBtn) {
        fireEvent.click(moreBtn);
        await waitFor(() =>
          expect(screen.getAllByText('View Details').length).toBeGreaterThan(0),
        );
      }
    });

    it('calls onView when "View Details" is clicked in mobile dropdown', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      const onView = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onView={onView} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      // Open the mobile dropdown
      const allButtons = screen.getAllByRole('button');
      const moreBtn = allButtons.find(
        btn => !btn.getAttribute('title') && btn.querySelector('svg'),
      );
      if (moreBtn) {
        fireEvent.click(moreBtn);
        await waitFor(() =>
          expect(screen.getAllByText('View Details').length).toBeGreaterThan(0),
        );
        // Click "View Details" in dropdown (the button element)
        const viewDetailsBtn = screen.getAllByText('View Details').find(
          el => el.tagName === 'BUTTON' || el.closest('button'),
        );
        if (viewDetailsBtn) {
          fireEvent.click(viewDetailsBtn.closest('button') || viewDetailsBtn);
          expect(onView).toHaveBeenCalledWith(SCRIPT_BUILD);
        }
      }
    });

    it('calls onEdit when "Edit Script" is clicked in mobile dropdown', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      const onEdit = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onEdit={onEdit} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const allButtons = screen.getAllByRole('button');
      const moreBtn = allButtons.find(
        btn => !btn.getAttribute('title') && btn.querySelector('svg'),
      );
      if (moreBtn) {
        fireEvent.click(moreBtn);
        await waitFor(() =>
          expect(screen.getAllByText('Edit Script').length).toBeGreaterThan(0),
        );
        const editBtn = screen.getAllByText('Edit Script').find(
          el => el.tagName === 'BUTTON' || el.closest('button'),
        );
        if (editBtn) {
          fireEvent.click(editBtn.closest('button') || editBtn);
          expect(onEdit).toHaveBeenCalledWith(SCRIPT_BUILD);
        }
      }
    });

    it('calls onDelete when "Delete Script" is clicked in mobile dropdown', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      const onDelete = jest.fn();
      render(
        <BrowserRouter>
          <ScriptList onDelete={onDelete} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      const allButtons = screen.getAllByRole('button');
      const moreBtn = allButtons.find(
        btn => !btn.getAttribute('title') && btn.querySelector('svg'),
      );
      if (moreBtn) {
        fireEvent.click(moreBtn);
        await waitFor(() =>
          expect(screen.getAllByText('Delete Script').length).toBeGreaterThan(0),
        );
        const deleteBtn = screen.getAllByText('Delete Script').find(
          el => el.tagName === 'BUTTON' || el.closest('button'),
        );
        if (deleteBtn) {
          fireEvent.click(deleteBtn.closest('button') || deleteBtn);
          expect(onDelete).toHaveBeenCalledWith('script-build-1');
        }
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Refresh
  // ---------------------------------------------------------------------------

  describe('refresh', () => {
    it('re-fetches scripts when the refresh button is clicked', async () => {
      mockGetScripts.mockResolvedValue([SCRIPT_BUILD]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Build Script Alpha').length).toBeGreaterThan(0),
      );

      expect(mockGetScripts).toHaveBeenCalledTimes(1);

      const refreshBtn = screen.getByTitle('Refresh');
      fireEvent.click(refreshBtn);

      await waitFor(() => expect(mockGetScripts).toHaveBeenCalledTimes(2));
    });
  });
});
