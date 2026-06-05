import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { UnclaimedDevicesPanel } from './UnclaimedDevicesPanel';

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

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// useAuth returns account.id for the WS subscription
const mockCurrentUser = { account: { id: 'acct-1' } };
jest.mock('@/shared/hooks/useAuth', () => ({
  useAuth: () => ({ currentUser: mockCurrentUser }),
}));

// WebSocketManager — capture the subscribe callback so tests can fire WS events.
// The subscribe mock MUST return a function (the unsubscribe cleanup) — so we
// use jest.fn() inside the factory and re-configure its implementation in beforeEach.
jest.mock('@/shared/services/WebSocketManager', () => ({
  wsManager: {
    subscribe: jest.fn(() => () => undefined),
  },
}));

// systemApi — getNodes + getNodeInstances
const mockGetNodes = jest.fn();
const mockGetNodeInstances = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getNodes: (...args: unknown[]) => mockGetNodes(...args),
    getNodeInstances: (...args: unknown[]) => mockGetNodeInstances(...args),
  },
}));

// unclaimedDevicesApi
const mockApiList = jest.fn();
const mockApiClaim = jest.fn();
const mockApiDiscard = jest.fn();
jest.mock('@system/features/system/services/api/unclaimedDevicesApi', () => ({
  unclaimedDevicesApi: {
    list: (...args: unknown[]) => mockApiList(...args),
    claim: (...args: unknown[]) => mockApiClaim(...args),
    discard: (...args: unknown[]) => mockApiDiscard(...args),
  },
}));

// Import after mocks so we get the jest-controlled version.
// We need to cast it so TS doesn't complain about jest types.
import { wsManager } from '@/shared/services/WebSocketManager';

// =============================================================================
// Fixtures
// =============================================================================

const DEVICE_A = {
  id: 'dev-a',
  claim_code: 'ABCD-1234',
  discovered_mac: 'aa:bb:cc:dd:ee:ff',
  discovered_hostname: 'pi-rack-01',
  architecture: 'arm64',
  platform_hint: 'raspberry-pi',
  first_seen_at: '2026-06-01T10:00:00Z',
  last_seen_at: '2026-06-01T12:00:00Z',
  expires_at: '2026-06-02T10:00:00Z',
  claimed_at: undefined,
  claimed_node_instance_id: undefined,
};

const DEVICE_B = {
  id: 'dev-b',
  claim_code: 'WXYZ-5678',
  discovered_mac: '11:22:33:44:55:66',
  first_seen_at: '2026-06-01T11:00:00Z',
  last_seen_at: '2026-06-01T13:00:00Z',
  expires_at: '2026-06-02T11:00:00Z',
  claimed_at: undefined,
  claimed_node_instance_id: undefined,
};

const DEVICE_CLAIMED = {
  ...DEVICE_A,
  id: 'dev-claimed',
  discovered_mac: 'cc:dd:ee:ff:00:11',
  claimed_at: '2026-06-01T11:00:00Z',
};

const INSTANCE_1 = {
  id: 'inst-1',
  name: 'rack-pi-01',
  variety: 'physical' as const,
  status: 'pending',
  node_id: 'node-1',
  node_name: 'edge-rack',
  config: {},
  created_at: '2026-06-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
};

// Non-physical instance — should be excluded from picker
const INSTANCE_CLOUD = {
  id: 'inst-cloud',
  name: 'cloud-01',
  variety: 'cloud' as const,
  status: 'running',
  node_id: 'node-1',
  node_name: 'cloud-rack',
  config: {},
  created_at: '2026-06-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
};

const NODE_1 = {
  id: 'node-1',
  name: 'edge-rack',
  enabled: true,
  allocate_public_ip: false,
  config: {},
  created_at: '2026-06-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
};

function makeListResponse(devices: typeof DEVICE_A[]) {
  return {
    devices,
    meta: {
      current_page: 1,
      per_page: 50,
      total_count: devices.length,
      total_pages: 1,
      next_page: null,
      prev_page: null,
    },
  };
}

// =============================================================================
// Helpers
// =============================================================================

// Captured WS subscribe callback — set in beforeEach via mockImplementation.
let wsOnMessage: ((data: unknown) => void) | null = null;

const renderPanel = (props: React.ComponentProps<typeof UnclaimedDevicesPanel> = {}) =>
  render(
    <BrowserRouter>
      <UnclaimedDevicesPanel {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('UnclaimedDevicesPanel', () => {
  beforeEach(() => {
    wsOnMessage = null;
    // Re-implement subscribe each test so cleanup always gets a real function back
    (wsManager.subscribe as jest.Mock).mockImplementation(
      ({ onMessage }: { onMessage: (data: unknown) => void }) => {
        wsOnMessage = onMessage;
        return () => undefined;
      },
    );

    mockGet.mockReset();
    mockPost.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockGetNodes.mockReset();
    mockGetNodeInstances.mockReset();
    mockApiList.mockReset();
    mockApiClaim.mockReset();
    mockApiDiscard.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render / loading / empty states
  // ---------------------------------------------------------------------------

  it('shows the section header with title', async () => {
    mockApiList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    expect(screen.getByText('Unclaimed Devices')).toBeInTheDocument();
  });

  it('shows the empty state message when no unclaimed devices are returned', async () => {
    mockApiList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    await waitFor(() =>
      expect(
        screen.getByText(/No devices waiting to be claimed/),
      ).toBeInTheDocument(),
    );
  });

  it('renders device rows when devices are present', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A, DEVICE_B]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    expect(screen.getByText('11:22:33:44:55:66')).toBeInTheDocument();
  });

  it('shows device hostname when present', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('(pi-rack-01)')).toBeInTheDocument(),
    );
  });

  it('shows architecture badge when present', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('arm64')).toBeInTheDocument(),
    );
  });

  it('shows platform_hint badge when present', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('raspberry-pi')).toBeInTheDocument(),
    );
  });

  it('shows the device claim_code in each row', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('ABCD-1234')).toBeInTheDocument(),
    );
  });

  it('shows device count badge when devices are present', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A, DEVICE_B]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('2')).toBeInTheDocument(),
    );
  });

  it('filters out already-claimed devices from the list', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A, DEVICE_CLAIMED]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );

    // DEVICE_CLAIMED has claimed_at set — should be invisible
    expect(screen.queryByText('cc:dd:ee:ff:00:11')).not.toBeInTheDocument();
    // Badge shows only 1 device
    expect(screen.getByText('1')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // API call on mount
  // ---------------------------------------------------------------------------

  it('calls unclaimedDevicesApi.list on mount', async () => {
    mockApiList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    await waitFor(() =>
      expect(mockApiList).toHaveBeenCalledTimes(1),
    );
  });

  it('shows error notification when the list API fails', async () => {
    mockApiList.mockRejectedValue(new Error('Network error'));

    renderPanel();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load unclaimed devices',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Refresh button
  // ---------------------------------------------------------------------------

  it('re-fetches devices when the Refresh button is clicked', async () => {
    mockApiList
      .mockResolvedValueOnce(makeListResponse([]))
      .mockResolvedValueOnce(makeListResponse([DEVICE_A]));

    renderPanel();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    const refreshBtn = screen.getByTitle('Refresh');
    fireEvent.click(refreshBtn);

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(2));
    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // WebSocket live-update subscription
  // ---------------------------------------------------------------------------

  it('subscribes to SystemFleetChannel on mount with the account_id', async () => {
    mockApiList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    await waitFor(() =>
      expect(wsManager.subscribe).toHaveBeenCalledWith(
        expect.objectContaining({
          channel: 'SystemFleetChannel',
          params: { account_id: 'acct-1' },
        }),
      ),
    );
  });

  it('refreshes the list when system.physical_device_discovered WS event arrives', async () => {
    mockApiList
      .mockResolvedValueOnce(makeListResponse([]))
      .mockResolvedValueOnce(makeListResponse([DEVICE_A]));

    renderPanel();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    // Fire the WS event via the captured callback
    expect(wsOnMessage).not.toBeNull();
    wsOnMessage!({ kind: 'system.physical_device_discovered' });

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(2));
    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
  });

  it('refreshes the list when system.physical_device_claimed WS event arrives', async () => {
    mockApiList
      .mockResolvedValueOnce(makeListResponse([DEVICE_A]))
      .mockResolvedValueOnce(makeListResponse([]));

    renderPanel();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    wsOnMessage!({ kind: 'system.physical_device_claimed' });

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(2));
  });

  it('does NOT refresh on unrelated WS events', async () => {
    mockApiList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(1));

    wsOnMessage!({ kind: 'system.node_heartbeat' });

    // Give time for any spurious call
    await new Promise((r) => setTimeout(r, 50));
    expect(mockApiList).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Claim flow — modal open and instance picker
  // ---------------------------------------------------------------------------

  it('opens the claim modal when Claim button is clicked', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(screen.getByText('Claim device')).toBeInTheDocument(),
    );
    expect(screen.getByText(/Bind device/)).toBeInTheDocument();
  });

  it('fetches all nodes then instances when opening the claim modal (no scopedToNode)', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(mockGetNodes).toHaveBeenCalledTimes(1),
    );
    expect(mockGetNodeInstances).toHaveBeenCalledWith('node-1');
  });

  it('uses scopedToNode directly without fetching all nodes', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });

    renderPanel({ scopedToNode: NODE_1 });

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(mockGetNodeInstances).toHaveBeenCalledWith('node-1'),
    );
    expect(mockGetNodes).not.toHaveBeenCalled();
  });

  it('shows only physical instances in the picker (excludes cloud variety)', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({
      node_instances: [INSTANCE_1, INSTANCE_CLOUD],
    });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(screen.getByText('Claim device')).toBeInTheDocument(),
    );

    // rack-pi-01 should be in the picker (physical)
    await waitFor(() =>
      expect(screen.getByText('rack-pi-01 (edge-rack)')).toBeInTheDocument(),
    );
    // cloud-01 should NOT be in the picker
    expect(screen.queryByText(/cloud-01/)).not.toBeInTheDocument();
  });

  it('shows warning when no claimable instances are available', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [] });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(
        screen.getByText(/No claimable instances/),
      ).toBeInTheDocument(),
    );
  });

  it('shows error notification when instance loading fails', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockGetNodes.mockRejectedValue(new Error('Nodes fetch failed'));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load claimable instances',
      }),
    );
  });

  it('disables Confirm claim button until an instance is selected', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(screen.getByText('Claim device')).toBeInTheDocument(),
    );

    const confirmBtn = screen.getByRole('button', { name: /confirm claim/i });
    expect(confirmBtn).toBeDisabled();
  });

  it('enables Confirm claim button after selecting an instance', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(screen.getByText('rack-pi-01 (edge-rack)')).toBeInTheDocument(),
    );

    const select = screen.getByRole('combobox');
    fireEvent.change(select, { target: { value: 'inst-1' } });

    const confirmBtn = screen.getByRole('button', { name: /confirm claim/i });
    expect(confirmBtn).not.toBeDisabled();
  });

  it('closes modal when Cancel is clicked', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(screen.getByText('Claim device')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText('Claim device')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Claim submission
  // ---------------------------------------------------------------------------

  it('calls unclaimedDevicesApi.claim with correct deviceId and nodeInstanceId', async () => {
    mockApiList
      .mockResolvedValueOnce(makeListResponse([DEVICE_A]))
      .mockResolvedValueOnce(makeListResponse([]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });
    mockApiClaim.mockResolvedValue({
      unclaimed_device: DEVICE_A,
      node_instance_id: 'inst-1',
      node_instance_name: 'rack-pi-01',
    });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(screen.getByText('rack-pi-01 (edge-rack)')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'inst-1' } });
    fireEvent.click(screen.getByRole('button', { name: /confirm claim/i }));

    await waitFor(() =>
      expect(mockApiClaim).toHaveBeenCalledWith('dev-a', 'inst-1'),
    );
  });

  it('shows success notification after a successful claim', async () => {
    mockApiList
      .mockResolvedValueOnce(makeListResponse([DEVICE_A]))
      .mockResolvedValueOnce(makeListResponse([]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });
    mockApiClaim.mockResolvedValue({
      unclaimed_device: DEVICE_A,
      node_instance_id: 'inst-1',
      node_instance_name: 'rack-pi-01',
    });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(screen.getByText('rack-pi-01 (edge-rack)')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'inst-1' } });
    fireEvent.click(screen.getByRole('button', { name: /confirm claim/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Claimed device for rack-pi-01. Device will enroll on next poll.',
      }),
    );
  });

  it('calls onClaimed callback after a successful claim', async () => {
    const onClaimed = jest.fn();
    mockApiList
      .mockResolvedValueOnce(makeListResponse([DEVICE_A]))
      .mockResolvedValueOnce(makeListResponse([]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });
    mockApiClaim.mockResolvedValue({
      unclaimed_device: DEVICE_A,
      node_instance_id: 'inst-1',
      node_instance_name: 'rack-pi-01',
    });

    renderPanel({ onClaimed });

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(screen.getByText('rack-pi-01 (edge-rack)')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'inst-1' } });
    fireEvent.click(screen.getByRole('button', { name: /confirm claim/i }));

    await waitFor(() =>
      expect(onClaimed).toHaveBeenCalledWith('dev-a', 'inst-1'),
    );
  });

  it('closes the modal after a successful claim', async () => {
    mockApiList
      .mockResolvedValueOnce(makeListResponse([DEVICE_A]))
      .mockResolvedValueOnce(makeListResponse([]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });
    mockApiClaim.mockResolvedValue({
      unclaimed_device: DEVICE_A,
      node_instance_id: 'inst-1',
      node_instance_name: 'rack-pi-01',
    });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(screen.getByText('rack-pi-01 (edge-rack)')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'inst-1' } });
    fireEvent.click(screen.getByRole('button', { name: /confirm claim/i }));

    await waitFor(() =>
      expect(screen.queryByText('Claim device')).not.toBeInTheDocument(),
    );
  });

  it('shows error notification when claim API fails', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockGetNodes.mockResolvedValue({ nodes: [NODE_1] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_1] });
    mockApiClaim.mockRejectedValue(new Error('Token issuance failed'));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /claim/i }));

    await waitFor(() =>
      expect(screen.getByText('rack-pi-01 (edge-rack)')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'inst-1' } });
    fireEvent.click(screen.getByRole('button', { name: /confirm claim/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Token issuance failed',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Discard flow
  // ---------------------------------------------------------------------------

  it('calls unclaimedDevicesApi.discard with the device id when Discard is clicked', async () => {
    mockApiList
      .mockResolvedValueOnce(makeListResponse([DEVICE_A]))
      .mockResolvedValueOnce(makeListResponse([]));
    mockApiDiscard.mockResolvedValue(undefined);

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Discard this device'));

    await waitFor(() =>
      expect(mockApiDiscard).toHaveBeenCalledWith('dev-a'),
    );
  });

  it('refreshes list after successful discard', async () => {
    mockApiList
      .mockResolvedValueOnce(makeListResponse([DEVICE_A]))
      .mockResolvedValueOnce(makeListResponse([]));
    mockApiDiscard.mockResolvedValue(undefined);

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTitle('Discard this device'));

    await waitFor(() => expect(mockApiList).toHaveBeenCalledTimes(2));
  });

  it('shows error notification when discard API fails', async () => {
    mockApiList.mockResolvedValue(makeListResponse([DEVICE_A]));
    mockApiDiscard.mockRejectedValue(new Error('Device locked'));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTitle('Discard this device'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Device locked',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Multiple devices — correct device targeted
  // ---------------------------------------------------------------------------

  it('discards only the targeted device when multiple devices are listed', async () => {
    mockApiList
      .mockResolvedValueOnce(makeListResponse([DEVICE_A, DEVICE_B]))
      .mockResolvedValueOnce(makeListResponse([DEVICE_B]));
    mockApiDiscard.mockResolvedValue(undefined);

    renderPanel();

    await waitFor(() => {
      expect(screen.getByText('aa:bb:cc:dd:ee:ff')).toBeInTheDocument();
      expect(screen.getByText('11:22:33:44:55:66')).toBeInTheDocument();
    });

    // Click the first device's discard button
    const discardBtns = screen.getAllByTitle('Discard this device');
    fireEvent.click(discardBtns[0]);

    await waitFor(() =>
      expect(mockApiDiscard).toHaveBeenCalledWith('dev-a'),
    );
  });
});
