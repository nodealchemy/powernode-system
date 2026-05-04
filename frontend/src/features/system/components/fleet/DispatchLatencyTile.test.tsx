import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { DispatchLatencyTile } from './DispatchLatencyTile';
import { metricsApi } from '../../services/api/metricsApi';

jest.mock('../../services/api/metricsApi', () => ({
  metricsApi: {
    dispatch: jest.fn(),
  },
}));

const mockDispatch = metricsApi.dispatch as jest.MockedFunction<typeof metricsApi.dispatch>;

function buildResponse(overrides: Record<string, { count: number; rate_per_sec: number }> = {}) {
  const baseStat = (count = 0, rate = 0) => ({
    count,
    rate_per_sec: rate,
    window_seconds: 300,
    buckets: [],
  });
  return {
    window_seconds: 300,
    metrics: {
      'system.dispatch.claimed': baseStat(),
      'system.dispatch.started': baseStat(),
      'system.dispatch.completed': baseStat(),
      'system.dispatch.failed': baseStat(),
      'system.fleet.event': baseStat(),
      ...Object.fromEntries(
        Object.entries(overrides).map(([k, v]) => [k, { ...baseStat(v.count, v.rate_per_sec) }])
      ),
    },
  };
}

describe('DispatchLatencyTile', () => {
  beforeEach(() => {
    mockDispatch.mockReset();
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('renders loading state initially', () => {
    mockDispatch.mockReturnValue(new Promise(() => {})); // never resolves
    render(<DispatchLatencyTile />);
    expect(screen.getByText(/Loading metrics/)).toBeInTheDocument();
  });

  it('renders error state on fetch failure', async () => {
    mockDispatch.mockRejectedValue(new Error('boom'));
    render(<DispatchLatencyTile />);

    await waitFor(() => {
      expect(screen.getByText(/Failed to load dispatch metrics/)).toBeInTheDocument();
    });
  });

  it('renders all 5 tracked metric tiles after a successful fetch', async () => {
    mockDispatch.mockResolvedValue(
      buildResponse({
        'system.dispatch.completed': { count: 12, rate_per_sec: 0.04 },
        'system.dispatch.failed': { count: 1, rate_per_sec: 0.003 },
      })
    );
    render(<DispatchLatencyTile />);

    await waitFor(() => expect(screen.getByText('Completed')).toBeInTheDocument());

    expect(screen.getByText('Claimed')).toBeInTheDocument();
    expect(screen.getByText('Started')).toBeInTheDocument();
    expect(screen.getByText('Failed')).toBeInTheDocument();
    expect(screen.getByText('Fleet events')).toBeInTheDocument();
    expect(screen.getByText('12')).toBeInTheDocument();
  });

  it('computes failure rate % across completed+failed', async () => {
    mockDispatch.mockResolvedValue(
      buildResponse({
        'system.dispatch.completed': { count: 0, rate_per_sec: 0.9 },
        'system.dispatch.failed': { count: 0, rate_per_sec: 0.1 },
      })
    );
    render(<DispatchLatencyTile />);

    await waitFor(() => expect(screen.getByText(/Failure rate/)).toBeInTheDocument());

    // 0.1 / (0.9 + 0.1) = 10%
    expect(screen.getByText(/10\.00%/)).toBeInTheDocument();
  });

  it('hides failure-rate footer when no completed or failed in window', async () => {
    mockDispatch.mockResolvedValue(buildResponse({}));
    render(<DispatchLatencyTile />);

    await waitFor(() => expect(screen.getByText('Completed')).toBeInTheDocument());

    expect(screen.queryByText(/Failure rate/)).not.toBeInTheDocument();
  });

  it('renders the window label in the badge', async () => {
    mockDispatch.mockResolvedValue(buildResponse());
    render(<DispatchLatencyTile />);

    await waitFor(() => expect(screen.getByText('5m window')).toBeInTheDocument());
  });
});
