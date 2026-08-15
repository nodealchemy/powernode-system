import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { IpfixCollectorsTab } from './IpfixCollectorsTab';
import type { SdwanIpfixCollector } from '@system/features/system/types/sdwan.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPatch = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

let mockHasPermission = jest.fn(() => true);

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

// =============================================================================
// Fixtures
// =============================================================================

const COLLECTOR_A: SdwanIpfixCollector = {
  id: 'ipfix-a',
  name: 'primary-collector',
  host: '10.0.0.1',
  port: 4739,
  target_endpoint: '10.0.0.1:4739',
  sampling_rate: 100,
  state: 'active',
  is_winning_collector: true,
  created_at: '2026-01-15T10:00:00Z',
  updated_at: '2026-02-20T14:30:00Z',
};

const COLLECTOR_B: SdwanIpfixCollector = {
  id: 'ipfix-b',
  name: 'backup-collector',
  host: '10.0.0.2',
  port: 4739,
  target_endpoint: '10.0.0.2:4739',
  sampling_rate: 1000,
  state: 'disabled',
  is_winning_collector: false,
  created_at: '2026-02-01T08:00:00Z',
  updated_at: null,
};

// Build the double-envelope shape: AxiosResponse.data = { success, data: { ipfix_collectors: [...] } }
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function collectorsEnvelope(collectors: SdwanIpfixCollector[]) {
  return envelope({ ipfix_collectors: collectors });
}

function singleCollectorEnvelope(collector: SdwanIpfixCollector) {
  return envelope({ ipfix_collector: collector });
}

// =============================================================================
// Tests
// =============================================================================

const renderTab = () => render(<IpfixCollectorsTab />);

describe('IpfixCollectorsTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPatch.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while fetching', () => {
    // Never resolve — keep loading state
    mockGet.mockReturnValue(new Promise(() => {}));
    renderTab();
    expect(screen.getByText(/loading ipfix collectors/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows the error message when the API call rejects', async () => {
    mockGet.mockRejectedValueOnce(new Error('Network failure'));
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('Network failure')).toBeInTheDocument(),
    );
  });

  it('shows a generic error message for non-Error rejections', async () => {
    mockGet.mockRejectedValueOnce('something went wrong');
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('Failed to load IPFIX collectors')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows the empty-state panel when no collectors are returned', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([]));
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('No IPFIX collectors yet')).toBeInTheDocument(),
    );
    expect(screen.getByText(/register a collector via/i)).toBeInTheDocument();
    expect(screen.getByText('system_sdwan_create_ipfix_collector')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Render list
  // ---------------------------------------------------------------------------

  it('renders a row for each returned collector', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A, COLLECTOR_B]));
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('primary-collector')).toBeInTheDocument(),
    );
    expect(screen.getByText('backup-collector')).toBeInTheDocument();
  });

  it('calls the list endpoint with no params on mount', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([]));
    renderTab();
    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        '/system/sdwan/ipfix_collectors',
        { params: undefined },
      ),
    );
  });

  it('renders the target endpoint in monospace', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('10.0.0.1:4739')).toBeInTheDocument(),
    );
  });

  it('shows "1 in N" for sampling rate', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A, COLLECTOR_B]));
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('1 in 100')).toBeInTheDocument(),
    );
    expect(screen.getByText('1 in 1000')).toBeInTheDocument();
  });

  it('renders the state badge for each collector', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A, COLLECTOR_B]));
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('active')).toBeInTheDocument(),
    );
    expect(screen.getByText('disabled')).toBeInTheDocument();
  });

  it('shows "Winning" badge for the winning collector only', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A, COLLECTOR_B]));
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('Winning')).toBeInTheDocument(),
    );
    // Only one badge, for COLLECTOR_A
    expect(screen.getAllByText('Winning')).toHaveLength(1);
  });

  // ---------------------------------------------------------------------------
  // Toggle state (enable / disable)
  // ---------------------------------------------------------------------------

  it('disables an active collector via PATCH with state=disabled', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    mockPatch.mockResolvedValueOnce(
      singleCollectorEnvelope({ ...COLLECTOR_A, state: 'disabled' }),
    );
    // Second GET after refresh
    mockGet.mockResolvedValueOnce(collectorsEnvelope([{ ...COLLECTOR_A, state: 'disabled' }]));

    renderTab();
    const btn = await waitFor(() => screen.getByTestId('toggle-ipfix-ipfix-a'));
    fireEvent.click(btn);

    await waitFor(() =>
      expect(mockPatch).toHaveBeenCalledWith(
        '/system/sdwan/ipfix_collectors/ipfix-a',
        { ipfix_collector: { state: 'disabled' } },
      ),
    );
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success', message: expect.stringContaining('disabled') }),
    );
  });

  it('enables a disabled collector via PATCH with state=active', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_B]));
    mockPatch.mockResolvedValueOnce(
      singleCollectorEnvelope({ ...COLLECTOR_B, state: 'active' }),
    );
    mockGet.mockResolvedValueOnce(collectorsEnvelope([{ ...COLLECTOR_B, state: 'active' }]));

    renderTab();
    const btn = await waitFor(() => screen.getByTestId('toggle-ipfix-ipfix-b'));
    fireEvent.click(btn);

    await waitFor(() =>
      expect(mockPatch).toHaveBeenCalledWith(
        '/system/sdwan/ipfix_collectors/ipfix-b',
        { ipfix_collector: { state: 'active' } },
      ),
    );
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success', message: expect.stringContaining('enabled') }),
    );
  });

  it('shows an error notification when toggle PATCH fails', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    mockPatch.mockRejectedValueOnce(new Error('Patch failed'));

    renderTab();
    const btn = await waitFor(() => screen.getByTestId('toggle-ipfix-ipfix-a'));
    fireEvent.click(btn);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Patch failed' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Delete (armed confirm)
  // ---------------------------------------------------------------------------

  it('shows "Confirm?" text after the first click on the delete button', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    renderTab();
    const btn = await waitFor(() => screen.getByTestId('delete-ipfix-ipfix-a'));
    fireEvent.click(btn);
    await waitFor(() =>
      expect(screen.getByText('Confirm?')).toBeInTheDocument(),
    );
    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('deletes the collector via DELETE on the second click (confirm)', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    mockDelete.mockResolvedValueOnce({ data: { success: true } });
    mockGet.mockResolvedValueOnce(collectorsEnvelope([]));

    renderTab();
    const btn = await waitFor(() => screen.getByTestId('delete-ipfix-ipfix-a'));
    // First click: arm
    fireEvent.click(btn);
    await waitFor(() => expect(screen.getByText('Confirm?')).toBeInTheDocument());
    // Second click: confirm
    fireEvent.click(screen.getByTestId('delete-ipfix-ipfix-a'));

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/ipfix_collectors/ipfix-a'),
    );
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success', message: expect.stringContaining('deleted') }),
    );
  });

  it('shows an error notification when DELETE fails', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    mockDelete.mockRejectedValueOnce(new Error('Delete error'));

    renderTab();
    const btn = await waitFor(() => screen.getByTestId('delete-ipfix-ipfix-a'));
    fireEvent.click(btn);
    await waitFor(() => expect(screen.getByText('Confirm?')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('delete-ipfix-ipfix-a'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Delete error' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  it('expands a row and fetches detail on first expand', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    mockGet.mockResolvedValueOnce(singleCollectorEnvelope(COLLECTOR_A));

    renderTab();
    const expandBtn = await waitFor(() =>
      screen.getByTestId('expand-ipfix-ipfix-a'),
    );
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/sdwan/ipfix_collectors/ipfix-a'),
    );
  });

  it('renders detail fields inside expanded row', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    mockGet.mockResolvedValueOnce(singleCollectorEnvelope(COLLECTOR_A));

    renderTab();
    const expandBtn = await waitFor(() =>
      screen.getByTestId('expand-ipfix-ipfix-a'),
    );
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getByText('Collector ID')).toBeInTheDocument(),
    );
    // Detail section has the Name label
    expect(screen.getAllByText('primary-collector').length).toBeGreaterThan(0);
    // Host and port rendered
    expect(screen.getByText('10.0.0.1')).toBeInTheDocument();
    expect(screen.getByText('4739')).toBeInTheDocument();
    // Winning collector label in detail
    expect(screen.getAllByText('Winning').length).toBeGreaterThan(0);
  });

  it('does not fetch detail a second time if already loaded', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    // Detail fetch
    mockGet.mockResolvedValueOnce(singleCollectorEnvelope(COLLECTOR_A));

    renderTab();
    const expandBtn = await waitFor(() =>
      screen.getByTestId('expand-ipfix-ipfix-a'),
    );
    // Expand
    fireEvent.click(expandBtn);
    await waitFor(() => expect(screen.getByText('Collector ID')).toBeInTheDocument());

    // Collapse
    fireEvent.click(screen.getByTestId('expand-ipfix-ipfix-a'));
    await waitFor(() =>
      expect(screen.queryByText('Collector ID')).not.toBeInTheDocument(),
    );

    // Re-expand — should NOT call detail endpoint again
    const expandBtn2 = screen.getByTestId('expand-ipfix-ipfix-a');
    fireEvent.click(expandBtn2);
    await waitFor(() => expect(screen.getByText('Collector ID')).toBeInTheDocument());

    // mockGet was called: once for list, once for detail — not a third time
    expect(mockGet).toHaveBeenCalledTimes(2);
  });

  it('shows detail error message when detail fetch fails', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    mockGet.mockRejectedValueOnce(new Error('Detail load error'));

    renderTab();
    const expandBtn = await waitFor(() =>
      screen.getByTestId('expand-ipfix-ipfix-a'),
    );
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getByText(/detail unavailable/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/detail load error/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  it('hides action buttons when canManage is false', async () => {
    mockHasPermission.mockReturnValue(false);
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    renderTab();
    await waitFor(() =>
      expect(screen.getByText('primary-collector')).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('toggle-ipfix-ipfix-a')).not.toBeInTheDocument();
    expect(screen.queryByTestId('delete-ipfix-ipfix-a')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Table headers
  // ---------------------------------------------------------------------------

  it('renders the table with the expected column headers', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    renderTab();
    await waitFor(() => expect(screen.getByText('Name')).toBeInTheDocument());
    expect(screen.getByText('Target')).toBeInTheDocument();
    expect(screen.getByText('Sampling')).toBeInTheDocument();
    expect(screen.getByText('State')).toBeInTheDocument();
    expect(screen.getByText('Compiler picks')).toBeInTheDocument();
    expect(screen.getByText('Actions')).toBeInTheDocument();
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

  it('shows the pending-approval notification (not success) when the state toggle is parked', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    mockPatch.mockResolvedValueOnce(pendingEnvelope('sdwan.ipfix_collector_update'));

    renderTab();
    const btn = await waitFor(() => screen.getByTestId('toggle-ipfix-ipfix-a'));
    fireEvent.click(btn);

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

  it('shows the pending-approval notification (not success) when the delete is parked', async () => {
    mockGet.mockResolvedValueOnce(collectorsEnvelope([COLLECTOR_A]));
    mockDelete.mockResolvedValueOnce(pendingEnvelope('sdwan.ipfix_collector_delete'));

    renderTab();
    const btn = await waitFor(() => screen.getByTestId('delete-ipfix-ipfix-a'));
    fireEvent.click(btn);
    await waitFor(() => expect(screen.getByText('Confirm?')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('delete-ipfix-ipfix-a'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval required/i),
        }),
      ),
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' }),
    );
  });
});
