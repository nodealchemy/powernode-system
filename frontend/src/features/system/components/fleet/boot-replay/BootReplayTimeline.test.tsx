import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import { BootReplayTimeline } from './BootReplayTimeline';
import type { BootEvent, BootReplayResponse } from '../../../services/api/bootReplayApi';

const mockUseBootReplay = jest.fn();

jest.mock('./useBootReplay', () => ({
  useBootReplay: (instanceId: string | null, correlationId?: string) =>
    mockUseBootReplay(instanceId, correlationId),
}));

function buildResponse(events: BootEvent[]): BootReplayResponse {
  return {
    events,
    instance_id: 'i-test',
    phase_summary: {
      kernel: { first_at: '2026-05-04T10:00:00Z', last_at: '2026-05-04T10:00:30Z', count: 2 },
    },
  };
}

describe('BootReplayTimeline', () => {
  beforeEach(() => {
    mockUseBootReplay.mockReset();
  });

  it('prompts to select an instance when instanceId is null', () => {
    mockUseBootReplay.mockReturnValue({ loading: false, data: null, error: null, refresh: jest.fn() });
    render(<BootReplayTimeline instanceId={null} />);
    expect(
      screen.getByText('Select a node instance to replay its boot timeline.')
    ).toBeInTheDocument();
  });

  it('renders loading state until data arrives', () => {
    mockUseBootReplay.mockReturnValue({ loading: true, data: null, error: null, refresh: jest.fn() });
    render(<BootReplayTimeline instanceId="i-1" />);
    expect(screen.getByText(/Loading boot replay/)).toBeInTheDocument();
  });

  it('renders error state with a retry button', () => {
    const refresh = jest.fn();
    mockUseBootReplay.mockReturnValue({ loading: false, data: null, error: 'fetch failed', refresh });
    render(<BootReplayTimeline instanceId="i-1" />);

    expect(screen.getByText(/fetch failed/)).toBeInTheDocument();
    fireEvent.click(screen.getByText('retry'));
    expect(refresh).toHaveBeenCalled();
  });

  it('renders empty-events fallback when data has zero events', () => {
    mockUseBootReplay.mockReturnValue({
      loading: false,
      data: buildResponse([]),
      error: null,
      refresh: jest.fn(),
    });
    render(<BootReplayTimeline instanceId="i-1" />);

    expect(screen.getByText(/No boot events recorded/)).toBeInTheDocument();
  });

  it('renders all phases (events / no events) and event list', () => {
    const events: BootEvent[] = [
      {
        id: 'e1', kind: 'kernel.boot', severity: 'low', payload: {},
        emitted_at: '2026-05-04T10:00:00Z',
      },
      {
        id: 'e2', kind: 'enrollment.token_seen', severity: 'high', payload: {},
        emitted_at: '2026-05-04T10:00:05Z',
      },
    ];
    mockUseBootReplay.mockReturnValue({
      loading: false,
      data: buildResponse(events),
      error: null,
      refresh: jest.fn(),
    });
    render(<BootReplayTimeline instanceId="i-1" />);

    expect(screen.getByText(/Boot phases — 2 events/)).toBeInTheDocument();
    expect(screen.getByText('kernel')).toBeInTheDocument();
    expect(screen.getByText('firmware')).toBeInTheDocument();
    expect(screen.getAllByText('no events').length).toBeGreaterThan(0);
    expect(screen.getByText('kernel.boot')).toBeInTheDocument();
    expect(screen.getByText('enrollment.token_seen')).toBeInTheDocument();
    expect(screen.getByText('high')).toBeInTheDocument();
  });

  it('shows event detail in the right panel when an event is clicked', () => {
    const events: BootEvent[] = [
      {
        id: 'e1', kind: 'kernel.module_loaded', severity: 'low',
        payload: { module: 'overlay' },
        emitted_at: '2026-05-04T10:00:00Z',
      },
    ];
    mockUseBootReplay.mockReturnValue({
      loading: false,
      data: buildResponse(events),
      error: null,
      refresh: jest.fn(),
    });
    render(<BootReplayTimeline instanceId="i-1" />);

    expect(screen.getByText('Select an event to view its payload.')).toBeInTheDocument();

    fireEvent.click(screen.getByText('kernel.module_loaded'));

    expect(screen.getByText(/"module": "overlay"/)).toBeInTheDocument();
  });
});
