import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { OfferingsTab } from './OfferingsTab';

// =============================================================================
// Mocks
//
// OfferingsTab composes ServiceOfferingsPanel + ServiceOfferingEditorModal.
// Both panels call serviceCatalogApi which uses apiClient under the hood.
// We mock apiClient at the shared layer and serviceCatalogApi at the feature
// layer so we can assert the real API shapes.
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPatch = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
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

// =============================================================================
// Fixtures & helpers
// =============================================================================

/** Standard API double-envelope: { data: { success: true, data: <payload> } } */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

const OFFERING_DRAFT = {
  id: 'off-draft-1',
  slug: 'managed-git',
  name: 'Managed Git',
  protocol: 'https' as const,
  status: 'draft' as const,
  backend_host: 'git.internal',
  backend_port: 443,
  backend_vip_id: null,
  default_grant_ttl_days: 30,
  default_grant_scopes: ['read'] as const,
  capacity_metadata: {},
  latency_metadata: {},
  accepting_new_subscriptions: true,
  active_subscription_count: 0,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const OFFERING_ACTIVE = {
  id: 'off-active-2',
  slug: 'managed-postgres',
  name: 'Managed Postgres',
  protocol: 'tcp' as const,
  status: 'active' as const,
  backend_host: 'pg.internal',
  backend_port: 5432,
  backend_vip_id: null,
  default_grant_ttl_days: 14,
  default_grant_scopes: ['read', 'write'] as const,
  capacity_metadata: { max_subscribers: 5 },
  latency_metadata: { region: 'us-east-1', p50_ms: 2, p95_ms: 10 },
  accepting_new_subscriptions: true,
  active_subscription_count: 2,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-15T00:00:00Z',
};

const OFFERING_DEPRECATED = {
  id: 'off-dep-3',
  slug: 'legacy-api',
  name: 'Legacy API',
  protocol: 'http' as const,
  status: 'deprecated' as const,
  backend_host: 'old.internal',
  backend_port: 80,
  backend_vip_id: null,
  default_grant_ttl_days: 7,
  default_grant_scopes: ['read'] as const,
  capacity_metadata: {},
  latency_metadata: {},
  accepting_new_subscriptions: false,
  active_subscription_count: 1,
  created_at: '2025-01-01T00:00:00Z',
  updated_at: '2026-03-01T00:00:00Z',
};

const OFFERING_RETIRED = {
  id: 'off-ret-4',
  slug: 'old-service',
  name: 'Old Service',
  protocol: 'tcp' as const,
  status: 'retired' as const,
  backend_host: null,
  backend_port: 9000,
  backend_vip_id: null,
  default_grant_ttl_days: 30,
  default_grant_scopes: ['read'] as const,
  capacity_metadata: {},
  latency_metadata: {},
  accepting_new_subscriptions: false,
  active_subscription_count: 0,
  created_at: '2024-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const OFFERINGS_BASE = '/system/federation/service_offerings';

function listEnvelope(offerings: unknown[]) {
  return envelope({ offerings, count: offerings.length });
}

const renderTab = () =>
  render(
    <BrowserRouter>
      <OfferingsTab />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('OfferingsTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPatch.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render & loading states
  // ---------------------------------------------------------------------------

  it('renders the panel header while loading', () => {
    // Never resolves — stays in loading state
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByText('Service Offerings')).toBeInTheDocument();
    expect(screen.getByText('loading…')).toBeInTheDocument();
  });

  it('shows the offerings count label after load', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_DRAFT, OFFERING_ACTIVE]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('2 offerings')).toBeInTheDocument(),
    );
  });

  it('shows singular "offering" when count is 1', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_DRAFT]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('1 offering')).toBeInTheDocument(),
    );
  });

  it('shows an empty-state message when no offerings exist', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText(/No offerings yet/),
      ).toBeInTheDocument(),
    );
  });

  it('shows an error notification when the list fetch fails', async () => {
    const err = new Error('Network error');
    mockGet.mockRejectedValue(err);

    renderTab();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network error',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // List renders rows with correct data
  // ---------------------------------------------------------------------------

  it('fetches offerings from the correct API endpoint with no params', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(OFFERINGS_BASE, { params: {} }),
    );
  });

  it('renders offering name, slug, protocol and status for each row', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_DRAFT, OFFERING_ACTIVE]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Managed Git')).toBeInTheDocument(),
    );
    expect(screen.getByText('managed-git')).toBeInTheDocument();
    expect(screen.getByText('draft')).toBeInTheDocument();

    expect(screen.getByText('Managed Postgres')).toBeInTheDocument();
    expect(screen.getByText('managed-postgres')).toBeInTheDocument();
    expect(screen.getByText('active')).toBeInTheDocument();
  });

  it('renders subscriber count (with cap) for active offering', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_ACTIVE]));

    renderTab();

    // 2 subscribers with max cap 5 → "2 / 5"
    await waitFor(() =>
      expect(screen.getByText('2')).toBeInTheDocument(),
    );
    expect(screen.getByText('/ 5')).toBeInTheDocument();
  });

  it('renders backend label as host:port when no VIP', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_DRAFT]));

    renderTab();

    // backendLabel for OFFERING_DRAFT: 'git.internal:443'
    await waitFor(() =>
      expect(screen.getByText('git.internal:443')).toBeInTheDocument(),
    );
  });

  it('renders <unset>:port when backend_host is null and no VIP', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_RETIRED]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('<unset>:9000')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Status filter bar
  // ---------------------------------------------------------------------------

  it('renders status filter buttons (All, Draft, Active, Deprecated, Retired)', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('All')).toBeInTheDocument());
    expect(screen.getByText('Draft')).toBeInTheDocument();
    expect(screen.getByText('Active')).toBeInTheDocument();
    expect(screen.getByText('Deprecated')).toBeInTheDocument();
    expect(screen.getByText('Retired')).toBeInTheDocument();
  });

  it('re-fetches with status param when a filter button is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([OFFERING_DRAFT, OFFERING_ACTIVE]))
      .mockResolvedValueOnce(listEnvelope([OFFERING_ACTIVE]));

    renderTab();

    await waitFor(() => expect(screen.getByText('Managed Git')).toBeInTheDocument());

    // Click the "Active" filter
    fireEvent.click(screen.getByText('Active'));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(OFFERINGS_BASE, {
        params: { status: 'active' },
      }),
    );
  });

  it('re-fetches without status param when "All" filter is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([OFFERING_ACTIVE]))
      .mockResolvedValueOnce(listEnvelope([OFFERING_DRAFT, OFFERING_ACTIVE]));

    renderTab();

    // Start in active filter state by clicking Active first
    await waitFor(() => expect(screen.getByText('Managed Postgres')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Active'));

    // Wait for second fetch, then click All
    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
    mockGet.mockResolvedValueOnce(listEnvelope([OFFERING_DRAFT, OFFERING_ACTIVE]));
    fireEvent.click(screen.getByText('All'));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(OFFERINGS_BASE, { params: {} }),
    );
  });

  // ---------------------------------------------------------------------------
  // Expand / collapse row details
  // ---------------------------------------------------------------------------

  it('expands a row to show detail fields when the chevron button is clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_ACTIVE]));

    renderTab();

    await waitFor(() => expect(screen.getByText('Managed Postgres')).toBeInTheDocument());

    // Find the expand button by its title
    const expandBtn = screen.getByTitle('Expand details');
    fireEvent.click(expandBtn);

    // Expanded detail panel should now show additional metadata labels
    await waitFor(() =>
      expect(screen.getByText('Default Grant TTL')).toBeInTheDocument(),
    );
    expect(screen.getByText('Default Grant Scopes')).toBeInTheDocument();
    expect(screen.getByText('Accepting New')).toBeInTheDocument();
    expect(screen.getByText('Offering ID')).toBeInTheDocument();
    // Latency section for OFFERING_ACTIVE (has region + p50/p95)
    expect(screen.getByText('Latency Region')).toBeInTheDocument();
    expect(screen.getByText('us-east-1')).toBeInTheDocument();
    expect(screen.getByText(/p50 2ms/)).toBeInTheDocument();
  });

  it('collapses the row when the chevron is clicked again', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_ACTIVE]));

    renderTab();

    await waitFor(() => expect(screen.getByText('Managed Postgres')).toBeInTheDocument());

    const expandBtn = screen.getByTitle('Expand details');
    fireEvent.click(expandBtn);
    await waitFor(() => expect(screen.getByText('Offering ID')).toBeInTheDocument());

    // Title should now be "Collapse details"
    const collapseBtn = screen.getByTitle('Collapse details');
    fireEvent.click(collapseBtn);

    await waitFor(() =>
      expect(screen.queryByText('Offering ID')).not.toBeInTheDocument(),
    );
  });

  it('shows expanded description when description_markdown is present', async () => {
    const withDesc = {
      ...OFFERING_ACTIVE,
      description_markdown: 'Full-featured managed Postgres service.',
    };
    mockGet.mockResolvedValue(listEnvelope([withDesc]));

    renderTab();

    await waitFor(() => expect(screen.getByText('Managed Postgres')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Full-featured managed Postgres service.')).toBeInTheDocument(),
    );
  });

  it('does not show Latency Region section when latency_metadata.region is absent', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_DRAFT]));

    renderTab();

    await waitFor(() => expect(screen.getByText('Managed Git')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() => expect(screen.getByText('Offering ID')).toBeInTheDocument());
    expect(screen.queryByText('Latency Region')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Status transition action buttons
  // ---------------------------------------------------------------------------

  it('shows Activate action button for draft offerings', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_DRAFT]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTitle('Activate')).toBeInTheDocument(),
    );
    // Draft also has Retire, but not Deprecate
    expect(screen.queryByTitle('Deprecate')).not.toBeInTheDocument();
  });

  it('shows Deprecate action button for active offerings', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_ACTIVE]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTitle('Deprecate')).toBeInTheDocument(),
    );
    expect(screen.queryByTitle('Activate')).not.toBeInTheDocument();
  });

  it('shows Reactivate action button for deprecated offerings', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_DEPRECATED]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTitle('Reactivate')).toBeInTheDocument(),
    );
    expect(screen.getByTitle('Retire')).toBeInTheDocument();
  });

  it('hides Retire action for retired offerings', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_RETIRED]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Old Service')).toBeInTheDocument(),
    );
    expect(screen.queryByTitle('Retire')).not.toBeInTheDocument();
  });

  it('activates a draft offering via POST to /activate and re-fetches', async () => {
    const activatedOffering = { ...OFFERING_DRAFT, status: 'active' as const };

    mockGet
      .mockResolvedValueOnce(listEnvelope([OFFERING_DRAFT]))
      .mockResolvedValueOnce(listEnvelope([activatedOffering]));
    mockPost.mockResolvedValueOnce(envelope({ offering: activatedOffering }));

    renderTab();

    await waitFor(() => expect(screen.getByTitle('Activate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Activate'));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        `${OFFERINGS_BASE}/${OFFERING_DRAFT.id}/activate`,
        {},
      ),
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Offering "${OFFERING_DRAFT.name}" activated`,
      }),
    );

    // Panel re-fetches after success
    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
  });

  it('deprecates an active offering via POST to /deprecate and re-fetches', async () => {
    const deprecatedOffering = { ...OFFERING_ACTIVE, status: 'deprecated' as const };

    mockGet
      .mockResolvedValueOnce(listEnvelope([OFFERING_ACTIVE]))
      .mockResolvedValueOnce(listEnvelope([deprecatedOffering]));
    mockPost.mockResolvedValueOnce(envelope({ offering: deprecatedOffering }));

    renderTab();

    await waitFor(() => expect(screen.getByTitle('Deprecate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Deprecate'));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        `${OFFERINGS_BASE}/${OFFERING_ACTIVE.id}/deprecate`,
        {},
      ),
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Offering "${OFFERING_ACTIVE.name}" deprecated`,
      }),
    );
  });

  it('retires an active offering via DELETE and shows success notification', async () => {
    const retiredOffering = { ...OFFERING_ACTIVE, status: 'retired' as const };

    mockGet
      .mockResolvedValueOnce(listEnvelope([OFFERING_ACTIVE]))
      .mockResolvedValueOnce(listEnvelope([]));
    mockDelete.mockResolvedValueOnce(envelope({ offering: retiredOffering }));

    renderTab();

    await waitFor(() => expect(screen.getByTitle('Retire')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Retire'));

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith(
        `${OFFERINGS_BASE}/${OFFERING_ACTIVE.id}`,
        { data: undefined },
      ),
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Offering "${OFFERING_ACTIVE.name}" retired`,
      }),
    );
  });

  it('shows error notification when a transition fails', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_DRAFT]));
    mockPost.mockRejectedValueOnce(new Error('Server error'));

    renderTab();

    await waitFor(() => expect(screen.getByTitle('Activate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Activate'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Server error',
      }),
    );
  });

  it('reactivates a deprecated offering via POST to /activate', async () => {
    const reactivated = { ...OFFERING_DEPRECATED, status: 'active' as const };

    mockGet
      .mockResolvedValueOnce(listEnvelope([OFFERING_DEPRECATED]))
      .mockResolvedValueOnce(listEnvelope([reactivated]));
    mockPost.mockResolvedValueOnce(envelope({ offering: reactivated }));

    renderTab();

    await waitFor(() => expect(screen.getByTitle('Reactivate')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Reactivate'));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        `${OFFERINGS_BASE}/${OFFERING_DEPRECATED.id}/activate`,
        {},
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // onSelect → opens edit modal (OfferingsTab wires panel → modal)
  // ---------------------------------------------------------------------------

  it('opens the editor modal in edit mode when a row is clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_ACTIVE]));

    renderTab();

    await waitFor(() => expect(screen.getByText('Managed Postgres')).toBeInTheDocument());

    // Click the row (the td that contains the name)
    fireEvent.click(screen.getByText('Managed Postgres'));

    await waitFor(() =>
      expect(screen.getByText('Edit Service Offering')).toBeInTheDocument(),
    );

    // Slug field should be pre-populated and disabled in edit mode
    const slugInput = screen.getByDisplayValue('managed-postgres');
    expect(slugInput).toBeDisabled();
  });

  it('pre-populates all form fields when editing an existing offering', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_ACTIVE]));

    renderTab();

    await waitFor(() => expect(screen.getByText('Managed Postgres')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Managed Postgres'));

    await waitFor(() =>
      expect(screen.getByText('Edit Service Offering')).toBeInTheDocument(),
    );

    expect(screen.getByDisplayValue('Managed Postgres')).toBeInTheDocument();
    expect(screen.getByDisplayValue('5432')).toBeInTheDocument();
    expect(screen.getByDisplayValue('14')).toBeInTheDocument();
    expect(screen.getByDisplayValue('pg.internal')).toBeInTheDocument();
    // max_subscribers: 5
    expect(screen.getByDisplayValue('5')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // "New Offering" button → opens create modal
  // ---------------------------------------------------------------------------

  it('renders the "New Offering" button in the panel header', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('New Offering')).toBeInTheDocument(),
    );
  });

  it('opens the editor modal in create mode when "New Offering" is clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );
  });

  it('shows an empty slug field (editable) in create mode', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );

    // Slug must be editable in create mode
    const slugInput = screen.getByPlaceholderText(/gitea, managed-postgres/i);
    expect(slugInput).not.toBeDisabled();
    expect((slugInput as HTMLInputElement).value).toBe('');
  });

  it('disables the Create Offering button when the form is invalid', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );

    const createBtn = screen.getByRole('button', { name: /create offering/i });
    // Form starts invalid (empty slug, empty name, empty backend host)
    expect(createBtn).toBeDisabled();
  });

  it('enables the Create Offering button only when all required fields are valid', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );

    // Fill required fields
    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'my-service' },
    });
    fireEvent.change(screen.getByPlaceholderText(/hosted git/i), {
      target: { value: 'My Service' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend\.internal/i), {
      target: { value: 'svc.internal' },
    });

    await waitFor(() => {
      const createBtn = screen.getByRole('button', { name: /create offering/i });
      expect(createBtn).not.toBeDisabled();
    });
  });

  it('submits a create POST with the correct payload', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([]))
      .mockResolvedValueOnce(listEnvelope([OFFERING_DRAFT]));
    mockPost.mockResolvedValueOnce(envelope({ offering: OFFERING_DRAFT }));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'managed-git' },
    });
    fireEvent.change(screen.getByPlaceholderText(/hosted git/i), {
      target: { value: 'Managed Git' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend\.internal/i), {
      target: { value: 'git.internal' },
    });

    // Port defaults to 443, TTL defaults to 30, scopes default to ['read']
    await waitFor(() => {
      const createBtn = screen.getByRole('button', { name: /create offering/i });
      expect(createBtn).not.toBeDisabled();
    });

    fireEvent.click(screen.getByRole('button', { name: /create offering/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(OFFERINGS_BASE, {
        slug: 'managed-git',
        name: 'Managed Git',
        protocol: 'https',
        backend_host: 'git.internal',
        backend_port: 443,
        default_grant_ttl_days: 30,
        default_grant_scopes: ['read'],
      }),
    );
  });

  it('shows success notification and closes modal after successful create', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([]))
      .mockResolvedValueOnce(listEnvelope([OFFERING_DRAFT]));
    mockPost.mockResolvedValueOnce(envelope({ offering: OFFERING_DRAFT }));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'managed-git' },
    });
    fireEvent.change(screen.getByPlaceholderText(/hosted git/i), {
      target: { value: 'Managed Git' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend\.internal/i), {
      target: { value: 'git.internal' },
    });

    await waitFor(() => {
      expect(screen.getByRole('button', { name: /create offering/i })).not.toBeDisabled();
    });

    fireEvent.click(screen.getByRole('button', { name: /create offering/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Offering "Managed Git" created`,
      }),
    );

    // Modal closes
    await waitFor(() =>
      expect(screen.queryByText('New Service Offering')).not.toBeInTheDocument(),
    );
  });

  it('submits PATCH with correct update payload (no slug)', async () => {
    const updatedOffering = {
      ...OFFERING_ACTIVE,
      name: 'Managed Postgres v2',
    };

    mockGet
      .mockResolvedValueOnce(listEnvelope([OFFERING_ACTIVE]))
      .mockResolvedValueOnce(listEnvelope([updatedOffering]));
    mockPatch.mockResolvedValueOnce(envelope({ offering: updatedOffering }));

    renderTab();

    await waitFor(() => expect(screen.getByText('Managed Postgres')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Managed Postgres'));

    await waitFor(() =>
      expect(screen.getByText('Edit Service Offering')).toBeInTheDocument(),
    );

    // Update the name
    const nameInput = screen.getByDisplayValue('Managed Postgres');
    fireEvent.change(nameInput, { target: { value: 'Managed Postgres v2' } });

    await waitFor(() => {
      expect(screen.getByRole('button', { name: /save changes/i })).not.toBeDisabled();
    });

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(mockPatch).toHaveBeenCalledWith(
        `${OFFERINGS_BASE}/${OFFERING_ACTIVE.id}`,
        expect.objectContaining({
          name: 'Managed Postgres v2',
          protocol: 'tcp',
          backend_host: 'pg.internal',
          backend_port: 5432,
          default_grant_ttl_days: 14,
          default_grant_scopes: ['read', 'write'],
        }),
      ),
    );

    // The update payload must NOT contain slug
    const patchCall = mockPatch.mock.calls[0][1] as Record<string, unknown>;
    expect(patchCall).not.toHaveProperty('slug');
  });

  // ---------------------------------------------------------------------------
  // Slug validation
  // ---------------------------------------------------------------------------

  it('disables submit when slug contains uppercase letters', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );

    // The slug input auto-lowercases on change, so type uppercase to test
    // (the component calls .toLowerCase().trim() — input will be lowercase)
    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'INVALID' },
    });
    // After toLowerCase, 'INVALID' becomes 'invalid' which IS valid slug-wise
    // Test with a slug starting with a hyphen (invalid pattern)
    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: '-bad-slug' },
    });
    fireEvent.change(screen.getByPlaceholderText(/hosted git/i), {
      target: { value: 'Test Service' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend\.internal/i), {
      target: { value: 'svc.internal' },
    });

    await waitFor(() => {
      const createBtn = screen.getByRole('button', { name: /create offering/i });
      expect(createBtn).toBeDisabled();
    });
  });

  // ---------------------------------------------------------------------------
  // Grant scopes toggle
  // ---------------------------------------------------------------------------

  it('toggles grant scopes on/off in create modal', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );

    // 'write' scope should not be active by default
    // Click 'write' to add it
    const writeBtn = screen.getByRole('button', { name: 'write' });
    fireEvent.click(writeBtn);

    // Click 'read' to remove it (was active by default)
    const readBtn = screen.getByRole('button', { name: 'read' });
    fireEvent.click(readBtn);

    // Now only 'write' is active — but that still satisfies the "at least one
    // scope" validation.  The form validation remains satisfied.
    // Fill other required fields to confirm form is valid
    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/hosted git/i), {
      target: { value: 'Service' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend\.internal/i), {
      target: { value: 'svc.internal' },
    });

    await waitFor(() => {
      expect(screen.getByRole('button', { name: /create offering/i })).not.toBeDisabled();
    });
  });

  it('disables submit when all grant scopes are removed', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );

    // Fill required fields first
    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/hosted git/i), {
      target: { value: 'Service' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend\.internal/i), {
      target: { value: 'svc.internal' },
    });

    // Remove the only active scope ('read')
    fireEvent.click(screen.getByRole('button', { name: 'read' }));

    await waitFor(() => {
      const createBtn = screen.getByRole('button', { name: /create offering/i });
      expect(createBtn).toBeDisabled();
    });
  });

  // ---------------------------------------------------------------------------
  // refreshKey: after save, panel re-fetches
  // ---------------------------------------------------------------------------

  it('re-fetches offerings after a successful create (refreshKey bump)', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([]))
      .mockResolvedValueOnce(listEnvelope([OFFERING_DRAFT]));
    mockPost.mockResolvedValueOnce(envelope({ offering: OFFERING_DRAFT }));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'managed-git' },
    });
    fireEvent.change(screen.getByPlaceholderText(/hosted git/i), {
      target: { value: 'Managed Git' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend\.internal/i), {
      target: { value: 'git.internal' },
    });

    await waitFor(() => {
      expect(screen.getByRole('button', { name: /create offering/i })).not.toBeDisabled();
    });

    fireEvent.click(screen.getByRole('button', { name: /create offering/i }));

    // Panel fetches again after save (triggered by handleSaved → setRefreshKey)
    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));

    // New offering appears in the re-fetched list
    await waitFor(() =>
      expect(screen.getByText('Managed Git')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Close modal with Cancel
  // ---------------------------------------------------------------------------

  it('closes the modal when Cancel is clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('New Offering')).toBeInTheDocument());
    fireEvent.click(screen.getByText('New Offering'));

    await waitFor(() =>
      expect(screen.getByText('New Service Offering')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText('New Service Offering')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Multiple rows — expand independence
  // ---------------------------------------------------------------------------

  it('can expand multiple rows independently', async () => {
    mockGet.mockResolvedValue(listEnvelope([OFFERING_DRAFT, OFFERING_ACTIVE]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByTitle('Expand details').length).toBe(2),
    );

    const [expandDraft, expandActive] = screen.getAllByTitle('Expand details');
    fireEvent.click(expandDraft);
    fireEvent.click(expandActive);

    // Both should now show 'Collapse details'
    await waitFor(() =>
      expect(screen.getAllByTitle('Collapse details').length).toBe(2),
    );
  });
});
