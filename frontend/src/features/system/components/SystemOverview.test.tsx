import React, { createRef } from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { SystemOverview, SystemOverviewHandle } from './SystemOverview';

// =============================================================================
// Mocks
//
// The component calls systemApi.getOverviewStats() and systemApi.getRecentActivity(5)
// — both of which fan out to apiClient.get internally. We mock systemApi
// directly (the facade) so we can control each method's resolved value.
// =============================================================================

const mockGetOverviewStats = jest.fn();
const mockGetRecentActivity = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getOverviewStats: (...args: unknown[]) => mockGetOverviewStats(...args),
    getRecentActivity: (...args: unknown[]) => mockGetRecentActivity(...args),
  },
}));

// useNavigate — we capture the mock so we can assert navigation calls.
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
  volumes: { total: 0, total_size_gb: 0 },
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
  {
    id: 'task-4',
    type: 'operation' as const,
    action: 'schedule_upgrade',
    description: 'Upgrade pending',
    status: 'pending',
    entity_name: 'Module',
    entity_id: 'mod-2',
    initiated_by: undefined,
    timestamp: '2026-05-01T09:00:00Z',
  },
];

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
  const { rerender } = render(
    <BrowserRouter>
      <SystemOverview ref={ref} />
    </BrowserRouter>,
  );
  return { ref, rerender };
};

// =============================================================================
// Tests
// =============================================================================

describe('SystemOverview', () => {
  beforeEach(() => {
    mockGetOverviewStats.mockReset();
    mockGetRecentActivity.mockReset();
    mockNavigate.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  describe('loading state', () => {
    it('renders 8 skeleton cards while data is loading', () => {
      // Never resolve — keep perpetual loading state
      mockGetOverviewStats.mockReturnValue(new Promise(() => {}));
      mockGetRecentActivity.mockReturnValue(new Promise(() => {}));

      renderComponent();

      // The loading skeleton renders 8 cards with animate-pulse
      const pulseElements = document.querySelectorAll('.animate-pulse');
      expect(pulseElements.length).toBe(8);
    });
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  describe('error state', () => {
    it('shows error message when API call fails', async () => {
      mockGetOverviewStats.mockRejectedValue(new Error('Network timeout'));
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('Failed to Load System Data')).toBeInTheDocument(),
      );
      expect(screen.getByText('Network timeout')).toBeInTheDocument();
    });

    it('shows a generic error message for non-Error rejections', async () => {
      mockGetOverviewStats.mockRejectedValue('string error');
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('Failed to Load System Data')).toBeInTheDocument(),
      );
      expect(screen.getByText('Failed to load system data')).toBeInTheDocument();
    });

    it('shows a Retry button that triggers a reload', async () => {
      mockGetOverviewStats
        .mockRejectedValueOnce(new Error('Temporary failure'))
        .mockResolvedValueOnce(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /retry/i })).toBeInTheDocument(),
      );

      // Click retry — second call succeeds
      fireEvent.click(screen.getByRole('button', { name: /retry/i }));

      await waitFor(() =>
        expect(screen.getByText('System Overview')).toBeInTheDocument(),
      );
      expect(mockGetOverviewStats).toHaveBeenCalledTimes(2);
    });
  });

  // ---------------------------------------------------------------------------
  // Successful render — primary metric cards
  // ---------------------------------------------------------------------------

  describe('primary metric cards', () => {
    beforeEach(() => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);
    });

    it('renders the "System Overview" section heading', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('System Overview')).toBeInTheDocument(),
      );
    });

    it('renders Nodes metric card with correct value and description', async () => {
      renderComponent();
      await waitFor(() => expect(screen.getByText('Nodes')).toBeInTheDocument());

      // value = 4, description = "3 enabled, 1 disabled"
      const nodesSection = screen.getByText('Nodes').closest('div');
      expect(nodesSection).toBeTruthy();
      expect(screen.getByText('3 enabled, 1 disabled')).toBeInTheDocument();
    });

    it('renders Templates metric card with public/private breakdown', async () => {
      renderComponent();
      // "Templates" appears in both MetricCard and the Quick Actions button —
      // we only need to confirm the description rendered
      await waitFor(() =>
        expect(screen.getByText('1 public, 1 private')).toBeInTheDocument(),
      );
      // The heading appears at least once (MetricCard h3)
      expect(screen.getAllByText('Templates').length).toBeGreaterThan(0);
    });

    it('renders Providers metric card with enabled count', async () => {
      renderComponent();
      // Providers description — "2 enabled" appears in the metric card description
      await waitFor(() =>
        expect(screen.getAllByText('2 enabled').length).toBeGreaterThan(0),
      );
      // Heading appears at least once
      expect(screen.getAllByText('Providers').length).toBeGreaterThan(0);
    });

    it('renders Modules metric card with enabled count', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getAllByText('Modules').length).toBeGreaterThan(0),
      );
      // "5 enabled" is the modules enabled count
      expect(screen.getByText('5 enabled')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Secondary metric cards
  // ---------------------------------------------------------------------------

  describe('secondary metric cards', () => {
    beforeEach(() => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);
    });

    it('renders Platforms metric card', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('Platforms')).toBeInTheDocument(),
      );
    });

    it('renders Puppet Modules metric card with resources description', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('Puppet Modules')).toBeInTheDocument(),
      );
      expect(screen.getByText('12 resources')).toBeInTheDocument();
    });

    it('renders Operations metric card with running count', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getAllByText('Operations').length).toBeGreaterThan(0),
      );
      // "1 running" appears in the MetricCard description
      expect(screen.getByText('1 running')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Operations Status card
  // ---------------------------------------------------------------------------

  describe('Operations Status card', () => {
    beforeEach(() => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);
    });

    it('shows pending, running, completed, and failed counts', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('Operations Status')).toBeInTheDocument(),
      );

      expect(screen.getByText('Pending')).toBeInTheDocument();
      expect(screen.getByText('Running')).toBeInTheDocument();
      expect(screen.getByText('Completed')).toBeInTheDocument();
      expect(screen.getByText('Failed')).toBeInTheDocument();
    });

    it('navigates to tasks page when "View All" is clicked', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('Operations Status')).toBeInTheDocument(),
      );

      // Operations Status card's View All button
      const viewAllButtons = screen.getAllByRole('button', { name: /view all/i });
      fireEvent.click(viewAllButtons[0]);
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/tasks');
    });
  });

  // ---------------------------------------------------------------------------
  // Module Distribution card
  // ---------------------------------------------------------------------------

  describe('Module Distribution card', () => {
    beforeEach(() => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);
    });

    it('shows Config, Instance, Subscription module counts', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('Module Distribution')).toBeInTheDocument(),
      );

      expect(screen.getByText('Config Modules')).toBeInTheDocument();
      expect(screen.getByText('Instance Modules')).toBeInTheDocument();
      expect(screen.getByText('Subscription Modules')).toBeInTheDocument();
    });

    it('shows Puppet Assignments row', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('Puppet Assignments')).toBeInTheDocument(),
      );
    });

    it('navigates to modules page when "Manage" is clicked', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('Module Distribution')).toBeInTheDocument(),
      );

      // Find the "Manage" button within the Module Distribution card
      const manageButtons = screen.getAllByRole('button', { name: /manage/i });
      // The Manage button should navigate to /app/system/modules
      fireEvent.click(manageButtons[0]);
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/modules');
    });
  });

  // ---------------------------------------------------------------------------
  // SDWAN section
  // ---------------------------------------------------------------------------

  describe('SDWAN section', () => {
    it('renders SDWAN section when stats have non-zero sdwan values', async () => {
      mockGetOverviewStats.mockResolvedValue(statsWithSdwan);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('SDWAN')).toBeInTheDocument(),
      );
      expect(screen.getByText('SDWAN Networks')).toBeInTheDocument();
      expect(screen.getByText('Host Bridges')).toBeInTheDocument();
      expect(screen.getByText('OVN Deployments')).toBeInTheDocument();
      expect(screen.getByText('IPFIX Collectors')).toBeInTheDocument();
    });

    it('does not render SDWAN section when all sdwan counts are zero', async () => {
      mockGetOverviewStats.mockResolvedValue(statsWithSdwanZero);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('System Overview')).toBeInTheDocument(),
      );
      expect(screen.queryByText('SDWAN')).not.toBeInTheDocument();
    });

    it('does not render SDWAN section when sdwan block is absent', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats); // no sdwan key
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('System Overview')).toBeInTheDocument(),
      );
      expect(screen.queryByText('SDWAN')).not.toBeInTheDocument();
    });

    it('renders "Open SDWAN" button that navigates to SDWAN page', async () => {
      mockGetOverviewStats.mockResolvedValue(statsWithSdwan);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /open sdwan/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /open sdwan/i }));
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/sdwan');
    });

    it('shows host bridges kind breakdown in description', async () => {
      mockGetOverviewStats.mockResolvedValue(statsWithSdwan);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('2 Linux, 1 OVS')).toBeInTheDocument(),
      );
    });

    it('shows "Heavyweight profile only" when OVN deployments is 0 but other SDWAN has values', async () => {
      const statsWithSdwanNoOvn = {
        ...baseStats,
        sdwan: {
          networks: 2,
          host_bridges: 1,
          bridges_by_kind: { linux: 1, ovs: 0 },
          ovn_deployments: 0,
          ovn_active: 0,
          ipfix_collectors: 1,
          ipfix_active: 1,
        },
      };
      mockGetOverviewStats.mockResolvedValue(statsWithSdwanNoOvn);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('Heavyweight profile only')).toBeInTheDocument(),
      );
    });

    it('shows "Flow telemetry export" when IPFIX collectors is 0 but other SDWAN has values', async () => {
      const statsWithSdwanNoIpfix = {
        ...baseStats,
        sdwan: {
          networks: 2,
          host_bridges: 1,
          bridges_by_kind: { linux: 1, ovs: 0 },
          ovn_deployments: 1,
          ovn_active: 1,
          ipfix_collectors: 0,
          ipfix_active: 0,
        },
      };
      mockGetOverviewStats.mockResolvedValue(statsWithSdwanNoIpfix);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('Flow telemetry export')).toBeInTheDocument(),
      );
    });

    it('navigates to SDWAN networks when SDWAN Networks card is clicked', async () => {
      mockGetOverviewStats.mockResolvedValue(statsWithSdwan);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('SDWAN Networks')).toBeInTheDocument(),
      );

      // Click the SDWAN Networks metric card
      fireEvent.click(screen.getByText('SDWAN Networks').closest('[class*="cursor-pointer"]') || screen.getByText('SDWAN Networks'));
      await waitFor(() =>
        expect(mockNavigate).toHaveBeenCalledWith('/app/system/sdwan/networks'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Recent Activity section
  // ---------------------------------------------------------------------------

  describe('Recent Activity section', () => {
    it('renders "No recent activity" when activity list is empty', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('No recent activity')).toBeInTheDocument(),
      );
    });

    it('renders activity items with action, description, and timestamp', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue(recentActivities);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('provision_node')).toBeInTheDocument(),
      );
      expect(screen.getByText('Provisioning node alpha')).toBeInTheDocument();
      expect(screen.getByText('deploy_module')).toBeInTheDocument();
      expect(screen.getByText('Deploying base-config')).toBeInTheDocument();
    });

    it('shows "by <initiator>" for activities with an initiator', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue(recentActivities);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText(/by admin/)).toBeInTheDocument(),
      );
      expect(screen.getByText(/by ops-bot/)).toBeInTheDocument();
    });

    it('shows status badge on activity items that have a status', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue(recentActivities);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('provision_node')).toBeInTheDocument(),
      );
      // Status badges — one per activity that has a status field
      expect(screen.getAllByText('complete').length).toBeGreaterThan(0);
      expect(screen.getAllByText('running').length).toBeGreaterThan(0);
      expect(screen.getAllByText('failed').length).toBeGreaterThan(0);
      expect(screen.getAllByText('pending').length).toBeGreaterThan(0);
    });

    it('navigates to tasks page when an activity item is clicked', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([recentActivities[0]]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('provision_node')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByText('provision_node'));
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/tasks');
    });

    it('requests activity with limit=5', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(mockGetRecentActivity).toHaveBeenCalledWith(5),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Provider Types section
  // ---------------------------------------------------------------------------

  describe('Provider Types section', () => {
    it('renders configured provider type badges when types list is non-empty', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats); // types: ['proxmox', 'aws']
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('Configured Provider Types')).toBeInTheDocument(),
      );
      expect(screen.getByText('proxmox')).toBeInTheDocument();
      expect(screen.getByText('aws')).toBeInTheDocument();
    });

    it('does not render provider types section when types list is empty', async () => {
      const statsNoTypes = {
        ...baseStats,
        providers: { ...baseStats.providers, types: [] },
      };
      mockGetOverviewStats.mockResolvedValue(statsNoTypes);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('System Overview')).toBeInTheDocument(),
      );
      expect(screen.queryByText('Configured Provider Types')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Quick Actions section
  // ---------------------------------------------------------------------------

  describe('Quick Actions section', () => {
    beforeEach(() => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);
    });

    it('renders all six quick action buttons', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('Quick Actions')).toBeInTheDocument(),
      );

      expect(screen.getByRole('button', { name: /manage nodes/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /templates/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /providers/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /modules/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /puppet/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /operations/i })).toBeInTheDocument();
    });

    it('navigates to /app/system/nodes when "Manage Nodes" is clicked', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /manage nodes/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /manage nodes/i }));
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/nodes');
    });

    it('navigates to /app/system/templates when "Templates" quick action is clicked', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /^templates$/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /^templates$/i }));
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/templates');
    });

    it('navigates to /app/system/providers when "Providers" quick action is clicked', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /^providers$/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /^providers$/i }));
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/providers');
    });

    it('navigates to /app/system/puppet when "Puppet" quick action is clicked', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /^puppet$/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /^puppet$/i }));
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/puppet');
    });

    it('navigates to /app/system/tasks when "Operations" quick action is clicked', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /^operations$/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /^operations$/i }));
      expect(mockNavigate).toHaveBeenCalledWith('/app/system/tasks');
    });
  });

  // ---------------------------------------------------------------------------
  // Navigation from metric cards
  // ---------------------------------------------------------------------------

  describe('metric card navigation', () => {
    beforeEach(() => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);
    });

    it('navigates to nodes page when Nodes metric card is clicked', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('Nodes')).toBeInTheDocument(),
      );

      // MetricCard renders as a clickable div; find by the title text
      fireEvent.click(screen.getByText('Nodes'));
      await waitFor(() =>
        expect(mockNavigate).toHaveBeenCalledWith('/app/system/nodes'),
      );
    });

    it('navigates to templates page when Templates metric card is clicked', async () => {
      renderComponent();
      // Wait for the content to load — use the description text which is unique
      await waitFor(() =>
        expect(screen.getByText('1 public, 1 private')).toBeInTheDocument(),
      );

      // "Templates" appears both as MetricCard heading and Quick Action button.
      // The MetricCard heading is an h3; click the first occurrence.
      const templatesHeadings = screen.getAllByText('Templates');
      fireEvent.click(templatesHeadings[0]);
      await waitFor(() =>
        expect(mockNavigate).toHaveBeenCalledWith('/app/system/templates'),
      );
    });

    it('navigates to puppet page when Puppet Modules metric card is clicked', async () => {
      renderComponent();
      await waitFor(() =>
        expect(screen.getByText('Puppet Modules')).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByText('Puppet Modules'));
      await waitFor(() =>
        expect(mockNavigate).toHaveBeenCalledWith('/app/system/puppet'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // API calls — getOverviewStats + getRecentActivity called on mount
  // ---------------------------------------------------------------------------

  describe('API calls', () => {
    it('calls getOverviewStats and getRecentActivity(5) on mount', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);

      renderComponent();

      await waitFor(() =>
        expect(mockGetOverviewStats).toHaveBeenCalledTimes(1),
      );
      expect(mockGetRecentActivity).toHaveBeenCalledWith(5);
    });
  });

  // ---------------------------------------------------------------------------
  // Imperative ref — refresh()
  // ---------------------------------------------------------------------------

  describe('imperative ref refresh()', () => {
    it('exposes a refresh method via forwardRef that re-fetches data', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);

      const { ref } = renderWithRef();

      // Wait for initial load
      await waitFor(() =>
        expect(mockGetOverviewStats).toHaveBeenCalledTimes(1),
      );

      // Call refresh imperatively
      await ref.current?.refresh();

      expect(mockGetOverviewStats).toHaveBeenCalledTimes(2);
      expect(mockGetRecentActivity).toHaveBeenCalledTimes(2);
    });
  });

  // ---------------------------------------------------------------------------
  // className prop
  // ---------------------------------------------------------------------------

  describe('className prop', () => {
    it('applies custom className in the loading state', () => {
      mockGetOverviewStats.mockReturnValue(new Promise(() => {}));
      mockGetRecentActivity.mockReturnValue(new Promise(() => {}));

      const { container } = render(
        <BrowserRouter>
          <SystemOverview className="custom-test-class" />
        </BrowserRouter>,
      );

      expect(container.querySelector('.custom-test-class')).toBeInTheDocument();
    });

    it('applies custom className in the success state', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([]);

      const { container } = render(
        <BrowserRouter>
          <SystemOverview className="custom-test-class" />
        </BrowserRouter>,
      );

      await waitFor(() =>
        expect(screen.getByText('System Overview')).toBeInTheDocument(),
      );
      expect(container.querySelector('.custom-test-class')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Status color / icon logic — getStatusColor
  // ---------------------------------------------------------------------------

  describe('activity status display', () => {
    it('renders "complete" status activities with correct badge', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([recentActivities[0]]); // status: complete

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('provision_node')).toBeInTheDocument(),
      );
      expect(screen.getByText('complete')).toBeInTheDocument();
    });

    it('renders "failed" status activities with correct badge', async () => {
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([recentActivities[2]]); // status: failed

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('sync_puppet')).toBeInTheDocument(),
      );
      expect(screen.getByText('failed')).toBeInTheDocument();
    });

    it('does not show status badge for activities without a status', async () => {
      const noStatusActivity = {
        ...recentActivities[0],
        id: 'no-status',
        status: undefined,
      };
      mockGetOverviewStats.mockResolvedValue(baseStats);
      mockGetRecentActivity.mockResolvedValue([noStatusActivity]);

      renderComponent();

      await waitFor(() =>
        expect(screen.getByText('provision_node')).toBeInTheDocument(),
      );
      // No badge rendered — the status span is gated on `activity.status`
      expect(screen.queryByText('undefined')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Null guard — returns null when stats is null after load finishes
  // ---------------------------------------------------------------------------

  it('renders nothing (null) when stats is null after successful load', async () => {
    // When getOverviewStats resolves to null, setStats(null) is called and
    // setLoading(false) is called. Since !stats is truthy, the component
    // returns null — meaning no System Overview heading appears.
    mockGetOverviewStats.mockResolvedValue(null as unknown as typeof baseStats);
    mockGetRecentActivity.mockResolvedValue([]);

    renderComponent();

    // Wait for the API call to complete
    await waitFor(() =>
      expect(mockGetOverviewStats).toHaveBeenCalledTimes(1),
    );

    // After load completes with null stats, neither loading skeleton nor
    // the "System Overview" heading should exist. The component returns null.
    await waitFor(() =>
      expect(screen.queryByText('System Overview')).not.toBeInTheDocument(),
    );
    // No error state either
    expect(screen.queryByText('Failed to Load System Data')).not.toBeInTheDocument();
  });
});
