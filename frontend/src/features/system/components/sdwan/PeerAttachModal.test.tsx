import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { PeerAttachModal } from './PeerAttachModal';

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

// Modal: render children only when isOpen so jsdom can query normally.
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

// Button: render a real <button> so role queries + disabled work.
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

// sdwanApi facade — attachPeer is the only method used by this component.
const mockAttachPeer = jest.fn();
jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    attachPeer: (...args: unknown[]) => mockAttachPeer(...args),
  },
}));

// systemApi facade — getNodes + getNodeInstances are used for the instance dropdown.
const mockGetNodes = jest.fn();
const mockGetNodeInstances = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getNodes: (...args: unknown[]) => mockGetNodes(...args),
    getNodeInstances: (...args: unknown[]) => mockGetNodeInstances(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_ID = 'net-sdwan-001';

const NODE_A = {
  id: 'node-a',
  name: 'node-alpha',
  enabled: true,
  allocate_public_ip: false,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const NODE_B = {
  id: 'node-b',
  name: 'node-beta',
  enabled: true,
  allocate_public_ip: false,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const INSTANCE_A: { id: string; name: string; status: string; node_id: string; variety: 'cloud'; config: Record<string, unknown>; created_at: string; updated_at: string } = {
  id: 'inst-a1',
  name: 'alpha-instance-1',
  status: 'running',
  node_id: 'node-a',
  variety: 'cloud',
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const INSTANCE_B: { id: string; name: string; status: string; node_id: string; variety: 'cloud'; config: Record<string, unknown>; created_at: string; updated_at: string } = {
  id: 'inst-b1',
  name: 'beta-instance-1',
  status: 'stopped',
  node_id: 'node-b',
  variety: 'cloud',
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PEER_RESULT = {
  id: 'peer-xyz',
  network_id: NETWORK_ID,
  node_instance_id: INSTANCE_A.id,
  publicly_reachable: false,
  status: 'active',
  created_at: '2026-06-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
};

// systemApi.getNodes and getNodeInstances resolve to their own shapes
// (not double-envelope — the api facade already strips the HTTP envelope).
function nodesResponse(nodes = [NODE_A, NODE_B]) {
  return Promise.resolve({
    nodes,
    meta: {
      current_page: 1,
      per_page: 50,
      total_count: nodes.length,
      total_pages: 1,
      next_page: null,
      prev_page: null,
    },
  });
}

function instancesResponse(instances: typeof INSTANCE_A[]) {
  return Promise.resolve({ node_instances: instances });
}

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  networkId?: string;
  onClose?: () => void;
  onAttached?: () => void;
}

function renderModal({
  isOpen = true,
  networkId = NETWORK_ID,
  onClose = jest.fn(),
  onAttached = jest.fn(),
}: RenderProps = {}) {
  return render(
    <PeerAttachModal
      isOpen={isOpen}
      networkId={networkId}
      onClose={onClose}
      onAttached={onAttached}
    />,
  );
}

// Convenience selectors
function getInstanceSelect() {
  return screen.getByRole('combobox');
}

function getHubCheckbox() {
  return screen.getByRole('checkbox');
}

function getAttachButton() {
  return screen.getByRole('button', { name: /^attach$/i });
}

function getCancelButton() {
  return screen.getByRole('button', { name: /cancel/i });
}

// The Port label has no htmlFor so getByLabelText doesn't work.
// Use getByRole('spinbutton') which matches <input type="number">.
function getPortInput() {
  return screen.getByRole('spinbutton');
}

// =============================================================================
// Tests
// =============================================================================

describe('PeerAttachModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockAttachPeer.mockReset();
    mockGetNodes.mockReset();
    mockGetNodeInstances.mockReset();

    // Default: two nodes, one instance each
    mockGetNodes.mockReturnValue(nodesResponse());
    mockGetNodeInstances.mockImplementation((nodeId: string) => {
      if (nodeId === 'node-a') return instancesResponse([INSTANCE_A]);
      if (nodeId === 'node-b') return instancesResponse([INSTANCE_B]);
      return instancesResponse([]);
    });
  });

  // ---------------------------------------------------------------------------
  // Visibility
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
  });

  it('renders the modal with the correct title when isOpen is true', () => {
    renderModal();
    expect(screen.getByTestId('modal')).toBeInTheDocument();
    expect(screen.getByTestId('modal-title')).toHaveTextContent(
      'Attach peer to network',
    );
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows "Loading…" placeholder in the select while instances are loading', () => {
    // Keep getNodes pending
    let resolveNodes!: (v: unknown) => void;
    mockGetNodes.mockReturnValue(new Promise((r) => { resolveNodes = r; }));

    renderModal();

    expect(getInstanceSelect()).toHaveTextContent('Loading…');

    // Resolve to avoid act() warning
    resolveNodes({
      nodes: [],
      meta: { current_page: 1, per_page: 50, total_count: 0, total_pages: 1, next_page: null, prev_page: null },
    });
  });

  it('disables the instance select while instances are loading', () => {
    let resolveNodes!: (v: unknown) => void;
    mockGetNodes.mockReturnValue(new Promise((r) => { resolveNodes = r; }));

    renderModal();

    expect(getInstanceSelect()).toBeDisabled();

    resolveNodes({
      nodes: [],
      meta: { current_page: 1, per_page: 50, total_count: 0, total_pages: 1, next_page: null, prev_page: null },
    });
  });

  it('populates the select with all instances after loading', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );
    expect(screen.getByRole('option', { name: /beta-instance-1/i })).toBeInTheDocument();
  });

  it('renders instance options with name and status in parentheses', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /alpha-instance-1 \(running\)/i }),
      ).toBeInTheDocument(),
    );
    expect(
      screen.getByRole('option', { name: /beta-instance-1 \(stopped\)/i }),
    ).toBeInTheDocument();
  });

  it('calls systemApi.getNodes with per_page 50 when the modal opens', async () => {
    renderModal();

    await waitFor(() =>
      expect(mockGetNodes).toHaveBeenCalledWith({ per_page: 50 }),
    );
  });

  it('calls systemApi.getNodeInstances for each node returned', async () => {
    renderModal();

    await waitFor(() => {
      expect(mockGetNodeInstances).toHaveBeenCalledWith('node-a');
      expect(mockGetNodeInstances).toHaveBeenCalledWith('node-b');
    });
  });

  it('shows an error notification when loading instances fails', async () => {
    mockGetNodes.mockRejectedValue(new Error('network error'));

    renderModal();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load node instances',
      }),
    );
  });

  it('does NOT fetch instances when the modal is closed (isOpen=false)', () => {
    renderModal({ isOpen: false });
    expect(mockGetNodes).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Initial field state
  // ---------------------------------------------------------------------------

  it('initialises the instance select with the placeholder option selected', async () => {
    renderModal();

    // The select starts on the placeholder (empty value)
    expect(getInstanceSelect()).toHaveValue('');
  });

  it('initialises the "publicly reachable" checkbox as unchecked', () => {
    renderModal();
    expect(getHubCheckbox()).not.toBeChecked();
  });

  it('does not show the hub endpoint fields by default (spoke mode)', () => {
    renderModal();
    expect(screen.queryByLabelText(/ipv6 endpoint host/i)).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/ipv4 endpoint host/i)).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/port/i)).not.toBeInTheDocument();
  });

  it('renders the Attach button disabled when no instance is selected', () => {
    renderModal();
    expect(getAttachButton()).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Hub mode toggle
  // ---------------------------------------------------------------------------

  it('reveals the endpoint fields when the hub checkbox is checked', async () => {
    renderModal();

    fireEvent.click(getHubCheckbox());

    expect(
      screen.getByPlaceholderText('2001:db8::1 or hub.v6.example.com'),
    ).toBeInTheDocument();
    expect(
      screen.getByPlaceholderText('203.0.113.10 or hub.example.com'),
    ).toBeInTheDocument();
    // Port field appears — the label has no htmlFor so use role spinbutton.
    expect(getPortInput()).toBeInTheDocument();
  });

  it('defaults the port field to 51820', async () => {
    renderModal();

    fireEvent.click(getHubCheckbox());

    expect(getPortInput()).toHaveValue(51820);
  });

  it('hides the endpoint fields again after unchecking the hub checkbox', () => {
    renderModal();

    fireEvent.click(getHubCheckbox());
    expect(
      screen.getByPlaceholderText('2001:db8::1 or hub.v6.example.com'),
    ).toBeInTheDocument();

    fireEvent.click(getHubCheckbox());
    expect(
      screen.queryByPlaceholderText('2001:db8::1 or hub.v6.example.com'),
    ).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Attach button enable / disable based on selection
  // ---------------------------------------------------------------------------

  it('enables the Attach button once an instance is selected', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    expect(getAttachButton()).not.toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  it('shows an error when submitting without selecting an instance', async () => {
    renderModal();

    const form = screen.getByTestId('modal').querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Pick a node instance to attach',
      }),
    );
    expect(mockAttachPeer).not.toHaveBeenCalled();
  });

  it('shows an error when hub mode is on but both endpoint hosts are empty', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getHubCheckbox());

    // Port is already populated, but both host fields are empty
    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Hub peers need at least one endpoint (v6 or v4)',
      }),
    );
    expect(mockAttachPeer).not.toHaveBeenCalled();
  });

  it('shows an error when hub mode is on with a host but no port', async () => {
    // This test patches the number input's value via a property descriptor
    // before firing the change event. jsdom's synthetic event system does
    // NOT update a controlled <input type="number"> via the simple
    // { target: { value } } shorthand, so we have to manipulate the input's
    // nativeEvent target directly before dispatching.
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getHubCheckbox());

    fireEvent.change(
      screen.getByPlaceholderText('2001:db8::1 or hub.v6.example.com'),
      { target: { value: '2001:db8::1' } },
    );

    // To reliably set the port to 0, we define the property on the input
    // element before firing the change event so React's synthetic handler
    // sees value '0' and calls setEndpointPort(0).
    const portInput = getPortInput();
    Object.defineProperty(portInput, 'value', {
      writable: true,
      configurable: true,
      value: '0',
    });
    fireEvent.change(portInput);

    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Hub peers require an endpoint port',
      }),
    );
    expect(mockAttachPeer).not.toHaveBeenCalled();
  });

  it('passes validation when hub mode has only the v4 host filled in', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getHubCheckbox());

    fireEvent.change(
      screen.getByPlaceholderText('203.0.113.10 or hub.example.com'),
      { target: { value: '203.0.113.10' } },
    );
    // Port keeps default 51820

    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAttachPeer).toHaveBeenCalledTimes(1),
    );
  });

  // ---------------------------------------------------------------------------
  // Spoke-mode submit (publiclyReachable = false)
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.attachPeer with the correct payload for spoke mode', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);

    renderModal({ networkId: NETWORK_ID });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAttachPeer).toHaveBeenCalledWith(NETWORK_ID, {
        node_instance_id: INSTANCE_A.id,
        publicly_reachable: false,
        endpoint_host_v6: undefined,
        endpoint_host_v4: undefined,
        endpoint_port: undefined,
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Hub-mode submit (publiclyReachable = true)
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.attachPeer with v6 host, v4 host, and port in hub mode', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);

    renderModal({ networkId: NETWORK_ID });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getHubCheckbox());

    fireEvent.change(
      screen.getByPlaceholderText('2001:db8::1 or hub.v6.example.com'),
      { target: { value: '  2001:db8::1  ' } },
    );
    fireEvent.change(
      screen.getByPlaceholderText('203.0.113.10 or hub.example.com'),
      { target: { value: '  203.0.113.10  ' } },
    );
    fireEvent.change(getPortInput(), { target: { value: '51820' } });

    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAttachPeer).toHaveBeenCalledWith(NETWORK_ID, {
        node_instance_id: INSTANCE_A.id,
        publicly_reachable: true,
        endpoint_host_v6: '2001:db8::1',
        endpoint_host_v4: '203.0.113.10',
        endpoint_port: 51820,
      }),
    );
  });

  it('strips whitespace from endpoint hosts before sending', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getHubCheckbox());

    fireEvent.change(
      screen.getByPlaceholderText('2001:db8::1 or hub.v6.example.com'),
      { target: { value: '   hub.v6.example.com   ' } },
    );

    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAttachPeer).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({ endpoint_host_v6: 'hub.v6.example.com' }),
      ),
    );
  });

  it('sends endpoint_host_v6 as undefined when only v4 is provided in hub mode', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getHubCheckbox());

    fireEvent.change(
      screen.getByPlaceholderText('203.0.113.10 or hub.example.com'),
      { target: { value: '203.0.113.10' } },
    );

    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAttachPeer).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({
          endpoint_host_v6: undefined,
          endpoint_host_v4: '203.0.113.10',
        }),
      ),
    );
  });

  it('sends endpoint_host_v4 as undefined when only v6 is provided in hub mode', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getHubCheckbox());

    fireEvent.change(
      screen.getByPlaceholderText('2001:db8::1 or hub.v6.example.com'),
      { target: { value: '2001:db8::1' } },
    );

    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAttachPeer).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({
          endpoint_host_v6: '2001:db8::1',
          endpoint_host_v4: undefined,
        }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Successful submission callbacks
  // ---------------------------------------------------------------------------

  it('fires onAttached after a successful attach', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);
    const onAttached = jest.fn();

    renderModal({ onAttached });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() => expect(onAttached).toHaveBeenCalledTimes(1));
  });

  it('fires onClose after a successful attach', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);
    const onClose = jest.fn();

    renderModal({ onClose });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
  });

  it('shows a success notification after a successful attach', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Peer attached',
      }),
    );
  });

  it('resets form state after a successful attach', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);
    const onClose = jest.fn();

    renderModal({ onClose });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getHubCheckbox());
    fireEvent.change(
      screen.getByPlaceholderText('2001:db8::1 or hub.v6.example.com'),
      { target: { value: '2001:db8::1' } },
    );

    fireEvent.click(getAttachButton());

    await waitFor(() => expect(onClose).toHaveBeenCalled());

    // Select is back to placeholder
    expect(getInstanceSelect()).toHaveValue('');
    // Hub checkbox is unchecked
    expect(getHubCheckbox()).not.toBeChecked();
  });

  // ---------------------------------------------------------------------------
  // In-flight / submitting state
  // ---------------------------------------------------------------------------

  it('shows "Attaching…" on the submit button while the request is in-flight', async () => {
    let resolveFn!: (v: unknown) => void;
    mockAttachPeer.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /attaching…/i })).toBeInTheDocument(),
    );

    resolveFn(PEER_RESULT);
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /attaching…/i })).not.toBeInTheDocument(),
    );
  });

  it('disables the Cancel button while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockAttachPeer.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() => expect(getCancelButton()).toBeDisabled());

    resolveFn(PEER_RESULT);
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /attaching…/i })).not.toBeInTheDocument(),
    );
  });

  it('disables the instance select while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockAttachPeer.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() => expect(getInstanceSelect()).toBeDisabled());

    resolveFn(PEER_RESULT);
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /attaching…/i })).not.toBeInTheDocument(),
    );
  });

  it('disables the hub endpoint inputs while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockAttachPeer.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getHubCheckbox());
    fireEvent.change(
      screen.getByPlaceholderText('2001:db8::1 or hub.v6.example.com'),
      { target: { value: '2001:db8::1' } },
    );

    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(screen.getByPlaceholderText('2001:db8::1 or hub.v6.example.com')).toBeDisabled(),
    );

    resolveFn(PEER_RESULT);
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /attaching…/i })).not.toBeInTheDocument(),
    );
  });

  it('ignores handleClose while submitting', async () => {
    let resolveFn!: (v: unknown) => void;
    mockAttachPeer.mockReturnValue(new Promise((r) => { resolveFn = r; }));
    const onClose = jest.fn();

    renderModal({ onClose });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() => expect(getCancelButton()).toBeDisabled());

    // Clicking Cancel when disabled should not fire onClose
    fireEvent.click(getCancelButton());
    expect(onClose).not.toHaveBeenCalled();

    resolveFn(PEER_RESULT);
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1)); // fired by success path
  });

  // ---------------------------------------------------------------------------
  // Error path
  // ---------------------------------------------------------------------------

  it('shows an error notification with the Error message when attach fails', async () => {
    mockAttachPeer.mockRejectedValue(new Error('Conflict: already attached'));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Conflict: already attached',
      }),
    );
  });

  it('shows "Failed to attach peer" when attach throws a non-Error value', async () => {
    mockAttachPeer.mockRejectedValue('something went wrong');

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to attach peer',
      }),
    );
  });

  it('does not call onAttached or onClose when attach fails', async () => {
    mockAttachPeer.mockRejectedValue(new Error('server error'));
    const onAttached = jest.fn();
    const onClose = jest.fn();

    renderModal({ onAttached, onClose });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onAttached).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('re-enables the Attach button after a failed submission', async () => {
    mockAttachPeer.mockRejectedValue(new Error('server error'));

    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getAttachButton());

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    // nodeInstanceId still set, so disabled={false}
    expect(getAttachButton()).not.toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Cancel / Close behaviour
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel is clicked and not submitting', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    // Wait for modal to be fully ready
    await waitFor(() => expect(getCancelButton()).not.toBeDisabled());

    fireEvent.click(getCancelButton());

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(mockAttachPeer).not.toHaveBeenCalled();
  });

  it('resets form fields when Cancel is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });
    fireEvent.click(getHubCheckbox());

    fireEvent.click(getCancelButton());

    // Select reverts to placeholder
    expect(getInstanceSelect()).toHaveValue('');
    // Hub checkbox unchecked
    expect(getHubCheckbox()).not.toBeChecked();
    // Hub endpoint fields hidden
    expect(
      screen.queryByPlaceholderText('2001:db8::1 or hub.v6.example.com'),
    ).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Form-level submit (native onSubmit)
  // ---------------------------------------------------------------------------

  it('submitting the form element directly triggers the same flow as the button', async () => {
    mockAttachPeer.mockResolvedValue(PEER_RESULT);
    const onClose = jest.fn();

    renderModal({ onClose });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /alpha-instance-1/i })).toBeInTheDocument(),
    );

    fireEvent.change(getInstanceSelect(), { target: { value: INSTANCE_A.id } });

    const form = screen.getByTestId('modal').querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(mockAttachPeer).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Hub checkbox label text
  // ---------------------------------------------------------------------------

  it('renders the hub checkbox label text describing hub behaviour', () => {
    renderModal();
    expect(
      screen.getByText(/publicly reachable \(hub\)/i),
    ).toBeInTheDocument();
  });

  it('renders the spoke-mode explainer text below the hub checkbox', () => {
    renderModal();
    expect(
      screen.getByText(/networks with no hub are isolated until one is attached/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Dual-stack endpoint help text
  // ---------------------------------------------------------------------------

  it('renders the "Provide at least one" helper text in hub mode', () => {
    renderModal();
    fireEvent.click(getHubCheckbox());
    expect(
      screen.getByText(/provide at least one\. both = v6 preferred with v4 fallback/i),
    ).toBeInTheDocument();
  });
});
