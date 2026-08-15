import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { HostBridgesTab } from './HostBridgesTab';
import type { SdwanHostBridge } from '@system/features/system/types/sdwan.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
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

// =============================================================================
// Helpers
// =============================================================================

/** Wrap the API double-envelope: AxiosResponse body = { success, data: payload } */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const BRIDGE_ACTIVE: SdwanHostBridge = {
  id: 'hb-001',
  node_instance_id: 'ni-abc',
  node_instance_name: 'node-alpha',
  network_profile: 'heavyweight',
  short_id: 1,
  bridge_name: 'ovs-br-001',
  kind: 'ovs',
  state: 'active',
  applied_at: '2026-01-10T08:00:00Z',
  draining_at: null,
  removed_at: null,
  created_at: '2026-01-09T12:00:00Z',
  updated_at: '2026-01-10T08:00:00Z',
};

const BRIDGE_LINUX: SdwanHostBridge = {
  id: 'hb-002',
  node_instance_id: 'ni-def',
  node_instance_name: 'node-beta',
  network_profile: 'lightweight',
  short_id: 2,
  bridge_name: 'br-002',
  kind: 'linux',
  state: 'pending',
  applied_at: null,
  draining_at: null,
  removed_at: null,
  created_at: '2026-01-09T13:00:00Z',
  updated_at: null,
};

const BRIDGE_DRAINING: SdwanHostBridge = {
  id: 'hb-003',
  node_instance_id: 'ni-abc',
  node_instance_name: 'node-alpha',
  network_profile: null,
  short_id: 3,
  bridge_name: 'ovs-br-003',
  kind: 'ovs',
  state: 'draining',
  applied_at: '2026-01-08T00:00:00Z',
  draining_at: '2026-01-11T06:00:00Z',
  removed_at: null,
  created_at: '2026-01-07T00:00:00Z',
  updated_at: '2026-01-11T06:00:00Z',
};

const BRIDGE_REMOVED: SdwanHostBridge = {
  id: 'hb-004',
  node_instance_id: 'ni-def',
  node_instance_name: 'node-beta',
  network_profile: 'lightweight',
  short_id: 4,
  bridge_name: 'br-004',
  kind: 'linux',
  state: 'removed',
  applied_at: '2026-01-01T00:00:00Z',
  draining_at: '2026-01-05T00:00:00Z',
  removed_at: '2026-01-06T00:00:00Z',
  created_at: '2025-12-31T00:00:00Z',
  updated_at: '2026-01-06T00:00:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

const renderTab = () =>
  render(
    <BrowserRouter>
      <HostBridgesTab />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('HostBridgesTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------
  it('shows a loading indicator while the initial fetch is in flight', () => {
    // Never resolve — keep the promise pending
    mockGet.mockReturnValue(new Promise(() => undefined));

    renderTab();

    expect(screen.getByText(/loading host bridges/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------
  it('renders an error message when the API call rejects', async () => {
    mockGet.mockRejectedValue(new Error('Network timeout'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------
  it('renders the empty state when there are no bridges', async () => {
    mockGet.mockResolvedValue(
      envelope({ host_bridges: [] }),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('No host bridges yet')).toBeInTheDocument(),
    );
    expect(screen.getByText(/bridges are allocated by the on-node agent/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // List rendering
  // ---------------------------------------------------------------------------
  it('fetches bridges from the correct endpoint and renders them in a table', async () => {
    mockGet.mockResolvedValue(
      envelope({ host_bridges: [BRIDGE_ACTIVE, BRIDGE_LINUX] }),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('ovs-br-001')).toBeInTheDocument(),
    );

    expect(mockGet).toHaveBeenCalledWith(
      '/system/sdwan/host_bridges',
      { params: undefined },
    );

    // Bridge names
    expect(screen.getByText('ovs-br-001')).toBeInTheDocument();
    expect(screen.getByText('br-002')).toBeInTheDocument();

    // Host names (node_instance_name)
    expect(screen.getAllByText('node-alpha').length).toBeGreaterThan(0);
    expect(screen.getAllByText('node-beta').length).toBeGreaterThan(0);

    // Short IDs
    expect(screen.getByText('1')).toBeInTheDocument();
    expect(screen.getByText('2')).toBeInTheDocument();

    // Network profiles
    expect(screen.getByText('heavyweight')).toBeInTheDocument();
    expect(screen.getByText('lightweight')).toBeInTheDocument();

    // Kind badges
    expect(screen.getByText('ovs')).toBeInTheDocument();
    expect(screen.getByText('linux')).toBeInTheDocument();

    // State badges
    expect(screen.getByText('active')).toBeInTheDocument();
    expect(screen.getByText('pending')).toBeInTheDocument();
  });

  it('shows a dash for missing network_profile', async () => {
    mockGet.mockResolvedValue(
      envelope({ host_bridges: [BRIDGE_DRAINING] }),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('ovs-br-003')).toBeInTheDocument(),
    );

    // BRIDGE_DRAINING has network_profile: null — should render '—'
    expect(screen.getByText('—')).toBeInTheDocument();
  });

  it('uses node_instance_id as the host label when node_instance_name is absent', async () => {
    const bridgeNoName: SdwanHostBridge = {
      ...BRIDGE_ACTIVE,
      id: 'hb-noname',
      node_instance_name: null,
    };
    mockGet.mockResolvedValue(
      envelope({ host_bridges: [bridgeNoName] }),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getAllByText('ni-abc').length).toBeGreaterThan(0),
    );
  });

  // ---------------------------------------------------------------------------
  // State badge presence for all states
  // ---------------------------------------------------------------------------
  it.each([
    ['active', BRIDGE_ACTIVE],
    ['pending', BRIDGE_LINUX],
    ['draining', BRIDGE_DRAINING],
    ['removed', BRIDGE_REMOVED],
  ])('renders the %s state badge correctly', async (state, bridge) => {
    mockGet.mockResolvedValue(envelope({ host_bridges: [bridge] }));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(state)).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Expand / collapse row details
  // ---------------------------------------------------------------------------
  it('expands a row on expand-button click and fetches bridge detail', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ host_bridges: [BRIDGE_ACTIVE] }))
      .mockResolvedValueOnce(
        envelope({
          host_bridge: {
            ...BRIDGE_ACTIVE,
            created_at: '2026-01-09T12:00:00Z',
          },
        }),
      );

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('expand-host-bridge-hb-001')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('expand-host-bridge-hb-001'));

    // Detail row appears
    await waitFor(() =>
      expect(screen.getByText('Bridge ID')).toBeInTheDocument(),
    );

    // Detail fetch called with the bridge's ID
    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/host_bridges/hb-001');

    // Detail fields are visible
    expect(screen.getByText('Bridge Name')).toBeInTheDocument();
    expect(screen.getByText('Network Profile')).toBeInTheDocument();
    expect(screen.getByText('Applied')).toBeInTheDocument();
    expect(screen.getByText('Created')).toBeInTheDocument();
  });

  it('collapses the detail row when the expand button is clicked again', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ host_bridges: [BRIDGE_ACTIVE] }))
      .mockResolvedValueOnce(envelope({ host_bridge: BRIDGE_ACTIVE }));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('expand-host-bridge-hb-001')).toBeInTheDocument(),
    );

    // Expand
    fireEvent.click(screen.getByTestId('expand-host-bridge-hb-001'));
    await waitFor(() =>
      expect(screen.getByText('Bridge ID')).toBeInTheDocument(),
    );

    // Collapse
    fireEvent.click(screen.getByTestId('expand-host-bridge-hb-001'));
    expect(screen.queryByText('Bridge ID')).not.toBeInTheDocument();
  });

  it('does not re-fetch detail if the row was already expanded (cached)', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ host_bridges: [BRIDGE_ACTIVE] }))
      .mockResolvedValueOnce(envelope({ host_bridge: BRIDGE_ACTIVE }));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('expand-host-bridge-hb-001')).toBeInTheDocument(),
    );

    // Expand once
    fireEvent.click(screen.getByTestId('expand-host-bridge-hb-001'));
    await waitFor(() =>
      expect(screen.getByText('Bridge ID')).toBeInTheDocument(),
    );

    // Collapse then expand again
    fireEvent.click(screen.getByTestId('expand-host-bridge-hb-001'));
    fireEvent.click(screen.getByTestId('expand-host-bridge-hb-001'));

    // Only one detail GET should have been issued
    const detailCalls = mockGet.mock.calls.filter(
      (c: unknown[]) => typeof c[0] === 'string' && (c[0] as string).includes('/hb-001'),
    );
    expect(detailCalls.length).toBe(1);
  });

  it('shows an inline error when the detail fetch fails', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ host_bridges: [BRIDGE_ACTIVE] }))
      .mockRejectedValueOnce(new Error('Detail unavailable'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('expand-host-bridge-hb-001')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('expand-host-bridge-hb-001'));

    await waitFor(() =>
      expect(screen.getByText(/detail unavailable: detail unavailable/i)).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Multiple rows can be expanded simultaneously
  // ---------------------------------------------------------------------------
  it('allows multiple rows to be expanded at the same time', async () => {
    mockGet
      .mockResolvedValueOnce(
        envelope({ host_bridges: [BRIDGE_ACTIVE, BRIDGE_LINUX] }),
      )
      .mockResolvedValue(envelope({ host_bridge: BRIDGE_ACTIVE }));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('expand-host-bridge-hb-001')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('expand-host-bridge-hb-001'));
    fireEvent.click(screen.getByTestId('expand-host-bridge-hb-002'));

    // Both detail panels should be visible
    await waitFor(() =>
      expect(screen.getAllByText('Bridge ID').length).toBe(2),
    );
  });

  // ---------------------------------------------------------------------------
  // Delete (arm-and-confirm)
  // ---------------------------------------------------------------------------
  it('shows the delete button for active bridges when canManage=true', async () => {
    mockGet.mockResolvedValue(
      envelope({ host_bridges: [BRIDGE_ACTIVE] }),
    );

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByTestId('delete-host-bridge-hb-001'),
      ).toBeInTheDocument(),
    );
  });

  it('does NOT show a delete button for removed bridges', async () => {
    mockGet.mockResolvedValue(
      envelope({ host_bridges: [BRIDGE_REMOVED] }),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('br-004')).toBeInTheDocument(),
    );

    expect(
      screen.queryByTestId('delete-host-bridge-hb-004'),
    ).not.toBeInTheDocument();
  });

  it('arms the delete button on first click (shows Confirm?)', async () => {
    mockGet.mockResolvedValue(
      envelope({ host_bridges: [BRIDGE_ACTIVE] }),
    );

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByTestId('delete-host-bridge-hb-001'),
      ).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('delete-host-bridge-hb-001'));

    expect(screen.getByText('Confirm?')).toBeInTheDocument();
    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('calls DELETE /system/sdwan/host_bridges/:id after confirm click', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ host_bridges: [BRIDGE_ACTIVE] }))
      .mockResolvedValueOnce(envelope({ host_bridges: [] })); // refresh
    mockDelete.mockResolvedValue({ data: { success: true } });

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByTestId('delete-host-bridge-hb-001'),
      ).toBeInTheDocument(),
    );

    // Arm
    fireEvent.click(screen.getByTestId('delete-host-bridge-hb-001'));
    await waitFor(() => expect(screen.getByText('Confirm?')).toBeInTheDocument());

    // Confirm
    fireEvent.click(screen.getByText('Confirm?'));

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/host_bridges/hb-001'),
    );
  });

  it('shows a success notification after a successful delete', async () => {
    mockGet
      .mockResolvedValueOnce(envelope({ host_bridges: [BRIDGE_ACTIVE] }))
      .mockResolvedValueOnce(envelope({ host_bridges: [] }));
    mockDelete.mockResolvedValue({ data: { success: true } });

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('delete-host-bridge-hb-001')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('delete-host-bridge-hb-001'));
    await waitFor(() => expect(screen.getByText('Confirm?')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Confirm?'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'success',
          message: 'Bridge ovs-br-001 removed',
        }),
      ),
    );
  });

  it('shows an error notification when delete fails', async () => {
    mockGet.mockResolvedValue(
      envelope({ host_bridges: [BRIDGE_ACTIVE] }),
    );
    mockDelete.mockRejectedValue(new Error('Bridge locked'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('delete-host-bridge-hb-001')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('delete-host-bridge-hb-001'));
    await waitFor(() => expect(screen.getByText('Confirm?')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Confirm?'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Bridge locked',
        }),
      ),
    );
  });

  it('arm-and-confirm states are independent per row', async () => {
    mockGet.mockResolvedValue(
      envelope({ host_bridges: [BRIDGE_ACTIVE, BRIDGE_DRAINING] }),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('delete-host-bridge-hb-001')).toBeInTheDocument(),
    );

    // Arm the first row's delete
    fireEvent.click(screen.getByTestId('delete-host-bridge-hb-001'));

    await waitFor(() => expect(screen.getByText('Confirm?')).toBeInTheDocument());

    // The second row's delete button should still show the trash icon (not armed)
    expect(
      screen.getByTestId('delete-host-bridge-hb-003'),
    ).not.toHaveTextContent('Confirm?');
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------
  it('hides delete buttons when canManage is false', async () => {
    // hasPermission returns false — so canManage = false
    mockHasPermission.mockReturnValue(false);

    mockGet.mockResolvedValue(
      envelope({ host_bridges: [BRIDGE_ACTIVE] }),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('ovs-br-001')).toBeInTheDocument(),
    );

    expect(
      screen.queryByTestId('delete-host-bridge-hb-001'),
    ).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Table column headers
  // ---------------------------------------------------------------------------
  it('renders all expected column headers', async () => {
    mockGet.mockResolvedValue(
      envelope({ host_bridges: [BRIDGE_ACTIVE] }),
    );

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('ovs-br-001')).toBeInTheDocument(),
    );

    expect(screen.getByText('Host')).toBeInTheDocument();
    expect(screen.getByText('Profile')).toBeInTheDocument();
    expect(screen.getByText('Bridge')).toBeInTheDocument();
    expect(screen.getByText('Kind')).toBeInTheDocument();
    expect(screen.getByText('State')).toBeInTheDocument();
    expect(screen.getByText('Short ID')).toBeInTheDocument();
    expect(screen.getByText('Actions')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Refresh after delete
  // ---------------------------------------------------------------------------
  it('re-fetches the bridge list after a successful delete', async () => {
    mockGet
      .mockResolvedValueOnce(
        envelope({ host_bridges: [BRIDGE_ACTIVE] }),
      )
      .mockResolvedValueOnce(
        envelope({ host_bridges: [] }), // post-delete refresh
      );
    mockDelete.mockResolvedValue({ data: { success: true } });

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('delete-host-bridge-hb-001')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('delete-host-bridge-hb-001'));
    await waitFor(() => expect(screen.getByText('Confirm?')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Confirm?'));

    // After the delete resolves, the tab should trigger a second GET
    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Pending-approval branch (IMP-87ec6f651f07)
  // ---------------------------------------------------------------------------

  it('shows the pending-approval notification (not success) when the bridge delete is parked', async () => {
    mockGet.mockResolvedValue(envelope({ host_bridges: [BRIDGE_ACTIVE] }));
    mockDelete.mockResolvedValue({
      status: 202,
      data: {
        success: true,
        data: {
          pending: true,
          deferred_operation_id: 'dop-1',
          action_category: 'sdwan.host_bridge_release',
          approval_request_id: 'ar-1',
          message: 'Approval required',
        },
      },
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('delete-host-bridge-hb-001')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('delete-host-bridge-hb-001'));
    await waitFor(() => expect(screen.getByText('Confirm?')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Confirm?'));

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
});
