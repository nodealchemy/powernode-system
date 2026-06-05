import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ServiceSubscriptionsPanel } from './ServiceSubscriptionsPanel';
import type { ServiceSubscription } from '../../types/service_delivery.types';

// =============================================================================
// Mocks
// =============================================================================

const mockListSubscriptions = jest.fn();
const mockGetSubscription = jest.fn();
const mockCancelSubscription = jest.fn();

jest.mock('@system/features/system/services/api/serviceCatalogApi', () => ({
  serviceCatalogApi: {
    listSubscriptions: (...args: unknown[]) => mockListSubscriptions(...args),
    getSubscription: (...args: unknown[]) => mockGetSubscription(...args),
    cancelSubscription: (...args: unknown[]) => mockCancelSubscription(...args),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// EntityLink calls entityRegistry.getEntity + useEntityModal + usePermissions.
// Stub the entire component so test output is predictable and isolation is clean.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label, id }: { label?: React.ReactNode; id?: string | null }) => (
    <span data-testid="entity-link">{label ?? id}</span>
  ),
}));

// =============================================================================
// Fixtures
// =============================================================================

const SUB_A: ServiceSubscription = {
  id: 'sub-aaa',
  service_offering_slug: 'api-gateway',
  service_offering_id: 'offer-1',
  federation_peer_id: 'peer-deadbeef-1234',
  local_hostname: 'api.myhost.internal',
  protocol: 'https',
  backend_port: 443,
  status: 'active',
  site_local: false,
  subscribed_at: '2026-01-10T08:00:00Z',
  activated_at: '2026-01-10T09:00:00Z',
};

const SUB_B: ServiceSubscription = {
  id: 'sub-bbb',
  service_offering_slug: 'metrics-sink',
  service_offering_id: 'offer-2',
  federation_peer_id: 'peer-cafecafe-5678',
  local_hostname: 'metrics.internal',
  protocol: 'tcp',
  backend_port: 9090,
  status: 'pending',
  site_local: true,
  subscribed_at: '2026-02-01T10:00:00Z',
  activated_at: null,
};

const SUB_CANCELLED: ServiceSubscription = {
  id: 'sub-ccc',
  service_offering_slug: 'old-service',
  service_offering_id: 'offer-3',
  federation_peer_id: 'peer-aabbccdd-9999',
  local_hostname: 'old.internal',
  protocol: 'http',
  backend_port: 80,
  status: 'cancelled',
  site_local: false,
  subscribed_at: '2026-01-01T00:00:00Z',
  activated_at: '2026-01-02T00:00:00Z',
  cancelled_at: '2026-03-01T00:00:00Z',
};

// Detail-enriched version of SUB_A (returned by getSubscription)
const SUB_A_DETAIL: ServiceSubscription = {
  ...SUB_A,
  backend_vip: '10.0.1.50',
  federation_grant_id: 'grant-xyz-999',
  acme_certificate_id: 'cert-abc-111',
  suspended_at: null,
};

function listResponse(subscriptions: ServiceSubscription[]) {
  return { subscriptions, count: subscriptions.length };
}

// =============================================================================
// Render helper
// =============================================================================

const renderPanel = (props: React.ComponentProps<typeof ServiceSubscriptionsPanel> = {}) =>
  render(
    <BrowserRouter>
      <ServiceSubscriptionsPanel {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('ServiceSubscriptionsPanel', () => {
  beforeEach(() => {
    mockListSubscriptions.mockReset();
    mockGetSubscription.mockReset();
    mockCancelSubscription.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render / loading / empty states
  // ---------------------------------------------------------------------------

  it('shows a loading indicator initially before data resolves', async () => {
    mockListSubscriptions.mockReturnValue(new Promise(() => {})); // never resolves
    renderPanel();
    expect(screen.getByText('loading…')).toBeInTheDocument();
  });

  it('shows the subscription count once data loads', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A, SUB_B]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('2 subscriptions')).toBeInTheDocument());
  });

  it('shows singular "subscription" for exactly one result', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('1 subscription')).toBeInTheDocument());
  });

  it('renders empty-state message when the list is empty', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([]));
    renderPanel();
    await waitFor(() =>
      expect(
        screen.getByText(/No active subscriptions/i),
      ).toBeInTheDocument(),
    );
  });

  it('calls listSubscriptions with no params when no filters given', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([]));
    renderPanel();
    await waitFor(() => expect(mockListSubscriptions).toHaveBeenCalledWith({}));
  });

  it('shows an error notification when listSubscriptions rejects', async () => {
    mockListSubscriptions.mockRejectedValue(new Error('network failure'));
    renderPanel();
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'network failure' }),
      ),
    );
  });

  it('shows a generic error message when rejection has no message', async () => {
    mockListSubscriptions.mockRejectedValue('oops');
    renderPanel();
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Failed to load subscriptions' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Table rendering
  // ---------------------------------------------------------------------------

  it('renders one table row per subscription', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A, SUB_B]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('api-gateway')).toBeInTheDocument());
    expect(screen.getByText('metrics-sink')).toBeInTheDocument();
  });

  it('renders status pills for each subscription', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A, SUB_B]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('active')).toBeInTheDocument());
    expect(screen.getByText('pending')).toBeInTheDocument();
  });

  it('renders the local_hostname under each service slug', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('api.myhost.internal')).toBeInTheDocument());
  });

  it('renders (site-local) label for site-local subscriptions', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_B]));
    renderPanel();
    // The site-local flag and hostname share a single text node: "(site-local) metrics.internal"
    await waitFor(() =>
      expect(screen.getByText(/\(site-local\)/)).toBeInTheDocument(),
    );
  });

  it('renders protocol with correct icon cell', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('https')).toBeInTheDocument());
  });

  it('shows the activated_at date when present', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    renderPanel();
    await waitFor(() => {
      const dateStr = new Date(SUB_A.activated_at!).toLocaleDateString();
      expect(screen.getByText(dateStr)).toBeInTheDocument();
    });
  });

  it('shows an em-dash when activated_at is null', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_B]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('—')).toBeInTheDocument());
  });

  it('renders EntityLink for the federation peer', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    renderPanel();
    await waitFor(() => {
      const links = screen.getAllByTestId('entity-link');
      // Peer link should show truncated id
      const peerLabel = `${SUB_A.federation_peer_id.slice(0, 8)}…`;
      expect(links.some((el) => el.textContent === peerLabel)).toBe(true);
    });
  });

  // ---------------------------------------------------------------------------
  // Cancel action visibility
  // ---------------------------------------------------------------------------

  it('shows Cancel button for non-terminal subscriptions', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A, SUB_B]));
    renderPanel();
    await waitFor(() => expect(screen.getAllByTitle('Cancel subscription')).toHaveLength(2));
  });

  it('does NOT show Cancel button for cancelled subscriptions', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_CANCELLED]));
    renderPanel();
    await waitFor(() => expect(screen.queryByTitle('Cancel subscription')).not.toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Cancel flow
  // ---------------------------------------------------------------------------

  it('calls cancelSubscription with id and reason, then refreshes', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    const promptSpy = jest.spyOn(window, 'prompt').mockReturnValue('testing reason');
    const cancelledSub = { ...SUB_A, status: 'cancelled' as const };
    mockCancelSubscription.mockResolvedValue(cancelledSub);
    // Second call returns updated list
    mockListSubscriptions.mockResolvedValueOnce(listResponse([SUB_A]));
    mockListSubscriptions.mockResolvedValue(listResponse([cancelledSub]));

    renderPanel();
    const cancelBtn = await screen.findByTitle('Cancel subscription');
    fireEvent.click(cancelBtn);

    await waitFor(() =>
      expect(mockCancelSubscription).toHaveBeenCalledWith('sub-aaa', 'testing reason'),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: 'Cancelled subscription to "api-gateway"' }),
      ),
    );
    promptSpy.mockRestore();
  });

  it('calls cancelSubscription with undefined reason when prompt returns empty string', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    const promptSpy = jest.spyOn(window, 'prompt').mockReturnValue('');
    mockCancelSubscription.mockResolvedValue({ ...SUB_A, status: 'cancelled' as const });

    renderPanel();
    const cancelBtn = await screen.findByTitle('Cancel subscription');
    fireEvent.click(cancelBtn);

    await waitFor(() =>
      expect(mockCancelSubscription).toHaveBeenCalledWith('sub-aaa', undefined),
    );
    promptSpy.mockRestore();
  });

  it('does not call cancelSubscription when user dismisses the prompt', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    const promptSpy = jest.spyOn(window, 'prompt').mockReturnValue(null);

    renderPanel();
    const cancelBtn = await screen.findByTitle('Cancel subscription');
    fireEvent.click(cancelBtn);

    // Give async code a chance to run
    await new Promise((r) => setTimeout(r, 50));
    expect(mockCancelSubscription).not.toHaveBeenCalled();
    promptSpy.mockRestore();
  });

  it('shows error notification when cancelSubscription fails', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    const promptSpy = jest.spyOn(window, 'prompt').mockReturnValue('reason');
    mockCancelSubscription.mockRejectedValue(new Error('server error'));

    renderPanel();
    const cancelBtn = await screen.findByTitle('Cancel subscription');
    fireEvent.click(cancelBtn);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'server error' }),
      ),
    );
    promptSpy.mockRestore();
  });

  it('shows Cancelling… text while the request is in flight', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    const promptSpy = jest.spyOn(window, 'prompt').mockReturnValue('reason');
    // Never resolves so we can inspect the in-flight state
    mockCancelSubscription.mockReturnValue(new Promise(() => {}));

    renderPanel();
    const cancelBtn = await screen.findByTitle('Cancel subscription');
    fireEvent.click(cancelBtn);

    await waitFor(() => expect(screen.getByText('Cancelling…')).toBeInTheDocument());
    promptSpy.mockRestore();
  });

  // ---------------------------------------------------------------------------
  // Status filter bar
  // ---------------------------------------------------------------------------

  it('renders all status filter buttons', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([]));
    renderPanel();
    await waitFor(() => {
      expect(screen.getByRole('button', { name: 'All' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Active' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Pending' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Suspended' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Cancelled' })).toBeInTheDocument();
    });
  });

  it('re-fetches subscriptions with status filter when a filter is selected', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([]));
    renderPanel();
    await waitFor(() => expect(screen.getByRole('button', { name: 'Active' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Active' }));

    await waitFor(() =>
      expect(mockListSubscriptions).toHaveBeenCalledWith(
        expect.objectContaining({ status: 'active' }),
      ),
    );
  });

  it('clears the filter when All is clicked', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([]));
    renderPanel({ initialStatusFilter: 'active' });
    await waitFor(() => expect(screen.getByRole('button', { name: 'All' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'All' }));

    await waitFor(() => {
      const calls = mockListSubscriptions.mock.calls;
      const lastCall = calls[calls.length - 1][0];
      // null/undefined status → param omitted from the object (via paramsFromFilters)
      expect(lastCall.status === undefined || lastCall.status === null).toBe(true);
    });
  });

  it('applies initialStatusFilter on first fetch', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([]));
    renderPanel({ initialStatusFilter: 'suspended' });
    await waitFor(() =>
      expect(mockListSubscriptions).toHaveBeenCalledWith(
        expect.objectContaining({ status: 'suspended' }),
      ),
    );
  });

  it('scopes to a peer when peerIdFilter is provided', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([]));
    renderPanel({ peerIdFilter: 'peer-xyz' });
    await waitFor(() =>
      expect(mockListSubscriptions).toHaveBeenCalledWith(
        expect.objectContaining({ peer_id: 'peer-xyz' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // refreshKey triggers re-fetch
  // ---------------------------------------------------------------------------

  it('re-fetches when refreshKey changes', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    const { rerender } = render(
      <BrowserRouter>
        <ServiceSubscriptionsPanel refreshKey={0} />
      </BrowserRouter>,
    );
    await waitFor(() => expect(mockListSubscriptions).toHaveBeenCalledTimes(1));

    rerender(
      <BrowserRouter>
        <ServiceSubscriptionsPanel refreshKey={1} />
      </BrowserRouter>,
    );
    await waitFor(() => expect(mockListSubscriptions).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // onSelect callback
  // ---------------------------------------------------------------------------

  it('calls onSelect when a subscription row is clicked', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    const onSelect = jest.fn();
    renderPanel({ onSelect });
    await waitFor(() => expect(screen.getByText('api-gateway')).toBeInTheDocument());

    // Click on the service slug cell
    fireEvent.click(screen.getByText('api-gateway'));
    expect(onSelect).toHaveBeenCalledWith(SUB_A);
  });

  // ---------------------------------------------------------------------------
  // Row expand / detail loading
  // ---------------------------------------------------------------------------

  it('expands the row and fetches detail when expand button is clicked', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    mockGetSubscription.mockResolvedValue(SUB_A_DETAIL);

    renderPanel();
    const expandBtn = await screen.findByTitle('Expand details');
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(mockGetSubscription).toHaveBeenCalledWith('sub-aaa'),
    );
    // Detail section should appear with extra fields
    await waitFor(() => expect(screen.getByText('Backend VIP')).toBeInTheDocument());
    expect(screen.getByText('10.0.1.50')).toBeInTheDocument();
  });

  it('shows federation_grant_id in expanded detail when present', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    mockGetSubscription.mockResolvedValue(SUB_A_DETAIL);

    renderPanel();
    fireEvent.click(await screen.findByTitle('Expand details'));

    await waitFor(() => expect(screen.getByText('grant-xyz-999')).toBeInTheDocument());
  });

  it('shows acme_certificate_id in expanded detail when present', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    mockGetSubscription.mockResolvedValue(SUB_A_DETAIL);

    renderPanel();
    fireEvent.click(await screen.findByTitle('Expand details'));

    await waitFor(() => expect(screen.getByText('ACME Certificate')).toBeInTheDocument());
  });

  it('shows "Loading detail…" while getSubscription is in flight', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    mockGetSubscription.mockReturnValue(new Promise(() => {})); // never resolves

    renderPanel();
    fireEvent.click(await screen.findByTitle('Expand details'));

    await waitFor(() => expect(screen.getByText('Loading detail…')).toBeInTheDocument());
  });

  it('collapses the row when expand button is clicked again', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    mockGetSubscription.mockResolvedValue(SUB_A_DETAIL);

    renderPanel();
    const expandBtn = await screen.findByTitle('Expand details');
    fireEvent.click(expandBtn);

    // Wait for expand to complete
    await waitFor(() => expect(screen.getByTitle('Collapse details')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() => expect(screen.getByTitle('Expand details')).toBeInTheDocument());
    expect(screen.queryByText('Backend VIP')).not.toBeInTheDocument();
  });

  it('does not call getSubscription twice when already cached', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    mockGetSubscription.mockResolvedValue(SUB_A_DETAIL);

    renderPanel();
    const expandBtn = await screen.findByTitle('Expand details');
    fireEvent.click(expandBtn);
    await waitFor(() => expect(mockGetSubscription).toHaveBeenCalledTimes(1));

    // Collapse then re-expand
    fireEvent.click(screen.getByTitle('Collapse details'));
    fireEvent.click(screen.getByTitle('Expand details'));

    await new Promise((r) => setTimeout(r, 50));
    expect(mockGetSubscription).toHaveBeenCalledTimes(1); // still just once
  });

  it('shows error notification when getSubscription fails on expand', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    mockGetSubscription.mockRejectedValue(new Error('detail load error'));

    renderPanel();
    fireEvent.click(await screen.findByTitle('Expand details'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'detail load error' }),
      ),
    );
  });

  it('shows a generic error when getSubscription rejects without message', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    mockGetSubscription.mockRejectedValue('fail');

    renderPanel();
    fireEvent.click(await screen.findByTitle('Expand details'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Failed to load subscription detail',
        }),
      ),
    );
  });

  it('shows subscribed_at timestamp in expanded detail', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_A]));
    mockGetSubscription.mockResolvedValue(SUB_A_DETAIL);

    renderPanel();
    fireEvent.click(await screen.findByTitle('Expand details'));

    await waitFor(() => {
      const dateStr = new Date(SUB_A.subscribed_at).toLocaleString();
      expect(screen.getByText(dateStr)).toBeInTheDocument();
    });
  });

  it('shows cancelled_at in expanded detail for cancelled subscriptions', async () => {
    mockListSubscriptions.mockResolvedValue(listResponse([SUB_CANCELLED]));
    const cancelledDetail: ServiceSubscription = {
      ...SUB_CANCELLED,
      cancelled_at: '2026-03-01T00:00:00Z',
    };
    mockGetSubscription.mockResolvedValue(cancelledDetail);

    renderPanel();
    fireEvent.click(await screen.findByTitle('Expand details'));

    await waitFor(() => expect(screen.getByText('Cancelled')).toBeInTheDocument());
  });
});
