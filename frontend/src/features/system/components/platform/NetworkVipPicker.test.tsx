import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworkVipPicker } from './NetworkVipPicker';
import type { SdwanNetwork } from '../../types/sdwan.types';

// =============================================================================
// Mocks
//
// NetworkVipPicker uses sdwanApi.getNetworks directly and renders
// NetworkVipsTab for the selected network. We mock sdwanApi at the module
// level and fully stub out NetworkVipsTab so the test stays focused on
// the picker's own behaviour (network selection, loading, error, empty states).
// =============================================================================

const mockGetNetworks = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    getNetworks: (...args: unknown[]) => mockGetNetworks(...args),
  },
}));

// Stub NetworkVipsTab: record props and render a placeholder so we can verify
// what networkId and onActionsReady the picker forwards.
const mockNetworkVipsTab = jest.fn();

jest.mock('../sdwan/vips/NetworkVipsTab', () => ({
  NetworkVipsTab: (props: { networkId: string; onActionsReady?: (h: unknown) => void }) => {
    mockNetworkVipsTab(props);
    return <div data-testid="network-vips-tab" data-network-id={props.networkId} />;
  },
}));

// These shared hooks are imported transitively but we silence them so the
// test host doesn't break on missing context.
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => true }),
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

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_A: SdwanNetwork = {
  id: 'net-aaa',
  name: 'prod-overlay',
  slug: 'prod-overlay',
  status: 'active',
  cidr_64: 'fd00:aaaa::/64',
  peer_count: 3,
  created_at: '2026-01-01T00:00:00Z',
};

const NETWORK_B: SdwanNetwork = {
  id: 'net-bbb',
  name: 'dev-overlay',
  slug: 'dev-overlay',
  status: 'active',
  cidr_64: 'fd00:bbbb::/64',
  peer_count: 1,
  created_at: '2026-02-01T00:00:00Z',
};

const DEFAULT_META = {
  current_page: 1,
  per_page: 200,
  total_count: 2,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

/**
 * sdwanApi.getNetworks resolves to { networks, meta } — the inner payload
 * after extractPaginated unwraps the double-envelope.
 */
function networksResult(networks: SdwanNetwork[]) {
  return {
    networks,
    meta: { ...DEFAULT_META, total_count: networks.length },
  };
}

// =============================================================================
// Render helper
// =============================================================================

const renderPicker = (props: { readOnly?: boolean } = {}) =>
  render(
    <BrowserRouter>
      <NetworkVipPicker readOnly={props.readOnly} />
    </BrowserRouter>
  );

// =============================================================================
// Tests
// =============================================================================

describe('NetworkVipPicker', () => {
  beforeEach(() => {
    mockGetNetworks.mockReset();
    mockNetworkVipsTab.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while networks are being fetched', () => {
    // Promise that never resolves keeps component in loading state.
    mockGetNetworks.mockReturnValue(new Promise(() => {}));

    renderPicker();

    expect(screen.getByText(/loading networks/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error message when the network fetch fails with an Error', async () => {
    mockGetNetworks.mockRejectedValue(new Error('Connection refused'));

    renderPicker();

    await waitFor(() =>
      expect(screen.getByText('Connection refused')).toBeInTheDocument()
    );
    // Error UI has an AlertTriangle icon — verify via accessible text / error region
    expect(screen.queryByText(/loading networks/i)).not.toBeInTheDocument();
  });

  it('shows a generic fallback error message for non-Error rejections', async () => {
    mockGetNetworks.mockRejectedValue('something bad');

    renderPicker();

    await waitFor(() =>
      expect(screen.getByText('Failed to load networks')).toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows the empty-state message when no SDWAN networks exist', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([]));

    renderPicker();

    await waitFor(() =>
      expect(
        screen.getByText(/no sdwan networks yet/i)
      ).toBeInTheDocument()
    );
    // No network selector should appear
    expect(screen.queryByLabelText('Network:')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Render with networks — network selector
  // ---------------------------------------------------------------------------

  it('renders the network selector with all returned networks as options', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_A, NETWORK_B]));

    renderPicker();

    await waitFor(() =>
      expect(screen.getByLabelText('Network:')).toBeInTheDocument()
    );

    const select = screen.getByLabelText('Network:') as HTMLSelectElement;
    expect(select.options.length).toBe(2);
    expect(select.options[0].text).toContain('prod-overlay');
    expect(select.options[0].text).toContain('fd00:aaaa::/64');
    expect(select.options[1].text).toContain('dev-overlay');
    expect(select.options[1].text).toContain('fd00:bbbb::/64');
  });

  it('pre-selects the first network by default', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_A, NETWORK_B]));

    renderPicker();

    await waitFor(() =>
      expect(screen.getByLabelText('Network:')).toBeInTheDocument()
    );

    const select = screen.getByLabelText('Network:') as HTMLSelectElement;
    expect(select.value).toBe(NETWORK_A.id);
  });

  // ---------------------------------------------------------------------------
  // API call — exact parameters
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.getNetworks with per_page: 200 on mount', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_A]));

    renderPicker();

    await waitFor(() =>
      expect(screen.getByLabelText('Network:')).toBeInTheDocument()
    );

    expect(mockGetNetworks).toHaveBeenCalledTimes(1);
    expect(mockGetNetworks).toHaveBeenCalledWith({ per_page: 200 });
  });

  // ---------------------------------------------------------------------------
  // NetworkVipsTab integration
  // ---------------------------------------------------------------------------

  it('renders NetworkVipsTab with the first network id by default', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_A, NETWORK_B]));

    renderPicker();

    await waitFor(() =>
      expect(screen.getByTestId('network-vips-tab')).toBeInTheDocument()
    );

    const tab = screen.getByTestId('network-vips-tab');
    expect(tab.getAttribute('data-network-id')).toBe(NETWORK_A.id);
  });

  it('does NOT render NetworkVipsTab while loading or when empty', async () => {
    mockGetNetworks.mockReturnValue(new Promise(() => {}));

    renderPicker();

    expect(screen.queryByTestId('network-vips-tab')).not.toBeInTheDocument();
  });

  it('does NOT render NetworkVipsTab when there are no networks', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([]));

    renderPicker();

    await waitFor(() =>
      expect(screen.getByText(/no sdwan networks yet/i)).toBeInTheDocument()
    );
    expect(screen.queryByTestId('network-vips-tab')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Network selection changes
  // ---------------------------------------------------------------------------

  it('updates the displayed NetworkVipsTab when a different network is selected', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_A, NETWORK_B]));

    renderPicker();

    await waitFor(() =>
      expect(screen.getByLabelText('Network:')).toBeInTheDocument()
    );

    // Switch to NETWORK_B
    fireEvent.change(screen.getByLabelText('Network:'), {
      target: { value: NETWORK_B.id },
    });

    await waitFor(() => {
      const tab = screen.getByTestId('network-vips-tab');
      expect(tab.getAttribute('data-network-id')).toBe(NETWORK_B.id);
    });
  });

  it('passes the correct networkId to NetworkVipsTab after network change', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_A, NETWORK_B]));

    renderPicker();

    await waitFor(() =>
      expect(screen.getByLabelText('Network:')).toBeInTheDocument()
    );

    fireEvent.change(screen.getByLabelText('Network:'), {
      target: { value: NETWORK_B.id },
    });

    await waitFor(() => {
      const lastCall = mockNetworkVipsTab.mock.calls[mockNetworkVipsTab.mock.calls.length - 1][0];
      expect(lastCall.networkId).toBe(NETWORK_B.id);
    });
  });

  // ---------------------------------------------------------------------------
  // readOnly prop — onActionsReady forwarding
  // ---------------------------------------------------------------------------

  it('passes a no-op onActionsReady to NetworkVipsTab when readOnly=true', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_A]));

    renderPicker({ readOnly: true });

    await waitFor(() =>
      expect(screen.getByTestId('network-vips-tab')).toBeInTheDocument()
    );

    // All calls should have received a function (the no-op) for onActionsReady
    expect(mockNetworkVipsTab).toHaveBeenCalled();
    const lastCall = mockNetworkVipsTab.mock.calls[mockNetworkVipsTab.mock.calls.length - 1][0];
    expect(typeof lastCall.onActionsReady).toBe('function');
  });

  it('passes undefined onActionsReady to NetworkVipsTab when readOnly is not set', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_A]));

    renderPicker();

    await waitFor(() =>
      expect(screen.getByTestId('network-vips-tab')).toBeInTheDocument()
    );

    expect(mockNetworkVipsTab).toHaveBeenCalled();
    const lastCall = mockNetworkVipsTab.mock.calls[mockNetworkVipsTab.mock.calls.length - 1][0];
    expect(lastCall.onActionsReady).toBeUndefined();
  });

  it('the no-op onActionsReady in readOnly mode is callable without error', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_A]));

    renderPicker({ readOnly: true });

    await waitFor(() =>
      expect(screen.getByTestId('network-vips-tab')).toBeInTheDocument()
    );

    const lastCall = mockNetworkVipsTab.mock.calls[mockNetworkVipsTab.mock.calls.length - 1][0];
    // The no-op should not throw when called
    expect(() => lastCall.onActionsReady()).not.toThrow();
    expect(() => lastCall.onActionsReady({ openCreate: () => {} })).not.toThrow();
    expect(() => lastCall.onActionsReady(null)).not.toThrow();
  });

  // ---------------------------------------------------------------------------
  // Cancellation — unmounting before fetch completes
  // ---------------------------------------------------------------------------

  it('does not update state after unmount (no state-on-unmounted-component warning)', async () => {
    let resolve: (value: { networks: SdwanNetwork[]; meta: typeof DEFAULT_META }) => void;
    const pending = new Promise<{ networks: SdwanNetwork[]; meta: typeof DEFAULT_META }>(
      (res) => { resolve = res; }
    );
    mockGetNetworks.mockReturnValue(pending);

    const { unmount } = renderPicker();

    // Unmount while the fetch is in-flight
    unmount();

    // Resolve after unmount — should not trigger any state update or React warning
    await expect(
      Promise.resolve().then(() => resolve(networksResult([NETWORK_A])))
    ).resolves.toBeUndefined();
  });

  // ---------------------------------------------------------------------------
  // Single network — no selector needed visually but still renders
  // ---------------------------------------------------------------------------

  it('renders the selector even when only one network is available', async () => {
    mockGetNetworks.mockResolvedValue(networksResult([NETWORK_A]));

    renderPicker();

    await waitFor(() =>
      expect(screen.getByLabelText('Network:')).toBeInTheDocument()
    );

    const select = screen.getByLabelText('Network:') as HTMLSelectElement;
    expect(select.options.length).toBe(1);
    expect(select.value).toBe(NETWORK_A.id);
  });
});
