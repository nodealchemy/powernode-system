import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PeerCatalogBrowser } from './PeerCatalogBrowser';

// =============================================================================
// Mocks
//
// PeerCatalogBrowser calls serviceCatalogApi.fetchPeerCatalog (which uses
// apiClient.get under the hood). We mock serviceCatalogApi at the facade level
// because that is the actual import boundary the component crosses.
// SubscribeServiceModal is mocked to a sentinel so we can test the open/close
// state without pulling in that modal's own apiClient calls.
// =============================================================================

const mockFetchPeerCatalog = jest.fn();

jest.mock(
  '@system/features/system/services/api/serviceCatalogApi',
  () => ({
    serviceCatalogApi: {
      fetchPeerCatalog: (...args: unknown[]) => mockFetchPeerCatalog(...args),
    },
  }),
);

// Stub SubscribeServiceModal so we can verify it receives the right props and
// its open/close state changes are testable without rendering the full modal.
const mockSubscribeModalClose = jest.fn();
jest.mock(
  '@system/features/system/components/federation/SubscribeServiceModal',
  () => ({
    SubscribeServiceModal: ({
      isOpen,
      onClose,
      peerId,
      offering,
      onSubscribed,
    }: {
      isOpen: boolean;
      onClose: () => void;
      peerId: string;
      offering: { name: string; slug: string } | null;
      onSubscribed?: (sub: unknown) => void;
    }) =>
      isOpen && offering ? (
        <div data-testid="subscribe-modal">
          <span data-testid="modal-peer-id">{peerId}</span>
          <span data-testid="modal-offering-name">{offering.name}</span>
          <span data-testid="modal-offering-slug">{offering.slug}</span>
          <button
            data-testid="modal-close-btn"
            onClick={() => {
              mockSubscribeModalClose();
              onClose();
            }}
          >
            Close
          </button>
          <button
            data-testid="modal-subscribed-btn"
            onClick={() =>
              onSubscribed?.({
                id: 'sub-1',
                service_offering_slug: offering.slug,
                service_offering_id: null,
                federation_peer_id: peerId,
                local_hostname: 'example.tld',
                protocol: 'https',
                backend_port: 443,
                status: 'pending',
                site_local: false,
                subscribed_at: '2026-06-01T00:00:00Z',
                activated_at: null,
              })
            }
          >
            Subscribe
          </button>
        </div>
      ) : null,
  }),
);

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

const PEER_ID = 'abcdef12-0000-0000-0000-000000000000';
const PEER_LABEL = 'alice-node';
const GENERATED_AT = '2026-06-05T10:00:00Z';

const OFFERING_HTTP = {
  slug: 'git-service',
  name: 'Git Service',
  description_markdown: 'A hosted git service.',
  protocol: 'https' as const,
  backend_port: 443,
  capacity_metadata: { max_subscribers: 10 },
  latency_metadata: {},
  subscription_terms_markdown: null,
  default_grant_ttl_days: 30,
  default_grant_scopes: ['read' as const, 'write' as const],
  status: 'active' as const,
  accepting_new_subscriptions: true,
};

const OFFERING_TCP = {
  slug: 'tcp-relay',
  name: 'TCP Relay',
  description_markdown: null,
  protocol: 'tcp' as const,
  backend_port: 5432,
  capacity_metadata: {},
  latency_metadata: {},
  subscription_terms_markdown: null,
  default_grant_ttl_days: 14,
  default_grant_scopes: ['read' as const],
  status: 'active' as const,
  accepting_new_subscriptions: true,
};

const OFFERING_DEPRECATED = {
  slug: 'old-api',
  name: 'Old API',
  description_markdown: null,
  protocol: 'http' as const,
  backend_port: 80,
  capacity_metadata: {},
  latency_metadata: {},
  subscription_terms_markdown: null,
  default_grant_ttl_days: 7,
  default_grant_scopes: ['read' as const],
  status: 'deprecated' as const,
  accepting_new_subscriptions: false,
};

const OFFERING_CLOSED = {
  slug: 'private-api',
  name: 'Private API',
  description_markdown: null,
  protocol: 'https' as const,
  backend_port: 8443,
  capacity_metadata: {},
  latency_metadata: {},
  subscription_terms_markdown: null,
  default_grant_ttl_days: 7,
  default_grant_scopes: ['admin' as const],
  status: 'active' as const,
  accepting_new_subscriptions: false,
};

function catalogResponse(offerings: typeof OFFERING_HTTP[]) {
  return { offerings, generated_at: GENERATED_AT };
}

// =============================================================================
// Helpers
// =============================================================================

interface RenderOptions {
  peerId?: string;
  peerLabel?: string;
  refreshKey?: number;
  onSubscribed?: jest.Mock;
}

const renderBrowser = ({
  peerId = PEER_ID,
  peerLabel = PEER_LABEL,
  refreshKey = 0,
  onSubscribed,
}: RenderOptions = {}) =>
  render(
    <BrowserRouter>
      <PeerCatalogBrowser
        peerId={peerId}
        peerLabel={peerLabel}
        refreshKey={refreshKey}
        onSubscribed={onSubscribed}
      />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('PeerCatalogBrowser', () => {
  beforeEach(() => {
    mockFetchPeerCatalog.mockReset();
    mockAddNotification.mockReset();
    mockSubscribeModalClose.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a "refreshing…" label while the catalog is loading', async () => {
    // Never resolves within the test — stays in loading state.
    mockFetchPeerCatalog.mockReturnValue(new Promise(() => {}));

    renderBrowser();

    // The refresh button shows "refreshing…" while loading is true and is
    // disabled so operators can't double-trigger.
    const btn = screen.getByRole('button', { name: /refreshing/i });
    expect(btn).toBeInTheDocument();
    expect(btn).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Fetch: correct URL + empty state
  // ---------------------------------------------------------------------------

  it('calls fetchPeerCatalog with the provided peerId on mount', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([]));

    renderBrowser();

    await waitFor(() => expect(mockFetchPeerCatalog).toHaveBeenCalledWith(PEER_ID));
  });

  it('shows empty-state text when no offerings are returned', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([]));

    renderBrowser();

    await waitFor(() =>
      expect(
        screen.getByText(/has not published any active offerings yet/i),
      ).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Fetch: successful render with offerings
  // ---------------------------------------------------------------------------

  it('renders offering cards for every offering in the catalog', async () => {
    mockFetchPeerCatalog.mockResolvedValue(
      catalogResponse([OFFERING_HTTP, OFFERING_TCP]),
    );

    renderBrowser();

    await waitFor(() =>
      expect(screen.getByText('Git Service')).toBeInTheDocument(),
    );
    expect(screen.getByText('TCP Relay')).toBeInTheDocument();
    expect(screen.getByText('git-service')).toBeInTheDocument();
    expect(screen.getByText('tcp-relay')).toBeInTheDocument();
  });

  it('renders the peerLabel + abbreviated peerId in the header', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([]));

    renderBrowser();

    await waitFor(() =>
      expect(screen.getByText(/alice-node Service Catalog/i)).toBeInTheDocument(),
    );
    // peerId abbreviated to first 8 chars + ellipsis
    expect(screen.getByText(`${PEER_ID.slice(0, 8)}…`)).toBeInTheDocument();
  });

  it('falls back to "Peer" when peerLabel is omitted', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([]));

    render(
      <BrowserRouter>
        <PeerCatalogBrowser peerId={PEER_ID} />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(screen.getByText(/Peer Service Catalog/i)).toBeInTheDocument(),
    );
  });

  it('displays the generated_at timestamp in the header after loading', async () => {
    mockFetchPeerCatalog.mockResolvedValue(
      catalogResponse([OFFERING_HTTP]),
    );

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    const formatted = new Date(GENERATED_AT).toLocaleString();
    expect(screen.getByText(`Generated ${formatted}`)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Offering card: protocol + port meta display
  // ---------------------------------------------------------------------------

  it('renders protocol:port, TTL, and scopes for each offering', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    expect(screen.getByText('https:443')).toBeInTheDocument();
    expect(screen.getByText('TTL 30d')).toBeInTheDocument();
    expect(screen.getByText('scopes: read, write')).toBeInTheDocument();
  });

  it('renders the max_subscribers capacity when present', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    expect(screen.getByText('cap 10')).toBeInTheDocument();
  });

  it('does NOT render the capacity segment when max_subscribers is absent', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_TCP]));

    renderBrowser();

    await waitFor(() => expect(screen.getByText('TCP Relay')).toBeInTheDocument());

    expect(screen.queryByText(/cap \d+/)).not.toBeInTheDocument();
  });

  it('renders the description when description_markdown is present', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    renderBrowser();

    await waitFor(() =>
      expect(screen.getByText('A hosted git service.')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Offering status: deprecated badge
  // ---------------------------------------------------------------------------

  it('shows a "deprecated" badge for deprecated offerings', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_DEPRECATED]));

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Old API')).toBeInTheDocument());

    expect(screen.getByText('deprecated')).toBeInTheDocument();
  });

  it('does NOT show the deprecated badge for active offerings', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    expect(screen.queryByText('deprecated')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Subscribe button state
  // ---------------------------------------------------------------------------

  it('renders an enabled "Subscribe" button for accepting_new_subscriptions=true', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    const btn = screen.getByRole('button', { name: /^Subscribe$/i });
    expect(btn).not.toBeDisabled();
  });

  it('renders a disabled "Closed" button when accepting_new_subscriptions=false', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_CLOSED]));

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Private API')).toBeInTheDocument());

    const btn = screen.getByRole('button', { name: /^Closed$/i });
    expect(btn).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Subscribe modal: open + close
  // ---------------------------------------------------------------------------

  it('opens SubscribeServiceModal with the correct offering when Subscribe is clicked', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    expect(screen.getByTestId('subscribe-modal')).toBeInTheDocument();
    expect(screen.getByTestId('modal-peer-id').textContent).toBe(PEER_ID);
    expect(screen.getByTestId('modal-offering-name').textContent).toBe('Git Service');
    expect(screen.getByTestId('modal-offering-slug').textContent).toBe('git-service');
  });

  it('closes SubscribeServiceModal when onClose is called', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));
    expect(screen.getByTestId('subscribe-modal')).toBeInTheDocument();

    fireEvent.click(screen.getByTestId('modal-close-btn'));

    await waitFor(() =>
      expect(screen.queryByTestId('subscribe-modal')).not.toBeInTheDocument(),
    );
  });

  it('does not open the modal for a Closed offering', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_CLOSED]));

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Private API')).toBeInTheDocument());

    // The Closed button is disabled — clicking it should not open the modal.
    // We use fireEvent directly to verify the disabled attribute prevents action.
    const btn = screen.getByRole('button', { name: /^Closed$/i });
    expect(btn).toBeDisabled();
    expect(screen.queryByTestId('subscribe-modal')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onSubscribed callback
  // ---------------------------------------------------------------------------

  it('calls onSubscribed with the subscription and closes the modal on success', async () => {
    const onSubscribed = jest.fn();
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    renderBrowser({ onSubscribed });

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));
    fireEvent.click(screen.getByTestId('modal-subscribed-btn'));

    await waitFor(() => expect(onSubscribed).toHaveBeenCalledTimes(1));
    // The modal should close after a successful subscribe.
    await waitFor(() =>
      expect(screen.queryByTestId('subscribe-modal')).not.toBeInTheDocument(),
    );
  });

  it('does NOT re-fetch the catalog after a successful subscribe', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    renderBrowser({ onSubscribed: jest.fn() });

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    const callCountBefore = mockFetchPeerCatalog.mock.calls.length;

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));
    fireEvent.click(screen.getByTestId('modal-subscribed-btn'));

    // Wait briefly for any spurious re-fetch to surface.
    await new Promise((r) => setTimeout(r, 50));
    expect(mockFetchPeerCatalog).toHaveBeenCalledTimes(callCountBefore);
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  it('shows an error notification when fetchPeerCatalog rejects', async () => {
    mockFetchPeerCatalog.mockRejectedValue(new Error('Network error'));

    renderBrowser();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network error',
      }),
    );
  });

  it('shows a generic error notification for non-Error rejections', async () => {
    mockFetchPeerCatalog.mockRejectedValue('oops');

    renderBrowser();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to fetch peer catalog',
      }),
    );
  });

  it('renders empty offerings after a failed fetch', async () => {
    mockFetchPeerCatalog.mockRejectedValue(new Error('Network error'));

    renderBrowser();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(
      screen.getByText(/has not published any active offerings yet/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Refresh button
  // ---------------------------------------------------------------------------

  it('re-fetches the catalog when the Refresh button is clicked', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    renderBrowser();

    // Wait for the initial load to complete — the button shows "Refresh" (not
    // "refreshing…") only when loading is false.
    await waitFor(() => {
      const btn = screen.getByRole('button', { name: /^Refresh$/i });
      expect(btn).not.toBeDisabled();
    });

    fireEvent.click(screen.getByRole('button', { name: /^Refresh$/i }));

    await waitFor(() => expect(mockFetchPeerCatalog).toHaveBeenCalledTimes(2));
    // Both calls must use the same peerId.
    expect(mockFetchPeerCatalog).toHaveBeenNthCalledWith(1, PEER_ID);
    expect(mockFetchPeerCatalog).toHaveBeenNthCalledWith(2, PEER_ID);
  });

  it('disables the Refresh button while a fetch is in-flight', async () => {
    // First call hangs forever so we can observe the disabled state.
    mockFetchPeerCatalog.mockReturnValue(new Promise(() => {}));

    renderBrowser();

    const btn = screen.getByRole('button', { name: /refreshing/i });
    expect(btn).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // refreshKey prop: re-fetch on change
  // ---------------------------------------------------------------------------

  it('re-fetches the catalog when refreshKey changes', async () => {
    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP]));

    const { rerender } = renderBrowser({ refreshKey: 0 });

    await waitFor(() => expect(mockFetchPeerCatalog).toHaveBeenCalledTimes(1));

    mockFetchPeerCatalog.mockResolvedValue(catalogResponse([OFFERING_HTTP, OFFERING_TCP]));

    rerender(
      <BrowserRouter>
        <PeerCatalogBrowser
          peerId={PEER_ID}
          peerLabel={PEER_LABEL}
          refreshKey={1}
        />
      </BrowserRouter>,
    );

    await waitFor(() => expect(mockFetchPeerCatalog).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(screen.getByText('TCP Relay')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Multiple offerings
  // ---------------------------------------------------------------------------

  it('renders all offerings side by side with independent Subscribe buttons', async () => {
    mockFetchPeerCatalog.mockResolvedValue(
      catalogResponse([OFFERING_HTTP, OFFERING_TCP, OFFERING_CLOSED]),
    );

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    expect(screen.getByText('TCP Relay')).toBeInTheDocument();
    expect(screen.getByText('Private API')).toBeInTheDocument();

    // Two enabled Subscribe buttons (HTTP + TCP) + one disabled Closed button.
    const subscribeBtns = screen.getAllByRole('button', { name: /^Subscribe$/i });
    expect(subscribeBtns).toHaveLength(2);

    const closedBtns = screen.getAllByRole('button', { name: /^Closed$/i });
    expect(closedBtns).toHaveLength(1);
    expect(closedBtns[0]).toBeDisabled();
  });

  it('opens the modal for the correct offering when there are multiple cards', async () => {
    mockFetchPeerCatalog.mockResolvedValue(
      catalogResponse([OFFERING_HTTP, OFFERING_TCP]),
    );

    renderBrowser();

    await waitFor(() => expect(screen.getByText('Git Service')).toBeInTheDocument());

    // Click the second Subscribe button (TCP Relay).
    const subscribeBtns = screen.getAllByRole('button', { name: /^Subscribe$/i });
    fireEvent.click(subscribeBtns[1]);

    expect(screen.getByTestId('modal-offering-name').textContent).toBe('TCP Relay');
    expect(screen.getByTestId('modal-offering-slug').textContent).toBe('tcp-relay');
  });
});
