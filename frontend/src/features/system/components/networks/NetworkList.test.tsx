import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworkList } from './NetworkList';
import type { SystemProviderNetwork } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGetNetworks = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getNetworks: (...args: unknown[]) => mockGetNetworks(...args),
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

// EntityLink renders as a plain span — mock to avoid entityRegistry deps.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label, id }: { type: string; id?: string; label?: React.ReactNode }) => (
    <span data-testid="entity-link">{label ?? id}</span>
  ),
}));

// =============================================================================
// Fixtures
// =============================================================================

const makeMeta = (total: number) => ({
  current_page: 1,
  per_page: 20,
  total_count: total,
  total_pages: 1,
  next_page: null,
  prev_page: null,
});

// systemApi.getNetworks returns { networks, meta } (already-extracted by the api module).
function networksResponse(networks: SystemProviderNetwork[]) {
  return Promise.resolve({ networks, meta: makeMeta(networks.length) });
}

const NET_AVAILABLE: SystemProviderNetwork = {
  id: 'net-aaa',
  name: 'production-vpc',
  description: 'Main production VPC',
  cidr_block: '10.0.0.0/16',
  status: 'available',
  is_default: false,
  dns_support: true,
  dns_hostnames: true,
  config: {},
  provider_region_id: 'region-1',
  provider_region_name: 'us-east-1',
  region_name: 'US East (N. Virginia)',
  subnet_count: 4,
  created_at: '2025-01-15T10:00:00Z',
  updated_at: '2025-02-01T08:30:00Z',
};

const NET_PENDING: SystemProviderNetwork = {
  id: 'net-bbb',
  name: 'staging-net',
  description: undefined,
  cidr_block: '172.16.0.0/12',
  status: 'pending',
  is_default: false,
  dns_support: false,
  dns_hostnames: false,
  config: {},
  provider_region_id: undefined,
  provider_region_name: undefined,
  region_name: undefined,
  subnet_count: undefined,
  created_at: '2025-03-01T00:00:00Z',
  updated_at: '2025-03-01T00:00:00Z',
};

const NET_DEFAULT: SystemProviderNetwork = {
  id: 'net-ccc',
  name: 'default-vpc',
  cidr_block: '192.168.0.0/16',
  status: 'available',
  is_default: true,
  dns_support: true,
  dns_hostnames: false,
  config: {},
  provider_region_id: 'region-1',
  created_at: '2024-12-01T00:00:00Z',
  updated_at: '2024-12-01T00:00:00Z',
};

const NET_ERROR: SystemProviderNetwork = {
  id: 'net-ddd',
  name: 'broken-network',
  cidr_block: '10.99.0.0/24',
  status: 'error',
  is_default: false,
  dns_support: false,
  dns_hostnames: false,
  config: {},
  created_at: '2025-04-01T00:00:00Z',
  updated_at: '2025-04-01T00:00:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

interface RenderOptions {
  onView?: (n: SystemProviderNetwork) => void;
  onEdit?: (n: SystemProviderNetwork) => void;
  onDelete?: (id: string) => void;
  onCreate?: () => void;
}

const renderList = (opts: RenderOptions = {}) =>
  render(
    <BrowserRouter>
      <NetworkList {...opts} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('NetworkList', () => {
  beforeEach(() => {
    mockGetNetworks.mockReset();
    mockAddNotification.mockReset();
  });

  // --------------------------------------------------------------------------
  // Loading / empty / error states
  // --------------------------------------------------------------------------

  it('shows a loading spinner while the initial fetch is in flight', () => {
    // Never resolve — loader stays visible
    mockGetNetworks.mockReturnValue(new Promise(() => {}));
    const { container } = renderList();
    // LoadingSpinner renders an animated div; check that no network table rows exist yet
    expect(container.querySelector('tbody')).not.toBeInTheDocument();
    // The spinner wrapper is visible
    expect(container.querySelector('.animate-spin')).toBeInTheDocument();
  });

  it('renders empty state when the API returns no networks', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([]));
    renderList();
    await waitFor(() =>
      expect(screen.getByText('No networks found')).toBeInTheDocument(),
    );
    expect(screen.getByText('Create a network to get started')).toBeInTheDocument();
  });

  it('client-filters table to empty when no networks match status filter', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList();
    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    fireEvent.change(screen.getByDisplayValue('All Status'), { target: { value: 'error' } });

    // The available network disappears from the table (client-side filter)
    await waitFor(() =>
      expect(screen.queryByText('production-vpc')).not.toBeInTheDocument(),
    );
    // Table is still shown (totalCount > 0) — just no rows match the filter
    expect(screen.queryByText('No networks found')).not.toBeInTheDocument();
  });

  it('calls addNotification with error message when API fetch fails', async () => {
    mockGetNetworks.mockRejectedValue(new Error('network error'));
    renderList();
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Failed to load networks' }),
      ),
    );
  });

  // --------------------------------------------------------------------------
  // Rendering networks
  // --------------------------------------------------------------------------

  it('renders network names, CIDR blocks, and status badges after fetch', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE, NET_PENDING]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('staging-net').length).toBeGreaterThan(0);

    // CIDR blocks rendered (desktop + mobile = multiple instances)
    expect(screen.getAllByText('10.0.0.0/16').length).toBeGreaterThan(0);
    expect(screen.getAllByText('172.16.0.0/12').length).toBeGreaterThan(0);

    // Status badges (desktop + mobile)
    expect(screen.getAllByText('available').length).toBeGreaterThan(0);
    expect(screen.getAllByText('pending').length).toBeGreaterThan(0);
  });

  it('renders region_name when present, falls back to dash when absent', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE, NET_PENDING]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );
    expect(screen.getByText('US East (N. Virginia)')).toBeInTheDocument();
    // NET_PENDING has no region — desktop region column shows "—"
    expect(screen.getAllByText('—').length).toBeGreaterThan(0);
  });

  it('renders the Default badge for is_default networks', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_DEFAULT]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('default-vpc').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('Default').length).toBeGreaterThan(0);
  });

  it('renders the DNS badge when dns_support is true', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );
    // DNS badge appears in features column (desktop) and mobile
    expect(screen.getAllByText('DNS').length).toBeGreaterThan(0);
  });

  it('does not render DNS badge when dns_support is false', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_PENDING]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('staging-net').length).toBeGreaterThan(0),
    );
    expect(screen.queryByText('DNS')).not.toBeInTheDocument();
  });

  // --------------------------------------------------------------------------
  // API call shape
  // --------------------------------------------------------------------------

  it('fetches from systemApi.getNetworks on mount with page and per_page params', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([]));
    renderList();

    await waitFor(() => expect(mockGetNetworks).toHaveBeenCalledTimes(1));
    expect(mockGetNetworks).toHaveBeenCalledWith(
      expect.objectContaining({ page: 1, per_page: 20 }),
    );
  });

  it('includes search param when search filter is committed via form submit', async () => {
    // Provide a network so the filters row (and search input) is rendered
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );
    expect(mockGetNetworks).toHaveBeenCalledTimes(1);

    const input = screen.getByPlaceholderText('Search networks (press Enter)...');
    fireEvent.change(input, { target: { value: 'prod' } });
    fireEvent.submit(input.closest('form')!);

    await waitFor(() => expect(mockGetNetworks).toHaveBeenCalledTimes(2));
    expect(mockGetNetworks).toHaveBeenLastCalledWith(
      expect.objectContaining({ search: 'prod' }),
    );
  });

  it('does NOT re-fetch on every keystroke in the search box', async () => {
    // Provide a network so the filters row (and search input) is rendered
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );
    expect(mockGetNetworks).toHaveBeenCalledTimes(1);

    const input = screen.getByPlaceholderText('Search networks (press Enter)...');
    fireEvent.change(input, { target: { value: 'p' } });
    fireEvent.change(input, { target: { value: 'pr' } });
    fireEvent.change(input, { target: { value: 'pro' } });

    // No additional fetch until form submit
    expect(mockGetNetworks).toHaveBeenCalledTimes(1);
  });

  // --------------------------------------------------------------------------
  // Client-side status filter (no re-fetch)
  // --------------------------------------------------------------------------

  it('client-filters to show only matching status without a new API call', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE, NET_PENDING]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    fireEvent.change(screen.getByDisplayValue('All Status'), {
      target: { value: 'available' },
    });

    // available network stays visible; pending disappears
    expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0);
    expect(screen.queryByText('staging-net')).not.toBeInTheDocument();

    // No second API call fired
    expect(mockGetNetworks).toHaveBeenCalledTimes(1);
  });

  it('shows error-status networks when error filter selected', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE, NET_ERROR]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    fireEvent.change(screen.getByDisplayValue('All Status'), {
      target: { value: 'error' },
    });

    expect(screen.queryByText('production-vpc')).not.toBeInTheDocument();
    expect(screen.getAllByText('broken-network').length).toBeGreaterThan(0);
  });

  // --------------------------------------------------------------------------
  // Row expand / collapse
  // --------------------------------------------------------------------------

  it('expands a network row to show detailed fields when chevron is clicked', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    // Detail labels should be absent before expansion
    expect(screen.queryByText('DNS Resolution')).not.toBeInTheDocument();

    // Click the first "Expand details" button (desktop row)
    const expandBtns = screen.getAllByTitle('Expand details');
    fireEvent.click(expandBtns[0]);

    // Desktop + mobile each render the detail section → multiple matches expected
    await waitFor(() =>
      expect(screen.getAllByText('DNS Resolution').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('DNS Hostnames').length).toBeGreaterThan(0);
    // "CIDR Block" appears as both table header AND expanded detail label
    expect(screen.getAllByText('CIDR Block').length).toBeGreaterThanOrEqual(2);
    expect(screen.getAllByText('Network ID').length).toBeGreaterThan(0);
  });

  it('collapses an expanded row when chevron is clicked again', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('DNS Resolution').length).toBeGreaterThan(0),
    );

    // After expansion the title changes to "Collapse details"
    const collapseBtn = screen.getAllByTitle('Collapse details')[0];
    fireEvent.click(collapseBtn);

    await waitFor(() =>
      expect(screen.queryByText('DNS Resolution')).not.toBeInTheDocument(),
    );
  });

  it('shows DNS Resolution as Enabled when dns_support is true', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('DNS Resolution').length).toBeGreaterThan(0),
    );
    // dns_support = true → "Enabled" text appears in the detail section
    expect(screen.getAllByText('Enabled').length).toBeGreaterThan(0);
  });

  it('shows description in expanded detail when present', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('Description').length).toBeGreaterThan(0),
    );
    // The description text appears in the expanded section
    expect(screen.getAllByText('Main production VPC').length).toBeGreaterThan(0);
  });

  it('shows subnet count in expanded detail when present', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('Subnets').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('4').length).toBeGreaterThan(0);
  });

  it('renders EntityLink for provider when provider_id is present in config', async () => {
    const netWithProvider: SystemProviderNetwork = {
      ...NET_AVAILABLE,
      id: 'net-provider',
      config: { provider_id: 'prov-1', provider_name: 'AWS' },
    };
    mockGetNetworks.mockResolvedValue(networksResponse([netWithProvider]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('Provider').length).toBeGreaterThan(0),
    );
    // EntityLink mock renders the label — 'AWS' is the provider_name
    expect(screen.getAllByTestId('entity-link').length).toBeGreaterThan(0);
    expect(screen.getAllByText('AWS').length).toBeGreaterThan(0);
  });

  it('renders EntityLink for node instance when node_id + node_instance_id present in config', async () => {
    const netWithInstance: SystemProviderNetwork = {
      ...NET_AVAILABLE,
      id: 'net-instance',
      config: {
        node_id: 'node-1',
        node_instance_id: 'inst-1',
        node_instance_name: 'my-instance',
      },
    };
    mockGetNetworks.mockResolvedValue(networksResponse([netWithInstance]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('Instance').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('my-instance').length).toBeGreaterThan(0);
  });

  it('does NOT render the provider detail section when provider_id is absent', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const expandBtn = screen.getAllByTitle('Expand details')[0];
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getAllByText('Network ID').length).toBeGreaterThan(0),
    );
    // NET_AVAILABLE has no config.provider_id and no direct provider_id
    expect(screen.queryByText('Provider')).not.toBeInTheDocument();
  });

  // --------------------------------------------------------------------------
  // Action callbacks
  // --------------------------------------------------------------------------

  it('calls onView when the Eye button is clicked', async () => {
    const onView = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList({ onView });

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    // The Eye icon is inside a ghost Button rendered only when onView is provided.
    // In the desktop row the view button is the first button in the actions cell.
    // We find it by locating the row in the desktop table (hidden md:block).
    const desktopTable = document.querySelector('.hidden.md\\:block table');
    expect(desktopTable).toBeInTheDocument();
    const actionButtons = desktopTable!.querySelectorAll('tbody tr:first-child td:last-child button');
    // First action button is the eye/view button
    fireEvent.click(actionButtons[0]);

    expect(onView).toHaveBeenCalledWith(NET_AVAILABLE);
  });

  it('opens dropdown menu when MoreVertical button is clicked', async () => {
    const onEdit = jest.fn();
    const onDelete = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList({ onEdit, onDelete });

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const desktopTable = document.querySelector('.hidden.md\\:block table');
    const actionButtons = desktopTable!.querySelectorAll('tbody tr:first-child td:last-child button');
    // Last action button is the MoreVertical button
    fireEvent.click(actionButtons[actionButtons.length - 1]);

    await waitFor(() => expect(screen.getByText('Edit')).toBeInTheDocument());
    expect(screen.getByText('Delete')).toBeInTheDocument();
  });

  it('calls onEdit with the network when Edit is clicked in dropdown', async () => {
    const onEdit = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList({ onEdit });

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const desktopTable = document.querySelector('.hidden.md\\:block table');
    const actionButtons = desktopTable!.querySelectorAll('tbody tr:first-child td:last-child button');
    fireEvent.click(actionButtons[actionButtons.length - 1]);

    await waitFor(() => expect(screen.getByText('Edit')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Edit'));

    expect(onEdit).toHaveBeenCalledWith(NET_AVAILABLE);
  });

  it('calls onDelete with network id when Delete is clicked in dropdown', async () => {
    const onDelete = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList({ onDelete });

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const desktopTable = document.querySelector('.hidden.md\\:block table');
    const actionButtons = desktopTable!.querySelectorAll('tbody tr:first-child td:last-child button');
    fireEvent.click(actionButtons[actionButtons.length - 1]);

    await waitFor(() => expect(screen.getByText('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Delete'));

    expect(onDelete).toHaveBeenCalledWith(NET_AVAILABLE.id);
  });

  it('closes dropdown after an action is clicked', async () => {
    const onEdit = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList({ onEdit });

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const desktopTable = document.querySelector('.hidden.md\\:block table');
    const actionButtons = desktopTable!.querySelectorAll('tbody tr:first-child td:last-child button');
    fireEvent.click(actionButtons[actionButtons.length - 1]);

    await waitFor(() => expect(screen.getByText('Edit')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Edit'));

    await waitFor(() => expect(screen.queryByText('Edit')).not.toBeInTheDocument());
  });

  // --------------------------------------------------------------------------
  // Delete permission gating
  // --------------------------------------------------------------------------

  it('does not show Delete option for is_default networks', async () => {
    const onEdit = jest.fn();
    const onDelete = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResponse([NET_DEFAULT]));
    renderList({ onEdit, onDelete });

    await waitFor(() =>
      expect(screen.getAllByText('default-vpc').length).toBeGreaterThan(0),
    );

    const desktopTable = document.querySelector('.hidden.md\\:block table');
    const actionButtons = desktopTable!.querySelectorAll('tbody tr:first-child td:last-child button');
    fireEvent.click(actionButtons[actionButtons.length - 1]);

    // Edit button appears (canUpdate && onEdit), but Delete should NOT appear for default network
    await waitFor(() =>
      expect(screen.getByText('Edit')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Delete')).not.toBeInTheDocument();
  });

  it('does not show Delete option for non-available networks (pending)', async () => {
    const onEdit = jest.fn();
    const onDelete = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResponse([NET_PENDING]));
    renderList({ onEdit, onDelete });

    await waitFor(() =>
      expect(screen.getAllByText('staging-net').length).toBeGreaterThan(0),
    );

    const desktopTable = document.querySelector('.hidden.md\\:block table');
    const actionButtons = desktopTable!.querySelectorAll('tbody tr:first-child td:last-child button');
    fireEvent.click(actionButtons[actionButtons.length - 1]);

    await waitFor(() =>
      expect(screen.getByText('Edit')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Delete')).not.toBeInTheDocument();
  });

  // --------------------------------------------------------------------------
  // Create action in empty state
  // --------------------------------------------------------------------------

  it('shows Create Network button in empty state when onCreate is provided', async () => {
    const onCreate = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResponse([]));
    renderList({ onCreate });

    await waitFor(() =>
      expect(screen.getByText('No networks found')).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: 'Create Network' })).toBeInTheDocument();
  });

  it('calls onCreate when the Create Network empty-state button is clicked', async () => {
    const onCreate = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResponse([]));
    renderList({ onCreate });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Create Network' })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: 'Create Network' }));
    expect(onCreate).toHaveBeenCalledTimes(1);
  });

  it('does NOT show Create Network button when search filter is active', async () => {
    const onCreate = jest.fn();
    // First call (initial load) — returns one network so filters row is rendered
    mockGetNetworks.mockResolvedValueOnce(networksResponse([NET_AVAILABLE]));
    // Second call (after search submit) — returns empty
    mockGetNetworks.mockResolvedValueOnce(networksResponse([]));
    renderList({ onCreate });

    // Wait for initial render with data
    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const input = screen.getByPlaceholderText('Search networks (press Enter)...');
    fireEvent.change(input, { target: { value: 'prod' } });
    fireEvent.submit(input.closest('form')!);

    await waitFor(() => expect(mockGetNetworks).toHaveBeenCalledTimes(2));

    // After empty search result: empty state with "Try adjusting your filters" — no Create button
    await waitFor(() =>
      expect(screen.getByText('No networks found')).toBeInTheDocument(),
    );
    expect(screen.queryByRole('button', { name: 'Create Network' })).not.toBeInTheDocument();
  });

  it('does NOT show Create Network button when statusFilter is not "all"', async () => {
    const onCreate = jest.fn();
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE]));
    renderList({ onCreate });

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    // Filter to 'error' — the available network client-filters out.
    // totalCount is still 1 so no empty state is shown, which means the
    // Create Network button is also not shown (it only appears in the
    // empty-state block which requires totalCount === 0).
    fireEvent.change(screen.getByDisplayValue('All Status'), {
      target: { value: 'error' },
    });

    await waitFor(() =>
      expect(screen.queryByText('production-vpc')).not.toBeInTheDocument(),
    );
    // Create Network button never appears — either in empty state (totalCount > 0)
    // or in the filter row (NetworkList only puts it in emptyState.action)
    expect(screen.queryByRole('button', { name: 'Create Network' })).not.toBeInTheDocument();
  });

  // --------------------------------------------------------------------------
  // Multiple expanded rows
  // --------------------------------------------------------------------------

  it('allows multiple rows to be expanded simultaneously', async () => {
    mockGetNetworks.mockResolvedValue(networksResponse([NET_AVAILABLE, NET_PENDING]));
    renderList();

    await waitFor(() =>
      expect(screen.getAllByText('production-vpc').length).toBeGreaterThan(0),
    );

    const expandBtns = screen.getAllByTitle('Expand details');
    fireEvent.click(expandBtns[0]);
    fireEvent.click(expandBtns[1]);

    // Both detail sections visible — "CIDR Block" label appears in each expanded section
    await waitFor(() => {
      const cidrLabels = screen.getAllByText('CIDR Block');
      expect(cidrLabels.length).toBeGreaterThanOrEqual(2);
    });
  });
});
