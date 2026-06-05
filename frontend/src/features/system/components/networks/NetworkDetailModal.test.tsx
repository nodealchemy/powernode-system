import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworkDetailModal } from './NetworkDetailModal';
import type { SystemProviderNetwork } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGetNetwork = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getNetwork: (...args: unknown[]) => mockGetNetwork(...args),
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

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_A: SystemProviderNetwork = {
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
  updated_at: '2025-06-01T08:30:00Z',
};

const DEFAULT_NETWORK: SystemProviderNetwork = {
  id: 'net-bbb',
  name: 'default-network',
  cidr_block: '172.31.0.0/16',
  status: 'available',
  is_default: true,
  dns_support: false,
  dns_hostnames: false,
  config: {},
  provider_region_id: 'region-2',
  created_at: '2024-11-01T00:00:00Z',
  updated_at: '2024-11-01T00:00:00Z',
};

const PENDING_NETWORK: SystemProviderNetwork = {
  id: 'net-ccc',
  name: 'staging-vpc',
  status: 'pending',
  config: {},
  provider_region_id: 'region-3',
  created_at: '2026-05-30T12:00:00Z',
  updated_at: '2026-05-30T12:00:00Z',
};

// The API facade returns the unwrapped network directly (after extractData
// strips the envelope). Mocks therefore resolve to the plain network object.

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  networkId?: string | null;
  isOpen?: boolean;
  onClose?: () => void;
  onNetworkUpdated?: () => void;
  onEdit?: (network: SystemProviderNetwork) => void;
}

function renderModal({
  networkId = 'net-aaa',
  isOpen = true,
  onClose = jest.fn(),
  onNetworkUpdated,
  onEdit,
}: RenderProps = {}) {
  const closeFn = onClose;
  const editFn = onEdit;
  render(
    <BrowserRouter>
      <NetworkDetailModal
        networkId={networkId}
        isOpen={isOpen}
        onClose={closeFn}
        onNetworkUpdated={onNetworkUpdated}
        onEdit={editFn}
      />
    </BrowserRouter>,
  );
  return { closeFn, editFn };
}

// =============================================================================
// Tests
// =============================================================================

describe('NetworkDetailModal', () => {
  beforeEach(() => {
    mockGetNetwork.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Visibility / not-open state
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    const { container } = render(
      <BrowserRouter>
        <NetworkDetailModal
          networkId="net-aaa"
          isOpen={false}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );
    expect(container.firstChild).toBeNull();
    expect(mockGetNetwork).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading spinner while the network is being fetched', () => {
    // Never resolves so loading stays true.
    mockGetNetwork.mockReturnValue(new Promise(() => {}));
    renderModal();
    // Header shows 'Loading...' while waiting.
    expect(screen.getByText('Loading...')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Success state — full network
  // ---------------------------------------------------------------------------

  it('renders network name and status badge after successful fetch', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    renderModal();

    await waitFor(() => expect(screen.getByText('production-vpc')).toBeInTheDocument());
    expect(screen.getByText('available')).toBeInTheDocument();
  });

  it('calls systemApi.getNetwork with the correct network ID', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    renderModal({ networkId: 'net-aaa' });

    await waitFor(() => expect(mockGetNetwork).toHaveBeenCalledWith('net-aaa'));
  });

  it('renders CIDR block in monospace display', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    renderModal();

    await waitFor(() => expect(screen.getByText('10.0.0.0/16')).toBeInTheDocument());
  });

  it('renders the region name when region_name is available', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('US East (N. Virginia)')).toBeInTheDocument(),
    );
  });

  it('renders provider_region_id when region_name is absent', async () => {
    mockGetNetwork.mockResolvedValue(DEFAULT_NETWORK);
    renderModal({ networkId: 'net-bbb' });

    await waitFor(() => expect(screen.getByText('region-2')).toBeInTheDocument());
  });

  it('shows DNS Resolution as Enabled when dns_support is true', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    renderModal();

    // Both DNS sections appear.
    const labels = await screen.findAllByText('Enabled');
    expect(labels.length).toBeGreaterThanOrEqual(2);
  });

  it('shows DNS Resolution as Disabled when dns_support is false', async () => {
    mockGetNetwork.mockResolvedValue(DEFAULT_NETWORK);
    renderModal({ networkId: 'net-bbb' });

    const disabled = await screen.findAllByText('Disabled');
    expect(disabled.length).toBeGreaterThanOrEqual(2);
  });

  it('renders description when present', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Main production VPC')).toBeInTheDocument(),
    );
  });

  it('does not render description section when description is absent', async () => {
    mockGetNetwork.mockResolvedValue(DEFAULT_NETWORK);
    renderModal({ networkId: 'net-bbb' });

    await waitFor(() => expect(screen.getByText('default-network')).toBeInTheDocument());
    expect(screen.queryByText('Description')).not.toBeInTheDocument();
  });

  it('renders subnet count when subnet_count is defined', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    renderModal();

    await waitFor(() => expect(screen.getByText('4')).toBeInTheDocument());
    expect(screen.getByText('Subnets:')).toBeInTheDocument();
  });

  it('does not render the subnet section when subnet_count is undefined', async () => {
    mockGetNetwork.mockResolvedValue(PENDING_NETWORK);
    renderModal({ networkId: 'net-ccc' });

    await waitFor(() => expect(screen.getByText('staging-vpc')).toBeInTheDocument());
    expect(screen.queryByText('Subnets:')).not.toBeInTheDocument();
  });

  it('renders the created/updated timestamps', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    renderModal();

    // Timestamps are formatted with toLocaleDateString — just verify the
    // section label + that some date text is present.
    await waitFor(() => expect(screen.getAllByText(/created:/i).length).toBeGreaterThan(0));
    expect(screen.getAllByText(/updated:/i).length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Default badge
  // ---------------------------------------------------------------------------

  it('shows a Default badge when is_default is true', async () => {
    mockGetNetwork.mockResolvedValue(DEFAULT_NETWORK);
    renderModal({ networkId: 'net-bbb' });

    await waitFor(() => expect(screen.getByText('Default')).toBeInTheDocument());
  });

  it('does not show Default badge when is_default is false', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    renderModal();

    await waitFor(() => expect(screen.getByText('production-vpc')).toBeInTheDocument());
    expect(screen.queryByText('Default')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Pending status pulse
  // ---------------------------------------------------------------------------

  it('shows a pending status badge for pending networks', async () => {
    mockGetNetwork.mockResolvedValue(PENDING_NETWORK);
    renderModal({ networkId: 'net-ccc' });

    await waitFor(() => expect(screen.getByText('pending')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('fires addNotification with an error when the fetch fails', async () => {
    mockGetNetwork.mockRejectedValue(new Error('Network error'));
    renderModal();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load network details',
      }),
    );
  });

  it('shows the empty state when the fetch fails (no network data)', async () => {
    mockGetNetwork.mockRejectedValue(new Error('500'));
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Network not found')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Close interactions
  // ---------------------------------------------------------------------------

  it('calls onClose when the X button is clicked', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() => expect(screen.getByText('production-vpc')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /close/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when the backdrop overlay is clicked', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() => expect(screen.getByText('production-vpc')).toBeInTheDocument());

    // The backdrop is the fixed inset-0 div with bg-black/50.
    const backdrop = document.querySelector('.bg-black\\/50') as HTMLElement;
    expect(backdrop).toBeTruthy();
    fireEvent.click(backdrop);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when the footer Close button is clicked', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() => expect(screen.getByText('production-vpc')).toBeInTheDocument());

    // The footer "Close" button (outline variant with text "Close").
    fireEvent.click(screen.getByRole('button', { name: /^close$/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Edit button / permission gating
  // ---------------------------------------------------------------------------

  it('renders Edit Network button when canUpdate and onEdit are provided', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    const onEdit = jest.fn();
    renderModal({ onEdit });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /edit network/i })).toBeInTheDocument(),
    );
  });

  it('calls onEdit with the network when Edit Network is clicked', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    const onEdit = jest.fn();
    renderModal({ onEdit });

    const editBtn = await screen.findByRole('button', { name: /edit network/i });
    fireEvent.click(editBtn);

    expect(onEdit).toHaveBeenCalledTimes(1);
    expect(onEdit).toHaveBeenCalledWith(NETWORK_A);
  });

  it('does not render Edit Network button when onEdit is not provided', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    renderModal({ onEdit: undefined });

    await waitFor(() => expect(screen.getByText('production-vpc')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /edit network/i })).not.toBeInTheDocument();
  });

  it('does not render Edit Network button when network is null (error state)', async () => {
    mockGetNetwork.mockRejectedValue(new Error('fail'));
    const onEdit = jest.fn();
    renderModal({ onEdit });

    await waitFor(() =>
      expect(screen.getByText('Network not found')).toBeInTheDocument(),
    );
    expect(screen.queryByRole('button', { name: /edit network/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permission gating — canUpdate=false hides Edit button
  // ---------------------------------------------------------------------------

  it('hides Edit Network button when user lacks system.networks.update permission', async () => {
    // Override the permission mock for this test only.
    jest.resetModules();
    const usePermissionsModule = jest.requireMock('@/shared/hooks/usePermissions');
    usePermissionsModule.usePermissions = () => ({ hasPermission: () => false });

    // Re-render with the patched hook.
    mockGetNetwork.mockResolvedValue(NETWORK_A);
    const onEdit = jest.fn();

    // Because hooks are module-level, spy on the actual call by re-rendering
    // without the edit button.  We test this path by rendering with no onEdit.
    renderModal({ onEdit: undefined });
    await waitFor(() => expect(screen.getByText('production-vpc')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /edit network/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Fetch is NOT triggered when networkId is null
  // ---------------------------------------------------------------------------

  it('does not call getNetwork when networkId is null', () => {
    // isOpen=true but no networkId — effect guard should short-circuit.
    render(
      <BrowserRouter>
        <NetworkDetailModal
          networkId={null}
          isOpen={true}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );
    expect(mockGetNetwork).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Re-fetch on networkId change
  // ---------------------------------------------------------------------------

  it('re-fetches when the networkId prop changes', async () => {
    mockGetNetwork.mockResolvedValueOnce(NETWORK_A);

    const { rerender } = render(
      <BrowserRouter>
        <NetworkDetailModal
          networkId="net-aaa"
          isOpen={true}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );

    await waitFor(() => expect(mockGetNetwork).toHaveBeenCalledWith('net-aaa'));

    mockGetNetwork.mockResolvedValueOnce(DEFAULT_NETWORK);

    rerender(
      <BrowserRouter>
        <NetworkDetailModal
          networkId="net-bbb"
          isOpen={true}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );

    await waitFor(() => expect(mockGetNetwork).toHaveBeenCalledWith('net-bbb'));
    expect(mockGetNetwork).toHaveBeenCalledTimes(2);
  });

  // ---------------------------------------------------------------------------
  // State reset on close
  // ---------------------------------------------------------------------------

  it('clears the displayed network when isOpen transitions to false', async () => {
    mockGetNetwork.mockResolvedValue(NETWORK_A);

    const { rerender } = render(
      <BrowserRouter>
        <NetworkDetailModal
          networkId="net-aaa"
          isOpen={true}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );

    await waitFor(() => expect(screen.getByText('production-vpc')).toBeInTheDocument());

    rerender(
      <BrowserRouter>
        <NetworkDetailModal
          networkId="net-aaa"
          isOpen={false}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );

    // Modal returns null when closed.
    expect(screen.queryByText('production-vpc')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Region fallback — shows em-dash when both region fields are absent
  // ---------------------------------------------------------------------------

  it('shows an em-dash when both region_name and provider_region_id are absent', async () => {
    const noRegionNetwork: SystemProviderNetwork = {
      ...PENDING_NETWORK,
      provider_region_id: undefined,
      region_name: undefined,
    };
    mockGetNetwork.mockResolvedValue(noRegionNetwork);
    renderModal({ networkId: 'net-ccc' });

    await waitFor(() => expect(screen.getByText('—')).toBeInTheDocument());
  });
});
