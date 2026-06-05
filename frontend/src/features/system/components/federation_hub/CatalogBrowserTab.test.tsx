import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { CatalogBrowserTab } from './CatalogBrowserTab';

// =============================================================================
// Mocks
//
// CatalogBrowserTab calls apiClient.get directly to load federation peers.
// PeerCatalogBrowser is mocked to a sentinel so we can verify prop
// passing and peer-selection without pulling in that component's own
// API calls.
// =============================================================================

const mockGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: jest.fn(),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

jest.mock(
  '@system/features/system/components/federation/PeerCatalogBrowser',
  () => ({
    PeerCatalogBrowser: ({
      peerId,
      peerLabel,
    }: {
      peerId: string;
      peerLabel?: string;
    }) => (
      <div data-testid="peer-catalog-browser">
        <span data-testid="browser-peer-id">{peerId}</span>
        {peerLabel !== undefined && (
          <span data-testid="browser-peer-label">{peerLabel}</span>
        )}
      </div>
    ),
  }),
);

// =============================================================================
// Fixtures
// =============================================================================

const PEER_A = {
  id: 'peer-aaaaaa00-0000-0000-0000-000000000001',
  name: 'alice-node',
  remote_instance_url: 'https://alice.example.com',
  peer_kind: 'platform',
  status: 'active',
};

const PEER_B = {
  id: 'peer-bbbbbb00-0000-0000-0000-000000000002',
  name: 'bob-node',
  remote_instance_url: 'https://bob.example.com',
  peer_kind: 'platform',
  status: 'enrolled',
};

const PEER_NO_NAME = {
  id: 'peer-cccccc00-0000-0000-0000-000000000003',
  name: null,
  remote_instance_url: 'https://carol.example.com',
  peer_kind: 'platform',
  status: 'degraded',
};

const PEER_NO_NAME_NO_URL = {
  id: 'peer-dddddd00-0000-0000-0000-000000000004',
  name: null,
  remote_instance_url: null,
  peer_kind: 'platform',
  status: 'active',
};

// Double-envelope as required: AxiosResponse.data = { success: true, data: <payload> }
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function peersResponse(peers: typeof PEER_A[]) {
  return envelope({ federation_peers: peers });
}

// =============================================================================
// Helpers
// =============================================================================

const renderTab = () =>
  render(
    <BrowserRouter>
      <CatalogBrowserTab />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('CatalogBrowserTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while peers are being fetched', () => {
    // Never resolves — stays in loading state.
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByText(/Loading peers/i)).toBeInTheDocument();
  });

  it('does not render the peer selector while loading', () => {
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // API call: correct URL + params
  // ---------------------------------------------------------------------------

  it('fetches federation peers from the correct URL with platform + status filters', async () => {
    mockGet.mockResolvedValue(peersResponse([]));

    renderTab();

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/federation_peers', {
      params: { peer_kind: 'platform', status: 'active,enrolled,degraded' },
    });
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error banner when the API call fails with an Error object', async () => {
    mockGet.mockRejectedValue(new Error('Network timeout'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
    // The error container should be visible.
    expect(screen.queryByText(/Loading peers/i)).not.toBeInTheDocument();
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
  });

  it('shows a generic error message for non-Error rejections', async () => {
    mockGet.mockRejectedValue('something blew up');

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Failed to load peers')).toBeInTheDocument(),
    );
  });

  it('renders an AlertTriangle icon alongside the error message', async () => {
    mockGet.mockRejectedValue(new Error('Boom'));

    renderTab();

    await waitFor(() => expect(screen.getByText('Boom')).toBeInTheDocument());
    // The error container uses the AlertTriangle lucide icon rendered as an SVG.
    const errorDiv = screen.getByText('Boom').closest('div');
    expect(errorDiv).not.toBeNull();
    // The icon is rendered inside the same flex container.
    expect(errorDiv?.querySelector('svg')).toBeTruthy();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows the empty-state message when no peers are returned', async () => {
    mockGet.mockResolvedValue(peersResponse([]));

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText(/No active platform peers/i),
      ).toBeInTheDocument(),
    );
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
    expect(screen.queryByTestId('peer-catalog-browser')).not.toBeInTheDocument();
  });

  it('includes the federation hint in the empty-state copy', async () => {
    mockGet.mockResolvedValue(peersResponse([]));

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText(/Federate with a peer first/i),
      ).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Successful render: peer selector
  // ---------------------------------------------------------------------------

  it('renders a peer selector dropdown when peers are returned', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByRole('combobox')).toBeInTheDocument(),
    );
  });

  it('populates the dropdown with an option for each peer', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const options = screen.getAllByRole('option');
    expect(options).toHaveLength(2);
  });

  it('renders peer name with status in the option label', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A]));

    renderTab();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    expect(screen.getByRole('option', { name: /alice-node \(active\)/i })).toBeInTheDocument();
  });

  it('falls back to remote_instance_url when name is null', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_NO_NAME]));

    renderTab();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    expect(
      screen.getByRole('option', { name: /https:\/\/carol\.example\.com/i }),
    ).toBeInTheDocument();
  });

  it('falls back to truncated id when both name and url are null', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_NO_NAME_NO_URL]));

    renderTab();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const expectedSlice = PEER_NO_NAME_NO_URL.id.slice(0, 8);
    expect(
      screen.getByRole('option', { name: new RegExp(expectedSlice) }),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Auto-selection: first peer pre-selected
  // ---------------------------------------------------------------------------

  it('auto-selects the first peer on load', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const select = screen.getByRole('combobox') as HTMLSelectElement;
    expect(select.value).toBe(PEER_A.id);
  });

  it('renders PeerCatalogBrowser for the auto-selected first peer', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('peer-catalog-browser')).toBeInTheDocument(),
    );

    expect(screen.getByTestId('browser-peer-id').textContent).toBe(PEER_A.id);
  });

  it('passes the peer name as peerLabel to PeerCatalogBrowser', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('peer-catalog-browser')).toBeInTheDocument(),
    );

    expect(screen.getByTestId('browser-peer-label').textContent).toBe(PEER_A.name);
  });

  it('passes remote_instance_url as peerLabel when name is null', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_NO_NAME]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('peer-catalog-browser')).toBeInTheDocument(),
    );

    expect(screen.getByTestId('browser-peer-label').textContent).toBe(
      PEER_NO_NAME.remote_instance_url,
    );
  });

  it('passes undefined peerLabel when both name and url are null', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_NO_NAME_NO_URL]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('peer-catalog-browser')).toBeInTheDocument(),
    );

    // When peerLabel is undefined, the sentinel renders nothing for browser-peer-label.
    expect(screen.queryByTestId('browser-peer-label')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Peer selector: switching peers
  // ---------------------------------------------------------------------------

  it('updates the PeerCatalogBrowser when a different peer is selected', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('peer-catalog-browser')).toBeInTheDocument(),
    );

    // Initially showing PEER_A.
    expect(screen.getByTestId('browser-peer-id').textContent).toBe(PEER_A.id);

    fireEvent.change(screen.getByRole('combobox'), { target: { value: PEER_B.id } });

    await waitFor(() =>
      expect(screen.getByTestId('browser-peer-id').textContent).toBe(PEER_B.id),
    );
  });

  it('shows the correct peerLabel after switching to a different peer', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByRole('combobox'), { target: { value: PEER_B.id } });

    await waitFor(() =>
      expect(screen.getByTestId('browser-peer-label').textContent).toBe(PEER_B.name),
    );
  });

  it('keeps PeerCatalogBrowser mounted when the selected peer changes', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('peer-catalog-browser')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), { target: { value: PEER_B.id } });

    // PeerCatalogBrowser should still be in the DOM (re-rendered with new props).
    expect(screen.getByTestId('peer-catalog-browser')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Single peer: no switching needed
  // ---------------------------------------------------------------------------

  it('renders correctly with a single peer', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('peer-catalog-browser')).toBeInTheDocument(),
    );

    const options = screen.getAllByRole('option');
    expect(options).toHaveLength(1);

    expect(screen.getByTestId('browser-peer-id').textContent).toBe(PEER_A.id);
  });

  // ---------------------------------------------------------------------------
  // Header: Server icon + Peer label present
  // ---------------------------------------------------------------------------

  it('renders the "Peer:" label in the selector bar', async () => {
    mockGet.mockResolvedValue(peersResponse([PEER_A]));

    renderTab();

    await waitFor(() => expect(screen.getByText('Peer:')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // State transitions: loading → empty → error do not leak across re-mounts
  // ---------------------------------------------------------------------------

  it('does not show the error banner after a successful subsequent fetch', async () => {
    // First call: simulate how the component always starts loading=true.
    mockGet.mockResolvedValue(peersResponse([PEER_A]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('peer-catalog-browser')).toBeInTheDocument(),
    );

    expect(screen.queryByText(/Failed to load/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/Network/i)).not.toBeInTheDocument();
  });
});
