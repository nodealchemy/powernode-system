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
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
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
