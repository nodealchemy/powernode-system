import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { MarketplaceTab } from './MarketplaceTab';
import { marketplaceApi } from '@system/features/system/services/api/marketplaceApi';

// =============================================================================
// Mocks
//
// MarketplaceTab calls marketplaceApi.list() directly. Child components
// (ModuleCard, ModuleDetailModal) are mocked so tests focus purely on the
// tab's orchestration: fetch lifecycle, filter interactions, empty/error states,
// and modal open/close.
// =============================================================================

jest.mock('@system/features/system/services/api/marketplaceApi', () => ({
  marketplaceApi: {
    list: jest.fn(),
    get: jest.fn(),
  },
}));

jest.mock('@system/features/system/components/marketplace/ModuleCard', () => ({
  ModuleCard: ({ module, onClick }: { module: { id: string; name: string }; onClick: () => void }) => (
    <button data-testid={`module-card-${module.id}`} onClick={onClick}>
      {module.name}
    </button>
  ),
}));

jest.mock('@system/features/system/components/marketplace/ModuleDetailModal', () => ({
  ModuleDetailModal: ({
    moduleId,
    onClose,
  }: {
    moduleId: string;
    onClose: () => void;
  }) => (
    <div data-testid="module-detail-modal" data-module-id={moduleId}>
      <button onClick={onClose}>Close modal</button>
    </div>
  ),
}));

jest.mock('@/shared/utils/logger', () => ({
  logger: { error: jest.fn(), warn: jest.fn(), info: jest.fn() },
}));

// =============================================================================
// Helpers
// =============================================================================

const mockList = marketplaceApi.list as jest.MockedFunction<typeof marketplaceApi.list>;

/** Build a mock resolved value for marketplaceApi.list */
function makeListResult(modules: Parameters<typeof marketplaceApi.list>[0] extends infer _F
  ? { id: string; name: string; description?: string; variety: string; priority: number;
      trust_tier: string; current_version_number: number; assignment_count: number;
      updated_at: string }[]
  : never) {
  return {
    modules,
    meta: {
      current_page: 1,
      per_page: 25,
      total_count: modules.length,
      total_pages: 1,
      next_page: null,
      prev_page: null,
    },
  };
}

const MODULE_A = {
  id: 'mod-a',
  name: 'nginx-base',
  description: 'Hardened nginx baseline',
  variety: 'subscription',
  priority: 10,
  trust_tier: 'internal',
  current_version_number: 2,
  assignment_count: 5,
  updated_at: '2026-05-01T10:00:00Z',
};

const MODULE_B = {
  id: 'mod-b',
  name: 'postgres-ha',
  description: 'High-availability Postgres cluster',
  variety: 'subscription',
  priority: 8,
  trust_tier: 'verified-publisher',
  current_version_number: 1,
  assignment_count: 2,
  updated_at: '2026-04-01T10:00:00Z',
};

const renderTab = () => render(<MarketplaceTab />);

// =============================================================================
// Tests
// =============================================================================

describe('MarketplaceTab', () => {
  beforeEach(() => {
    mockList.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while the API call is in-flight', () => {
    // Never resolves so we can assert the loading state synchronously
    mockList.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByText('Loading marketplace...')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Success — modules rendered
  // ---------------------------------------------------------------------------

  it('renders module cards after a successful fetch', async () => {
    mockList.mockResolvedValue(makeListResult([MODULE_A, MODULE_B]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('module-card-mod-a')).toBeInTheDocument(),
    );

    expect(screen.getByTestId('module-card-mod-b')).toBeInTheDocument();
    expect(screen.getByText('nginx-base')).toBeInTheDocument();
    expect(screen.getByText('postgres-ha')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows empty-state message when no modules match the filters', async () => {
    mockList.mockResolvedValue(makeListResult([]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('No modules match the current filters.')).toBeInTheDocument(),
    );

    expect(screen.queryByText('Loading marketplace...')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error message when the API call fails', async () => {
    mockList.mockRejectedValue(new Error('Network error'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Network error')).toBeInTheDocument(),
    );

    expect(screen.queryByText('Loading marketplace...')).not.toBeInTheDocument();
  });

  it('shows fallback error text for non-Error rejections', async () => {
    mockList.mockRejectedValue('oops');

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Failed to load marketplace')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Initial API call — no filters applied
  // ---------------------------------------------------------------------------

  it('calls marketplaceApi.list with no filters on mount', async () => {
    mockList.mockResolvedValue(makeListResult([]));

    renderTab();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    expect(mockList).toHaveBeenCalledWith({
      trust_tier: undefined,
      search: undefined,
    });
  });

  // ---------------------------------------------------------------------------
  // Trust-tier filter
  // ---------------------------------------------------------------------------

  it('re-fetches with trust_tier when a tier is selected', async () => {
    mockList.mockResolvedValue(makeListResult([]));

    renderTab();

    // Wait for initial fetch to complete
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    mockList.mockResolvedValue(makeListResult([MODULE_A]));

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'internal' } });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));

    expect(mockList).toHaveBeenNthCalledWith(2, {
      trust_tier: 'internal',
      search: undefined,
    });

    await waitFor(() =>
      expect(screen.getByTestId('module-card-mod-a')).toBeInTheDocument(),
    );
  });

  it('re-fetches with trust_tier=verified-publisher when that tier is selected', async () => {
    mockList.mockResolvedValue(makeListResult([]));

    renderTab();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    mockList.mockResolvedValue(makeListResult([MODULE_B]));

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'verified-publisher' },
    });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));

    expect(mockList).toHaveBeenNthCalledWith(2, {
      trust_tier: 'verified-publisher',
      search: undefined,
    });
  });

  it('re-fetches with trust_tier=undefined when "All trust tiers" is selected', async () => {
    mockList.mockResolvedValue(makeListResult([]));

    renderTab();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    // Select a tier first
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'community' } });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));

    // Revert to "All"
    fireEvent.change(screen.getByRole('combobox'), { target: { value: '' } });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(3));

    expect(mockList).toHaveBeenNthCalledWith(3, {
      trust_tier: undefined,
      search: undefined,
    });
  });

  // ---------------------------------------------------------------------------
  // Search filter
  // ---------------------------------------------------------------------------

  it('re-fetches with a search term when the user types in the search box', async () => {
    mockList.mockResolvedValue(makeListResult([]));

    renderTab();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    mockList.mockResolvedValue(makeListResult([MODULE_A]));

    fireEvent.change(screen.getByPlaceholderText('Search modules...'), {
      target: { value: 'nginx' },
    });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));

    expect(mockList).toHaveBeenNthCalledWith(2, {
      trust_tier: undefined,
      search: 'nginx',
    });

    await waitFor(() =>
      expect(screen.getByTestId('module-card-mod-a')).toBeInTheDocument(),
    );
  });

  it('re-fetches with search=undefined when the search input is cleared', async () => {
    mockList.mockResolvedValue(makeListResult([]));

    renderTab();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    // Type something
    fireEvent.change(screen.getByPlaceholderText('Search modules...'), {
      target: { value: 'nginx' },
    });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));

    // Clear it
    fireEvent.change(screen.getByPlaceholderText('Search modules...'), {
      target: { value: '' },
    });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(3));

    expect(mockList).toHaveBeenNthCalledWith(3, {
      trust_tier: undefined,
      search: undefined,
    });
  });

  // ---------------------------------------------------------------------------
  // Combined filters
  // ---------------------------------------------------------------------------

  it('combines search and trust_tier when both are set', async () => {
    mockList.mockResolvedValue(makeListResult([]));

    renderTab();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    // Set trust tier
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'community' } });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));

    // Then type a search
    fireEvent.change(screen.getByPlaceholderText('Search modules...'), {
      target: { value: 'my-module' },
    });

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(3));

    expect(mockList).toHaveBeenNthCalledWith(3, {
      trust_tier: 'community',
      search: 'my-module',
    });
  });

  // ---------------------------------------------------------------------------
  // Modal open / close
  // ---------------------------------------------------------------------------

  it('opens the ModuleDetailModal when a module card is clicked', async () => {
    mockList.mockResolvedValue(makeListResult([MODULE_A]));

    renderTab();

    const card = await waitFor(() => screen.getByTestId('module-card-mod-a'));

    fireEvent.click(card);

    const modal = screen.getByTestId('module-detail-modal');
    expect(modal).toBeInTheDocument();
    expect(modal.getAttribute('data-module-id')).toBe('mod-a');
  });

  it('closes the ModuleDetailModal when onClose is called', async () => {
    mockList.mockResolvedValue(makeListResult([MODULE_A]));

    renderTab();

    const card = await waitFor(() => screen.getByTestId('module-card-mod-a'));

    fireEvent.click(card);

    expect(screen.getByTestId('module-detail-modal')).toBeInTheDocument();

    fireEvent.click(screen.getByText('Close modal'));

    expect(screen.queryByTestId('module-detail-modal')).not.toBeInTheDocument();
  });

  it('opens the correct module detail modal for the clicked card', async () => {
    mockList.mockResolvedValue(makeListResult([MODULE_A, MODULE_B]));

    renderTab();

    await waitFor(() => screen.getByTestId('module-card-mod-a'));

    fireEvent.click(screen.getByTestId('module-card-mod-b'));

    const modal = screen.getByTestId('module-detail-modal');
    expect(modal.getAttribute('data-module-id')).toBe('mod-b');
  });

  it('does not show the modal before any card is clicked', async () => {
    mockList.mockResolvedValue(makeListResult([MODULE_A]));

    renderTab();

    await waitFor(() => screen.getByTestId('module-card-mod-a'));

    expect(screen.queryByTestId('module-detail-modal')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Filter controls render
  // ---------------------------------------------------------------------------

  it('renders the search input and trust-tier select', () => {
    mockList.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByPlaceholderText('Search modules...')).toBeInTheDocument();
    expect(screen.getByRole('combobox')).toBeInTheDocument();
    expect(screen.getByText('All trust tiers')).toBeInTheDocument();
    expect(screen.getByText('Internal')).toBeInTheDocument();
    expect(screen.getByText('Verified Publisher')).toBeInTheDocument();
    expect(screen.getByText('Community')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Loading spinner disappears after fetch completes
  // ---------------------------------------------------------------------------

  it('hides the loading indicator after the fetch resolves', async () => {
    mockList.mockResolvedValue(makeListResult([]));

    renderTab();

    expect(screen.getByText('Loading marketplace...')).toBeInTheDocument();

    await waitFor(() =>
      expect(screen.queryByText('Loading marketplace...')).not.toBeInTheDocument(),
    );
  });
});
