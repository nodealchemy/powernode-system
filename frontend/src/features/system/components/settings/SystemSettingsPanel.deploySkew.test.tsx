import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { SystemSettingsPanel } from './SystemSettingsPanel';

// =============================================================================
// IMP-82b43009d57b — DEPLOY SKEW between this extension's frontend and an older
// server.
//
// Core and the System extension are deployed as SEPARATE modules, so a newer
// frontend against an older server is a normal operational state. `agent_bucket`
// landed in the extension's serializer at d975e94a; `by_domain` and the
// `scope`/`agent_name` fields have shipped since 32398204. Against any server in
// that window every by_domain row arrives with no bucket.
//
// The panel used to read `row.agent_bucket || 'Manual Operations'`, which put
// every agent-scoped row in the manual group. That is bad as a READ — the modal
// showed a uniform, wrong picture of the account's autonomy posture. It is worse
// as a WRITE: the control the operator adjusted in the manual group carried the
// identity of a row they were never shown, so saving submitted a verb against
// it.
//
// This file drives the REAL hook with only `apiClient` mocked, so every rendered
// group comes from the HTTP payload. The field list in the fixtures below is
// execution-verified against `System::AutonomyActions#serialize_policy` (a
// request spec dumped the emitted keys), not inferred from the TypeScript type —
// the whole finding is that a field's presence cannot be assumed across
// independently deployed modules.
// =============================================================================

const mockGet = jest.fn();
const mockPatch = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  __esModule: true,
  default: {
    get: (...args: unknown[]) => mockGet(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
  },
}));

jest.mock('@/shared/utils/logger', () => ({
  logger: { error: jest.fn(), warn: jest.fn(), info: jest.fn(), debug: jest.fn() },
}));

jest.mock('@/shared/components/approval-chains/ApprovalChainList', () => ({
  ApprovalChainList: () => <div data-testid="approval-chain-list" />,
}));

// ---------------------------------------------------------------------------
// Old-shape rows: exactly what d975e94a^ emits — every field the current
// serializer ships EXCEPT `agent_bucket`.
// ---------------------------------------------------------------------------
const OLD_SHAPE_BY_DOMAIN = {
  node_lifecycle: [
    // An operator's own agent. `by_agent_pivot` keeps only SYSTEM_AGENT_NAMES
    // buckets, so this row reaches the client through by_domain ALONE — it has
    // no correct group to fall back to, which is what makes the misattribution
    // total rather than cosmetic.
    {
      action_category: 'system.instance_terminate',
      policy: 'notify_and_proceed',
      scope: 'agent',
      agent_id: 'ops-custom-uuid',
      agent_name: 'Ops Team Custom Agent',
    },
    // scope is NOT "agent" yet the row still names an agent. The live
    // serializer emits exactly this for a row created as
    // `scope: "action_type", ai_agent_id: <Fleet Autonomy>`, and buckets it
    // "Manual Operations" — so `agent_name || 'Manual Operations'` would file
    // it under the agent, a group the server never put it in.
    {
      action_category: 'system.task.ssh_command',
      policy: 'require_approval',
      scope: 'action_type',
      agent_id: 'fleet-uuid',
      agent_name: 'Fleet Autonomy',
    },
  ],
};

// ---------------------------------------------------------------------------
// Rows whose bucket cannot be determined at all: no `agent_bucket`, and not the
// fields the server's own rule (`scope` + the agent's NAME) reads.
// ---------------------------------------------------------------------------
const UNREADABLE_BY_DOMAIN = {
  gitops: [
    // Nothing the rule reads.
    { action_category: 'system.gitops_sync', policy: 'auto_approve' },
    // Agent-scoped, but the payload never says WHICH agent — and the bucket IS
    // the agent's name, so agent_id cannot stand in for it.
    {
      action_category: 'system.gitops_apply_proposal',
      policy: 'notify_and_proceed',
      scope: 'agent',
      agent_id: 'some-uuid',
    },
    // Bucketable but NOT addressable: we could name the owner, but with no
    // agent_id a save degrades to category + verb, which the update endpoint
    // stores as an ACCOUNT-WIDE scope-"global" row — written from a control
    // labelled with one agent's name. An editable control has to imply a row we
    // can write back to.
    {
      action_category: 'system.gitops_register_repository',
      policy: 'auto_approve',
      scope: 'agent',
      agent_name: 'GitOps Reconciler',
    },
  ],
};

// A domain whose rows are ALL readable, beside one whose rows are not. The
// modal opens on the readable one, which is what makes the banner's hoisting to
// modal scope observable rather than incidental.
const MIXED_BY_DOMAIN = {
  ...OLD_SHAPE_BY_DOMAIN,
  gitops: [{ action_category: 'system.gitops_sync', policy: 'auto_approve' }],
};

function autonomyResponse(byDomain: unknown) {
  return {
    data: {
      success: true,
      data: {
        agents: [],
        chains: [],
        policies: { by_agent: { 'Manual Operations': [] }, by_domain: byDomain },
      },
    },
  };
}

async function renderPanel() {
  render(<SystemSettingsPanel isOpen onClose={jest.fn()} />);
  await waitFor(() => expect(screen.queryByText('Loading…')).not.toBeInTheDocument());
}

/** The bordered box a group's header label sits in. */
function groupBox(label: string): HTMLElement {
  const box = screen.getByText(label).closest('div.rounded-lg');
  if (!box) throw new Error(`no group box rendered for ${label}`);
  return box as HTMLElement;
}

/** The `<select>` sitting next to an action row's label, or null if read-only. */
function selectFor(action: string): HTMLSelectElement | null {
  const row = screen.getByText(action).closest('div');
  return (row?.querySelector('select') as HTMLSelectElement) || null;
}

describe('SystemSettingsPanel — server predates agent_bucket', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPatch.mockReset();
  });

  it('groups an old-shape agent row under its own agent, not Manual Operations', async () => {
    mockGet.mockResolvedValue(autonomyResponse(OLD_SHAPE_BY_DOMAIN));
    await renderPanel();

    // Both groups exist — one row IS genuinely manual. What must not happen is
    // the agent-scoped row landing in the manual group, which is precisely what
    // a missing `agent_bucket` used to cause for EVERY agent-scoped row.
    const agentGroup = groupBox('Node Lifecycle · Ops Team Custom Agent');
    const manualGroup = groupBox('Node Lifecycle · Manual Operations');

    expect(within(agentGroup).getByText('system.instance_terminate')).toBeInTheDocument();
    expect(within(manualGroup).queryByText('system.instance_terminate')).not.toBeInTheDocument();
    expect(within(manualGroup).getByText('system.task.ssh_command')).toBeInTheDocument();
  });

  it('shows the agent row its own verb rather than the miss default', async () => {
    mockGet.mockResolvedValue(autonomyResponse(OLD_SHAPE_BY_DOMAIN));
    await renderPanel();

    // 'require_approval' is the hook's default for an unknown (bucket, action)
    // pair, so the seeded verb is what distinguishes "read the row" from "fell
    // through to manual and missed".
    expect(selectFor('system.instance_terminate')?.value).toBe('notify_and_proceed');
  });

  it('keys on scope, not agent_name, so a non-agent row stays manual', async () => {
    mockGet.mockResolvedValue(
      autonomyResponse({ node_lifecycle: [OLD_SHAPE_BY_DOMAIN.node_lifecycle[1]] })
    );
    await renderPanel();

    expect(screen.getByText('Node Lifecycle · Manual Operations')).toBeInTheDocument();
    expect(screen.queryByText('Node Lifecycle · Fleet Autonomy')).not.toBeInTheDocument();
  });

  // THE WRITE HALF, sharply. `AutonomyPolicyGroup` carries a "Set all" bulk
  // control that applies one verb to every action IN ITS GROUP. Merging every
  // agent-scoped row into Manual Operations therefore did not just mislabel the
  // view: an operator setting the manual group to one verb submitted that verb
  // for agent policies they never chose to touch, and did so from a screen that
  // showed those policies as manual.
  it('a bulk set in the manual group cannot reach an agent-scoped row', async () => {
    mockGet.mockResolvedValue(autonomyResponse(OLD_SHAPE_BY_DOMAIN));
    mockPatch.mockResolvedValue({ data: { ok: true } });
    await renderPanel();

    const manualGroup = groupBox('Node Lifecycle · Manual Operations');
    // The bulk control is the group header's select — first in DOM order,
    // ahead of the per-action ones in the body.
    const setAll = manualGroup.querySelector('select') as HTMLSelectElement;
    expect(within(setAll).getByText('Set all')).toBeInTheDocument();
    fireEvent.change(setAll, { target: { value: 'auto_approve' } });
    fireEvent.click(within(manualGroup).getByText('Save Permissions'));

    await waitFor(() => expect(mockPatch).toHaveBeenCalled());
    const [, body] = mockPatch.mock.calls[0] as [string, { updates: Array<Record<string, unknown>> }];
    expect(body.updates.map((u) => u.action_category)).toEqual(['system.task.ssh_command']);
  });

  it('sends the edited row its own identity, from its own group', async () => {
    mockGet.mockResolvedValue(autonomyResponse(OLD_SHAPE_BY_DOMAIN));
    mockPatch.mockResolvedValue({ data: { ok: true } });
    await renderPanel();

    const select = selectFor('system.instance_terminate');
    fireEvent.change(select as HTMLSelectElement, { target: { value: 'block' } });
    fireEvent.click(screen.getAllByText('Save Permissions')[0]);

    await waitFor(() => expect(mockPatch).toHaveBeenCalled());
    expect(mockPatch).toHaveBeenCalledWith('/system/autonomy', {
      updates: [
        {
          action_category: 'system.instance_terminate',
          policy: 'block',
          scope: 'agent',
          agent_id: 'ops-custom-uuid',
        },
      ],
    });
  });
});

describe('SystemSettingsPanel — a row whose posture cannot be read', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPatch.mockReset();
    mockGet.mockResolvedValue(autonomyResponse(UNREADABLE_BY_DOMAIN));
  });

  it('says so instead of showing a confident posture', async () => {
    await renderPanel();

    expect(screen.getByText('GitOps · Posture unknown')).toBeInTheDocument();
    expect(screen.getByTestId('autonomy-skew-warning')).toBeInTheDocument();
    // The bucket the old default invented, and the only one an operator could
    // have mistaken these rows for.
    expect(screen.queryByText('GitOps · Manual Operations')).not.toBeInTheDocument();
  });

  it('offers no editable control over state it cannot read', async () => {
    await renderPanel();

    expect(screen.getByText('system.gitops_sync')).toBeInTheDocument();
    expect(selectFor('system.gitops_sync')).toBeNull();
    expect(selectFor('system.gitops_apply_proposal')).toBeNull();
    expect(selectFor('system.gitops_register_repository')).toBeNull();
    // The one we could NAME but not address must not get a group of its own.
    expect(screen.queryByText('GitOps · GitOps Reconciler')).not.toBeInTheDocument();
    // No bulk "Set all" and no save button can reach these rows either.
    expect(screen.queryByText('Save Permissions')).not.toBeInTheDocument();
    expect(screen.queryByText('Set all')).not.toBeInTheDocument();
  });

  it('cannot be saved even when the whole domain is unreadable', async () => {
    await renderPanel();

    expect(mockPatch).not.toHaveBeenCalled();
  });

  // The badge counts rows LISTED. Unreadable rows are listed, so an operator
  // comparing the badge against the screen must not find rows missing from it.
  it('counts unreadable rows in the sidebar badge', async () => {
    await renderPanel();

    expect(screen.getByRole('button', { name: /GitOps/ })).toHaveTextContent('3');
  });
});

describe('SystemSettingsPanel — the warning is modal-scoped, not section-scoped', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPatch.mockReset();
    mockGet.mockResolvedValue(autonomyResponse(MIXED_BY_DOMAIN));
  });

  // An operator who never opens the affected section would otherwise read the
  // modal as complete. The modal opens on Node Lifecycle (SECTION_ORDER puts it
  // first among these two) and every row THERE is readable.
  it('warns while a fully readable section is on screen', async () => {
    await renderPanel();

    expect(screen.getByText('Node Lifecycle · Ops Team Custom Agent')).toBeInTheDocument();
    // No unreadable GROUP on screen — the unplaceable rows are in gitops...
    expect(screen.queryByText('GitOps · Posture unknown')).not.toBeInTheDocument();
    // ...but the warning is still up, because the modal is incomplete.
    expect(screen.getByTestId('autonomy-skew-warning')).toBeInTheDocument();
  });

  it('does not warn when every row in the payload was placeable', async () => {
    mockGet.mockResolvedValue(autonomyResponse(OLD_SHAPE_BY_DOMAIN));
    await renderPanel();

    expect(screen.queryByTestId('autonomy-skew-warning')).not.toBeInTheDocument();
  });
});
