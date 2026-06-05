import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { RoutePoliciesList } from './RoutePoliciesList';
import type { SdwanRoutePolicy, SdwanRoutePolicyStatement } from '../../../types/sdwan.types';

// =============================================================================
// Mocks
//
// RoutePoliciesList calls:
//   sdwanApi.listRoutePolicies({ scope?, direction? })   — on mount + filter change
//   sdwanApi.getRoutePolicy(id)                          — lazily on first expand
//
// EntityLink is the only shared component used; it references
// usePermissions + entityRegistry. We stub it to a plain <span> so we
// don't have to set up the registry.
// =============================================================================

const mockListRoutePolicies = jest.fn();
const mockGetRoutePolicy = jest.fn();

jest.mock('../../../services/api/sdwanApi', () => ({
  sdwanApi: {
    listRoutePolicies: (...args: unknown[]) => mockListRoutePolicies(...args),
    getRoutePolicy: (...args: unknown[]) => mockGetRoutePolicy(...args),
  },
}));

jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label, id }: { label?: React.ReactNode; id?: string | null }) => (
    <span data-testid="entity-link">{label ?? id}</span>
  ),
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => true }),
}));

// =============================================================================
// Fixtures
// =============================================================================

const STMT_A: SdwanRoutePolicyStatement = {
  match: { prefix_in: ['10.0.0.0/8', '192.168.0.0/16'] },
  action: { type: 'accept', set_local_pref: 200 },
};

const STMT_B: SdwanRoutePolicyStatement = {
  match: { as_path_regex: '^65000.*' },
  action: { type: 'reject' },
};

const STMT_COMMUNITY: SdwanRoutePolicyStatement = {
  match: { community_in: ['65000:100'], tag_in: ['prod'], peer_in: ['peer-1'] },
  action: { type: 'accept', add_community: '65001:200', set_med: 50, prepend_as_path: 2 },
};

const POLICY_ACCOUNT: SdwanRoutePolicy = {
  id: 'pol-001',
  name: 'allow-all-import',
  description: 'Accept all incoming routes',
  scope: 'account',
  scope_resource_id: null,
  direction: 'import',
  enabled: true,
  statement_count: 2,
  slug: 'allow-all-import',
  created_at: '2026-05-01T10:00:00Z',
  updated_at: '2026-05-10T12:00:00Z',
};

const POLICY_NETWORK: SdwanRoutePolicy = {
  id: 'pol-002',
  name: 'net-export-filter',
  description: null,
  scope: 'network',
  scope_resource_id: 'net-abcdef12',
  direction: 'export',
  enabled: false,
  statement_count: 1,
  slug: 'net-export-filter',
  created_at: '2026-05-02T08:00:00Z',
  updated_at: null,
};

const POLICY_PEER: SdwanRoutePolicy = {
  id: 'pol-003',
  name: 'peer-reject-bogons',
  description: undefined,
  scope: 'peer',
  scope_resource_id: 'peer-deadbeef',
  direction: 'import',
  enabled: true,
  statement_count: 3,
  slug: 'peer-reject-bogons',
};

// A policy whose list response already carries `statements` inline — so no
// lazy fetch is triggered on expand.
const POLICY_WITH_INLINE_STMTS: SdwanRoutePolicy = {
  id: 'pol-004',
  name: 'inline-policy',
  description: null,
  scope: 'account',
  scope_resource_id: null,
  direction: 'export',
  enabled: true,
  statement_count: 1,
  slug: 'inline-policy',
  statements: [STMT_A],
};

// =============================================================================
// Render helper
// =============================================================================

function renderList(props: React.ComponentProps<typeof RoutePoliciesList> = {}) {
  return render(<RoutePoliciesList {...props} />);
}

// =============================================================================
// Tests
// =============================================================================

describe('RoutePoliciesList', () => {
  beforeEach(() => {
    mockListRoutePolicies.mockReset();
    mockGetRoutePolicy.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while the initial fetch is in flight', async () => {
    // never resolve so loading state is stable
    mockListRoutePolicies.mockImplementation(() => new Promise(() => {}));
    renderList();
    expect(screen.getByText('Loading…')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('renders the error message when listRoutePolicies rejects', async () => {
    mockListRoutePolicies.mockRejectedValue(new Error('Network error'));
    renderList();
    await waitFor(() =>
      expect(screen.getByText('Network error')).toBeInTheDocument(),
    );
  });

  it('renders a generic fallback error for non-Error rejections', async () => {
    mockListRoutePolicies.mockRejectedValue('oops');
    renderList();
    await waitFor(() =>
      expect(screen.getByText('Failed to load route policies')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders the empty-state message when no policies exist', async () => {
    mockListRoutePolicies.mockResolvedValue({ route_policies: [], count: 0 });
    renderList();
    await waitFor(() =>
      expect(screen.getByText('No route policies yet.')).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/Route policies control which prefixes/),
    ).toBeInTheDocument();
  });

  it('shows "0 policies" counter when empty', async () => {
    mockListRoutePolicies.mockResolvedValue({ route_policies: [], count: 0 });
    renderList();
    await waitFor(() =>
      expect(screen.getByText('0 policies')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // List rendering
  // ---------------------------------------------------------------------------

  it('renders a row for each policy with name, scope, direction, statement count and enabled indicator', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT, POLICY_NETWORK],
      count: 2,
    });
    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );
    expect(screen.getByText('Accept all incoming routes')).toBeInTheDocument();
    expect(screen.getByText('net-export-filter')).toBeInTheDocument();

    // Scope badges
    expect(screen.getByText('account')).toBeInTheDocument();
    expect(screen.getByText('network')).toBeInTheDocument();

    // Direction values
    const importCells = screen.getAllByText('import');
    expect(importCells.length).toBeGreaterThan(0);
    const exportCells = screen.getAllByText('export');
    expect(exportCells.length).toBeGreaterThan(0);

    // Statement counts
    expect(screen.getByText('2')).toBeInTheDocument();
    expect(screen.getByText('1')).toBeInTheDocument();

    // Policy counter
    expect(screen.getByText('2 policies')).toBeInTheDocument();
  });

  it('shows singular "policy" when exactly 1 policy exists', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    renderList();
    await waitFor(() =>
      expect(screen.getByText('1 policy')).toBeInTheDocument(),
    );
  });

  it('calls listRoutePolicies without filters by default', async () => {
    mockListRoutePolicies.mockResolvedValue({ route_policies: [], count: 0 });
    renderList();
    await waitFor(() => expect(mockListRoutePolicies).toHaveBeenCalledTimes(1));
    expect(mockListRoutePolicies).toHaveBeenCalledWith({
      scope: undefined,
      direction: undefined,
    });
  });

  it('shows EntityLink for network scope_resource_id', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_NETWORK],
      count: 1,
    });
    renderList();
    await waitFor(() =>
      expect(screen.getByText('net-export-filter')).toBeInTheDocument(),
    );
    // EntityLink should render with the first 8 chars of the resource id
    expect(screen.getByTestId('entity-link')).toBeInTheDocument();
    expect(screen.getByTestId('entity-link').textContent).toBe('net-abcd');
  });

  it('renders EntityLink for peer scope_resource_id (sdwan_peer type is registered in the source)', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_PEER],
      count: 1,
    });
    renderList();
    await waitFor(() =>
      expect(screen.getByText('peer-reject-bogons')).toBeInTheDocument(),
    );
    // scopeResourceType('peer') returns 'sdwan_peer' — EntityLink IS rendered.
    // Our mock renders a <span data-testid="entity-link"> with the first-8-char label.
    expect(screen.getByTestId('entity-link')).toBeInTheDocument();
    expect(screen.getByTestId('entity-link').textContent).toBe('peer-dea');
  });

  // ---------------------------------------------------------------------------
  // Filter controls
  // ---------------------------------------------------------------------------

  it('re-fetches with scope filter when the scope select changes', async () => {
    mockListRoutePolicies.mockResolvedValue({ route_policies: [], count: 0 });
    renderList();

    await waitFor(() => expect(mockListRoutePolicies).toHaveBeenCalledTimes(1));

    const scopeSelect = screen.getByDisplayValue('All scopes');
    fireEvent.change(scopeSelect, { target: { value: 'network' } });

    await waitFor(() => expect(mockListRoutePolicies).toHaveBeenCalledTimes(2));
    expect(mockListRoutePolicies).toHaveBeenLastCalledWith({
      scope: 'network',
      direction: undefined,
    });
  });

  it('re-fetches with direction filter when the direction select changes', async () => {
    mockListRoutePolicies.mockResolvedValue({ route_policies: [], count: 0 });
    renderList();

    await waitFor(() => expect(mockListRoutePolicies).toHaveBeenCalledTimes(1));

    const directionSelect = screen.getByDisplayValue('Both directions');
    fireEvent.change(directionSelect, { target: { value: 'export' } });

    await waitFor(() => expect(mockListRoutePolicies).toHaveBeenCalledTimes(2));
    expect(mockListRoutePolicies).toHaveBeenLastCalledWith({
      scope: undefined,
      direction: 'export',
    });
  });

  it('passes both filters together when both are set', async () => {
    mockListRoutePolicies.mockResolvedValue({ route_policies: [], count: 0 });
    renderList();

    await waitFor(() => expect(mockListRoutePolicies).toHaveBeenCalledTimes(1));

    const scopeSelect = screen.getByDisplayValue('All scopes');
    fireEvent.change(scopeSelect, { target: { value: 'peer' } });

    await waitFor(() => expect(mockListRoutePolicies).toHaveBeenCalledTimes(2));

    const dirSelect = screen.getByDisplayValue('Both directions');
    fireEvent.change(dirSelect, { target: { value: 'import' } });

    await waitFor(() => expect(mockListRoutePolicies).toHaveBeenCalledTimes(3));
    expect(mockListRoutePolicies).toHaveBeenLastCalledWith({
      scope: 'peer',
      direction: 'import',
    });
  });

  it('refetches when refreshKey prop changes', async () => {
    mockListRoutePolicies.mockResolvedValue({ route_policies: [], count: 0 });
    const { rerender } = renderList({ refreshKey: 1 });

    await waitFor(() => expect(mockListRoutePolicies).toHaveBeenCalledTimes(1));

    rerender(<RoutePoliciesList refreshKey={2} />);

    await waitFor(() => expect(mockListRoutePolicies).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  it('clicking the expand button toggles the row and shows detail panel', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    // getRoutePolicy returns the full policy with statements
    mockGetRoutePolicy.mockResolvedValue({
      ...POLICY_ACCOUNT,
      statements: [STMT_A, STMT_B],
    });
    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    // No detail panel yet — "Slug" label only appears in the expanded detail
    expect(screen.queryByText('Slug')).not.toBeInTheDocument();

    // Expand
    fireEvent.click(screen.getByTitle('Expand details'));

    // Detail section appears — Slug label is only in the expanded panel
    await waitFor(() =>
      expect(screen.getByText('Slug')).toBeInTheDocument(),
    );

    // Slug is shown
    expect(screen.getByText('allow-all-import', { selector: 'p' })).toBeInTheDocument();
  });

  it('fetches detail on first expand and caches — second expand reuses cached data', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    mockGetRoutePolicy.mockResolvedValue({
      ...POLICY_ACCOUNT,
      statements: [STMT_A],
    });
    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    // First expand — triggers fetch
    fireEvent.click(screen.getByTitle('Expand details'));
    await waitFor(() => expect(mockGetRoutePolicy).toHaveBeenCalledTimes(1));
    expect(mockGetRoutePolicy).toHaveBeenCalledWith('pol-001');

    // Collapse
    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() =>
      expect(screen.queryByText('Statements (2)')).not.toBeInTheDocument(),
    );

    // Second expand — should NOT call getRoutePolicy again (cached)
    fireEvent.click(screen.getByTitle('Expand details'));
    await waitFor(() =>
      expect(screen.getAllByText('Scope').length).toBeGreaterThan(0),
    );
    expect(mockGetRoutePolicy).toHaveBeenCalledTimes(1);
  });

  it('does NOT call getRoutePolicy when the list response already has inline statements', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_WITH_INLINE_STMTS],
      count: 1,
    });
    renderList();

    await waitFor(() =>
      expect(screen.getByText('inline-policy')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    // Statements rendered from inline data
    await waitFor(() =>
      expect(screen.getByText('Statements (1)')).toBeInTheDocument(),
    );
    expect(mockGetRoutePolicy).not.toHaveBeenCalled();
  });

  it('shows "Loading statements…" while the detail fetch is in flight', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    // never resolve detail
    mockGetRoutePolicy.mockImplementation(() => new Promise(() => {}));
    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Loading statements…')).toBeInTheDocument(),
    );
  });

  it('shows the detail fetch error when getRoutePolicy rejects', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    mockGetRoutePolicy.mockRejectedValue(new Error('Detail failed'));
    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Detail failed')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Statement rendering (matchSummary + actionSummary)
  // ---------------------------------------------------------------------------

  it('renders statements with correct match and action summaries', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    mockGetRoutePolicy.mockResolvedValue({
      ...POLICY_ACCOUNT,
      statements: [STMT_A, STMT_B],
    });
    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(
        screen.getByText(/prefix ∈ \[10\.0\.0\.0\/8, 192\.168\.0\.0\/16\]/),
      ).toBeInTheDocument(),
    );
    expect(screen.getByText(/local-pref 200/)).toBeInTheDocument();
    // STMT_B: as-path match + reject action
    expect(screen.getByText(/as-path ~ \/\^65000\.\*\//)).toBeInTheDocument();
    expect(screen.getAllByText(/reject/).length).toBeGreaterThan(0);
  });

  it('renders "any" match summary when the match object has no criteria', async () => {
    const STMT_EMPTY: SdwanRoutePolicyStatement = {
      match: {},
      action: { type: 'accept' },
    };
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    mockGetRoutePolicy.mockResolvedValue({
      ...POLICY_ACCOUNT,
      statements: [STMT_EMPTY],
    });
    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      // "match any then accept"
      expect(screen.getByText(/any/)).toBeInTheDocument(),
    );
  });

  it('renders all match+action parts for a complex statement', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    mockGetRoutePolicy.mockResolvedValue({
      ...POLICY_ACCOUNT,
      statements: [STMT_COMMUNITY],
    });
    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText(/community ∈ \[65000:100\]/)).toBeInTheDocument(),
    );
    expect(screen.getByText(/tag ∈ \[prod\]/)).toBeInTheDocument();
    expect(screen.getByText(/peer ∈ \[peer-1\]/)).toBeInTheDocument();
    expect(screen.getByText(/\+community 65001:200/)).toBeInTheDocument();
    expect(screen.getByText(/med 50/)).toBeInTheDocument();
    expect(screen.getByText(/prepend-as 2/)).toBeInTheDocument();
  });

  it('renders "No statements defined." when the fetched policy has an empty statements array', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    mockGetRoutePolicy.mockResolvedValue({
      ...POLICY_ACCOUNT,
      statements: [],
    });
    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('No statements defined.')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Row action callbacks (onEdit / onDelete / onToggle)
  // ---------------------------------------------------------------------------

  it('calls onEdit with the correct policy when the Edit button is clicked', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    const onEdit = jest.fn();
    renderList({ onEdit });

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Edit'));
    expect(onEdit).toHaveBeenCalledWith(POLICY_ACCOUNT);
  });

  it('calls onDelete with the correct policy when the Delete button is clicked', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    const onDelete = jest.fn();
    renderList({ onDelete });

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Delete'));
    expect(onDelete).toHaveBeenCalledWith(POLICY_ACCOUNT);
  });

  it('calls onToggle with the correct policy when the toggle button is clicked', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    const onToggle = jest.fn();
    renderList({ onToggle });

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    // POLICY_ACCOUNT is enabled, so the button title is "Disable"
    fireEvent.click(screen.getByTitle('Disable'));
    expect(onToggle).toHaveBeenCalledWith(POLICY_ACCOUNT);
  });

  it('toggle button shows "Enable" title when the policy is disabled', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_NETWORK],
      count: 1,
    });
    const onToggle = jest.fn();
    renderList({ onToggle });

    await waitFor(() =>
      expect(screen.getByText('net-export-filter')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Enable'));
    expect(onToggle).toHaveBeenCalledWith(POLICY_NETWORK);
  });

  it('hides Edit button when onEdit is not provided', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    renderList({ onDelete: jest.fn() });

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    expect(screen.queryByTitle('Edit')).not.toBeInTheDocument();
  });

  it('hides Delete button when onDelete is not provided', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    renderList({ onEdit: jest.fn() });

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    expect(screen.queryByTitle('Delete')).not.toBeInTheDocument();
  });

  it('hides toggle button when onToggle is not provided', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    renderList({ onEdit: jest.fn() });

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    expect(screen.queryByTitle('Disable')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Enable')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Expanded detail — metadata fields
  // ---------------------------------------------------------------------------

  it('shows slug, enabled status and timestamps in the expanded detail panel', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT],
      count: 1,
    });
    mockGetRoutePolicy.mockResolvedValue({
      ...POLICY_ACCOUNT,
      statements: [],
    });
    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Statements (2)')).toBeInTheDocument(),
    );

    // Slug
    expect(screen.getByText('allow-all-import', { selector: 'p' })).toBeInTheDocument();
    // Enabled: Yes
    expect(screen.getByText('Yes')).toBeInTheDocument();
    // Timestamps — rendered via toLocaleString
    expect(screen.getByText('Created')).toBeInTheDocument();
    expect(screen.getByText('Updated')).toBeInTheDocument();
  });

  it('does not render Created/Updated labels when timestamps are absent', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_PEER],
      count: 1,
    });
    mockGetRoutePolicy.mockResolvedValue({
      ...POLICY_PEER,
      statements: [],
    });
    renderList();

    await waitFor(() =>
      expect(screen.getByText('peer-reject-bogons')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Statements (3)')).toBeInTheDocument(),
    );

    expect(screen.queryByText('Created')).not.toBeInTheDocument();
    expect(screen.queryByText('Updated')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Multiple rows — expand one while another is collapsed (independent state)
  // ---------------------------------------------------------------------------

  it('can expand two rows independently without collapsing each other', async () => {
    mockListRoutePolicies.mockResolvedValue({
      route_policies: [POLICY_ACCOUNT, POLICY_NETWORK],
      count: 2,
    });
    mockGetRoutePolicy
      .mockResolvedValueOnce({ ...POLICY_ACCOUNT, statements: [STMT_A] })
      .mockResolvedValueOnce({ ...POLICY_NETWORK, statements: [STMT_B] });

    renderList();

    await waitFor(() =>
      expect(screen.getByText('allow-all-import')).toBeInTheDocument(),
    );

    const expandButtons = screen.getAllByTitle('Expand details');
    expect(expandButtons).toHaveLength(2);

    fireEvent.click(expandButtons[0]);
    await waitFor(() => expect(mockGetRoutePolicy).toHaveBeenCalledTimes(1));

    fireEvent.click(expandButtons[1]);
    await waitFor(() => expect(mockGetRoutePolicy).toHaveBeenCalledTimes(2));

    // Both rows are expanded — both collapse buttons visible
    expect(screen.getAllByTitle('Collapse details')).toHaveLength(2);
  });
});
