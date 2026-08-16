import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { SystemSettingsPanel } from './SystemSettingsPanel';

// =============================================================================
// IMP-0874acd5b50c — the Autonomy modal must render the policy rows the SERVER
// returns, not a list literal-ed into this component.
//
// The defect these examples pin: `SystemSettingsPanel` used to declare
// `DOMAIN_SECTIONS`, seven sections each carrying a hardcoded `actions:
// string[]`, and rendered exactly those strings. Measured against the seed
// files that produce the policy rows (119 categories), the literal list omitted
// 28 — including all 14 registered by IMP-097a267b50b7 — and carried one ghost
// (`system.runtime_docker_tls_rotate`, whose seed was deleted in the 2026-05-19
// audit) that no row backs.
//
// This file is the companion to SystemSettingsPanel.test.tsx, which stubs the
// hook. A hook stub can only show that the panel renders whatever state it is
// handed; it cannot show that the state came from the endpoint. So here the
// REAL hook runs and only `apiClient` is mocked, which makes the HTTP payload
// the sole source of every rendered category.
//
// The invariant is written over the set the FAILING CONSUMER accepts. Two
// consumers matter and they are not the same set:
//
//   * What can be DISPLAYED is the policy ROWS the GET returns — the by_domain
//     pivot. That is what these examples drive.
//   * What can be SAVED is `Ai::InterventionPolicy.registered_categories` (134
//     as of IMP-eb60db901f5f; it was 138 when this was written, before the
//     docker-TLS ghost and three duplicate spellings were deregistered), a
//     strict SUPERSET of the seeded rows: it also carries core's generic
//     `approval` / `proposal` / `dev.*` categories, which have no business in a
//     System-extension modal. So "drive it from the registry" would be wrong —
//     the rows are the right source. When this was written the registry still
//     carried `system.runtime_docker_tls_rotate`, whose seed had been deleted,
//     so a registry-driven modal would have shown a control for an action
//     nothing could execute; that registration is gone now, but the reason the
//     rows are the right source is unchanged.
//
// So: no assertion below names a category the component knows about. Every
// rendered string has to arrive from the mocked HTTP payload, and a category
// the payload omits has to be absent even if the old literal listed it.
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

// The chains tab fetches on its own; it is not under test here.
jest.mock('@/shared/components/approval-chains/ApprovalChainList', () => ({
  ApprovalChainList: () => <div data-testid="approval-chain-list" />,
}));

// ---------------------------------------------------------------------------
// Fixture
//
// Shaped like GET /api/v1/system/autonomy. Deliberately NOT a copy of the real
// seed set — it is a small payload whose members were chosen for what they
// prove:
//
//   gitops            — a whole domain the old literal list had no section for,
//                       AND a row this fixture's `by_agent` map omits, so its
//                       value can only come from the row itself. (The live
//                       pivot has listed "GitOps Reconciler" since
//                       IMP-e3a30e2dd5ee; the omission here is the fixture's,
//                       and stands in for any agent outside that list.)
//   container_runtime — present, but WITHOUT the ghost the literal list carried.
//   node_lifecycle    — a domain the literal list did cover, returning ONE of
//                       its ten literals, so "the list is gone" is observable.
//                       Placed LAST, as the live server places it.
//   quarantine        — a domain key this component has never heard of; it has
//                       to render anyway, or the drift returns the day the
//                       server declares a new bucket.
//   other             — the pivot's catch-all, POPULATED. This is not a
//                       hypothetical: the endpoint is an account-wide policy
//                       view, and core seeds six of its own global rows
//                       (server/db/seeds/autonomy_data_seed.rb), none of which
//                       matches a DOMAIN_PREFIXES entry.
//
// Key order here is deliberately the SERVER's (DOMAIN_PREFIXES' order), which
// is ordered for prefix-shadowing correctness rather than operator priority —
// a fixture that led with node_lifecycle would make a default-section
// assertion pass while the live modal opened somewhere else.
// ---------------------------------------------------------------------------

const GITOPS_ROW = {
  action_category: 'system.gitops_apply_proposal',
  agent_bucket: 'GitOps Reconciler',
  policy: 'notify_and_proceed',
};

const byDomainFixture = {
  container_runtime: [
    { action_category: 'system.runtime_docker_provision', agent_bucket: 'Runtime Manager', policy: 'auto_approve' },
  ],
  gitops: [GITOPS_ROW],
  quarantine: [
    { action_category: 'system.made_up_future_action', agent_bucket: 'Manual Operations', policy: 'block' },
  ],
  node_lifecycle: [
    { action_category: 'system.cert_rotate', agent_bucket: 'Fleet Autonomy', policy: 'require_approval' },
  ],
  other: [
    { action_category: 'status_update', agent_bucket: 'Manual Operations', policy: 'notify_and_proceed' },
    { action_category: 'proposal', agent_bucket: 'Manual Operations', policy: 'require_approval' },
  ],
};

function autonomyResponse(byDomain: unknown = byDomainFixture) {
  return {
    data: {
      success: true,
      data: {
        agents: [],
        chains: [],
        policies: {
          // by_agent deliberately omits the GitOps Reconciler bucket, mirroring
          // the live pivot's `next unless result.key?(bucket)` drop. If the
          // gitops select still shows the seeded verb, the value came from the
          // row and not from this map.
          //
          // The live pivot no longer drops THIS agent specifically —
          // SYSTEM_AGENT_NAMES was extended with the GitOps Reconciler
          // (IMP-e3a30e2dd5ee) — but the drop itself is unchanged and still
          // reaches any agent outside that list, an operator's own agent
          // included. The fixture is kept as-is because what it pins is that
          // the panel reads the ROW, which must hold for any bucket by_agent
          // omits; retargeting it would only rename the agent in a payload
          // this file writes by hand.
          by_agent: {
            'Fleet Autonomy': [
              { action_category: 'system.cert_rotate', policy: 'require_approval' },
            ],
          },
          by_domain: byDomain,
        },
      },
    },
  };
}

/** The `<select>` sitting next to an action row's label. */
function selectFor(action: string): HTMLSelectElement {
  const row = screen.getByText(action).closest('div');
  const select = row?.querySelector('select');
  if (!select) throw new Error(`no policy select rendered for ${action}`);
  return select as HTMLSelectElement;
}

async function renderPanel() {
  render(<SystemSettingsPanel isOpen onClose={jest.fn()} />);
  await waitFor(() => expect(screen.queryByText('Loading…')).not.toBeInTheDocument());
}

/** Activates a sidebar section by its visible label. */
function openSection(label: string) {
  fireEvent.click(screen.getByRole('button', { name: new RegExp(label) }));
}

describe('SystemSettingsPanel — renders the server\'s policy rows', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPatch.mockReset();
    mockGet.mockResolvedValue(autonomyResponse());
  });

  it('renders a domain the component has no section literal for', async () => {
    await renderPanel();

    openSection('GitOps');

    expect(screen.getByText(GITOPS_ROW.action_category)).toBeInTheDocument();
  });

  it('renders a domain key it has never seen, under a derived label', async () => {
    await renderPanel();

    // No presentation entry exists for "quarantine" — the section still has to
    // appear, because a missing LABEL must degrade to a humanised fallback
    // while a missing ACTIONS list used to make the category unreachable.
    openSection('Quarantine');

    expect(screen.getByText('system.made_up_future_action')).toBeInTheDocument();
  });

  it('shows the row\'s own policy verb even when by_agent dropped its bucket', async () => {
    await renderPanel();

    openSection('GitOps');

    // 'require_approval' is the hook's default for an unknown (agent, action)
    // pair, so asserting the seeded verb is what distinguishes "read the row"
    // from "fell back".
    expect(selectFor(GITOPS_ROW.action_category).value).toBe('notify_and_proceed');
  });

  it('does not render the ghost control the server returns no row for', async () => {
    await renderPanel();

    openSection('Container Runtimes');

    expect(screen.getByText('system.runtime_docker_provision')).toBeInTheDocument();
    // Removed from the seeds by the 2026-05-19 audit — no executor ever backed
    // it. It stayed REGISTERED for another three months (removed under
    // IMP-6e52d6aa53da), which is why this guard is worth keeping even now:
    // it holds for a ROW-driven modal whatever the registry says, and the
    // registry is a second source that has already drifted once.
    expect(screen.queryByText('system.runtime_docker_tls_rotate')).not.toBeInTheDocument();
  });

  it('renders only the categories the payload carries for a domain it does have a section for', async () => {
    await renderPanel();

    openSection('Node Lifecycle');

    expect(screen.getByText('system.cert_rotate')).toBeInTheDocument();
    // Siblings of system.cert_rotate in the old node_lifecycle literal. The
    // payload does not carry them, so nothing may render them.
    expect(screen.queryByText('system.instance_terminate')).not.toBeInTheDocument();
    expect(screen.queryByText('system.fleet_rolling_upgrade')).not.toBeInTheDocument();
  });

  // Guards against a wrong FIX rather than against the old behaviour: reverting
  // the change leaves this green (the literal list had no "Other" section
  // either). It reds on a fix that renders every key the pivot ships.
  it('offers no section for the catch-all bucket of rows this extension does not own', async () => {
    await renderPanel();

    expect(screen.queryByRole('button', { name: /Other/ })).not.toBeInTheDocument();
    // The endpoint is an ACCOUNT-WIDE policy view and correctly returns these;
    // core's own notification categories are simply not the System extension's
    // to configure, so the modal must not offer them.
    expect(screen.queryByText('status_update')).not.toBeInTheDocument();
    expect(screen.queryByText('proposal')).not.toBeInTheDocument();
  });

  it('opens on the first section in presentation order, not the server\'s key order', async () => {
    await renderPanel();

    // The payload leads with container_runtime and puts node_lifecycle LAST —
    // DOMAIN_PREFIXES is ordered so that a prefix extending another is declared
    // first, which is a correctness constraint, not a running order. Reading it
    // as one opens the modal on whichever domain happens to be declared first.
    expect(
      screen.getByRole('heading', { name: 'Node Lifecycle' }),
    ).toBeInTheDocument();
    expect(screen.getByText('system.cert_rotate')).toBeInTheDocument();
  });

  it('appends a domain key it does not recognise after the ones it does', async () => {
    await renderPanel();

    const labels = screen
      .getAllByRole('button')
      .map((b) => b.textContent || '')
      .filter((t) => /Node Lifecycle|Container Runtimes|GitOps|Quarantine/.test(t));

    expect(labels.map((t) => t.replace(/\d+$/, '').trim())).toEqual([
      'Node Lifecycle',
      'Container Runtimes',
      'GitOps',
      'Quarantine',
    ]);
  });

  // Vacuity guard. No mutant of the fix reds this one — it fails only if the
  // examples above stopped being driven by the payload at all (a panel that
  // renders nothing makes every `queryBy...not.toBeInTheDocument` trivially
  // true, and `openSection` would then be the only thing throwing).
  it('has a real payload driving it (guards the negative assertions above)', async () => {
    await renderPanel();

    expect(mockGet).toHaveBeenCalledWith('/system/autonomy');
    // Every non-empty domain in the fixture, and nothing else.
    ['Node Lifecycle', 'Container Runtimes', 'GitOps', 'Quarantine'].forEach((label) => {
      expect(screen.getByRole('button', { name: new RegExp(label) })).toBeInTheDocument();
    });
    expect(screen.getByRole('button', { name: /Approval Chains/ })).toBeInTheDocument();
  });
});
