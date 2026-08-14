/**
 * Behavioral tests for SystemSettingsPanel component.
 *
 * SystemSettingsPanel is a settings modal for the System extension's autonomy
 * framework. It renders a sidebar nav and a content pane; sidebar nav switches
 * between domain sections and the Approval Chains tab. Domain sections render
 * an AutonomyPolicyGroup per agent bucket; the Approval Chains tab renders
 * ApprovalChainList.
 *
 * These examples stub the hook, so they pin the panel's RENDERING contract
 * against a controlled state. What they cannot show is where that state comes
 * from — that is the subject of SystemSettingsPanel.serverDriven.test.tsx,
 * which drives the real hook off a mocked HTTP payload.
 *
 * IMP-0874acd5b50c reshaped several of these. The panel used to own a
 * `DOMAIN_SECTIONS` array with a literal `actions: string[]` per section, and
 * this suite asserted those literals back (`actions.length` of 10 / 31 / 27, a
 * fixed list of 7 section labels, a "Manual Operations" SECTION). Every one of
 * those assertions was green while the modal omitted 28 of the 119 seeded
 * categories — they described the literal, not the data. Sections and their
 * rows now come from the hook's `domains`, and "Manual Operations" is an agent
 * BUCKET inside a domain rather than a domain of its own, so the assertions
 * below are written against the fixture instead of against constants.
 *
 * Tests cover:
 *  1. Modal not rendered when isOpen=false
 *  2. Modal renders title/subtitle when isOpen=true
 *  3. Sidebar renders one section per non-empty domain, + Approval Chains
 *  4. Default active section is the first the server returned
 *  5. Loading state — shows "Loading…" spinner when autonomy.loading is true
 *  6. Loaded state — renders AutonomyPolicyGroup (mocked) per agent bucket
 *  7. Clicking a different sidebar item activates that section
 *  8. Clicking Approval Chains renders ApprovalChainList (mocked)
 *  9. Each domain section shows its action count badge in the sidebar
 * 10. onClose is called when the modal close button is clicked
 * 11. save() on the hook is called via onSave handler
 * 12. Loading spinner disappears once loading resolves
 */

import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { SystemSettingsPanel } from './SystemSettingsPanel';

// =============================================================================
// Mocks
// =============================================================================

// useSystemAutonomyConfig — the hook the panel uses to fetch and manage
// autonomy policies. We stub it to control loading/data states.
const mockSave = jest.fn();
const mockGetPolicy = jest.fn().mockReturnValue('require_approval');
const mockUpdatePolicy = jest.fn();

const mockUseSystemAutonomyConfig = jest.fn();

jest.mock('@system/features/system/hooks/useSystemAutonomyConfig', () => ({
  useSystemAutonomyConfig: (...args: unknown[]) => mockUseSystemAutonomyConfig(...args),
}));

// AutonomyPolicyGroup — child component; stub to a minimal div so we can
// assert it receives props without needing its full rendering pipeline.
const mockAutonomyPolicyGroup = jest.fn();
jest.mock('@/shared/components/autonomy/AutonomyPolicyGroup', () => ({
  AutonomyPolicyGroup: (props: Record<string, unknown>) => {
    mockAutonomyPolicyGroup(props);
    return (
      <div data-testid="autonomy-policy-group" data-label={props.label as string}>
        <button
          data-testid="trigger-save"
          onClick={() => {
            if (typeof props.onSave === 'function') {
              void (props.onSave as () => Promise<void>)();
            }
          }}
        >
          Save
        </button>
      </div>
    );
  },
}));

// ApprovalChainList — child component rendered for the Approval Chains tab.
jest.mock('@/shared/components/approval-chains/ApprovalChainList', () => ({
  ApprovalChainList: () => <div data-testid="approval-chain-list" />,
}));

// =============================================================================
// Fixture
//
// Stands in for GET /api/v1/system/autonomy's `by_domain` view as the hook
// exposes it. Deliberately small and NOT a transcription of the seed set: the
// panel must be able to render whatever it is handed, so the assertions below
// are all derived from this object rather than from a list the component knows.
//
// `node_lifecycle` and `instance_pool` each carry two agent buckets, which is
// the live shape — a category is commonly seeded twice, once agent-scoped and
// once for the operator path, and those two rows can hold different verbs.
// =============================================================================

const DOMAINS = {
  node_lifecycle: [
    { action_category: 'system.cert_rotate', agent_bucket: 'Fleet Autonomy', policy: 'require_approval' },
    { action_category: 'system.instance_terminate', agent_bucket: 'Fleet Autonomy', policy: 'require_approval' },
    { action_category: 'system.task.ssh_command', agent_bucket: 'Manual Operations', policy: 'require_approval' },
    { action_category: 'system.task.terminate', agent_bucket: 'Manual Operations', policy: 'require_approval' },
  ],
  sdwan: [
    { action_category: 'sdwan.network_create', agent_bucket: 'SDWAN Manager', policy: 'auto_approve' },
    { action_category: 'system.sdwan_peer_remediate', agent_bucket: 'SDWAN Manager', policy: 'notify_and_proceed' },
    { action_category: 'sdwan.peer_delete', agent_bucket: 'SDWAN Manager', policy: 'require_approval' },
  ],
  container_runtime: [
    { action_category: 'system.runtime_docker_provision', agent_bucket: 'Runtime Manager', policy: 'auto_approve' },
  ],
  disk_image: [
    { action_category: 'system.disk_image_publication_promote', agent_bucket: 'Disk Image Manager', policy: 'require_approval' },
  ],
  instance_pool: [
    { action_category: 'system.instance_pool_create', agent_bucket: 'Fleet Autonomy', policy: 'require_approval' },
    { action_category: 'system.instance_pool_create', agent_bucket: 'Manual Operations', policy: 'auto_approve' },
  ],
  cve: [
    { action_category: 'system.cve_remediate', agent_bucket: 'CVE Responder', policy: 'notify_and_proceed' },
  ],
  other: [],
};

/** Sidebar labels the fixture should produce, in the fixture's own key order. */
const EXPECTED_SECTIONS = [
  'Node Lifecycle',
  'SDWAN',
  'Container Runtimes',
  'Disk Image CI',
  'Instance Pools',
  'CVE & Compliance',
];

// =============================================================================
// Helpers
// =============================================================================

function defaultAutonomyState(overrides: Record<string, unknown> = {}) {
  return {
    loading: false,
    isDirty: false,
    getPolicy: mockGetPolicy,
    updatePolicy: mockUpdatePolicy,
    save: mockSave,
    agentPolicies: {},
    agentNames: [],
    domains: DOMAINS,
    reload: jest.fn(),
    ...overrides,
  };
}

const renderPanel = (isOpen = true, onClose = jest.fn()) =>
  render(
    <BrowserRouter>
      <SystemSettingsPanel isOpen={isOpen} onClose={onClose} />
    </BrowserRouter>,
  );

/** Props of every AutonomyPolicyGroup rendered since the last mockClear. */
function groupProps(): Array<Record<string, unknown>> {
  return mockAutonomyPolicyGroup.mock.calls.map((c) => c[0] as Record<string, unknown>);
}

// =============================================================================
// Tests
// =============================================================================

describe('SystemSettingsPanel', () => {
  beforeEach(() => {
    mockSave.mockReset();
    mockGetPolicy.mockReset().mockReturnValue('require_approval');
    mockUpdatePolicy.mockReset();
    mockAutonomyPolicyGroup.mockReset();
    mockUseSystemAutonomyConfig.mockReturnValue(defaultAutonomyState());
  });

  // ---------------------------------------------------------------------------
  // Visibility
  // ---------------------------------------------------------------------------

  it('does not render modal content when isOpen is false', () => {
    renderPanel(false);
    expect(screen.queryByText('System Autonomy Settings')).not.toBeInTheDocument();
  });

  it('renders the modal title and subtitle when isOpen is true', async () => {
    renderPanel(true);
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );
    expect(
      screen.getByText('Configure per-action intervention policies and approval chains'),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Sidebar navigation
  // ---------------------------------------------------------------------------

  it('renders one sidebar section per non-empty domain the hook returned', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    for (const label of EXPECTED_SECTIONS) {
      expect(screen.getByRole('button', { name: new RegExp(label, 'i') })).toBeInTheDocument();
    }
    // "other" is in the fixture but empty — an empty bucket has nothing to tune.
    expect(screen.queryByRole('button', { name: /^other/i })).not.toBeInTheDocument();
    // Manual Operations is an agent BUCKET now, not a domain of its own, so it
    // must not appear as a sidebar section.
    expect(screen.queryByRole('button', { name: /manual operations/i })).not.toBeInTheDocument();
  });

  it('renders the Approval Chains item in the sidebar', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: /approval chains/i })).toBeInTheDocument();
  });

  it('shows each section\'s action count badge, counted from the rows', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    // node_lifecycle = 4 rows, sdwan = 3, container_runtime = 1, disk_image = 1,
    // instance_pool = 2 (one category, two buckets), cve = 1.
    const nodeBtn = screen.getByRole('button', { name: /node lifecycle/i });
    expect(nodeBtn).toHaveTextContent('4');
    expect(screen.getByRole('button', { name: /^sdwan/i })).toHaveTextContent('3');
    expect(screen.getByRole('button', { name: /instance pools/i })).toHaveTextContent('2');
  });

  // ---------------------------------------------------------------------------
  // Default active section
  // ---------------------------------------------------------------------------

  it('defaults to the first section the server returned', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    // "Node Lifecycle" appears both in the sidebar nav and as the content h3
    expect(screen.getAllByText('Node Lifecycle').length).toBeGreaterThanOrEqual(2);
    expect(
      screen.getByText(
        /cert rotation, module assignment, instance reboot\/reprovision\/terminate/i,
      ),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows loading spinner when autonomy.loading is true', async () => {
    mockUseSystemAutonomyConfig.mockReturnValue(
      defaultAutonomyState({ loading: true, domains: {} }),
    );
    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );
    expect(screen.getByText('Loading…')).toBeInTheDocument();
    expect(screen.queryByTestId('autonomy-policy-group')).not.toBeInTheDocument();
  });

  it('hides loading spinner and shows AutonomyPolicyGroup when loading is false', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Loading…')).not.toBeInTheDocument();
    expect(screen.getAllByTestId('autonomy-policy-group').length).toBeGreaterThan(0);
  });

  it('explains itself rather than rendering blank when no policies exist', async () => {
    mockUseSystemAutonomyConfig.mockReturnValue(defaultAutonomyState({ domains: {} }));
    renderPanel();

    await waitFor(() =>
      expect(
        screen.getByText(/no autonomy policies are configured for this account yet/i),
      ).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('autonomy-policy-group')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // AutonomyPolicyGroup receives correct props
  // ---------------------------------------------------------------------------

  it('renders one group per agent bucket in the domain, carrying that bucket\'s rows', async () => {
    renderPanel();
    await waitFor(() => expect(mockAutonomyPolicyGroup).toHaveBeenCalled());

    const groups = groupProps();
    expect(groups.map((p) => p.agentName)).toEqual(['Fleet Autonomy', 'Manual Operations']);
    expect(groups[0].label).toBe('Node Lifecycle · Fleet Autonomy');
    expect(groups[0].actions).toEqual(['system.cert_rotate', 'system.instance_terminate']);
    expect(groups[1].actions).toEqual(['system.task.ssh_command', 'system.task.terminate']);
  });

  it('passes getPolicy, updatePolicy, isDirty, and onSave props to AutonomyPolicyGroup', async () => {
    mockUseSystemAutonomyConfig.mockReturnValue(
      defaultAutonomyState({ isDirty: true }),
    );
    renderPanel();

    await waitFor(() =>
      expect(screen.getAllByTestId('autonomy-policy-group').length).toBeGreaterThan(0),
    );

    const props = groupProps()[0];
    expect(props.getPolicy).toBe(mockGetPolicy);
    expect(props.updatePolicy).toBe(mockUpdatePolicy);
    expect(props.isDirty).toBe(true);
    expect(typeof props.onSave).toBe('function');
  });

  // ---------------------------------------------------------------------------
  // Sidebar navigation — switching sections
  // ---------------------------------------------------------------------------

  it('switches to SDWAN section when SDWAN sidebar item is clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    mockAutonomyPolicyGroup.mockClear();
    fireEvent.click(screen.getByRole('button', { name: /^sdwan/i }));

    await waitFor(() =>
      expect(
        screen.getByText(/networks, peers, firewall rules, vips, route policies/i),
      ).toBeInTheDocument(),
    );
    expect(groupProps()[0].label).toBe('SDWAN · SDWAN Manager');
  });

  it('switches to Container Runtimes section when clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    mockAutonomyPolicyGroup.mockClear();
    fireEvent.click(screen.getByRole('button', { name: /container runtimes/i }));

    await waitFor(() =>
      expect(screen.getByText(/docker daemon \+ k3s cluster lifecycle/i)).toBeInTheDocument(),
    );
    expect(groupProps()[0].agentName).toBe('Runtime Manager');
  });

  it('switches to Disk Image CI section when clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    mockAutonomyPolicyGroup.mockClear();
    fireEvent.click(screen.getByRole('button', { name: /disk image ci/i }));

    await waitFor(() =>
      expect(screen.getByText(/publication promotion, rollback, retention/i)).toBeInTheDocument(),
    );
    expect(groupProps()[0].agentName).toBe('Disk Image Manager');
  });

  it('switches to Instance Pools section when clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    mockAutonomyPolicyGroup.mockClear();
    fireEvent.click(screen.getByRole('button', { name: /instance pools/i }));

    await waitFor(() =>
      expect(
        screen.getByText(/warm-pool create \/ update \/ delete \/ replenish \/ drain \/ acquire/i),
      ).toBeInTheDocument(),
    );

    // The same category, seeded twice — the operator has to be able to see and
    // tune BOTH rows, which one group per section could never show.
    const groups = groupProps();
    expect(groups.map((p) => p.agentName)).toEqual(['Fleet Autonomy', 'Manual Operations']);
    groups.forEach((p) => expect(p.actions).toEqual(['system.instance_pool_create']));
  });

  it('switches to CVE & Compliance section when clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    mockAutonomyPolicyGroup.mockClear();
    fireEvent.click(screen.getByRole('button', { name: /cve & compliance/i }));

    await waitFor(() =>
      expect(
        screen.getByText(/sbom ingest, exposure scan, remediation orchestration/i),
      ).toBeInTheDocument(),
    );
    expect(groupProps()[0].agentName).toBe('CVE Responder');
  });

  // ---------------------------------------------------------------------------
  // Approval Chains tab
  // ---------------------------------------------------------------------------

  it('renders ApprovalChainList when Approval Chains sidebar item is clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /approval chains/i }));

    await waitFor(() =>
      expect(screen.getByTestId('approval-chain-list')).toBeInTheDocument(),
    );
    // AutonomyPolicyGroup should NOT be visible in this tab
    expect(screen.queryByTestId('autonomy-policy-group')).not.toBeInTheDocument();
  });

  it('hides AutonomyPolicyGroup when Approval Chains tab is active', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    // AutonomyPolicyGroup visible initially
    expect(screen.getAllByTestId('autonomy-policy-group').length).toBeGreaterThan(0);

    fireEvent.click(screen.getByRole('button', { name: /approval chains/i }));

    await waitFor(() =>
      expect(screen.queryByTestId('autonomy-policy-group')).not.toBeInTheDocument(),
    );
    expect(screen.getByTestId('approval-chain-list')).toBeInTheDocument();
  });

  it('can switch back from Approval Chains to a domain section', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /approval chains/i }));
    await waitFor(() =>
      expect(screen.getByTestId('approval-chain-list')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /cve & compliance/i }));
    await waitFor(() =>
      expect(screen.getAllByTestId('autonomy-policy-group').length).toBeGreaterThan(0),
    );
    expect(screen.queryByTestId('approval-chain-list')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onSave handler wires to autonomy.save()
  // ---------------------------------------------------------------------------

  it('calls autonomy.save() when onSave is triggered from AutonomyPolicyGroup', async () => {
    mockSave.mockResolvedValue(undefined);
    renderPanel();

    await waitFor(() =>
      expect(screen.getAllByTestId('autonomy-policy-group').length).toBeGreaterThan(0),
    );

    fireEvent.click(screen.getAllByTestId('trigger-save')[0]);

    await waitFor(() => expect(mockSave).toHaveBeenCalledTimes(1));
  });

  // ---------------------------------------------------------------------------
  // onClose
  // ---------------------------------------------------------------------------

  it('calls onClose when the modal close button is pressed', async () => {
    const onClose = jest.fn();
    renderPanel(true, onClose);

    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    // The Modal renders a close button (aria-label="Close" or similar)
    const closeBtn = screen.getByRole('button', { name: /close/i });
    fireEvent.click(closeBtn);

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Active sidebar state
  // ---------------------------------------------------------------------------

  it('highlights the active sidebar item', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    // Click SDWAN
    const sdwanBtn = screen.getByRole('button', { name: /^sdwan/i });
    fireEvent.click(sdwanBtn);

    await waitFor(() =>
      expect(sdwanBtn.className).toMatch(/bg-theme-surface-selected/),
    );
    // Node lifecycle button should no longer have selected class
    const nodeBtn = screen.getByRole('button', { name: /node lifecycle/i });
    expect(nodeBtn.className).not.toMatch(/bg-theme-surface-selected/);
  });
});
