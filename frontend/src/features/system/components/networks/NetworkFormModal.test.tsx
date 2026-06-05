import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworkFormModal } from './NetworkFormModal';
import type { SystemProviderNetwork } from '@system/features/system/types/system.types';

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

// systemApi is the facade the component imports.
// getProviders and getProviderRegions are the two calls made during region fetch.
const mockGetProviders = jest.fn();
const mockGetProviderRegions = jest.fn();
const mockCreateNetwork = jest.fn();
const mockUpdateNetwork = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getProviders: (...args: unknown[]) => mockGetProviders(...args),
    getProviderRegions: (...args: unknown[]) => mockGetProviderRegions(...args),
    createNetwork: (...args: unknown[]) => mockCreateNetwork(...args),
    updateNetwork: (...args: unknown[]) => mockUpdateNetwork(...args),
  },
}));

// =============================================================================
// Fixtures + helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const PROVIDER_1 = {
  id: 'prov-1',
  name: 'AWS',
  provider_type: 'aws',
  enabled: true,
  public: true,
  config: {},
  capabilities: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const REGION_1 = {
  id: 'region-1',
  name: 'US East 1',
  region_code: 'us-east-1',
  capabilities: {},
  provider_id: 'prov-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const NETWORK: SystemProviderNetwork = {
  id: 'net-1',
  name: 'prod-vpc',
  description: 'Production VPC',
  cidr_block: '10.0.0.0/16',
  status: 'available',
  is_default: false,
  dns_support: true,
  dns_hostnames: false,
  config: {},
  provider_region_id: 'region-1',
  provider_region_name: 'US East 1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const DEFAULT_PROPS = {
  network: null,
  isOpen: true,
  onClose: jest.fn(),
  onNetworkSaved: jest.fn(),
};

function renderModal(props: Partial<typeof DEFAULT_PROPS> = {}) {
  return render(
    <BrowserRouter>
      <NetworkFormModal {...DEFAULT_PROPS} {...props} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('NetworkFormModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockGetProviders.mockReset();
    mockGetProviderRegions.mockReset();
    mockCreateNetwork.mockReset();
    mockUpdateNetwork.mockReset();
    DEFAULT_PROPS.onClose = jest.fn();
    DEFAULT_PROPS.onNetworkSaved = jest.fn();

    // Default: one provider + one region
    mockGetProviders.mockResolvedValue([PROVIDER_1]);
    mockGetProviderRegions.mockResolvedValue([REGION_1]);
  });

  // ---------------------------------------------------------------------------
  // Render: closed state
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Create Network')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Render: create mode
  // ---------------------------------------------------------------------------

  it('renders Create Network heading in create mode', async () => {
    renderModal({ network: null });
    expect(screen.getByRole('heading', { name: /create network/i })).toBeInTheDocument();
  });

  it('shows default CIDR block value in create mode', async () => {
    renderModal({ network: null });

    await waitFor(() =>
      expect(screen.queryByRole('combobox')).toBeInTheDocument(),
    );

    const cidrInput = screen.getByDisplayValue('10.0.0.0/16');
    expect(cidrInput).toBeInTheDocument();
  });

  it('renders Create Network submit button in create mode', async () => {
    renderModal({ network: null });
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create network/i })).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Render: edit mode
  // ---------------------------------------------------------------------------

  it('renders Edit Network heading in edit mode', async () => {
    renderModal({ network: NETWORK });
    expect(screen.getByRole('heading', { name: /edit network/i })).toBeInTheDocument();
  });

  it('pre-fills form fields with network data in edit mode', async () => {
    renderModal({ network: NETWORK });

    await waitFor(() =>
      expect((screen.getByDisplayValue('prod-vpc') as HTMLInputElement).value).toBe('prod-vpc'),
    );

    expect((screen.getByDisplayValue('Production VPC') as HTMLTextAreaElement).value).toBe(
      'Production VPC',
    );
    expect((screen.getByDisplayValue('10.0.0.0/16') as HTMLInputElement).value).toBe('10.0.0.0/16');
  });

  it('renders Update Network submit button in edit mode', async () => {
    renderModal({ network: NETWORK });
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /update network/i })).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Region loading
  // ---------------------------------------------------------------------------

  it('fetches providers then regions on open and populates the region select', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('combobox')).toBeInTheDocument(),
    );

    const select = screen.getByRole('combobox');
    expect(select).toBeInTheDocument();

    // Option should contain region name and code
    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /us east 1/i }),
      ).toBeInTheDocument(),
    );

    expect(mockGetProviders).toHaveBeenCalledTimes(1);
    expect(mockGetProviderRegions).toHaveBeenCalledWith('prov-1');
  });

  it('shows error notification when region fetch fails', async () => {
    mockGetProviders.mockRejectedValue(new Error('Network error'));

    renderModal();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load regions',
      }),
    );
  });

  it('does not fetch regions when modal is closed', () => {
    renderModal({ isOpen: false });
    expect(mockGetProviders).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Region select disabled in edit mode
  // ---------------------------------------------------------------------------

  it('disables region select in edit mode', async () => {
    renderModal({ network: NETWORK });

    await waitFor(() =>
      expect(screen.getByRole('combobox')).toBeInTheDocument(),
    );

    expect(screen.getByRole('combobox')).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // CIDR block disabled in edit mode
  // ---------------------------------------------------------------------------

  it('disables CIDR block input in edit mode', async () => {
    renderModal({ network: NETWORK });

    await waitFor(() =>
      expect(screen.getByDisplayValue('10.0.0.0/16')).toBeInTheDocument(),
    );

    const cidrInput = screen.getByDisplayValue('10.0.0.0/16');
    expect(cidrInput).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Validation: required fields
  // ---------------------------------------------------------------------------

  it('shows validation error when name is empty on submit', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument(),
    );
  });

  it('shows validation error when name is too short (< 2 chars)', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'x' },
    });
    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(screen.getByText('Name must be at least 2 characters')).toBeInTheDocument(),
    );
  });

  it('shows validation error when region is not selected', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'my-network' },
    });
    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(screen.getByText('Region is required')).toBeInTheDocument(),
    );
  });

  it('shows validation error when CIDR block is empty', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'my-network' },
    });
    // Clear the default CIDR
    fireEvent.change(screen.getByDisplayValue('10.0.0.0/16'), {
      target: { value: '' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });
    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(screen.getByText('CIDR block is required')).toBeInTheDocument(),
    );
  });

  it('shows validation error for invalid CIDR format', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'my-network' },
    });
    fireEvent.change(screen.getByDisplayValue('10.0.0.0/16'), {
      target: { value: 'not-a-cidr' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });
    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(
        screen.getByText('Invalid CIDR format (e.g., 10.0.0.0/16)'),
      ).toBeInTheDocument(),
    );
  });

  it('accepts a valid CIDR format without error', async () => {
    const savedNetwork = { ...NETWORK, id: 'new-net', name: 'my-network' };
    mockCreateNetwork.mockResolvedValue(savedNetwork);

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'my-network' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });
    // Default CIDR 10.0.0.0/16 is already set — no changes needed

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(screen.queryByText('Invalid CIDR format (e.g., 10.0.0.0/16)')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Validation error clearing on field change
  // ---------------------------------------------------------------------------

  it('clears name validation error when user types in the name field', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'valid-name' },
    });

    await waitFor(() =>
      expect(screen.queryByText('Name is required')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Create network submission
  // ---------------------------------------------------------------------------

  it('calls systemApi.createNetwork with correct payload on create submit', async () => {
    const savedNetwork = { ...NETWORK, id: 'new-net', name: 'test-vpc' };
    mockCreateNetwork.mockResolvedValue(savedNetwork);

    renderModal({ network: null });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'test-vpc' },
    });
    fireEvent.change(
      screen.getByPlaceholderText(/optional description/i),
      { target: { value: 'My test VPC' } },
    );
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(mockCreateNetwork).toHaveBeenCalledWith({
        name: 'test-vpc',
        description: 'My test VPC',
        provider_region_id: 'region-1',
        cidr_block: '10.0.0.0/16',
        is_default: false,
        dns_support: true,
        dns_hostnames: false,
      }),
    );
  });

  it('shows success notification after network creation', async () => {
    const savedNetwork = { ...NETWORK, id: 'new-net', name: 'test-vpc' };
    mockCreateNetwork.mockResolvedValue(savedNetwork);

    renderModal({ network: null });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'test-vpc' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Network "test-vpc" created successfully',
      }),
    );
  });

  it('calls onNetworkSaved and onClose after successful creation', async () => {
    const onClose = jest.fn();
    const onNetworkSaved = jest.fn();
    const savedNetwork = { ...NETWORK, id: 'new-net', name: 'test-vpc' };
    mockCreateNetwork.mockResolvedValue(savedNetwork);

    renderModal({ network: null, onClose, onNetworkSaved });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'test-vpc' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() => expect(onNetworkSaved).toHaveBeenCalledWith(savedNetwork));
    expect(onClose).toHaveBeenCalled();
  });

  it('shows error notification when network creation fails', async () => {
    mockCreateNetwork.mockRejectedValue(new Error('Server error'));

    renderModal({ network: null });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'test-vpc' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create network: Server error',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Update network submission
  // ---------------------------------------------------------------------------

  it('calls systemApi.updateNetwork with network id and payload on edit submit', async () => {
    const updatedNetwork = { ...NETWORK, name: 'prod-vpc-updated' };
    mockUpdateNetwork.mockResolvedValue(updatedNetwork);

    renderModal({ network: NETWORK });

    await waitFor(() =>
      expect(screen.getByDisplayValue('prod-vpc')).toBeInTheDocument(),
    );

    // Clear and re-type the name
    const nameInput = screen.getByDisplayValue('prod-vpc');
    fireEvent.change(nameInput, { target: { value: 'prod-vpc-updated' } });

    fireEvent.click(screen.getByRole('button', { name: /update network/i }));

    await waitFor(() =>
      expect(mockUpdateNetwork).toHaveBeenCalledWith('net-1', {
        name: 'prod-vpc-updated',
        description: 'Production VPC',
        provider_region_id: 'region-1',
        cidr_block: '10.0.0.0/16',
        is_default: false,
        dns_support: true,
        dns_hostnames: false,
      }),
    );
  });

  it('shows success notification after network update', async () => {
    const updatedNetwork = { ...NETWORK, name: 'prod-vpc' };
    mockUpdateNetwork.mockResolvedValue(updatedNetwork);

    renderModal({ network: NETWORK });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /update network/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Network "prod-vpc" updated successfully',
      }),
    );
  });

  it('shows error notification when network update fails', async () => {
    mockUpdateNetwork.mockRejectedValue(new Error('Update failed'));

    renderModal({ network: NETWORK });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /update network/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to update network: Update failed',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // onClose callbacks
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel button is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose when the backdrop overlay is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    // The backdrop is a sibling div with onClick=onClose (fixed inset-0 bg-black/50)
    const backdrop = document.querySelector('.fixed.inset-0.bg-black\\/50') as HTMLElement;
    expect(backdrop).toBeInTheDocument();
    fireEvent.click(backdrop);

    expect(onClose).toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Description omitted when empty (undefined in payload)
  // ---------------------------------------------------------------------------

  it('omits description from payload when it is empty', async () => {
    const savedNetwork = { ...NETWORK, id: 'new-net', name: 'nodesc' };
    mockCreateNetwork.mockResolvedValue(savedNetwork);

    renderModal({ network: null });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'nodesc' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });
    // Leave description blank

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() => expect(mockCreateNetwork).toHaveBeenCalled());

    const [payload] = mockCreateNetwork.mock.calls[0];
    expect(payload.description).toBeUndefined();
  });

  // ---------------------------------------------------------------------------
  // Checkbox toggles
  // ---------------------------------------------------------------------------

  it('toggles dns_support checkbox and reflects the value in payload', async () => {
    const savedNetwork = { ...NETWORK, id: 'n', name: 'toggle-test' };
    mockCreateNetwork.mockResolvedValue(savedNetwork);

    renderModal({ network: null });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'toggle-test' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });

    // dns_support starts checked (true) — uncheck it
    const dnsResolutionCheckbox = screen.getByRole('checkbox', { name: /enable dns resolution/i });
    expect(dnsResolutionCheckbox).toBeChecked();
    fireEvent.click(dnsResolutionCheckbox);

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(mockCreateNetwork).toHaveBeenCalledWith(
        expect.objectContaining({ dns_support: false }),
      ),
    );
  });

  it('toggles dns_hostnames checkbox off→on and reflects in payload', async () => {
    const savedNetwork = { ...NETWORK, id: 'n', name: 'hn-test' };
    mockCreateNetwork.mockResolvedValue(savedNetwork);

    renderModal({ network: null });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'hn-test' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });

    // dns_hostnames starts unchecked (false) — check it
    const dnsHostnamesCheckbox = screen.getByRole('checkbox', { name: /enable dns hostnames/i });
    expect(dnsHostnamesCheckbox).not.toBeChecked();
    fireEvent.click(dnsHostnamesCheckbox);

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(mockCreateNetwork).toHaveBeenCalledWith(
        expect.objectContaining({ dns_hostnames: true }),
      ),
    );
  });

  it('toggles is_default checkbox off→on and reflects in payload', async () => {
    const savedNetwork = { ...NETWORK, id: 'n', name: 'default-test' };
    mockCreateNetwork.mockResolvedValue(savedNetwork);

    renderModal({ network: null });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'default-test' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'region-1' },
    });

    const isDefaultCheckbox = screen.getByRole('checkbox', { name: /set as default network/i });
    expect(isDefaultCheckbox).not.toBeChecked();
    fireEvent.click(isDefaultCheckbox);

    fireEvent.click(screen.getByRole('button', { name: /create network/i }));

    await waitFor(() =>
      expect(mockCreateNetwork).toHaveBeenCalledWith(
        expect.objectContaining({ is_default: true }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Multiple providers / regions
  // ---------------------------------------------------------------------------

  it('aggregates regions from multiple providers with provider_name prefix', async () => {
    const provider2 = {
      id: 'prov-2',
      name: 'GCP',
      provider_type: 'gcp',
      enabled: true,
      public: true,
      config: {},
      capabilities: {},
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z',
    };
    const region2 = {
      id: 'region-2',
      name: 'Europe West 1',
      region_code: 'eu-west-1',
      capabilities: {},
      provider_id: 'prov-2',
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z',
    };

    mockGetProviders.mockResolvedValue([PROVIDER_1, provider2]);
    mockGetProviderRegions
      .mockResolvedValueOnce([REGION_1])
      .mockResolvedValueOnce([region2]);

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /us east 1/i })).toBeInTheDocument(),
    );

    expect(
      screen.getByRole('option', { name: /europe west 1/i }),
    ).toBeInTheDocument();

    // Provider names should be part of the option text
    expect(screen.getByRole('option', { name: /aws.*us east 1/i })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: /gcp.*europe west 1/i })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Form reset on close/reopen
  // ---------------------------------------------------------------------------

  it('resets form to defaults when modal reopens after being closed', async () => {
    const { rerender } = renderModal({ isOpen: true, network: null });

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    // Fill in name
    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'temp-name' },
    });

    // Close
    rerender(
      <BrowserRouter>
        <NetworkFormModal {...DEFAULT_PROPS} isOpen={false} network={null} />
      </BrowserRouter>,
    );

    // Reopen
    rerender(
      <BrowserRouter>
        <NetworkFormModal {...DEFAULT_PROPS} isOpen={true} network={null} />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(screen.getByPlaceholderText(/enter network name/i)).toHaveValue(''),
    );
  });
});
