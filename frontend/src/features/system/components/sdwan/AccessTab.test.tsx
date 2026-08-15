import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { AccessTab } from './AccessTab';
import type {
  SdwanAccessGrant,
  SdwanUserDevice,
  SdwanIssueUserDeviceResponse,
} from '../../types/sdwan.types';

// =============================================================================
// Mocks
//
// AccessTab calls sdwanApi directly (not apiClient). We mock the whole module
// so we can control each async method independently. Child modals
// (AccessGrantCreateModal, UserDeviceIssueModal, BootstrapUrlModal) use the
// same sdwanApi module and the same notification hook — they are rendered by
// the parent so their interactions flow through.
// =============================================================================

const mockGetAccessGrants = jest.fn();
const mockGetUserDevices = jest.fn();
const mockRevokeAccessGrant = jest.fn();
const mockRevokeUserDevice = jest.fn();
const mockCreateAccessGrant = jest.fn();
const mockIssueUserDevice = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    getAccessGrants: (...a: unknown[]) => mockGetAccessGrants(...a),
    getUserDevices: (...a: unknown[]) => mockGetUserDevices(...a),
    revokeAccessGrant: (...a: unknown[]) => mockRevokeAccessGrant(...a),
    revokeUserDevice: (...a: unknown[]) => mockRevokeUserDevice(...a),
    createAccessGrant: (...a: unknown[]) => mockCreateAccessGrant(...a),
    issueUserDevice: (...a: unknown[]) => mockIssueUserDevice(...a),
  },
}));

const mockHasPermission = jest.fn().mockReturnValue(true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (perm: string) => mockHasPermission(perm),
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

const GRANT_A: SdwanAccessGrant = {
  id: 'grant-a',
  network_id: NETWORK_ID,
  user_id: 'user-001',
  user_email: 'alice@example.com',
  status: 'active',
  tags: ['vpn-pilot'],
  granted_at: '2026-01-15T10:00:00Z',
  granted_by_user_id: 'user-admin',
  revoked_at: null,
  revocation_reason: null,
  device_count: 1,
  created_at: '2026-01-15T10:00:00Z',
};

const GRANT_B: SdwanAccessGrant = {
  id: 'grant-b',
  network_id: NETWORK_ID,
  user_id: 'user-002',
  user_email: 'bob@example.com',
  status: 'revoked',
  tags: [],
  granted_at: '2026-01-10T08:00:00Z',
  granted_by_user_id: 'user-admin',
  revoked_at: '2026-03-01T00:00:00Z',
  revocation_reason: 'left company',
  device_count: 0,
  created_at: '2026-01-10T08:00:00Z',
};

const DEVICE_A: SdwanUserDevice = {
  id: 'device-a',
  access_grant_id: 'grant-a',
  network_id: NETWORK_ID,
  label: 'macbook',
  public_key: 'pubkey-a==',
  assigned_address: 'fd00::10/128',
  downloadable: true,
  last_downloaded_at: '2026-02-01T12:00:00Z',
  last_seen_at: '2026-05-01T09:00:00Z',
  revoked_at: null,
  created_at: '2026-01-16T08:00:00Z',
};

const DEVICE_B: SdwanUserDevice = {
  id: 'device-b',
  access_grant_id: 'grant-a',
  network_id: NETWORK_ID,
  label: 'iphone',
  public_key: 'pubkey-b==',
  assigned_address: 'fd00::11/128',
  downloadable: true,
  last_downloaded_at: null,
  last_seen_at: null,
  revoked_at: null,
  created_at: '2026-01-20T08:00:00Z',
};

const DEVICE_REVOKED: SdwanUserDevice = {
  id: 'device-c',
  access_grant_id: 'grant-a',
  network_id: NETWORK_ID,
  label: 'old-tablet',
  public_key: 'pubkey-c==',
  assigned_address: 'fd00::12/128',
  downloadable: false,
  last_downloaded_at: '2026-01-20T10:00:00Z',
  last_seen_at: null,
  revoked_at: '2026-03-01T00:00:00Z',
  created_at: '2026-01-20T08:00:00Z',
};

// =============================================================================
// Helper
// =============================================================================

const renderTab = (props: { networkId?: string; refreshKey?: number } = {}) =>
  render(
    <BrowserRouter>
      <AccessTab networkId={props.networkId ?? NETWORK_ID} refreshKey={props.refreshKey} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('AccessTab', () => {
  beforeEach(() => {
    mockGetAccessGrants.mockReset();
    mockGetUserDevices.mockReset();
    mockRevokeAccessGrant.mockReset();
    mockRevokeUserDevice.mockReset();
    mockCreateAccessGrant.mockReset();
    mockIssueUserDevice.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows loading text while fetching', () => {
    // Never resolves → stays in loading state
    mockGetAccessGrants.mockImplementation(() => new Promise(() => {}));

    renderTab();

    expect(screen.getByText(/Loading access state/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows error message when getAccessGrants rejects', async () => {
    mockGetAccessGrants.mockRejectedValue(new Error('Network timeout'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
  });

  it('shows generic error when rejection is not an Error instance', async () => {
    mockGetAccessGrants.mockRejectedValue('boom');

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Failed to load access state')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders empty state when there are no grants', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [] });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/No users have access yet/i)).toBeInTheDocument(),
    );

    expect(screen.getByText(/Grant a user access first/i)).toBeInTheDocument();
    // Summary line shows 0 grants, 0 devices
    expect(screen.getByText(/0 grants/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Populated state
  // ---------------------------------------------------------------------------

  it('renders summary counts — grants and total devices', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A, GRANT_B] });
    mockGetUserDevices
      .mockResolvedValueOnce({ devices: [DEVICE_A, DEVICE_B] }) // grant-a
      .mockResolvedValueOnce({ devices: [] }); // grant-b

    renderTab();

    // 2 grants · 2 devices total
    await waitFor(() => expect(screen.getByText(/2 grants/i)).toBeInTheDocument());
    expect(screen.getByText(/2 devices total/i)).toBeInTheDocument();
  });

  it('shows grant user email and status', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());
    expect(screen.getByText(/active/)).toBeInTheDocument();
  });

  it('falls back to user_id when user_email is absent', async () => {
    const grantNoEmail: SdwanAccessGrant = { ...GRANT_A, user_email: undefined };
    mockGetAccessGrants.mockResolvedValue({ grants: [grantNoEmail] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText('user-001')).toBeInTheDocument());
  });

  it('shows tags when present', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText(/tags: vpn-pilot/i)).toBeInTheDocument());
  });

  it('shows "No devices issued yet" when a grant has no devices', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText(/No devices issued yet/i)).toBeInTheDocument());
  });

  it('renders device rows with label, address, and status', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_A, DEVICE_B] });

    renderTab();

    await waitFor(() => expect(screen.getByText('macbook')).toBeInTheDocument());
    expect(screen.getByText('iphone')).toBeInTheDocument();
    expect(screen.getByText('fd00::10/128')).toBeInTheDocument();
    expect(screen.getByText('fd00::11/128')).toBeInTheDocument();

    // DEVICE_A has been downloaded → "active"
    expect(screen.getByText('active')).toBeInTheDocument();
    // DEVICE_B has not been downloaded → "pending download"
    expect(screen.getByText('pending download')).toBeInTheDocument();
  });

  it('shows "revoked" status for a revoked device and omits revoke action', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_REVOKED] });

    renderTab();

    await waitFor(() => expect(screen.getByText('revoked')).toBeInTheDocument());
    // No revoke button since device already revoked
    expect(screen.queryByLabelText(/Revoke old-tablet/i)).not.toBeInTheDocument();
  });

  it('calls getUserDevices per grant with correct networkId and grantId', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A, GRANT_B] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(mockGetUserDevices).toHaveBeenCalledTimes(2));
    expect(mockGetUserDevices).toHaveBeenCalledWith(NETWORK_ID, 'grant-a');
    expect(mockGetUserDevices).toHaveBeenCalledWith(NETWORK_ID, 'grant-b');
  });

  it('gracefully handles a getUserDevices error by showing empty device list', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockRejectedValue(new Error('Devices fetch failed'));

    renderTab();

    // Should still render the grant row, just with empty devices
    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());
    expect(screen.getByText(/No devices issued yet/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  it('hides "Grant access" button and action buttons when canManage is false', async () => {
    mockHasPermission.mockReturnValue(false);
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_A] });

    renderTab();

    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());

    expect(screen.queryByRole('button', { name: /Grant access/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Issue device/i })).not.toBeInTheDocument();
    // No "Revoke" grant button (canManage=false)
    expect(screen.queryByRole('button', { name: /^Revoke$/i })).not.toBeInTheDocument();
    // No per-device revoke action button
    expect(screen.queryByLabelText(/Revoke macbook/i)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // "Grant access" button opens modal
  // ---------------------------------------------------------------------------

  it('opens AccessGrantCreateModal when "Grant access" button is clicked', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText(/No users have access yet/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Grant access/i }));

    await waitFor(() =>
      expect(screen.getByText(/Grant network access to user/i)).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Revoke access grant confirmation flow
  // ---------------------------------------------------------------------------

  it('opens revoke grant confirmation when Revoke button is clicked', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());

    // Click the Revoke button in the grant header
    const revokeButtons = screen.getAllByRole('button', { name: /^Revoke$/i });
    fireEvent.click(revokeButtons[0]);

    await waitFor(() =>
      expect(screen.getByText(/Revoke access grant/i)).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/Revoke access for/i),
    ).toBeInTheDocument();
    expect(screen.getByText(/cascades to revoke all of the user's devices/i)).toBeInTheDocument();
  });

  it('calls revokeAccessGrant with correct args and shows success notification', async () => {
    // First load
    mockGetAccessGrants.mockResolvedValueOnce({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });
    mockRevokeAccessGrant.mockResolvedValue({ ...GRANT_A, status: 'revoked' });
    // Second load after triggerLocalRefresh
    mockGetAccessGrants.mockResolvedValue({ grants: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());

    // Click the Revoke button in the grant header row
    const revokeButtons = screen.getAllByRole('button', { name: /^Revoke$/i });
    fireEvent.click(revokeButtons[0]);

    // Wait for the confirmation modal heading
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /Revoke access grant/i })).toBeInTheDocument(),
    );

    // Scope to the modal dialog to avoid ambiguity with the row's Revoke button
    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: /^Revoke$/i }));

    await waitFor(() =>
      expect(mockRevokeAccessGrant).toHaveBeenCalledWith(NETWORK_ID, 'grant-a'),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Grant revoked',
      }),
    );
  });

  it('shows error notification when revokeAccessGrant fails', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });
    mockRevokeAccessGrant.mockRejectedValue(new Error('Server error'));

    renderTab();

    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());

    const revokeButtons = screen.getAllByRole('button', { name: /^Revoke$/i });
    fireEvent.click(revokeButtons[0]);

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /Revoke access grant/i })).toBeInTheDocument(),
    );

    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: /^Revoke$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Server error',
      }),
    );
  });

  it('dismisses revoke grant modal when Cancel is clicked', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());

    const revokeButtons = screen.getAllByRole('button', { name: /^Revoke$/i });
    fireEvent.click(revokeButtons[0]);

    await waitFor(() => expect(screen.getByText(/Revoke access grant/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText(/Revoke access grant/i)).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Revoked grant: hides Issue device + Revoke buttons
  // ---------------------------------------------------------------------------

  it('does not show Issue device or Revoke buttons for a revoked grant', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_B] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText('bob@example.com')).toBeInTheDocument());

    expect(screen.queryByRole('button', { name: /Issue device/i })).not.toBeInTheDocument();
    // No "Revoke" button for grant row (grant is already revoked)
    expect(screen.queryByRole('button', { name: /^Revoke$/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // "Issue device" flow opens UserDeviceIssueModal
  // ---------------------------------------------------------------------------

  it('opens UserDeviceIssueModal when "Issue device" is clicked', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Issue device/i }));

    await waitFor(() =>
      expect(screen.getByText(/Issue VPN device/i)).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Revoke device confirmation flow
  // ---------------------------------------------------------------------------

  it('shows revoke button per non-revoked device and opens confirmation modal', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_A] });

    renderTab();

    await waitFor(() => expect(screen.getByText('macbook')).toBeInTheDocument());

    expect(screen.getByLabelText('Revoke macbook')).toBeInTheDocument();

    fireEvent.click(screen.getByLabelText('Revoke macbook'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /Revoke device/i })).toBeInTheDocument(),
    );
    expect(screen.getByText(/The agent drops it from the hub view/i)).toBeInTheDocument();
  });

  it('calls revokeUserDevice with correct network, grant, device IDs and shows success', async () => {
    mockGetAccessGrants.mockResolvedValueOnce({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_A] });
    mockRevokeUserDevice.mockResolvedValue({ ...DEVICE_A, revoked_at: '2026-06-01T00:00:00Z' });
    // After local refresh
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });

    renderTab();

    await waitFor(() => expect(screen.getByText('macbook')).toBeInTheDocument());

    fireEvent.click(screen.getByLabelText('Revoke macbook'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /Revoke device/i })).toBeInTheDocument(),
    );

    // Scope to dialog to avoid ambiguity with any table-row Revoke buttons
    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: /^Revoke$/i }));

    await waitFor(() =>
      expect(mockRevokeUserDevice).toHaveBeenCalledWith(NETWORK_ID, 'grant-a', 'device-a'),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Device revoked',
      }),
    );
  });

  it('shows error notification when revokeUserDevice fails', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_A] });
    mockRevokeUserDevice.mockRejectedValue(new Error('Revoke failed'));

    renderTab();

    await waitFor(() => expect(screen.getByText('macbook')).toBeInTheDocument());

    fireEvent.click(screen.getByLabelText('Revoke macbook'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /Revoke device/i })).toBeInTheDocument(),
    );

    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: /^Revoke$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Revoke failed',
      }),
    );
  });

  it('dismisses revoke device modal on Cancel', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_A] });

    renderTab();

    await waitFor(() => expect(screen.getByText('macbook')).toBeInTheDocument());

    fireEvent.click(screen.getByLabelText('Revoke macbook'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /Revoke device/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText(/The agent drops it from the hub view/i)).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Refresh key
  // ---------------------------------------------------------------------------

  it('re-fetches when refreshKey prop changes', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [] });

    const { rerender } = renderTab({ refreshKey: 0 });

    await waitFor(() => expect(mockGetAccessGrants).toHaveBeenCalledTimes(1));

    // Simulate parent bumping the refreshKey
    mockGetAccessGrants.mockResolvedValue({ grants: [] });

    rerender(
      <BrowserRouter>
        <AccessTab networkId={NETWORK_ID} refreshKey={1} />
      </BrowserRouter>,
    );

    await waitFor(() => expect(mockGetAccessGrants).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Singular vs plural grammar
  // ---------------------------------------------------------------------------

  it('uses singular "grant" and "device" when counts are 1', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_A] });

    renderTab();

    // "1 grant · 1 device total"
    await waitFor(() => {
      const summary = screen.getByText(/1 grant\b/);
      expect(summary).toBeInTheDocument();
    });
    expect(screen.getByText(/1 device total/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Date rendering
  // ---------------------------------------------------------------------------

  it('renders "—" for granted_at when null', async () => {
    const grantNoDate: SdwanAccessGrant = { ...GRANT_A, granted_at: null };
    mockGetAccessGrants.mockResolvedValue({ grants: [grantNoDate] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText(/—/)).toBeInTheDocument());
  });

  it('renders "—" for last_downloaded_at when null', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_B] });

    renderTab();

    await waitFor(() => expect(screen.getByText('iphone')).toBeInTheDocument());
    // DEVICE_B.last_downloaded_at is null → the table shows "—"
    const cells = screen.getAllByText('—');
    expect(cells.length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // AccessGrantCreateModal: submit flow
  // ---------------------------------------------------------------------------

  it('calls createAccessGrant and triggers refresh after modal submit', async () => {
    mockGetAccessGrants.mockResolvedValueOnce({ grants: [] });
    mockCreateAccessGrant.mockResolvedValue(GRANT_A);
    // Refresh response
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText(/No users have access yet/i)).toBeInTheDocument());

    // Click the "Grant access" button in the header
    fireEvent.click(screen.getByRole('button', { name: /Grant access/i }));

    await waitFor(() =>
      expect(screen.getByText(/Grant network access to user/i)).toBeInTheDocument(),
    );

    // Fill and submit the modal form — there are now 2 "Grant access" buttons:
    // the header button (background) and the modal submit button.
    // Use the form's submit button specifically.
    const userIdInput = screen.getByPlaceholderText(/019d/i);
    fireEvent.change(userIdInput, { target: { value: 'user-001' } });

    // Submit via the form submit button inside the modal
    const form = userIdInput.closest('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockCreateAccessGrant).toHaveBeenCalledWith(NETWORK_ID, {
        user_id: 'user-001',
        tags: [],
      }),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Access grant created',
      }),
    );
  });

  it('shows error notification when AccessGrantCreateModal submit fails', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [] });
    mockCreateAccessGrant.mockRejectedValue(new Error('User not found'));

    renderTab();

    await waitFor(() => expect(screen.getByText(/No users have access yet/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Grant access/i }));

    await waitFor(() =>
      expect(screen.getByText(/Grant network access to user/i)).toBeInTheDocument(),
    );

    const userIdInput = screen.getByPlaceholderText(/019d/i);
    fireEvent.change(userIdInput, { target: { value: 'user-bad' } });

    const form = userIdInput.closest('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'User not found',
      }),
    );
  });

  it('shows validation error in AccessGrantCreateModal when user ID is empty', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [] });

    renderTab();

    await waitFor(() => expect(screen.getByText(/No users have access yet/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Grant access/i }));

    await waitFor(() =>
      expect(screen.getByText(/Grant network access to user/i)).toBeInTheDocument(),
    );

    // Submit without entering a user ID
    fireEvent.submit(screen.getByPlaceholderText(/019d/i).closest('form')!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'User ID is required',
      }),
    );
    // API should NOT be called
    expect(mockCreateAccessGrant).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // UserDeviceIssueModal: submit flow and BootstrapUrlModal
  // ---------------------------------------------------------------------------

  it('calls issueUserDevice with correct args and shows BootstrapUrlModal on success', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });

    const issueResult: SdwanIssueUserDeviceResponse = {
      user_device: DEVICE_A,
      bootstrap: {
        token: 'tok-abc',
        url: '/api/v1/bootstrap/tok-abc',
        expires_at: '2026-06-05T23:00:00Z',
      },
    };
    mockIssueUserDevice.mockResolvedValue(issueResult);
    // After local refresh
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_A] });

    renderTab();

    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Issue device/i }));

    await waitFor(() =>
      expect(screen.getByText(/Issue VPN device/i)).toBeInTheDocument(),
    );

    // Fill label and submit
    const labelInput = screen.getByPlaceholderText(/macbook/i);
    fireEvent.change(labelInput, { target: { value: 'macbook' } });

    fireEvent.click(screen.getByRole('button', { name: /^Issue$/i }));

    await waitFor(() =>
      expect(mockIssueUserDevice).toHaveBeenCalledWith(NETWORK_ID, 'grant-a', { label: 'macbook' }),
    );

    // BootstrapUrlModal should appear with the device label in title
    await waitFor(() =>
      expect(screen.getByText(/Bootstrap URL — macbook/i)).toBeInTheDocument(),
    );
    // Single-use warning shown
    expect(screen.getByText(/Single-use, expires/i)).toBeInTheDocument();
  });

  it('shows error notification when issueUserDevice fails', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });
    mockIssueUserDevice.mockRejectedValue(new Error('Keypair generation failed'));

    renderTab();

    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Issue device/i }));

    await waitFor(() =>
      expect(screen.getByText(/Issue VPN device/i)).toBeInTheDocument(),
    );

    const labelInput = screen.getByPlaceholderText(/macbook/i);
    fireEvent.change(labelInput, { target: { value: 'work-laptop' } });

    fireEvent.click(screen.getByRole('button', { name: /^Issue$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Keypair generation failed',
      }),
    );
    // BootstrapUrlModal should NOT appear
    expect(screen.queryByText(/Bootstrap URL/i)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // getAccessGrants called with correct networkId
  // ---------------------------------------------------------------------------

  it('calls getAccessGrants with the provided networkId', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [] });

    renderTab({ networkId: 'net-xyz789' });

    await waitFor(() => expect(mockGetAccessGrants).toHaveBeenCalledWith('net-xyz789'));
  });

  // ---------------------------------------------------------------------------
  // Pending-approval branch (IMP-87ec6f651f07)
  // ---------------------------------------------------------------------------

  const PENDING_APPROVAL = {
    pending: true,
    deferred_operation_id: 'dop-1',
    action_category: 'sdwan.access_grant_revoke',
    approval_request_id: 'ar-1',
    message: 'Approval required',
  };

  it('shows the pending-approval notification (not success) when the grant revoke is parked', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [] });
    mockRevokeAccessGrant.mockResolvedValue(PENDING_APPROVAL);

    renderTab();

    await waitFor(() => expect(screen.getByText('alice@example.com')).toBeInTheDocument());

    const revokeButtons = screen.getAllByRole('button', { name: /^Revoke$/i });
    fireEvent.click(revokeButtons[0]);

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /Revoke access grant/i })).toBeInTheDocument(),
    );

    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: /^Revoke$/i }));

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

  it('shows the pending-approval notification (not success) when the device revoke is parked', async () => {
    mockGetAccessGrants.mockResolvedValue({ grants: [GRANT_A] });
    mockGetUserDevices.mockResolvedValue({ devices: [DEVICE_A] });
    mockRevokeUserDevice.mockResolvedValue({
      ...PENDING_APPROVAL,
      action_category: 'system.sdwan_user_device_revoke',
    });

    renderTab();

    await waitFor(() => expect(screen.getByText('macbook')).toBeInTheDocument());

    fireEvent.click(screen.getByLabelText('Revoke macbook'));

    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /Revoke device/i })).toBeInTheDocument(),
    );

    const dialog = screen.getByRole('dialog');
    fireEvent.click(within(dialog).getByRole('button', { name: /^Revoke$/i }));

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
