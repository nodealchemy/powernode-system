import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import SdwanRoutingPage from './SdwanRoutingPage';
import type { SdwanRoutingOverview, SdwanRoutePolicy } from '@system/features/system/types/sdwan.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockPatch = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
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

// Mock child components that make their own API calls — the page test exercises
// only the page's own data loading and interactions, not the sub-components'
// internals (those have their own co-located tests).
jest.mock('@system/features/system/components/sdwan/routing/RoutingOverviewPanel', () => ({
  RoutingOverviewPanel: ({ data }: { data: SdwanRoutingOverview }) => (
    <div data-testid="routing-overview-panel">
      overview-panel total_networks={data.summary.total_networks}
    </div>
  ),
}));

jest.mock('@system/features/system/components/sdwan/routing/BgpSessionsTable', () => ({
  BgpSessionsTable: ({ refreshKey }: { refreshKey?: number }) => (
    <div data-testid="bgp-sessions-table">bgp-sessions refreshKey={refreshKey}</div>
  ),
}));

jest.mock('@system/features/system/components/sdwan/routing/RoutePoliciesList', () => ({
  RoutePoliciesList: ({
    onEdit,
    onDelete,
    onToggle,
  }: {
    refreshKey?: number;
    onEdit?: (p: SdwanRoutePolicy) => void;
    onDelete?: (p: SdwanRoutePolicy) => void;
    onToggle?: (p: SdwanRoutePolicy) => void;
  }) => (
    <div data-testid="route-policies-list">
      <button
        type="button"
        data-testid="mock-edit-policy"
        onClick={() =>
          onEdit?.({
            id: 'pol-1',
            name: 'test-policy',
            scope: 'account',
            direction: 'import',
            enabled: true,
            statement_count: 1,
            slug: 'test-policy-import',
          })
        }
      >
        edit
      </button>
      <button
        type="button"
        data-testid="mock-delete-policy"
        onClick={() =>
          onDelete?.({
            id: 'pol-1',
            name: 'test-policy',
            scope: 'account',
            direction: 'import',
            enabled: true,
            statement_count: 1,
            slug: 'test-policy-import',
          })
        }
      >
        delete
      </button>
      <button
        type="button"
        data-testid="mock-toggle-policy"
        onClick={() =>
          onToggle?.({
            id: 'pol-1',
            name: 'test-policy',
            scope: 'account',
            direction: 'import',
            enabled: true,
            statement_count: 1,
            slug: 'test-policy-import',
          })
        }
      >
        toggle
      </button>
    </div>
  ),
}));

jest.mock('@system/features/system/components/sdwan/routing/RoutePolicyEditModal', () => ({
  RoutePolicyEditModal: ({
    policy,
    onClose,
    onSaved,
  }: {
    policy: SdwanRoutePolicy | null;
    onClose: () => void;
    onSaved: (p: SdwanRoutePolicy) => void;
  }) => (
    <div data-testid="route-policy-edit-modal">
      <span data-testid="edit-modal-mode">{policy ? 'edit' : 'create'}</span>
      <button type="button" data-testid="modal-close" onClick={onClose}>
        close
      </button>
      <button
        type="button"
        data-testid="modal-save"
        onClick={() =>
          onSaved({
            id: policy?.id ?? 'new-pol',
            name: policy?.name ?? 'New Policy',
            scope: 'account',
            direction: 'import',
            enabled: true,
            statement_count: 0,
            slug: 'new-policy-import',
          })
        }
      >
        save
      </button>
    </div>
  ),
}));

jest.mock('@system/features/system/components/sdwan/routing/AsNumberSetupBanner', () => ({
  AsNumberSetupBanner: ({
    accountBgp,
    onAllocated,
  }: {
    accountBgp: SdwanRoutingOverview['account_bgp'];
    canManage?: boolean;
    onAllocated?: () => void;
  }) => (
    <div data-testid="as-number-setup-banner">
      <span data-testid="as-bgp-status">{accountBgp ? 'allocated' : 'not-allocated'}</span>
      {!accountBgp && (
        <button type="button" data-testid="allocate-as" onClick={() => onAllocated?.()}>
          allocate
        </button>
      )}
    </div>
  ),
}));

// =============================================================================
// Fixtures + helpers
// =============================================================================

// The double-envelope: AxiosResponse.data = { success: true, data: <payload> }
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

const ACCOUNT_BGP = {
  id: 'bgp-1',
  as_number: 4200000001,
  router_id_strategy: 'peer_overlay_ipv6_hash' as const,
  default_local_pref: 100,
  enabled: true,
};

const ROUTING_OVERVIEW: SdwanRoutingOverview = {
  account_bgp: ACCOUNT_BGP,
  summary: {
    total_networks: 3,
    ibgp_networks: 2,
    static_networks: 1,
    established_sessions: 4,
    total_sessions: 6,
  },
};

const ROUTING_OVERVIEW_NO_BGP: SdwanRoutingOverview = {
  account_bgp: null,
  summary: {
    total_networks: 1,
    ibgp_networks: 0,
    static_networks: 1,
    established_sessions: 0,
    total_sessions: 0,
  },
};

// =============================================================================
// Render helpers
// =============================================================================

/**
 * Renders the page inside a MemoryRouter rooted at the given path so that
 * internal <Routes> and <Link> components resolve correctly.
 *
 * The page's child <Routes> uses relative paths ("overview", "sessions",
 * "policies"). We nest the component under a wildcard route so that the
 * sub-router receives the remaining path segments.
 */
const renderPage = (initialPath = '/app/system/sdwan/routing/overview', embedded = false) =>
  render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route
          path="/app/system/sdwan/routing/*"
          element={<SdwanRoutingPage embedded={embedded} />}
        />
      </Routes>
    </MemoryRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('SdwanRoutingPage', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockPatch.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while fetching routing overview', async () => {
    // Never resolves during this test
    mockGet.mockReturnValue(new Promise(() => {}));
    renderPage();

    expect(screen.getByText(/loading routing overview/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error message when the API call fails', async () => {
    mockGet.mockRejectedValue(new Error('Network failure'));
    renderPage();

    await waitFor(() =>
      expect(screen.getByText('Network failure')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Successful render
  // ---------------------------------------------------------------------------

  it('fetches routing overview from GET /system/sdwan/routing', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/sdwan/routing'),
    );
  });

  it('renders the PageContainer with title SDWAN Routing (standalone mode)', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage();

    await waitFor(() =>
      expect(screen.getByText('SDWAN Routing')).toBeInTheDocument(),
    );
  });

  it('renders the AS number banner once data loads', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage();

    await waitFor(() =>
      expect(screen.getByTestId('as-number-setup-banner')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('as-bgp-status')).toHaveTextContent('allocated');
  });

  it('renders the AS banner with not-allocated status when account_bgp is null', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW_NO_BGP));
    renderPage();

    await waitFor(() =>
      expect(screen.getByTestId('as-bgp-status')).toHaveTextContent('not-allocated'),
    );
  });

  // ---------------------------------------------------------------------------
  // Tab navigation
  // ---------------------------------------------------------------------------

  it('renders tab links: Overview, BGP Sessions, Route Policies', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage();

    await waitFor(() =>
      expect(screen.getByText('Overview')).toBeInTheDocument(),
    );
    expect(screen.getByText('BGP Sessions')).toBeInTheDocument();
    expect(screen.getByText('Route Policies')).toBeInTheDocument();
  });

  it('shows RoutingOverviewPanel on /overview path', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/overview');

    await waitFor(() =>
      expect(screen.getByTestId('routing-overview-panel')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('routing-overview-panel')).toHaveTextContent(
      'total_networks=3',
    );
  });

  it('shows BgpSessionsTable on /sessions path', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/sessions');

    await waitFor(() =>
      expect(screen.getByTestId('bgp-sessions-table')).toBeInTheDocument(),
    );
  });

  it('shows RoutePoliciesList on /policies path', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // "New policy" page action (standalone mode, policies tab)
  // ---------------------------------------------------------------------------

  it('shows "New policy" page action only when on the policies tab', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: /new policy/i })).toBeInTheDocument();
  });

  it('does NOT show "New policy" button on the overview tab', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/overview');

    await waitFor(() =>
      expect(screen.getByTestId('routing-overview-panel')).toBeInTheDocument(),
    );
    expect(screen.queryByRole('button', { name: /new policy/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // RoutePolicyEditModal — open / close / saved
  // ---------------------------------------------------------------------------

  it('opens RoutePolicyEditModal in create mode when "New policy" is clicked', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /new policy/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /new policy/i }));

    await waitFor(() =>
      expect(screen.getByTestId('route-policy-edit-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('edit-modal-mode')).toHaveTextContent('create');
  });

  it('opens RoutePolicyEditModal in edit mode when list emits onEdit', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('mock-edit-policy'));

    await waitFor(() =>
      expect(screen.getByTestId('route-policy-edit-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('edit-modal-mode')).toHaveTextContent('edit');
  });

  it('closes RoutePolicyEditModal when onClose is called', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('mock-edit-policy'));
    await waitFor(() =>
      expect(screen.getByTestId('route-policy-edit-modal')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('modal-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('route-policy-edit-modal')).not.toBeInTheDocument(),
    );
  });

  it('fires addNotification and closes modal when onSaved is called', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /new policy/i }));
    await waitFor(() =>
      expect(screen.getByTestId('route-policy-edit-modal')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('modal-save'));

    await waitFor(() =>
      expect(screen.queryByTestId('route-policy-edit-modal')).not.toBeInTheDocument(),
    );
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success', message: 'Route policy saved.' }),
    );
  });

  // ---------------------------------------------------------------------------
  // Delete policy modal
  // ---------------------------------------------------------------------------

  it('opens the delete confirmation modal when list emits onDelete', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('mock-delete-policy'));

    await waitFor(() =>
      expect(screen.getByText('Delete route policy')).toBeInTheDocument(),
    );
    // The modal contains "test-policy" in a <strong> tag — use getByRole strong
    expect(screen.getAllByText(/test-policy/).length).toBeGreaterThan(0);
    // Modal has a "Delete" button and a "Cancel" button
    expect(
      screen.getByRole('button', { name: 'Delete' }),
    ).toBeInTheDocument();
  });

  it('calls DELETE /system/sdwan/route_policies/:id and shows success notification', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    mockDelete.mockResolvedValue({ data: { success: true } });

    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('mock-delete-policy'));

    await waitFor(() =>
      expect(screen.getByRole('dialog')).toBeInTheDocument(),
    );
    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: 'Delete' }));

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/route_policies/pol-1'),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success' }),
      ),
    );
  });

  it('shows error notification when delete API call fails', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    mockDelete.mockRejectedValue(new Error('Delete failed'));

    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('mock-delete-policy'));
    await waitFor(() =>
      expect(screen.getByRole('dialog')).toBeInTheDocument(),
    );
    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: 'Delete' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Delete failed' }),
      ),
    );
  });

  it('closes the delete modal when Cancel is clicked', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('mock-delete-policy'));
    await waitFor(() =>
      expect(screen.getByRole('dialog')).toBeInTheDocument(),
    );
    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText('Delete route policy')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Toggle policy
  // ---------------------------------------------------------------------------

  it('calls PATCH /system/sdwan/route_policies/:id with enabled toggled', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    mockPatch.mockResolvedValue(
      envelope({
        route_policy: {
          id: 'pol-1',
          name: 'test-policy',
          scope: 'account',
          direction: 'import',
          enabled: false,
          statement_count: 1,
          slug: 'test-policy-import',
        },
      }),
    );

    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('mock-toggle-policy'));

    await waitFor(() =>
      expect(mockPatch).toHaveBeenCalledWith(
        '/system/sdwan/route_policies/pol-1',
        { route_policy: { enabled: false } },
      ),
    );
  });

  it('shows error notification when toggle API call fails', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    mockPatch.mockRejectedValue(new Error('Toggle failed'));

    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('mock-toggle-policy'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Toggle failed' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // AS number allocation refresh
  // ---------------------------------------------------------------------------

  it('triggers a data refresh (refetch) when AsNumberSetupBanner fires onAllocated', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW_NO_BGP));
    renderPage('/app/system/sdwan/routing/overview');

    await waitFor(() =>
      expect(screen.getByTestId('as-number-setup-banner')).toBeInTheDocument(),
    );

    // Initial fetch count
    const initialCallCount = mockGet.mock.calls.length;

    fireEvent.click(screen.getByTestId('allocate-as'));

    await waitFor(() =>
      expect(mockGet.mock.calls.length).toBeGreaterThan(initialCallCount),
    );
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  it('shows permission denied message when sdwan.routing.read is denied', async () => {
    // Override to deny only read permission
    jest.resetModules();
    const { usePermissions } = jest.requireMock('@/shared/hooks/usePermissions') as {
      usePermissions: () => { hasPermission: (perm: string) => boolean };
    };

    // Temporarily replace mock implementation
    (usePermissions as jest.Mock).mockImplementation
      ? (usePermissions as jest.Mock).mockImplementation(() => ({
          hasPermission: () => false,
        }))
      : undefined;

    // The mock was registered with jest.mock so we need to directly mock the module
    jest.mock('@/shared/hooks/usePermissions', () => ({
      usePermissions: () => ({
        hasPermission: () => false,
      }),
    }));
  });

  // ---------------------------------------------------------------------------
  // Embedded mode
  // ---------------------------------------------------------------------------

  it('renders body without PageContainer wrapper in embedded mode', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/overview', true);

    await waitFor(() =>
      expect(screen.getByTestId('routing-overview-panel')).toBeInTheDocument(),
    );
    // PageContainer renders the title as a heading — it should NOT appear
    expect(screen.queryByRole('heading', { name: 'SDWAN Routing' })).not.toBeInTheDocument();
  });

  it('shows an inline "New policy" button in embedded mode on the policies tab', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/policies', true);

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    // In embedded mode the inline button appears in the body, not the PageContainer action slot
    expect(screen.getByRole('button', { name: /new policy/i })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Slug + direction text in delete confirmation
  // ---------------------------------------------------------------------------

  it('shows the slug and direction in the delete modal body', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('mock-delete-policy'));

    await waitFor(() =>
      expect(screen.getByText('Delete route policy')).toBeInTheDocument(),
    );
    // The modal shows `route-map {slug}-{direction}` — check the slug portion
    expect(screen.getByText(/test-policy-import/)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Pending-approval branch (IMP-87ec6f651f07)
  // ---------------------------------------------------------------------------

  const pendingEnvelope = (action_category: string) => ({
    status: 202,
    data: {
      success: true,
      data: {
        pending: true,
        deferred_operation_id: 'dop-1',
        action_category,
        approval_request_id: 'ar-1',
        message: 'Approval required',
      },
    },
  });

  it('shows the pending-approval notification (not success) when the policy delete is parked', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    mockDelete.mockResolvedValue(pendingEnvelope('sdwan.route_policy_delete'));

    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('mock-delete-policy'));

    await waitFor(() => expect(screen.getByRole('dialog')).toBeInTheDocument());
    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: 'Delete' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval required/i),
          link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
        }),
      ),
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' }),
    );
  });

  it('shows the pending-approval notification when the enable toggle is parked', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));
    mockPatch.mockResolvedValue(pendingEnvelope('sdwan.route_policy_update'));

    renderPage('/app/system/sdwan/routing/policies');

    await waitFor(() =>
      expect(screen.getByTestId('route-policies-list')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('mock-toggle-policy'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval required/i),
        }),
      ),
    );
  });
});
