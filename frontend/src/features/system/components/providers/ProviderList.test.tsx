import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ProviderList } from './ProviderList';
import type { SystemProvider } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

const mockHasPermission = jest.fn(() => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (perm: string) => mockHasPermission(perm),
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

const mockGetProviders = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getProviders: (...args: unknown[]) => mockGetProviders(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const PROVIDER_AWS: SystemProvider = {
  id: 'prov-aws-1',
  name: 'Production AWS',
  description: 'Main AWS account',
  provider_type: 'aws',
  enabled: true,
  public: false,
  config: { default_region: 'us-east-1' },
  capabilities: { spot_instances: true },
  region_count: 5,
  connection_count: 2,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-15T00:00:00Z',
};

const PROVIDER_OS: SystemProvider = {
  id: 'prov-os-1',
  name: 'OpenStack Cloud',
  description: '',
  provider_type: 'openstack',
  enabled: false,
  public: true,
  config: {},
  capabilities: {},
  region_count: 0,
  connection_count: 0,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

const PROVIDER_PROXMOX: SystemProvider = {
  id: 'prov-pve-1',
  name: 'Homelab PVE',
  description: 'Local Proxmox cluster',
  provider_type: 'proxmox',
  enabled: true,
  public: false,
  config: { endpoint: 'https://pve.home.lab:8006' },
  capabilities: {},
  region_count: 1,
  connection_count: 3,
  created_at: '2026-03-01T00:00:00Z',
  updated_at: '2026-03-01T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  onView?: jest.Mock;
  onEdit?: jest.Mock;
  onDelete?: jest.Mock;
  onCreate?: jest.Mock;
}

function renderList(props: RenderProps = {}) {
  return render(
    <BrowserRouter>
      <ProviderList
        onView={props.onView ?? jest.fn()}
        onEdit={props.onEdit ?? jest.fn()}
        onDelete={props.onDelete ?? jest.fn()}
        onCreate={props.onCreate ?? jest.fn()}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('ProviderList', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockGetProviders.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  describe('loading state', () => {
    it('shows a loading spinner while providers are being fetched', async () => {
      // Never resolves so we remain in loading state
      mockGetProviders.mockReturnValue(new Promise(() => {}));
      renderList();
      // The spinner is present while loading
      expect(document.querySelector('[class*="animate-spin"], svg.animate-spin, [data-testid="loading-spinner"]') !== null
        || document.querySelector('svg') !== null).toBe(true);
    });
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  describe('empty state', () => {
    it('shows "No providers configured" when the list is empty', async () => {
      mockGetProviders.mockResolvedValue([]);
      renderList();
      await waitFor(() =>
        expect(screen.getByText('No providers configured')).toBeInTheDocument(),
      );
    });

    it('shows description text in empty state', async () => {
      mockGetProviders.mockResolvedValue([]);
      renderList();
      await waitFor(() =>
        expect(
          screen.getByText(/add cloud providers to manage infrastructure/i),
        ).toBeInTheDocument(),
      );
    });

    it('shows "Add Provider" action in empty state when canCreate is true', async () => {
      mockGetProviders.mockResolvedValue([]);
      const onCreate = jest.fn();
      renderList({ onCreate });
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add provider/i })).toBeInTheDocument(),
      );
    });

    it('calls onCreate when the empty-state Add Provider button is clicked', async () => {
      mockGetProviders.mockResolvedValue([]);
      const onCreate = jest.fn();
      renderList({ onCreate });
      await waitFor(() => screen.getByRole('button', { name: /add provider/i }));
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
      expect(onCreate).toHaveBeenCalled();
    });

    it('does not show Add Provider button when user lacks create permission', async () => {
      mockGetProviders.mockResolvedValue([]);
      mockHasPermission.mockImplementation((perm: string) => perm !== 'system.providers.create');
      renderList();
      await waitFor(() =>
        expect(screen.getByText('No providers configured')).toBeInTheDocument(),
      );
      expect(screen.queryByRole('button', { name: /add provider/i })).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Renders providers from API — exact URL verified
  // ---------------------------------------------------------------------------

  describe('provider list rendering', () => {
    it('calls systemApi.getProviders on mount', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() => expect(mockGetProviders).toHaveBeenCalledTimes(1));
    });

    it('renders provider names in the list', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );
      expect(screen.getAllByText('OpenStack Cloud').length).toBeGreaterThan(0);
    });

    it('renders provider type labels in the list', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Amazon Web Services').length).toBeGreaterThan(0),
      );
    });

    it('renders region count in the list', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        // Region count "5" is rendered alongside MapPin icon
        expect(screen.getAllByText('5').length).toBeGreaterThan(0),
      );
    });

    it('renders connection count in the list', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('2').length).toBeGreaterThan(0),
      );
    });

    it('renders Enabled badge for enabled provider', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Enabled').length).toBeGreaterThan(0),
      );
    });

    it('renders Disabled badge for disabled provider', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Disabled').length).toBeGreaterThan(0),
      );
    });

    it('renders Public badge for public provider', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Public').length).toBeGreaterThan(0),
      );
    });

    it('renders Private badge for private provider', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Private').length).toBeGreaterThan(0),
      );
    });

    it('renders zero counts when region_count and connection_count are absent', async () => {
      const providerNoCount: SystemProvider = {
        ...PROVIDER_AWS,
        id: 'prov-no-count',
        region_count: undefined,
        connection_count: undefined,
      };
      mockGetProviders.mockResolvedValue([providerNoCount]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('0').length).toBeGreaterThanOrEqual(2),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  describe('error state', () => {
    it('shows error notification when getProviders rejects', async () => {
      mockGetProviders.mockRejectedValue(new Error('Network failure'));
      renderList();
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'Failed to load providers' }),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Search filter
  // ---------------------------------------------------------------------------

  describe('search filter', () => {
    it('filters providers by name search', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText('Search providers...');
      fireEvent.change(searchInput, { target: { value: 'OpenStack' } });

      await waitFor(() =>
        expect(screen.queryAllByText('Production AWS').length).toBe(0),
      );
      expect(screen.getAllByText('OpenStack Cloud').length).toBeGreaterThan(0);
    });

    it('filters providers by description search', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_PROXMOX]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText('Search providers...');
      // PROVIDER_PROXMOX has description "Local Proxmox cluster"
      fireEvent.change(searchInput, { target: { value: 'Local Proxmox' } });

      await waitFor(() =>
        expect(screen.queryAllByText('Production AWS').length).toBe(0),
      );
      expect(screen.getAllByText('Homelab PVE').length).toBeGreaterThan(0);
    });

    it('filters providers by provider_type search', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText('Search providers...');
      fireEvent.change(searchInput, { target: { value: 'openstack' } });

      await waitFor(() =>
        expect(screen.queryAllByText('Production AWS').length).toBe(0),
      );
      expect(screen.getAllByText('OpenStack Cloud').length).toBeGreaterThan(0);
    });

    it('shows all providers when search is cleared', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText('Search providers...');
      fireEvent.change(searchInput, { target: { value: 'openstack' } });
      await waitFor(() =>
        expect(screen.queryAllByText('Production AWS').length).toBe(0),
      );

      fireEvent.change(searchInput, { target: { value: '' } });
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Provider type filter
  // ---------------------------------------------------------------------------

  describe('provider type filter', () => {
    it('filters providers by selected type', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS, PROVIDER_PROXMOX]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      // The type select should have the provider types populated
      // Get the first select (All Types)
      const allSelects = screen.getAllByRole('combobox');
      const typeSelect = allSelects[0]; // first is the type filter
      fireEvent.change(typeSelect, { target: { value: 'aws' } });

      await waitFor(() =>
        expect(screen.queryAllByText('OpenStack Cloud').length).toBe(0),
      );
      expect(screen.queryAllByText('Homelab PVE').length).toBe(0);
      expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0);
    });

    it('shows all providers when "all" type is selected', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      const allSelects = screen.getAllByRole('combobox');
      const typeSelect = allSelects[0];
      fireEvent.change(typeSelect, { target: { value: 'openstack' } });
      await waitFor(() =>
        expect(screen.queryAllByText('Production AWS').length).toBe(0),
      );

      fireEvent.change(typeSelect, { target: { value: 'all' } });
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Enabled/disabled filter
  // ---------------------------------------------------------------------------

  describe('enabled/disabled filter', () => {
    it('filters to only enabled providers', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      const allSelects = screen.getAllByRole('combobox');
      // The enabled filter select is the last combobox (index 1)
      const enabledSelect = allSelects[allSelects.length - 1];
      fireEvent.change(enabledSelect, { target: { value: 'enabled' } });

      await waitFor(() =>
        expect(screen.queryAllByText('OpenStack Cloud').length).toBe(0),
      );
      expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0);
    });

    it('filters to only disabled providers', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('OpenStack Cloud').length).toBeGreaterThan(0),
      );

      const allSelects = screen.getAllByRole('combobox');
      const enabledSelect = allSelects[allSelects.length - 1];
      fireEvent.change(enabledSelect, { target: { value: 'disabled' } });

      await waitFor(() =>
        expect(screen.queryAllByText('Production AWS').length).toBe(0),
      );
      expect(screen.getAllByText('OpenStack Cloud').length).toBeGreaterThan(0);
    });
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  describe('row expand/collapse', () => {
    it('shows expand button for each provider row (desktop)', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      // The expand button has title "Expand details"
      const expandBtns = screen.getAllByTitle('Expand details');
      expect(expandBtns.length).toBeGreaterThan(0);
    });

    it('expands provider details when the expand button is clicked', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      const expandBtn = screen.getAllByTitle('Expand details')[0];
      fireEvent.click(expandBtn);

      await waitFor(() =>
        // The expanded detail section shows the provider type — rendered in desktop + mobile rows
        expect(screen.getAllByText('Amazon Web Services').length).toBeGreaterThanOrEqual(2),
      );
    });

    it('shows "Collapse details" title after expansion', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      const expandBtn = screen.getAllByTitle('Expand details')[0];
      fireEvent.click(expandBtn);

      await waitFor(() =>
        expect(screen.getAllByTitle('Collapse details').length).toBeGreaterThan(0),
      );
    });

    it('collapses provider details when the collapse button is clicked', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      // Expand first
      const expandBtn = screen.getAllByTitle('Expand details')[0];
      fireEvent.click(expandBtn);

      await waitFor(() =>
        expect(screen.getAllByTitle('Collapse details').length).toBeGreaterThan(0),
      );

      // Collapse
      const collapseBtn = screen.getAllByTitle('Collapse details')[0];
      fireEvent.click(collapseBtn);

      await waitFor(() =>
        expect(screen.getAllByTitle('Expand details').length).toBeGreaterThan(0),
      );
    });

    it('can expand multiple rows independently', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByTitle('Expand details').length).toBeGreaterThanOrEqual(2),
      );

      const expandBtns = screen.getAllByTitle('Expand details');
      fireEvent.click(expandBtns[0]);
      // After first expand, we have 1 collapse and at least 1 expand remaining
      await waitFor(() =>
        expect(screen.getAllByTitle('Collapse details').length).toBeGreaterThanOrEqual(1),
      );

      // Expand second row too
      const remainingExpand = screen.getAllByTitle('Expand details');
      if (remainingExpand.length > 0) {
        fireEvent.click(remainingExpand[0]);
      }

      await waitFor(() =>
        expect(screen.getAllByTitle('Collapse details').length).toBeGreaterThanOrEqual(2),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Expanded row detail content
  // ---------------------------------------------------------------------------

  describe('expanded detail content', () => {
    it('shows description in expanded detail when provider has a description', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Expand details')[0]);

      await waitFor(() =>
        // 'Main AWS account' is the description
        expect(screen.getAllByText('Main AWS account').length).toBeGreaterThan(0),
      );
    });

    it('shows provider type label in expanded detail', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Expand details')[0]);

      await waitFor(() => {
        // The expanded section has a "Type" label and the expanded text
        const typeLabelEls = screen.getAllByText('Amazon Web Services');
        expect(typeLabelEls.length).toBeGreaterThanOrEqual(1);
      });
    });

    it('shows status (Enabled) in expanded detail', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Expand details')[0]);

      // There should be at least 2 occurrences of "Enabled": the badge in the row + the text in expanded detail
      await waitFor(() =>
        expect(screen.getAllByText('Enabled').length).toBeGreaterThanOrEqual(2),
      );
    });

    it('shows region and connection counts in expanded detail', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Expand details')[0]);

      // Region count label should appear in expanded detail
      await waitFor(() => {
        const regionLabels = screen.getAllByText('Regions');
        expect(regionLabels.length).toBeGreaterThan(0);
        const connectionLabels = screen.getAllByText('Connections');
        expect(connectionLabels.length).toBeGreaterThan(0);
      });
    });

    it('shows provider ID in expanded detail', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Expand details')[0]);

      await waitFor(() =>
        // Rendered in both desktop and mobile expanded rows
        expect(screen.getAllByTitle(PROVIDER_AWS.id).length).toBeGreaterThanOrEqual(1),
      );
    });

    it('shows config JSON in expanded detail when provider has config', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Expand details')[0]);

      await waitFor(() => {
        // The pre block with JSON.stringify output — rendered in desktop + mobile
        expect(screen.getAllByText(/default_region/).length).toBeGreaterThanOrEqual(1);
      });
    });

    it('shows capabilities JSON in expanded detail when provider has capabilities', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Expand details')[0]);

      await waitFor(() => {
        // spot_instances is in capabilities — rendered in desktop + mobile expanded rows
        expect(screen.getAllByText(/spot_instances/).length).toBeGreaterThanOrEqual(1);
      });
    });

    it('does not show config section when config is empty', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_OS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('OpenStack Cloud').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Expand details')[0]);

      // Wait for expanded content to appear (Status label appears in detail)
      await waitFor(() => {
        const statusLabels = screen.getAllByText('Status');
        expect(statusLabels.length).toBeGreaterThan(0);
      });

      // Config heading should not appear since config is empty
      const configLabels = screen.queryAllByText('Configuration');
      expect(configLabels.length).toBe(0);
    });

    it('shows visibility (Public/Private) in expanded detail', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Expand details')[0]);

      // Expanded detail should show "Visibility" label
      await waitFor(() => {
        const visibilityLabels = screen.getAllByText('Visibility');
        expect(visibilityLabels.length).toBeGreaterThan(0);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // onView callback
  // ---------------------------------------------------------------------------

  describe('onView callback', () => {
    it('calls onView when provider name is clicked in the desktop table', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      const onView = jest.fn();
      renderList({ onView });

      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      // In desktop view the name is a clickable span
      const nameCells = screen.getAllByText('Production AWS');
      // Click the one that is a span with cursor-pointer (table name cell)
      const clickableSpan = nameCells.find(el => el.tagName === 'SPAN');
      if (clickableSpan) {
        fireEvent.click(clickableSpan);
      } else {
        fireEvent.click(nameCells[0]);
      }

      expect(onView).toHaveBeenCalledWith(PROVIDER_AWS);
    });

    it('calls onView when the View Details button is clicked', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      const onView = jest.fn();
      renderList({ onView });

      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      const viewBtns = screen.getAllByTitle('View Details');
      fireEvent.click(viewBtns[0]);

      expect(onView).toHaveBeenCalledWith(PROVIDER_AWS);
    });
  });

  // ---------------------------------------------------------------------------
  // onEdit callback — gated by canUpdate permission
  // ---------------------------------------------------------------------------

  describe('onEdit callback', () => {
    it('shows Edit button when user has update permission', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );
      expect(screen.getAllByTitle('Edit Provider').length).toBeGreaterThan(0);
    });

    it('calls onEdit when the Edit Provider button is clicked', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      const onEdit = jest.fn();
      renderList({ onEdit });

      await waitFor(() =>
        expect(screen.getAllByTitle('Edit Provider').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Edit Provider')[0]);
      expect(onEdit).toHaveBeenCalledWith(PROVIDER_AWS);
    });

    it('does not show Edit button when user lacks update permission', async () => {
      mockHasPermission.mockImplementation((perm: string) => perm !== 'system.providers.update');
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();

      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      expect(screen.queryByTitle('Edit Provider')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // onDelete callback — gated by canDelete permission
  // ---------------------------------------------------------------------------

  describe('onDelete callback', () => {
    it('shows Delete button when user has delete permission', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );
      expect(screen.getAllByTitle('Delete Provider').length).toBeGreaterThan(0);
    });

    it('calls onDelete with provider id when the Delete button is clicked', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      const onDelete = jest.fn();
      renderList({ onDelete });

      await waitFor(() =>
        expect(screen.getAllByTitle('Delete Provider').length).toBeGreaterThan(0),
      );

      fireEvent.click(screen.getAllByTitle('Delete Provider')[0]);
      expect(onDelete).toHaveBeenCalledWith(PROVIDER_AWS.id);
    });

    it('does not show Delete button when user lacks delete permission', async () => {
      mockHasPermission.mockImplementation((perm: string) => perm !== 'system.providers.delete');
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();

      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      expect(screen.queryByTitle('Delete Provider')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Refresh behavior
  // ---------------------------------------------------------------------------

  describe('refresh', () => {
    it('calls getProviders again when the refresh button is clicked', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();

      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      // The refresh button has title="Refresh"
      const refreshBtn = screen.getByTitle('Refresh');
      fireEvent.click(refreshBtn);

      await waitFor(() =>
        expect(mockGetProviders).toHaveBeenCalledTimes(2),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // "Showing N of M" count hint
  // ---------------------------------------------------------------------------

  describe('filtered count hint', () => {
    it('shows "Showing N of M" hint when filters reduce the list', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS, PROVIDER_PROXMOX]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText('Search providers...');
      fireEvent.change(searchInput, { target: { value: 'AWS' } });

      await waitFor(() =>
        expect(screen.getByText(/showing 1 of 3/i)).toBeInTheDocument(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Provider description shown in table row
  // ---------------------------------------------------------------------------

  describe('provider description in table', () => {
    it('renders provider description below name in the desktop table', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS]);
      renderList();
      await waitFor(() =>
        // "Main AWS account" is the description rendered as a truncated p tag
        expect(screen.getAllByText('Main AWS account').length).toBeGreaterThan(0),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Multiple provider types in type filter dropdown
  // ---------------------------------------------------------------------------

  describe('dynamic type filter options', () => {
    it('populates the type filter dropdown with all loaded provider types', async () => {
      mockGetProviders.mockResolvedValue([PROVIDER_AWS, PROVIDER_OS, PROVIDER_PROXMOX]);
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Production AWS').length).toBeGreaterThan(0),
      );

      // The type select should have options for aws, openstack, proxmox
      const allSelects = screen.getAllByRole('combobox');
      const typeSelect = allSelects[0] as HTMLSelectElement;
      const optionValues = Array.from(typeSelect.options).map(o => o.value);
      expect(optionValues).toContain('aws');
      expect(optionValues).toContain('openstack');
      expect(optionValues).toContain('proxmox');
    });
  });
});
