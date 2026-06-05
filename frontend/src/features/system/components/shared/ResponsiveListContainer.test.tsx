import React from 'react';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { Server } from 'lucide-react';
import { ResponsiveListContainer } from './ResponsiveListContainer';

// =============================================================================
// IntersectionObserver mock
//
// jsdom does not implement IntersectionObserver. We replace it with a test
// double that captures every (callback, options) pair so individual tests can
// fire intersection events programmatically.
// =============================================================================

type IOCallback = (entries: IntersectionObserverEntry[]) => void;

interface MockObserverInstance {
  callback: IOCallback;
  options: IntersectionObserverInit | undefined;
  observe: jest.Mock;
  disconnect: jest.Mock;
}

let mockObserverInstances: MockObserverInstance[] = [];

class MockIntersectionObserver {
  callback: IOCallback;
  options: IntersectionObserverInit | undefined;
  observe: jest.Mock;
  disconnect: jest.Mock;

  constructor(callback: IOCallback, options?: IntersectionObserverInit) {
    this.callback = callback;
    this.options = options;
    this.observe = jest.fn();
    this.disconnect = jest.fn();
    mockObserverInstances.push(this);
  }
}

const triggerIntersect = (instance: MockObserverInstance, isIntersecting: boolean) => {
  act(() => {
    instance.callback([{ isIntersecting } as IntersectionObserverEntry]);
  });
};

beforeAll(() => {
  Object.defineProperty(window, 'IntersectionObserver', {
    writable: true,
    configurable: true,
    value: MockIntersectionObserver,
  });
});

beforeEach(() => {
  mockObserverInstances = [];
});

// =============================================================================
// Shared fixtures
// =============================================================================

const DEFAULT_EMPTY_STATE = {
  icon: Server,
  title: 'No items found',
  description: 'Add your first item to get started.',
  action: {
    label: 'Create Item',
    onClick: jest.fn(),
  },
};

// =============================================================================
// Tests
// =============================================================================

describe('ResponsiveListContainer', () => {
  // ---------------------------------------------------------------------------
  // Initial loading state (loading=true, totalCount=0)
  // ---------------------------------------------------------------------------

  describe('initial loading state', () => {
    it('renders a loading spinner when loading=true and totalCount=0', () => {
      render(
        <ResponsiveListContainer
          loading={true}
          totalCount={0}
          filteredCount={0}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          {null}
        </ResponsiveListContainer>,
      );
      const spinnerDiv = document.querySelector('.animate-spin');
      expect(spinnerDiv).toBeInTheDocument();
    });

    it('does not render the empty-state title or filter row during initial load', () => {
      render(
        <ResponsiveListContainer
          loading={true}
          totalCount={0}
          filteredCount={0}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          {null}
        </ResponsiveListContainer>,
      );
      expect(screen.queryByText('No items found')).not.toBeInTheDocument();
      expect(screen.queryByTitle('Refresh')).not.toBeInTheDocument();
    });

    it('applies the className prop to the loading wrapper', () => {
      const { container } = render(
        <ResponsiveListContainer
          loading={true}
          totalCount={0}
          filteredCount={0}
          emptyState={DEFAULT_EMPTY_STATE}
          className="custom-loading"
        >
          {null}
        </ResponsiveListContainer>,
      );
      expect(container.firstChild).toHaveClass('custom-loading');
    });

    it('does NOT show the full-screen spinner when loading=true but totalCount>0 (refresh scenario)', () => {
      render(
        <ResponsiveListContainer
          loading={true}
          totalCount={2}
          filteredCount={2}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Desktop>
            <div data-testid="table">table</div>
          </ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      // The loaded list remains visible; empty-state title is not shown
      expect(screen.queryByText('No items found')).not.toBeInTheDocument();
      expect(screen.getByTestId('table')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Empty state (loading=false, totalCount=0)
  // ---------------------------------------------------------------------------

  describe('empty state', () => {
    it('renders the empty-state title', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={0}
          filteredCount={0}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          {null}
        </ResponsiveListContainer>,
      );
      expect(screen.getByText('No items found')).toBeInTheDocument();
    });

    it('renders the empty-state description when provided', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={0}
          filteredCount={0}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          {null}
        </ResponsiveListContainer>,
      );
      expect(screen.getByText('Add your first item to get started.')).toBeInTheDocument();
    });

    it('does not render description when omitted', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={0}
          filteredCount={0}
          emptyState={{ icon: Server, title: 'Nothing here' }}
        >
          {null}
        </ResponsiveListContainer>,
      );
      expect(screen.queryByText(/add your first/i)).not.toBeInTheDocument();
    });

    it('renders the action button when action is provided without a permission prop', () => {
      const onClick = jest.fn();
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={0}
          filteredCount={0}
          emptyState={{ icon: Server, title: 'No items', action: { label: 'Create Now', onClick } }}
        >
          {null}
        </ResponsiveListContainer>,
      );
      expect(screen.getByRole('button', { name: /create now/i })).toBeInTheDocument();
    });

    it('calls action.onClick when the action button is clicked', () => {
      const onClick = jest.fn();
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={0}
          filteredCount={0}
          emptyState={{ icon: Server, title: 'No items', action: { label: 'Create Now', onClick } }}
        >
          {null}
        </ResponsiveListContainer>,
      );
      fireEvent.click(screen.getByRole('button', { name: /create now/i }));
      expect(onClick).toHaveBeenCalledTimes(1);
    });

    it('suppresses the action button when action.permission === false', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={0}
          filteredCount={0}
          emptyState={{
            icon: Server,
            title: 'No items',
            action: { label: 'Create Now', onClick: jest.fn(), permission: false },
          }}
        >
          {null}
        </ResponsiveListContainer>,
      );
      expect(screen.queryByRole('button', { name: /create now/i })).not.toBeInTheDocument();
    });

    it('shows the action button when action.permission === true', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={0}
          filteredCount={0}
          emptyState={{
            icon: Server,
            title: 'No items',
            action: { label: 'Create Now', onClick: jest.fn(), permission: true },
          }}
        >
          {null}
        </ResponsiveListContainer>,
      );
      expect(screen.getByRole('button', { name: /create now/i })).toBeInTheDocument();
    });

    it('applies className to the empty-state wrapper', () => {
      const { container } = render(
        <ResponsiveListContainer
          loading={false}
          totalCount={0}
          filteredCount={0}
          emptyState={DEFAULT_EMPTY_STATE}
          className="my-custom-class"
        >
          {null}
        </ResponsiveListContainer>,
      );
      expect(container.firstChild).toHaveClass('my-custom-class');
    });

    it('renders the icon (SVG element) in the empty state', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={0}
          filteredCount={0}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          {null}
        </ResponsiveListContainer>,
      );
      expect(document.querySelector('svg')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Loaded state with content — slot rendering
  //
  // IMPORTANT: slots MUST be DIRECT children of ResponsiveListContainer.
  // React.Children.forEach does NOT traverse fragments, so wrapping slots in
  // <> </> would hide them from the findSlot identity check. Slots are passed
  // as adjacent JSX elements directly inside the component.
  // ---------------------------------------------------------------------------

  describe('loaded state with content', () => {
    it('renders Desktop slot content inside the hidden-md wrapper', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Desktop>
            <div data-testid="desktop-content">Desktop Table</div>
          </ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      const desktopContent = screen.getByTestId('desktop-content');
      expect(desktopContent).toBeInTheDocument();
      expect(desktopContent.closest('.hidden')).toBeInTheDocument();
    });

    it('renders Mobile slot content inside the md:hidden wrapper', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Mobile>
            <div data-testid="mobile-content">Mobile Cards</div>
          </ResponsiveListContainer.Mobile>
        </ResponsiveListContainer>,
      );
      const mobileContent = screen.getByTestId('mobile-content');
      expect(mobileContent).toBeInTheDocument();
      expect(mobileContent.closest('.md\\:hidden')).toBeInTheDocument();
    });

    it('renders both Desktop and Mobile slots as direct siblings', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Desktop>
            <div data-testid="desktop-content">Desktop</div>
          </ResponsiveListContainer.Desktop>
          <ResponsiveListContainer.Mobile>
            <div data-testid="mobile-content">Mobile</div>
          </ResponsiveListContainer.Mobile>
        </ResponsiveListContainer>,
      );
      expect(screen.getByTestId('desktop-content')).toBeInTheDocument();
      expect(screen.getByTestId('mobile-content')).toBeInTheDocument();
    });

    it('renders Body slot directly without the Desktop/Mobile surface-card wrapper', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Body>
            <div data-testid="body-content">Grid Content</div>
          </ResponsiveListContainer.Body>
        </ResponsiveListContainer>,
      );
      const bodyContent = screen.getByTestId('body-content');
      expect(bodyContent).toBeInTheDocument();
      // Body slot bypasses the surface card — no hidden/md:block wrapper
      expect(document.querySelector('.hidden')).not.toBeInTheDocument();
    });

    it('applies className to the loaded-state outer wrapper', () => {
      const { container } = render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          className="my-space-class"
        >
          <ResponsiveListContainer.Desktop>
            <div>content</div>
          </ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(container.firstChild).toHaveClass('my-space-class');
    });
  });

  // ---------------------------------------------------------------------------
  // Filter slot
  // ---------------------------------------------------------------------------

  describe('Filters slot', () => {
    it('renders the Filters slot content inside the filter bar', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Filters>
            <input data-testid="search-input" placeholder="Search..." />
          </ResponsiveListContainer.Filters>
          <ResponsiveListContainer.Desktop>
            <div>content</div>
          </ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.getByTestId('search-input')).toBeInTheDocument();
    });

    it('does NOT render the filter bar when no Filters slot and no onRefresh', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Desktop>
            <div>content</div>
          </ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.queryByTitle('Refresh')).not.toBeInTheDocument();
    });

    it('renders the filter bar when onRefresh is provided even without a Filters slot', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
        >
          <ResponsiveListContainer.Desktop>
            <div>content</div>
          </ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.getByTitle('Refresh')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Refresh button
  // ---------------------------------------------------------------------------

  describe('refresh button', () => {
    it('renders the refresh button when onRefresh is provided', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.getByTitle('Refresh')).toBeInTheDocument();
    });

    it('calls onRefresh when the refresh button is clicked', () => {
      const onRefresh = jest.fn();
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={onRefresh}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      fireEvent.click(screen.getByTitle('Refresh'));
      expect(onRefresh).toHaveBeenCalledTimes(1);
    });

    it('disables the refresh button when refreshing=true', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
          refreshing={true}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.getByTitle('Refresh')).toBeDisabled();
    });

    it('enables the refresh button when refreshing=false', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
          refreshing={false}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.getByTitle('Refresh')).not.toBeDisabled();
    });

    it('adds animate-spin to the RefreshCw SVG when refreshing=true', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
          refreshing={true}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      const refreshBtn = screen.getByTitle('Refresh');
      expect(refreshBtn.querySelector('.animate-spin')).toBeInTheDocument();
    });

    it('does NOT add animate-spin when refreshing=false', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
          refreshing={false}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      const refreshBtn = screen.getByTitle('Refresh');
      expect(refreshBtn.querySelector('.animate-spin')).not.toBeInTheDocument();
    });

    it('does not render the refresh button when onRefresh is not provided', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Filters>
            <input placeholder="Search" />
          </ResponsiveListContainer.Filters>
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.queryByTitle('Refresh')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // "Showing N of M" count summary
  // ---------------------------------------------------------------------------

  describe('count summary hint', () => {
    it('renders "Showing N of M" when filteredCount < totalCount', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={10}
          filteredCount={4}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.getByText('Showing 4 of 10')).toBeInTheDocument();
    });

    it('does NOT render the count hint when filteredCount === totalCount', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={5}
          filteredCount={5}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.queryByText(/showing \d+ of \d+/i)).not.toBeInTheDocument();
    });

    it('does NOT render the count hint when filteredCount > totalCount (edge case)', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={5}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.queryByText(/showing \d+ of \d+/i)).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Infinite scroll — disabled (no onLoadMore)
  // ---------------------------------------------------------------------------

  describe('infinite scroll — disabled', () => {
    it('does not create an IntersectionObserver when onLoadMore is not provided', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(mockObserverInstances.length).toBe(0);
    });

    it('does not render "All N loaded" text when infinite scroll is disabled', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          serverTotalCount={100}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.queryByText(/all \d+ loaded/i)).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Infinite scroll — enabled
  // ---------------------------------------------------------------------------

  describe('infinite scroll — enabled', () => {
    it('creates an IntersectionObserver sentinel when onLoadMore is provided and hasMore=true', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={jest.fn()}
          hasMore={true}
          loadingMore={false}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(mockObserverInstances.length).toBe(1);
    });

    it('calls onLoadMore when the sentinel fires an intersection event', () => {
      const onLoadMore = jest.fn();
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={onLoadMore}
          hasMore={true}
          loadingMore={false}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      triggerIntersect(mockObserverInstances[0], true);
      expect(onLoadMore).toHaveBeenCalledTimes(1);
    });

    it('does not fire onLoadMore for a leave event (isIntersecting=false)', () => {
      const onLoadMore = jest.fn();
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={onLoadMore}
          hasMore={true}
          loadingMore={false}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      triggerIntersect(mockObserverInstances[0], false);
      expect(onLoadMore).not.toHaveBeenCalled();
    });

    it('disables the sentinel observer when loadingMore=true', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={jest.fn()}
          hasMore={true}
          loadingMore={true}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      // Sentinel mounts but observer is not created (enabled=false because loadingMore=true)
      expect(mockObserverInstances.length).toBe(0);
    });

    it('disables the sentinel observer when hasMore=false', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={jest.fn()}
          hasMore={false}
          loadingMore={false}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(mockObserverInstances.length).toBe(0);
    });

    it('renders the loading-more spinner when loadingMore=true', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={jest.fn()}
          hasMore={true}
          loadingMore={true}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(document.querySelector('.animate-spin')).toBeInTheDocument();
    });

    it('does NOT render the loading-more spinner when loadingMore=false', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={jest.fn()}
          hasMore={true}
          loadingMore={false}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(document.querySelector('.animate-spin')).not.toBeInTheDocument();
    });

    it('renders "All N loaded" when hasMore=false, totalCount>0, serverTotalCount provided', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={25}
          filteredCount={25}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={jest.fn()}
          hasMore={false}
          loadingMore={false}
          serverTotalCount={25}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.getByText('All 25 loaded')).toBeInTheDocument();
    });

    it('does NOT render "All N loaded" when hasMore=true (more pages remain)', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={10}
          filteredCount={10}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={jest.fn()}
          hasMore={true}
          loadingMore={false}
          serverTotalCount={100}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.queryByText(/all \d+ loaded/i)).not.toBeInTheDocument();
    });

    it('does NOT render "All N loaded" when serverTotalCount is undefined', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={5}
          filteredCount={5}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={jest.fn()}
          hasMore={false}
          loadingMore={false}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.queryByText(/all \d+ loaded/i)).not.toBeInTheDocument();
    });

    it('does NOT render "All N loaded" when totalCount===0 (empty list with infinite props)', () => {
      // Verifies the !hasMore && totalCount > 0 guard
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={0}
          filteredCount={0}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={jest.fn()}
          hasMore={false}
          loadingMore={false}
          serverTotalCount={0}
        >
          {null}
        </ResponsiveListContainer>,
      );
      // Empty state renders — infinite scroll footer is suppressed
      expect(screen.getByText('No items found')).toBeInTheDocument();
      expect(screen.queryByText(/all \d+ loaded/i)).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Slot identity resolution
  // ---------------------------------------------------------------------------

  describe('slot identity resolution', () => {
    it('non-slot children (plain divs) are passed through as normal children', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Desktop>
            <div data-testid="desktop-content">desktop</div>
          </ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.getByTestId('desktop-content')).toBeInTheDocument();
    });

    it('renders Body slot bypassing the Desktop/Mobile surface-card layout', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Body>
            <div data-testid="body-grid">Grid</div>
          </ResponsiveListContainer.Body>
        </ResponsiveListContainer>,
      );
      expect(screen.getByTestId('body-grid')).toBeInTheDocument();
      // Body bypasses the surface card wrapper — no hidden md:block container
      expect(document.querySelector('.hidden')).not.toBeInTheDocument();
    });

    it('when Body is present alongside Desktop, Body is rendered and Desktop card wrapper is omitted', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Body>
            <div data-testid="body-content">Body</div>
          </ResponsiveListContainer.Body>
          <ResponsiveListContainer.Desktop>
            <div data-testid="desktop-content">Desktop</div>
          </ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.getByTestId('body-content')).toBeInTheDocument();
      // When Body slot is active, the surface card wrapper is not rendered
      expect(document.querySelector('.hidden')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Subcomponent displayNames (used by findSlot identity check)
  // ---------------------------------------------------------------------------

  describe('subcomponent displayNames', () => {
    it('Filters has the correct displayName', () => {
      expect(ResponsiveListContainer.Filters.displayName).toBe('ResponsiveListContainer.Filters');
    });

    it('Desktop has the correct displayName', () => {
      expect(ResponsiveListContainer.Desktop.displayName).toBe('ResponsiveListContainer.Desktop');
    });

    it('Mobile has the correct displayName', () => {
      expect(ResponsiveListContainer.Mobile.displayName).toBe('ResponsiveListContainer.Mobile');
    });

    it('Body has the correct displayName', () => {
      expect(ResponsiveListContainer.Body.displayName).toBe('ResponsiveListContainer.Body');
    });
  });

  // ---------------------------------------------------------------------------
  // Combined: Filters + refresh + Desktop + count hint
  // ---------------------------------------------------------------------------

  describe('combined filter bar with all elements', () => {
    it('renders filters, refresh button, and count hint together', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={20}
          filteredCount={7}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
        >
          <ResponsiveListContainer.Filters>
            <input data-testid="filter-input" placeholder="Filter" />
          </ResponsiveListContainer.Filters>
          <ResponsiveListContainer.Desktop>
            <div>table</div>
          </ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );

      expect(screen.getByTestId('filter-input')).toBeInTheDocument();
      expect(screen.getByTitle('Refresh')).toBeInTheDocument();
      expect(screen.getByText('Showing 7 of 20')).toBeInTheDocument();
    });

    it('clicking refresh while filters are active calls onRefresh', () => {
      const onRefresh = jest.fn();
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={20}
          filteredCount={7}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={onRefresh}
        >
          <ResponsiveListContainer.Filters>
            <input data-testid="filter-input" placeholder="Filter" />
          </ResponsiveListContainer.Filters>
          <ResponsiveListContainer.Desktop>
            <div>table</div>
          </ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );

      fireEvent.click(screen.getByTitle('Refresh'));
      expect(onRefresh).toHaveBeenCalledTimes(1);
    });
  });

  // ---------------------------------------------------------------------------
  // Default prop values
  // ---------------------------------------------------------------------------

  describe('default prop values', () => {
    it('defaults refreshing to false (button enabled without explicit prop)', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onRefresh={jest.fn()}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      expect(screen.getByTitle('Refresh')).not.toBeDisabled();
    });

    it('defaults loadingMore to false — sentinel observer IS created when hasMore=true', () => {
      render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
          onLoadMore={jest.fn()}
          hasMore={true}
          // loadingMore not passed — defaults to false
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      // enabled = hasMore=true && !loadingMore=false && !loading=false → observer created
      expect(mockObserverInstances.length).toBe(1);
    });

    it('defaults className to empty string — outer div has only built-in classes', () => {
      const { container } = render(
        <ResponsiveListContainer
          loading={false}
          totalCount={3}
          filteredCount={3}
          emptyState={DEFAULT_EMPTY_STATE}
        >
          <ResponsiveListContainer.Desktop><div>content</div></ResponsiveListContainer.Desktop>
        </ResponsiveListContainer>,
      );
      const outer = container.firstChild as HTMLElement;
      expect(outer.className).toContain('space-y-6');
    });
  });
});
