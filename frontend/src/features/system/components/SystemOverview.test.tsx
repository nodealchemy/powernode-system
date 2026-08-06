import React, { createRef } from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { SystemOverview, SystemOverviewHandle } from './SystemOverview';

// =============================================================================
// Mocks
//
// The Fleet-Command overview reads four lanes:
//   systemApi.getOverviewStats()      — the only lane allowed to fail the page
//   systemApi.getRecentActivity(5)    — soft
//   cveApi.list({ state: 'open' })    — soft (needs system.cve.read)
//   GET /system/instance_pools        — soft (pool readiness)
// plus the embedded <FleetTopology>, which reports a snapshot the strip
// derives boot-image drift from.
// =============================================================================

const mockGetOverviewStats = jest.fn();
const mockGetRecentActivity = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getOverviewStats: (...args: unknown[]) => mockGetOverviewStats(...args),
    getRecentActivity: (...args: unknown[]) => mockGetRecentActivity(...args),
  },
}));

const mockCveList = jest.fn();

jest.mock('@system/features/system/services/api/cveApi', () => ({
  cveApi: {
    list: (...args: unknown[]) => mockCveList(...args),
  },
}));

const mockApiGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockApiGet(...args),
  },
}));

// FleetTopology is exercised by its own suite (and pulls @xyflow/react +
// its stylesheet). Here we only care that the overview embeds it and folds
// the snapshot it reports into the drift signal.
let mockSnapshot: unknown = null;

jest.mock('./topology/FleetTopology', () => {
  const ReactLib = jest.requireActual<typeof import('react')>('react');
  return {
    FleetTopology: ({
      refreshKey,
      onSnapshot,
    }: {
      refreshKey?: number;
      onSnapshot?: (snapshot: unknown) => void;
    }) => {
      ReactLib.useEffect(() => {
        if (mockSnapshot) onSnapshot?.(mockSnapshot);
      }, [onSnapshot, refreshKey]);
      return ReactLib.createElement('div', {
        'data-testid': 'fleet-topology',
        'data-refresh-key': String(refreshKey),
      });
    },
  };
});

// useNavigate — captured so we can assert the canonical hub paths.
const mockNavigate = jest.fn();
jest.mock('react-router-dom', () => ({
  ...jest.requireActual('react-router-dom'),
  useNavigate: () => mockNavigate,
}));

// =============================================================================
// Fixtures
// =============================================================================

const baseStats = {
  nodes: { total: 4, enabled: 3, disabled: 1 },
  instances: { total: 10, running: 7, stopped: 2, pending: 1 },
  templates: { total: 2, public: 1, private: 1 },
  platforms: { total: 3, enabled: 2 },
  providers: { total: 2, enabled: 2, types: ['proxmox', 'aws'] },
  regions: { total: 5 },
  modules: {
    total: 6,
    enabled: 5,
    by_variety: { config: 3, instance: 2, subscription: 1 },
  },
  operations: { total: 10, pending: 2, running: 1, completed: 6, failed: 1 },
  puppet: { modules: 4, resources: 12, assignments: 3 },
  volumes: { total: 2, total_size_gb: 120 },
  networks: { total: 0 },
};

const statsWithSdwan = {
  ...baseStats,
  sdwan: {
    networks: 2,
    host_bridges: 3,
    bridges_by_kind: { linux: 2, ovs: 1 },
    ovn_deployments: 1,
    ovn_active: 1,
    ipfix_collectors: 2,
    ipfix_active: 2,
  },
};

const statsWithSdwanZero = {
  ...baseStats,
  sdwan: {
    networks: 0,
    host_bridges: 0,
    bridges_by_kind: { linux: 0, ovs: 0 },
    ovn_deployments: 0,
    ovn_active: 0,
    ipfix_collectors: 0,
    ipfix_active: 0,
  },
};

const recentActivities = [
  {
    id: 'task-1',
    type: 'operation' as const,
    action: 'provision_node',
    description: 'Provisioning node alpha',
    status: 'complete',
    entity_name: 'Node',
    entity_id: 'node-1',
    initiated_by: 'admin',
    timestamp: '2026-05-01T12:00:00Z',
  },
  {
    id: 'task-2',
    type: 'operation' as const,
    action: 'deploy_module',
    description: 'Deploying base-config',
    status: 'running',
    entity_name: 'Module',
    entity_id: 'mod-1',
    initiated_by: undefined,
    timestamp: '2026-05-01T11:00:00Z',
  },
  {
    id: 'task-3',
    type: 'operation' as const,
    action: 'sync_puppet',
    description: 'Syncing puppet resources',
    status: 'failed',
    entity_name: 'Puppet',
    entity_id: 'pup-1',
    initiated_by: 'ops-bot',
    timestamp: '2026-05-01T10:00:00Z',
  },
];

/** Two drifted instances across two nodes; one clean instance. */
const snapshotWithDrift = {
  groups: [],
  networks: [],
  memberships: [],
  truncatedNodeCount: 0,
  totalNodeCount: 2,
  nodes: [
    {
      node: { id: 'n1' },
      groupId: 'g1',
      modules: [],
      hiddenInstanceCount: 0,
      instancesLoaded: true,
      instances: [
        { id: 'i1', boot_image_drifted: true },
        { id: 'i2', boot_image_drifted: false },
      ],
    },
    {
      node: { id: 'n2' },
      groupId: 'g1',
      modules: [],
      hiddenInstanceCount: 0,
      instancesLoaded: true,
      instances: [{ id: 'i3', boot_image_drifted: true }],
    },
  ],
};

const snapshotClean = {
  ...snapshotWithDrift,
  nodes: [
    {
      ...snapshotWithDrift.nodes[0],
      instances: [{ id: 'i1', boot_image_drifted: false }],
    },
  ],
};

const poolsEnvelope = (pools: Array<{ ready_count: number; target_size: number }>) => ({
  data: { success: true, data: { pools } },
});

// =============================================================================
// Helpers
// =============================================================================

const renderComponent = (props: { className?: string } = {}) =>
  render(
    <BrowserRouter>
      <SystemOverview {...props} />
    </BrowserRouter>,
  );

const renderWithRef = () => {
  const ref = createRef<SystemOverviewHandle>();
  render(
    <BrowserRouter>
      <SystemOverview ref={ref} />
    </BrowserRouter>,
  );
  return { ref };
};

/** Status-strip cells, in render order: instances, drift, CVE, pools. */
const signals = () => screen.getAllByTestId('fleet-signal');

/** Inventory tiles, in render order. */
const INVENTORY = {
  nodes: 0,
  modules: 1,
  templates: 2,
  providers: 3,
  platforms: 4,
  puppet: 5,
  operations: 6,
  volumes: 7,
} as const;

const tile = (index: number) => screen.getAllByTestId('stat-tile')[index];

const happyPath = () => {
  mockGetOverviewStats.mockResolvedValue(baseStats);
  mockGetRecentActivity.mockResolvedValue([]);
  mockCveList.mockResolvedValue({ cve_exposures: [], meta: { total_count: 3 } });
  mockApiGet.mockResolvedValue(poolsEnvelope([{ ready_count: 4, target_size: 6 }]));
};

// =============================================================================
// Tests
// =============================================================================

describe('SystemOverview', () => {
  beforeEach(() => {
    mockGetOverviewStats.mockReset();
    mockGetRecentActivity.mockReset();
    mockCveList.mockReset();
    mockApiGet.mockReset();
    mockNavigate.mockReset();
    mockSnapshot = null;
  });

  // ---------------------------------------------------------------------------
  // Loading + error
  // ---------------------------------------------------------------------------

  describe('loading state', () => {
    it('renders skeletons while the primary stats lane is in flight', () => {
      mockGetOverviewStats.mockReturnValue(new Promise(() => {}));
      mockGetRecentActivity.mockReturnValue(new Promise(() => {}));
      mockCveList.mockReturnValue(new Promise(() => {}));
      mockApiGet.mockReturnValue(new Promise(() => {}));

      renderComponent();

      expect(document.querySelectorAll('.animate-pulse').length).toBeGreaterThan(0);
      expect(screen.queryByTestId('fleet-topology')).not.toBeInTheDocument();
    });
  });

  describe('error state', () => {
    it('shows the error message when the stats aggregate fails', async () => {
      mockGetOverviewStats.mockRejectedValue(new Error('Network timeout'));
      mockGetRecentActivity.mockResolvedValue([]);
      mockCveList.mockResolvedValue({ cve_exposures: [], meta: { total_count: 0 } });
      mockApiGet.mockResolvedValue(poolsEnvelope([]));

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('Failed to Load System Data')).toBeInTheDocument(),
      );
      expect(screen.getByText('Network timeout')).toBeInTheDocument();
    });

    it('shows a generic message for non-Error rejections', async () => {
      mockGetOverviewStats.mockRejectedValue('string error');
      mockGetRecentActivity.mockResolvedValue([]);
      mockCveList.mockResolvedValue({ cve_exposures: [], meta: { total_count: 0 } });
      mockApiGet.mockResolvedValue(poolsEnvelope([]));

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('Failed to load system data')).toBeInTheDocument(),
      );
    });

    it('retries the load when Retry is clicked', async () => {
      mockGetOverviewStats
        .mockRejectedValueOnce(new Error('Temporary failure'))
        .mockResolvedValueOnce(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);
      mockCveList.mockResolvedValue({ cve_exposures: [], meta: { total_count: 0 } });
      mockApiGet.mockResolvedValue(poolsEnvelope([]));

      renderComponent();

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /retry/i })).toBeInTheDocument(),
      );
      fireEvent.click(screen.getByRole('button', { name: /retry/i }));

      await waitFor(() => expect(screen.getByTestId('fleet-topology')).toBeInTheDocument());
      expect(mockGetOverviewStats).toHaveBeenCalledTimes(2);
    });
  });

  // ---------------------------------------------------------------------------
  // Status strip
  // ---------------------------------------------------------------------------

  describe('status strip', () => {
    it('renders four signals: instances, drift, CVE, pool readiness', async () => {
      happyPath();
      renderComponent();

      await waitFor(() => expect(signals()).toHaveLength(4));
      expect(within(signals()[0]).getByText('Instances')).toBeInTheDocument();
      expect(within(signals()[1]).getByText('Boot image drift')).toBeInTheDocument();
      expect(within(signals()[2]).getByText('Open CVE exposures')).toBeInTheDocument();
      expect(within(signals()[3]).getByText('Pool readiness')).toBeInTheDocument();
    });

    it('shows running instances over the fleet total', async () => {
      happyPath();
      renderComponent();

      await waitFor(() => expect(signals()).toHaveLength(4));
      expect(within(signals()[0]).getByText('7')).toBeInTheDocument();
      expect(within(signals()[0]).getByText('/ 10')).toBeInTheDocument();
      expect(within(signals()[0]).getByText(/3 not running/)).toBeInTheDocument();
    });

    it('derives the drift count from the fleet topology snapshot', async () => {
      happyPath();
      mockSnapshot = snapshotWithDrift;
      renderComponent();

      await waitFor(() => expect(within(signals()[1]).getByText('2')).toBeInTheDocument());
    });

    it('reports zero drift when every graphed instance is on its published image', async () => {
      happyPath();
      mockSnapshot = snapshotClean;
      renderComponent();

      await waitFor(() =>
        expect(
          within(signals()[1]).getByText(/Every graphed instance on its published image/),
        ).toBeInTheDocument(),
      );
    });

    it('renders an em-dash for drift until the graph reports', async () => {
      happyPath(); // mockSnapshot stays null — the graph never reports
      renderComponent();

      await waitFor(() => expect(signals()).toHaveLength(4));
      expect(within(signals()[1]).getByText('—')).toBeInTheDocument();
      expect(within(signals()[1]).getByText('Waiting on the fleet graph')).toBeInTheDocument();
    });

    it('shows the open CVE exposure count from the paginated meta', async () => {
      happyPath();
      renderComponent();

      await waitFor(() => expect(within(signals()[2]).getByText('3')).toBeInTheDocument());
      expect(mockCveList).toHaveBeenCalledWith({ state: 'open', per_page: 1 });
    });

    it('shows aggregate pool readiness with the warm percentage', async () => {
      happyPath();
      renderComponent();

      await waitFor(() => expect(within(signals()[3]).getByText('4')).toBeInTheDocument());
      expect(within(signals()[3]).getByText('/ 6')).toBeInTheDocument();
      expect(within(signals()[3]).getByText(/1 active pool · 67% warm/)).toBeInTheDocument();
    });

    it('sums readiness across every active pool', async () => {
      happyPath();
      mockApiGet.mockResolvedValue(
        poolsEnvelope([
          { ready_count: 2, target_size: 4 },
          { ready_count: 3, target_size: 4 },
        ]),
      );
      renderComponent();

      await waitFor(() => expect(within(signals()[3]).getByText('5')).toBeInTheDocument());
      expect(within(signals()[3]).getByText('/ 8')).toBeInTheDocument();
      expect(within(signals()[3]).getByText(/2 active pools/)).toBeInTheDocument();
    });

    it('navigates to the canonical hub path for each signal', async () => {
      happyPath();
      renderComponent();

      await waitFor(() => expect(signals()).toHaveLength(4));

      fireEvent.click(signals()[0]);
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/compute/nodes');
      fireEvent.click(signals()[1]);
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/operations/fleet');
      fireEvent.click(signals()[2]);
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/operations/cve');
      fireEvent.click(signals()[3]);
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/instance-pools');
    });
  });

  // ---------------------------------------------------------------------------
  // Fail-soft lanes
  // ---------------------------------------------------------------------------

  describe('fail-soft lanes', () => {
    it('keeps the page when the CVE lane 403s, showing an em-dash', async () => {
      happyPath();
      mockCveList.mockRejectedValue(new Error('Forbidden'));

      renderComponent();

      await waitFor(() => expect(signals()).toHaveLength(4));
      expect(within(signals()[2]).getByText('—')).toBeInTheDocument();
      expect(within(signals()[2]).getByText(/needs system\.cve\.read/)).toBeInTheDocument();
      // Fleet picture survives
      expect(screen.getByTestId('fleet-topology')).toBeInTheDocument();
    });

    it('keeps the page when the pool lane fails, showing an em-dash', async () => {
      happyPath();
      mockApiGet.mockRejectedValue(new Error('boom'));

      renderComponent();

      await waitFor(() => expect(signals()).toHaveLength(4));
      expect(within(signals()[3]).getByText('—')).toBeInTheDocument();
      expect(within(signals()[3]).getByText(/pools could not be read/)).toBeInTheDocument();
    });

    it('keeps the page when the recent-activity lane fails', async () => {
      happyPath();
      mockGetRecentActivity.mockRejectedValue(new Error('boom'));

      renderComponent();

      await waitFor(() => expect(screen.getByText('No recent activity')).toBeInTheDocument());
      expect(screen.getByTestId('fleet-topology')).toBeInTheDocument();
    });

    it('reports "No active pools" rather than a zero-warm warning when none exist', async () => {
      happyPath();
      mockApiGet.mockResolvedValue(poolsEnvelope([]));

      renderComponent();

      await waitFor(() => expect(within(signals()[3]).getByText('No active pools')).toBeInTheDocument());
    });
  });

  // ---------------------------------------------------------------------------
  // Embedded fleet topology
  // ---------------------------------------------------------------------------

  describe('fleet topology centrepiece', () => {
    it('embeds FleetTopology under a "Fleet" heading', async () => {
      happyPath();
      renderComponent();

      await waitFor(() => expect(screen.getByTestId('fleet-topology')).toBeInTheDocument());
      expect(screen.getByText('Fleet')).toBeInTheDocument();
    });

    it('links out to the standalone topology page', async () => {
      happyPath();
      renderComponent();

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /full view/i })).toBeInTheDocument(),
      );
      fireEvent.click(screen.getByRole('button', { name: /full view/i }));
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/topology');
    });

    it('bumps the topology refreshKey on an imperative refresh', async () => {
      happyPath();
      const { ref } = renderWithRef();

      await waitFor(() => expect(screen.getByTestId('fleet-topology')).toBeInTheDocument());
      const initial = screen.getByTestId('fleet-topology').getAttribute('data-refresh-key');

      await ref.current?.refresh();

      await waitFor(() =>
        expect(screen.getByTestId('fleet-topology').getAttribute('data-refresh-key')).not.toBe(
          initial,
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Inventory tiles (shared chart kit)
  // ---------------------------------------------------------------------------

  describe('inventory tiles', () => {
    beforeEach(happyPath);

    it('renders eight StatTiles from the shared chart kit', async () => {
      renderComponent();
      await waitFor(() => expect(screen.getAllByTestId('stat-tile')).toHaveLength(8));
    });

    it('renders the Nodes tile with an enabled/total meter', async () => {
      renderComponent();
      await waitFor(() => expect(screen.getAllByTestId('stat-tile').length).toBeGreaterThan(0));

      const nodes = tile(INVENTORY.nodes);
      expect(within(nodes).getByText('Nodes')).toBeInTheDocument();
      expect(within(nodes).getByTestId('stat-tile-value')).toHaveTextContent('4');
      expect(within(nodes).getByText('3 enabled · 1 disabled')).toBeInTheDocument();
      expect(within(nodes).getByTestId('meter-bar')).toBeInTheDocument();
    });

    it('renders the Modules tile with its variety breakdown', async () => {
      renderComponent();
      await waitFor(() => expect(screen.getAllByTestId('stat-tile').length).toBeGreaterThan(0));

      const modules = tile(INVENTORY.modules);
      expect(within(modules).getByText('Modules')).toBeInTheDocument();
      expect(
        within(modules).getByText('3 config · 2 instance · 1 subscription'),
      ).toBeInTheDocument();
    });

    it('folds provider types into the Providers tile', async () => {
      renderComponent();
      await waitFor(() => expect(screen.getAllByTestId('stat-tile').length).toBeGreaterThan(0));

      expect(
        within(tile(INVENTORY.providers)).getByText('5 regions · proxmox, aws'),
      ).toBeInTheDocument();
    });

    it('falls back to enabled/regions when no provider types are configured', async () => {
      mockGetOverviewStats.mockResolvedValue({
        ...baseStats,
        providers: { ...baseStats.providers, types: [] },
      });
      renderComponent();
      await waitFor(() => expect(screen.getAllByTestId('stat-tile').length).toBeGreaterThan(0));

      expect(
        within(tile(INVENTORY.providers)).getByText('2 enabled · 5 regions'),
      ).toBeInTheDocument();
    });

    it('renders the Operations tile with a pending/running/failed breakdown', async () => {
      renderComponent();
      await waitFor(() => expect(screen.getAllByTestId('stat-tile').length).toBeGreaterThan(0));

      expect(
        within(tile(INVENTORY.operations)).getByText('2 pending · 1 running · 1 failed'),
      ).toBeInTheDocument();
    });

    it.each<[keyof typeof INVENTORY, string]>([
      ['nodes', '/app/system/compute/nodes'],
      ['modules', '/app/system/catalog/modules'],
      ['templates', '/app/system/catalog/templates'],
      ['providers', '/app/system/compute/providers'],
      ['platforms', '/app/system/catalog/platforms'],
      ['puppet', '/app/system/catalog/puppet-modules'],
      ['operations', '/app/system/operations/tasks'],
      ['volumes', '/app/system/compute/volumes'],
    ])('navigates the %s tile to its canonical hub path', async (key, path) => {
      renderComponent();
      await waitFor(() => expect(screen.getAllByTestId('stat-tile')).toHaveLength(8));

      fireEvent.click(tile(INVENTORY[key]));
      expect(mockNavigate).toHaveBeenCalledWith(path);
    });
  });

  // ---------------------------------------------------------------------------
  // SDWAN section
  // ---------------------------------------------------------------------------

  describe('SDWAN section', () => {
    beforeEach(() => {
      mockGetRecentActivity.mockResolvedValue([]);
      mockCveList.mockResolvedValue({ cve_exposures: [], meta: { total_count: 0 } });
      mockApiGet.mockResolvedValue(poolsEnvelope([]));
    });

    it('renders SDWAN tiles when any SDWAN count is non-zero', async () => {
      mockGetOverviewStats.mockResolvedValue(statsWithSdwan);
      renderComponent();

      await waitFor(() => expect(screen.getByText('SDWAN')).toBeInTheDocument());
      expect(screen.getByText('SDWAN networks')).toBeInTheDocument();
      expect(screen.getByText('Host bridges')).toBeInTheDocument();
      expect(screen.getByText('2 Linux · 1 OVS')).toBeInTheDocument();
    });

    it('hides the section when every SDWAN count is zero', async () => {
      mockGetOverviewStats.mockResolvedValue(statsWithSdwanZero);
      renderComponent();

      await waitFor(() => expect(screen.getByTestId('fleet-topology')).toBeInTheDocument());
      expect(screen.queryByText('SDWAN')).not.toBeInTheDocument();
    });

    it('hides the section when the sdwan block is absent', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      renderComponent();

      await waitFor(() => expect(screen.getByTestId('fleet-topology')).toBeInTheDocument());
      expect(screen.queryByText('SDWAN')).not.toBeInTheDocument();
    });

    it('navigates to the SDWAN hub from the section button', async () => {
      mockGetOverviewStats.mockResolvedValue(statsWithSdwan);
      renderComponent();

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /open sdwan/i })).toBeInTheDocument(),
      );
      fireEvent.click(screen.getByRole('button', { name: /open sdwan/i }));
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/sdwan');
    });

    it('navigates to the SDWAN networks tab from its tile', async () => {
      mockGetOverviewStats.mockResolvedValue(statsWithSdwan);
      renderComponent();

      await waitFor(() => expect(screen.getByText('SDWAN networks')).toBeInTheDocument());
      // SDWAN tiles follow the eight inventory tiles.
      fireEvent.click(screen.getAllByTestId('stat-tile')[8]);
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/sdwan/networks');
    });
  });

  // ---------------------------------------------------------------------------
  // Quick actions
  // ---------------------------------------------------------------------------

  describe('quick actions', () => {
    beforeEach(happyPath);

    it.each([
      ['Nodes', '/app/system/compute/nodes'],
      ['Catalog', '/app/system/catalog/modules'],
      ['Templates', '/app/system/catalog/templates'],
      ['Operations', '/app/system/operations/tasks'],
      ['Fleet signals', '/app/system/operations/fleet'],
      ['Topology', '/app/system/topology'],
    ])('routes the "%s" action to %s', async (label, path) => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByRole('button', { name: label })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: label }));
      expect(mockNavigate).toHaveBeenCalledWith(path);
    });
  });

  // ---------------------------------------------------------------------------
  // Recent activity
  // ---------------------------------------------------------------------------

  describe('recent activity', () => {
    it('renders the empty state when there is nothing recent', async () => {
      happyPath();
      renderComponent();

      await waitFor(() => expect(screen.getByText('No recent activity')).toBeInTheDocument());
    });

    it('renders each activity with its action, timestamp and status badge', async () => {
      happyPath();
      mockGetRecentActivity.mockResolvedValue(recentActivities);
      renderComponent();

      await waitFor(() => expect(screen.getByText('provision_node')).toBeInTheDocument());
      expect(screen.getByText('deploy_module')).toBeInTheDocument();
      expect(screen.getByText('sync_puppet')).toBeInTheDocument();
      expect(screen.getByText('complete')).toBeInTheDocument();
      expect(screen.getByText('running')).toBeInTheDocument();
      expect(screen.getByText('failed')).toBeInTheDocument();
      expect(screen.getByText(/admin/)).toBeInTheDocument();
    });

    it('requests exactly five activity rows', async () => {
      happyPath();
      renderComponent();

      await waitFor(() => expect(mockGetRecentActivity).toHaveBeenCalledWith(5));
    });

    it('navigates to the tasks tab when an activity row is clicked', async () => {
      happyPath();
      mockGetRecentActivity.mockResolvedValue([recentActivities[0]]);
      renderComponent();

      await waitFor(() => expect(screen.getByText('provision_node')).toBeInTheDocument());
      fireEvent.click(screen.getByText('provision_node'));
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/operations/tasks');
    });

    it('omits the badge for an activity with no status', async () => {
      happyPath();
      mockGetRecentActivity.mockResolvedValue([
        { ...recentActivities[0], id: 'no-status', status: undefined },
      ]);
      renderComponent();

      await waitFor(() => expect(screen.getByText('provision_node')).toBeInTheDocument());
      expect(screen.queryByText('undefined')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Imperative ref + className
  // ---------------------------------------------------------------------------

  describe('imperative ref refresh()', () => {
    it('re-fetches every lane', async () => {
      happyPath();
      const { ref } = renderWithRef();

      await waitFor(() => expect(mockGetOverviewStats).toHaveBeenCalledTimes(1));

      await ref.current?.refresh();

      expect(mockGetOverviewStats).toHaveBeenCalledTimes(2);
      expect(mockGetRecentActivity).toHaveBeenCalledTimes(2);
      expect(mockCveList).toHaveBeenCalledTimes(2);
      expect(mockApiGet).toHaveBeenCalledTimes(2);
    });
  });

  describe('className prop', () => {
    it('applies the custom className while loading', () => {
      mockGetOverviewStats.mockReturnValue(new Promise(() => {}));
      mockGetRecentActivity.mockReturnValue(new Promise(() => {}));
      mockCveList.mockReturnValue(new Promise(() => {}));
      mockApiGet.mockReturnValue(new Promise(() => {}));

      const { container } = render(
        <BrowserRouter>
          <SystemOverview className="custom-test-class" />
        </BrowserRouter>,
      );

      expect(container.querySelector('.custom-test-class')).toBeInTheDocument();
    });

    it('applies the custom className once loaded', async () => {
      happyPath();
      const { container } = render(
        <BrowserRouter>
          <SystemOverview className="custom-test-class" />
        </BrowserRouter>,
      );

      await waitFor(() => expect(screen.getByTestId('fleet-topology')).toBeInTheDocument());
      expect(container.querySelector('.custom-test-class')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Null guard
  // ---------------------------------------------------------------------------

  it('renders nothing when the stats aggregate resolves null', async () => {
    happyPath();
    mockGetOverviewStats.mockResolvedValue(null as unknown as typeof baseStats);

    renderComponent();

    await waitFor(() => expect(mockGetOverviewStats).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(screen.queryByTestId('fleet-topology')).not.toBeInTheDocument());
    expect(screen.queryByText('Failed to Load System Data')).not.toBeInTheDocument();
  });
});
