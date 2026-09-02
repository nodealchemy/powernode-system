import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import InstancePoolsPage from './InstancePoolsPage';

// =============================================================================
// Mocks
//
// The page calls `apiClient` directly for instance-pool CRUD and reaches
// `systemApi.getTemplates` for the create-modal dropdown. We stub both
// surfaces and the permission/notification hooks so the page renders
// without a real backend.
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

const mockGetTemplates = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getTemplates: (...args: unknown[]) => mockGetTemplates(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const POOL_A = {
  id: 'pool-a',
  name: 'web-warm',
  status: 'active' as const,
  lifecycle_class: 'ephemeral' as const,
  target_size: 3,
  min_size: 1,
  max_size: 5,
  ready_count: 2,
  warming_count: 1,
  claimed_count: 0,
  errored_count: 0,
  deficit: 0,
  last_replenished_at: '2026-05-07T10:00:00Z',
};

const POOL_B = {
  id: 'pool-b',
  name: 'spot-fleet',
  status: 'draining' as const,
  lifecycle_class: 'spot' as const,
  target_size: 0,
  min_size: 0,
  max_size: 10,
  ready_count: 0,
  warming_count: 0,
  claimed_count: 4,
  errored_count: 0,
  deficit: 0,
  last_replenished_at: null,
};

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function listResponse(pools: unknown[]) {
  return envelope({ pools, count: pools.length });
}

// =============================================================================
// Tests
// =============================================================================

const renderPage = () =>
  render(
    <BrowserRouter>
      <InstancePoolsPage />
    </BrowserRouter>,
  );

describe('InstancePoolsPage', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPatch.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockGetTemplates.mockReset();
    mockGetTemplates.mockResolvedValue({
      templates: [
        {
          id: 'tpl-1',
          name: 'ubuntu-base',
          enabled: true,
          public: true,
          config: {},
          created_at: '2026-01-01T00:00:00Z',
          updated_at: '2026-01-01T00:00:00Z',
        },
      ],
      meta: {
        current_page: 1,
        per_page: 200,
        total_count: 1,
        total_pages: 1,
        next_page: null,
        prev_page: null,
      },
    });
  });

  it('renders the list of pools fetched from the API', async () => {
    mockGet.mockResolvedValue(listResponse([POOL_A, POOL_B]));

    renderPage();

    // Row testids are rendered inside the desktop table once the items
    // resolve from the API — wait on those rather than text content (the
    // table lives in a `hidden md:block` wrapper that some matchers skip).
    await waitFor(
      () => expect(screen.getByTestId('pool-row-pool-a')).toBeInTheDocument(),
      { timeout: 3000 },
    );
    expect(screen.getByTestId('pool-row-pool-b')).toBeInTheDocument();
    expect(screen.getAllByText('web-warm').length).toBeGreaterThan(0);
    expect(screen.getAllByText('spot-fleet').length).toBeGreaterThan(0);

    expect(mockGet).toHaveBeenCalledWith('/system/instance_pools', { params: {} });
  });

  it('opens the Create Pool modal when the header action is clicked', async () => {
    mockGet.mockResolvedValueOnce(listResponse([]));

    renderPage();

    // Empty-state's Create Pool button — there's also a header button. Both
    // open the same modal; pick the first match (header) to avoid ambiguity.
    await waitFor(() => expect(screen.getAllByText('Create Pool').length).toBeGreaterThan(0));
    fireEvent.click(screen.getAllByText('Create Pool')[0]);

    await waitFor(() =>
      expect(screen.getByText('Create instance pool')).toBeInTheDocument(),
    );
    expect(screen.getByLabelText(/^name/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/node template/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/lifecycle class/i)).toBeInTheDocument();
  });

  it('triggers replenish via POST when the Replenish action is clicked', async () => {
    mockGet.mockResolvedValueOnce(listResponse([POOL_A]));
    mockPost.mockResolvedValueOnce(
      envelope({ pool: { ...POOL_A, ready_count: 3 } }),
    );

    renderPage();

    const row = await waitFor(() => screen.getByTestId('pool-row-pool-a'));
    fireEvent.click(within(row).getByLabelText(/replenish web-warm/i));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/instance_pools/pool-a/replenish',
      ),
    );
  });

  it('triggers drain via POST when the Drain action is clicked', async () => {
    mockGet.mockResolvedValueOnce(listResponse([POOL_A]));
    mockPost.mockResolvedValueOnce(
      envelope({ pool: { ...POOL_A, status: 'draining' } }),
    );

    renderPage();

    const row = await waitFor(() => screen.getByTestId('pool-row-pool-a'));
    fireEvent.click(within(row).getByLabelText(/drain web-warm/i));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/instance_pools/pool-a/drain',
      ),
    );
  });

  // IMP-24daa05e7a22 — a target_size/max_size raise and the archive
  // transition now gate, so this PATCH can answer 202 `{pending: true, ...}`
  // with NO `pool` key. The edit form always sends target_size, max_size AND
  // status, so both gated transitions are reachable from this one submit.
  // Before the fix `extractData(response).pool` returned undefined here and
  // the upsert threw, which the catch rendered as a red "Failed to update
  // pool" toast for an operation that had successfully parked an approval.
  describe('a gated PATCH parked for approval', () => {
    const PENDING = {
      pending: true,
      deferred_operation_id: 'dop-1',
      action_category: 'system.instance_pool_ceiling_raise',
      approval_request_id: 'ar-1',
      message: 'Awaiting approval',
    };

    const openEditAndSave = async () => {
      mockGet.mockResolvedValueOnce(listResponse([POOL_A]));
      renderPage();

      const row = await waitFor(() => screen.getByTestId('pool-row-pool-a'));
      fireEvent.click(within(row).getByLabelText(/edit web-warm/i));

      await waitFor(() =>
        expect(screen.getByText('Adjust sizing, status, and description')).toBeInTheDocument(),
      );
      fireEvent.click(screen.getByRole('button', { name: /save changes/i }));
    };

    it('surfaces an approval-required notice instead of a failure', async () => {
      mockPatch.mockResolvedValueOnce(envelope(PENDING));

      await openEditAndSave();

      await waitFor(() => expect(mockPatch).toHaveBeenCalled());
      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());

      const notice = mockAddNotification.mock.calls[0][0];
      expect(notice.type).toBe('info');
      expect(notice.message).toMatch(/approval required/i);
      expect(notice.details).toMatchObject({
        action: 'system.instance_pool_ceiling_raise',
        approval_request_id: 'ar-1',
        deferred_operation_id: 'dop-1',
      });
    });

    it('never reports the parked change as saved or failed', async () => {
      mockPatch.mockResolvedValueOnce(envelope(PENDING));

      await openEditAndSave();

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      const types = mockAddNotification.mock.calls.map((c) => c[0].type);
      expect(types).not.toContain('error');
      expect(types).not.toContain('success');
    });

    // Control: the ungated branch still returns the pool and toasts success.
    it('still upserts and toasts success on the inline 200', async () => {
      mockPatch.mockResolvedValueOnce(
        envelope({ pool: { ...POOL_A, target_size: 1 } }),
      );

      await openEditAndSave();

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      const notice = mockAddNotification.mock.calls[0][0];
      expect(notice.type).toBe('success');
      expect(notice.message).toMatch(/updated successfully/i);
    });
  });

  // IMP-067f39468350 — POST /instance_pools and DELETE /instance_pools/:id are
  // BOTH approval-gated (system.instance_pool_create / _delete), and have been
  // since IMP-24daa05e7a22 wired the REST gates. The client did not know:
  // `create` read `extractData(response).pool` off a 202 body that carries no
  // `pool`, so the caller upserted `undefined` and the catch rendered "Failed
  // to create pool" for an operation that had parked correctly; `destroy`
  // ignored the response entirely and removed the row from the list, telling
  // the operator a pool was archived while it still existed. Same defect the
  // gated PATCH above already fixed, on the two doors that were missed.
  describe('a gated create parked for approval', () => {
    const PENDING_CREATE = {
      pending: true,
      deferred_operation_id: 'dop-2',
      action_category: 'system.instance_pool_create',
      approval_request_id: 'ar-2',
      message: 'Awaiting approval',
    };

    const openCreateAndSubmit = async () => {
      mockGet.mockResolvedValueOnce(listResponse([]));
      renderPage();

      await waitFor(() =>
        expect(screen.getAllByText('Create Pool').length).toBeGreaterThan(0),
      );
      fireEvent.click(screen.getAllByText('Create Pool')[0]);
      await waitFor(() =>
        expect(screen.getByText('Create instance pool')).toBeInTheDocument(),
      );

      fireEvent.change(screen.getByLabelText(/^name/i), {
        target: { value: 'burst-pool' },
      });
      fireEvent.change(screen.getByLabelText(/node template/i), {
        target: { value: 'tpl-1' },
      });
      // Submit the modal's FORM rather than clicking by name: the footer
      // button, the header action and the empty-state action all read
      // "Create Pool", and a by-name click is ambiguous between them.
      const nameInput = screen.getByLabelText(/^name/i);
      fireEvent.submit(nameInput.closest('form') as HTMLFormElement);
    };

    it('surfaces an approval-required notice instead of a failure', async () => {
      mockPost.mockResolvedValueOnce(envelope(PENDING_CREATE));

      await openCreateAndSubmit();

      await waitFor(() => expect(mockPost).toHaveBeenCalled());
      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());

      const notice = mockAddNotification.mock.calls[0][0];
      expect(notice.type).toBe('info');
      expect(notice.message).toMatch(/approval required/i);
      expect(notice.details).toMatchObject({
        action: 'system.instance_pool_create',
        approval_request_id: 'ar-2',
        deferred_operation_id: 'dop-2',
      });
    });

    it('never reports the parked create as created or failed', async () => {
      mockPost.mockResolvedValueOnce(envelope(PENDING_CREATE));

      await openCreateAndSubmit();

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      const types = mockAddNotification.mock.calls.map((c) => c[0].type);
      expect(types).not.toContain('error');
      expect(types).not.toContain('success');
    });

    // Control: the ungated 201 still upserts the new pool and toasts success.
    it('still reports success on the inline 201', async () => {
      mockPost.mockResolvedValueOnce(
        envelope({ pool: { ...POOL_A, id: 'pool-new', name: 'burst-pool' } }),
      );

      await openCreateAndSubmit();

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      const notice = mockAddNotification.mock.calls[0][0];
      expect(notice.type).toBe('success');
      expect(notice.message).toMatch(/created successfully/i);
    });
  });

  describe('a gated delete parked for approval', () => {
    const PENDING_DELETE = {
      pending: true,
      deferred_operation_id: 'dop-3',
      action_category: 'system.instance_pool_delete',
      approval_request_id: 'ar-3',
      message: 'Awaiting approval',
    };

    const confirmDelete = async () => {
      mockGet.mockResolvedValueOnce(listResponse([POOL_A]));
      renderPage();

      const row = await waitFor(() => screen.getByTestId('pool-row-pool-a'));
      fireEvent.click(within(row).getByLabelText(/delete web-warm/i));
      await waitFor(() =>
        expect(screen.getByText('Archive instance pool')).toBeInTheDocument(),
      );
      fireEvent.click(screen.getByRole('button', { name: /archive pool/i }));
    };

    it('surfaces an approval-required notice and leaves the row in the list', async () => {
      mockDelete.mockResolvedValueOnce(envelope(PENDING_DELETE));

      await confirmDelete();

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());

      const notice = mockAddNotification.mock.calls[0][0];
      expect(notice.type).toBe('info');
      expect(notice.message).toMatch(/approval required/i);
      expect(notice.details).toMatchObject({
        action: 'system.instance_pool_delete',
        approval_request_id: 'ar-3',
        deferred_operation_id: 'dop-3',
      });

      // The ROW is the oracle: nothing was archived, so nothing may vanish
      // from the operator's list.
      expect(screen.getByTestId('pool-row-pool-a')).toBeInTheDocument();
    });

    it('never reports the parked delete as archived', async () => {
      mockDelete.mockResolvedValueOnce(envelope(PENDING_DELETE));

      await confirmDelete();

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      const types = mockAddNotification.mock.calls.map((c) => c[0].type);
      expect(types).not.toContain('success');
      expect(types).not.toContain('error');
    });
  });

  it('archives a pool via DELETE after confirmation', async () => {
    mockGet.mockResolvedValueOnce(listResponse([POOL_A]));
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    renderPage();

    const row = await waitFor(() => screen.getByTestId('pool-row-pool-a'));
    fireEvent.click(within(row).getByLabelText(/delete web-warm/i));

    // Confirmation modal opens — click "Archive Pool" to confirm.
    await waitFor(() => expect(screen.getByText('Archive instance pool')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /archive pool/i }));

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith('/system/instance_pools/pool-a'),
    );
  });
});
