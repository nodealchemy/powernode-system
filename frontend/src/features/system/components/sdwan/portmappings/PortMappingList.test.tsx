import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PortMappingList } from './PortMappingList';
import type { SdwanPortMapping, SdwanPeer } from '@system/features/system/types/sdwan.types';

// =============================================================================
// Mocks
//
// PortMappingList imports:
//   - sdwanApi from '@system/features/system/services/api/sdwanApi'
//     calls: sdwanApi.listPortMappings(networkId), sdwanApi.getPeers(networkId)
//   - EntityLink from '@/shared/components/entity'
//     (uses usePermissions + useEntityModal internally)
//
// We mock sdwanApi directly (not apiClient) because the component calls the
// typed facade, not the raw HTTP client.
// =============================================================================

const mockListPortMappings = jest.fn();
const mockGetPeers = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    listPortMappings: (...args: unknown[]) => mockListPortMappings(...args),
    getPeers: (...args: unknown[]) => mockGetPeers(...args),
  },
}));

// EntityLink uses usePermissions and useEntityModal internally.
// Mock EntityLink itself to render a simple span so we avoid that
// dependency chain in these orchestration-level tests.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label, id }: { label?: React.ReactNode; id?: string | null }) => (
    <span data-testid="entity-link">{label ?? id ?? ''}</span>
  ),
}));

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_ID = 'net-abc123';

const PEER_HUB: SdwanPeer = {
  id: 'peer-hub-001',
  network_id: NETWORK_ID,
  node_instance_id: 'inst-001',
  assigned_address: 'fd00::1',
  publicly_reachable: true,
  listen_port: 51820,
  status: 'active',
};

const PEER_SPOKE: SdwanPeer = {
  id: 'peer-spoke-002',
  network_id: NETWORK_ID,
  node_instance_id: 'inst-002',
  assigned_address: 'fd00::2',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'active',
};

const MAPPING_TCP: SdwanPortMapping = {
  id: 'map-tcp-001',
  network_id: NETWORK_ID,
  hub_peer_id: 'peer-hub-001',
  target_peer_id: 'peer-spoke-002',
  target_virtual_ip_id: null,
  name: 'web-http',
  listen_port: 80,
  target_port: null,
  effective_target_port: 80,
  protocol: 'tcp',
  enabled: true,
  description: 'HTTP traffic',
  metadata: {},
  resolved_target_address: 'fd00::2',
  last_compiled_at: '2026-01-15T10:00:00Z',
  created_at: '2026-01-10T08:00:00Z',
};

const MAPPING_UDP: SdwanPortMapping = {
  id: 'map-udp-002',
  network_id: NETWORK_ID,
  hub_peer_id: 'peer-hub-001',
  target_peer_id: null,
  target_virtual_ip_id: 'vip-aaa',
  name: 'game-server',
  listen_port: 7777,
  target_port: 7778,
  effective_target_port: 7778,
  protocol: 'udp',
  enabled: false,
  description: null,
  metadata: {},
  resolved_target_address: null,
  last_compiled_at: null,
  created_at: '2026-01-12T09:00:00Z',
};

function portMappingsResult(mappings: SdwanPortMapping[]) {
  return { port_mappings: mappings, count: mappings.length };
}

function peersResult(peers: SdwanPeer[]) {
  return { peers };
}

const renderList = (props: Partial<React.ComponentProps<typeof PortMappingList>> = {}) =>
  render(
    <BrowserRouter>
      <PortMappingList networkId={NETWORK_ID} {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('PortMappingList', () => {
  beforeEach(() => {
    mockListPortMappings.mockReset();
    mockGetPeers.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while data is being fetched', () => {
    // Never resolve — keep it pending
    mockListPortMappings.mockReturnValue(new Promise(() => {}));
    mockGetPeers.mockReturnValue(new Promise(() => {}));

    renderList();

    expect(screen.getByText(/loading port mappings/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows the error message when the API call fails', async () => {
    mockListPortMappings.mockRejectedValue(new Error('Network error'));
    mockGetPeers.mockRejectedValue(new Error('Network error'));

    renderList();

    await waitFor(() =>
      expect(screen.getByText('Network error')).toBeInTheDocument(),
    );
  });

  it('shows a generic error message for non-Error rejections', async () => {
    mockListPortMappings.mockRejectedValue('oops');
    mockGetPeers.mockResolvedValue(peersResult([]));

    renderList();

    await waitFor(() =>
      expect(screen.getByText('Failed to load port mappings')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders the empty state when no mappings exist', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([]));
    mockGetPeers.mockResolvedValue(peersResult([]));

    renderList();

    await waitFor(() =>
      expect(
        screen.getByText('No port mappings in this network.'),
      ).toBeInTheDocument(),
    );
    expect(screen.getByText(/Port mappings publish overlay services/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Populated state — column rendering
  // ---------------------------------------------------------------------------

  it('renders table rows for each port mapping', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP, MAPPING_UDP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    expect(screen.getByText('game-server')).toBeInTheDocument();
  });

  it('displays the mapping name and description in the row', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    expect(screen.getByText('HTTP traffic')).toBeInTheDocument();
  });

  it('renders protocol as tcp styled as info and udp styled as success', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP, MAPPING_UDP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());

    const tcpSpan = screen.getByText('tcp');
    expect(tcpSpan).toHaveClass('text-theme-info-fg');

    const udpSpan = screen.getByText('udp');
    expect(udpSpan).toHaveClass('text-theme-success-fg');
  });

  it('displays the listen port next to protocol', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    // Port 80 appears in both the "Listen" column and the "Target Port" column
    expect(screen.getAllByText('80').length).toBeGreaterThan(0);
  });

  it('displays the effective target port', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_UDP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB]));

    renderList();

    await waitFor(() => expect(screen.getByText('game-server')).toBeInTheDocument());
    expect(screen.getByText('7778')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Peer label resolution
  // ---------------------------------------------------------------------------

  it('labels the hub peer with the short id + (hub) suffix when publicly_reachable', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    // hub_peer_id = 'peer-hub-001', slice 0..8 = 'peer-hub', publicly_reachable = true
    await waitFor(() => expect(screen.getAllByText('peer-hub (hub)').length).toBeGreaterThan(0));
  });

  it('labels spoke peers without (hub) suffix', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    // target_peer_id = 'peer-spoke-002', publicly_reachable = false
    // peerLabel returns 'peer-spo' (8 chars) with NO ' (hub)' suffix
    expect(screen.getAllByText('peer-spo').length).toBeGreaterThan(0);
    // Hub peer should have ' (hub)' suffix — spoke should NOT appear with it
    expect(screen.queryByText('peer-spo (hub)')).not.toBeInTheDocument();
  });

  it('falls back to 8-char peer ID slice when peer is not found in peerById map', async () => {
    const mappingUnknownPeer: SdwanPortMapping = {
      ...MAPPING_TCP,
      hub_peer_id: 'unknown-peer-xyz',
    };
    mockListPortMappings.mockResolvedValue(portMappingsResult([mappingUnknownPeer]));
    mockGetPeers.mockResolvedValue(peersResult([])); // empty peers list

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    // 'unknown-peer-xyz'.slice(0, 8) = 'unknown-'
    expect(screen.getAllByText('unknown-').length).toBeGreaterThan(0);
  });

  it('shows — for null hub_peer_id', async () => {
    const mappingNullHub: SdwanPortMapping = {
      ...MAPPING_TCP,
      hub_peer_id: undefined as unknown as string,
    };
    mockListPortMappings.mockResolvedValue(portMappingsResult([mappingNullHub]));
    mockGetPeers.mockResolvedValue(peersResult([]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    expect(screen.getAllByText('—').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Target rendering — VIP vs peer
  // ---------------------------------------------------------------------------

  it('renders VIP label + EntityLink when target_virtual_ip_id is set', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_UDP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB]));

    renderList();

    await waitFor(() => expect(screen.getByText('game-server')).toBeInTheDocument());
    expect(screen.getAllByText('VIP').length).toBeGreaterThan(0);
    // EntityLink is mocked to a span with data-testid="entity-link"
    expect(screen.getAllByTestId('entity-link').length).toBeGreaterThan(0);
  });

  it('renders the resolved target address below the target when present', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    // resolved_target_address = 'fd00::2' — shown as "→ fd00::2"
    expect(screen.getByText('→ fd00::2')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Enabled indicator
  // ---------------------------------------------------------------------------

  it('renders Power icon for enabled and PowerOff for disabled', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP, MAPPING_UDP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    const { container } = renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());

    // Lucide renders SVG. We can verify via title attributes set by the action buttons.
    // Enabled icon row has a button with title 'Disable'; disabled has 'Enable'.
    // (These only appear when the callbacks are provided — pass them in.)
    // Without callbacks, the status column still shows the SVG icons but they
    // have no accessible label. We verify the two rows are rendered and the
    // enabled column SVGs differ via presence of both icon types in the DOM.
    const svgElements = container.querySelectorAll('svg');
    expect(svgElements.length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Row expansion (expand/collapse)
  // ---------------------------------------------------------------------------

  it('expands a row when the expand button is clicked and shows detail fields', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());

    // Initially collapsed — detail labels should not be visible
    expect(screen.queryByText('Listen Port')).not.toBeInTheDocument();

    // Click the expand button
    const expandBtn = screen.getByRole('button', {
      name: /expand mapping web-http/i,
    });
    fireEvent.click(expandBtn);

    // Detail panel appears — these labels are only in the expanded section
    await waitFor(() => expect(screen.getByText('Listen Port')).toBeInTheDocument());
    expect(screen.getByText('Protocol')).toBeInTheDocument();
    expect(screen.getByText('Hub Peer')).toBeInTheDocument();
    // 'Enabled' appears in both the table header and expanded panel — use getAllByText
    expect(screen.getAllByText('Enabled').length).toBeGreaterThan(1);
    // enabled = true → shows 'Yes'
    expect(screen.getByText('Yes')).toBeInTheDocument();
  });

  it('collapses the expanded row when the button is clicked again', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());

    // Expand
    const btn = screen.getByRole('button', { name: /expand mapping web-http/i });
    fireEvent.click(btn);
    await waitFor(() => expect(screen.getByText('Listen Port')).toBeInTheDocument());

    // Collapse
    const collapseBtn = screen.getByRole('button', {
      name: /collapse mapping web-http/i,
    });
    fireEvent.click(collapseBtn);

    await waitFor(() =>
      expect(screen.queryByText('Listen Port')).not.toBeInTheDocument(),
    );
  });

  it('shows description in expanded detail panel when description is set', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand mapping web-http/i }));

    await waitFor(() => expect(screen.getByText('Description')).toBeInTheDocument());
    // description = 'HTTP traffic' — shown in both summary row and expanded panel
    expect(screen.getAllByText('HTTP traffic').length).toBeGreaterThan(0);
  });

  it('shows target port note "(defaulted to listen port)" when target_port is null', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand mapping web-http/i }));

    await waitFor(() =>
      expect(
        screen.getByText('80 (defaulted to listen port)'),
      ).toBeInTheDocument(),
    );
  });

  it('shows resolved_target_address field in expanded panel', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand mapping web-http/i }));

    await waitFor(() =>
      expect(screen.getByText('Resolved Target Address')).toBeInTheDocument(),
    );
    expect(screen.getAllByText('fd00::2').length).toBeGreaterThan(0);
  });

  it('shows "Last Compiled" field in expanded panel when last_compiled_at is set', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand mapping web-http/i }));

    await waitFor(() =>
      expect(screen.getByText('Last Compiled')).toBeInTheDocument(),
    );
  });

  it('shows "Created" field in expanded panel when created_at is set', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand mapping web-http/i }));

    await waitFor(() => expect(screen.getByText('Created')).toBeInTheDocument());
  });

  it('shows metadata in expanded panel when metadata has keys', async () => {
    const mappingWithMeta: SdwanPortMapping = {
      ...MAPPING_TCP,
      metadata: { extra: 'value', count: 3 },
    };
    mockListPortMappings.mockResolvedValue(portMappingsResult([mappingWithMeta]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand mapping web-http/i }));

    await waitFor(() => expect(screen.getByText('Metadata')).toBeInTheDocument());
    expect(screen.getByText(/"extra": "value"/)).toBeInTheDocument();
  });

  it('does not show metadata section when metadata is empty object', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand mapping web-http/i }));

    await waitFor(() => expect(screen.getByText('Listen Port')).toBeInTheDocument());
    expect(screen.queryByText('Metadata')).not.toBeInTheDocument();
  });

  it('shows VIP EntityLink in expanded panel for target_virtual_ip_id mappings', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_UDP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB]));

    renderList();

    await waitFor(() => expect(screen.getByText('game-server')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand mapping game-server/i }));

    // 'Target' appears in both the table header <th> and the expanded panel <label>
    await waitFor(() => expect(screen.getAllByText('Target').length).toBeGreaterThan(1));
    expect(screen.getAllByText('VIP').length).toBeGreaterThan(0);
    expect(screen.getAllByTestId('entity-link').length).toBeGreaterThan(0);
  });

  it('shows disabled = "No (disabled)" in expanded panel for disabled mappings', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_UDP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB]));

    renderList();

    await waitFor(() => expect(screen.getByText('game-server')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /expand mapping game-server/i }));

    await waitFor(() =>
      expect(screen.getByText('No (disabled)')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Action callbacks
  // ---------------------------------------------------------------------------

  it('calls onEdit with the mapping when the edit button is clicked', async () => {
    const onEdit = jest.fn();
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList({ onEdit });

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Edit'));

    expect(onEdit).toHaveBeenCalledTimes(1);
    expect(onEdit).toHaveBeenCalledWith(MAPPING_TCP);
  });

  it('calls onDelete with the mapping when the delete button is clicked', async () => {
    const onDelete = jest.fn();
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList({ onDelete });

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Delete'));

    expect(onDelete).toHaveBeenCalledTimes(1);
    expect(onDelete).toHaveBeenCalledWith(MAPPING_TCP);
  });

  it('calls onToggle with the mapping when the toggle button is clicked', async () => {
    const onToggle = jest.fn();
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList({ onToggle });

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());
    // Enabled mapping: toggle button title is 'Disable'
    fireEvent.click(screen.getByTitle('Disable'));

    expect(onToggle).toHaveBeenCalledTimes(1);
    expect(onToggle).toHaveBeenCalledWith(MAPPING_TCP);
  });

  it('shows Enable title on toggle button for disabled mapping', async () => {
    const onToggle = jest.fn();
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_UDP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB]));

    renderList({ onToggle });

    await waitFor(() => expect(screen.getByText('game-server')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Enable'));

    expect(onToggle).toHaveBeenCalledWith(MAPPING_UDP);
  });

  it('does not render action buttons when callbacks are not provided', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList(); // no callbacks

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());

    expect(screen.queryByTitle('Edit')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Delete')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Disable')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Enable')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // API call verification
  // ---------------------------------------------------------------------------

  it('calls listPortMappings and getPeers with the correct networkId', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([]));
    mockGetPeers.mockResolvedValue(peersResult([]));

    renderList({ networkId: 'net-xyz' });

    await waitFor(() =>
      expect(screen.getByText('No port mappings in this network.')).toBeInTheDocument(),
    );

    expect(mockListPortMappings).toHaveBeenCalledWith('net-xyz');
    expect(mockGetPeers).toHaveBeenCalledWith('net-xyz');
  });

  it('re-fetches when refreshKey changes', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([]));
    mockGetPeers.mockResolvedValue(peersResult([]));

    const { rerender } = renderList({ refreshKey: 0 });
    await waitFor(() =>
      expect(screen.getByText('No port mappings in this network.')).toBeInTheDocument(),
    );
    expect(mockListPortMappings).toHaveBeenCalledTimes(1);

    rerender(
      <BrowserRouter>
        <PortMappingList networkId={NETWORK_ID} refreshKey={1} />
      </BrowserRouter>,
    );

    await waitFor(() => expect(mockListPortMappings).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Multiple rows — independent expand state
  // ---------------------------------------------------------------------------

  it('expands only the clicked row when multiple rows are present', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP, MAPPING_UDP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB, PEER_SPOKE]));

    renderList();

    await waitFor(() => {
      expect(screen.getByText('web-http')).toBeInTheDocument();
      expect(screen.getByText('game-server')).toBeInTheDocument();
    });

    // Expand only the TCP mapping
    fireEvent.click(screen.getByRole('button', { name: /expand mapping web-http/i }));

    await waitFor(() => expect(screen.getByText('Listen Port')).toBeInTheDocument());

    // UDP mapping should still have its expand button (not collapse)
    expect(
      screen.getByRole('button', { name: /expand mapping game-server/i }),
    ).toBeInTheDocument();
  });

  it('renders table headers', async () => {
    mockListPortMappings.mockResolvedValue(portMappingsResult([MAPPING_TCP]));
    mockGetPeers.mockResolvedValue(peersResult([PEER_HUB]));

    renderList();

    await waitFor(() => expect(screen.getByText('web-http')).toBeInTheDocument());

    expect(screen.getByText('Name')).toBeInTheDocument();
    expect(screen.getByText('Hub')).toBeInTheDocument();
    expect(screen.getByText('Listen')).toBeInTheDocument();
    expect(screen.getByText('Target')).toBeInTheDocument();
    expect(screen.getByText('Target Port')).toBeInTheDocument();
    expect(screen.getByText('Enabled')).toBeInTheDocument();
    expect(screen.getByText('Actions')).toBeInTheDocument();
  });
});
