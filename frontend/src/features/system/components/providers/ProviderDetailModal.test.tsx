import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ProviderDetailModal } from './ProviderDetailModal';
import type { SystemProvider, SystemProviderRegion, SystemProviderConnection } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGetProvider = jest.fn();
const mockGetProviderRegions = jest.fn();
const mockGetProviderConnections = jest.fn();
const mockDeleteProviderRegion = jest.fn();
const mockDeleteProviderConnection = jest.fn();
const mockTestProviderConnection = jest.fn();
const mockSyncProviderConnectionCatalog = jest.fn();
const mockGetProviderInstanceTypes = jest.fn();
const mockDeleteProviderInstanceType = jest.fn();
const mockGetProviderAvailabilityZones = jest.fn();
const mockDeleteProviderAvailabilityZone = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getProvider: (...args: unknown[]) => mockGetProvider(...args),
    getProviderRegions: (...args: unknown[]) => mockGetProviderRegions(...args),
    getProviderConnections: (...args: unknown[]) => mockGetProviderConnections(...args),
    deleteProviderRegion: (...args: unknown[]) => mockDeleteProviderRegion(...args),
    deleteProviderConnection: (...args: unknown[]) => mockDeleteProviderConnection(...args),
    testProviderConnection: (...args: unknown[]) => mockTestProviderConnection(...args),
    syncProviderConnectionCatalog: (...args: unknown[]) =>
      mockSyncProviderConnectionCatalog(...args),
    getProviderInstanceTypesPage: (...args: unknown[]) =>
      mockGetProviderInstanceTypes(...args),
    deleteProviderInstanceType: (...args: unknown[]) => mockDeleteProviderInstanceType(...args),
    getProviderAvailabilityZonesPage: (...args: unknown[]) =>
      mockGetProviderAvailabilityZones(...args),
    deleteProviderAvailabilityZone: (...args: unknown[]) =>
      mockDeleteProviderAvailabilityZone(...args),
  },
}));

jest.mock('./InstanceTypeFormModal', () => ({
  InstanceTypeFormModal: ({ isOpen, onClose, onSaved, instanceType, manualOverride }: {
    isOpen: boolean;
    onClose: () => void;
    onSaved?: () => void;
    instanceType: { id: string; name: string } | null;
    manualOverride?: boolean;
  }) =>
    isOpen ? (
      <div data-testid="instance-type-form-modal" data-manual-override={String(!!manualOverride)}>
        <span data-testid="instance-type-form-subject">{instanceType?.name ?? 'new'}</span>
        <button onClick={onClose}>Close Instance Type Form</button>
        <button onClick={onSaved}>Save Instance Type</button>
      </div>
    ) : null,
}));

jest.mock('./AvailabilityZoneFormModal', () => ({
  AvailabilityZoneFormModal: ({ isOpen, onClose, onSaved, regionId, zone, manualOverride }: {
    isOpen: boolean;
    onClose: () => void;
    onSaved?: () => void;
    regionId: string;
    zone: { id: string; name: string } | null;
    manualOverride?: boolean;
  }) =>
    isOpen ? (
      <div data-testid="zone-form-modal" data-manual-override={String(!!manualOverride)}>
        <span data-testid="zone-form-region">{regionId}</span>
        <span data-testid="zone-form-subject">{zone?.name ?? 'new'}</span>
        <button onClick={onClose}>Close Zone Form</button>
        <button onClick={onSaved}>Save Zone</button>
      </div>
    ) : null,
}));

jest.mock('@/shared/components/ui/Button', () => ({
  Button: ({ children, onClick, disabled, variant, size, title, className }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    variant?: string;
    size?: string;
    title?: string;
    className?: string;
  }) => (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      className={className}
      data-variant={variant}
      data-size={size}
    >
      {children}
    </button>
  ),
}));

jest.mock('@/shared/components/ui/Badge', () => ({
  Badge: ({ children, variant, size }: { children: React.ReactNode; variant?: string; size?: string }) => (
    <span data-variant={variant} data-size={size}>{children}</span>
  ),
}));

jest.mock('@/shared/components/ui/LoadingSpinner', () => ({
  LoadingSpinner: ({ size }: { size?: string }) => (
    <div data-testid="loading-spinner" data-size={size} />
  ),
}));

jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ type, id, label, className }: { type: string; id: string; label: string; className?: string }) => (
    <a href={`/${type}/${id}`} className={className}>{label}</a>
  ),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

let mockHasPermission = jest.fn(() => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (...args: unknown[]) => mockHasPermission(...args),
  }),
}));

// Child form modals — stub them out; we test ProviderDetailModal in isolation.
jest.mock('./RegionFormModal', () => ({
  RegionFormModal: ({ isOpen, onClose, onRegionSaved, providerId, region }: {
    isOpen: boolean;
    onClose: () => void;
    onRegionSaved?: () => void;
    providerId: string;
    region: unknown;
  }) =>
    isOpen ? (
      <div data-testid="region-form-modal">
        <button onClick={onClose}>Close Region Form</button>
        <button onClick={onRegionSaved}>Save Region</button>
      </div>
    ) : null,
}));

jest.mock('./ConnectionFormModal', () => ({
  ConnectionFormModal: ({ isOpen, onClose, onConnectionSaved, providerId, connection }: {
    isOpen: boolean;
    onClose: () => void;
    onConnectionSaved?: () => void;
    providerId: string;
    connection: unknown;
  }) =>
    isOpen ? (
      <div data-testid="connection-form-modal">
        <button onClick={onClose}>Close Connection Form</button>
        <button onClick={onConnectionSaved}>Save Connection</button>
      </div>
    ) : null,
}));

// =============================================================================
// Fixtures
// =============================================================================

const PROVIDER: SystemProvider = {
  id: 'prov-1',
  name: 'My AWS Provider',
  description: 'Primary AWS account',
  provider_type: 'aws',
  enabled: true,
  public: false,
  config: { region: 'us-east-1' },
  capabilities: { spot: true },
  region_count: 2,
  connection_count: 1,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-03-01T00:00:00Z',
};

const PROVIDER_OPENSTACK: SystemProvider = {
  id: 'prov-2',
  name: 'OpenStack Cluster',
  description: undefined,
  provider_type: 'openstack',
  enabled: false,
  public: true,
  config: {},
  capabilities: {},
  region_count: 0,
  connection_count: 0,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const REGION_A: SystemProviderRegion = {
  id: 'reg-a',
  name: 'us-east-1',
  description: 'US East Virginia',
  endpoint_url: 'https://ec2.us-east-1.amazonaws.com',
  region_code: 'use1',
  capabilities: {},
  provider_id: 'prov-1',
  provider_name: 'My AWS Provider',
  zone_count: 3,
  instance_type_count: 42,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const REGION_B: SystemProviderRegion = {
  id: 'reg-b',
  name: 'eu-west-1',
  description: undefined,
  endpoint_url: undefined,
  region_code: 'euw1',
  capabilities: {},
  provider_id: 'prov-1',
  provider_name: 'My AWS Provider',
  zone_count: 2,
  instance_type_count: 30,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CONNECTION_A: SystemProviderConnection = {
  id: 'conn-a',
  name: 'prod-creds',
  description: 'Production IAM credentials',
  endpoint_url: 'https://aws.example.com',
  config: {},
  provider_id: 'prov-1',
  provider_name: 'My AWS Provider',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CONNECTION_OTHER: SystemProviderConnection = {
  id: 'conn-other',
  name: 'other-creds',
  description: undefined,
  endpoint_url: undefined,
  config: {},
  provider_id: 'prov-99',
  provider_name: 'Other Provider',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  providerId?: string | null;
  isOpen?: boolean;
  onClose?: () => void;
  onEdit?: (p: SystemProvider) => void;
}

function renderModal({
  providerId = 'prov-1',
  isOpen = true,
  onClose = jest.fn(),
  onEdit,
}: RenderProps = {}) {
  return render(
    <BrowserRouter>
      <ProviderDetailModal
        providerId={providerId}
        isOpen={isOpen}
        onClose={onClose}
        onEdit={onEdit}
      />
    </BrowserRouter>,
  );
}

function setupHappyPath(overrides: {
  provider?: SystemProvider;
  regions?: SystemProviderRegion[];
  connections?: SystemProviderConnection[];
} = {}) {
  const provider = overrides.provider ?? PROVIDER;
  const regions = overrides.regions ?? [REGION_A, REGION_B];
  const connections = overrides.connections ?? [CONNECTION_A, CONNECTION_OTHER];

  mockGetProvider.mockResolvedValue(provider);
  mockGetProviderRegions.mockResolvedValue(regions);
  // getProviderConnections returns ALL connections; the component filters by provider_id
  mockGetProviderConnections.mockResolvedValue(connections);
}

/**
 * Wait for the modal to finish loading by expecting the h2 heading to show
 * the provider name (not "Loading..."). The provider name also appears in the
 * info-tab body so we query the heading role specifically to avoid
 * "Found multiple elements" errors.
 */
async function waitForLoaded(providerName = 'My AWS Provider') {
  await waitFor(() =>
    expect(screen.getByRole('heading', { name: providerName })).toBeInTheDocument(),
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('ProviderDetailModal', () => {
  beforeEach(() => {
    mockGetProvider.mockReset();
    mockGetProviderRegions.mockReset();
    mockGetProviderConnections.mockReset();
    mockDeleteProviderRegion.mockReset();
    mockDeleteProviderConnection.mockReset();
    mockTestProviderConnection.mockReset();
    mockSyncProviderConnectionCatalog.mockReset();
    mockGetProviderInstanceTypes.mockReset();
    mockGetProviderInstanceTypes.mockResolvedValue({ instanceTypes: [], total: 0 });
    mockDeleteProviderInstanceType.mockReset();
    mockGetProviderAvailabilityZones.mockReset();
    mockGetProviderAvailabilityZones.mockResolvedValue({ zones: [], total: 0 });
    mockDeleteProviderAvailabilityZone.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission = jest.fn(() => true);
  });

  // -------------------------------------------------------------------------
  // Render gate
  // -------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    const { container } = renderModal({ isOpen: false });
    expect(container.firstChild).toBeNull();
  });

  it('does not fetch when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(mockGetProvider).not.toHaveBeenCalled();
  });

  // -------------------------------------------------------------------------
  // Loading state
  // -------------------------------------------------------------------------

  it('shows a loading spinner while data is being fetched', async () => {
    // Never resolve so we stay in loading state
    mockGetProvider.mockReturnValue(new Promise(() => undefined));
    mockGetProviderRegions.mockReturnValue(new Promise(() => undefined));
    mockGetProviderConnections.mockReturnValue(new Promise(() => undefined));

    renderModal();

    expect(screen.getByTestId('loading-spinner')).toBeInTheDocument();
    expect(screen.getByText('Loading...')).toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // Successful load — initial API calls
  // -------------------------------------------------------------------------

  it('fetches provider, regions, and connections on open', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();

    expect(mockGetProvider).toHaveBeenCalledWith('prov-1');
    expect(mockGetProviderRegions).toHaveBeenCalledWith('prov-1');
    expect(mockGetProviderConnections).toHaveBeenCalled();
  });

  it('resets to the info tab and reloads when providerId changes', async () => {
    setupHappyPath({ provider: PROVIDER });
    const { rerender } = renderModal({ providerId: 'prov-1' });

    await waitForLoaded();

    // Navigate to regions tab
    fireEvent.click(screen.getByText('Regions'));
    expect(screen.getByText('Add Region')).toBeInTheDocument();

    // Switch to new provider
    setupHappyPath({ provider: PROVIDER_OPENSTACK, regions: [], connections: [] });
    rerender(
      <BrowserRouter>
        <ProviderDetailModal
          providerId="prov-2"
          isOpen={true}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );

    await waitForLoaded('OpenStack Cluster');
    // Should reset back to info tab
    expect(screen.getByText('Name')).toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // Error state
  // -------------------------------------------------------------------------

  it('shows error message when data fetching fails', async () => {
    mockGetProvider.mockRejectedValue(new Error('Network error'));
    mockGetProviderRegions.mockRejectedValue(new Error('Network error'));
    mockGetProviderConnections.mockRejectedValue(new Error('Network error'));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Failed to load provider details')).toBeInTheDocument(),
    );
  });

  // -------------------------------------------------------------------------
  // Header
  // -------------------------------------------------------------------------

  it('shows provider name and type label in the header after load', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    // 'Amazon Web Services' appears in both the header subtitle and the info-tab
    // Provider Type field, so at least one instance must be present.
    expect(screen.getAllByText('Amazon Web Services').length).toBeGreaterThan(0);
  });

  it('displays the Edit button when onEdit is provided', async () => {
    setupHappyPath();
    const onEdit = jest.fn();
    renderModal({ onEdit });

    await waitForLoaded();
    expect(screen.getByRole('button', { name: 'Edit' })).toBeInTheDocument();
  });

  it('calls onEdit with the provider when Edit is clicked', async () => {
    setupHappyPath();
    const onEdit = jest.fn();
    renderModal({ onEdit });

    await waitForLoaded();
    fireEvent.click(screen.getByRole('button', { name: 'Edit' }));

    expect(onEdit).toHaveBeenCalledWith(PROVIDER);
  });

  it('does not show the Edit button when onEdit is not provided', async () => {
    setupHappyPath();
    renderModal({ onEdit: undefined });

    await waitForLoaded();
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
  });

  it('calls onClose when the X button is clicked', async () => {
    setupHappyPath();
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitForLoaded();
    // X button has no text, find via the Close button in footer
    const closeBtn = screen.getByRole('button', { name: 'Close' });
    fireEvent.click(closeBtn);

    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose when the backdrop is clicked', async () => {
    setupHappyPath();
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitForLoaded();

    // The core Modal dismisses on a click that lands on its positioning
    // container, which is what a click outside the panel resolves to.
    const overlay = document.querySelector('[class*="justify-center"]');
    expect(overlay).not.toBeNull();
    fireEvent.click(overlay!);

    expect(onClose).toHaveBeenCalled();
  });

  // -------------------------------------------------------------------------
  // Info tab
  // -------------------------------------------------------------------------

  it('renders provider info fields on the info tab by default', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();

    expect(screen.getByText('Primary AWS account')).toBeInTheDocument();
    // 'Amazon Web Services' appears in the header subtitle and info-tab Provider Type
    expect(screen.getAllByText('Amazon Web Services').length).toBeGreaterThan(0);
    expect(screen.getByText('2 regions')).toBeInTheDocument();
    expect(screen.getByText('1 connections')).toBeInTheDocument();
  });

  it('shows Enabled status badge for an enabled provider', async () => {
    setupHappyPath();
    renderModal();

    await waitFor(() => expect(screen.getByText('Enabled')).toBeInTheDocument());
  });

  it('shows Disabled status for a disabled provider', async () => {
    setupHappyPath({ provider: PROVIDER_OPENSTACK, regions: [], connections: [] });
    renderModal({ providerId: 'prov-2' });

    await waitFor(() => expect(screen.getByText('Disabled')).toBeInTheDocument());
  });

  it('shows Private for a private provider', async () => {
    setupHappyPath();
    renderModal();
    await waitFor(() => expect(screen.getByText('Private')).toBeInTheDocument());
  });

  it('shows Public for a public provider', async () => {
    setupHappyPath({ provider: PROVIDER_OPENSTACK, regions: [], connections: [] });
    renderModal({ providerId: 'prov-2' });
    await waitFor(() => expect(screen.getByText('Public')).toBeInTheDocument());
  });

  it('shows description fallback dash when description is absent', async () => {
    setupHappyPath({ provider: PROVIDER_OPENSTACK, regions: [], connections: [] });
    renderModal({ providerId: 'prov-2' });

    await waitForLoaded('OpenStack Cluster');
    expect(screen.getByText('—')).toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // Tab navigation
  // -------------------------------------------------------------------------

  it('shows tabs for Information, Regions, Connections, and Configuration', async () => {
    setupHappyPath();
    renderModal();

    await waitFor(() => expect(screen.getByText('Information')).toBeInTheDocument());
    expect(screen.getByText('Regions')).toBeInTheDocument();
    expect(screen.getByText('Connections')).toBeInTheDocument();
    expect(screen.getByText('Configuration')).toBeInTheDocument();
  });

  it('switches to the Regions tab when clicked', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    expect(screen.getByText('Add Region')).toBeInTheDocument();
    expect(screen.getByText('us-east-1')).toBeInTheDocument();
  });

  it('switches to the Connections tab when clicked', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    expect(screen.getByText('Add Connection')).toBeInTheDocument();
    expect(screen.getByText('prod-creds')).toBeInTheDocument();
  });

  it('switches to the Configuration tab when clicked', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    // Click the tab button by role to avoid ambiguity with the tab content heading
    const configTab = screen.getAllByText('Configuration').find(el => el.closest('button') !== null);
    expect(configTab).toBeTruthy();
    fireEvent.click(configTab!);

    // Config and Capabilities headers appear in the content area
    expect(screen.getByText('Capabilities')).toBeInTheDocument();
    // JSON content rendered in pre block
    expect(screen.getByText(/"region"/)).toBeInTheDocument();
  });

  it('shows count badges on Regions and Connections tabs', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();

    // Regions has 2, connections filtered to prov-1 = 1
    const regionsTab = screen.getByText('Regions').closest('button')!;
    expect(within(regionsTab).getByText('2')).toBeInTheDocument();

    const connectionsTab = screen.getByText('Connections').closest('button')!;
    expect(within(connectionsTab).getByText('1')).toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // Regions tab
  // -------------------------------------------------------------------------

  it('filters connections to only those belonging to the current provider', async () => {
    setupHappyPath({ connections: [CONNECTION_A, CONNECTION_OTHER] });
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    // Only CONNECTION_A has provider_id === 'prov-1'
    expect(screen.getByText('prod-creds')).toBeInTheDocument();
    expect(screen.queryByText('other-creds')).not.toBeInTheDocument();
  });

  it('renders region list with name, code, and endpoint', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    expect(screen.getByText('us-east-1')).toBeInTheDocument();
    expect(screen.getByText('use1')).toBeInTheDocument();
    expect(screen.getByText('https://ec2.us-east-1.amazonaws.com')).toBeInTheDocument();
    expect(screen.getByText(/3 zones/)).toBeInTheDocument();
  });

  it('shows empty state when no regions exist', async () => {
    setupHappyPath({ regions: [] });
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    expect(screen.getByText('No regions configured')).toBeInTheDocument();
  });

  it('shows Add Region button when user has system.regions.create permission', async () => {
    setupHappyPath({ regions: [] });
    mockHasPermission = jest.fn((perm: string) => perm === 'system.regions.create');
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    expect(screen.getByText('Add Region')).toBeInTheDocument();
  });

  it('hides Add Region button without system.regions.create permission', async () => {
    setupHappyPath({ regions: [] });
    mockHasPermission = jest.fn(() => false);
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    expect(screen.queryByText('Add Region')).not.toBeInTheDocument();
  });

  it('opens the RegionFormModal (create mode) when Add Region is clicked', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));
    fireEvent.click(screen.getByText('Add Region'));

    expect(screen.getByTestId('region-form-modal')).toBeInTheDocument();
  });

  it('opens the RegionFormModal (edit mode) when Edit Region is clicked', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    // Find the edit button by title in the region row
    const editButtons = screen.getAllByTitle('Edit region');
    fireEvent.click(editButtons[0]);

    expect(screen.getByTestId('region-form-modal')).toBeInTheDocument();
  });

  it('closes RegionFormModal when onClose is triggered', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));
    fireEvent.click(screen.getByText('Add Region'));

    expect(screen.getByTestId('region-form-modal')).toBeInTheDocument();
    fireEvent.click(screen.getByText('Close Region Form'));

    expect(screen.queryByTestId('region-form-modal')).not.toBeInTheDocument();
  });

  it('refreshes data after region save', async () => {
    setupHappyPath();
    mockGetProviderRegions.mockResolvedValue([REGION_A]);
    mockGetProviderConnections.mockResolvedValue([CONNECTION_A]);
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));
    fireEvent.click(screen.getByText('Add Region'));

    const callsBefore = mockGetProviderRegions.mock.calls.length;
    fireEvent.click(screen.getByText('Save Region'));

    await waitFor(() =>
      expect(mockGetProviderRegions.mock.calls.length).toBeGreaterThan(callsBefore),
    );
  });

  it('shows delete region confirmation dialog when delete is clicked', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    const deleteButtons = screen.getAllByTitle('Delete region');
    fireEvent.click(deleteButtons[0]);

    // Both the heading and the danger button say "Delete Region"
    expect(screen.getAllByText('Delete Region').length).toBeGreaterThan(0);
    expect(
      screen.getByText(/Are you sure you want to delete the region "us-east-1"/),
    ).toBeInTheDocument();
  });

  it('cancels region delete confirmation without calling API', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    const deleteButtons = screen.getAllByTitle('Delete region');
    fireEvent.click(deleteButtons[0]);

    // Click Cancel in the confirmation dialog
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(mockDeleteProviderRegion).not.toHaveBeenCalled();
    expect(screen.queryByText('Delete Region')).not.toBeInTheDocument();
  });

  it('calls deleteProviderRegion with correct providerId and regionId on confirm', async () => {
    // Initial load returns both regions; after delete only REGION_B remains
    mockGetProvider.mockResolvedValue(PROVIDER);
    mockGetProviderRegions
      .mockResolvedValueOnce([REGION_A, REGION_B]) // initial load
      .mockResolvedValueOnce([REGION_B]);           // after delete refresh
    mockGetProviderConnections
      .mockResolvedValueOnce([CONNECTION_A])
      .mockResolvedValueOnce([CONNECTION_A]);
    mockDeleteProviderRegion.mockResolvedValue(undefined);

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    const deleteButtons = screen.getAllByTitle('Delete region');
    fireEvent.click(deleteButtons[0]); // first region = reg-a

    fireEvent.click(screen.getByRole('button', { name: 'Delete Region' }));

    await waitFor(() =>
      expect(mockDeleteProviderRegion).toHaveBeenCalledWith('prov-1', 'reg-a'),
    );
  });

  it('shows success notification after region delete', async () => {
    mockGetProvider.mockResolvedValue(PROVIDER);
    mockGetProviderRegions
      .mockResolvedValueOnce([REGION_A]) // initial load — only one region so deleteButtons[0] = reg-a
      .mockResolvedValueOnce([]);        // after delete
    mockGetProviderConnections
      .mockResolvedValueOnce([CONNECTION_A])
      .mockResolvedValueOnce([]);
    mockDeleteProviderRegion.mockResolvedValue(undefined);

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    const deleteButtons = screen.getAllByTitle('Delete region');
    fireEvent.click(deleteButtons[0]);
    fireEvent.click(screen.getByRole('button', { name: 'Delete Region' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Region "us-east-1" deleted successfully',
      }),
    );
  });

  it('shows error notification when region delete fails', async () => {
    setupHappyPath();
    mockDeleteProviderRegion.mockRejectedValue(new Error('Delete failed'));

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    const deleteButtons = screen.getAllByTitle('Delete region');
    fireEvent.click(deleteButtons[0]);
    fireEvent.click(screen.getByRole('button', { name: 'Delete Region' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete region: Delete failed',
      }),
    );
  });

  it('hides Edit and Delete region buttons when permissions are absent', async () => {
    setupHappyPath();
    mockHasPermission = jest.fn((perm: string) => {
      // Allow everything except region manage/delete
      return perm !== 'system.regions.create' && perm !== 'system.regions.delete';
    });
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));

    expect(screen.queryByTitle('Edit region')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Delete region')).not.toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // Connections tab
  // -------------------------------------------------------------------------

  it('renders connection list with name and endpoint', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    expect(screen.getByText('prod-creds')).toBeInTheDocument();
    expect(screen.getByText('https://aws.example.com')).toBeInTheDocument();
  });

  it('shows empty state when no connections exist for the provider', async () => {
    setupHappyPath({ connections: [] });
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    expect(screen.getByText('No connections configured')).toBeInTheDocument();
  });

  it('shows Add Connection button with system.connections.create permission', async () => {
    setupHappyPath();
    mockHasPermission = jest.fn((perm: string) => perm === 'system.connections.create');
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    expect(screen.getByText('Add Connection')).toBeInTheDocument();
  });

  it('opens ConnectionFormModal in create mode when Add Connection is clicked', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByText('Add Connection'));

    expect(screen.getByTestId('connection-form-modal')).toBeInTheDocument();
  });

  it('opens ConnectionFormModal in edit mode when Edit Connection is clicked', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    fireEvent.click(screen.getByTitle('Edit connection'));

    expect(screen.getByTestId('connection-form-modal')).toBeInTheDocument();
  });

  it('closes ConnectionFormModal when onClose is triggered', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByText('Add Connection'));

    expect(screen.getByTestId('connection-form-modal')).toBeInTheDocument();
    fireEvent.click(screen.getByText('Close Connection Form'));

    expect(screen.queryByTestId('connection-form-modal')).not.toBeInTheDocument();
  });

  it('shows delete connection confirmation dialog when delete is clicked', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    fireEvent.click(screen.getByTitle('Delete connection'));

    // Both the heading and the danger button say "Delete Connection"
    expect(screen.getAllByText('Delete Connection').length).toBeGreaterThan(0);
    expect(
      screen.getByText(/Are you sure you want to delete the connection "prod-creds"/),
    ).toBeInTheDocument();
  });

  it('cancels connection delete without calling the API', async () => {
    setupHappyPath();
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByTitle('Delete connection'));

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(mockDeleteProviderConnection).not.toHaveBeenCalled();
  });

  it('calls deleteProviderConnection with correct id on confirm', async () => {
    // Initial load returns conn-a; after delete the connection list is empty
    mockGetProvider.mockResolvedValue(PROVIDER);
    mockGetProviderRegions
      .mockResolvedValueOnce([REGION_A])
      .mockResolvedValueOnce([REGION_A]);
    mockGetProviderConnections
      .mockResolvedValueOnce([CONNECTION_A])  // initial load — shows conn-a
      .mockResolvedValueOnce([]);             // after delete refresh
    mockDeleteProviderConnection.mockResolvedValue(undefined);

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    fireEvent.click(screen.getByTitle('Delete connection'));
    fireEvent.click(screen.getByRole('button', { name: 'Delete Connection' }));

    await waitFor(() =>
      expect(mockDeleteProviderConnection).toHaveBeenCalledWith('conn-a'),
    );
  });

  it('shows success notification after connection delete', async () => {
    mockGetProvider.mockResolvedValue(PROVIDER);
    mockGetProviderRegions
      .mockResolvedValueOnce([REGION_A])
      .mockResolvedValueOnce([]);
    mockGetProviderConnections
      .mockResolvedValueOnce([CONNECTION_A])  // initial load
      .mockResolvedValueOnce([]);             // after delete
    mockDeleteProviderConnection.mockResolvedValue(undefined);

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByTitle('Delete connection'));
    fireEvent.click(screen.getByRole('button', { name: 'Delete Connection' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Connection "prod-creds" deleted successfully',
      }),
    );
  });

  it('shows error notification when connection delete fails', async () => {
    setupHappyPath();
    mockDeleteProviderConnection.mockRejectedValue(new Error('API error'));

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByTitle('Delete connection'));
    fireEvent.click(screen.getByRole('button', { name: 'Delete Connection' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete connection: API error',
      }),
    );
  });

  it('calls testProviderConnection with the correct id', async () => {
    setupHappyPath();
    mockTestProviderConnection.mockResolvedValue({ success: true, message: 'Connection test successful' });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    fireEvent.click(screen.getByTitle('Test connection'));

    await waitFor(() =>
      expect(mockTestProviderConnection).toHaveBeenCalledWith('conn-a'),
    );
  });

  it('shows success notification when connection test succeeds', async () => {
    setupHappyPath();
    mockTestProviderConnection.mockResolvedValue({ success: true, message: 'All good' });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByTitle('Test connection'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'All good',
      }),
    );
  });

  it('shows success notification with fallback message when test result has no message', async () => {
    setupHappyPath();
    mockTestProviderConnection.mockResolvedValue({ success: true, message: '' });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByTitle('Test connection'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Connection test successful',
      }),
    );
  });

  it('syncs the provider catalog for a connection when Sync catalog is clicked', async () => {
    setupHappyPath();
    mockSyncProviderConnectionCatalog.mockResolvedValue({
      connection: CONNECTION_A,
      catalog: {
        regions: { created: 1, updated: 2, total: 3 },
        availability_zones: { created: 0, updated: 0 },
        instance_types: { created: 4, updated: 0, total: 4 },
        volume_types: { created: 0, updated: 0, total: 0 },
      },
    });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByTitle('Sync catalog'));

    await waitFor(() =>
      expect(mockSyncProviderConnectionCatalog).toHaveBeenCalledWith('conn-a'),
    );
  });

  it('summarises the synced catalog counts in the success notification', async () => {
    setupHappyPath();
    mockSyncProviderConnectionCatalog.mockResolvedValue({
      connection: CONNECTION_A,
      catalog: {
        regions: { created: 1, updated: 2, total: 3 },
        availability_zones: { created: 0, updated: 0 },
        instance_types: { created: 4, updated: 0, total: 4 },
        volume_types: { created: 0, updated: 0, total: 0 },
      },
    });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByTitle('Sync catalog'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message:
          'Catalog synced for "prod-creds": regions 3 (1 new), availability zones 0, instance types 4 (4 new), volume types 0',
      }),
    );
  });

  it('shows an error notification when the catalog sync fails', async () => {
    setupHappyPath();
    mockSyncProviderConnectionCatalog.mockRejectedValue(new Error('adapter refused'));

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByTitle('Sync catalog'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Catalog sync failed: adapter refused',
      }),
    );
  });

  it('hides Sync catalog without the connections update permission', async () => {
    setupHappyPath();
    mockHasPermission = jest.fn((p: string) => p !== 'system.connections.update');

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    expect(screen.queryByTitle('Sync catalog')).not.toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // Sub-catalog: instance types (IMP-353211667af8)
  // -------------------------------------------------------------------------

  const INSTANCE_TYPE = {
    id: 'it-1',
    name: 'General Medium',
    instance_type_code: 't3.medium',
    vcpus: 2,
    memory_mb: 4096,
    storage_gb: 50,
    enabled: true,
    specs: {},
    provider_id: 'prov-1',
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
  };

  const ZONE = {
    id: 'az-1',
    name: 'Zone A',
    zone_code: 'us-east-1a',
    status: 'available' as const,
    enabled: true,
    capabilities: {},
    provider_region_id: 'reg-a',
    operational: true,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
  };

  it('lists the provider instance types when the Instance Types tab is opened', async () => {
    setupHappyPath();
    mockGetProviderInstanceTypes.mockResolvedValue({ instanceTypes: [INSTANCE_TYPE], total: 1 });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Instance Types'));

    await waitFor(() =>
      expect(mockGetProviderInstanceTypes).toHaveBeenCalledWith('prov-1'),
    );
    expect(await screen.findByTestId('instance-type-it-1')).toBeInTheDocument();
    expect(screen.getByText('t3.medium')).toBeInTheDocument();
  });

  it('opens the instance type form in create mode from the Instance Types tab', async () => {
    setupHappyPath();

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Instance Types'));
    fireEvent.click(await screen.findByText('Add Instance Type'));

    expect(await screen.findByTestId('instance-type-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('instance-type-form-subject')).toHaveTextContent('new');
  });

  it('opens the instance type form pre-filled from a row', async () => {
    setupHappyPath();
    mockGetProviderInstanceTypes.mockResolvedValue({ instanceTypes: [INSTANCE_TYPE], total: 1 });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Instance Types'));
    fireEvent.click(await screen.findByTitle('Edit instance type'));

    expect(screen.getByTestId('instance-type-form-subject')).toHaveTextContent(
      'General Medium',
    );
  });

  it('deletes an instance type and reloads the list', async () => {
    setupHappyPath();
    mockGetProviderInstanceTypes.mockResolvedValue({ instanceTypes: [INSTANCE_TYPE], total: 1 });
    mockDeleteProviderInstanceType.mockResolvedValue(undefined);

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Instance Types'));
    fireEvent.click(await screen.findByTitle('Delete instance type'));

    await waitFor(() =>
      expect(mockDeleteProviderInstanceType).toHaveBeenCalledWith('prov-1', 'it-1'),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Instance type "General Medium" deleted successfully',
      }),
    );
  });

  it('marks sub-catalog writes as a manual override when the provider has a connection', async () => {
    setupHappyPath();

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Instance Types'));
    fireEvent.click(await screen.findByText('Add Instance Type'));

    expect(screen.getByTestId('instance-type-form-modal')).toHaveAttribute(
      'data-manual-override',
      'true',
    );
  });

  it('does not mark sub-catalog writes as an override for a provider with no connection', async () => {
    setupHappyPath({ connections: [] });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Instance Types'));
    fireEvent.click(await screen.findByText('Add Instance Type'));

    expect(screen.getByTestId('instance-type-form-modal')).toHaveAttribute(
      'data-manual-override',
      'false',
    );
  });

  it('says so when the instance type list is truncated by the page cap', async () => {
    setupHappyPath();
    mockGetProviderInstanceTypes.mockResolvedValue({
      instanceTypes: [INSTANCE_TYPE],
      total: 137,
    });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Instance Types'));

    expect(
      await screen.findByText(/Showing 1 of 137 instance types/),
    ).toBeInTheDocument();
  });

  it('shows no truncation notice when the page holds every instance type', async () => {
    setupHappyPath();
    mockGetProviderInstanceTypes.mockResolvedValue({
      instanceTypes: [INSTANCE_TYPE],
      total: 1,
    });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Instance Types'));

    await screen.findByTestId('instance-type-it-1');
    expect(screen.queryByText(/Showing 1 of/)).not.toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // Sub-catalog: availability zones under a region row
  // -------------------------------------------------------------------------

  it('loads a region\'s availability zones when the region row is expanded', async () => {
    setupHappyPath();
    mockGetProviderAvailabilityZones.mockResolvedValue({ zones: [ZONE], total: 1 });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));
    fireEvent.click(await screen.findByTestId('region-zones-toggle-reg-a'));

    await waitFor(() =>
      expect(mockGetProviderAvailabilityZones).toHaveBeenCalledWith('prov-1', 'reg-a'),
    );
    expect(await screen.findByTestId('availability-zone-az-1')).toBeInTheDocument();
    expect(screen.getByText('us-east-1a')).toBeInTheDocument();
  });

  it('opens the zone form for the region whose row it was launched from', async () => {
    setupHappyPath();
    mockGetProviderAvailabilityZones.mockResolvedValue({ zones: [ZONE], total: 1 });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));
    fireEvent.click(await screen.findByTestId('region-zones-toggle-reg-a'));
    fireEvent.click(await screen.findByText('Add Zone'));

    expect(screen.getByTestId('zone-form-region')).toHaveTextContent('reg-a');
    expect(screen.getByTestId('zone-form-subject')).toHaveTextContent('new');
  });

  it('collapsing a region row drops the zones it loaded', async () => {
    setupHappyPath();
    mockGetProviderAvailabilityZones.mockResolvedValue({ zones: [ZONE], total: 1 });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));
    const toggle = await screen.findByTestId('region-zones-toggle-reg-a');
    fireEvent.click(toggle);
    await screen.findByTestId('availability-zone-az-1');

    fireEvent.click(toggle);

    await waitFor(() =>
      expect(screen.queryByTestId('availability-zone-az-1')).not.toBeInTheDocument(),
    );
  });

  it('ignores a late zone response for a region that is no longer expanded', async () => {
    setupHappyPath();
    let resolveFirst: ((v: { zones: typeof ZONE[]; total: number }) => void) | undefined;
    mockGetProviderAvailabilityZones.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveFirst = resolve;
        }),
    );

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));
    const toggle = await screen.findByTestId('region-zones-toggle-reg-a');

    // Expand, then collapse before the fetch settles.
    fireEvent.click(toggle);
    fireEvent.click(toggle);

    resolveFirst?.({ zones: [ZONE], total: 1 });

    await waitFor(() =>
      expect(screen.queryByTestId('availability-zone-az-1')).not.toBeInTheDocument(),
    );
  });

  it('deletes an availability zone and reloads the region\'s zones', async () => {
    setupHappyPath();
    mockGetProviderAvailabilityZones.mockResolvedValue({ zones: [ZONE], total: 1 });
    mockDeleteProviderAvailabilityZone.mockResolvedValue(undefined);

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));
    fireEvent.click(await screen.findByTestId('region-zones-toggle-reg-a'));
    fireEvent.click(await screen.findByTitle('Delete availability zone'));

    await waitFor(() =>
      expect(mockDeleteProviderAvailabilityZone).toHaveBeenCalledWith(
        'prov-1',
        'reg-a',
        'az-1',
      ),
    );
  });

  it('shows error notification when connection test returns success:false', async () => {
    setupHappyPath();
    mockTestProviderConnection.mockResolvedValue({ success: false, message: 'Auth failed' });

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByTitle('Test connection'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Auth failed',
      }),
    );
  });

  it('shows error notification when connection test throws', async () => {
    setupHappyPath();
    mockTestProviderConnection.mockRejectedValue(new Error('Timeout'));

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByTitle('Test connection'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Connection test failed: Timeout',
      }),
    );
  });

  it('hides Test, Edit, Delete connection buttons when permissions are absent', async () => {
    setupHappyPath();
    mockHasPermission = jest.fn(() => false);
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));

    expect(screen.queryByTitle('Test connection')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Edit connection')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Delete connection')).not.toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // Configuration tab
  // -------------------------------------------------------------------------

  it('renders JSON config and capabilities when present', async () => {
    setupHappyPath({ provider: { ...PROVIDER, config: { region: 'us-east-1' }, capabilities: { spot: true } } });
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Configuration'));

    // Config section
    expect(screen.getByText(/"region"/)).toBeInTheDocument();
    // Capabilities section
    expect(screen.getByText(/"spot"/)).toBeInTheDocument();
  });

  it('shows "No configuration defined" when config is empty', async () => {
    setupHappyPath({
      provider: { ...PROVIDER, config: {}, capabilities: {} },
    });
    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Configuration'));

    expect(screen.getByText('No configuration defined')).toBeInTheDocument();
    expect(screen.getByText('No capabilities defined')).toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // Refresh via data callback
  // -------------------------------------------------------------------------

  it('refreshes regions and connections after connection save', async () => {
    const updatedConnection: SystemProviderConnection = { ...CONNECTION_A, name: 'updated-creds' };
    setupHappyPath();
    mockGetProviderRegions.mockResolvedValue([REGION_A]);
    mockGetProviderConnections.mockResolvedValue([updatedConnection]);

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Connections'));
    fireEvent.click(screen.getByText('Add Connection'));

    const callsBefore = mockGetProviderConnections.mock.calls.length;
    fireEvent.click(screen.getByText('Save Connection'));

    await waitFor(() =>
      expect(mockGetProviderConnections.mock.calls.length).toBeGreaterThan(callsBefore),
    );
  });

  it('shows error notification when refreshData fails', async () => {
    setupHappyPath();
    // After initial load, subsequent refresh fails
    mockGetProviderRegions
      .mockResolvedValueOnce([REGION_A])
      .mockRejectedValueOnce(new Error('Refresh error'));
    mockGetProviderConnections
      .mockResolvedValueOnce([CONNECTION_A])
      .mockRejectedValueOnce(new Error('Refresh error'));

    renderModal();

    await waitForLoaded();
    fireEvent.click(screen.getByText('Regions'));
    fireEvent.click(screen.getByText('Add Region'));

    fireEvent.click(screen.getByText('Save Region'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to refresh data',
      }),
    );
  });
});
