import React from 'react';
import { render, screen } from '@testing-library/react';
import { BootReplayDrawerView } from './BootReplayDrawerView';
import type { ComponentStatusDetail } from '@/shared/types/platformStatus';

// =============================================================================
// Mocks
// =============================================================================

const mockHasPermission = jest.fn<boolean, [string]>();

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (p: string) => mockHasPermission(p),
  }),
}));

// Stub BootReplayTimeline so this test focuses on BootReplayDrawerView's own
// behavior (permission gate, row -> instanceId mapping), not the timeline's
// own already-covered suite.
jest.mock('./BootReplayTimeline', () => ({
  BootReplayTimeline: ({ instanceId, correlationId }: { instanceId: string | null; correlationId?: string }) => (
    <div data-testid="boot-replay-timeline" data-instance-id={instanceId ?? ''} data-correlation-id={correlationId ?? ''}>
      timeline-stub
    </div>
  ),
}));

// =============================================================================
// Helpers
// =============================================================================

const INSTANCE_ID = 'abcdef1234567890';

// Only component_ref matters to this view; the rest of ComponentStatusDetail
// is padded with minimal valid values so the cast reads honestly.
const buildRow = (overrides: Partial<ComponentStatusDetail> = {}): ComponentStatusDetail => ({
  id: 'row-1',
  component_kind: 'node_instance',
  component_ref: INSTANCE_ID,
  display_name: 'test-instance',
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

// =============================================================================
// Tests
// =============================================================================

describe('BootReplayDrawerView', () => {
  beforeEach(() => {
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  it('checks the system.fleet.read permission', () => {
    render(<BootReplayDrawerView row={buildRow()} />);
    expect(mockHasPermission).toHaveBeenCalledWith('system.fleet.read');
  });

  it('shows the inline refusal naming system.fleet.read when the operator lacks it, with no nested Modal', () => {
    mockHasPermission.mockReturnValue(false);
    render(<BootReplayDrawerView row={buildRow()} />);

    expect(
      screen.getByText(/You don't have permission to view boot replays\./),
    ).toBeInTheDocument();
    expect(screen.getByText('system.fleet.read')).toBeInTheDocument();
    expect(screen.queryByTestId('boot-replay-timeline')).not.toBeInTheDocument();
    // No Modal chrome (close button, "Boot Replay" title) — this renders
    // inline inside the drawer's own tab, not a second overlay.
    expect(screen.queryByLabelText('Close modal')).not.toBeInTheDocument();
  });

  it('shows the timeline when the operator has system.fleet.read', () => {
    render(<BootReplayDrawerView row={buildRow()} />);

    expect(screen.getByTestId('boot-replay-timeline')).toBeInTheDocument();
    expect(screen.queryByText(/You don't have permission/)).not.toBeInTheDocument();
  });

  it('passes row.component_ref as instanceId (NodeInstanceContributor.ref_for = record.id.to_s)', () => {
    render(<BootReplayDrawerView row={buildRow({ component_ref: INSTANCE_ID })} />);

    const timeline = screen.getByTestId('boot-replay-timeline');
    expect(timeline.getAttribute('data-instance-id')).toBe(INSTANCE_ID);
  });

  it('passes no correlationId — the drawer has no notion of a specific boot session', () => {
    render(<BootReplayDrawerView row={buildRow()} />);

    const timeline = screen.getByTestId('boot-replay-timeline');
    expect(timeline.getAttribute('data-correlation-id')).toBe('');
  });
});
