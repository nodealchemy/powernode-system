import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { RemediationEffectivenessTile } from './RemediationEffectivenessTile';
import { fleetApi, type RemediationOutcomesSummary } from '../../services/api/fleetApi';

jest.mock('../../services/api/fleetApi', () => ({
  fleetApi: {
    remediationOutcomes: jest.fn(),
  },
}));

const mockOutcomes = fleetApi.remediationOutcomes as jest.MockedFunction<
  typeof fleetApi.remediationOutcomes
>;

const counts = (over: Partial<RemediationOutcomesSummary['totals']> = {}) => ({
  pending: 0,
  effective: 0,
  ineffective: 0,
  inconclusive: 0,
  settled: 0,
  effectiveness_rate: null,
  ...over,
});

function buildSummary(over: Partial<RemediationOutcomesSummary> = {}): RemediationOutcomesSummary {
  return {
    window_days: 7,
    since: '2026-09-03T00:00:00Z',
    kinds: [],
    totals: counts(),
    stuck: { threshold: 3, fingerprints: [] },
    ...over,
  };
}

describe('RemediationEffectivenessTile', () => {
  beforeEach(() => {
    mockOutcomes.mockReset();
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('renders loading state initially', () => {
    mockOutcomes.mockReturnValue(new Promise(() => {}));
    render(<RemediationEffectivenessTile />);
    expect(screen.getByText(/Loading outcomes/)).toBeInTheDocument();
  });

  it('renders error state on fetch failure', async () => {
    mockOutcomes.mockRejectedValue(new Error('boom'));
    render(<RemediationEffectivenessTile />);

    await waitFor(() =>
      expect(screen.getByText(/Failed to load remediation outcomes/)).toBeInTheDocument()
    );
  });

  it('asks for the 7-day window', async () => {
    mockOutcomes.mockResolvedValue(buildSummary());
    render(<RemediationEffectivenessTile />);

    await waitFor(() => expect(screen.getByText('7d window')).toBeInTheDocument());
    expect(mockOutcomes).toHaveBeenCalledWith(7);
  });

  it('shows the overall rate over settled rows and the per-status counts', async () => {
    mockOutcomes.mockResolvedValue(
      buildSummary({
        totals: counts({ effective: 3, ineffective: 1, pending: 2, settled: 4, effectiveness_rate: 0.75 }),
        kinds: [
          { signal_kind: 'system.module_drift', ...counts({ effective: 3, ineffective: 1, settled: 4, effectiveness_rate: 0.75 }) },
          { signal_kind: 'system.cert_expiring', ...counts({ pending: 2 }) },
        ],
      })
    );
    render(<RemediationEffectivenessTile />);

    await waitFor(() => expect(screen.getByText(/of 4 settled/)).toBeInTheDocument());
    expect(screen.getAllByText('75%').length).toBeGreaterThan(0);
    expect(screen.getByText('system.module_drift')).toBeInTheDocument();
    // A kind with nothing settled shows a dash, not 0%.
    expect(screen.getByText(/— · 0 settled/)).toBeInTheDocument();
  });

  it('says so when nothing has settled, rather than showing 0%', async () => {
    mockOutcomes.mockResolvedValue(buildSummary({ totals: counts({ pending: 5 }) }));
    render(<RemediationEffectivenessTile />);

    await waitFor(() =>
      expect(screen.getByText(/No settled remediations in this window/)).toBeInTheDocument()
    );
    expect(screen.queryByText('0%')).not.toBeInTheDocument();
  });

  it('lists stuck fingerprints with their streak', async () => {
    mockOutcomes.mockResolvedValue(
      buildSummary({
        stuck: {
          threshold: 3,
          fingerprints: [
            { fingerprint: 'module_drift:abc', signal_kind: 'system.module_drift', streak: 4, last_validated_at: null },
          ],
        },
      })
    );
    render(<RemediationEffectivenessTile />);

    await waitFor(() => expect(screen.getByText(/1 stuck \(3\+ ineffective in a row\)/)).toBeInTheDocument());
    expect(screen.getByText(/module_drift:abc · 4×/)).toBeInTheDocument();
    expect(screen.queryByText(/No stuck remediations/)).not.toBeInTheDocument();
  });

  it('says there are no stuck remediations when the list is empty', async () => {
    mockOutcomes.mockResolvedValue(buildSummary());
    render(<RemediationEffectivenessTile />);

    await waitFor(() => expect(screen.getByText(/No stuck remediations/)).toBeInTheDocument());
  });
});
