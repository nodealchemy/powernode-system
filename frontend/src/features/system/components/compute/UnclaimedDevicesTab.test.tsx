import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { UnclaimedDevicesTab } from './UnclaimedDevicesTab';

// =============================================================================
// Mocks
//
// UnclaimedDevicesTab renders:
//   1. A permission gate — calls usePermissions().hasPermission('system.unclaimed_devices.read')
//   2. UnclaimedDevicesPanel — we stub it so its own API calls don't interfere
// =============================================================================

// Permission hook — default allows; individual tests override.
let mockHasPermission = jest.fn(() => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: (...args: unknown[]) => mockHasPermission(...args) }),
}));

// Stub UnclaimedDevicesPanel — it is tested independently in its own spec.
jest.mock('@system/features/system/components/nodes/UnclaimedDevicesPanel', () => ({
  UnclaimedDevicesPanel: () => (
    <div data-testid="unclaimed-devices-panel">UnclaimedDevicesPanel stub</div>
  ),
}));

// =============================================================================
// Helpers
// =============================================================================

const renderTab = () =>
  render(
    <BrowserRouter>
      <UnclaimedDevicesTab />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('UnclaimedDevicesTab', () => {
  beforeEach(() => {
    mockHasPermission = jest.fn(() => true);
  });

  // ---------------------------------------------------------------------------
  // Permission-gated render
  // ---------------------------------------------------------------------------

  it('renders the descriptive paragraph and the panel when the user has the required permission', async () => {
    renderTab();

    // Descriptive paragraph
    await waitFor(() =>
      expect(
        screen.getByText(/Physical devices that have polled/),
      ).toBeInTheDocument(),
    );

    // Panel stub is mounted
    expect(screen.getByTestId('unclaimed-devices-panel')).toBeInTheDocument();
  });

  it('checks the exact permission key system.unclaimed_devices.read', async () => {
    renderTab();

    await waitFor(() =>
      expect(mockHasPermission).toHaveBeenCalledWith('system.unclaimed_devices.read'),
    );
  });

  it('renders the access-denied message when permission is absent', async () => {
    mockHasPermission = jest.fn(() => false);

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText(/You don't have permission to view unclaimed devices/),
      ).toBeInTheDocument(),
    );

    // The required permission name is shown inline
    expect(screen.getByText('system.unclaimed_devices.read')).toBeInTheDocument();
  });

  it('does NOT render UnclaimedDevicesPanel when permission is absent', async () => {
    mockHasPermission = jest.fn(() => false);

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText(/You don't have permission to view unclaimed devices/),
      ).toBeInTheDocument(),
    );

    expect(screen.queryByTestId('unclaimed-devices-panel')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Descriptive content (with permission)
  // ---------------------------------------------------------------------------

  it('mentions the /api/v1/system/node_api/claim polling endpoint in the description', async () => {
    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText(/\/api\/v1\/system\/node_api\/claim/),
      ).toBeInTheDocument(),
    );
  });

  it('wraps the content in a space-y-4 container div', async () => {
    const { container } = renderTab();

    await waitFor(() =>
      expect(screen.getByTestId('unclaimed-devices-panel')).toBeInTheDocument(),
    );

    // The outer wrapper should carry the space-y-4 layout class
    const wrapper = container.querySelector('.space-y-4');
    expect(wrapper).not.toBeNull();
  });
});
