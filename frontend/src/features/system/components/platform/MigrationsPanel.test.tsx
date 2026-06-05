import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { MigrationsPanel } from './MigrationsPanel';

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

// =============================================================================
// Fixtures & Helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const MIGRATION_A = {
  id: 'mig-aaaa-0001',
  operation: 'migrate' as const,
  status: 'completed' as const,
  root_resource_kind: 'NodeInstance',
  root_resource_id: '12345678-abcd-efgh-0000-000000000000',
  dry_run: false,
  destination_peer_id: 'peer-xyz',
  step_count: 5,
  total_steps: 5,
  created_at: '2026-05-01T10:00:00Z',
  started_at: '2026-05-01T10:01:00Z',
  completed_at: '2026-05-01T10:05:00Z',
  failed_at: null,
  cancelled_at: null,
  terminal: true,
  error_message: null,
};

const MIGRATION_B = {
  id: 'mig-bbbb-0002',
  operation: 'duplicate' as const,
  status: 'failed' as const,
  root_resource_kind: 'NodeTemplate',
  root_resource_id: null,
  dry_run: true,
  destination_peer_id: null,
  step_count: 2,
  total_steps: 7,
  created_at: '2026-05-02T08:30:00Z',
  started_at: null,
  completed_at: null,
  failed_at: '2026-05-02T08:31:00Z',
  cancelled_at: null,
  terminal: true,
  error_message: 'Connection refused',
};

const MIGRATION_DETAIL_A = {
  ...MIGRATION_A,
  plan_summary: { steps: [{ name: 'transfer_data' }], version: 1 },
  conflict_log: [{ kind: 'overlap', message: 'IP conflict detected' }],
  audit_log: [
    { at: '2026-05-01T10:01:00Z', event: 'started', message: 'Migration began' },
    { at: '2026-05-01T10:05:00Z', event: 'completed', message: 'Migration finished' },
  ],
  metadata: { initiated_by: 'operator' },
  initiated_by_user_id: 'user-001',
};

const MIGRATION_DETAIL_EMPTY_LOGS = {
  ...MIGRATION_A,
  id: 'mig-cccc-0003',
  plan_summary: {},
  conflict_log: [],
  audit_log: [],
  metadata: {},
  initiated_by_user_id: null,
};

function listResponse(migrations: unknown[]) {
  return envelope({ migrations, count: migrations.length });
}

const renderPanel = () =>
  render(
    <BrowserRouter>
      <MigrationsPanel />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('MigrationsPanel', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows loading indicator in the header while fetching', () => {
    mockGet.mockReturnValue(new Promise(() => {})); // never resolves

    renderPanel();

    expect(screen.getByText('loading…')).toBeInTheDocument();
  });

  it('refresh button is disabled while loading', () => {
    mockGet.mockReturnValue(new Promise(() => {}));

    renderPanel();

    const refreshBtn = screen.getByTitle('Refresh');
    expect(refreshBtn).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows empty-state message when no migrations are returned', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('No migrations recorded yet.')).toBeInTheDocument(),
    );
    expect(screen.getByText(/0 records/)).toBeInTheDocument();
  });

  it('does not render the table when there are no migrations', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('No migrations recorded yet.')).toBeInTheDocument(),
    );
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('displays an error banner when the API call fails', async () => {
    mockGet.mockRejectedValue(new Error('Network timeout'));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
  });

  it('uses fallback error message for non-Error rejections', async () => {
    mockGet.mockRejectedValue('server down');

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('Failed to load migrations')).toBeInTheDocument(),
    );
  });

  it('dismisses the error banner when X is clicked', async () => {
    mockGet.mockRejectedValue(new Error('Boom'));

    renderPanel();

    await waitFor(() => expect(screen.getByText('Boom')).toBeInTheDocument());

    // Click the dismiss button (X inside the error banner)
    const errorBanner = screen.getByText('Boom').closest('div');
    const dismissBtn = errorBanner!.parentElement!.querySelector('button');
    fireEvent.click(dismissBtn!);

    expect(screen.queryByText('Boom')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // API call
  // ---------------------------------------------------------------------------

  it('calls the migrations API at the correct URL on mount', async () => {
    mockGet.mockResolvedValue(listResponse([]));

    renderPanel();

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
    expect(mockGet).toHaveBeenCalledWith('/system/platform/migrations', { params: {} });
  });

  // ---------------------------------------------------------------------------
  // List rendering
  // ---------------------------------------------------------------------------

  it('renders a table row for each migration returned', async () => {
    mockGet.mockResolvedValue(listResponse([MIGRATION_A, MIGRATION_B]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    expect(screen.getByText('NodeTemplate')).toBeInTheDocument();
  });

  it('shows the singular "record" label when exactly one migration is returned', async () => {
    mockGet.mockResolvedValue(listResponse([MIGRATION_A]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('1 record')).toBeInTheDocument(),
    );
  });

  it('shows the plural "records" label for multiple migrations', async () => {
    mockGet.mockResolvedValue(listResponse([MIGRATION_A, MIGRATION_B]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('2 records')).toBeInTheDocument(),
    );
  });

  it('renders the operation badge with the correct label', async () => {
    mockGet.mockResolvedValue(listResponse([MIGRATION_A, MIGRATION_B]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('migrate')).toBeInTheDocument());
    expect(screen.getByText('duplicate')).toBeInTheDocument();
  });

  it('renders status pills for each migration', async () => {
    mockGet.mockResolvedValue(listResponse([MIGRATION_A, MIGRATION_B]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('completed')).toBeInTheDocument());
    expect(screen.getByText('failed')).toBeInTheDocument();
  });

  it('shows "dry-run" label for dry_run migrations', async () => {
    mockGet.mockResolvedValue(listResponse([MIGRATION_B]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('dry-run')).toBeInTheDocument());
  });

  it('shows "no" for migrations that are not dry-run', async () => {
    mockGet.mockResolvedValue(listResponse([MIGRATION_A]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('no')).toBeInTheDocument());
  });

  it('renders the step count as "step_count / total_steps"', async () => {
    mockGet.mockResolvedValue(listResponse([MIGRATION_A]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('5 / 5')).toBeInTheDocument());
  });

  it('truncates the root_resource_id to 8 chars followed by ellipsis', async () => {
    mockGet.mockResolvedValue(listResponse([MIGRATION_A]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('12345678…')).toBeInTheDocument(),
    );
  });

  it('does not render resource ID cell suffix when root_resource_id is null', async () => {
    mockGet.mockResolvedValue(listResponse([MIGRATION_B]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeTemplate')).toBeInTheDocument(),
    );
    // There should be no "…" truncation text when ID is null
    expect(screen.queryByText(/…/)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Refresh
  // ---------------------------------------------------------------------------

  it('re-fetches the list when refresh button is clicked', async () => {
    mockGet.mockResolvedValueOnce(listResponse([]));
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('No migrations recorded yet.')).toBeInTheDocument(),
    );

    const refreshBtn = screen.getByTitle('Refresh');
    fireEvent.click(refreshBtn);

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    expect(mockGet).toHaveBeenCalledTimes(2);
  });

  // ---------------------------------------------------------------------------
  // Detail drawer — open
  // ---------------------------------------------------------------------------

  it('opens the detail drawer when a table row is clicked', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(screen.getByText('Migration Detail')).toBeInTheDocument(),
    );
  });

  it('fetches migration detail at the correct URL when a row is clicked', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        `/system/platform/migrations/${MIGRATION_A.id}`,
      ),
    );
  });

  it('renders migration detail fields inside the drawer', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(screen.getByText('Migration Detail')).toBeInTheDocument(),
    );

    // KV labels are rendered with CSS uppercase class but actual DOM text
    // is the original case passed to the KV label prop.
    await waitFor(() =>
      expect(screen.getAllByText('Operation').length).toBeGreaterThan(0),
    );
    expect(screen.getAllByText('Status').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Resource Kind').length).toBeGreaterThan(0);
  });

  it('renders the conflict log entries in the drawer', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    // Collapsible title is "Conflicts" (CSS uppercase applied visually only)
    await waitFor(() =>
      expect(screen.getByText('Conflicts')).toBeInTheDocument(),
    );
  });

  it('renders the audit log entries in the drawer', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    // Collapsible title is "Audit Log" (CSS uppercase applied visually only)
    await waitFor(() =>
      expect(screen.getByText('Audit Log')).toBeInTheDocument(),
    );
    await waitFor(() =>
      expect(screen.getByText('Migration began')).toBeInTheDocument(),
    );
    expect(screen.getByText('Migration finished')).toBeInTheDocument();
  });

  it('shows "No conflicts recorded." when conflict_log is empty', async () => {
    // MIGRATION_DETAIL_EMPTY_LOGS has a different id (mig-cccc-0003) so
    // make it work: render a summary row with mig-cccc-0003 id and click it.
    const summaryC = { ...MIGRATION_A, id: 'mig-cccc-0003' };
    mockGet.mockResolvedValueOnce(listResponse([summaryC]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_EMPTY_LOGS }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(screen.getByText('No conflicts recorded.')).toBeInTheDocument(),
    );
  });

  it('shows "No audit entries." when audit_log is empty', async () => {
    const summaryC = { ...MIGRATION_A, id: 'mig-cccc-0003' };
    mockGet.mockResolvedValueOnce(listResponse([summaryC]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_EMPTY_LOGS }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(screen.getByText('No audit entries.')).toBeInTheDocument(),
    );
  });

  it('renders plan_summary as pretty-printed JSON in the drawer', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    // Collapsible title is "Plan Summary" (CSS uppercase applied visually only)
    await waitFor(() =>
      expect(screen.getByText('Plan Summary')).toBeInTheDocument(),
    );
    // The pre element should contain JSON-formatted plan content
    expect(screen.getByText(/transfer_data/)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Detail drawer — error state
  // ---------------------------------------------------------------------------

  it('shows loading indicator inside the drawer while detail is fetching', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockReturnValueOnce(new Promise(() => {})); // detail never resolves

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(screen.getByText('Migration Detail')).toBeInTheDocument(),
    );
    expect(screen.getByText('Loading…')).toBeInTheDocument();
  });

  it('shows an error banner in the drawer when detail fetch fails', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockRejectedValueOnce(new Error('Detail fetch failed'));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(screen.getByText('Detail fetch failed')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Detail drawer — error_message field
  // ---------------------------------------------------------------------------

  it('renders the error_message section when migration has an error', async () => {
    const failedDetail = {
      ...MIGRATION_DETAIL_A,
      status: 'failed' as const,
      error_message: 'Disk quota exceeded on peer-xyz',
    };

    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(envelope({ migration: failedDetail }));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(screen.getByText('Disk quota exceeded on peer-xyz')).toBeInTheDocument(),
    );
    expect(screen.getByText('Error')).toBeInTheDocument();
  });

  it('does not render the error section when error_message is null', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }), // error_message is null
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(screen.getByText('Migration Detail')).toBeInTheDocument(),
    );
    // Wait until Plan Summary section appears (drawer content loaded)
    await waitFor(() =>
      expect(screen.getByText('Plan Summary')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Error')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Detail drawer — close
  // ---------------------------------------------------------------------------

  it('closes the drawer when the X button is clicked', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(screen.getByText('Migration Detail')).toBeInTheDocument(),
    );

    // The X button is inside the drawer header — aria-label not present,
    // find by its position in the drawer header
    const drawerHeader = screen.getByText('Migration Detail').closest('header');
    const closeBtn = drawerHeader!.querySelector('button')!;
    fireEvent.click(closeBtn);

    await waitFor(() =>
      expect(screen.queryByText('Migration Detail')).not.toBeInTheDocument(),
    );
  });

  it('closes the drawer when the backdrop overlay is clicked', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    await waitFor(() =>
      expect(screen.getByText('Migration Detail')).toBeInTheDocument(),
    );

    // The backdrop div has aria-hidden="true" and is a sibling to the aside.
    // lucide SVGs also carry aria-hidden, so we narrow to div elements only.
    const backdrop = document.querySelector('div[aria-hidden="true"]');
    fireEvent.click(backdrop!);

    await waitFor(() =>
      expect(screen.queryByText('Migration Detail')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Collapsible — counts
  // ---------------------------------------------------------------------------

  it('displays the plan_summary key count in the Collapsible header', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    // Collapsible title uses CSS uppercase; DOM text is "Plan Summary"
    await waitFor(() =>
      expect(screen.getByText('Plan Summary')).toBeInTheDocument(),
    );
    // MIGRATION_DETAIL_A.plan_summary has 2 keys: 'steps' and 'version'
    const planSummarySection = screen.getByText('Plan Summary').closest('section');
    expect(planSummarySection).not.toBeNull();
    // count = Object.keys({ steps: [...], version: 1 }).length = 2
    expect(planSummarySection!.textContent).toContain('2');
  });

  it('displays the conflict_log length in the Conflicts Collapsible', async () => {
    mockGet.mockResolvedValueOnce(listResponse([MIGRATION_A]));
    mockGet.mockResolvedValueOnce(
      envelope({ migration: MIGRATION_DETAIL_A }),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('NodeInstance')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('NodeInstance'));

    // Collapsible title uses CSS uppercase; DOM text is "Conflicts"
    await waitFor(() =>
      expect(screen.getByText('Conflicts')).toBeInTheDocument(),
    );
    const conflictsSection = screen.getByText('Conflicts').closest('section');
    // MIGRATION_DETAIL_A.conflict_log.length = 1
    expect(conflictsSection!.textContent).toContain('1');
  });
});
