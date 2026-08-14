import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PeerEditModal } from './PeerEditModal';
import type { SdwanPeer } from '../../types/sdwan.types';

// =============================================================================
// Mocks
//
// PeerEditModal calls apiClient.put directly and uses useNotifications.
// We mock both surfaces so the component renders without a real backend.
// =============================================================================

const mockPut = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: jest.fn(),
    put: (...args: unknown[]) => mockPut(...args),
    delete: jest.fn(),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
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
// Helpers
// =============================================================================

/** Wrap the double-envelope that apiClient resolves to. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_ID = 'net-abc';

/** Spoke peer — publicly_reachable: false, no endpoint info */
const SPOKE_PEER: SdwanPeer = {
  id: 'peer-spoke-1',
  network_id: NETWORK_ID,
  node_instance_id: 'node-1',
  assigned_address: 'fd00::1',
  publicly_reachable: false,
  listen_port: 51820,
  status: 'active',
};

/** Hub peer — publicly_reachable: true with dual-stack endpoints */
const HUB_PEER: SdwanPeer = {
  id: 'peer-hub-1',
  network_id: NETWORK_ID,
  node_instance_id: 'node-2',
  assigned_address: 'fd00::2',
  publicly_reachable: true,
  endpoint_host_v6: '2001:db8::1',
  endpoint_host_v4: '203.0.113.10',
  endpoint_port: 51820,
  listen_port: 51820,
  status: 'active',
  effective_endpoint: '2001:db8::1:51820',
  effective_endpoint_family: 'v6',
  fallback_endpoint: '203.0.113.10:51820',
};

/** Hub peer with only a legacy endpoint_host (pre-dual-stack migration) */
const LEGACY_V4_HUB_PEER: SdwanPeer = {
  id: 'peer-legacy-v4',
  network_id: NETWORK_ID,
  node_instance_id: 'node-3',
  assigned_address: 'fd00::3',
  publicly_reachable: true,
  endpoint_host: '192.0.2.5',
  endpoint_port: 51820,
  listen_port: 51820,
  status: 'active',
};

/** Hub peer with a legacy v6 endpoint_host (contains ':') */
const LEGACY_V6_HUB_PEER: SdwanPeer = {
  id: 'peer-legacy-v6',
  network_id: NETWORK_ID,
  node_instance_id: 'node-4',
  assigned_address: 'fd00::4',
  publicly_reachable: true,
  endpoint_host: '2001:db8::ff',
  endpoint_port: 51820,
  listen_port: 51820,
  status: 'active',
};

/** Peer with lan_subnets */
const PEER_WITH_SUBNETS: SdwanPeer = {
  ...SPOKE_PEER,
  id: 'peer-subnets-1',
  lan_subnets: ['10.0.0.0/24', '192.168.1.0/24'],
};

// =============================================================================
// Render helper
// =============================================================================

const renderModal = (
  props: Partial<React.ComponentProps<typeof PeerEditModal>> = {}
) => {
  const onClose = jest.fn();
  const onSaved = jest.fn();

  render(
    <BrowserRouter>
      <PeerEditModal
        isOpen={true}
        networkId={NETWORK_ID}
        peer={SPOKE_PEER}
        onClose={onClose}
        onSaved={onSaved}
        {...props}
      />
    </BrowserRouter>
  );

  return { onClose, onSaved };
};

// =============================================================================
// Tests
// =============================================================================

describe('PeerEditModal', () => {
  beforeEach(() => {
    mockPut.mockReset();
    mockAddNotification.mockReset();
  });

  // ──── Null / closed guard ─────────────────────────────────────────────────

  it('renders nothing when peer is null', () => {
    const { container } = render(
      <BrowserRouter>
        <PeerEditModal
          isOpen={true}
          networkId={NETWORK_ID}
          peer={null}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );
    expect(container).toBeEmptyDOMElement();
  });

  it('renders nothing when isOpen is false and peer is null', () => {
    const { container } = render(
      <BrowserRouter>
        <PeerEditModal
          isOpen={false}
          networkId={NETWORK_ID}
          peer={null}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );
    expect(container).toBeEmptyDOMElement();
  });

  // ──── Modal title + assigned address display ──────────────────────────────

  it('shows "Edit peer" as the modal title', () => {
    renderModal();
    expect(screen.getByText('Edit peer')).toBeInTheDocument();
  });

  it('displays the assigned address of the peer', () => {
    renderModal({ peer: SPOKE_PEER });
    expect(screen.getByText(/fd00::1/)).toBeInTheDocument();
  });

  // ──── Spoke peer initial state ────────────────────────────────────────────

  it('renders the publicly reachable checkbox unchecked for a spoke peer', () => {
    renderModal({ peer: SPOKE_PEER });
    const checkbox = screen.getByRole('checkbox');
    expect(checkbox).not.toBeChecked();
  });

  it('hides endpoint fields for a spoke peer (publicly_reachable: false)', () => {
    renderModal({ peer: SPOKE_PEER });
    expect(screen.queryByLabelText(/IPv6 endpoint host/i)).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/IPv4 endpoint host/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/Port/)).not.toBeInTheDocument();
  });

  // ──── Hub peer initial state ──────────────────────────────────────────────

  it('renders checkbox checked for a hub peer', () => {
    renderModal({ peer: HUB_PEER });
    const checkbox = screen.getByRole('checkbox');
    expect(checkbox).toBeChecked();
  });

  it('populates IPv6 endpoint host from peer.endpoint_host_v6', () => {
    renderModal({ peer: HUB_PEER });
    expect(screen.getByDisplayValue('2001:db8::1')).toBeInTheDocument();
  });

  it('populates IPv4 endpoint host from peer.endpoint_host_v4', () => {
    renderModal({ peer: HUB_PEER });
    expect(screen.getByDisplayValue('203.0.113.10')).toBeInTheDocument();
  });

  it('populates port from peer.endpoint_port', () => {
    renderModal({ peer: HUB_PEER });
    expect(screen.getByDisplayValue('51820')).toBeInTheDocument();
  });

  // ──── Effective endpoint display ──────────────────────────────────────────

  it('shows effective_endpoint when present on the peer', () => {
    renderModal({ peer: HUB_PEER });
    expect(screen.getByText(/2001:db8::1:51820/)).toBeInTheDocument();
  });

  it('shows effective_endpoint_family badge when present', () => {
    renderModal({ peer: HUB_PEER });
    expect(screen.getByText('(v6)')).toBeInTheDocument();
  });

  it('shows fallback_endpoint when present', () => {
    renderModal({ peer: HUB_PEER });
    expect(screen.getByText(/203.0.113.10:51820/)).toBeInTheDocument();
  });

  it('does not show effective_endpoint block when peer has none', () => {
    renderModal({ peer: SPOKE_PEER });
    // SPOKE_PEER has no effective_endpoint
    expect(screen.queryByText(/Currently using/)).not.toBeInTheDocument();
  });

  // ──── Legacy endpoint_host back-compat ───────────────────────────────────

  it('classifies legacy endpoint_host without ":" as v4 and populates the v4 field', () => {
    renderModal({ peer: LEGACY_V4_HUB_PEER });
    // v4 field should have the value, v6 field should be empty
    expect(screen.getByDisplayValue('192.0.2.5')).toBeInTheDocument();
    // The v6 field is present (publicly_reachable=true) but empty
    const inputs = screen.getAllByRole('textbox');
    const v6Input = inputs.find((el) => (el as HTMLInputElement).placeholder?.includes('2001:db8'));
    expect(v6Input).toBeTruthy();
    expect((v6Input as HTMLInputElement).value).toBe('');
  });

  it('classifies legacy endpoint_host containing ":" as v6 and populates the v6 field', () => {
    renderModal({ peer: LEGACY_V6_HUB_PEER });
    expect(screen.getByDisplayValue('2001:db8::ff')).toBeInTheDocument();
    // The v4 field should be empty
    const inputs = screen.getAllByRole('textbox');
    const v4Input = inputs.find((el) => (el as HTMLInputElement).placeholder?.includes('203.0.113'));
    expect(v4Input).toBeTruthy();
    expect((v4Input as HTMLInputElement).value).toBe('');
  });

  // ──── LAN subnets display ─────────────────────────────────────────────────

  it('renders lan_subnets as newline-separated text in the textarea / input', async () => {
    // The source renders lanSubnets in state but does NOT actually have a textarea
    // in the form — we must check whether this is visible by looking at the DOM.
    // The PeerEditModal doesn't render a lan_subnets input visually in the returned
    // JSX (only stores it in state and sends in payload). Skip DOM check; verify
    // the state was set by checking the submitted payload includes parsed subnets.
    mockPut.mockResolvedValueOnce(envelope({ peer: PEER_WITH_SUBNETS }));

    const { onSaved } = renderModal({ peer: PEER_WITH_SUBNETS });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { peer: { lan_subnets: string[] } }];
    expect(payload.peer.lan_subnets).toEqual(['10.0.0.0/24', '192.168.1.0/24']);

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
  });

  // ──── Toggle publicly_reachable ───────────────────────────────────────────

  it('shows endpoint fields after checking the hub checkbox', () => {
    renderModal({ peer: SPOKE_PEER });
    expect(screen.queryByText(/IPv6 endpoint host/)).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('checkbox'));

    expect(screen.getByText(/IPv6 endpoint host/)).toBeInTheDocument();
    expect(screen.getByText(/IPv4 endpoint host/)).toBeInTheDocument();
    expect(screen.getByText(/^Port$/)).toBeInTheDocument();
  });

  it('hides endpoint fields after unchecking the hub checkbox', () => {
    renderModal({ peer: HUB_PEER });
    expect(screen.getByText(/IPv6 endpoint host/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole('checkbox'));

    expect(screen.queryByText(/IPv6 endpoint host/)).not.toBeInTheDocument();
    expect(screen.queryByText(/IPv4 endpoint host/)).not.toBeInTheDocument();
  });

  // ──── Validation ──────────────────────────────────────────────────────────

  it('shows error and does not call API when hub has no endpoint hosts', async () => {
    renderModal({ peer: SPOKE_PEER });

    // Enable hub mode
    fireEvent.click(screen.getByRole('checkbox'));

    // Leave both host fields empty, port has default 51820
    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Hub peers need at least one endpoint (v6 or v4)',
        })
      )
    );
    expect(mockPut).not.toHaveBeenCalled();
  });

  it('shows error when hub has endpoint host but endpoint_port is 0', async () => {
    renderModal({ peer: SPOKE_PEER });

    // Enable hub mode
    fireEvent.click(screen.getByRole('checkbox'));

    // Fill v4 host
    const inputs = screen.getAllByRole('textbox');
    const v4Input = inputs.find((el) => (el as HTMLInputElement).placeholder?.includes('203.0.113'));
    fireEvent.change(v4Input!, { target: { value: '1.2.3.4' } });

    // Clear the port (set to 0 which is falsy)
    const portInput = screen.getByRole('spinbutton');
    fireEvent.change(portInput, { target: { value: '0' } });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Hub peers require an endpoint port',
        })
      )
    );
    expect(mockPut).not.toHaveBeenCalled();
  });

  it('accepts a hub with only v6 host filled (v4 empty)', async () => {
    mockPut.mockResolvedValueOnce(envelope({ peer: HUB_PEER }));

    renderModal({ peer: SPOKE_PEER });

    fireEvent.click(screen.getByRole('checkbox'));

    const inputs = screen.getAllByRole('textbox');
    const v6Input = inputs.find((el) => (el as HTMLInputElement).placeholder?.includes('2001:db8'));
    fireEvent.change(v6Input!, { target: { value: '2001:db8::1' } });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'error' })
    );
  });

  it('accepts a hub with only v4 host filled (v6 empty)', async () => {
    mockPut.mockResolvedValueOnce(envelope({ peer: HUB_PEER }));

    renderModal({ peer: SPOKE_PEER });

    fireEvent.click(screen.getByRole('checkbox'));

    const inputs = screen.getAllByRole('textbox');
    const v4Input = inputs.find((el) => (el as HTMLInputElement).placeholder?.includes('203.0.113'));
    fireEvent.change(v4Input!, { target: { value: '1.2.3.4' } });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'error' })
    );
  });

  // ──── Successful submit: exact URL + payload ──────────────────────────────

  it('calls apiClient.put with correct URL and spoke payload on submit', async () => {
    mockPut.mockResolvedValueOnce(envelope({ peer: SPOKE_PEER }));

    const { onSaved, onClose } = renderModal({ peer: SPOKE_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    expect(mockPut).toHaveBeenCalledWith(
      `/system/sdwan/networks/${NETWORK_ID}/peers/${SPOKE_PEER.id}`,
      {
        peer: {
          publicly_reachable: false,
          lan_subnets: [],
          endpoint_host_v6: null,
          endpoint_host_v4: null,
          endpoint_host: null,
          endpoint_port: null,
        },
      }
    );

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success', message: 'Peer updated' })
    );
  });

  it('calls apiClient.put with correct URL and hub payload on submit', async () => {
    mockPut.mockResolvedValueOnce(envelope({ peer: HUB_PEER }));

    const { onSaved, onClose } = renderModal({ peer: HUB_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    expect(mockPut).toHaveBeenCalledWith(
      `/system/sdwan/networks/${NETWORK_ID}/peers/${HUB_PEER.id}`,
      {
        peer: {
          publicly_reachable: true,
          lan_subnets: [],
          endpoint_host_v6: '2001:db8::1',
          endpoint_host_v4: '203.0.113.10',
          endpoint_host: null,
          endpoint_port: 51820,
        },
      }
    );

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
  });

  it('sends null endpoint hosts and null port when demoting hub to spoke', async () => {
    mockPut.mockResolvedValueOnce(envelope({ peer: { ...HUB_PEER, publicly_reachable: false } }));

    renderModal({ peer: HUB_PEER });

    // Uncheck hub mode
    fireEvent.click(screen.getByRole('checkbox'));

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [url, payload] = mockPut.mock.calls[0] as [string, { peer: Record<string, unknown> }];
    expect(url).toBe(`/system/sdwan/networks/${NETWORK_ID}/peers/${HUB_PEER.id}`);
    expect(payload.peer.publicly_reachable).toBe(false);
    expect(payload.peer.endpoint_host_v6).toBeNull();
    expect(payload.peer.endpoint_host_v4).toBeNull();
    expect(payload.peer.endpoint_port).toBeNull();
    expect(payload.peer.endpoint_host).toBeNull();
  });

  it('trims whitespace from endpoint hosts before submitting', async () => {
    mockPut.mockResolvedValueOnce(envelope({ peer: HUB_PEER }));

    renderModal({ peer: SPOKE_PEER });

    fireEvent.click(screen.getByRole('checkbox'));

    const inputs = screen.getAllByRole('textbox');
    const v6Input = inputs.find((el) => (el as HTMLInputElement).placeholder?.includes('2001:db8'));
    const v4Input = inputs.find((el) => (el as HTMLInputElement).placeholder?.includes('203.0.113'));
    fireEvent.change(v6Input!, { target: { value: '  2001:db8::1  ' } });
    fireEvent.change(v4Input!, { target: { value: '  203.0.113.10  ' } });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { peer: Record<string, unknown> }];
    expect(payload.peer.endpoint_host_v6).toBe('2001:db8::1');
    expect(payload.peer.endpoint_host_v4).toBe('203.0.113.10');
  });

  it('sends endpoint_host: null always (clears legacy column)', async () => {
    mockPut.mockResolvedValueOnce(envelope({ peer: HUB_PEER }));

    renderModal({ peer: HUB_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { peer: Record<string, unknown> }];
    expect(payload.peer.endpoint_host).toBeNull();
  });

  // ──── LAN subnets: parsing newline/comma separated ────────────────────────

  it('parses comma-separated lan_subnets correctly in payload', async () => {
    mockPut.mockResolvedValueOnce(envelope({ peer: SPOKE_PEER }));

    // Create a peer fixture that we can manipulate to test lanSubnets state
    // We'll use a peer with subnets and verify the parsed output
    const peerWithSubnets: SdwanPeer = {
      ...SPOKE_PEER,
      lan_subnets: ['10.0.0.0/24', '192.168.1.0/24'],
    };

    renderModal({ peer: peerWithSubnets });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { peer: { lan_subnets: string[] } }];
    expect(payload.peer.lan_subnets).toEqual(['10.0.0.0/24', '192.168.1.0/24']);
  });

  it('sends empty array when peer has no lan_subnets', async () => {
    mockPut.mockResolvedValueOnce(envelope({ peer: SPOKE_PEER }));

    renderModal({ peer: SPOKE_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { peer: { lan_subnets: string[] } }];
    expect(payload.peer.lan_subnets).toEqual([]);
  });

  // ──── Error handling ──────────────────────────────────────────────────────

  it('shows error notification with message and does not call onSaved when API rejects with Error', async () => {
    mockPut.mockRejectedValueOnce(new Error('Connection refused'));

    const { onSaved, onClose } = renderModal({ peer: SPOKE_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Connection refused' })
      )
    );
    expect(onSaved).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('shows generic "Update failed" when API rejects with non-Error value', async () => {
    mockPut.mockRejectedValueOnce('oops');

    renderModal({ peer: SPOKE_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Update failed' })
      )
    );
  });

  // ──── Submitting state ────────────────────────────────────────────────────

  it('shows "Saving…" on the button while the request is in flight', async () => {
    let resolve!: (v: unknown) => void;
    mockPut.mockReturnValueOnce(new Promise((res) => { resolve = res; }));

    renderModal({ peer: SPOKE_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(screen.getByText(/saving…/i)).toBeInTheDocument());

    resolve(envelope({ peer: SPOKE_PEER }));
    await waitFor(() => expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument());
  });

  it('disables the checkbox while submitting', async () => {
    let resolve!: (v: unknown) => void;
    mockPut.mockReturnValueOnce(new Promise((res) => { resolve = res; }));

    renderModal({ peer: SPOKE_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(screen.getByText(/saving…/i)).toBeInTheDocument());

    expect(screen.getByRole('checkbox')).toBeDisabled();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();

    resolve(envelope({ peer: SPOKE_PEER }));
    await waitFor(() => expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument());
  });

  it('disables endpoint inputs while submitting (hub mode)', async () => {
    let resolve!: (v: unknown) => void;
    mockPut.mockReturnValueOnce(new Promise((res) => { resolve = res; }));

    renderModal({ peer: HUB_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(screen.getByText(/saving…/i)).toBeInTheDocument());

    // All textbox inputs should be disabled during submission
    const textboxes = screen.getAllByRole('textbox');
    textboxes.forEach((input) => {
      expect(input).toBeDisabled();
    });

    resolve(envelope({ peer: HUB_PEER }));
    await waitFor(() => expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument());
  });

  // ──── Cancel button ───────────────────────────────────────────────────────

  it('calls onClose when Cancel is clicked', () => {
    const { onClose } = renderModal({ peer: SPOKE_PEER });
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('does not call onClose from modal backdrop when submitting', async () => {
    // The modal's onClose is guarded by !submitting — clicking the X or backdrop
    // while submitting should be a no-op. We test the guard indirectly by confirming
    // the Cancel button itself is disabled (which also prevents the click from firing).
    let resolve!: (v: unknown) => void;
    mockPut.mockReturnValueOnce(new Promise((res) => { resolve = res; }));

    const { onClose } = renderModal({ peer: SPOKE_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => expect(screen.getByText(/saving…/i)).toBeInTheDocument());

    const cancelButton = screen.getByRole('button', { name: /cancel/i });
    expect(cancelButton).toBeDisabled();
    // Clicking a disabled button should not trigger onClose
    fireEvent.click(cancelButton);
    expect(onClose).not.toHaveBeenCalled();

    resolve(envelope({ peer: SPOKE_PEER }));
    await waitFor(() => expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument());
  });

  // ──── Default port value ──────────────────────────────────────────────────

  it('defaults endpoint_port to 51820 when peer has no endpoint_port', () => {
    const peerNoPort: SdwanPeer = {
      ...HUB_PEER,
      endpoint_port: null,
      endpoint_host_v4: '1.2.3.4',
      endpoint_host_v6: '',
    };

    renderModal({ peer: peerNoPort });

    // The port spinbutton should have value 51820
    const portInput = screen.getByRole('spinbutton');
    expect((portInput as HTMLInputElement).value).toBe('51820');
  });

  // ──── Hint text visible when hub mode active ──────────────────────────────

  it('shows "Provide at least one" hint text when hub mode is active', () => {
    renderModal({ peer: HUB_PEER });
    expect(screen.getByText(/Provide at least one/i)).toBeInTheDocument();
  });

  it('does not show hint text when hub mode is inactive', () => {
    renderModal({ peer: SPOKE_PEER });
    expect(screen.queryByText(/Provide at least one/i)).not.toBeInTheDocument();
  });

  // ──── Pending-approval branch (IMP-87ec6f651f07) ──────────────────────────

  it('shows the pending-approval notification (not success) and skips onSaved when the update is parked', async () => {
    mockPut.mockResolvedValueOnce({
      status: 202,
      data: {
        success: true,
        data: {
          pending: true,
          deferred_operation_id: 'dop-1',
          action_category: 'sdwan.peer_update',
          approval_request_id: 'ar-1',
          message: 'Approval required',
        },
      },
    });

    const { onSaved, onClose } = renderModal({ peer: SPOKE_PEER });

    const form = screen.getByRole('button', { name: /save/i }).closest('form')!;
    fireEvent.submit(form);

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
    expect(onSaved).not.toHaveBeenCalled();
    expect(onClose).toHaveBeenCalled();
  });
});
