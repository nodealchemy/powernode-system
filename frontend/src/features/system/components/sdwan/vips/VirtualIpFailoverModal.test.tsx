import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { VirtualIpFailoverModal } from './VirtualIpFailoverModal';
import type { SdwanVirtualIp } from '../../../types/sdwan.types';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: (...args: unknown[]) => mockPost(...args),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
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

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const NETWORK_ID = 'net-abc123';

const VIP_WITH_FAILOVER: SdwanVirtualIp = {
  id: 'vip-001',
  network_id: NETWORK_ID,
  name: 'edge-vip',
  cidr: '10.100.0.1/32',
  anycast: false,
  state: 'active',
  holder_peer_ids: ['peer-aaa', 'peer-bbb'],
  failover_holder_peer_ids: ['peer-bbb', 'peer-ccc'],
  primary_holder_peer_id: 'peer-aaaaaa111111',
  primary_holder_address: '10.100.0.1',
  advertised_med: 100,
  advertised_local_pref: 100,
  tags: [],
};

const VIP_NO_FAILOVER: SdwanVirtualIp = {
  id: 'vip-002',
  network_id: NETWORK_ID,
  name: 'solo-vip',
  cidr: '10.100.0.2/32',
  anycast: false,
  state: 'active',
  holder_peer_ids: ['peer-aaa'],
  failover_holder_peer_ids: [],
  primary_holder_peer_id: 'peer-aaaaaa111111',
  primary_holder_address: '10.100.0.2',
  advertised_med: 100,
  advertised_local_pref: 100,
  tags: [],
};

const VIP_NULL_PRIMARY: SdwanVirtualIp = {
  ...VIP_WITH_FAILOVER,
  id: 'vip-003',
  primary_holder_peer_id: null,
};

// =============================================================================
// Tests
// =============================================================================

const mockOnClose = jest.fn();
const mockOnFailedOver = jest.fn();

const renderModal = (vip: SdwanVirtualIp = VIP_WITH_FAILOVER) =>
  render(
    <VirtualIpFailoverModal
      networkId={NETWORK_ID}
      vip={vip}
      onClose={mockOnClose}
      onFailedOver={mockOnFailedOver}
    />,
  );

describe('VirtualIpFailoverModal', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockAddNotification.mockReset();
    mockOnClose.mockReset();
    mockOnFailedOver.mockReset();
  });

  // ── Render state ──────────────────────────────────────────────────────────

  it('renders the modal title with the VIP name', () => {
    renderModal();
    expect(screen.getByText('Failover VIP — edge-vip')).toBeInTheDocument();
  });

  it('displays the VIP CIDR', () => {
    renderModal();
    expect(screen.getByText('10.100.0.1/32')).toBeInTheDocument();
  });

  it('shows the current primary holder truncated to 12 chars', () => {
    renderModal();
    // primary_holder_peer_id is 'peer-aaaaaa111111' → first 12 = 'peer-aaaaaa1'
    expect(screen.getByText('peer-aaaaaa1')).toBeInTheDocument();
  });

  it('shows "—" for current holder when primary_holder_peer_id is null', () => {
    renderModal(VIP_NULL_PRIMARY);
    // Both current and next holder show "—" since primary is null and
    // failover_holder_peer_ids[0] is still 'peer-bbb' (slice(0,12))
    const dashes = screen.getAllByText('—');
    expect(dashes.length).toBeGreaterThanOrEqual(1);
  });

  it('displays the next failover holder truncated to 12 chars', () => {
    renderModal();
    // failover_holder_peer_ids[0] = 'peer-bbb' → first 12 = 'peer-bbb'
    expect(screen.getByText('peer-bbb')).toBeInTheDocument();
  });

  it('shows the warning banner with manual failover explanation', () => {
    renderModal();
    expect(screen.getByText('Manual failover')).toBeInTheDocument();
    expect(
      screen.getByText(/Promotes the head of/i),
    ).toBeInTheDocument();
  });

  it('shows the "Confirm failover" button when a failover candidate exists', () => {
    renderModal();
    const btn = screen.getByRole('button', { name: /confirm failover/i });
    expect(btn).toBeInTheDocument();
    expect(btn).not.toBeDisabled();
  });

  it('shows the "Cancel" button', () => {
    renderModal();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
  });

  // ── No-failover-candidate state ───────────────────────────────────────────

  it('shows the no-candidates warning when failover_holder_peer_ids is empty', () => {
    renderModal(VIP_NO_FAILOVER);
    expect(
      screen.getByText(/No failover candidates configured/i),
    ).toBeInTheDocument();
  });

  it('disables the Confirm failover button when there are no failover candidates', () => {
    renderModal(VIP_NO_FAILOVER);
    expect(screen.getByRole('button', { name: /confirm failover/i })).toBeDisabled();
  });

  it('shows "—" for next holder when failover_holder_peer_ids is empty', () => {
    renderModal(VIP_NO_FAILOVER);
    // At least the "next holder" dash should appear
    expect(screen.getAllByText('—').length).toBeGreaterThanOrEqual(1);
  });

  it('does NOT show the no-candidates warning when candidates exist', () => {
    renderModal(VIP_WITH_FAILOVER);
    expect(
      screen.queryByText(/No failover candidates configured/i),
    ).not.toBeInTheDocument();
  });

  // ── Cancel interaction ────────────────────────────────────────────────────

  it('calls onClose when Cancel is clicked', () => {
    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(mockOnClose).toHaveBeenCalledTimes(1);
    expect(mockPost).not.toHaveBeenCalled();
  });

  // ── Successful failover ───────────────────────────────────────────────────

  it('calls the correct POST endpoint on confirm', async () => {
    const updatedVip: SdwanVirtualIp = {
      ...VIP_WITH_FAILOVER,
      state: 'failing_over',
      primary_holder_peer_id: 'peer-bbb',
    };
    mockPost.mockResolvedValueOnce(
      envelope({ virtual_ip: updatedVip }),
    );

    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /confirm failover/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        `/system/sdwan/networks/${NETWORK_ID}/virtual_ips/${VIP_WITH_FAILOVER.id}/failover`,
        {},
      ),
    );
  });

  it('calls onFailedOver with the updated VIP returned by the API', async () => {
    const updatedVip: SdwanVirtualIp = {
      ...VIP_WITH_FAILOVER,
      state: 'failing_over',
      primary_holder_peer_id: 'peer-bbb',
    };
    mockPost.mockResolvedValueOnce(
      envelope({ virtual_ip: updatedVip }),
    );

    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /confirm failover/i }));

    await waitFor(() =>
      expect(mockOnFailedOver).toHaveBeenCalledWith(updatedVip),
    );
  });

  it('does not call onClose or addNotification on success', async () => {
    const updatedVip: SdwanVirtualIp = { ...VIP_WITH_FAILOVER, state: 'failing_over' };
    mockPost.mockResolvedValueOnce(envelope({ virtual_ip: updatedVip }));

    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /confirm failover/i }));

    await waitFor(() => expect(mockOnFailedOver).toHaveBeenCalled());
    expect(mockAddNotification).not.toHaveBeenCalled();
    expect(mockOnClose).not.toHaveBeenCalled();
  });

  // ── Submitting state ──────────────────────────────────────────────────────

  it('shows "Failing over…" label and disables the button while submitting', async () => {
    let resolve: (v: unknown) => void = () => undefined;
    mockPost.mockReturnValueOnce(new Promise((res) => { resolve = res; }));

    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /confirm failover/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /failing over/i })).toBeDisabled(),
    );

    // Resolve so React can clean up
    resolve(envelope({ virtual_ip: VIP_WITH_FAILOVER }));
    await waitFor(() =>
      expect(screen.queryByText(/Failing over/i)).not.toBeInTheDocument(),
    );
  });

  // ── Error handling ────────────────────────────────────────────────────────

  it('adds an error notification when the API call rejects with an Error', async () => {
    mockPost.mockRejectedValueOnce(new Error('Network unreachable'));

    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /confirm failover/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network unreachable',
      }),
    );
    expect(mockOnFailedOver).not.toHaveBeenCalled();
  });

  it('adds a generic error notification when the API rejects with a non-Error', async () => {
    mockPost.mockRejectedValueOnce('some string error');

    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /confirm failover/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failover failed',
      }),
    );
  });

  it('re-enables the button and restores label after an API error', async () => {
    mockPost.mockRejectedValueOnce(new Error('Timeout'));

    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /confirm failover/i }));

    await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());

    const btn = screen.getByRole('button', { name: /confirm failover/i });
    expect(btn).not.toBeDisabled();
  });
});
