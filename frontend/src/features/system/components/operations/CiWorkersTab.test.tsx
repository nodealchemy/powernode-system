import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { CiWorkersTab } from './CiWorkersTab';
import type { SystemCiWorker, SystemCiWorkerCreatedResponse } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
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

const mockHasPermission = jest.fn(() => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (...args: unknown[]) => mockHasPermission(...args),
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// ciWorkersApi resolves directly — not through apiClient shapes — so we mock
// the entire module and control return values per test.
const mockCiWorkersApiList = jest.fn();
const mockCiWorkersApiCreate = jest.fn();
const mockCiWorkersApiDestroy = jest.fn();
const mockCiWorkersApiRotateToken = jest.fn();

jest.mock('@system/features/system/services/api/ciWorkersApi', () => ({
  ciWorkersApi: {
    list: (...args: unknown[]) => mockCiWorkersApiList(...args),
    get: jest.fn(),
    create: (...args: unknown[]) => mockCiWorkersApiCreate(...args),
    destroy: (...args: unknown[]) => mockCiWorkersApiDestroy(...args),
    rotateToken: (...args: unknown[]) => mockCiWorkersApiRotateToken(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const WORKER_A: SystemCiWorker = {
  id: 'wkr-aaa',
  account_id: 'acct-001',
  name: 'release-pipeline-runner',
  description: 'Main release CI worker',
  status: 'active',
  last_seen_at: '2026-05-01T12:00:00Z',
  roles: ['ci_worker'],
  created_at: '2026-04-01T00:00:00Z',
  updated_at: '2026-05-01T12:00:00Z',
};

const WORKER_B: SystemCiWorker = {
  id: 'wkr-bbb',
  account_id: 'acct-001',
  name: 'staging-runner',
  status: 'inactive',
  roles: [],
  created_at: '2026-03-01T00:00:00Z',
  updated_at: '2026-03-01T00:00:00Z',
};

const CREATED_RESPONSE: SystemCiWorkerCreatedResponse = {
  ci_worker: WORKER_A,
  token_plaintext: 'pnci_super_secret_abc123',
  note: 'Store this token as POWERNODE_CI_WORKER_TOKEN in your CI secret manager.',
};

// =============================================================================
// Helpers
// =============================================================================

const renderTab = (props: Partial<React.ComponentProps<typeof CiWorkersTab>> = {}) =>
  render(<CiWorkersTab {...props} />);

// =============================================================================
// Tests
// =============================================================================

describe('CiWorkersTab', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    // Default: all permissions granted
    mockHasPermission.mockReturnValue(true);
    // Default: return an empty list
    mockCiWorkersApiList.mockResolvedValue([]);
    // Suppress window.confirm — tests that need it override per-test
    jest.spyOn(window, 'confirm').mockReturnValue(true);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows loading indicator while fetching workers', async () => {
    let resolve!: (value: SystemCiWorker[]) => void;
    mockCiWorkersApiList.mockReturnValue(new Promise<SystemCiWorker[]>(r => { resolve = r; }));

    renderTab();

    expect(screen.getByText(/loading…/i)).toBeInTheDocument();

    // Resolve so teardown doesn't leak act() warnings
    await act(async () => { resolve([]); });
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows empty-state message when no workers exist', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/no ci workers yet/i)).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Populated list
  // ---------------------------------------------------------------------------

  it('renders worker list after successful fetch', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A, WORKER_B]);

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument(),
    );
    expect(screen.getByText('staging-runner')).toBeInTheDocument();
  });

  it('calls ciWorkersApi.list() on mount', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);

    renderTab();

    await waitFor(() => expect(mockCiWorkersApiList).toHaveBeenCalledTimes(1));
  });

  it('displays worker count badge when workers are present', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A, WORKER_B]);

    renderTab();

    await waitFor(() => expect(screen.getByText('2')).toBeInTheDocument());
  });

  it('shows active badge for active workers and secondary badge for non-active', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A, WORKER_B]);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    // WORKER_A status: active, WORKER_B status: inactive
    const badges = screen.getAllByText(/active|inactive/i);
    const statuses = badges.map(b => b.textContent);
    expect(statuses).toContain('active');
    expect(statuses).toContain('inactive');
  });

  it('shows last seen time when last_seen_at is set', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());
    // Some form of the date appears
    expect(screen.getByText(/last seen/i)).toBeInTheDocument();
  });

  it('shows "Never seen" when last_seen_at is absent', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_B]);

    renderTab();

    await waitFor(() => expect(screen.getByText('staging-runner')).toBeInTheDocument());
    expect(screen.getByText(/never seen/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows error notification when fetch fails', async () => {
    mockCiWorkersApiList.mockRejectedValue(new Error('Network error'));

    renderTab();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load CI workers',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  it('expands a worker row on chevron click to show detail fields', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    // Description section should not be visible yet
    expect(screen.queryByText(/main release ci worker/i)).not.toBeInTheDocument();

    // Click the expand button (title="Expand details")
    const expandBtn = screen.getByTitle('Expand details');
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getByText('Main release CI worker')).toBeInTheDocument(),
    );
    // Detail fields appear
    expect(screen.getByText('Worker ID')).toBeInTheDocument();
    expect(screen.getByText('Created')).toBeInTheDocument();
    expect(screen.getByText('Updated')).toBeInTheDocument();
  });

  it('collapses an expanded row on second chevron click', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    const expandBtn = screen.getByTitle('Expand details');
    fireEvent.click(expandBtn);

    await waitFor(() => expect(screen.getByText('Worker ID')).toBeInTheDocument());

    // Should now show collapse title
    const collapseBtn = screen.getByTitle('Collapse details');
    fireEvent.click(collapseBtn);

    await waitFor(() =>
      expect(screen.queryByText('Worker ID')).not.toBeInTheDocument(),
    );
  });

  it('shows roles in expanded view when roles are present', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() => expect(screen.getByText('Roles')).toBeInTheDocument());
    expect(screen.getByText('ci_worker')).toBeInTheDocument();
  });

  it('does not show roles section in expanded view when roles are empty', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_B]);

    renderTab();

    await waitFor(() => expect(screen.getByText('staging-runner')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() => expect(screen.getByText('Worker ID')).toBeInTheDocument());
    expect(screen.queryByText('Roles')).not.toBeInTheDocument();
  });

  it('does not show description field in expanded view when description is absent', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_B]);

    renderTab();

    await waitFor(() => expect(screen.getByText('staging-runner')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() => expect(screen.getByText('Worker ID')).toBeInTheDocument());
    expect(screen.queryByText('Description')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onActionsReady callback
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with an openCreate handle on mount', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    const onActionsReady = jest.fn();

    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(onActionsReady).toHaveBeenCalledWith(
        expect.objectContaining({ openCreate: expect.any(Function) }),
      ),
    );
  });

  it('calls onActionsReady(null) on unmount', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    const onActionsReady = jest.fn();

    const { unmount } = renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalledTimes(1));

    unmount();

    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  it('opens the create modal via the openCreate handle from onActionsReady', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    const onActionsReady = jest.fn();

    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    const handle = onActionsReady.mock.calls[0][0] as { openCreate: () => void };
    act(() => { handle.openCreate(); });

    await waitFor(() =>
      expect(screen.getByText('New CI worker')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Create modal
  // ---------------------------------------------------------------------------

  it('opens the create modal and renders name input', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    const onActionsReady = jest.fn();

    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    const handle = onActionsReady.mock.calls[0][0] as { openCreate: () => void };
    act(() => { handle.openCreate(); });

    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());
    expect(screen.getByLabelText('Name')).toBeInTheDocument();
  });

  it('disables the Create button when the name field is empty', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    const onActionsReady = jest.fn();

    renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    act(() => { (onActionsReady.mock.calls[0][0] as { openCreate: () => void }).openCreate(); });
    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());

    const createBtn = screen.getByRole('button', { name: /create ci worker/i });
    expect(createBtn).toBeDisabled();
  });

  it('enables the Create button once a name is typed', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    const onActionsReady = jest.fn();

    renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    act(() => { (onActionsReady.mock.calls[0][0] as { openCreate: () => void }).openCreate(); });
    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'my-runner' } });

    const createBtn = screen.getByRole('button', { name: /create ci worker/i });
    expect(createBtn).not.toBeDisabled();
  });

  it('calls ciWorkersApi.create() with trimmed name on submit', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    mockCiWorkersApiCreate.mockResolvedValue(CREATED_RESPONSE);
    // Subsequent list refresh
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    act(() => { (onActionsReady.mock.calls[0][0] as { openCreate: () => void }).openCreate(); });
    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText('Name'), { target: { value: '  my-runner  ' } });
    fireEvent.click(screen.getByRole('button', { name: /create ci worker/i }));

    await waitFor(() =>
      expect(mockCiWorkersApiCreate).toHaveBeenCalledWith('my-runner'),
    );
  });

  it('closes the create modal and opens the token modal on successful create', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    mockCiWorkersApiCreate.mockResolvedValue(CREATED_RESPONSE);
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    act(() => { (onActionsReady.mock.calls[0][0] as { openCreate: () => void }).openCreate(); });
    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'my-runner' } });
    fireEvent.click(screen.getByRole('button', { name: /create ci worker/i }));

    // Token-shown-once modal appears
    await waitFor(() =>
      expect(screen.getByText(/this token is shown once/i)).toBeInTheDocument(),
    );
    // Create modal is gone
    expect(screen.queryByText('New CI worker')).not.toBeInTheDocument();
  });

  it('shows error notification when create fails', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    mockCiWorkersApiCreate.mockRejectedValue(new Error('Name already taken'));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    act(() => { (onActionsReady.mock.calls[0][0] as { openCreate: () => void }).openCreate(); });
    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'my-runner' } });
    fireEvent.click(screen.getByRole('button', { name: /create ci worker/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Name already taken',
      }),
    );
  });

  it('closes the create modal without calling create when Cancel is clicked', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    act(() => { (onActionsReady.mock.calls[0][0] as { openCreate: () => void }).openCreate(); });
    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText('New CI worker')).not.toBeInTheDocument(),
    );
    expect(mockCiWorkersApiCreate).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Token shown-once modal
  // ---------------------------------------------------------------------------

  it('displays the token plaintext and note in the token modal', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    mockCiWorkersApiCreate.mockResolvedValue(CREATED_RESPONSE);
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    act(() => { (onActionsReady.mock.calls[0][0] as { openCreate: () => void }).openCreate(); });
    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'my-runner' } });
    fireEvent.click(screen.getByRole('button', { name: /create ci worker/i }));

    await waitFor(() =>
      expect(screen.getByText('pnci_super_secret_abc123')).toBeInTheDocument(),
    );
    expect(screen.getByText(CREATED_RESPONSE.note)).toBeInTheDocument();
  });

  it('disables Done button until the acknowledgement checkbox is checked', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    mockCiWorkersApiCreate.mockResolvedValue(CREATED_RESPONSE);

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    act(() => { (onActionsReady.mock.calls[0][0] as { openCreate: () => void }).openCreate(); });
    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'my-runner' } });
    fireEvent.click(screen.getByRole('button', { name: /create ci worker/i }));

    await waitFor(() =>
      expect(screen.getByText(/this token is shown once/i)).toBeInTheDocument(),
    );

    const doneBtn = screen.getByRole('button', { name: /done/i });
    expect(doneBtn).toBeDisabled();

    // Check the acknowledgement checkbox
    fireEvent.click(screen.getByRole('checkbox'));

    expect(doneBtn).not.toBeDisabled();
  });

  it('closes the token modal when Done is clicked after acknowledging', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    mockCiWorkersApiCreate.mockResolvedValue(CREATED_RESPONSE);

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    act(() => { (onActionsReady.mock.calls[0][0] as { openCreate: () => void }).openCreate(); });
    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'my-runner' } });
    fireEvent.click(screen.getByRole('button', { name: /create ci worker/i }));

    await waitFor(() =>
      expect(screen.getByText(/this token is shown once/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('checkbox'));
    fireEvent.click(screen.getByRole('button', { name: /done/i }));

    await waitFor(() =>
      expect(screen.queryByText(/this token is shown once/i)).not.toBeInTheDocument(),
    );
  });

  it('copies token to clipboard when copy button is clicked', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);
    mockCiWorkersApiCreate.mockResolvedValue(CREATED_RESPONSE);

    const writeText = jest.fn().mockResolvedValue(undefined);
    Object.assign(navigator, { clipboard: { writeText } });

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });
    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    act(() => { (onActionsReady.mock.calls[0][0] as { openCreate: () => void }).openCreate(); });
    await waitFor(() => expect(screen.getByText('New CI worker')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'my-runner' } });
    fireEvent.click(screen.getByRole('button', { name: /create ci worker/i }));

    await waitFor(() =>
      expect(screen.getByText('pnci_super_secret_abc123')).toBeInTheDocument(),
    );

    // The copy button has no text label — it's an icon-only button next to the
    // token code block. Find all buttons in the token modal and click the one
    // that isn't "Done" (which has text).
    const allBtns = screen.getAllByRole('button');
    const copyBtn = allBtns.find(b => !b.textContent?.match(/done/i) && b.closest('.fixed'));
    expect(copyBtn).toBeDefined();
    fireEvent.click(copyBtn!);

    expect(writeText).toHaveBeenCalledWith('pnci_super_secret_abc123');
  });

  // ---------------------------------------------------------------------------
  // Revoke (delete)
  // ---------------------------------------------------------------------------

  it('calls ciWorkersApi.destroy() and refreshes after confirmed revoke', async () => {
    mockCiWorkersApiList.mockResolvedValueOnce([WORKER_A]);
    mockCiWorkersApiDestroy.mockResolvedValue(undefined);
    mockCiWorkersApiList.mockResolvedValue([]);

    jest.spyOn(window, 'confirm').mockReturnValue(true);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    const revokeBtn = screen.getByTitle('Revoke worker');
    fireEvent.click(revokeBtn);

    await waitFor(() =>
      expect(mockCiWorkersApiDestroy).toHaveBeenCalledWith('wkr-aaa'),
    );
    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'success',
      message: `CI worker "release-pipeline-runner" revoked`,
    });
  });

  it('does NOT call ciWorkersApi.destroy() when revoke is cancelled', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    jest.spyOn(window, 'confirm').mockReturnValue(false);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Revoke worker'));

    // Give async handler time to run
    await new Promise(r => setTimeout(r, 50));
    expect(mockCiWorkersApiDestroy).not.toHaveBeenCalled();
  });

  it('shows correct confirm message when revoking', async () => {
    mockCiWorkersApiList.mockResolvedValueOnce([WORKER_A]).mockResolvedValue([]);
    mockCiWorkersApiDestroy.mockResolvedValue(undefined);

    const confirmSpy = jest.spyOn(window, 'confirm').mockReturnValue(true);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Revoke worker'));

    await waitFor(() => expect(confirmSpy).toHaveBeenCalled());
    expect(confirmSpy.mock.calls[0][0]).toContain('release-pipeline-runner');
    expect(confirmSpy.mock.calls[0][0]).toContain('CI runs using this token will start failing');
  });

  it('shows error notification when revoke fails', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);
    mockCiWorkersApiDestroy.mockRejectedValue(new Error('Not found'));

    jest.spyOn(window, 'confirm').mockReturnValue(true);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Revoke worker'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Not found',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Rotate token
  // ---------------------------------------------------------------------------

  it('calls ciWorkersApi.rotateToken() and shows token modal after confirmed rotate', async () => {
    mockCiWorkersApiList.mockResolvedValueOnce([WORKER_A]);
    mockCiWorkersApiRotateToken.mockResolvedValue(CREATED_RESPONSE);
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    jest.spyOn(window, 'confirm').mockReturnValue(true);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    const rotateBtn = screen.getByTitle('Rotate token');
    fireEvent.click(rotateBtn);

    await waitFor(() =>
      expect(mockCiWorkersApiRotateToken).toHaveBeenCalledWith('wkr-aaa'),
    );
    // Token modal appears with the new plaintext
    await waitFor(() =>
      expect(screen.getByText('pnci_super_secret_abc123')).toBeInTheDocument(),
    );
  });

  it('does NOT call ciWorkersApi.rotateToken() when rotate is cancelled', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    jest.spyOn(window, 'confirm').mockReturnValue(false);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Rotate token'));

    await new Promise(r => setTimeout(r, 50));
    expect(mockCiWorkersApiRotateToken).not.toHaveBeenCalled();
  });

  it('shows correct confirm message when rotating', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);
    mockCiWorkersApiRotateToken.mockResolvedValue(CREATED_RESPONSE);
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    const confirmSpy = jest.spyOn(window, 'confirm').mockReturnValue(true);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Rotate token'));

    await waitFor(() => expect(confirmSpy).toHaveBeenCalled());
    expect(confirmSpy.mock.calls[0][0]).toContain('release-pipeline-runner');
    expect(confirmSpy.mock.calls[0][0]).toContain('Old token is revoked immediately');
  });

  it('shows error notification when rotate fails', async () => {
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);
    mockCiWorkersApiRotateToken.mockRejectedValue(new Error('Rotation failed'));

    jest.spyOn(window, 'confirm').mockReturnValue(true);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Rotate token'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Rotation failed',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  it('hides rotate and revoke buttons when permissions are absent', async () => {
    // Override: deny both ci_workers permissions
    mockHasPermission.mockReturnValue(false);
    mockCiWorkersApiList.mockResolvedValue([WORKER_A]);

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline-runner')).toBeInTheDocument());

    expect(screen.queryByTitle('Rotate token')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Revoke worker')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Static description text
  // ---------------------------------------------------------------------------

  it('renders the description blurb with the permission scope note', async () => {
    mockCiWorkersApiList.mockResolvedValue([]);

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/per-pipeline ci worker tokens/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/leaked token can register disk images/i)).toBeInTheDocument();
  });
});
