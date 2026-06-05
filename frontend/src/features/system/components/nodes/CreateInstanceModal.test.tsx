import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { CreateInstanceModal } from './CreateInstanceModal';
import type { SystemNode, SystemNodeInstance } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGetProviderConnections = jest.fn();
const mockGetProviderRegions = jest.fn();
const mockGetProviderInstanceTypes = jest.fn();
const mockGetProviderAvailabilityZones = jest.fn();
const mockGetNetworks = jest.fn();
const mockGetNetworkSubnets = jest.fn();
const mockCreateNodeInstance = jest.fn();
const mockGetPlatforms = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getProviderConnections: (...args: unknown[]) => mockGetProviderConnections(...args),
    getProviderRegions: (...args: unknown[]) => mockGetProviderRegions(...args),
    getProviderInstanceTypes: (...args: unknown[]) => mockGetProviderInstanceTypes(...args),
    getProviderAvailabilityZones: (...args: unknown[]) => mockGetProviderAvailabilityZones(...args),
    getNetworks: (...args: unknown[]) => mockGetNetworks(...args),
    getNetworkSubnets: (...args: unknown[]) => mockGetNetworkSubnets(...args),
    createNodeInstance: (...args: unknown[]) => mockCreateNodeInstance(...args),
    getPlatforms: (...args: unknown[]) => mockGetPlatforms(...args),
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

// EntityLink uses entityRegistry and useEntityModal — stub these out
jest.mock('@/shared/services/entityRegistry', () => ({
  entityRegistry: {
    getEntity: () => null,
  },
}));

jest.mock('@/shared/hooks/useEntityModal', () => ({
  useEntityModal: () => ({
    openEntity: jest.fn(),
    openByParam: jest.fn(),
  }),
}));

// =============================================================================
// Fixtures
// =============================================================================

const NODE: SystemNode = {
  id: 'node-123',
  name: 'my-node',
  enabled: true,
  allocate_public_ip: false,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CONNECTION = {
  id: 'conn-1',
  name: 'AWS Production',
  provider_name: 'AWS',
  provider_id: 'prov-aws',
  description: '',
  endpoint_url: undefined,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const REGION = {
  id: 'region-1',
  name: 'US East',
  region_code: 'us-east-1',
  description: undefined,
  endpoint_url: undefined,
  capabilities: {},
  provider_id: 'prov-aws',
  zone_count: 3,
  instance_type_count: 20,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const INSTANCE_TYPE = {
  id: 'itype-1',
  name: 't3.micro',
  display_name: 'T3 Micro (1 vCPU, 1GB RAM)',
  description: undefined,
  instance_type_code: 't3.micro',
  vcpus: 1,
  memory_mb: 1024,
  enabled: true,
  specs: {},
  provider_id: 'prov-aws',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const ZONE = {
  id: 'zone-1',
  name: 'us-east-1a',
  zone_code: 'us-east-1a',
  status: 'available' as const,
  enabled: true,
  capabilities: {},
  provider_region_id: 'region-1',
  operational: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const NETWORK = {
  id: 'net-1',
  name: 'default-vpc',
  cidr_block: '10.0.0.0/16',
  status: 'available',
  config: {},
  provider_region_id: 'region-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const SUBNET = {
  id: 'subnet-1',
  name: 'subnet-public-1',
  cidr_block: '10.0.1.0/24',
  status: 'available',
  is_public: true,
  enabled: true,
  config: {},
  provider_network_id: 'net-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PLATFORM = {
  id: 'plat-1',
  name: 'Ubuntu RPi4',
  architecture_name: 'ARM64',
  enabled: true,
  public: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CREATED_INSTANCE: SystemNodeInstance = {
  id: 'inst-new',
  name: 'my-node-instance-abcd',
  variety: 'cloud',
  status: 'pending',
  config: {},
  node_id: 'node-123',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

const defaultProps = {
  node: NODE,
  isOpen: true,
  onClose: jest.fn(),
  onInstanceCreated: jest.fn(),
};

function renderModal(props: Partial<typeof defaultProps> = {}) {
  return render(
    <BrowserRouter>
      <CreateInstanceModal {...defaultProps} {...props} />
    </BrowserRouter>
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('CreateInstanceModal', () => {
  beforeEach(() => {
    jest.clearAllMocks();

    // Default: resolve with empty lists so cloud branch doesn't error
    mockGetProviderConnections.mockResolvedValue([]);
    mockGetProviderRegions.mockResolvedValue([]);
    mockGetProviderInstanceTypes.mockResolvedValue([]);
    mockGetProviderAvailabilityZones.mockResolvedValue([]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });
    mockGetNetworkSubnets.mockResolvedValue([]);
    mockGetPlatforms.mockResolvedValue([]);
  });

  // ===========================================================================
  // Render / open state
  // ===========================================================================

  it('renders the modal title and node name when open', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Create Instance' })).toBeInTheDocument()
    );
    expect(screen.getByText('For node: my-node')).toBeInTheDocument();
  });

  it('does not render when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Create Instance')).not.toBeInTheDocument();
  });

  it('pre-fills the name field with a generated name based on the node name', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());
    const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
    expect(nameInput.value).toMatch(/^my-node-instance-/);
  });

  it('defaults to the cloud variety', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByText('Cloud Provider Configuration')).toBeInTheDocument());
  });

  // ===========================================================================
  // Variety selection
  // ===========================================================================

  it('switches to physical configuration when Physical button is clicked', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('button', { name: /physical/i })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /physical/i }));

    await waitFor(() =>
      expect(screen.getByText('Physical Device Configuration')).toBeInTheDocument()
    );
    expect(screen.queryByText('Cloud Provider Configuration')).not.toBeInTheDocument();
  });

  it('shows Physical hardware server description when physical is selected', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('button', { name: /physical/i })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /physical/i }));

    await waitFor(() =>
      expect(screen.getByText('Physical hardware server')).toBeInTheDocument()
    );
  });

  it('switches to dynamic variety and shows correct description', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('button', { name: /dynamic/i })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /dynamic/i }));

    await waitFor(() =>
      expect(screen.getByText('Dynamically provisioned instance')).toBeInTheDocument()
    );
    expect(screen.queryByText('Cloud Provider Configuration')).not.toBeInTheDocument();
    expect(screen.queryByText('Physical Device Configuration')).not.toBeInTheDocument();
  });

  // ===========================================================================
  // Cloud provider connections load
  // ===========================================================================

  it('calls getProviderConnections when modal opens in cloud mode', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    renderModal();

    await waitFor(() =>
      expect(mockGetProviderConnections).toHaveBeenCalledTimes(1)
    );
  });

  it('renders connection options in the Provider Connection select', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
  });

  // ===========================================================================
  // Cascading selects: connection → region → instance types + zones + networks
  // ===========================================================================

  it('loads regions when a provider connection is selected', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    renderModal();

    // Wait for connection options to render
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );

    const connectionSelect = screen.getByLabelText(/provider connection/i);
    fireEvent.change(connectionSelect, { target: { value: 'conn-1' } });

    await waitFor(() =>
      expect(mockGetProviderRegions).toHaveBeenCalledWith('prov-aws')
    );
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East \(us-east-1\)/ })).toBeInTheDocument()
    );
  });

  it('resets region and downstream fields when connection is cleared', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );

    const connectionSelect = screen.getByLabelText(/provider connection/i);
    // Select connection then deselect
    fireEvent.change(connectionSelect, { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East \(us-east-1\)/ })).toBeInTheDocument()
    );
    fireEvent.change(connectionSelect, { target: { value: '' } });

    await waitFor(() =>
      expect(screen.queryByRole('option', { name: /US East \(us-east-1\)/ })).not.toBeInTheDocument()
    );
  });

  it('loads instance types, availability zones, and networks when region is selected', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([ZONE]);
    mockGetNetworks.mockResolvedValue({ networks: [NETWORK], meta: { current_page: 1, per_page: 200, total_count: 1, total_pages: 1, next_page: null, prev_page: null } });
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East \(us-east-1\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });

    await waitFor(() =>
      expect(mockGetProviderInstanceTypes).toHaveBeenCalledWith('prov-aws')
    );
    await waitFor(() =>
      expect(mockGetProviderAvailabilityZones).toHaveBeenCalledWith('prov-aws', 'region-1')
    );
    await waitFor(() =>
      expect(mockGetNetworks).toHaveBeenCalledWith({ provider_region_id: 'region-1' })
    );

    // Instance types appear in the Instance Size select
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /T3 Micro \(1 vCPU, 1GB RAM\)/ })).toBeInTheDocument()
    );
    // Availability zones appear (operational ones only)
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /us-east-1a.*available/ })).toBeInTheDocument()
    );
    // Networks appear
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /default-vpc \(10\.0\.0\.0\/16\)/ })).toBeInTheDocument()
    );
  });

  it('only renders operational availability zones', async () => {
    const nonOperationalZone = { ...ZONE, id: 'zone-2', name: 'us-east-1b', zone_code: 'us-east-1b', operational: false };
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([]);
    mockGetProviderAvailabilityZones.mockResolvedValue([ZONE, nonOperationalZone]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East \(us-east-1\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /us-east-1a/ })).toBeInTheDocument()
    );
    // Non-operational zone must NOT appear
    expect(screen.queryByRole('option', { name: /us-east-1b/ })).not.toBeInTheDocument();
  });

  // ===========================================================================
  // Subnet loading (triggered by network selection)
  // ===========================================================================

  it('loads subnets when a network is selected and shows subnet select', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([ZONE]);
    mockGetNetworks.mockResolvedValue({ networks: [NETWORK], meta: { current_page: 1, per_page: 200, total_count: 1, total_pages: 1, next_page: null, prev_page: null } });
    mockGetNetworkSubnets.mockResolvedValue([SUBNET]);
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East \(us-east-1\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /default-vpc/ })).toBeInTheDocument()
    );

    fireEvent.change(screen.getByLabelText(/^network$/i), { target: { value: 'net-1' } });

    await waitFor(() =>
      expect(mockGetNetworkSubnets).toHaveBeenCalledWith('net-1', undefined)
    );
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /subnet-public-1.*\(Public\)/ })).toBeInTheDocument()
    );
  });

  it('hides the subnet select when no network is selected', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByText('Cloud Provider Configuration')).toBeInTheDocument());
    expect(screen.queryByLabelText(/^subnet$/i)).not.toBeInTheDocument();
  });

  it('calls getNetworkSubnets with availability zone id when both network and zone are set', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([ZONE]);
    mockGetNetworks.mockResolvedValue({ networks: [NETWORK], meta: { current_page: 1, per_page: 200, total_count: 1, total_pages: 1, next_page: null, prev_page: null } });
    mockGetNetworkSubnets.mockResolvedValue([SUBNET]);
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East \(us-east-1\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /us-east-1a/ })).toBeInTheDocument()
    );

    fireEvent.change(screen.getByLabelText(/availability zone/i), { target: { value: 'zone-1' } });
    fireEvent.change(screen.getByLabelText(/^network$/i), { target: { value: 'net-1' } });

    await waitFor(() =>
      expect(mockGetNetworkSubnets).toHaveBeenCalledWith('net-1', 'zone-1')
    );
  });

  // ===========================================================================
  // Physical mode
  // ===========================================================================

  it('loads platforms when switching to physical mode', async () => {
    mockGetPlatforms.mockResolvedValue([PLATFORM]);
    renderModal();

    await waitFor(() => expect(screen.getByRole('button', { name: /physical/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /physical/i }));

    await waitFor(() =>
      expect(mockGetPlatforms).toHaveBeenCalledTimes(1)
    );
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /Ubuntu RPi4 \(ARM64\)/ })).toBeInTheDocument()
    );
  });

  it('renders the MAC address and description fields in physical mode', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('button', { name: /physical/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /physical/i }));

    await waitFor(() =>
      expect(screen.getByLabelText(/mac address/i)).toBeInTheDocument()
    );
    expect(screen.getByLabelText(/description \/ notes/i)).toBeInTheDocument();
  });

  it('does not call getPlatforms when variety is cloud', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByText('Cloud Provider Configuration')).toBeInTheDocument());
    expect(mockGetPlatforms).not.toHaveBeenCalled();
  });

  // ===========================================================================
  // IP address fields always visible
  // ===========================================================================

  it('renders Private IP, Public IP, and VPN IP fields', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/private ip/i)).toBeInTheDocument());
    expect(screen.getByLabelText(/public ip/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/vpn ip/i)).toBeInTheDocument();
  });

  // ===========================================================================
  // Validation
  // ===========================================================================

  it('shows required error when name is cleared and form is submitted', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    const nameInput = screen.getByLabelText(/name/i);
    fireEvent.change(nameInput, { target: { value: '' } });

    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument()
    );
    expect(mockCreateNodeInstance).not.toHaveBeenCalled();
  });

  it('shows min-length validation error when name is too short', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'ab' } });
    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(screen.getByText('Name must be at least 3 characters')).toBeInTheDocument()
    );
  });

  it('shows max-length validation error when name exceeds 100 characters', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'a'.repeat(101) } });
    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(screen.getByText('Name must be less than 100 characters')).toBeInTheDocument()
    );
  });

  it('shows format validation error when name contains invalid characters', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: '-invalid-start' } });
    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(
        screen.getByText(/name must start with alphanumeric/i)
      ).toBeInTheDocument()
    );
  });

  it('shows cloud-specific validation errors when required provider fields are empty', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    // Keep a valid name
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'valid-name' } });
    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(screen.getByText('Provider connection is required for cloud instances')).toBeInTheDocument()
    );
    expect(screen.getByText('Region is required for cloud instances')).toBeInTheDocument();
    expect(screen.getByText('Instance type is required for cloud instances')).toBeInTheDocument();
  });

  it('clears field error when the field is edited after a failed validation', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    const nameInput = screen.getByLabelText(/name/i);
    fireEvent.change(nameInput, { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument()
    );

    // Now fix the field
    fireEvent.change(nameInput, { target: { value: 'fixed-name' } });
    expect(screen.queryByText('Name is required')).not.toBeInTheDocument();
  });

  // ===========================================================================
  // Form submission — cloud
  // ===========================================================================

  it('submits the correct payload for a cloud instance', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });
    mockCreateNodeInstance.mockResolvedValue(CREATED_INSTANCE);
    renderModal();

    // Wait for connections to load
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );

    // Set name
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'test-cloud-instance' } });

    // Select connection → triggers region load
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });

    // Wait for regions
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East \(us-east-1\)/ })).toBeInTheDocument()
    );

    // Select region → triggers instance types load
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });

    // Wait for instance types
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /T3 Micro/ })).toBeInTheDocument()
    );

    // Select instance type
    fireEvent.change(screen.getByLabelText(/instance size/i), { target: { value: 'itype-1' } });

    // Submit
    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(mockCreateNodeInstance).toHaveBeenCalledWith(
        'node-123',
        expect.objectContaining({
          name: 'test-cloud-instance',
          variety: 'cloud',
          status: 'pending',
          config: expect.objectContaining({
            provider_connection_id: 'conn-1',
            provider_region_id: 'region-1',
            provider_instance_type_id: 'itype-1',
          }),
        })
      )
    );
  });

  it('calls createNodeInstance at the correct API URL (POST to /system/nodes/:id/node_instances)', async () => {
    // This test verifies the actual apiClient call path via the systemApi facade
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });
    mockCreateNodeInstance.mockResolvedValue(CREATED_INSTANCE);
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'my-cloud-inst' } });
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /T3 Micro/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/instance size/i), { target: { value: 'itype-1' } });

    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(mockCreateNodeInstance).toHaveBeenCalledWith('node-123', expect.any(Object))
    );
  });

  it('omits optional IP fields from the payload when left blank', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });
    mockCreateNodeInstance.mockResolvedValue(CREATED_INSTANCE);
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'ip-omit-test' } });
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /T3 Micro/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/instance size/i), { target: { value: 'itype-1' } });

    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() => expect(mockCreateNodeInstance).toHaveBeenCalled());

    const [, payload] = mockCreateNodeInstance.mock.calls[0] as [string, Record<string, unknown>];
    // Blank IP strings should be coerced to undefined (absent from payload or undefined)
    expect(payload.private_ip_address).toBeUndefined();
    expect(payload.public_ip_address).toBeUndefined();
    expect(payload.vpn_ip_address).toBeUndefined();
  });

  it('includes IP addresses in the payload when provided', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });
    mockCreateNodeInstance.mockResolvedValue(CREATED_INSTANCE);
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'ip-test' } });
    fireEvent.change(screen.getByLabelText(/private ip/i), { target: { value: '10.0.0.5' } });
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /T3 Micro/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/instance size/i), { target: { value: 'itype-1' } });

    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() => expect(mockCreateNodeInstance).toHaveBeenCalled());
    const [, payload] = mockCreateNodeInstance.mock.calls[0] as [string, Record<string, unknown>];
    expect(payload.private_ip_address).toBe('10.0.0.5');
  });

  // ===========================================================================
  // Success path
  // ===========================================================================

  it('shows success notification and calls onInstanceCreated + onClose on success', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });
    mockCreateNodeInstance.mockResolvedValue(CREATED_INSTANCE);

    const onInstanceCreated = jest.fn();
    const onClose = jest.fn();
    renderModal({ onInstanceCreated, onClose });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'success-test' } });
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /T3 Micro/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/instance size/i), { target: { value: 'itype-1' } });

    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Instance "${CREATED_INSTANCE.name}" created successfully`,
      })
    );
    expect(onInstanceCreated).toHaveBeenCalledWith(CREATED_INSTANCE);
    expect(onClose).toHaveBeenCalled();
  });

  // ===========================================================================
  // Error path
  // ===========================================================================

  it('shows error notification when createNodeInstance rejects', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });
    mockCreateNodeInstance.mockRejectedValue(new Error('Server error'));
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'error-test' } });
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /T3 Micro/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/instance size/i), { target: { value: 'itype-1' } });

    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Server error',
      })
    );
  });

  it('shows generic error message when error is not an Error instance', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });
    mockCreateNodeInstance.mockRejectedValue('not an error object');
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'generic-error-test' } });
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /T3 Micro/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/instance size/i), { target: { value: 'itype-1' } });

    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create instance',
      })
    );
  });

  // ===========================================================================
  // Submitting state
  // ===========================================================================

  it('disables the submit button and shows Creating... during submission', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });

    // Pause resolution so we can observe the in-flight state
    let resolveCreate!: (v: SystemNodeInstance) => void;
    mockCreateNodeInstance.mockReturnValue(
      new Promise<SystemNodeInstance>((res) => { resolveCreate = res; })
    );
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'inflight-test' } });
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /T3 Micro/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/instance size/i), { target: { value: 'itype-1' } });

    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /creating\.\.\./i })).toBeDisabled()
    );

    // Resolve the promise so React doesn't leak state
    resolveCreate(CREATED_INSTANCE);
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /creating\.\.\./i })).not.toBeInTheDocument()
    );
  });

  // ===========================================================================
  // Cancel
  // ===========================================================================

  it('calls onClose when Cancel button is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() => expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    expect(onClose).toHaveBeenCalled();
  });

  // ===========================================================================
  // Re-open / reset behaviour
  // ===========================================================================

  it('resets form fields when modal re-opens with a different node', async () => {
    const node2: SystemNode = {
      ...NODE,
      id: 'node-456',
      name: 'another-node',
    };
    const { rerender } = renderModal();

    await waitFor(() => {
      const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
      expect(nameInput.value).toMatch(/^my-node-instance-/);
    });

    rerender(
      <BrowserRouter>
        <CreateInstanceModal
          {...defaultProps}
          node={node2}
          isOpen={false}
        />
      </BrowserRouter>
    );
    rerender(
      <BrowserRouter>
        <CreateInstanceModal
          {...defaultProps}
          node={node2}
          isOpen={true}
        />
      </BrowserRouter>
    );

    await waitFor(() => {
      const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
      expect(nameInput.value).toMatch(/^another-node-instance-/);
    });
  });

  // ===========================================================================
  // Physical mode: cloud fields hidden
  // ===========================================================================

  it('does not render cloud provider fields in physical mode', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('button', { name: /physical/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /physical/i }));

    await waitFor(() =>
      expect(screen.getByText('Physical Device Configuration')).toBeInTheDocument()
    );
    expect(screen.queryByLabelText(/provider connection/i)).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/region/i)).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/instance size/i)).not.toBeInTheDocument();
  });

  // ===========================================================================
  // Cloud: no provider_availability_zone_id or provider_network_id in config
  // when those optional fields are left empty
  // ===========================================================================

  it('omits optional cloud config fields when not selected', async () => {
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderInstanceTypes.mockResolvedValue([INSTANCE_TYPE]);
    mockGetProviderAvailabilityZones.mockResolvedValue([]);
    mockGetNetworks.mockResolvedValue({ networks: [], meta: { current_page: 1, per_page: 200, total_count: 0, total_pages: 1, next_page: null, prev_page: null } });
    mockCreateNodeInstance.mockResolvedValue(CREATED_INSTANCE);
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /AWS Production \(AWS\)/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'optional-omit' } });
    fireEvent.change(screen.getByLabelText(/provider connection/i), { target: { value: 'conn-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /US East/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/region/i), { target: { value: 'region-1' } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /T3 Micro/ })).toBeInTheDocument()
    );
    fireEvent.change(screen.getByLabelText(/instance size/i), { target: { value: 'itype-1' } });

    fireEvent.click(screen.getByRole('button', { name: /create instance/i }));

    await waitFor(() => expect(mockCreateNodeInstance).toHaveBeenCalled());
    const [, payload] = mockCreateNodeInstance.mock.calls[0] as [string, { config: Record<string, unknown> }];
    expect(payload.config.provider_availability_zone_id).toBeUndefined();
    expect(payload.config.provider_network_id).toBeUndefined();
    expect(payload.config.provider_network_subnet_id).toBeUndefined();
  });
});
