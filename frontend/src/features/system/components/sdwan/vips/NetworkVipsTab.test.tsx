import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworkVipsTab } from './NetworkVipsTab';
import type { SdwanVirtualIp, SdwanPeer } from '../../../types/sdwan.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// Use a mutable spy so individual tests can override permission behaviour.
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

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_ID = 'net-abc123';

const PEER_A: SdwanPeer = {
  id: 'peer-aaa',
  network_id: NETWORK_ID,
  node_instance_id: 'inst-11111111',
  assigned_address: '10.0.0.1/24',
  publicly_reachable: true,
  listen_port: 51820,
  status: 'active',
};

const PEER_B: SdwanPeer = {
  id: 'peer-bbb',
  network_id: NETWORK_ID,
  node_instance_id: 'inst-22222222',
  assigned_address: '10.0.0.2/24',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'active',
};

const VIP_ACTIVE: SdwanVirtualIp = {
  id: 'vip-111',
  network_id: NETWORK_ID,
  name: 'webapp-vip',
  cidr: '192.0.2.42/32',
  anycast: false,
  state: 'active',
  holder_peer_ids: [],
  failover_holder_peer_ids: ['peer-bbb'],
  primary_holder_peer_id: 'peer-aaa',
  primary_holder_address: '10.0.0.1',
  advertised_med: 0,
  advertised_local_pref: 100,
  tags: [],
  description: null,
  assignments: [],
  created_at: '2026-01-01T00:00:00Z',
};

const VIP_ANYCAST: SdwanVirtualIp = {
  id: 'vip-222',
  network_id: NETWORK_ID,
  name: 'anycast-vip',
  cidr: 'fd00::1/128',
  anycast: true,
  state: 'active',
  holder_peer_ids: ['peer-aaa', 'peer-bbb'],
  failover_holder_peer_ids: [],
  primary_holder_peer_id: null,
  primary_holder_address: null,
  advertised_med: 100,
  advertised_local_pref: 200,
  tags: ['prod'],
  description: 'Anycast address for load balancing',
  assignments: [],
  created_at: '2026-01-02T00:00:00Z',
};

/**
 * Double-envelope helper: apiClient methods resolve to AxiosResponse whose
 * .data body is { success: true, data: <payload> }.
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

function vipListEnvelope(vips: SdwanVirtualIp[]) {
  return envelope({ virtual_ips: vips, count: vips.length });
}

function peerListEnvelope(peers: SdwanPeer[]) {
  return envelope({ peers, count: peers.length });
}

// =============================================================================
// Render helper
// =============================================================================

type TabProps = {
  networkId?: string;
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
};

const renderTab = (props: TabProps = {}) =>
  render(
    <BrowserRouter>
      <NetworkVipsTab networkId={props.networkId ?? NETWORK_ID} onActionsReady={props.onActionsReady} />
    </BrowserRouter>
  );

// =============================================================================
// Tests
// =============================================================================

describe('NetworkVipsTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while VIPs are being fetched', () => {
    // Promise that never resolves keeps component in loading state
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByText(/loading virtual ips/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows an empty-state message when no VIPs exist', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error message when the VIP list fetch fails', async () => {
    mockGet.mockRejectedValue(new Error('Network timeout'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Renders VIP list
  // ---------------------------------------------------------------------------

  it('renders the list of VIPs fetched from the API', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE, VIP_ANYCAST]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());
    expect(screen.getByText('anycast-vip')).toBeInTheDocument();
    expect(screen.getByText('192.0.2.42/32')).toBeInTheDocument();
    expect(screen.getByText('fd00::1/128')).toBeInTheDocument();
  });

  it('calls the correct API URLs for VIP list and peers on mount', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );

    expect(mockGet).toHaveBeenCalledWith(
      `/system/sdwan/networks/${NETWORK_ID}/virtual_ips`
    );
    expect(mockGet).toHaveBeenCalledWith(
      `/system/sdwan/networks/${NETWORK_ID}/peers`
    );
  });

  // ---------------------------------------------------------------------------
  // Renders explanatory description text
  // ---------------------------------------------------------------------------

  it('renders the tab description text about first-class addresses', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );

    expect(screen.getByText(/first-class addresses/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onActionsReady callback
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with an openCreate handle on mount', () => {
    mockGet.mockResolvedValue(vipListEnvelope([]));

    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    expect(onActionsReady).toHaveBeenCalledWith(
      expect.objectContaining({ openCreate: expect.any(Function) })
    );
  });

  it('calls onActionsReady(null) when the component unmounts', () => {
    mockGet.mockResolvedValue(vipListEnvelope([]));

    const onActionsReady = jest.fn();
    const { unmount } = renderTab({ onActionsReady });
    unmount();

    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  it('opens the Create VIP modal when the action handle openCreate is invoked', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    let capturedHandle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => {
      capturedHandle = h;
    });

    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );

    // Simulate the parent page invoking the action handle
    expect(capturedHandle).not.toBeNull();
    (capturedHandle as { openCreate: () => void }).openCreate();

    // Wait for the modal heading (distinct from the submit button)
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Create Virtual IP' })).toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // VIP row expansion
  // ---------------------------------------------------------------------------

  it('toggles expanded detail row when the expand button is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());

    const expandBtn = screen.getByLabelText(/expand vip webapp-vip/i);
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getByLabelText(/collapse vip webapp-vip/i)).toBeInTheDocument()
    );

    // Collapse again
    fireEvent.click(screen.getByLabelText(/collapse vip webapp-vip/i));
    await waitFor(() =>
      expect(screen.getByLabelText(/expand vip webapp-vip/i)).toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Anycast vs Active/passive mode display
  // ---------------------------------------------------------------------------

  it('displays Active/passive mode for non-anycast VIP', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());
    expect(screen.getByText('Active/passive')).toBeInTheDocument();
  });

  it('displays Anycast mode with holder count for anycast VIP', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ANYCAST]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() => expect(screen.getByText('anycast-vip')).toBeInTheDocument());
    expect(screen.getByText(/anycast \(2\)/i)).toBeInTheDocument();
  });

  it('shows failover candidate count for non-anycast VIP with failover peers', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());
    expect(screen.getByText('1 candidate')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Delete confirmation modal
  // ---------------------------------------------------------------------------

  it('opens the delete confirmation modal when the delete action is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Delete'));

    // Modal title is in a heading
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Virtual IP' })).toBeInTheDocument()
    );
    // VIP name appears as a <strong> child (text is split across elements)
    expect(screen.getAllByText('webapp-vip').length).toBeGreaterThan(0);
    // CIDR appears inside the confirmation text
    expect(screen.getAllByText('192.0.2.42/32').length).toBeGreaterThan(0);
  });

  it('cancels the delete modal without calling the API', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Delete'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Virtual IP' })).toBeInTheDocument()
    );

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Delete Virtual IP' })).not.toBeInTheDocument()
    );
    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('calls DELETE /system/sdwan/networks/:id/virtual_ips/:vipId and shows success notification', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([]))
      // After refresh, return empty list
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Delete'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Virtual IP' })).toBeInTheDocument()
    );

    // Click the danger Delete button inside the modal (not the row icon)
    const deleteModal = screen.getByRole('dialog');
    fireEvent.click(within(deleteModal).getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith(
        `/system/sdwan/networks/${NETWORK_ID}/virtual_ips/${VIP_ACTIVE.id}`
      )
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'success',
          message: `VIP '${VIP_ACTIVE.name}' deleted.`,
        })
      )
    );
  });

  it('shows an error notification when delete API call fails', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    mockDelete.mockRejectedValueOnce(new Error('Server error'));

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Delete'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Virtual IP' })).toBeInTheDocument()
    );

    const deleteModal = screen.getByRole('dialog');
    fireEvent.click(within(deleteModal).getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Server error' })
      )
    );
  });

  // ---------------------------------------------------------------------------
  // Failover modal
  // ---------------------------------------------------------------------------

  it('opens the failover modal when the failover action is clicked on a VIP with failover candidates', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Trigger failover'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: `Failover VIP — ${VIP_ACTIVE.name}` })).toBeInTheDocument()
    );
  });

  it('does NOT show the failover button for anycast VIPs', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ANYCAST]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() => expect(screen.getByText('anycast-vip')).toBeInTheDocument());

    expect(screen.queryByTitle('Trigger failover')).not.toBeInTheDocument();
  });

  it('does NOT show the failover button when VIP has no failover candidates', async () => {
    const noFailoverVip: SdwanVirtualIp = {
      ...VIP_ACTIVE,
      failover_holder_peer_ids: [],
    };

    mockGet
      .mockResolvedValueOnce(vipListEnvelope([noFailoverVip]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A]));

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());

    expect(screen.queryByTitle('Trigger failover')).not.toBeInTheDocument();
  });

  it('calls POST /system/sdwan/networks/:id/virtual_ips/:vipId/failover and shows success notification on confirm', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]))
      // Refresh after failover
      .mockResolvedValueOnce(vipListEnvelope([{ ...VIP_ACTIVE, primary_holder_peer_id: 'peer-bbb' }]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    mockPost.mockResolvedValueOnce(
      envelope({ virtual_ip: { ...VIP_ACTIVE, primary_holder_peer_id: 'peer-bbb' } })
    );

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Trigger failover'));

    await waitFor(() =>
      expect(
        screen.getByRole('heading', { name: `Failover VIP — ${VIP_ACTIVE.name}` })
      ).toBeInTheDocument()
    );

    fireEvent.click(screen.getByRole('button', { name: /confirm failover/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        `/system/sdwan/networks/${NETWORK_ID}/virtual_ips/${VIP_ACTIVE.id}/failover`,
        {}
      )
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'success',
          message: 'Failover triggered.',
        })
      )
    );
  });

  // ---------------------------------------------------------------------------
  // Create VIP modal
  // ---------------------------------------------------------------------------

  it('renders the Create VIP modal with name, CIDR, and anycast fields', async () => {
    // VirtualIpCreateModal also calls getPeers on mount
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]))
      // Create modal peer fetch
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    let handle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => { handle = h; });

    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );

    (handle as { openCreate: () => void }).openCreate();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Create Virtual IP' })).toBeInTheDocument()
    );

    expect(screen.getByText('Name')).toBeInTheDocument();
    expect(screen.getByText('CIDR')).toBeInTheDocument();
    expect(screen.getByLabelText(/anycast mode/i)).toBeInTheDocument();
  });

  it('submits the create form and calls POST with correct payload for active/passive VIP', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]))
      // Create modal peer fetch
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]))
      // Refresh after creation
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    mockPost.mockResolvedValueOnce(envelope({ virtual_ip: VIP_ACTIVE }));

    let handle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => { handle = h; });

    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );

    (handle as { openCreate: () => void }).openCreate();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Create Virtual IP' })).toBeInTheDocument()
    );

    // Fill in the form
    const nameInput = screen.getByPlaceholderText(/webapp-vip/i);
    fireEvent.change(nameInput, { target: { value: 'webapp-vip' } });

    const cidrInput = screen.getByPlaceholderText(/192\.0\.2\.42\/32/i);
    fireEvent.change(cidrInput, { target: { value: '192.0.2.42/32' } });

    // Select primary holder
    const holderSelect = screen.getByRole('combobox');
    fireEvent.change(holderSelect, { target: { value: PEER_A.id } });

    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        `/system/sdwan/networks/${NETWORK_ID}/virtual_ips`,
        expect.objectContaining({
          virtual_ip: expect.objectContaining({
            name: 'webapp-vip',
            cidr: '192.0.2.42/32',
            anycast: false,
          }),
        })
      )
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'success',
          message: 'Virtual IP created.',
        })
      )
    );
  });

  it('shows a validation error for an invalid CIDR', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A]));

    let handle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => { handle = h; });

    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );

    (handle as { openCreate: () => void }).openCreate();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Create Virtual IP' })).toBeInTheDocument()
    );

    fireEvent.change(screen.getByPlaceholderText(/webapp-vip/i), {
      target: { value: 'test-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText(/192\.0\.2\.42\/32/i), {
      target: { value: 'not-a-valid-cidr' },
    });

    // Select a primary holder to avoid triggering that validation first
    const holderSelect = screen.getByRole('combobox');
    fireEvent.change(holderSelect, { target: { value: PEER_A.id } });

    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: expect.stringMatching(/cidr must be a valid/i),
        })
      )
    );
    expect(mockPost).not.toHaveBeenCalled();
  });

  it('shows a validation error for anycast VIP with fewer than 2 holders', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    let handle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => { handle = h; });

    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );

    (handle as { openCreate: () => void }).openCreate();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Create Virtual IP' })).toBeInTheDocument()
    );

    fireEvent.change(screen.getByPlaceholderText(/webapp-vip/i), {
      target: { value: 'ac-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText(/192\.0\.2\.42\/32/i), {
      target: { value: '10.0.0.1/32' },
    });

    // Enable anycast mode
    fireEvent.click(screen.getByLabelText(/anycast mode/i));

    await waitFor(() =>
      expect(screen.getByText(/anycast holders/i)).toBeInTheDocument()
    );

    // Select only ONE holder peer (need 2 for anycast)
    const checkboxes = screen.getAllByRole('checkbox');
    // anycast checkbox is the labelled one; the rest are holder peer checkboxes
    const anycastCheckbox = screen.getByLabelText(/anycast mode/i);
    const holderCheckboxes = checkboxes.filter((cb) => cb !== anycastCheckbox);
    fireEvent.click(holderCheckboxes[0]);

    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: expect.stringMatching(/at least 2 holder/i),
        })
      )
    );
    expect(mockPost).not.toHaveBeenCalled();
  });

  it('closes the create modal when Cancel is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    let handle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => { handle = h; });

    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );

    (handle as { openCreate: () => void }).openCreate();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Create Virtual IP' })).toBeInTheDocument()
    );

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Create Virtual IP' })).not.toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Permission gating — no manage permission
  // ---------------------------------------------------------------------------

  it('hides delete and failover buttons when user lacks sdwan.vips.manage permission', async () => {
    // Override the permission spy to deny manage access
    mockHasPermission.mockReturnValue(false);

    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());

    expect(screen.queryByTitle('Delete')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Trigger failover')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Refresh after create
  // ---------------------------------------------------------------------------

  it('refreshes the VIP list after a VIP is successfully created', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([]))
      .mockResolvedValueOnce(peerListEnvelope([]))
      // Create modal peer fetch
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]))
      // Refresh after create
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([PEER_A, PEER_B]));

    mockPost.mockResolvedValueOnce(envelope({ virtual_ip: VIP_ACTIVE }));

    let handle: { openCreate: () => void } | null = null;
    const onActionsReady = jest.fn((h) => { handle = h; });

    renderTab({ onActionsReady });

    await waitFor(() =>
      expect(screen.getByText(/no virtual ips in this network/i)).toBeInTheDocument()
    );

    (handle as { openCreate: () => void }).openCreate();

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Create Virtual IP' })).toBeInTheDocument()
    );

    fireEvent.change(screen.getByPlaceholderText(/webapp-vip/i), {
      target: { value: 'webapp-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText(/192\.0\.2\.42\/32/i), {
      target: { value: '192.0.2.42/32' },
    });

    const holderSelect = screen.getByRole('combobox');
    fireEvent.change(holderSelect, { target: { value: PEER_A.id } });

    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    // Modal closes, list refreshes and shows the newly created VIP
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: 'Create Virtual IP' })).not.toBeInTheDocument()
    );
    await waitFor(() =>
      expect(screen.getByText('webapp-vip')).toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Pending-approval branch (IMP-87ec6f651f07)
  // ---------------------------------------------------------------------------

  it('shows the pending-approval notification (not success) when the VIP delete is parked', async () => {
    mockGet
      .mockResolvedValueOnce(vipListEnvelope([VIP_ACTIVE]))
      .mockResolvedValueOnce(peerListEnvelope([]));

    mockDelete.mockResolvedValueOnce({
      status: 202,
      data: {
        success: true,
        data: {
          pending: true,
          deferred_operation_id: 'dop-1',
          action_category: 'sdwan.virtual_ip_delete',
          approval_request_id: 'ar-1',
          message: 'Approval required',
        },
      },
    });

    renderTab();

    await waitFor(() => expect(screen.getByText('webapp-vip')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Delete'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Delete Virtual IP' })).toBeInTheDocument()
    );

    const deleteModal = screen.getByRole('dialog');
    fireEvent.click(within(deleteModal).getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval required/i),
          link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
        })
      )
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' })
    );
  });
});
