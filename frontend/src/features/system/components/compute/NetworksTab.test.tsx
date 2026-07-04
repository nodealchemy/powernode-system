import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworksTab } from './NetworksTab';
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

// EntityLink uses the router, keep it simple
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label?: string }) => <span>{label}</span>,
}));

// =============================================================================
// Fixtures & helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function networkListEnvelope(networks: SystemProviderNetwork[]) {
  return {
    data: {
      success: true,
      data: { networks },
      meta: {
        current_page: 1,
        per_page: 20,
        total_count: networks.length,
        total_pages: 1,
        next_page: null,
        prev_page: null,
      },
    },
  };
}

const NETWORK_A: SystemProviderNetwork = {
  id: 'net-a',
  name: 'prod-vpc',
  description: 'Production VPC',
  cidr_block: '10.0.0.0/16',
  status: 'available',
  is_default: false,
  dns_support: true,
  dns_hostnames: false,
  config: {},
  provider_region_id: 'region-1',
  region_name: 'us-east-1',
  subnet_count: 3,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const NETWORK_B: SystemProviderNetwork = {
  id: 'net-b',
  name: 'staging-vpc',
  cidr_block: '172.16.0.0/12',
  status: 'pending',
  is_default: true,
  dns_support: false,
  dns_hostnames: false,
  config: {},
  provider_region_id: 'region-2',
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-02T00:00:00Z',
};

// Provider / region fixtures used by the NetworkFormModal
const PROVIDER = { id: 'prov-1', name: 'Local', enabled: true };
const REGION = {
  id: 'region-1',
  name: 'US East',
  region_code: 'us-east-1',
  provider_id: 'prov-1',
};

// =============================================================================
// Render helper
// =============================================================================

const renderTab = (props: Partial<React.ComponentProps<typeof NetworksTab>> = {}) =>
  render(
    <BrowserRouter>
      <NetworksTab {...props} />
    </BrowserRouter>,
  );

// Click the modal form's submit button. The NetworkList empty-state also renders
// a button with the same label — we scope the search to the modal overlay (the
// fixed-position z-50 container) to avoid ambiguity.
function clickModalSubmit(labelPattern: RegExp) {
  // The form modal renders inside a `div.fixed.inset-0.z-50`
  const overlay = document.querySelector('[class*="fixed"][class*="z-50"]');
  if (!overlay) throw new Error('Modal overlay not found');
  const allBtns = Array.from(overlay.querySelectorAll('button')) as HTMLButtonElement[];
  const submitBtn = allBtns.find(
    (b) => b.getAttribute('type') === 'submit' || labelPattern.test(b.textContent ?? ''),
  );
  if (!submitBtn) throw new Error(`Submit button matching ${labelPattern} not found in modal`);
  fireEvent.click(submitBtn);
}

// Helpers to interact with the desktop table row action buttons.
// The actions column (<td>) in each row contains:
//   [0] Eye/View button
//   [1] MoreVertical/dropdown button
function getLastTd(): Element | null {
  // The table may have multiple rows; grab the first data row's last td.
  const tbody = document.querySelector('tbody');
  if (!tbody) return null;
  const firstRow = tbody.querySelectorAll('tr')[0];
  if (!firstRow) return null;
  const tds = firstRow.querySelectorAll('td');
  return tds[tds.length - 1] ?? null;
}

function clickViewButton() {
  const td = getLastTd();
  if (td) {
    const btns = td.querySelectorAll('button');
    if (btns.length >= 1) fireEvent.click(btns[0]);
  }
}

function clickMoreButton() {
  const td = getLastTd();
  if (td) {
    const btns = td.querySelectorAll('button');
    if (btns.length >= 2) fireEvent.click(btns[1]);
  }
}

// =============================================================================
// Tests
// =============================================================================

describe('NetworksTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render / loading states
  // ---------------------------------------------------------------------------

  it('renders the list of networks fetched from the API', async () => {
    mockGet.mockResolvedValue(networkListEnvelope([NETWORK_A, NETWORK_B]));

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));
    expect(screen.getAllByText('staging-vpc').length).toBeGreaterThan(0);

    expect(mockGet).toHaveBeenCalledWith(
      '/system/provider_networks',
      expect.objectContaining({ params: expect.objectContaining({ page: 1 }) }),
    );
  });

  it('shows empty state when there are no networks', async () => {
    mockGet.mockResolvedValue(networkListEnvelope([]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('No networks found')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // onActionsReady callback
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with an openCreate handle on mount', async () => {
    mockGet.mockResolvedValue(networkListEnvelope([]));
    const onActionsReady = jest.fn();

    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalledTimes(1));

    const handle = onActionsReady.mock.calls[0][0];
    expect(handle).not.toBeNull();
    expect(typeof handle.openCreate).toBe('function');
  });

  it('calls onActionsReady(null) on unmount', async () => {
    mockGet.mockResolvedValue(networkListEnvelope([]));
    const onActionsReady = jest.fn();

    const { unmount } = renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    unmount();

    const lastCall = onActionsReady.mock.calls[onActionsReady.mock.calls.length - 1][0];
    expect(lastCall).toBeNull();
  });

  // ---------------------------------------------------------------------------
  // Create flow — openCreate via onActionsReady handle
  // ---------------------------------------------------------------------------

  it('opens the NetworkFormModal when openCreate is invoked via handle', async () => {
    // First call: network list; subsequent calls for provider/region loading
    mockGet
      .mockResolvedValueOnce(networkListEnvelope([]))
      .mockResolvedValue(envelope({ providers: [] }));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    const { openCreate } = onActionsReady.mock.calls[0][0];

    openCreate();

    // The modal header says "Create Network"
    await waitFor(() =>
      expect(
        screen.getByRole('heading', { name: /create network/i }),
      ).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // View (detail modal)
  // ---------------------------------------------------------------------------

  it('opens the NetworkDetailModal when the view button is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(networkListEnvelope([NETWORK_A]))
      .mockResolvedValueOnce(envelope({ network: NETWORK_A }));

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));

    clickViewButton();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'prod-vpc' })).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Detail modal — fetches by ID
  // ---------------------------------------------------------------------------

  it('fetches network details by ID when detail modal opens', async () => {
    mockGet
      .mockResolvedValueOnce(networkListEnvelope([NETWORK_A]))
      .mockResolvedValueOnce(envelope({ network: NETWORK_A }));

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));

    clickViewButton();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/provider_networks/net-a'),
    );

    // The detail modal renders the CIDR block — it also appears in the list row,
    // so use getAllByText and confirm at least one instance is present.
    await waitFor(() =>
      expect(screen.getAllByText('10.0.0.0/16').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Edit flow
  // ---------------------------------------------------------------------------

  it('opens the NetworkFormModal in edit mode when edit menu item is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(networkListEnvelope([NETWORK_A]))
      .mockResolvedValue(envelope({ providers: [PROVIDER] }));

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));

    clickMoreButton();

    await waitFor(() => expect(screen.getByText('Edit')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Edit'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /edit network/i })).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Detail modal — edit from detail triggers form modal
  // ---------------------------------------------------------------------------

  it('opens the form modal in edit mode when Edit Network is clicked in the detail modal', async () => {
    mockGet
      .mockResolvedValueOnce(networkListEnvelope([NETWORK_A]))
      .mockResolvedValueOnce(envelope({ network: NETWORK_A }))
      .mockResolvedValue(envelope({ providers: [PROVIDER] }));

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));

    clickViewButton();

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /edit network/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /edit network/i }));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /edit network/i })).toBeInTheDocument(),
    );
    // Form is pre-populated with the network name
    expect(screen.getByDisplayValue('prod-vpc')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Delete confirmation dialog
  // ---------------------------------------------------------------------------

  it('shows the delete confirmation dialog when delete is triggered', async () => {
    mockGet.mockResolvedValue(networkListEnvelope([NETWORK_A]));

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));

    clickMoreButton();

    await waitFor(() => expect(screen.queryByText('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Delete'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Network' })).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/Are you sure you want to delete this network/),
    ).toBeInTheDocument();
  });

  it('calls systemApi.deleteNetwork with the correct id and shows success notification', async () => {
    mockGet.mockResolvedValue(networkListEnvelope([NETWORK_A]));
    mockDelete.mockResolvedValue({ data: { success: true } });

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));

    clickMoreButton();

    await waitFor(() => expect(screen.queryByText('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Delete'));

    // Confirm dialog is open — click the danger "Delete Network" button
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /delete network/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /delete network/i }));

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith('/system/provider_networks/net-a'),
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Network deleted successfully',
      }),
    );
  });

  it('shows error notification when delete fails', async () => {
    mockGet.mockResolvedValue(networkListEnvelope([NETWORK_A]));
    mockDelete.mockRejectedValue(new Error('Server error'));

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));

    clickMoreButton();

    await waitFor(() => expect(screen.queryByText('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Delete'));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /delete network/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /delete network/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete network: Server error',
      }),
    );
  });

  it('dismisses the delete confirmation without calling API when Cancel is clicked', async () => {
    mockGet.mockResolvedValue(networkListEnvelope([NETWORK_A]));

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));

    clickMoreButton();

    await waitFor(() => expect(screen.queryByText('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Delete'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Network' })).toBeInTheDocument(),
    );

    // The confirm dialog has two buttons: Cancel and Delete Network
    // Find Cancel specifically via role
    const cancelBtn = screen.getAllByRole('button', { name: /cancel/i })[0];
    fireEvent.click(cancelBtn);

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Network' })).not.toBeInTheDocument(),
    );

    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('shows Deleting... on the confirm button while delete is in flight', async () => {
    mockGet.mockResolvedValue(networkListEnvelope([NETWORK_A]));

    let resolveDelete!: () => void;
    mockDelete.mockReturnValue(
      new Promise<{ data: { success: boolean } }>((resolve) => {
        resolveDelete = () => resolve({ data: { success: true } });
      }),
    );

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));

    clickMoreButton();

    await waitFor(() => expect(screen.queryByText('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Delete'));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /delete network/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /delete network/i }));

    await waitFor(() =>
      expect(screen.getByText('Processing...')).toBeInTheDocument(),
    );

    resolveDelete();

    await waitFor(() =>
      expect(screen.queryByText('Processing...')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // NetworkFormModal — create submission
  // ---------------------------------------------------------------------------

  it('creates a network via POST and refreshes the list on save', async () => {
    const savedNetwork: SystemProviderNetwork = {
      ...NETWORK_A,
      id: 'net-new',
      name: 'new-vpc',
    };

    mockGet
      .mockResolvedValueOnce(networkListEnvelope([]))           // initial list
      .mockResolvedValueOnce(envelope({ providers: [PROVIDER] })) // getProviders
      .mockResolvedValueOnce(envelope({ regions: [REGION] }))     // getProviderRegions
      .mockResolvedValueOnce(networkListEnvelope([savedNetwork])); // refresh after save

    mockPost.mockResolvedValue(envelope({ network: savedNetwork }));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openCreate();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /create network/i })).toBeInTheDocument(),
    );

    // Fill name
    const nameInput = screen.getByPlaceholderText(/enter network name/i);
    fireEvent.change(nameInput, { target: { value: 'new-vpc' } });

    // Wait for regions to load and select
    await waitFor(() =>
      expect(screen.queryByDisplayValue('Select a region')).toBeInTheDocument(),
    );
    const regionSelect = screen.getByDisplayValue('Select a region');
    fireEvent.change(regionSelect, { target: { value: 'region-1' } });

    // Submit — use type="submit" to avoid the NetworkList empty-state button
    clickModalSubmit(/create network/i);

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/provider_networks',
        expect.objectContaining({
          network: expect.objectContaining({
            name: 'new-vpc',
            provider_region_id: 'region-1',
            cidr_block: '10.0.0.0/16',
          }),
        }),
      ),
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // NetworkFormModal — validation
  // ---------------------------------------------------------------------------

  it('shows validation errors when required fields are missing', async () => {
    mockGet
      .mockResolvedValueOnce(networkListEnvelope([]))
      .mockResolvedValue(envelope({ providers: [] }));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openCreate();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /create network/i })).toBeInTheDocument(),
    );

    // Clear the CIDR default
    const cidrInput = screen.getByPlaceholderText(/e\.g\., 10\.0\.0\.0\/16/i);
    fireEvent.change(cidrInput, { target: { value: '' } });

    // Submit without filling required fields
    clickModalSubmit(/create network/i);

    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument(),
    );
    expect(screen.getByText('Region is required')).toBeInTheDocument();
    expect(screen.getByText('CIDR block is required')).toBeInTheDocument();

    expect(mockPost).not.toHaveBeenCalled();
  });

  it('shows CIDR format error for an invalid CIDR block', async () => {
    mockGet
      .mockResolvedValueOnce(networkListEnvelope([]))
      .mockResolvedValue(envelope({ providers: [PROVIDER] }));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openCreate();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /create network/i })).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'my-network' },
    });

    fireEvent.change(screen.getByPlaceholderText(/e\.g\., 10\.0\.0\.0\/16/i), {
      target: { value: 'not-a-cidr' },
    });

    await waitFor(() =>
      expect(screen.queryByDisplayValue('Select a region')).toBeInTheDocument(),
    );
    const regionSelect = screen.getByDisplayValue('Select a region');
    fireEvent.change(regionSelect, { target: { value: 'region-1' } });

    clickModalSubmit(/create network/i);

    await waitFor(() =>
      expect(
        screen.getByText('Invalid CIDR format (e.g., 10.0.0.0/16)'),
      ).toBeInTheDocument(),
    );

    expect(mockPost).not.toHaveBeenCalled();
  });

  it('shows name too short error when name is only one character', async () => {
    mockGet
      .mockResolvedValueOnce(networkListEnvelope([]))
      .mockResolvedValue(envelope({ providers: [] }));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    onActionsReady.mock.calls[0][0].openCreate();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /create network/i })).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByPlaceholderText(/enter network name/i), {
      target: { value: 'x' },
    });

    clickModalSubmit(/create network/i);

    await waitFor(() =>
      expect(
        screen.getByText('Name must be at least 2 characters'),
      ).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Form modal — update submission
  // ---------------------------------------------------------------------------

  it('updates a network via PUT and shows success notification', async () => {
    const updatedNetwork: SystemProviderNetwork = {
      ...NETWORK_A,
      name: 'prod-vpc-renamed',
    };

    mockGet
      .mockResolvedValueOnce(networkListEnvelope([NETWORK_A]))
      .mockResolvedValue(envelope({ providers: [PROVIDER] }));

    mockPut.mockResolvedValue(envelope({ network: updatedNetwork }));

    renderTab();

    await waitFor(() => expect(screen.getAllByText('prod-vpc').length).toBeGreaterThan(0));

    clickMoreButton();

    await waitFor(() => expect(screen.getByText('Edit')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Edit'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /edit network/i })).toBeInTheDocument(),
    );

    // Change the name
    const nameInput = screen.getByDisplayValue('prod-vpc');
    fireEvent.change(nameInput, { target: { value: 'prod-vpc-renamed' } });

    fireEvent.click(screen.getByRole('button', { name: /update network/i }));

    await waitFor(() =>
      expect(mockPut).toHaveBeenCalledWith(
        '/system/provider_networks/net-a',
        expect.objectContaining({
          network: expect.objectContaining({ name: 'prod-vpc-renamed' }),
        }),
      ),
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success' }),
      ),
    );
  });
});
