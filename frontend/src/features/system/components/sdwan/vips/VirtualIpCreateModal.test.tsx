import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { VirtualIpCreateModal } from './VirtualIpCreateModal';

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

const mockGetPeers = jest.fn();
const mockCreateVirtualIp = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    getPeers: (...args: unknown[]) => mockGetPeers(...args),
    createVirtualIp: (...args: unknown[]) => mockCreateVirtualIp(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_ID = 'net-abc-123';

const PEER_HUB = {
  id: 'peer-hub-001',
  network_id: NETWORK_ID,
  node_instance_id: 'inst-aabbcc',
  assigned_address: 'fd00::1',
  publicly_reachable: true,
  listen_port: 51820,
  status: 'active' as const,
};

const PEER_SPOKE = {
  id: 'peer-spoke-002',
  network_id: NETWORK_ID,
  node_instance_id: 'inst-ddeeff',
  assigned_address: 'fd00::2',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'active' as const,
};

const PEER_SPOKE_2 = {
  id: 'peer-spoke-003',
  network_id: NETWORK_ID,
  node_instance_id: 'inst-001122',
  assigned_address: 'fd00::3',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'active' as const,
};

const CREATED_VIP = {
  id: 'vip-001',
  network_id: NETWORK_ID,
  name: 'webapp-vip',
  cidr: '192.0.2.42/32',
  anycast: false,
  state: 'pending' as const,
  holder_peer_ids: [PEER_HUB.id],
  failover_holder_peer_ids: [],
  advertised_med: 0,
  advertised_local_pref: 100,
  tags: [],
};

// sdwanApi facade resolves to the unwrapped value — no HTTP envelope needed.
function resolvedPeers(peers = [PEER_HUB, PEER_SPOKE, PEER_SPOKE_2]) {
  return Promise.resolve({ peers });
}

function resolvedVip(vip = CREATED_VIP) {
  return Promise.resolve(vip);
}

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  networkId?: string;
  onClose?: () => void;
  onCreated?: (vip: typeof CREATED_VIP) => void;
}

function renderModal({
  networkId = NETWORK_ID,
  onClose = jest.fn(),
  onCreated = jest.fn(),
}: RenderProps = {}) {
  return render(
    <VirtualIpCreateModal
      networkId={networkId}
      onClose={onClose}
      onCreated={onCreated}
    />,
  );
}

// Helper to fill in the minimum required fields for a unicast submit.
async function fillUnicastForm({
  name = 'webapp-vip',
  cidr = '192.0.2.42/32',
}: { name?: string; cidr?: string } = {}) {
  fireEvent.change(screen.getByPlaceholderText('e.g. webapp-vip'), {
    target: { value: name },
  });
  fireEvent.change(screen.getByPlaceholderText('192.0.2.42/32 or fdXX::/128'), {
    target: { value: cidr },
  });

  // Select the first peer as primary holder
  await waitFor(() =>
    expect(screen.getByRole('combobox')).not.toBeDisabled(),
  );
  fireEvent.change(screen.getByRole('combobox'), {
    target: { value: PEER_HUB.id },
  });
}

// =============================================================================
// Tests
// =============================================================================

describe('VirtualIpCreateModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockGetPeers.mockReset();
    mockCreateVirtualIp.mockReset();
    mockGetPeers.mockReturnValue(resolvedPeers());
  });

  // ---------------------------------------------------------------------------
  // Render / mount
  // ---------------------------------------------------------------------------

  it('renders the modal with the correct title', () => {
    renderModal();
    expect(screen.getByTestId('modal-title')).toHaveTextContent('Create Virtual IP');
  });

  it('renders the Name field', () => {
    renderModal();
    expect(screen.getByPlaceholderText('e.g. webapp-vip')).toBeInTheDocument();
  });

  it('renders the CIDR field', () => {
    renderModal();
    expect(screen.getByPlaceholderText('192.0.2.42/32 or fdXX::/128')).toBeInTheDocument();
  });

  it('renders the Description field', () => {
    renderModal();
    expect(screen.getByText('Description')).toBeInTheDocument();
  });

  it('renders the Anycast checkbox', () => {
    renderModal();
    expect(screen.getByLabelText(/anycast mode/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/anycast mode/i)).not.toBeChecked();
  });

  it('renders the Cancel and Create Virtual IP buttons', () => {
    renderModal();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /create virtual ip/i })).toBeInTheDocument();
  });

  it('fetches peers for the given networkId on mount', async () => {
    renderModal({ networkId: NETWORK_ID });
    await waitFor(() =>
      expect(mockGetPeers).toHaveBeenCalledWith(NETWORK_ID),
    );
  });

  // ---------------------------------------------------------------------------
  // Unicast mode (anycast = false) — initial state
  // ---------------------------------------------------------------------------

  it('shows the Primary holder select when anycast is unchecked', async () => {
    renderModal();
    await waitFor(() =>
      expect(screen.getByRole('combobox')).toBeInTheDocument(),
    );
    expect(screen.getByText(/primary holder/i)).toBeInTheDocument();
  });

  it('populates the Primary holder select with fetched peers', async () => {
    renderModal();

    // peerOption: node_instance_id.slice(0,8) + " (hub|spoke)"
    // 'inst-aabbcc'.slice(0,8) === 'inst-aab', 'inst-ddeeff'.slice(0,8) === 'inst-dde'
    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /inst-aab.*hub/i }),
      ).toBeInTheDocument(),
    );

    // Spoke peers
    expect(
      screen.getByRole('option', { name: /inst-dde.*spoke/i }),
    ).toBeInTheDocument();
  });

  it('shows Failover candidates list (excluding the selected primary)', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByRole('combobox')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: PEER_HUB.id },
    });

    // Failover section should contain the other peers but not the primary
    expect(screen.getByText(/failover candidates/i)).toBeInTheDocument();
    // 'inst-ddeeff'.slice(0,8) === 'inst-dde'
    await waitFor(() => {
      const labels = screen.getAllByText(/inst-dde.*spoke/i);
      expect(labels.length).toBeGreaterThan(0);
    });
  });

  it('does not show the primary peer in the failover list', async () => {
    renderModal();

    // Wait for peers to load, then select hub as primary
    await waitFor(() => {
      const select = screen.getByRole('combobox');
      expect(select.children.length).toBeGreaterThan(1); // at least 1 real peer + placeholder
    });

    fireEvent.change(screen.getByRole('combobox'), { target: { value: PEER_HUB.id } });

    // The failover list filters out the selected primary (PEER_HUB).
    // Wait for the spoke peers to be visible in the failover section —
    // this confirms the filtered list has rendered.
    await waitFor(() => {
      expect(screen.getAllByText(/inst-dde \(spoke\)/i).length).toBeGreaterThan(0);
    });

    // The failover scrollable inner container (max-h-32) exclusively contains the
    // filtered peers. The outer wrapper div for the failover section starts after
    // the primary holder section. We locate the inner scroll div via its class.
    // Hub must NOT appear in the failover peer labels.
    const allSpanTexts = Array.from(document.querySelectorAll('span'))
      .map((s) => s.textContent ?? '');
    const hubInFailoverSpan = allSpanTexts.filter(
      (t) => /inst-aab \(hub\)/i.test(t),
    );
    // Hub text appears exactly once — as the selected <option> in the combobox.
    // <option> elements are not <span>s, so this count should be 0 among spans.
    expect(hubInFailoverSpan.length).toBe(0);
  });

  // ---------------------------------------------------------------------------
  // Anycast mode toggle
  // ---------------------------------------------------------------------------

  it('switches to anycast holders checklist when anycast is checked', async () => {
    renderModal();

    fireEvent.click(screen.getByLabelText(/anycast mode/i));

    await waitFor(() =>
      expect(screen.getByText(/anycast holders/i)).toBeInTheDocument(),
    );
    // The primary holder select should no longer be present
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
  });

  it('renders all peers as checkboxes in anycast mode', async () => {
    renderModal();
    fireEvent.click(screen.getByLabelText(/anycast mode/i));

    await waitFor(() =>
      expect(screen.getByText(/anycast holders/i)).toBeInTheDocument(),
    );

    // Each peer gets a checkbox in the anycast list
    const checkboxes = screen.getAllByRole('checkbox');
    // anycast checkbox + 3 peer checkboxes
    expect(checkboxes.length).toBe(4);
  });

  it('returns to primary holder select when anycast is unchecked again', async () => {
    renderModal();

    fireEvent.click(screen.getByLabelText(/anycast mode/i));
    await waitFor(() => expect(screen.queryByRole('combobox')).not.toBeInTheDocument());

    fireEvent.click(screen.getByLabelText(/anycast mode/i));
    await waitFor(() =>
      expect(screen.getByRole('combobox')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Advanced BGP fields
  // ---------------------------------------------------------------------------

  it('renders the Advanced BGP metrics section in a <details> element', () => {
    renderModal();
    expect(screen.getByText(/advanced.*bgp metrics/i)).toBeInTheDocument();
  });

  it('defaults MED to 0 and Local Preference to 100', () => {
    renderModal();
    // Open the details section
    fireEvent.click(screen.getByText(/advanced.*bgp metrics/i));
    const numberInputs = screen.getAllByRole('spinbutton');
    // MED first, then Local Preference
    expect(numberInputs[0]).toHaveValue(0);
    expect(numberInputs[1]).toHaveValue(100);
  });

  // ---------------------------------------------------------------------------
  // CIDR validation
  // ---------------------------------------------------------------------------

  it('shows an error notification when the CIDR is invalid', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText('e.g. webapp-vip'), {
      target: { value: 'my-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText('192.0.2.42/32 or fdXX::/128'), {
      target: { value: 'not-a-cidr' },
    });
    fireEvent.change(screen.getByRole('combobox'), { target: { value: PEER_HUB.id } });

    const form = screen.getByTestId('modal').querySelector('form');
    fireEvent.submit(form!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'CIDR must be a valid v4 or v6 prefix (e.g. 192.0.2.42/32).',
      }),
    );
    expect(mockCreateVirtualIp).not.toHaveBeenCalled();
  });

  it('accepts a valid IPv4 CIDR like 192.0.2.42/32', async () => {
    mockCreateVirtualIp.mockReturnValue(resolvedVip());
    renderModal();

    await fillUnicastForm({ cidr: '192.0.2.42/32' });
    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() => expect(mockCreateVirtualIp).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'error' }),
    );
  });

  it('accepts a valid IPv6 CIDR like fd00::1/128', async () => {
    mockCreateVirtualIp.mockReturnValue(resolvedVip());
    renderModal();

    await fillUnicastForm({ cidr: 'fd00::1/128' });
    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() => expect(mockCreateVirtualIp).toHaveBeenCalledTimes(1));
  });

  // ---------------------------------------------------------------------------
  // Anycast validation: requires >= 2 holders
  // ---------------------------------------------------------------------------

  it('shows an error when anycast mode has fewer than 2 holders selected', async () => {
    renderModal();
    fireEvent.click(screen.getByLabelText(/anycast mode/i));

    await waitFor(() => expect(screen.getByText(/anycast holders/i)).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText('e.g. webapp-vip'), {
      target: { value: 'my-anycast-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText('192.0.2.42/32 or fdXX::/128'), {
      target: { value: '192.0.2.1/32' },
    });

    // Select only 1 anycast holder
    const checkboxes = screen.getAllByRole('checkbox');
    // checkboxes[0] is the anycast toggle itself; peer checkboxes start at index 1
    fireEvent.click(checkboxes[1]);

    const form = screen.getByTestId('modal').querySelector('form');
    fireEvent.submit(form!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Anycast VIPs require at least 2 holder peers.',
      }),
    );
    expect(mockCreateVirtualIp).not.toHaveBeenCalled();
  });

  it('does not show the anycast error when 2 or more holders are selected', async () => {
    mockCreateVirtualIp.mockReturnValue(resolvedVip({ ...CREATED_VIP, anycast: true, holder_peer_ids: [PEER_SPOKE.id, PEER_SPOKE_2.id] }));
    renderModal();
    fireEvent.click(screen.getByLabelText(/anycast mode/i));

    await waitFor(() => expect(screen.getByText(/anycast holders/i)).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText('e.g. webapp-vip'), {
      target: { value: 'anycast-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText('192.0.2.42/32 or fdXX::/128'), {
      target: { value: '192.0.2.1/32' },
    });

    // Click 2 peer checkboxes
    const checkboxes = screen.getAllByRole('checkbox');
    fireEvent.click(checkboxes[1]);
    fireEvent.click(checkboxes[2]);

    const form = screen.getByTestId('modal').querySelector('form');
    fireEvent.submit(form!);

    await waitFor(() => expect(mockCreateVirtualIp).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ message: expect.stringContaining('Anycast') }),
    );
  });

  // ---------------------------------------------------------------------------
  // Successful unicast submission — payload shape
  // ---------------------------------------------------------------------------

  it('calls createVirtualIp with the correct unicast payload', async () => {
    mockCreateVirtualIp.mockReturnValue(resolvedVip());
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText('e.g. webapp-vip'), {
      target: { value: 'webapp-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText('192.0.2.42/32 or fdXX::/128'), {
      target: { value: '192.0.2.42/32' },
    });
    fireEvent.change(screen.getByRole('combobox'), { target: { value: PEER_HUB.id } });

    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockCreateVirtualIp).toHaveBeenCalledWith(NETWORK_ID, {
        name: 'webapp-vip',
        cidr: '192.0.2.42/32',
        description: undefined,
        anycast: false,
        holder_peer_ids: [PEER_HUB.id],
        failover_holder_peer_ids: [],
        advertised_med: 0,
        advertised_local_pref: 100,
      }),
    );
  });

  it('includes description in payload when filled in', async () => {
    mockCreateVirtualIp.mockReturnValue(resolvedVip());
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText('e.g. webapp-vip'), {
      target: { value: 'webapp-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText('192.0.2.42/32 or fdXX::/128'), {
      target: { value: '192.0.2.42/32' },
    });
    fireEvent.change(screen.getByRole('combobox'), { target: { value: PEER_HUB.id } });

    // Fill in description
    const descriptionInput = screen.getAllByRole('textbox').find(
      (el) => !el.getAttribute('placeholder'),
    );
    expect(descriptionInput).toBeDefined();
    fireEvent.change(descriptionInput!, { target: { value: 'My VIP description' } });

    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockCreateVirtualIp).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({ description: 'My VIP description' }),
      ),
    );
  });

  it('sends description as undefined when the description field is blank', async () => {
    mockCreateVirtualIp.mockReturnValue(resolvedVip());
    renderModal();

    await fillUnicastForm();
    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockCreateVirtualIp).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({ description: undefined }),
      ),
    );
  });

  it('includes failover_holder_peer_ids in unicast payload when failover is selected', async () => {
    mockCreateVirtualIp.mockReturnValue(resolvedVip());
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText('e.g. webapp-vip'), {
      target: { value: 'webapp-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText('192.0.2.42/32 or fdXX::/128'), {
      target: { value: '192.0.2.42/32' },
    });
    fireEvent.change(screen.getByRole('combobox'), { target: { value: PEER_HUB.id } });

    // The failover list shows peers excluding the primary.
    // Check the first failover checkbox (PEER_SPOKE since PEER_HUB is primary)
    await waitFor(() => {
      const failoverCheckboxes = screen
        .getAllByRole('checkbox')
        .filter((cb) => cb !== screen.getByLabelText(/anycast mode/i));
      expect(failoverCheckboxes.length).toBeGreaterThan(0);
      fireEvent.click(failoverCheckboxes[0]);
    });

    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockCreateVirtualIp).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({
          failover_holder_peer_ids: expect.arrayContaining([expect.any(String)]),
        }),
      ),
    );
  });

  it('sends empty failover_holder_peer_ids for anycast VIPs', async () => {
    mockCreateVirtualIp.mockReturnValue(resolvedVip({ ...CREATED_VIP, anycast: true }));
    renderModal();

    fireEvent.click(screen.getByLabelText(/anycast mode/i));

    await waitFor(() => expect(screen.getByText(/anycast holders/i)).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText('e.g. webapp-vip'), {
      target: { value: 'anycast-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText('192.0.2.42/32 or fdXX::/128'), {
      target: { value: '10.0.0.1/32' },
    });

    // Select 2 holders
    const checkboxes = screen.getAllByRole('checkbox');
    fireEvent.click(checkboxes[1]);
    fireEvent.click(checkboxes[2]);

    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockCreateVirtualIp).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({
          anycast: true,
          failover_holder_peer_ids: [],
        }),
      ),
    );
  });

  it('includes custom MED and Local Preference in payload', async () => {
    mockCreateVirtualIp.mockReturnValue(resolvedVip());
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByPlaceholderText('e.g. webapp-vip'), {
      target: { value: 'webapp-vip' },
    });
    fireEvent.change(screen.getByPlaceholderText('192.0.2.42/32 or fdXX::/128'), {
      target: { value: '192.0.2.42/32' },
    });
    fireEvent.change(screen.getByRole('combobox'), { target: { value: PEER_HUB.id } });

    // Open details and change BGP values
    fireEvent.click(screen.getByText(/advanced.*bgp metrics/i));
    const numberInputs = screen.getAllByRole('spinbutton');
    fireEvent.change(numberInputs[0], { target: { value: '200' } });
    fireEvent.change(numberInputs[1], { target: { value: '150' } });

    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockCreateVirtualIp).toHaveBeenCalledWith(
        NETWORK_ID,
        expect.objectContaining({
          advertised_med: 200,
          advertised_local_pref: 150,
        }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // onCreated callback
  // ---------------------------------------------------------------------------

  it('calls onCreated with the returned VIP after a successful submission', async () => {
    mockCreateVirtualIp.mockReturnValue(resolvedVip());
    const onCreated = jest.fn();

    renderModal({ onCreated });
    await fillUnicastForm();
    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(onCreated).toHaveBeenCalledWith(CREATED_VIP),
    );
  });

  // ---------------------------------------------------------------------------
  // In-flight state
  // ---------------------------------------------------------------------------

  it('shows "Creating…" on the submit button while the request is in-flight', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateVirtualIp.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    renderModal();
    await fillUnicastForm();
    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /creating/i })).toBeInTheDocument(),
    );

    resolveFn(CREATED_VIP);
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /creating/i })).not.toBeInTheDocument(),
    );
  });

  it('disables the submit button while the request is in-flight', async () => {
    let resolveFn!: (v: unknown) => void;
    mockCreateVirtualIp.mockReturnValue(new Promise((r) => { resolveFn = r; }));

    renderModal();
    await fillUnicastForm();
    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /creating/i })).toBeDisabled(),
    );

    resolveFn(CREATED_VIP);
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /creating/i })).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Error path
  // ---------------------------------------------------------------------------

  it('shows an error notification with the Error message on API failure', async () => {
    mockCreateVirtualIp.mockRejectedValue(new Error('Server error: 500'));

    renderModal();
    await fillUnicastForm();
    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Server error: 500',
      }),
    );
  });

  it('shows "Failed to create virtual IP" when a non-Error is thrown', async () => {
    mockCreateVirtualIp.mockRejectedValue('unexpected string error');

    renderModal();
    await fillUnicastForm();
    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create virtual IP',
      }),
    );
  });

  it('does not call onCreated when creation fails', async () => {
    mockCreateVirtualIp.mockRejectedValue(new Error('oops'));
    const onCreated = jest.fn();

    renderModal({ onCreated });
    await fillUnicastForm();
    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );
    expect(onCreated).not.toHaveBeenCalled();
  });

  it('re-enables the submit button after a failed submission', async () => {
    mockCreateVirtualIp.mockRejectedValue(new Error('server error'));

    renderModal();
    await fillUnicastForm();
    fireEvent.click(screen.getByRole('button', { name: /create virtual ip/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(screen.getByRole('button', { name: /create virtual ip/i })).not.toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Peer fetch failure — graceful degradation
  // ---------------------------------------------------------------------------

  it('gracefully handles a failed getPeers call (renders empty lists)', async () => {
    mockGetPeers.mockRejectedValue(new Error('network error'));

    renderModal();

    // The modal still renders — just with no peers in the dropdown
    await waitFor(() =>
      expect(screen.getByTestId('modal')).toBeInTheDocument(),
    );

    expect(screen.getByRole('combobox')).toBeInTheDocument();
    // Only the "Select a peer…" placeholder option
    expect(screen.getByRole('option', { name: /select a peer/i })).toBeInTheDocument();
    // No real peer options
    expect(screen.queryByRole('option', { name: /hub|spoke/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel is clicked', () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(mockCreateVirtualIp).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Anycast holder toggle behavior
  // ---------------------------------------------------------------------------

  it('toggles an anycast holder on and off with repeated clicks', async () => {
    renderModal();
    fireEvent.click(screen.getByLabelText(/anycast mode/i));

    await waitFor(() => expect(screen.getByText(/anycast holders/i)).toBeInTheDocument());

    const checkboxes = screen.getAllByRole('checkbox');
    // checkboxes[1] is the first peer checkbox
    expect(checkboxes[1]).not.toBeChecked();
    fireEvent.click(checkboxes[1]);
    expect(checkboxes[1]).toBeChecked();
    fireEvent.click(checkboxes[1]);
    expect(checkboxes[1]).not.toBeChecked();
  });

  it('toggles a failover candidate on and off with repeated clicks', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());
    fireEvent.change(screen.getByRole('combobox'), { target: { value: PEER_HUB.id } });

    // Get the failover checkboxes (excluding the anycast mode checkbox)
    await waitFor(() => {
      const allCheckboxes = screen.getAllByRole('checkbox');
      const failoverCheckboxes = allCheckboxes.filter(
        (cb) => cb !== screen.getByLabelText(/anycast mode/i),
      );
      expect(failoverCheckboxes.length).toBeGreaterThan(0);
      expect(failoverCheckboxes[0]).not.toBeChecked();
      fireEvent.click(failoverCheckboxes[0]);
      expect(failoverCheckboxes[0]).toBeChecked();
      fireEvent.click(failoverCheckboxes[0]);
      expect(failoverCheckboxes[0]).not.toBeChecked();
    });
  });
});
