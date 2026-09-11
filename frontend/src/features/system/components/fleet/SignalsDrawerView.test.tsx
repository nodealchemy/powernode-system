import React from 'react';
import { act, render, screen, fireEvent, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import type { ComponentStatusDetail } from '@/shared/types/platformStatus';
import type { FleetEvent } from '@system/features/system/services/api/fleetApi';
import { SignalsDrawerView, SIGNALS_LIMIT } from './SignalsDrawerView';

// =============================================================================
// Mocks
// =============================================================================

const mockHasPermission = jest.fn<boolean, [string]>();
const mockRecentSignals = jest.fn();

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: (p: string) => mockHasPermission(p) }),
}));

jest.mock('@system/features/system/services/api/fleetApi', () => ({
  fleetApi: { recentSignals: (...args: unknown[]) => mockRecentSignals(...args) },
}));

// EntityLink needs a redux Provider this suite does not set up; its own suite
// covers it. Same stub the Fleet Dashboard's tests use.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label?: React.ReactNode }) => <span data-testid="entity-link">{label}</span>,
}));

// =============================================================================
// Helpers
// =============================================================================

const REF = '019f0000-0000-7000-8000-000000000001';

const buildRow = (overrides: Partial<ComponentStatusDetail> = {}): ComponentStatusDetail => ({
  id: 'row-1',
  component_kind: 'node_instance',
  component_ref: REF,
  display_name: 'test-component',
  verdict: 'ok',
  scope: 'account',
  observed_at: null,
  presentation: null,
  conditions: [],
  dependencies: [],
  remediation: { signals: [], remediation_state: 'none', lane_reason: null },
  links: [],
  actions: [],
  observed_generation: null,
  last_notified_at: null,
  ...overrides,
} as unknown as ComponentStatusDetail);

const makeEvent = (overrides: Partial<FleetEvent> = {}): FleetEvent => ({
  id: 'evt-1',
  account_id: 'acct-1',
  kind: 'system.sdwan_peer_drift',
  severity: 'medium',
  payload: { peer_id: 'peer-1' },
  correlation_id: null,
  source: 'sensor',
  emitted_at: '2026-09-11T10:00:00Z',
  node_instance_id: REF,
  ...overrides,
});

const signals = (events: FleetEvent[]) => ({ events, count: events.length, channel: 'system_fleet:acct-1' });

const renderView = (row: ComponentStatusDetail = buildRow()) =>
  render(
    <MemoryRouter>
      <SignalsDrawerView row={row} />
    </MemoryRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('SignalsDrawerView', () => {
  beforeEach(() => {
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
    mockRecentSignals.mockReset();
    mockRecentSignals.mockResolvedValue(signals([]));
  });

  describe('permission gate', () => {
    it('checks system.fleet.read, the permission the signals endpoint enforces', () => {
      renderView();
      expect(mockHasPermission).toHaveBeenCalledWith('system.fleet.read');
    });

    it('refuses inline, naming system.fleet.read, and never asks the server', () => {
      mockHasPermission.mockReturnValue(false);
      renderView();

      expect(screen.getByText(/You don't have permission to view signals\./)).toBeInTheDocument();
      expect(screen.getByText('system.fleet.read')).toBeInTheDocument();
      expect(mockRecentSignals).not.toHaveBeenCalled();
    });

    it('asks the server once the operator holds the permission (the other arm)', async () => {
      renderView();
      await waitFor(() => expect(mockRecentSignals).toHaveBeenCalledTimes(1));
    });
  });

  // Each kind filters by its OWN typed column and sends no other id filter:
  // a stray node_module_id beside node_instance_id would AND two conditions
  // and silently return nothing.
  describe.each([
    ['node_instance', 'node_instance_id'],
    ['node_module', 'node_module_id'],
    ['acme_certificate', 'certificate_id'],
  ])('kind %s', (kind, column) => {
    it(`filters by ${column} = component_ref, and by nothing else`, async () => {
      renderView(buildRow({ component_kind: kind } as Partial<ComponentStatusDetail>));

      await waitFor(() => expect(mockRecentSignals).toHaveBeenCalledTimes(1));
      expect(mockRecentSignals).toHaveBeenCalledWith({ limit: SIGNALS_LIMIT, [column]: REF });
    });
  });

  it('does not ask the server for a kind with no typed signals column', () => {
    renderView(buildRow({ component_kind: 'redis' } as Partial<ComponentStatusDetail>));

    expect(screen.getByText(/not recorded per component for this kind/)).toBeInTheDocument();
    expect(mockRecentSignals).not.toHaveBeenCalled();
  });

  it('shows the shared loading spinner before the response lands', () => {
    mockRecentSignals.mockReturnValue(new Promise(() => undefined));
    renderView();
    expect(screen.getByText('Loading signals…')).toBeInTheDocument();
  });

  it('says so when no event records this component', async () => {
    renderView();
    expect(
      await screen.findByText('No signals: no recent fleet event records this component by node_instance_id.'),
    ).toBeInTheDocument();
  });

  it('renders each event with the Fleet Dashboard row, and states the basis of the count', async () => {
    mockRecentSignals.mockResolvedValue(
      signals([makeEvent({ id: 'evt-a', kind: 'system.kind_a' }), makeEvent({ id: 'evt-b', kind: 'system.kind_b' })]),
    );
    renderView();

    expect(await screen.findByText('system.kind_a')).toBeInTheDocument();
    expect(screen.getByText('system.kind_b')).toBeInTheDocument();
    expect(
      screen.getByText(/The 2 most recent fleet events whose node_instance_id is this component/),
    ).toBeInTheDocument();
  });

  it('opens the shared detail pane for the event the operator selects', async () => {
    mockRecentSignals.mockResolvedValue(signals([makeEvent({ id: 'evt-detail', kind: 'system.detail_kind' })]));
    renderView();

    fireEvent.click(await screen.findByText('system.detail_kind'));
    expect(screen.getByText('evt-detail')).toBeInTheDocument();
    expect(screen.getByText('payload')).toBeInTheDocument();
  });

  it('shows the error with the shared ErrorAlert and retries on request', async () => {
    mockRecentSignals.mockRejectedValueOnce(new Error('Request failed with status code 422'));
    renderView();

    expect(await screen.findByText('Request failed with status code 422')).toBeInTheDocument();

    mockRecentSignals.mockResolvedValueOnce(signals([makeEvent({ kind: 'system.after_retry' })]));
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));

    expect(await screen.findByText('system.after_retry')).toBeInTheDocument();
    expect(mockRecentSignals).toHaveBeenCalledTimes(2);
  });

  it('refetches for a new component and drops a late response for the old one', async () => {
    let resolveOld: (value: unknown) => void = () => undefined;
    mockRecentSignals.mockReturnValueOnce(new Promise((resolve) => { resolveOld = resolve; }));
    const { rerender } = renderView();

    const newRef = '019f0000-0000-7000-8000-000000000002';
    mockRecentSignals.mockResolvedValueOnce(signals([makeEvent({ kind: 'system.new_component' })]));
    rerender(
      <MemoryRouter>
        <SignalsDrawerView row={buildRow({ component_ref: newRef })} />
      </MemoryRouter>,
    );

    expect(await screen.findByText('system.new_component')).toBeInTheDocument();
    expect(mockRecentSignals).toHaveBeenLastCalledWith({ limit: SIGNALS_LIMIT, node_instance_id: newRef });

    // Resolve the stale request AND let its .then run before asserting. A
    // waitFor on an absence passes on its first check, before the late
    // response could land, so it would prove nothing about the guard.
    await act(async () => {
      resolveOld(signals([makeEvent({ kind: 'system.stale_component' })]));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(screen.queryByText('system.stale_component')).not.toBeInTheDocument();
    expect(screen.getByText('system.new_component')).toBeInTheDocument();
  });
});
