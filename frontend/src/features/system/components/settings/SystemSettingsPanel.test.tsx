/**
 * Behavioral tests for SystemSettingsPanel component.
 *
 * SystemSettingsPanel is a 7-domain + approval-chains settings modal for
 * the System extension's autonomy framework. It renders a sidebar nav
 * and a content pane; sidebar nav switches between domain sections and
 * the Approval Chains tab. Domain sections render an AutonomyPolicyGroup;
 * the Approval Chains tab renders ApprovalChainList.
 *
 * Tests cover:
 *  1. Modal not rendered when isOpen=false
 *  2. Modal renders title/subtitle when isOpen=true
 *  3. Sidebar renders all 7 domain sections + Approval Chains
 *  4. Default active section (node_lifecycle) shows label, agentName, description
 *  5. Loading state — shows "Loading…" spinner when autonomy.loading is true
 *  6. Loaded state — renders AutonomyPolicyGroup (mocked)
 *  7. Clicking a different sidebar item activates that section
 *  8. Clicking Approval Chains renders ApprovalChainList (mocked)
 *  9. Each domain section shows correct action count badge in sidebar
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

  it('renders all 7 domain sections in the sidebar', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    const expectedLabels = [
      'Node Lifecycle',
      'SDWAN',
      'Container Runtimes',
      'Disk Image CI',
      'Instance Pools',
      'CVE & Compliance',
      'Manual Operations',
    ];
    for (const label of expectedLabels) {
      expect(screen.getByRole('button', { name: new RegExp(label, 'i') })).toBeInTheDocument();
    }
  });

  it('renders the Approval Chains item in the sidebar', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: /approval chains/i })).toBeInTheDocument();
  });

  it('shows correct action count badge for each domain section', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    // Each sidebar button contains the action count as text (span with tabular-nums class).
    // node_lifecycle=10, sdwan=31, runtime=8, disk_image=6, instance_pool=6, cve=4, manual=27
    const expectedCounts = ['10', '31', '8', '4', '27'];
    for (const count of expectedCounts) {
      const els = screen.getAllByText(count);
      expect(els.length).toBeGreaterThan(0);
    }
    // Instance Pools has 6 actions — same as disk_image; both should be present (×2 = 2 elements)
    const sixEls = screen.getAllByText('6');
    expect(sixEls.length).toBeGreaterThanOrEqual(2);
  });

  // ---------------------------------------------------------------------------
  // Default active section — node_lifecycle
  // ---------------------------------------------------------------------------

  it('defaults to the Node Lifecycle section showing label, agentName, and description', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    // "Node Lifecycle" appears both in the sidebar nav and as the content h3
    expect(screen.getAllByText('Node Lifecycle').length).toBeGreaterThanOrEqual(2);
    // "Fleet Autonomy" appears both as a sidebar button text and the content agentName badge
    expect(screen.getAllByText('Fleet Autonomy').length).toBeGreaterThanOrEqual(1);
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
    mockUseSystemAutonomyConfig.mockReturnValue(defaultAutonomyState({ loading: true }));
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
    expect(screen.getByTestId('autonomy-policy-group')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // AutonomyPolicyGroup receives correct props
  // ---------------------------------------------------------------------------

  it('passes correct label, agentName, and actions to AutonomyPolicyGroup for node_lifecycle', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );
    await waitFor(() => expect(mockAutonomyPolicyGroup).toHaveBeenCalled());

    const props = mockAutonomyPolicyGroup.mock.calls[0][0] as Record<string, unknown>;
    expect(props.label).toBe('Node Lifecycle policies');
    expect(props.agentName).toBe('Fleet Autonomy');
    expect(Array.isArray(props.actions)).toBe(true);
    const actions = props.actions as string[];
    expect(actions).toContain('system.cert_rotate');
    expect(actions).toContain('system.instance_terminate');
    expect(actions.length).toBe(10);
  });

  it('passes getPolicy, updatePolicy, isDirty, and onSave props to AutonomyPolicyGroup', async () => {
    mockUseSystemAutonomyConfig.mockReturnValue(
      defaultAutonomyState({ isDirty: true }),
    );
    renderPanel();

    await waitFor(() =>
      expect(screen.getByTestId('autonomy-policy-group')).toBeInTheDocument(),
    );

    const props = mockAutonomyPolicyGroup.mock.calls[0][0] as Record<string, unknown>;
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

    fireEvent.click(screen.getByRole('button', { name: /sdwan/i }));

    await waitFor(() => {
      expect(screen.getByText('SDWAN Manager')).toBeInTheDocument();
    });
    expect(
      screen.getByText(/networks, peers, firewall rules, vips, route policies/i),
    ).toBeInTheDocument();
  });

  it('switches to Container Runtimes section when clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /container runtimes/i }));

    await waitFor(() =>
      expect(screen.getByText('Runtime Manager')).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/docker daemon \+ k3s cluster lifecycle/i),
    ).toBeInTheDocument();
  });

  it('switches to Disk Image CI section when clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /disk image ci/i }));

    await waitFor(() =>
      expect(screen.getByText('Disk Image Manager')).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/publication promotion, rollback, retention/i),
    ).toBeInTheDocument();
  });

  it('switches to Instance Pools section when clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /instance pools/i }));

    // The content area should show agent name for the pool section
    await waitFor(() => {
      // Fleet Autonomy is the agentName for instance_pool section
      // This is shown both in the sidebar (Node Lifecycle) AND the content area badge
      const badges = screen.getAllByText('Fleet Autonomy');
      expect(badges.length).toBeGreaterThan(0);
    });
    expect(
      screen.getByText(/warm-pool create \/ update \/ delete \/ replenish \/ drain \/ acquire/i),
    ).toBeInTheDocument();
  });

  it('switches to CVE & Compliance section when clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /cve & compliance/i }));

    await waitFor(() =>
      expect(screen.getByText('CVE Responder')).toBeInTheDocument(),
    );
    expect(
      screen.getByText(/sbom ingest, exposure scan, remediation orchestration/i),
    ).toBeInTheDocument();
  });

  it('switches to Manual Operations section when clicked', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /manual operations/i }));

    // "Manual Operations" appears in the sidebar, content h3, and agentName badge
    await waitFor(() =>
      expect(screen.getAllByText('Manual Operations').length).toBeGreaterThanOrEqual(2),
    );
    expect(
      screen.getByText(/operator-initiated system::task commands/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // AutonomyPolicyGroup props per section
  // ---------------------------------------------------------------------------

  it('passes correct actions to AutonomyPolicyGroup for SDWAN section', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    mockAutonomyPolicyGroup.mockClear();
    fireEvent.click(screen.getByRole('button', { name: /sdwan/i }));

    await waitFor(() => expect(mockAutonomyPolicyGroup).toHaveBeenCalled());

    const props = mockAutonomyPolicyGroup.mock.calls[0][0] as Record<string, unknown>;
    const actions = props.actions as string[];
    expect(props.agentName).toBe('SDWAN Manager');
    expect(actions).toContain('sdwan.network_create');
    expect(actions).toContain('system.sdwan_peer_remediate');
    expect(actions.length).toBe(31);
  });

  it('passes correct actions to AutonomyPolicyGroup for Manual Operations section', async () => {
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('System Autonomy Settings')).toBeInTheDocument(),
    );

    mockAutonomyPolicyGroup.mockClear();
    fireEvent.click(screen.getByRole('button', { name: /manual operations/i }));

    await waitFor(() => expect(mockAutonomyPolicyGroup).toHaveBeenCalled());

    const props = mockAutonomyPolicyGroup.mock.calls[0][0] as Record<string, unknown>;
    const actions = props.actions as string[];
    expect(props.agentName).toBe('Manual Operations');
    expect(actions).toContain('system.task.ssh_command');
    expect(actions).toContain('system.task.terminate');
    expect(actions.length).toBe(27);
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
    expect(screen.getByTestId('autonomy-policy-group')).toBeInTheDocument();

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
      expect(screen.getByTestId('autonomy-policy-group')).toBeInTheDocument(),
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
      expect(screen.getByTestId('autonomy-policy-group')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('trigger-save'));

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
    const sdwanBtn = screen.getByRole('button', { name: /sdwan/i });
    fireEvent.click(sdwanBtn);

    await waitFor(() =>
      expect(sdwanBtn.className).toMatch(/bg-theme-surface-selected/),
    );
    // Node lifecycle button should no longer have selected class
    const nodeBtn = screen.getByRole('button', { name: /node lifecycle/i });
    expect(nodeBtn.className).not.toMatch(/bg-theme-surface-selected/);
  });
});
