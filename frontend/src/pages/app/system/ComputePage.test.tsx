import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import ComputePage from './ComputePage';

// =============================================================================
// Mocks
//
// ComputePage is a routing hub that composes five tab orchestrators
// (NodesTab, UnclaimedDevicesTab, VolumesTab, ProvidersTab, NetworksTab) and
// PlatformInfraTab — each a heavy surface with their own API calls. We stub
// every child to a sentinel element so the hub's own concerns are testable in
// isolation:
//   - permission-gated tab visibility (6 tabs, each gated on a read permission)
//   - /app/system/compute/<slug> link targets + active-tab highlight
//   - per-tab header actions (Create Node, Create Volume, Add Provider,
//     Create Network) wired via onActionsReady callbacks
//   - the permission-denied empty state when no tab is visible
//   - the index redirect to the first visible tab
//   - the platform tab's nested wildcard route (platform/*)
// =============================================================================

// ---------------------------------------------------------------------------
// Permission + notification hooks
// ---------------------------------------------------------------------------

const mockHasPermission = jest.fn(() => true);

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (...args: unknown[]) => mockHasPermission(...args),
  }),
}));

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: jest.fn(),
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

// ---------------------------------------------------------------------------
// Action handle captures — module-level vars so tests can read them.
// ---------------------------------------------------------------------------

const mockNodesOpenCreate = jest.fn();
const mockVolumesOpenCreate = jest.fn();
const mockProvidersOpenCreate = jest.fn();
const mockNetworksOpenCreate = jest.fn();

// ---------------------------------------------------------------------------
// Child tab stubs.  onActionsReady stubs fire immediately on mount so the
// parent hub can wire header actions.
// ---------------------------------------------------------------------------

jest.mock('@system/features/system/components/compute', () => {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { useEffect } = require('react');
  return {
    NodesTab: (props: { onActionsReady?: (h: { openCreate: () => void } | null) => void }) => {
      useEffect(() => {
        props.onActionsReady?.({ openCreate: mockNodesOpenCreate });
        return () => props.onActionsReady?.(null);
        // eslint-disable-next-line react-hooks/exhaustive-deps
      }, []);
      return require('react').createElement('div', { 'data-testid': 'nodes-tab' }, 'NodesTab');
    },
    UnclaimedDevicesTab: () =>
      require('react').createElement(
        'div',
        { 'data-testid': 'unclaimed-devices-tab' },
        'UnclaimedDevicesTab',
      ),
    VolumesTab: (props: { onActionsReady?: (h: { openCreate: () => void } | null) => void }) => {
      useEffect(() => {
        props.onActionsReady?.({ openCreate: mockVolumesOpenCreate });
        return () => props.onActionsReady?.(null);
        // eslint-disable-next-line react-hooks/exhaustive-deps
      }, []);
      return require('react').createElement(
        'div',
        { 'data-testid': 'volumes-tab' },
        'VolumesTab',
      );
    },
    ProvidersTab: (props: { onActionsReady?: (h: { openCreate: () => void } | null) => void }) => {
      useEffect(() => {
        props.onActionsReady?.({ openCreate: mockProvidersOpenCreate });
        return () => props.onActionsReady?.(null);
        // eslint-disable-next-line react-hooks/exhaustive-deps
      }, []);
      return require('react').createElement(
        'div',
        { 'data-testid': 'providers-tab' },
        'ProvidersTab',
      );
    },
    NetworksTab: (props: { onActionsReady?: (h: { openCreate: () => void } | null) => void }) => {
      useEffect(() => {
        props.onActionsReady?.({ openCreate: mockNetworksOpenCreate });
        return () => props.onActionsReady?.(null);
        // eslint-disable-next-line react-hooks/exhaustive-deps
      }, []);
      return require('react').createElement(
        'div',
        { 'data-testid': 'networks-tab' },
        'NetworksTab',
      );
    },
  };
});

jest.mock('@system/features/system/components/platform/PlatformInfraTab', () => ({
  PlatformInfraTab: () =>
    require('react').createElement(
      'div',
      { 'data-testid': 'platform-infra-tab' },
      'PlatformInfraTab',
    ),
}));

// =============================================================================
// Helpers
// =============================================================================

/**
 * Render ComputePage inside a MemoryRouter at the given path.
 * The hub is registered at /app/system/compute/* so we nest it under the
 * same wildcard route to satisfy the component's inner <Routes>.
 */
const renderAt = (initialPath = '/app/system/compute/nodes') =>
  render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/app/system/compute/*" element={<ComputePage />} />
      </Routes>
    </MemoryRouter>,
  );

// All read permissions for the six tabs, plus all create permissions.
const ALL_PERMISSIONS = [
  'system.nodes.read',
  'system.unclaimed_devices.read',
  'system.volumes.read',
  'system.providers.read',
  'system.networks.read',
  'system.platform.read',
  'system.nodes.create',
  'system.volumes.create',
  'system.providers.create',
  'system.networks.create',
];

// =============================================================================
// Tests
// =============================================================================

describe('ComputePage', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockHasPermission.mockImplementation((perm: string) => ALL_PERMISSIONS.includes(perm));
  });

  // ---------------------------------------------------------------------------
  // Basic rendering
  // ---------------------------------------------------------------------------

  it('renders the page title "Compute"', () => {
    renderAt();
    expect(screen.getByRole('heading', { name: 'Compute', level: 1 })).toBeInTheDocument();
  });

  it('renders all 6 tab links when user has all permissions', () => {
    renderAt();
    expect(screen.getByRole('link', { name: 'Nodes' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Unclaimed Devices' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Volumes' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Providers' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Networks' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Platform' })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tab routing — each tab renders at the correct path
  // ---------------------------------------------------------------------------

  it('renders NodesTab at the /nodes path', () => {
    renderAt('/app/system/compute/nodes');
    expect(screen.getByTestId('nodes-tab')).toBeInTheDocument();
  });

  it('renders UnclaimedDevicesTab at the /unclaimed-devices path', () => {
    renderAt('/app/system/compute/unclaimed-devices');
    expect(screen.getByTestId('unclaimed-devices-tab')).toBeInTheDocument();
  });

  it('renders VolumesTab at the /volumes path', () => {
    renderAt('/app/system/compute/volumes');
    expect(screen.getByTestId('volumes-tab')).toBeInTheDocument();
  });

  it('renders ProvidersTab at the /providers path', () => {
    renderAt('/app/system/compute/providers');
    expect(screen.getByTestId('providers-tab')).toBeInTheDocument();
  });

  it('renders NetworksTab at the /networks path', () => {
    renderAt('/app/system/compute/networks');
    expect(screen.getByTestId('networks-tab')).toBeInTheDocument();
  });

  it('renders PlatformInfraTab at the /platform path', () => {
    renderAt('/app/system/compute/platform');
    expect(screen.getByTestId('platform-infra-tab')).toBeInTheDocument();
  });

  it('renders PlatformInfraTab on nested /platform/* sub-routes', () => {
    renderAt('/app/system/compute/platform/services');
    expect(screen.getByTestId('platform-infra-tab')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Active tab detection (border-theme-focus class)
  // ---------------------------------------------------------------------------

  it('marks the Nodes tab as active (border-theme-focus) on /nodes', () => {
    renderAt('/app/system/compute/nodes');
    const link = screen.getByRole('link', { name: 'Nodes' });
    expect(link.className).toContain('border-theme-focus');
  });

  it('marks the Volumes tab as active on /volumes', () => {
    renderAt('/app/system/compute/volumes');
    const link = screen.getByRole('link', { name: 'Volumes' });
    expect(link.className).toContain('border-theme-focus');
  });

  it('marks the Providers tab as active on /providers', () => {
    renderAt('/app/system/compute/providers');
    const link = screen.getByRole('link', { name: 'Providers' });
    expect(link.className).toContain('border-theme-focus');
  });

  it('marks the Networks tab as active on /networks', () => {
    renderAt('/app/system/compute/networks');
    const link = screen.getByRole('link', { name: 'Networks' });
    expect(link.className).toContain('border-theme-focus');
  });

  it('marks the Platform tab as active on /platform', () => {
    renderAt('/app/system/compute/platform');
    const link = screen.getByRole('link', { name: 'Platform' });
    expect(link.className).toContain('border-theme-focus');
  });

  it('marks the Platform tab as active on a nested /platform/services path', () => {
    renderAt('/app/system/compute/platform/services');
    const link = screen.getByRole('link', { name: 'Platform' });
    expect(link.className).toContain('border-theme-focus');
  });

  it('inactive tab links carry border-transparent class', () => {
    renderAt('/app/system/compute/nodes');
    const volumesLink = screen.getByRole('link', { name: 'Volumes' });
    expect(volumesLink.className).toContain('border-transparent');
  });

  // ---------------------------------------------------------------------------
  // Tab link hrefs
  // ---------------------------------------------------------------------------

  it('tab links point to the correct /app/system/compute/<slug> hrefs', () => {
    renderAt('/app/system/compute/nodes');

    expect(screen.getByRole('link', { name: 'Nodes' })).toHaveAttribute(
      'href',
      '/app/system/compute/nodes',
    );
    expect(screen.getByRole('link', { name: 'Unclaimed Devices' })).toHaveAttribute(
      'href',
      '/app/system/compute/unclaimed-devices',
    );
    expect(screen.getByRole('link', { name: 'Volumes' })).toHaveAttribute(
      'href',
      '/app/system/compute/volumes',
    );
    expect(screen.getByRole('link', { name: 'Providers' })).toHaveAttribute(
      'href',
      '/app/system/compute/providers',
    );
    expect(screen.getByRole('link', { name: 'Networks' })).toHaveAttribute(
      'href',
      '/app/system/compute/networks',
    );
    expect(screen.getByRole('link', { name: 'Platform' })).toHaveAttribute(
      'href',
      '/app/system/compute/platform',
    );
  });

  // ---------------------------------------------------------------------------
  // Default redirect — index route sends to the first visible tab
  // ---------------------------------------------------------------------------

  it('redirects from the bare /compute path to the first visible tab (nodes)', () => {
    renderAt('/app/system/compute/');
    expect(screen.getByTestId('nodes-tab')).toBeInTheDocument();
  });

  it('redirects to the first visible tab when only volumes permission is held', () => {
    mockHasPermission.mockImplementation((perm: string) =>
      ['system.volumes.read', 'system.volumes.create'].includes(perm),
    );
    renderAt('/app/system/compute/');
    expect(screen.getByTestId('volumes-tab')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permission gating — tab visibility
  // ---------------------------------------------------------------------------

  it('hides the Nodes tab when system.nodes.read is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.nodes.read' && perm !== 'system.nodes.create' &&
        ALL_PERMISSIONS.includes(perm),
    );
    renderAt('/app/system/compute/volumes');
    expect(screen.queryByRole('link', { name: 'Nodes' })).not.toBeInTheDocument();
  });

  it('hides the Unclaimed Devices tab when system.unclaimed_devices.read is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.unclaimed_devices.read' && ALL_PERMISSIONS.includes(perm),
    );
    renderAt('/app/system/compute/nodes');
    expect(screen.queryByRole('link', { name: 'Unclaimed Devices' })).not.toBeInTheDocument();
  });

  it('hides the Volumes tab when system.volumes.read is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.volumes.read' && perm !== 'system.volumes.create' &&
        ALL_PERMISSIONS.includes(perm),
    );
    renderAt('/app/system/compute/nodes');
    expect(screen.queryByRole('link', { name: 'Volumes' })).not.toBeInTheDocument();
  });

  it('hides the Providers tab when system.providers.read is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.providers.read' && perm !== 'system.providers.create' &&
        ALL_PERMISSIONS.includes(perm),
    );
    renderAt('/app/system/compute/nodes');
    expect(screen.queryByRole('link', { name: 'Providers' })).not.toBeInTheDocument();
  });

  it('hides the Networks tab when system.networks.read is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.networks.read' && perm !== 'system.networks.create' &&
        ALL_PERMISSIONS.includes(perm),
    );
    renderAt('/app/system/compute/nodes');
    expect(screen.queryByRole('link', { name: 'Networks' })).not.toBeInTheDocument();
  });

  it('hides the Platform tab when system.platform.read is absent', () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.platform.read' && ALL_PERMISSIONS.includes(perm),
    );
    renderAt('/app/system/compute/nodes');
    expect(screen.queryByRole('link', { name: 'Platform' })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // No-permission empty state
  // ---------------------------------------------------------------------------

  it('shows the permission-denied empty state when no tab is visible', () => {
    mockHasPermission.mockReturnValue(false);
    renderAt('/app/system/compute/nodes');
    expect(
      screen.getByText(/you don.*t have permission to view any compute resources/i),
    ).toBeInTheDocument();
  });

  it('does not render the tab nav when user has no tab permissions', () => {
    mockHasPermission.mockReturnValue(false);
    renderAt('/app/system/compute/nodes');
    expect(screen.queryByRole('link', { name: 'Nodes' })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Volumes' })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Header action — nodes tab "Create Node"
  // ---------------------------------------------------------------------------

  it('shows the "Create Node" action button on the nodes tab', async () => {
    renderAt('/app/system/compute/nodes');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create node/i })).toBeInTheDocument(),
    );
  });

  it('calls nodesActions.openCreate when "Create Node" is clicked', async () => {
    renderAt('/app/system/compute/nodes');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create node/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /create node/i }));
    expect(mockNodesOpenCreate).toHaveBeenCalledTimes(1);
  });

  it('does not show "Create Node" when system.nodes.create is absent', async () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.nodes.create' && ALL_PERMISSIONS.includes(perm),
    );
    renderAt('/app/system/compute/nodes');
    await waitFor(() => expect(screen.getByTestId('nodes-tab')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /create node/i })).not.toBeInTheDocument();
  });

  it('does not show "Create Node" on a non-nodes tab', () => {
    renderAt('/app/system/compute/volumes');
    expect(screen.queryByRole('button', { name: /create node/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Header action — volumes tab "Create Volume"
  // ---------------------------------------------------------------------------

  it('shows the "Create Volume" action button on the volumes tab', async () => {
    renderAt('/app/system/compute/volumes');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create volume/i })).toBeInTheDocument(),
    );
  });

  it('calls volumesActions.openCreate when "Create Volume" is clicked', async () => {
    renderAt('/app/system/compute/volumes');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create volume/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /create volume/i }));
    expect(mockVolumesOpenCreate).toHaveBeenCalledTimes(1);
  });

  it('does not show "Create Volume" when system.volumes.create is absent', async () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.volumes.create' && ALL_PERMISSIONS.includes(perm),
    );
    renderAt('/app/system/compute/volumes');
    await waitFor(() => expect(screen.getByTestId('volumes-tab')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /create volume/i })).not.toBeInTheDocument();
  });

  it('does not show "Create Volume" on a non-volumes tab', () => {
    renderAt('/app/system/compute/nodes');
    expect(screen.queryByRole('button', { name: /create volume/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Header action — providers tab "Add Provider"
  // ---------------------------------------------------------------------------

  it('shows the "Add Provider" action button on the providers tab', async () => {
    renderAt('/app/system/compute/providers');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add provider/i })).toBeInTheDocument(),
    );
  });

  it('calls providersActions.openCreate when "Add Provider" is clicked', async () => {
    renderAt('/app/system/compute/providers');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add provider/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
    expect(mockProvidersOpenCreate).toHaveBeenCalledTimes(1);
  });

  it('does not show "Add Provider" when system.providers.create is absent', async () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.providers.create' && ALL_PERMISSIONS.includes(perm),
    );
    renderAt('/app/system/compute/providers');
    await waitFor(() => expect(screen.getByTestId('providers-tab')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /add provider/i })).not.toBeInTheDocument();
  });

  it('does not show "Add Provider" on a non-providers tab', () => {
    renderAt('/app/system/compute/nodes');
    expect(screen.queryByRole('button', { name: /add provider/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Header action — networks tab "Create Network"
  // ---------------------------------------------------------------------------

  it('shows the "Create Network" action button on the networks tab', async () => {
    renderAt('/app/system/compute/networks');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create network/i })).toBeInTheDocument(),
    );
  });

  it('calls networksActions.openCreate when "Create Network" is clicked', async () => {
    renderAt('/app/system/compute/networks');
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /create network/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /create network/i }));
    expect(mockNetworksOpenCreate).toHaveBeenCalledTimes(1);
  });

  it('does not show "Create Network" when system.networks.create is absent', async () => {
    mockHasPermission.mockImplementation(
      (perm: string) =>
        perm !== 'system.networks.create' && ALL_PERMISSIONS.includes(perm),
    );
    renderAt('/app/system/compute/networks');
    await waitFor(() => expect(screen.getByTestId('networks-tab')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /create network/i })).not.toBeInTheDocument();
  });

  it('does not show "Create Network" on a non-networks tab', () => {
    renderAt('/app/system/compute/nodes');
    expect(screen.queryByRole('button', { name: /create network/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // No header action on tabs that don't have one
  // ---------------------------------------------------------------------------

  it('shows no create action button on the unclaimed-devices tab', async () => {
    renderAt('/app/system/compute/unclaimed-devices');
    await waitFor(() =>
      expect(screen.getByTestId('unclaimed-devices-tab')).toBeInTheDocument(),
    );
    expect(screen.queryByRole('button', { name: /create/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /add/i })).not.toBeInTheDocument();
  });

  it('shows no create action button on the platform tab', async () => {
    renderAt('/app/system/compute/platform');
    await waitFor(() =>
      expect(screen.getByTestId('platform-infra-tab')).toBeInTheDocument(),
    );
    expect(screen.queryByRole('button', { name: /create/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /add/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Action handle cleanup — no create button on tabs without one
  // ---------------------------------------------------------------------------

  it('shows no create action on unclaimed-devices (no onActionsReady callback)', async () => {
    renderAt('/app/system/compute/unclaimed-devices');
    await waitFor(() =>
      expect(screen.getByTestId('unclaimed-devices-tab')).toBeInTheDocument(),
    );
    // No create / add buttons — unclaimed-devices tab has no onActionsReady
    expect(screen.queryByRole('button', { name: /create node/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /create volume/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /add provider/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /create network/i })).not.toBeInTheDocument();
  });

  it('shows no create action button on the volumes tab when on nodes path', () => {
    renderAt('/app/system/compute/nodes');
    // Volumes create button should not appear when nodes tab is active
    expect(screen.queryByRole('button', { name: /create volume/i })).not.toBeInTheDocument();
  });
});
