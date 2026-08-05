import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import { BootReplayModal } from './BootReplayModal';

// =============================================================================
// Mocks
// =============================================================================

const mockHasPermission = jest.fn<boolean, [string]>();

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (p: string) => mockHasPermission(p),
  }),
}));

// Stub BootReplayTimeline so this test focuses on BootReplayModal's own
// behavior (open/close, permission gate, subtitle) without reproducing
// the timeline's own test suite.
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
const CORRELATION_ID = 'corr9876543210ab';

const renderModal = (props: Partial<React.ComponentProps<typeof BootReplayModal>> = {}) => {
  const defaults = {
    instanceId: INSTANCE_ID,
    onClose: jest.fn(),
  };
  return render(<BootReplayModal {...defaults} {...props} />);
};

// =============================================================================
// Tests
// =============================================================================

describe('BootReplayModal', () => {
  beforeEach(() => {
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
  });

  // ── Closed state ────────────────────────────────────────────────────────────

  it('renders nothing when instanceId is null (modal stays closed)', () => {
    renderModal({ instanceId: null });
    // When isOpen is false the Modal component returns null — the portal is
    // never mounted so "Boot Replay" heading is absent.
    expect(screen.queryByText('Boot Replay')).not.toBeInTheDocument();
  });

  // ── Open state ──────────────────────────────────────────────────────────────

  it('renders the modal title when instanceId is provided', () => {
    renderModal();
    expect(screen.getByText('Boot Replay')).toBeInTheDocument();
  });

  it('renders subtitle with first 8 chars of instanceId only', () => {
    renderModal({ instanceId: INSTANCE_ID });
    // First 8 chars of INSTANCE_ID is 'abcdef12'
    expect(screen.getByText(/Instance abcdef12$/)).toBeInTheDocument();
  });

  it('renders subtitle including session when correlationId is provided', () => {
    renderModal({ instanceId: INSTANCE_ID, correlationId: CORRELATION_ID });
    // First 8 of CORRELATION_ID is 'corr9876'
    expect(screen.getByText(/Instance abcdef12 · session corr9876/)).toBeInTheDocument();
  });

  // ── Permission gate ──────────────────────────────────────────────────────────

  it('checks the system.fleet.read permission', () => {
    renderModal();
    expect(mockHasPermission).toHaveBeenCalledWith('system.fleet.read');
  });

  it('shows permission-denied message when operator lacks system.fleet.read', () => {
    mockHasPermission.mockReturnValue(false);
    renderModal();

    expect(
      screen.getByText(/You don't have permission to view boot replays\./),
    ).toBeInTheDocument();
    expect(screen.getByText('system.fleet.read')).toBeInTheDocument();
    expect(screen.queryByTestId('boot-replay-timeline')).not.toBeInTheDocument();
  });

  it('shows the timeline when operator has system.fleet.read', () => {
    mockHasPermission.mockReturnValue(true);
    renderModal();

    expect(screen.getByTestId('boot-replay-timeline')).toBeInTheDocument();
    expect(
      screen.queryByText(/You don't have permission/),
    ).not.toBeInTheDocument();
  });

  // ── Timeline props ───────────────────────────────────────────────────────────

  it('passes instanceId down to BootReplayTimeline', () => {
    renderModal({ instanceId: INSTANCE_ID });
    const timeline = screen.getByTestId('boot-replay-timeline');
    expect(timeline.getAttribute('data-instance-id')).toBe(INSTANCE_ID);
  });

  it('passes correlationId down to BootReplayTimeline', () => {
    renderModal({ instanceId: INSTANCE_ID, correlationId: CORRELATION_ID });
    const timeline = screen.getByTestId('boot-replay-timeline');
    expect(timeline.getAttribute('data-correlation-id')).toBe(CORRELATION_ID);
  });

  it('passes empty correlationId when prop is omitted', () => {
    renderModal({ instanceId: INSTANCE_ID });
    const timeline = screen.getByTestId('boot-replay-timeline');
    // Our stub converts undefined to '' via the ?? '' fallback
    expect(timeline.getAttribute('data-correlation-id')).toBe('');
  });

  // ── Close behaviour ──────────────────────────────────────────────────────────

  it('calls onClose when the modal close button is clicked', () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.click(screen.getByLabelText('Close modal'));

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when Escape key is pressed', () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.keyDown(document, { key: 'Escape' });

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ── Size / structure ─────────────────────────────────────────────────────────

  it('wraps content in a min-h-[60vh] container', () => {
    renderModal();
    // The wrapping div inside Modal children carries this class
    const wrapper = screen.getByTestId('boot-replay-timeline').closest('.min-h-\\[60vh\\]');
    expect(wrapper).not.toBeNull();
  });
});
