import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { CveTab } from './CveTab';
import type { SystemCveExposure } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
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

// EntityLink — render a plain anchor so tests can assert on labels.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({
    label,
    id,
  }: {
    type: string;
    id?: string;
    label?: string;
    className?: string;
  }) => <a href={`#${id ?? ''}`}>{label}</a>,
}));

// =============================================================================
// Fixtures & helpers
// =============================================================================

/** Build the double-envelope that apiClient resolves to. */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

/** Build a paginated envelope (meta at ROOT of body, not inside data). */
function paginatedEnvelope<T>(payload: T, count = 0) {
  return {
    data: {
      success: true,
      data: payload,
      meta: {
        current_page: 1,
        per_page: 50,
        total_count: count,
        total_pages: 1,
        next_page: null,
        prev_page: null,
      },
    },
  };
}

const CVE_CRITICAL: SystemCveExposure = {
  id: 'exp-1',
  state: 'open',
  package_name: 'openssl',
  package_version: '1.1.1',
  detected_at: '2026-01-15T10:00:00Z',
  resolved_at: null,
  resolution_note: null,
  metadata: {},
  created_at: '2026-01-15T10:00:00Z',
  updated_at: '2026-01-15T10:00:00Z',
  cve: {
    id: 'cve-001',
    cve_id: 'CVE-2026-0001',
    severity: 'critical',
    severity_weight: 10,
    summary: 'A critical buffer overflow in OpenSSL.',
    reference_url: 'https://nvd.nist.gov/vuln/detail/CVE-2026-0001',
    published_at: '2026-01-01T00:00:00Z',
    feed_source: 'NVD',
  },
  node_module: { id: 'mod-1', name: 'openssl-module' },
  node_module_version: {
    id: 'ver-1',
    version_number: '1.0.0',
    promotion_state: 'stable',
  },
};

const CVE_MEDIUM: SystemCveExposure = {
  id: 'exp-2',
  state: 'remediating',
  package_name: 'libcurl',
  package_version: null,
  detected_at: null,
  resolved_at: null,
  resolution_note: null,
  metadata: {},
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
  cve: {
    id: 'cve-002',
    cve_id: 'CVE-2026-0002',
    severity: 'medium',
    severity_weight: 5,
    summary: null,
    reference_url: null,
    published_at: null,
    feed_source: null,
  },
  node_module: null,
  node_module_version: null,
};

const CVE_RESOLVED: SystemCveExposure = {
  id: 'exp-3',
  state: 'resolved',
  package_name: 'zlib',
  package_version: '1.2.11',
  detected_at: '2026-01-20T08:00:00Z',
  resolved_at: '2026-02-10T12:00:00Z',
  resolution_note: 'Upgraded to zlib 1.2.13.',
  metadata: {},
  created_at: '2026-01-20T08:00:00Z',
  updated_at: '2026-02-10T12:00:00Z',
  cve: {
    id: 'cve-003',
    cve_id: 'CVE-2026-0003',
    severity: 'low',
    severity_weight: 2,
    summary: 'Low-severity issue in zlib.',
    reference_url: null,
    published_at: null,
    feed_source: null,
  },
  node_module: { id: 'mod-2', name: 'zlib-module' },
  node_module_version: {
    id: 'ver-2',
    version_number: '1.2.11',
    promotion_state: 'stable',
  },
};

/** Standard list response shape that cveApi.list extracts via extractPaginated. */
function listResponse(exposures: SystemCveExposure[]) {
  return paginatedEnvelope({ cve_exposures: exposures }, exposures.length);
}

const renderTab = (props: React.ComponentProps<typeof CveTab> = {}) =>
  render(
    <BrowserRouter>
      <CveTab {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('CveTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------
  it('shows a loading indicator while the API call is in-flight', () => {
    // Never resolve so we stay in the loading state.
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByText('Loading…')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------
  it('shows the generic empty message when no exposures are returned', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText('No CVE exposures detected in your fleet.'),
      ).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Render — list
  // ---------------------------------------------------------------------------
  it('renders the exposure list with CVE IDs and state badges', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL, CVE_MEDIUM]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('CVE-2026-0001')).toBeInTheDocument(),
    );

    expect(screen.getByText('CVE-2026-0002')).toBeInTheDocument();

    // State badges
    expect(screen.getByText('Open')).toBeInTheDocument();
    expect(screen.getByText('Remediating')).toBeInTheDocument();
  });

  it('shows the count badge in the section header when exposures are present', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL, CVE_MEDIUM]));

    renderTab();

    // Badge showing count "2"
    await waitFor(() => expect(screen.getByText('2')).toBeInTheDocument());
  });

  it('does NOT show the count badge when list is empty', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText('No CVE exposures detected in your fleet.'),
      ).toBeInTheDocument(),
    );
    // Numeric count badge should not be present
    expect(screen.queryByText('0')).not.toBeInTheDocument();
  });

  it('renders package name and version in the collapsed row', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL]));

    renderTab();

    await waitFor(() => expect(screen.getByText('CVE-2026-0001')).toBeInTheDocument());

    // package@version code element
    expect(screen.getByText('openssl@1.1.1')).toBeInTheDocument();
  });

  it('renders package name without version when version is null', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_MEDIUM]));

    renderTab();

    await waitFor(() => expect(screen.getByText('CVE-2026-0002')).toBeInTheDocument());
    expect(screen.getByText('libcurl')).toBeInTheDocument();
  });

  it('renders the CVE summary when present', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL]));

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText('A critical buffer overflow in OpenSSL.'),
      ).toBeInTheDocument(),
    );
  });

  it('renders a Reference link when reference_url is present', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL]));

    renderTab();

    await waitFor(() => expect(screen.getByText('Reference')).toBeInTheDocument());
    const link = screen.getByText('Reference').closest('a');
    expect(link).toHaveAttribute('href', 'https://nvd.nist.gov/vuln/detail/CVE-2026-0001');
    expect(link).toHaveAttribute('target', '_blank');
    expect(link).toHaveAttribute('rel', 'noopener noreferrer');
  });

  it('does not render a Reference link when reference_url is absent', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_MEDIUM]));

    renderTab();

    await waitFor(() => expect(screen.getByText('CVE-2026-0002')).toBeInTheDocument());
    expect(screen.queryByText('Reference')).not.toBeInTheDocument();
  });

  it('renders "Detection time unknown" when detected_at is null', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_MEDIUM]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Detection time unknown')).toBeInTheDocument(),
    );
  });

  it('renders node module EntityLink when node_module is present', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('openssl-module')).toBeInTheDocument(),
    );
  });

  it('renders module version EntityLink when node_module_version is present', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('v1.0.0')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Expand / collapse
  // ---------------------------------------------------------------------------
  it('expands a row to show full detail panel when the chevron button is clicked', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL]));

    renderTab();

    await waitFor(() => expect(screen.getByText('CVE-2026-0001')).toBeInTheDocument());

    const expandBtn = screen.getByTitle('Expand details');
    fireEvent.click(expandBtn);

    // Detail panel fields
    await waitFor(() =>
      expect(screen.getByText('Remediation state')).toBeInTheDocument(),
    );
    expect(screen.getByText('Package')).toBeInTheDocument();
    expect(screen.getByText('Severity')).toBeInTheDocument();
    expect(screen.getByText('Module')).toBeInTheDocument();
    expect(screen.getByText('Module version')).toBeInTheDocument();
    expect(screen.getByText('Feed source')).toBeInTheDocument();
    expect(screen.getByText('NVD')).toBeInTheDocument();
    expect(screen.getByText('Detected')).toBeInTheDocument();
    expect(screen.getByText('Resolved')).toBeInTheDocument();
    expect(screen.getByText('CVE published')).toBeInTheDocument();
    // Promotion state
    expect(screen.getByText('Promotion state')).toBeInTheDocument();
    expect(screen.getByText('stable')).toBeInTheDocument();
  });

  it('shows resolution note in expanded panel when present', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_RESOLVED]));

    renderTab();

    await waitFor(() => expect(screen.getByText('CVE-2026-0003')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Resolution note')).toBeInTheDocument(),
    );
    expect(screen.getByText('Upgraded to zlib 1.2.13.')).toBeInTheDocument();
  });

  it('collapses the detail panel on second chevron click', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL]));

    renderTab();

    await waitFor(() => expect(screen.getByText('CVE-2026-0001')).toBeInTheDocument());

    // Expand
    fireEvent.click(screen.getByTitle('Expand details'));
    await waitFor(() =>
      expect(screen.getByText('Remediation state')).toBeInTheDocument(),
    );

    // Collapse — title changes after first click
    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() =>
      expect(screen.queryByText('Remediation state')).not.toBeInTheDocument(),
    );
  });

  it('can expand multiple rows independently', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL, CVE_RESOLVED]));

    renderTab();

    await waitFor(() => expect(screen.getByText('CVE-2026-0001')).toBeInTheDocument());

    const expandBtns = screen.getAllByTitle('Expand details');
    fireEvent.click(expandBtns[0]);
    fireEvent.click(expandBtns[1]);

    await waitFor(() => {
      // Both detail panels visible — Remediation state label appears twice
      expect(screen.getAllByText('Remediation state').length).toBe(2);
    });
  });

  // ---------------------------------------------------------------------------
  // Severity filter
  // ---------------------------------------------------------------------------
  it('calls the API without severity param on initial load', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderTab();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/cve_exposures', { params: undefined }),
    );
  });

  it('re-fetches with severity param when a filter button is clicked', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderTab();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/cve_exposures', { params: undefined }),
    );

    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL]));
    fireEvent.click(screen.getByRole('button', { name: 'critical' }));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/cve_exposures', {
        params: { severity: 'critical' },
      }),
    );
  });

  it('clears the severity filter and re-fetches when "All" is clicked', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderTab();

    // First select a filter
    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL]));
    fireEvent.click(screen.getByRole('button', { name: 'critical' }));
    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/cve_exposures', {
        params: { severity: 'critical' },
      }),
    );

    // Then click All
    mockGet.mockResolvedValue(listResponse([]));
    fireEvent.click(screen.getByRole('button', { name: 'All' }));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/cve_exposures', { params: undefined }),
    );
  });

  it('shows severity-specific empty message when filter is active and list is empty', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('No CVE exposures detected in your fleet.')).toBeInTheDocument(),
    );

    mockGet.mockResolvedValue(listResponse([]));
    fireEvent.click(screen.getByRole('button', { name: 'high' }));

    await waitFor(() =>
      expect(
        screen.getByText('No high CVE exposures in your fleet.'),
      ).toBeInTheDocument(),
    );
  });

  it('renders all four severity filter buttons', () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderTab();

    expect(screen.getByRole('button', { name: 'critical' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'high' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'medium' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'low' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'All' })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------
  it('fires an error notification when the API call rejects', async () => {
    mockGet.mockRejectedValue(new Error('Network error'));

    renderTab();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load CVE exposures',
      }),
    );
  });

  it('hides the loading indicator after an error', async () => {
    mockGet.mockRejectedValue(new Error('fail'));

    renderTab();

    await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
    expect(screen.queryByText('Loading…')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onActionsReady callback
  // ---------------------------------------------------------------------------
  it('calls onActionsReady with a refresh handle after mount', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(onActionsReady).toHaveBeenCalledWith(
        expect.objectContaining({ refresh: expect.any(Function) }),
      ),
    );
  });

  it('calls onActionsReady(null) on unmount', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    const onActionsReady = jest.fn();
    const { unmount } = renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    unmount();

    expect(onActionsReady).toHaveBeenCalledWith(null);
  });

  it('invokes a fresh API call when the refresh handle is used', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_MEDIUM]));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());
    const handle = onActionsReady.mock.calls[0][0] as { refresh: () => void };
    expect(handle).not.toBeNull();

    mockGet.mockResolvedValue(listResponse([CVE_CRITICAL]));
    handle.refresh();

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Wont-fix state label
  // ---------------------------------------------------------------------------
  it('renders "Won\'t fix" label for wont_fix state', async () => {
    const wontFix: SystemCveExposure = {
      ...CVE_MEDIUM,
      id: 'exp-wf',
      state: 'wont_fix',
    };
    mockGet.mockResolvedValue(listResponse([wontFix]));

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText("Won't fix").length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // Resolved state — resolved_at rendered
  // ---------------------------------------------------------------------------
  it('renders resolved timestamp in the row when resolved_at is present', async () => {
    mockGet.mockResolvedValue(listResponse([CVE_RESOLVED]));

    renderTab();

    await waitFor(() => expect(screen.getByText('CVE-2026-0003')).toBeInTheDocument());

    // "Resolved <timestamp>" text appears in the row summary line
    const resolvedMatch = screen.getByText(
      (content) => content.includes('Resolved') && content.includes('2026'),
    );
    expect(resolvedMatch).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Unknown CVE fallback
  // ---------------------------------------------------------------------------
  it('renders "Unknown CVE" when cve is null', async () => {
    const noCve: SystemCveExposure = {
      ...CVE_MEDIUM,
      id: 'exp-nocve',
      cve: null,
    };
    mockGet.mockResolvedValue(listResponse([noCve]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Unknown CVE')).toBeInTheDocument(),
    );
  });
});
