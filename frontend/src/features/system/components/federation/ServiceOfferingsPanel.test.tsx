import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { ServiceOfferingsPanel } from './ServiceOfferingsPanel';
import type { ServiceOffering } from '../../types/service_delivery.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockDelete = jest.fn();

// The component imports serviceCatalogApi which in turn uses apiClient.
// We mock serviceCatalogApi directly because it is the module the component
// imports — this is cleaner than going through the raw apiClient mock.
const mockListOfferings = jest.fn();
const mockActivateOffering = jest.fn();
const mockDeprecateOffering = jest.fn();
const mockRetireOffering = jest.fn();

jest.mock('../../services/api/serviceCatalogApi', () => ({
  serviceCatalogApi: {
    listOfferings: (...args: unknown[]) => mockListOfferings(...args),
    activateOffering: (...args: unknown[]) => mockActivateOffering(...args),
    deprecateOffering: (...args: unknown[]) => mockDeprecateOffering(...args),
    retireOffering: (...args: unknown[]) => mockRetireOffering(...args),
  },
}));

// Suppress unused mock warnings; apiClient is not called by the component
// directly but must be declared so Jest doesn't complain about unmocked
// modules in the transitive tree.
jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
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

// =============================================================================
// Fixtures
// =============================================================================

function makeDraftOffering(overrides: Partial<ServiceOffering> = {}): ServiceOffering {
  return {
    id: 'offer-draft-1',
    slug: 'my-api',
    name: 'My API',
    protocol: 'https',
    status: 'draft',
    backend_host: 'api.internal',
    backend_port: 8080,
    backend_vip_id: null,
    default_grant_ttl_days: 30,
    default_grant_scopes: ['read'],
    capacity_metadata: {},
    latency_metadata: {},
    accepting_new_subscriptions: true,
    active_subscription_count: 0,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-02T00:00:00Z',
    ...overrides,
  };
}

function makeActiveOffering(overrides: Partial<ServiceOffering> = {}): ServiceOffering {
  return {
    ...makeDraftOffering(),
    id: 'offer-active-1',
    slug: 'live-service',
    name: 'Live Service',
    status: 'active',
    active_subscription_count: 3,
    capacity_metadata: { max_subscribers: 10 },
    ...overrides,
  };
}

function makeDeprecatedOffering(overrides: Partial<ServiceOffering> = {}): ServiceOffering {
  return {
    ...makeDraftOffering(),
    id: 'offer-deprecated-1',
    slug: 'old-service',
    name: 'Old Service',
    status: 'deprecated',
    ...overrides,
  };
}

function makeRetiredOffering(overrides: Partial<ServiceOffering> = {}): ServiceOffering {
  return {
    ...makeDraftOffering(),
    id: 'offer-retired-1',
    slug: 'retired-service',
    name: 'Retired Service',
    status: 'retired',
    ...overrides,
  };
}

// serviceCatalogApi.listOfferings already returns the unwrapped payload —
// this helper builds the shape it returns (not the raw axios response).
function listResult(offerings: ServiceOffering[]) {
  return { offerings, count: offerings.length };
}

// =============================================================================
// Render helper
// =============================================================================

interface RenderOptions {
  initialStatusFilter?: 'draft' | 'active' | 'deprecated' | 'retired' | null;
  refreshKey?: number;
  onCreateClick?: jest.Mock;
  onSelect?: jest.Mock;
}

function renderPanel(opts: RenderOptions = {}) {
  const {
    initialStatusFilter = null,
    refreshKey = 0,
    onCreateClick,
    onSelect,
  } = opts;

  return render(
    <ServiceOfferingsPanel
      initialStatusFilter={initialStatusFilter}
      refreshKey={refreshKey}
      onCreateClick={onCreateClick}
      onSelect={onSelect}
    />,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('ServiceOfferingsPanel', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  // ─── Loading + initial fetch ──────────────────────────────────────────────

  it('shows loading text while the initial fetch is in-flight', async () => {
    // Never resolves — keeps the component in loading state.
    mockListOfferings.mockReturnValue(new Promise(() => {}));

    renderPanel();

    expect(screen.getByText('loading…')).toBeInTheDocument();
  });

  it('fetches offerings without a filter on mount', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));

    renderPanel();

    await waitFor(() => expect(mockListOfferings).toHaveBeenCalledWith(undefined));
  });

  it('fetches offerings with the initialStatusFilter when provided', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));

    renderPanel({ initialStatusFilter: 'active' });

    await waitFor(() =>
      expect(mockListOfferings).toHaveBeenCalledWith({ status: 'active' }),
    );
  });

  // ─── Empty state ──────────────────────────────────────────────────────────

  it('renders the empty-state message when no offerings are returned', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));

    renderPanel();

    await waitFor(() =>
      expect(
        screen.getByText(/No offerings yet/i),
      ).toBeInTheDocument(),
    );
  });

  it('shows "0 offerings" count after an empty fetch', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('0 offerings')).toBeInTheDocument());
  });

  // ─── Error state ──────────────────────────────────────────────────────────

  it('fires an error notification when listOfferings rejects', async () => {
    mockListOfferings.mockRejectedValue(new Error('Network failure'));

    renderPanel();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network failure',
      }),
    );
  });

  it('fires a generic error notification when the rejection has no message', async () => {
    mockListOfferings.mockRejectedValue({ status: 503 });

    renderPanel();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load offerings',
      }),
    );
  });

  // ─── Offerings list rendering ─────────────────────────────────────────────

  it('renders a row for each returned offering', async () => {
    const draft = makeDraftOffering();
    const active = makeActiveOffering();
    mockListOfferings.mockResolvedValue(listResult([draft, active]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('My API')).toBeInTheDocument());
    expect(screen.getByText('Live Service')).toBeInTheDocument();
  });

  it('shows the slug below the offering name', async () => {
    mockListOfferings.mockResolvedValue(listResult([makeDraftOffering()]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('my-api')).toBeInTheDocument());
  });

  it('shows correct subscriber count without a cap when max_subscribers is absent', async () => {
    mockListOfferings.mockResolvedValue(
      listResult([makeDraftOffering({ active_subscription_count: 7, capacity_metadata: {} })]),
    );

    renderPanel();

    await waitFor(() => expect(screen.getByText('7')).toBeInTheDocument());
    // There should be no "/ N" text when max_subscribers is missing
    expect(screen.queryByText(/\/ \d/)).not.toBeInTheDocument();
  });

  it('shows subscriber cap when max_subscribers is set', async () => {
    mockListOfferings.mockResolvedValue(
      listResult([
        makeActiveOffering({
          active_subscription_count: 3,
          capacity_metadata: { max_subscribers: 10 },
        }),
      ]),
    );

    renderPanel();

    await waitFor(() => expect(screen.getByText('/ 10')).toBeInTheDocument());
  });

  it('displays "1 offering" singular when exactly one offering is present', async () => {
    mockListOfferings.mockResolvedValue(listResult([makeDraftOffering()]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('1 offering')).toBeInTheDocument());
  });

  it('displays protocol in the table', async () => {
    mockListOfferings.mockResolvedValue(listResult([makeDraftOffering({ protocol: 'tcp' })]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('tcp')).toBeInTheDocument());
  });

  // ─── Status pills ─────────────────────────────────────────────────────────

  it('renders the correct status pills for each offering', async () => {
    const offerings = [
      makeDraftOffering(),
      makeActiveOffering(),
      makeDeprecatedOffering(),
      makeRetiredOffering(),
    ];
    mockListOfferings.mockResolvedValue(listResult(offerings));

    renderPanel();

    await waitFor(() => expect(screen.getByText('draft')).toBeInTheDocument());
    expect(screen.getByText('active')).toBeInTheDocument();
    expect(screen.getByText('deprecated')).toBeInTheDocument();
    expect(screen.getByText('retired')).toBeInTheDocument();
  });

  // ─── Backend label formatting ─────────────────────────────────────────────

  it('formats the backend label as host:port when backend_host is set', async () => {
    mockListOfferings.mockResolvedValue(
      listResult([makeDraftOffering({ backend_host: 'api.internal', backend_port: 8080 })]),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('api.internal:8080')).toBeInTheDocument(),
    );
  });

  it('formats the backend label as vip:<id truncated>:port when backend_vip_id is set', async () => {
    mockListOfferings.mockResolvedValue(
      listResult([
        makeDraftOffering({
          backend_host: null,
          backend_vip_id: 'abcdef12-rest-of-the-id',
          backend_port: 443,
        }),
      ]),
    );

    renderPanel();

    // The component truncates the VIP id to 8 chars then appends an ellipsis
    await waitFor(() =>
      expect(screen.getByText('vip:abcdef12…:443')).toBeInTheDocument(),
    );
  });

  it('formats the backend label as <unset>:port when neither host nor vip_id is set', async () => {
    mockListOfferings.mockResolvedValue(
      listResult([
        makeDraftOffering({ backend_host: null, backend_vip_id: null, backend_port: 9000 }),
      ]),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('<unset>:9000')).toBeInTheDocument(),
    );
  });

  // ─── "New Offering" button ────────────────────────────────────────────────

  it('does NOT render the "New Offering" button when onCreateClick is absent', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));

    renderPanel();

    await waitFor(() => expect(screen.queryByText('New Offering')).not.toBeInTheDocument());
  });

  it('renders the "New Offering" button when onCreateClick is provided', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));
    const onCreateClick = jest.fn();

    renderPanel({ onCreateClick });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /new offering/i })).toBeInTheDocument(),
    );
  });

  it('calls onCreateClick when the button is clicked', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));
    const onCreateClick = jest.fn();

    renderPanel({ onCreateClick });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /new offering/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /new offering/i }));

    expect(onCreateClick).toHaveBeenCalledTimes(1);
  });

  // ─── Row click (onSelect) ─────────────────────────────────────────────────

  it('calls onSelect with the offering when a row is clicked', async () => {
    const offering = makeDraftOffering();
    mockListOfferings.mockResolvedValue(listResult([offering]));
    const onSelect = jest.fn();

    renderPanel({ onSelect });

    await waitFor(() => expect(screen.getByText('My API')).toBeInTheDocument());
    // Click the name cell; the whole row is clickable
    fireEvent.click(screen.getByText('My API'));

    expect(onSelect).toHaveBeenCalledWith(offering);
  });

  it('does NOT call onSelect when the action cell is clicked (stopPropagation)', async () => {
    const offering = makeDraftOffering();
    mockListOfferings.mockResolvedValue(listResult([offering]));
    const onSelect = jest.fn();
    mockActivateOffering.mockResolvedValue({ ...offering, status: 'active' });
    mockListOfferings.mockResolvedValueOnce(listResult([offering]));
    mockListOfferings.mockResolvedValue(listResult([{ ...offering, status: 'active' }]));

    renderPanel({ onSelect });

    await waitFor(() => expect(screen.getByTitle('Activate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Activate'));

    // Wait for the re-fetch to settle
    await waitFor(() => expect(mockActivateOffering).toHaveBeenCalled());
    expect(onSelect).not.toHaveBeenCalled();
  });

  // ─── Expand / collapse rows ───────────────────────────────────────────────

  it('expands a row to show detailed metadata when the chevron is clicked', async () => {
    const offering = makeDraftOffering({
      default_grant_ttl_days: 14,
      default_grant_scopes: ['read', 'write'],
      accepting_new_subscriptions: true,
    });
    mockListOfferings.mockResolvedValue(listResult([offering]));

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Expand details')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    // Check expanded details
    expect(screen.getByText('14 days')).toBeInTheDocument();
    expect(screen.getByText('read, write')).toBeInTheDocument();
    expect(screen.getByText('Yes')).toBeInTheDocument();
    expect(screen.getByText(offering.id)).toBeInTheDocument();
  });

  it('shows "Collapse details" title after a row is expanded', async () => {
    mockListOfferings.mockResolvedValue(listResult([makeDraftOffering()]));

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Expand details')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    expect(screen.getByTitle('Collapse details')).toBeInTheDocument();
  });

  it('collapses the row when the chevron is clicked again', async () => {
    mockListOfferings.mockResolvedValue(listResult([makeDraftOffering()]));

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Expand details')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));
    fireEvent.click(screen.getByTitle('Collapse details'));

    expect(screen.getByTitle('Expand details')).toBeInTheDocument();
  });

  it('shows the latency region field when present', async () => {
    mockListOfferings.mockResolvedValue(
      listResult([
        makeDraftOffering({
          latency_metadata: { region: 'us-east-1', p50_ms: 12, p95_ms: 45 },
        }),
      ]),
    );

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Expand details')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    expect(screen.getByText('us-east-1')).toBeInTheDocument();
    // Latency summary line
    expect(screen.getByText(/p50 12ms/)).toBeInTheDocument();
    expect(screen.getByText(/p95 45ms/)).toBeInTheDocument();
  });

  it('hides the latency region field when not present in metadata', async () => {
    mockListOfferings.mockResolvedValue(listResult([makeDraftOffering()]));

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Expand details')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    // Labels are "Latency Region" and "Latency" — neither should appear
    expect(screen.queryByText('Latency Region')).not.toBeInTheDocument();
  });

  it('shows the description when description_markdown is set', async () => {
    mockListOfferings.mockResolvedValue(
      listResult([makeDraftOffering({ description_markdown: 'Serves widget data.' })]),
    );

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Expand details')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    expect(screen.getByText('Serves widget data.')).toBeInTheDocument();
  });

  it('shows backend vip detail in expanded view when backend_vip_id is set', async () => {
    const vipId = 'vip-uuid-1234-abcdef';
    mockListOfferings.mockResolvedValue(
      listResult([
        makeDraftOffering({
          backend_vip_id: vipId,
          backend_host: null,
          backend_port: 443,
        }),
      ]),
    );

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Expand details')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    // Expanded view shows full vip:id:port (not truncated like the table column)
    expect(screen.getByText(`vip:${vipId}:443`)).toBeInTheDocument();
  });

  it('shows default grant scopes as em-dash when none are set', async () => {
    mockListOfferings.mockResolvedValue(
      listResult([makeDraftOffering({ default_grant_scopes: [] })]),
    );

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Expand details')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    expect(screen.getByText('—')).toBeInTheDocument();
  });

  // ─── State-transition action buttons ──────────────────────────────────────

  describe('action buttons per status', () => {
    it('shows Activate for draft, no Deprecate or Reactivate', async () => {
      mockListOfferings.mockResolvedValue(listResult([makeDraftOffering()]));

      renderPanel();

      await waitFor(() => expect(screen.getByTitle('Activate')).toBeInTheDocument());
      expect(screen.queryByTitle('Deprecate')).not.toBeInTheDocument();
      expect(screen.queryByTitle('Reactivate')).not.toBeInTheDocument();
    });

    it('shows Deprecate for active, no Activate', async () => {
      mockListOfferings.mockResolvedValue(listResult([makeActiveOffering()]));

      renderPanel();

      await waitFor(() => expect(screen.getByTitle('Deprecate')).toBeInTheDocument());
      expect(screen.queryByTitle('Activate')).not.toBeInTheDocument();
    });

    it('shows Reactivate for deprecated, no Deprecate or plain Activate', async () => {
      mockListOfferings.mockResolvedValue(listResult([makeDeprecatedOffering()]));

      renderPanel();

      await waitFor(() => expect(screen.getByTitle('Reactivate')).toBeInTheDocument());
      expect(screen.queryByTitle('Deprecate')).not.toBeInTheDocument();
    });

    it('shows Retire for draft (not retired)', async () => {
      mockListOfferings.mockResolvedValue(listResult([makeDraftOffering()]));

      renderPanel();

      await waitFor(() => expect(screen.getByTitle('Retire')).toBeInTheDocument());
    });

    it('shows Retire for active (not retired)', async () => {
      mockListOfferings.mockResolvedValue(listResult([makeActiveOffering()]));

      renderPanel();

      await waitFor(() => expect(screen.getByTitle('Retire')).toBeInTheDocument());
    });

    it('does NOT show Retire for a retired offering', async () => {
      mockListOfferings.mockResolvedValue(listResult([makeRetiredOffering()]));

      renderPanel();

      await waitFor(() => expect(screen.getByText('retired')).toBeInTheDocument());
      expect(screen.queryByTitle('Retire')).not.toBeInTheDocument();
    });

    it('shows no action buttons at all for a retired offering', async () => {
      mockListOfferings.mockResolvedValue(listResult([makeRetiredOffering()]));

      renderPanel();

      await waitFor(() => expect(screen.getByText('retired')).toBeInTheDocument());
      expect(screen.queryByTitle('Activate')).not.toBeInTheDocument();
      expect(screen.queryByTitle('Deprecate')).not.toBeInTheDocument();
      expect(screen.queryByTitle('Reactivate')).not.toBeInTheDocument();
      expect(screen.queryByTitle('Retire')).not.toBeInTheDocument();
    });
  });

  // ─── Activate transition ──────────────────────────────────────────────────

  it('calls activateOffering with the offering id and refreshes', async () => {
    const draft = makeDraftOffering();
    const activated = { ...draft, status: 'active' as const };
    mockListOfferings
      .mockResolvedValueOnce(listResult([draft]))
      .mockResolvedValueOnce(listResult([activated]));
    mockActivateOffering.mockResolvedValue(activated);

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Activate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Activate'));

    await waitFor(() =>
      expect(mockActivateOffering).toHaveBeenCalledWith(draft.id),
    );
    // After success the list should refresh
    await waitFor(() => expect(mockListOfferings).toHaveBeenCalledTimes(2));
  });

  it('shows a success notification after activate', async () => {
    const draft = makeDraftOffering();
    mockListOfferings
      .mockResolvedValueOnce(listResult([draft]))
      .mockResolvedValueOnce(listResult([{ ...draft, status: 'active' }]));
    mockActivateOffering.mockResolvedValue({ ...draft, status: 'active' });

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Activate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Activate'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Offering "${draft.name}" activated`,
      }),
    );
  });

  it('shows an error notification when activate fails', async () => {
    const draft = makeDraftOffering();
    mockListOfferings.mockResolvedValue(listResult([draft]));
    mockActivateOffering.mockRejectedValue(new Error('Service unavailable'));

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Activate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Activate'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Service unavailable',
      }),
    );
  });

  // ─── Deprecate transition ─────────────────────────────────────────────────

  it('calls deprecateOffering with the offering id and refreshes', async () => {
    const active = makeActiveOffering();
    const deprecated = { ...active, status: 'deprecated' as const };
    mockListOfferings
      .mockResolvedValueOnce(listResult([active]))
      .mockResolvedValueOnce(listResult([deprecated]));
    mockDeprecateOffering.mockResolvedValue(deprecated);

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Deprecate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Deprecate'));

    await waitFor(() =>
      expect(mockDeprecateOffering).toHaveBeenCalledWith(active.id),
    );
    await waitFor(() => expect(mockListOfferings).toHaveBeenCalledTimes(2));
  });

  it('shows a success notification after deprecate', async () => {
    const active = makeActiveOffering();
    mockListOfferings
      .mockResolvedValueOnce(listResult([active]))
      .mockResolvedValueOnce(listResult([{ ...active, status: 'deprecated' }]));
    mockDeprecateOffering.mockResolvedValue({ ...active, status: 'deprecated' });

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Deprecate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Deprecate'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Offering "${active.name}" deprecated`,
      }),
    );
  });

  it('shows an error notification when deprecate fails', async () => {
    const active = makeActiveOffering();
    mockListOfferings.mockResolvedValue(listResult([active]));
    mockDeprecateOffering.mockRejectedValue(new Error('Not allowed'));

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Deprecate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Deprecate'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Not allowed',
      }),
    );
  });

  // ─── Retire transition ────────────────────────────────────────────────────

  it('calls retireOffering with the offering id and refreshes', async () => {
    const draft = makeDraftOffering();
    const retired = { ...draft, status: 'retired' as const };
    mockListOfferings
      .mockResolvedValueOnce(listResult([draft]))
      .mockResolvedValueOnce(listResult([retired]));
    mockRetireOffering.mockResolvedValue(retired);

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Retire')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Retire'));

    await waitFor(() =>
      expect(mockRetireOffering).toHaveBeenCalledWith(draft.id),
    );
    await waitFor(() => expect(mockListOfferings).toHaveBeenCalledTimes(2));
  });

  it('shows a success notification after retire', async () => {
    const draft = makeDraftOffering();
    mockListOfferings
      .mockResolvedValueOnce(listResult([draft]))
      .mockResolvedValueOnce(listResult([{ ...draft, status: 'retired' }]));
    mockRetireOffering.mockResolvedValue({ ...draft, status: 'retired' });

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Retire')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Retire'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Offering "${draft.name}" retired`,
      }),
    );
  });

  it('shows a generic error notification when retire fails without an Error instance', async () => {
    const draft = makeDraftOffering();
    mockListOfferings.mockResolvedValue(listResult([draft]));
    mockRetireOffering.mockRejectedValue({ code: 'forbidden' });

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Retire')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Retire'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to retire offering',
      }),
    );
  });

  // ─── Status filter bar ────────────────────────────────────────────────────

  it('renders all filter buttons: All / Draft / Active / Deprecated / Retired', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));

    renderPanel();

    await waitFor(() => screen.getByText('0 offerings'));

    expect(screen.getByRole('button', { name: 'All' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Draft' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Active' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Deprecated' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Retired' })).toBeInTheDocument();
  });

  it('re-fetches with a status filter when a filter button is clicked', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));

    renderPanel();

    await waitFor(() => screen.getByText('0 offerings'));
    fireEvent.click(screen.getByRole('button', { name: 'Active' }));

    await waitFor(() =>
      expect(mockListOfferings).toHaveBeenCalledWith({ status: 'active' }),
    );
  });

  it('re-fetches without a filter when "All" is clicked after a filter was active', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));

    renderPanel({ initialStatusFilter: 'active' });

    await waitFor(() => screen.getByText('0 offerings'));
    fireEvent.click(screen.getByRole('button', { name: 'All' }));

    await waitFor(() =>
      expect(mockListOfferings).toHaveBeenCalledWith(undefined),
    );
  });

  it('re-fetches when refreshKey changes', async () => {
    mockListOfferings.mockResolvedValue(listResult([]));

    const { rerender } = renderPanel({ refreshKey: 0 });

    await waitFor(() => expect(mockListOfferings).toHaveBeenCalledTimes(1));

    rerender(<ServiceOfferingsPanel refreshKey={1} />);

    await waitFor(() => expect(mockListOfferings).toHaveBeenCalledTimes(2));
  });

  // ─── Disabled state during action ─────────────────────────────────────────

  it('disables all action buttons while a transition is in-flight', async () => {
    const draft = makeDraftOffering();
    mockListOfferings.mockResolvedValue(listResult([draft]));
    // Make activate hang indefinitely so we can inspect the disabled state
    mockActivateOffering.mockReturnValue(new Promise(() => {}));

    renderPanel();

    await waitFor(() => expect(screen.getByTitle('Activate')).toBeInTheDocument());
    const activateBtn = screen.getByTitle('Activate');
    const retireBtn = screen.getByTitle('Retire');

    fireEvent.click(activateBtn);

    // Both buttons should be disabled while the request is in-flight
    await waitFor(() => expect(activateBtn).toBeDisabled());
    expect(retireBtn).toBeDisabled();
  });

  // ─── Multiple offerings — expand independence ─────────────────────────────

  it('expands each row independently without affecting others', async () => {
    const draft = makeDraftOffering();
    const active = makeActiveOffering();
    mockListOfferings.mockResolvedValue(listResult([draft, active]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getAllByTitle('Expand details')).toHaveLength(2),
    );

    const [expandDraft] = screen.getAllByTitle('Expand details');
    fireEvent.click(expandDraft);

    // One collapsed, one expanded
    expect(screen.getAllByTitle('Expand details')).toHaveLength(1);
    expect(screen.getAllByTitle('Collapse details')).toHaveLength(1);
  });
});
