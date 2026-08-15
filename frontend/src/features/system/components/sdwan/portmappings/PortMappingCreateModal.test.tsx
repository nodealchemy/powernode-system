import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { PortMappingCreateModal } from './PortMappingCreateModal';
import type { SdwanPeer, SdwanVirtualIp, SdwanPortMapping } from '../../../types/sdwan.types';

// =============================================================================
// Mocks
// =============================================================================

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// Modal: render children when isOpen; expose title via data-testid.
jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({
    isOpen,
    children,
    title,
    onClose,
  }: {
    isOpen: boolean;
    children: React.ReactNode;
    title?: string;
    onClose: () => void;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="modal">
        <span data-testid="modal-title">{title}</span>
        <button data-testid="modal-close" onClick={onClose}>
          ×
        </button>
        {children}
      </div>
    );
  },
}));

// Button: pass through type so submit works.
jest.mock('@/shared/components/ui/Button', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    variant,
    type,
  }: {
    children: React.ReactNode;
    onClick?: (e: React.MouseEvent) => void;
    disabled?: boolean;
    variant?: string;
    type?: 'button' | 'submit' | 'reset';
  }) => (
    <button
      onClick={onClick}
      disabled={disabled}
      data-variant={variant}
      type={type ?? 'button'}
    >
      {children}
    </button>
  ),
}));

// sdwanApi — mock the three methods the component calls.
const mockGetPeers = jest.fn();
const mockListVirtualIps = jest.fn();
const mockCreatePortMapping = jest.fn();
const mockUpdatePortMapping = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    getPeers: (...args: unknown[]) => mockGetPeers(...args),
    listVirtualIps: (...args: unknown[]) => mockListVirtualIps(...args),
    createPortMapping: (...args: unknown[]) => mockCreatePortMapping(...args),
    updatePortMapping: (...args: unknown[]) => mockUpdatePortMapping(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_ID = 'net-abc-123';

const HUB_PEER: SdwanPeer = {
  id: 'peer-hub-001',
  network_id: NETWORK_ID,
  node_instance_id: 'ni-001',
  assigned_address: '10.0.0.1',
  publicly_reachable: true,
  listen_port: 51820,
  status: 'active',
};

const SPOKE_PEER: SdwanPeer = {
  id: 'peer-spoke-002',
  network_id: NETWORK_ID,
  node_instance_id: 'ni-002',
  assigned_address: '10.0.0.2',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'active',
};

const VIP: SdwanVirtualIp = {
  id: 'vip-001',
  network_id: NETWORK_ID,
  name: 'db-vip',
  cidr: '10.100.0.1/32',
  anycast: false,
  state: 'active',
  holder_peer_ids: ['peer-hub-001'],
  failover_holder_peer_ids: [],
  advertised_med: 100,
  advertised_local_pref: 100,
  tags: [],
};

const SAVED_MAPPING: SdwanPortMapping = {
  id: 'pm-001',
  network_id: NETWORK_ID,
  hub_peer_id: 'peer-hub-001',
  target_peer_id: 'peer-spoke-002',
  target_virtual_ip_id: null,
  name: 'db-public',
  listen_port: 5432,
  target_port: null,
  effective_target_port: 5432,
  protocol: 'tcp',
  enabled: true,
  description: undefined,
};

const EXISTING_MAPPING: SdwanPortMapping = {
  id: 'pm-existing',
  network_id: NETWORK_ID,
  hub_peer_id: 'peer-hub-001',
  target_peer_id: 'peer-spoke-002',
  target_virtual_ip_id: null,
  name: 'existing-map',
  listen_port: 8080,
  target_port: 9090,
  effective_target_port: 9090,
  protocol: 'udp',
  enabled: false,
  description: 'existing description',
};

const EXISTING_VIP_MAPPING: SdwanPortMapping = {
  id: 'pm-vip',
  network_id: NETWORK_ID,
  hub_peer_id: 'peer-hub-001',
  target_peer_id: null,
  target_virtual_ip_id: 'vip-001',
  name: 'vip-map',
  listen_port: 443,
  target_port: null,
  effective_target_port: 443,
  protocol: 'tcp',
  enabled: true,
};

// The sdwanApi facade returns unwrapped values (extractData has already run).
function peersResult(peers: SdwanPeer[] = [HUB_PEER, SPOKE_PEER]) {
  return Promise.resolve({ peers });
}

function vipsResult(vips: SdwanVirtualIp[] = [VIP]) {
  return Promise.resolve({ virtual_ips: vips, count: vips.length });
}

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  networkId?: string;
  mapping?: SdwanPortMapping | null;
  onClose?: () => void;
  onSaved?: (mapping: SdwanPortMapping) => void;
}

function renderModal({
  networkId = NETWORK_ID,
  mapping = null,
  onClose = jest.fn(),
  onSaved = jest.fn(),
}: RenderProps = {}) {
  return render(
    <PortMappingCreateModal
      networkId={networkId}
      mapping={mapping}
      onClose={onClose}
      onSaved={onSaved}
    />,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PortMappingCreateModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockGetPeers.mockReset();
    mockListVirtualIps.mockReset();
    mockCreatePortMapping.mockReset();
    mockUpdatePortMapping.mockReset();

    // Default: happy-path API responses
    mockGetPeers.mockReturnValue(peersResult());
    mockListVirtualIps.mockReturnValue(vipsResult());
  });

  // ---------------------------------------------------------------------------
  // Render + initial state
  // ---------------------------------------------------------------------------

  it('renders the modal with create title when no mapping is provided', async () => {
    renderModal();
    expect(screen.getByTestId('modal-title')).toHaveTextContent('New port mapping');
  });

  it('renders the modal with edit title when a mapping is provided', async () => {
    renderModal({ mapping: EXISTING_MAPPING });
    expect(screen.getByTestId('modal-title')).toHaveTextContent(
      `Edit port mapping — ${EXISTING_MAPPING.name}`,
    );
  });

  it('renders all form field labels', async () => {
    renderModal();
    expect(screen.getByText('Name')).toBeInTheDocument();
    expect(screen.getByText('Description')).toBeInTheDocument();
    expect(screen.getByText('Hub peer')).toBeInTheDocument();
    expect(screen.getByText('Protocol')).toBeInTheDocument();
    expect(screen.getByText('Listen port')).toBeInTheDocument();
    expect(screen.getByText(/Target port/)).toBeInTheDocument();
    expect(screen.getByText('Target type')).toBeInTheDocument();
  });

  it('renders Cancel and Create mapping buttons in create mode', async () => {
    renderModal();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /create mapping/i })).toBeInTheDocument();
  });

  it('renders Save changes button in edit mode', async () => {
    renderModal({ mapping: EXISTING_MAPPING });
    expect(screen.getByRole('button', { name: /save changes/i })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Initial data loading
  // ---------------------------------------------------------------------------

  it('fetches peers and VIPs for the given networkId on mount', async () => {
    renderModal({ networkId: 'net-xyz' });
    await waitFor(() => expect(mockGetPeers).toHaveBeenCalledWith('net-xyz'));
    expect(mockListVirtualIps).toHaveBeenCalledWith('net-xyz');
  });

  it('shows hub peers in the hub peer dropdown (only publicly_reachable)', async () => {
    renderModal();
    // Wait for peers to load (both peer IDs appear across the two select elements)
    await waitFor(() => {
      const options = screen.getAllByRole('option');
      const values = options.map((o) => o.getAttribute('value') ?? '');
      expect(values).toContain('peer-hub-001');
    });

    // The hub peer select is the first combobox.
    // Only HUB_PEER (publicly_reachable: true) should appear in it.
    // SPOKE_PEER is not publicly_reachable — it must not be in the hub select.
    const hubSelect = screen.getAllByRole('combobox')[0] as HTMLSelectElement;
    const hubOptionValues = Array.from(hubSelect.options).map((o) => o.value);
    expect(hubOptionValues).toContain('peer-hub-001');
    expect(hubOptionValues).not.toContain('peer-spoke-002');
  });

  it('shows a warning when there are no publicly reachable peers', async () => {
    mockGetPeers.mockReturnValue(Promise.resolve({ peers: [SPOKE_PEER] }));
    renderModal();
    await waitFor(() =>
      expect(screen.getByText(/No hubs available/)).toBeInTheDocument(),
    );
  });

  it('shows all peers in the target peer dropdown', async () => {
    renderModal();
    await waitFor(() => {
      const options = screen.getAllByRole('option');
      const hubOption = options.find((o) => o.getAttribute('value') === 'peer-hub-001');
      const spokeOption = options.find((o) => o.getAttribute('value') === 'peer-spoke-002');
      expect(hubOption).toBeDefined();
      expect(spokeOption).toBeDefined();
    });
  });

  it('handles peer fetch failure gracefully (empty list)', async () => {
    mockGetPeers.mockReturnValue(Promise.reject(new Error('network error')));
    renderModal();
    await waitFor(() =>
      expect(screen.getByText(/No hubs available/)).toBeInTheDocument(),
    );
  });

  it('handles VIP fetch failure gracefully (empty list)', async () => {
    mockListVirtualIps.mockReturnValue(Promise.reject(new Error('network error')));
    renderModal();

    // Switch to VIP target type
    const vipRadio = screen.getByLabelText(/virtual ip/i);
    fireEvent.click(vipRadio);

    await waitFor(() =>
      expect(screen.getByText(/No VIPs in this network/)).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Edit mode pre-population
  // ---------------------------------------------------------------------------

  it('pre-populates fields with values from the existing mapping', async () => {
    renderModal({ mapping: EXISTING_MAPPING });

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    // Name field
    expect(screen.getByDisplayValue('existing-map')).toBeInTheDocument();
    // Description
    expect(screen.getByDisplayValue('existing description')).toBeInTheDocument();
    // Listen port
    expect(screen.getByDisplayValue('8080')).toBeInTheDocument();
    // Target port
    expect(screen.getByDisplayValue('9090')).toBeInTheDocument();
  });

  it('pre-selects hub peer from existing mapping', async () => {
    renderModal({ mapping: EXISTING_MAPPING });

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    // Find the hub peer select (first combobox after "Hub peer" label)
    const selects = screen.getAllByRole('combobox');
    const hubSelect = selects[0]; // Hub peer select
    expect(hubSelect).toHaveValue('peer-hub-001');
  });

  it('pre-selects protocol from existing mapping', async () => {
    renderModal({ mapping: EXISTING_MAPPING });

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    // EXISTING_MAPPING has protocol: 'udp' — find the combobox with that value.
    // The protocol select is the second combobox (after hub peer).
    const allSelects = screen.getAllByRole('combobox');
    const protocolBox = allSelects.find(
      (s) => (s as HTMLSelectElement).value === 'udp',
    );
    expect(protocolBox).toBeDefined();
    expect((protocolBox as HTMLSelectElement).value).toBe('udp');
  });

  it('defaults to target_type=virtual_ip when mapping has target_virtual_ip_id', async () => {
    renderModal({ mapping: EXISTING_VIP_MAPPING });

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    // VIP radio should be checked
    const vipRadio = screen.getByLabelText(/virtual ip/i);
    expect(vipRadio).toBeChecked();
  });

  // ---------------------------------------------------------------------------
  // Target type switching
  // ---------------------------------------------------------------------------

  it('defaults to "Specific peer" target type in create mode', () => {
    renderModal();
    const peerRadio = screen.getByLabelText(/specific peer/i);
    expect(peerRadio).toBeChecked();
  });

  it('shows Target peer dropdown when target type is "peer"', () => {
    renderModal();
    expect(screen.getByText('Target peer')).toBeInTheDocument();
    expect(screen.queryByText('Target virtual IP')).not.toBeInTheDocument();
  });

  it('switches to Target virtual IP dropdown when VIP radio is clicked', () => {
    renderModal();
    const vipRadio = screen.getByLabelText(/virtual ip/i);
    fireEvent.click(vipRadio);
    expect(screen.getByText('Target virtual IP')).toBeInTheDocument();
    expect(screen.queryByText('Target peer')).not.toBeInTheDocument();
  });

  it('switches back to Target peer dropdown when peer radio is clicked', () => {
    renderModal();
    const vipRadio = screen.getByLabelText(/virtual ip/i);
    fireEvent.click(vipRadio);
    const peerRadio = screen.getByLabelText(/specific peer/i);
    fireEvent.click(peerRadio);
    expect(screen.getByText('Target peer')).toBeInTheDocument();
    expect(screen.queryByText('Target virtual IP')).not.toBeInTheDocument();
  });

  it('shows VIPs in the target VIP dropdown', async () => {
    renderModal();
    const vipRadio = screen.getByLabelText(/virtual ip/i);
    fireEvent.click(vipRadio);
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /db-vip/ })).toBeInTheDocument(),
    );
  });

  it('shows "No VIPs in this network" warning when VIP list is empty', async () => {
    mockListVirtualIps.mockReturnValue(Promise.resolve({ virtual_ips: [], count: 0 }));
    renderModal();
    const vipRadio = screen.getByLabelText(/virtual ip/i);
    fireEvent.click(vipRadio);
    await waitFor(() =>
      expect(screen.getByText(/No VIPs in this network/)).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Protocol field
  // ---------------------------------------------------------------------------

  it('renders TCP and UDP options in the protocol dropdown', () => {
    renderModal();
    expect(screen.getByRole('option', { name: 'TCP' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'UDP' })).toBeInTheDocument();
  });

  it('defaults protocol to TCP in create mode', () => {
    renderModal();
    const allSelects = screen.getAllByRole('combobox');
    const protocolSelect = allSelects.find(
      (s) => (s as HTMLSelectElement).value === 'tcp',
    );
    expect(protocolSelect).toBeDefined();
  });

  // ---------------------------------------------------------------------------
  // Enabled checkbox
  // ---------------------------------------------------------------------------

  it('defaults the enabled checkbox to checked in create mode', () => {
    renderModal();
    const checkbox = screen.getByRole('checkbox');
    expect(checkbox).toBeChecked();
  });

  it('reflects enabled=false from the existing mapping', async () => {
    renderModal({ mapping: EXISTING_MAPPING }); // enabled: false
    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );
    const checkbox = screen.getByRole('checkbox');
    expect(checkbox).not.toBeChecked();
  });

  it('toggling the enabled checkbox changes its state', () => {
    renderModal();
    const checkbox = screen.getByRole('checkbox');
    fireEvent.click(checkbox);
    expect(checkbox).not.toBeChecked();
    fireEvent.click(checkbox);
    expect(checkbox).toBeChecked();
  });

  // ---------------------------------------------------------------------------
  // Validation — hub peer required
  // ---------------------------------------------------------------------------

  it('shows error notification when submitting without a hub peer', async () => {
    renderModal();

    // Fill in name and listen port but leave hub peer empty
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '5432' },
    });
    // Select a target peer so target validation passes
    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );
    // Explicitly pick a target peer
    const allSelects = screen.getAllByRole('combobox');
    // Target peer select is the last combobox when target type = peer
    const targetPeerSelect = allSelects[allSelects.length - 1];
    fireEvent.change(targetPeerSelect, { target: { value: 'peer-spoke-002' } });

    fireEvent.submit(screen.getByRole('button', { name: /create mapping/i }).closest('form')!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Select a hub peer (publicly reachable).',
      }),
    );
    expect(mockCreatePortMapping).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Validation — listen port
  // ---------------------------------------------------------------------------

  it('shows error notification when listen port is 0 (not filled)', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    // Select hub peer
    const hubSelect = screen.getAllByRole('combobox')[0];
    fireEvent.change(hubSelect, { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    // Leave listen port at 0 (default)

    const allSelects = screen.getAllByRole('combobox');
    const targetPeerSelect = allSelects[allSelects.length - 1];
    fireEvent.change(targetPeerSelect, { target: { value: 'peer-spoke-002' } });

    const form = screen.getByRole('button', { name: /create mapping/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Listen port must be 1-65535.',
      }),
    );
    expect(mockCreatePortMapping).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Validation — target peer required when target type is peer
  // ---------------------------------------------------------------------------

  it('shows error notification when target type is peer and no peer is selected', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    // Select hub peer and fill listen port
    const hubSelect = screen.getAllByRole('combobox')[0];
    fireEvent.change(hubSelect, { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '8080' },
    });
    // Leave target peer empty (default)

    const form = screen.getByRole('button', { name: /create mapping/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Select a target peer.',
      }),
    );
    expect(mockCreatePortMapping).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Validation — target VIP required when target type is virtual_ip
  // ---------------------------------------------------------------------------

  it('shows error notification when target type is virtual_ip and no VIP is selected', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    // Select hub peer and fill listen port
    const hubSelect = screen.getAllByRole('combobox')[0];
    fireEvent.change(hubSelect, { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '8080' },
    });

    // Switch to VIP target type but leave VIP unselected
    const vipRadio = screen.getByLabelText(/virtual ip/i);
    fireEvent.click(vipRadio);

    const form = screen.getByRole('button', { name: /create mapping/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Select a target VIP.',
      }),
    );
    expect(mockCreatePortMapping).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Submission — create mode (peer target)
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.createPortMapping with the correct payload for peer target', async () => {
    mockCreatePortMapping.mockResolvedValue(SAVED_MAPPING);
    const onSaved = jest.fn();

    renderModal({ onSaved });

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    // Fill the form
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'db-public' },
    });

    // Hub peer select is the first combobox
    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });

    // Listen port
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '5432' },
    });

    // Target peer (last combobox)
    const refreshedSelects = screen.getAllByRole('combobox');
    const targetPeerSelect = refreshedSelects[refreshedSelects.length - 1];
    fireEvent.change(targetPeerSelect, { target: { value: 'peer-spoke-002' } });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(mockCreatePortMapping).toHaveBeenCalledWith(NETWORK_ID, {
        name: 'db-public',
        description: undefined,
        sdwan_peer_id: 'peer-hub-001',
        protocol: 'tcp',
        listen_port: 5432,
        target_port: null,
        target_peer_id: 'peer-spoke-002',
        target_virtual_ip_id: null,
        enabled: true,
      }),
    );

    expect(onSaved).toHaveBeenCalledWith(SAVED_MAPPING);
  });

  it('sends description as undefined when the description field is empty', async () => {
    mockCreatePortMapping.mockResolvedValue(SAVED_MAPPING);
    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '3000' },
    });
    const refreshedSelects = screen.getAllByRole('combobox');
    fireEvent.change(refreshedSelects[refreshedSelects.length - 1], {
      target: { value: 'peer-spoke-002' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(mockCreatePortMapping).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({ description: undefined }),
      ),
    );
  });

  it('sends target_port as null when the target port field is empty', async () => {
    mockCreatePortMapping.mockResolvedValue(SAVED_MAPPING);
    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '3000' },
    });
    // Leave target port empty
    const refreshedSelects = screen.getAllByRole('combobox');
    fireEvent.change(refreshedSelects[refreshedSelects.length - 1], {
      target: { value: 'peer-spoke-002' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(mockCreatePortMapping).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({ target_port: null }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Submission — create mode (VIP target)
  // ---------------------------------------------------------------------------

  it('calls createPortMapping with target_virtual_ip_id when VIP target type is selected', async () => {
    mockCreatePortMapping.mockResolvedValue({
      ...SAVED_MAPPING,
      target_peer_id: null,
      target_virtual_ip_id: 'vip-001',
    });
    const onSaved = jest.fn();

    renderModal({ onSaved });

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'vip-port-map' },
    });

    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '443' },
    });

    // Switch to VIP target
    const vipRadio = screen.getByLabelText(/virtual ip/i);
    fireEvent.click(vipRadio);

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /db-vip/ })).toBeInTheDocument(),
    );

    const refreshedSelects = screen.getAllByRole('combobox');
    // VIP select is now the last combobox
    const vipSelect = refreshedSelects[refreshedSelects.length - 1];
    fireEvent.change(vipSelect, { target: { value: 'vip-001' } });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(mockCreatePortMapping).toHaveBeenCalledWith(NETWORK_ID, {
        name: 'vip-port-map',
        description: undefined,
        sdwan_peer_id: 'peer-hub-001',
        protocol: 'tcp',
        listen_port: 443,
        target_port: null,
        target_peer_id: null,
        target_virtual_ip_id: 'vip-001',
        enabled: true,
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Submission — edit mode
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.updatePortMapping with the correct payload in edit mode', async () => {
    const updatedMapping = { ...EXISTING_MAPPING, name: 'renamed' };
    mockUpdatePortMapping.mockResolvedValue(updatedMapping);
    const onSaved = jest.fn();

    renderModal({ mapping: EXISTING_MAPPING, onSaved });

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(mockUpdatePortMapping).toHaveBeenCalledWith(
        NETWORK_ID,
        EXISTING_MAPPING.id,
        expect.objectContaining({
          sdwan_peer_id: 'peer-hub-001',
          listen_port: 8080,
          protocol: 'udp',
          enabled: false,
        }),
      ),
    );

    expect(onSaved).toHaveBeenCalledWith(updatedMapping);
    expect(mockCreatePortMapping).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Submission — error path
  // ---------------------------------------------------------------------------

  it('shows an error notification when createPortMapping fails with an Error instance', async () => {
    mockCreatePortMapping.mockRejectedValue(new Error('Server error'));

    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '3000' },
    });
    const refreshedSelects = screen.getAllByRole('combobox');
    fireEvent.change(refreshedSelects[refreshedSelects.length - 1], {
      target: { value: 'peer-spoke-002' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Server error',
      }),
    );
  });

  it('shows a generic error notification when createPortMapping fails with non-Error', async () => {
    mockCreatePortMapping.mockRejectedValue('unknown');

    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '3000' },
    });
    const refreshedSelects = screen.getAllByRole('combobox');
    fireEvent.change(refreshedSelects[refreshedSelects.length - 1], {
      target: { value: 'peer-spoke-002' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Save failed',
      }),
    );
  });

  it('does not call onSaved when creation fails', async () => {
    mockCreatePortMapping.mockRejectedValue(new Error('oops'));
    const onSaved = jest.fn();

    renderModal({ onSaved });

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '3000' },
    });
    const refreshedSelects = screen.getAllByRole('combobox');
    fireEvent.change(refreshedSelects[refreshedSelects.length - 1], {
      target: { value: 'peer-spoke-002' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onSaved).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Button state during submission
  // ---------------------------------------------------------------------------

  it('shows "Saving…" on the submit button while in-flight', async () => {
    let resolve!: (v: SdwanPortMapping) => void;
    mockCreatePortMapping.mockReturnValue(
      new Promise<SdwanPortMapping>((r) => {
        resolve = r;
      }),
    );

    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '3000' },
    });
    const refreshedSelects = screen.getAllByRole('combobox');
    fireEvent.change(refreshedSelects[refreshedSelects.length - 1], {
      target: { value: 'peer-spoke-002' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(screen.getByText('Saving…')).toBeInTheDocument(),
    );

    resolve(SAVED_MAPPING);
    await waitFor(() =>
      expect(screen.queryByText('Saving…')).not.toBeInTheDocument(),
    );
  });

  it('disables the submit button while in-flight', async () => {
    let resolve!: (v: SdwanPortMapping) => void;
    mockCreatePortMapping.mockReturnValue(
      new Promise<SdwanPortMapping>((r) => {
        resolve = r;
      }),
    );

    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '3000' },
    });
    const refreshedSelects = screen.getAllByRole('combobox');
    fireEvent.change(refreshedSelects[refreshedSelects.length - 1], {
      target: { value: 'peer-spoke-002' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(screen.getByText('Saving…').closest('button')).toBeDisabled(),
    );

    resolve(SAVED_MAPPING);
    await waitFor(() =>
      expect(screen.queryByText('Saving…')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when the Cancel button is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(mockCreatePortMapping).not.toHaveBeenCalled();
  });

  it('calls onClose when the modal close button is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.click(screen.getByTestId('modal-close'));

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Payload details
  // ---------------------------------------------------------------------------

  it('sends enabled=false when the enabled checkbox is unchecked before submit', async () => {
    mockCreatePortMapping.mockResolvedValue(SAVED_MAPPING);
    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '3000' },
    });
    const refreshedSelects = screen.getAllByRole('combobox');
    fireEvent.change(refreshedSelects[refreshedSelects.length - 1], {
      target: { value: 'peer-spoke-002' },
    });

    fireEvent.click(screen.getByRole('checkbox')); // uncheck enabled

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(mockCreatePortMapping).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({ enabled: false }),
      ),
    );
  });

  it('sends target_peer_id=null and target_virtual_ip_id set when VIP target is used', async () => {
    mockCreatePortMapping.mockResolvedValue({
      ...SAVED_MAPPING,
      target_peer_id: null,
      target_virtual_ip_id: 'vip-001',
    });
    renderModal();

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'vip-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '443' },
    });

    const vipRadio = screen.getByLabelText(/virtual ip/i);
    fireEvent.click(vipRadio);

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /db-vip/ })).toBeInTheDocument(),
    );

    const updatedSelects = screen.getAllByRole('combobox');
    fireEvent.change(updatedSelects[updatedSelects.length - 1], {
      target: { value: 'vip-001' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(mockCreatePortMapping).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({
          target_peer_id: null,
          target_virtual_ip_id: 'vip-001',
        }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Pending-approval branch (IMP-87ec6f651f07)
  // ---------------------------------------------------------------------------

  it('shows the pending-approval notification, closes, and skips onSaved when the create is parked', async () => {
    mockCreatePortMapping.mockResolvedValue({
      pending: true,
      deferred_operation_id: 'dop-1',
      action_category: 'sdwan.port_mapping_create',
      approval_request_id: 'ar-1',
      message: 'Approval required',
    });
    const onSaved = jest.fn();
    const onClose = jest.fn();

    renderModal({ onSaved, onClose });

    await waitFor(() =>
      expect(
        screen.getAllByRole('option', { name: /peer-hub/ }).length,
      ).toBeGreaterThan(0),
    );

    const allSelects = screen.getAllByRole('combobox');
    fireEvent.change(allSelects[0], { target: { value: 'peer-hub-001' } });
    fireEvent.change(screen.getByPlaceholderText('e.g. db-public'), {
      target: { value: 'my-map' },
    });
    fireEvent.change(screen.getByPlaceholderText('5432'), {
      target: { value: '3000' },
    });
    const refreshedSelects = screen.getAllByRole('combobox');
    fireEvent.change(refreshedSelects[refreshedSelects.length - 1], {
      target: { value: 'peer-spoke-002' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create mapping/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringContaining('my-map'),
          link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
        }),
      ),
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' }),
    );
    expect(onSaved).not.toHaveBeenCalled();
    expect(onClose).toHaveBeenCalled();
  });
});
