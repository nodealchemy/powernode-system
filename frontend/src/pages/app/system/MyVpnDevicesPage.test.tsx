import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { BrowserRouter } from 'react-router-dom';
import MyVpnDevicesPage from './MyVpnDevicesPage';
import type { SdwanMyDevice } from '@system/features/system/types/sdwan.types';

// =============================================================================
// Mocks
// =============================================================================

const mockListMyDevices = jest.fn();
const mockDownloadMyDeviceConfig = jest.fn();

jest.mock('@system/features/system/services/api/myDevicesApi', () => ({
  myDevicesApi: {
    listMyDevices: (...args: unknown[]) => mockListMyDevices(...args),
    downloadMyDeviceConfig: (...args: unknown[]) => mockDownloadMyDeviceConfig(...args),
  },
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
// Fixtures — the four states the API contract actually produces.
// =============================================================================

const device = (over: Partial<SdwanMyDevice> = {}): SdwanMyDevice => ({
  id: 'dev-1',
  label: 'Laptop',
  status: 'pending_download',
  retrievable: true,
  network_id: 'net-1',
  created_at: '2026-08-01T12:00:00Z',
  last_downloaded_at: null,
  ...over,
});

const PENDING = device();
const DOWNLOADED = device({
  id: 'dev-2',
  label: 'Phone',
  status: 'downloaded',
  last_downloaded_at: '2026-08-20T09:00:00Z',
});
const REVOKED = device({ id: 'dev-3', label: 'Old tablet', status: 'revoked', retrievable: false });
// THE DISCRIMINATING FIXTURE: never downloaded and not revoked — so its
// derived status is the same "pending_download" a downloadable device has —
// but the access grant behind it is suspended, so `owner_retrievable?` is
// false and the server would answer 410. A UI that reads `status` cannot tell
// this row from PENDING; a UI that reads `retrievable` can.
const PENDING_BUT_NOT_RETRIEVABLE = device({
  id: 'dev-4',
  label: 'Suspended workstation',
  status: 'pending_download',
  retrievable: false,
});

// A payload from a server that does not send `retrievable` at all (an older
// deploy, a partial serializer). Deliberately built by DELETING the field
// rather than setting it false, so the fixture pins the fail-CLOSED default
// and not merely the false branch.
const MISSING_RETRIEVABLE = (() => {
  const d = device({ id: 'dev-5', label: 'Unknown vintage' }) as Partial<SdwanMyDevice>;
  delete d.retrievable;
  return d as SdwanMyDevice;
})();

const renderPage = () =>
  render(
    <BrowserRouter>
      <MyVpnDevicesPage />
    </BrowserRouter>
  );

beforeEach(() => {
  mockListMyDevices.mockReset();
  mockDownloadMyDeviceConfig.mockReset();
  mockAddNotification.mockReset();
});

// =============================================================================
// Load / list states
// =============================================================================

describe('MyVpnDevicesPage — list states', () => {
  it('loads the caller-scoped device list on mount, with no filter argument', async () => {
    mockListMyDevices.mockResolvedValue([PENDING]);

    renderPage();

    await waitFor(() => expect(mockListMyDevices).toHaveBeenCalledTimes(1));
    expect(mockListMyDevices).toHaveBeenCalledWith();
    expect(await screen.findByText('Laptop')).toBeInTheDocument();
  });

  it('treats an empty list as a normal state, not an error', async () => {
    mockListMyDevices.mockResolvedValue([]);

    renderPage();

    expect(await screen.findByText('No VPN devices yet')).toBeInTheDocument();
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('shows the failure when the list request fails', async () => {
    mockListMyDevices.mockRejectedValue(new Error('boom'));

    renderPage();

    expect(await screen.findByRole('alert')).toHaveTextContent('boom');
  });

  // A transient failure on mount is exactly when a retry matters, and it is
  // the state most likely to hide the control (the table, and the refresh
  // control beside it, are not rendered).
  it('offers a retry in the error state, and recovers when the retry succeeds', async () => {
    mockListMyDevices.mockRejectedValueOnce(new Error('boom')).mockResolvedValueOnce([PENDING]);

    renderPage();
    await screen.findByRole('alert');

    await userEvent.click(screen.getByRole('button', { name: 'Refresh device list' }));

    expect(await screen.findByText('Laptop')).toBeInTheDocument();
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('offers a refresh in the empty state too', async () => {
    mockListMyDevices.mockResolvedValue([]);

    renderPage();
    await screen.findByText('No VPN devices yet');

    await userEvent.click(screen.getByRole('button', { name: 'Refresh device list' }));

    await waitFor(() => expect(mockListMyDevices).toHaveBeenCalledTimes(2));
  });
});

// =============================================================================
// The download control's gate — `retrievable`, NOT `status`
// =============================================================================

describe('MyVpnDevicesPage — download control gating', () => {
  it('offers a download for a retrievable device', async () => {
    mockListMyDevices.mockResolvedValue([PENDING]);

    renderPage();

    expect(
      await screen.findByRole('button', { name: 'Download config for Laptop' })
    ).toBeInTheDocument();
  });

  it('offers a re-download for an already-downloaded but still retrievable device', async () => {
    mockListMyDevices.mockResolvedValue([DOWNLOADED]);

    renderPage();

    const btn = await screen.findByRole('button', { name: 'Download config for Phone' });
    expect(btn).toHaveTextContent('Download again');
  });

  it('offers no download for a revoked device', async () => {
    mockListMyDevices.mockResolvedValue([REVOKED]);

    renderPage();

    await screen.findByText('Old tablet');
    expect(
      screen.queryByRole('button', { name: 'Download config for Old tablet' })
    ).not.toBeInTheDocument();
    expect(screen.getByTestId('unavailable-dev-3')).toHaveTextContent('Revoked');
  });

  // THE DISCRIMINATING TEST.
  //
  // A test that only checks "the button renders for a pending_download device"
  // passes against a UI that ignores `retrievable` entirely. This one fails
  // against exactly that UI: same status string, opposite expectation.
  it('offers NO download for a device that is pending_download but not retrievable', async () => {
    mockListMyDevices.mockResolvedValue([PENDING_BUT_NOT_RETRIEVABLE]);

    renderPage();

    await screen.findByText('Suspended workstation');
    // The status the server derived is identical to the downloadable row's...
    expect(screen.getByText('not downloaded yet')).toBeInTheDocument();
    // ...and yet no download is offered, because `retrievable` is false.
    expect(
      screen.queryByRole('button', { name: 'Download config for Suspended workstation' })
    ).not.toBeInTheDocument();
    expect(screen.getByTestId('unavailable-dev-4')).toHaveTextContent(
      'your access is not active'
    );
  });

  // Fail-closed on a malformed payload. Without this fixture, an
  // implementation written as `d.retrievable !== false ?` — which offers a
  // download whenever the field is absent or non-boolean — passes every other
  // test in this file.
  it('offers NO download when the payload omits `retrievable` entirely', async () => {
    mockListMyDevices.mockResolvedValue([MISSING_RETRIEVABLE]);

    renderPage();

    await screen.findByText('Unknown vintage');
    expect(
      screen.queryByRole('button', { name: 'Download config for Unknown vintage' })
    ).not.toBeInTheDocument();
    expect(screen.getByTestId('unavailable-dev-5')).toBeInTheDocument();
  });

  it('gates each row independently when both pending rows are listed together', async () => {
    mockListMyDevices.mockResolvedValue([PENDING, PENDING_BUT_NOT_RETRIEVABLE]);

    renderPage();

    await screen.findByText('Suspended workstation');
    // Same `status` on both rows; exactly one download button.
    expect(screen.getAllByText('not downloaded yet')).toHaveLength(2);
    expect(screen.getAllByRole('button', { name: /^Download config for/ })).toHaveLength(1);
    expect(
      screen.getByRole('button', { name: 'Download config for Laptop' })
    ).toBeInTheDocument();
  });
});

// =============================================================================
// Download behaviour
// =============================================================================

describe('MyVpnDevicesPage — downloading', () => {
  it('delegates to the JWT-carrying api helper and refreshes the now-stale row', async () => {
    mockListMyDevices.mockResolvedValue([PENDING]);
    mockDownloadMyDeviceConfig.mockResolvedValue(undefined);

    renderPage();
    await userEvent.click(
      await screen.findByRole('button', { name: 'Download config for Laptop' })
    );

    await waitFor(() =>
      expect(mockDownloadMyDeviceConfig).toHaveBeenCalledWith('dev-1', 'Laptop')
    );
    // The fetch stamped last_downloaded_at server-side, so the list is re-read.
    await waitFor(() => expect(mockListMyDevices).toHaveBeenCalledTimes(2));
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' })
    );
  });

  it("surfaces the server's refusal text and does not refresh on failure", async () => {
    mockListMyDevices.mockResolvedValue([PENDING]);
    mockDownloadMyDeviceConfig.mockRejectedValue(
      new Error('underlying access grant is not active')
    );

    renderPage();
    await userEvent.click(
      await screen.findByRole('button', { name: 'Download config for Laptop' })
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'underlying access grant is not active',
      })
    );
    // AND re-reads: a 410 means the server considers this row no longer
    // retrievable, so the cached `retrievable: true` that rendered the button
    // is now known-wrong. Not re-reading would leave a control that can only
    // ever 410 again.
    await waitFor(() => expect(mockListMyDevices).toHaveBeenCalledTimes(2));
  });

  it('drops the download control once the refresh after a 410 reports it unretrievable', async () => {
    mockListMyDevices
      .mockResolvedValueOnce([PENDING])
      .mockResolvedValueOnce([{ ...PENDING, retrievable: false }]);
    mockDownloadMyDeviceConfig.mockRejectedValue(
      new Error('underlying access grant is not active')
    );

    renderPage();
    await userEvent.click(
      await screen.findByRole('button', { name: 'Download config for Laptop' })
    );

    await waitFor(() =>
      expect(
        screen.queryByRole('button', { name: 'Download config for Laptop' })
      ).not.toBeInTheDocument()
    );
    expect(screen.getByTestId('unavailable-dev-1')).toBeInTheDocument();
  });

  it('warns that re-downloading spends any one-time setup link', async () => {
    mockListMyDevices.mockResolvedValue([DOWNLOADED]);

    renderPage();

    expect(
      await screen.findByText(/consumes any one-time setup link/i)
    ).toBeInTheDocument();
  });
});
