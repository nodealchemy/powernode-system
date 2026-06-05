import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { OvnDeploymentsTab } from './OvnDeploymentsTab';
import type {
  SdwanOvnDeploymentSummary,
  SdwanOvnDeployment,
} from '@system/features/system/types/sdwan.types';

// =============================================================================
// Mocks
//
// OvnDeploymentsTab goes through sdwanApi (which internally calls apiClient).
// We mock sdwanApi directly so we can control the two-step fetch pattern:
//   1. getOvnDeployments() -> summary list
//   2. getOvnDeployment(id) -> full detail
// =============================================================================

const mockGetOvnDeployments = jest.fn();
const mockGetOvnDeployment = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    getOvnDeployments: (...args: unknown[]) => mockGetOvnDeployments(...args),
    getOvnDeployment: (...args: unknown[]) => mockGetOvnDeployment(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const SUMMARY: SdwanOvnDeploymentSummary = {
  id: 'ovn-deploy-01',
  status: 'active',
  nb_db_endpoint: 'tcp:10.0.0.1:6641',
  sb_db_endpoint: 'tcp:10.0.0.1:6642',
  northd_host: 'northd.internal',
  switch_count: 2,
  port_count: 4,
  bootstrapped_at: '2026-01-10T08:00:00Z',
  activated_at: '2026-01-10T08:05:00Z',
  degraded_at: null,
};

const FULL_DEPLOYMENT: SdwanOvnDeployment = {
  ...SUMMARY,
  created_at: '2026-01-10T07:50:00Z',
  updated_at: '2026-01-10T08:05:00Z',
  logical_switches: [
    {
      id: 'sw-01',
      name: 'ls-tenant-a',
      cidr: '10.10.0.0/24',
      state: 'active',
      activated_at: '2026-01-10T08:01:00Z',
      removed_at: null,
      ports: [
        {
          id: 'port-01',
          name: 'lsp-vm-alpha',
          kind: 'vm',
          state: 'active',
          mac: 'fa:16:3e:aa:bb:cc',
          addresses: ['10.10.0.10', '10.10.0.11'],
          host_node_instance_id: 'node-inst-abc',
          activated_at: '2026-01-10T08:02:00Z',
          removed_at: null,
        },
      ],
      acls: [
        {
          id: 'acl-01',
          name: 'allow-http',
          direction: 'to-lport',
          priority: 1000,
          match: 'tcp.dst == 80',
          action: 'allow',
          state: 'active',
        },
        {
          id: 'acl-02',
          name: 'drop-all',
          direction: 'to-lport',
          priority: 500,
          match: 'ip4',
          action: 'drop',
          state: 'active',
        },
      ],
    },
    {
      id: 'sw-02',
      name: 'ls-tenant-b',
      cidr: null,
      state: 'active',
      activated_at: null,
      removed_at: null,
      ports: [],
      acls: [],
    },
  ],
};

function renderTab() {
  return render(
    <BrowserRouter>
      <OvnDeploymentsTab />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('OvnDeploymentsTab', () => {
  beforeEach(() => {
    mockGetOvnDeployments.mockReset();
    mockGetOvnDeployment.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator before the API resolves', () => {
    // Never resolving promise so we stay in loading state
    mockGetOvnDeployments.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByText(/Loading OVN deployment/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders the empty state when getOvnDeployments returns an empty list', async () => {
    mockGetOvnDeployments.mockResolvedValue([]);

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/No OVN deployment yet/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/heavyweight-profile only/i)).toBeInTheDocument();
    expect(screen.getByText('system_sdwan_create_ovn_deployment')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('renders the error message when getOvnDeployments throws', async () => {
    mockGetOvnDeployments.mockRejectedValue(new Error('Network timeout'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
  });

  it('renders a fallback error message when getOvnDeployment (detail) throws', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockRejectedValue(new Error('Detail fetch failed'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Detail fetch failed')).toBeInTheDocument(),
    );
  });

  it('renders a generic fallback message when a non-Error is thrown', async () => {
    mockGetOvnDeployments.mockRejectedValue('some string error');

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Failed to load OVN deployment')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Successful data fetch — two-step API call pattern
  // ---------------------------------------------------------------------------

  it('calls getOvnDeployments then getOvnDeployment with the summary id', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('OVN Deployment')).toBeInTheDocument(),
    );

    expect(mockGetOvnDeployments).toHaveBeenCalledTimes(1);
    expect(mockGetOvnDeployment).toHaveBeenCalledTimes(1);
    expect(mockGetOvnDeployment).toHaveBeenCalledWith('ovn-deploy-01');
  });

  // ---------------------------------------------------------------------------
  // Deployment detail panel
  // ---------------------------------------------------------------------------

  it('renders the deployment ID and endpoint fields from the full detail', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('ovn-deploy-01')).toBeInTheDocument(),
    );
    expect(screen.getByText('tcp:10.0.0.1:6641')).toBeInTheDocument();
    expect(screen.getByText('tcp:10.0.0.1:6642')).toBeInTheDocument();
    expect(screen.getByText('northd.internal')).toBeInTheDocument();
  });

  it('renders the status badge with the deployment status', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    // 'active' appears in both the deployment-status badge (px-3) and
    // port-state badge (px-1.5); getAllByText is correct here
    await waitFor(() =>
      expect(screen.getAllByText('active').length).toBeGreaterThan(0),
    );
    // Verify the deployment-level badge (larger style) is present
    const badges = screen.getAllByText('active');
    const deploymentBadge = badges.find((el) => el.className.includes('px-3'));
    expect(deploymentBadge).toBeDefined();
  });

  it('renders the logical topology summary string including ACL count', async () => {
    // 2 switches, 4 ports (from summary), but total ACL count comes from
    // logical_switches in the full deployment (sw-01 has 2 ACLs, sw-02 has 0)
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/2 switches · 4 ports · 2 ACLs/i)).toBeInTheDocument(),
    );
  });

  it('uses singular form when counts are exactly 1', async () => {
    const singleDeploy: SdwanOvnDeployment = {
      ...FULL_DEPLOYMENT,
      switch_count: 1,
      port_count: 1,
      logical_switches: [
        {
          ...FULL_DEPLOYMENT.logical_switches[0],
          acls: [FULL_DEPLOYMENT.logical_switches[0].acls[0]],
          ports: [FULL_DEPLOYMENT.logical_switches[0].ports[0]],
        },
      ],
    };

    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: singleDeploy,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/1 switch · 1 port · 1 ACL/i)).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Logical switches section
  // ---------------------------------------------------------------------------

  it('renders the Logical Switches section heading when switches are present', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('Logical Switches')).toBeInTheDocument(),
    );
  });

  it('renders switch names and CIDRs', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('ls-tenant-a')).toBeInTheDocument(),
    );
    expect(screen.getByText('10.10.0.0/24')).toBeInTheDocument();
    expect(screen.getByText('ls-tenant-b')).toBeInTheDocument();
  });

  it('shows port and ACL count per switch', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('ls-tenant-a')).toBeInTheDocument(),
    );
    // sw-01: 1 port, 2 ACLs
    expect(screen.getByText('1 port')).toBeInTheDocument();
    expect(screen.getByText('2 ACLs')).toBeInTheDocument();
    // sw-02: 0 ports, 0 ACLs
    expect(screen.getAllByText('0 ports').length).toBeGreaterThan(0);
    expect(screen.getAllByText('0 ACLs').length).toBeGreaterThan(0);
  });

  it('does not render Logical Switches section when there are no switches', async () => {
    const emptyDeploy: SdwanOvnDeployment = {
      ...FULL_DEPLOYMENT,
      logical_switches: [],
    };

    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: emptyDeploy,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('OVN Deployment')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Logical Switches')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Port table
  // ---------------------------------------------------------------------------

  it('renders port rows with name, kind, state, MAC and addresses', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('lsp-vm-alpha')).toBeInTheDocument(),
    );
    expect(screen.getByText('vm')).toBeInTheDocument();
    expect(screen.getByText('fa:16:3e:aa:bb:cc')).toBeInTheDocument();
    expect(screen.getByText('10.10.0.10, 10.10.0.11')).toBeInTheDocument();
    expect(screen.getByText('node-inst-abc')).toBeInTheDocument();
  });

  it('shows — when a port has no addresses', async () => {
    const deployWithEmptyAddresses: SdwanOvnDeployment = {
      ...FULL_DEPLOYMENT,
      logical_switches: [
        {
          ...FULL_DEPLOYMENT.logical_switches[0],
          ports: [
            {
              ...FULL_DEPLOYMENT.logical_switches[0].ports[0],
              addresses: [],
              host_node_instance_id: null,
            },
          ],
        },
      ],
    };

    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: deployWithEmptyAddresses,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('lsp-vm-alpha')).toBeInTheDocument(),
    );
    // Both addresses and host columns show — when empty/null
    expect(screen.getAllByText('—').length).toBeGreaterThanOrEqual(2);
  });

  it('does not render the port table header when a switch has no ports', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('ls-tenant-b')).toBeInTheDocument(),
    );
    // ls-tenant-b has zero ports — "Logical Switch Ports" header should not
    // appear twice (only once for ls-tenant-a)
    expect(screen.getAllByText(/Logical Switch Ports/i).length).toBe(1);
  });

  // ---------------------------------------------------------------------------
  // ACL table
  // ---------------------------------------------------------------------------

  it('renders ACL rows with name, direction, priority, match and action', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('allow-http')).toBeInTheDocument(),
    );
    // both ACLs use 'to-lport' direction — getAllByText is appropriate
    expect(screen.getAllByText('to-lport').length).toBe(2);
    expect(screen.getByText('1000')).toBeInTheDocument();
    expect(screen.getByText('tcp.dst == 80')).toBeInTheDocument();
    // 'allow' appears as an action badge
    expect(screen.getByText('allow')).toBeInTheDocument();

    expect(screen.getByText('drop-all')).toBeInTheDocument();
    expect(screen.getByText('500')).toBeInTheDocument();
    expect(screen.getByText('ip4')).toBeInTheDocument();
    expect(screen.getByText('drop')).toBeInTheDocument();
  });

  it('does not render the ACL table section when a switch has no ACLs', async () => {
    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: FULL_DEPLOYMENT,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('ls-tenant-b')).toBeInTheDocument(),
    );
    // ls-tenant-b has zero ACLs — "Firewall ACLs" heading appears only once (for ls-tenant-a)
    expect(screen.getAllByText(/Firewall ACLs/i).length).toBe(1);
  });

  // ---------------------------------------------------------------------------
  // Status badge variants
  // ---------------------------------------------------------------------------

  it.each([
    ['active', /bg-theme-success/],
    ['bootstrapping', /bg-theme-info/],
    ['pending', /bg-theme-background-secondary/],
    ['degraded', /bg-theme-danger/],
  ] as const)(
    'applies correct status badge class for status "%s"',
    async (status, expectedClass) => {
      const deploy: SdwanOvnDeployment = {
        ...FULL_DEPLOYMENT,
        status,
        // Use empty logical_switches to avoid port-state badges that also say "active"
        logical_switches: [],
      };
      mockGetOvnDeployments.mockResolvedValue([{ ...SUMMARY, status }]);
      mockGetOvnDeployment.mockResolvedValue({
        deployment: deploy,
        compiled_plan: {},
      });

      const { unmount } = renderTab();

      // The deployment status badge has the larger px-3 py-1 class;
      // port state badges use px-1.5 py-0.5 — query all and find the right one.
      const badges = await waitFor(() => screen.getAllByText(status));
      const deploymentBadge = badges.find((el) =>
        el.className.includes('px-3'),
      );
      expect(deploymentBadge).toBeDefined();
      expect(deploymentBadge!.className).toMatch(expectedClass);
      unmount();
    },
  );

  // ---------------------------------------------------------------------------
  // northd_host fallback
  // ---------------------------------------------------------------------------

  it('shows — for northd host when it is null', async () => {
    const deployNoNorthd: SdwanOvnDeployment = {
      ...FULL_DEPLOYMENT,
      northd_host: null,
      logical_switches: [],
    };

    mockGetOvnDeployments.mockResolvedValue([SUMMARY]);
    mockGetOvnDeployment.mockResolvedValue({
      deployment: deployNoNorthd,
      compiled_plan: {},
    });

    renderTab();

    await waitFor(() =>
      expect(screen.getByText('OVN Deployment')).toBeInTheDocument(),
    );
    expect(screen.getByText('—')).toBeInTheDocument();
  });
});
