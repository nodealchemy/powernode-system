import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { FlowSamplesTab } from './FlowSamplesTab';
import type { SdwanIpfixCollector, SdwanFlowSample } from '@system/features/system/types/sdwan.types';

// =============================================================================
// Mocks
//
// The component calls sdwanApi.getIpfixCollectors() on mount, then
// sdwanApi.getFlowSamples() whenever selectedCollectorId / sinceMinutes /
// protocol changes.  We stub sdwanApi at the module level so no real HTTP
// requests are made.
// =============================================================================

const mockGetIpfixCollectors = jest.fn();
const mockGetFlowSamples = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    getIpfixCollectors: (...args: unknown[]) => mockGetIpfixCollectors(...args),
    getFlowSamples: (...args: unknown[]) => mockGetFlowSamples(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const COLLECTOR_A: SdwanIpfixCollector = {
  id: 'col-a',
  name: 'primary-collector',
  host: '10.0.0.1',
  port: 4739,
  target_endpoint: 'http://platform/api/v1/system/sdwan/ipfix_collectors/col-a/flow_samples',
  sampling_rate: 1,
  state: 'active',
  is_winning_collector: true,
  created_at: '2026-05-01T00:00:00Z',
  updated_at: '2026-05-01T00:00:00Z',
};

const COLLECTOR_B: SdwanIpfixCollector = {
  id: 'col-b',
  name: 'backup-collector',
  host: '10.0.0.2',
  port: 4739,
  target_endpoint: 'http://platform/api/v1/system/sdwan/ipfix_collectors/col-b/flow_samples',
  sampling_rate: 2,
  state: 'active',
  is_winning_collector: false,
  created_at: '2026-05-01T00:00:00Z',
  updated_at: '2026-05-01T00:00:00Z',
};

function makeSample(id: string, overrides: Partial<SdwanFlowSample> = {}): SdwanFlowSample {
  return {
    id,
    src_ip: '192.168.1.10',
    dst_ip: '10.0.0.5',
    src_port: 54321,
    dst_port: 443,
    protocol: 6,
    protocol_label: 'tcp',
    octet_count: 4096,
    packet_count: 32,
    flow_start_at: '2026-06-05T12:00:00Z',
    flow_end_at: '2026-06-05T12:00:01Z',
    observed_at: '2026-06-05T12:00:01Z',
    ...overrides,
  };
}

const SAMPLE_A = makeSample('sample-a');
const SAMPLE_B = makeSample('sample-b', {
  src_ip: '172.16.0.1',
  dst_ip: '8.8.8.8',
  src_port: null,
  dst_port: null,
  protocol: 1,
  protocol_label: 'icmp',
  octet_count: 84,
  packet_count: 1,
});

function flowResponse(samples: SdwanFlowSample[]) {
  return { samples, count: samples.length };
}

// =============================================================================
// Helpers
// =============================================================================

const renderTab = () =>
  render(
    <BrowserRouter>
      <FlowSamplesTab />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('FlowSamplesTab', () => {
  beforeEach(() => {
    mockGetIpfixCollectors.mockReset();
    mockGetFlowSamples.mockReset();
  });

  // --------------------------------------------------------------------------
  // Loading state
  // --------------------------------------------------------------------------

  it('shows a loading indicator while collectors are being fetched', () => {
    // Never resolve — stays in loading state
    mockGetIpfixCollectors.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByText(/loading collectors/i)).toBeInTheDocument();
  });

  // --------------------------------------------------------------------------
  // Empty / no collectors state
  // --------------------------------------------------------------------------

  it('shows the empty-collectors prompt when no collectors are registered', async () => {
    mockGetIpfixCollectors.mockResolvedValue([]);

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/No IPFIX collectors yet/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/Register an IPFIX collector first/i)).toBeInTheDocument();
    // getFlowSamples must NOT be called when there are no collectors
    expect(mockGetFlowSamples).not.toHaveBeenCalled();
  });

  // --------------------------------------------------------------------------
  // Error loading collectors
  // --------------------------------------------------------------------------

  it('shows an error message when getIpfixCollectors rejects', async () => {
    mockGetIpfixCollectors.mockRejectedValue(new Error('Network timeout'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/Network timeout/i)).toBeInTheDocument(),
    );
  });

  // --------------------------------------------------------------------------
  // Normal render with collectors
  // --------------------------------------------------------------------------

  it('renders filter controls after collectors load', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() => expect(screen.getByText(/primary-collector/i)).toBeInTheDocument());

    // Filter labels
    expect(screen.getByText('Collector')).toBeInTheDocument();
    expect(screen.getByText('Time range')).toBeInTheDocument();
    expect(screen.getByText('Protocol')).toBeInTheDocument();

    // Refresh button
    expect(screen.getByRole('button', { name: /refresh/i })).toBeInTheDocument();
  });

  // --------------------------------------------------------------------------
  // Default selection: winning collector
  // --------------------------------------------------------------------------

  it('auto-selects the winning collector and calls getFlowSamples with its id', async () => {
    // COLLECTOR_A is winning, COLLECTOR_B is not
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_B, COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalled());

    const [collectorId] = mockGetFlowSamples.mock.calls[0] as [string, unknown];
    expect(collectorId).toBe('col-a'); // winning collector
  });

  it('falls back to the first collector when no collector is marked winning', async () => {
    const nonWinning = { ...COLLECTOR_A, is_winning_collector: false };
    mockGetIpfixCollectors.mockResolvedValue([nonWinning, COLLECTOR_B]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalled());

    const [collectorId] = mockGetFlowSamples.mock.calls[0] as [string, unknown];
    expect(collectorId).toBe('col-a'); // first in array
  });

  // --------------------------------------------------------------------------
  // getFlowSamples called with correct params
  // --------------------------------------------------------------------------

  it('calls getFlowSamples with since, protocol: undefined, and limit: 200', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalled());

    const [collectorId, filters] = mockGetFlowSamples.mock.calls[0] as [
      string,
      { since: string; protocol: number | undefined; limit: number },
    ];
    expect(collectorId).toBe('col-a');
    expect(filters.limit).toBe(200);
    expect(filters.protocol).toBeUndefined();
    // `since` should be an ISO timestamp in the past
    expect(new Date(filters.since).getTime()).toBeLessThan(Date.now());
  });

  // --------------------------------------------------------------------------
  // Flow samples table rendering
  // --------------------------------------------------------------------------

  it('renders a table row for each flow sample', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([SAMPLE_A, SAMPLE_B]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/192\.168\.1\.10:54321/i)).toBeInTheDocument(),
    );

    // SAMPLE_A source + destination
    expect(screen.getByText('192.168.1.10:54321')).toBeInTheDocument();
    expect(screen.getByText('10.0.0.5:443')).toBeInTheDocument();

    // SAMPLE_B — null ports should NOT render the colon
    expect(screen.getByText('172.16.0.1')).toBeInTheDocument();
    expect(screen.getByText('8.8.8.8')).toBeInTheDocument();
  });

  it('shows correct byte formatting in the table', async () => {
    const large = makeSample('big', { octet_count: 2 * 1024 * 1024 }); // 2 MB
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([large]));

    renderTab();

    await waitFor(() => expect(screen.getByText('2.0 MB')).toBeInTheDocument());
  });

  it('shows KB formatting for sizes under 1 MB', async () => {
    const sample = makeSample('kb-sample', { octet_count: 2048 }); // 2 KB
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([sample]));

    renderTab();

    await waitFor(() => expect(screen.getByText('2.0 KB')).toBeInTheDocument());
  });

  it('shows GB formatting for very large byte counts', async () => {
    const sample = makeSample('gb-sample', { octet_count: 2 * 1024 * 1024 * 1024 }); // 2 GB
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([sample]));

    renderTab();

    await waitFor(() => expect(screen.getByText('2.00 GB')).toBeInTheDocument());
  });

  it('shows raw B formatting for bytes under 1 KB', async () => {
    const sample = makeSample('b-sample', { octet_count: 512 });
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([sample]));

    renderTab();

    await waitFor(() => expect(screen.getByText('512 B')).toBeInTheDocument());
  });

  it('shows packet count formatted with toLocaleString', async () => {
    const sample = makeSample('pkt', { packet_count: 1234 });
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([sample]));

    renderTab();

    // toLocaleString output depends on the locale; just assert a numeric string is present
    await waitFor(() =>
      expect(screen.getByText(sample.packet_count.toLocaleString())).toBeInTheDocument(),
    );
  });

  it('shows the sample count footer', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([SAMPLE_A, SAMPLE_B]));

    renderTab();

    await waitFor(() => expect(screen.getByText(/Showing 2 samples/i)).toBeInTheDocument());
  });

  it('uses singular "sample" when only one sample is present', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([SAMPLE_A]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/Showing 1 sample \(limit 200\)\./i)).toBeInTheDocument(),
    );
  });

  // --------------------------------------------------------------------------
  // Empty samples state (collectors present, no flows)
  // --------------------------------------------------------------------------

  it('shows the empty-samples prompt when collectors exist but no samples returned', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/No flow samples in this range/i)).toBeInTheDocument(),
    );
    // Shows the ingest endpoint path for the selected collector
    expect(
      screen.getByText((text) =>
        text.includes(`/api/v1/system/sdwan/ipfix_collectors/col-a/flow_samples`),
      ),
    ).toBeInTheDocument();
  });

  // --------------------------------------------------------------------------
  // Loading samples state
  // --------------------------------------------------------------------------

  it('shows a loading indicator while flow samples are fetching (no previous samples)', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    // Never resolve flow samples
    mockGetFlowSamples.mockReturnValue(new Promise(() => {}));

    renderTab();

    await waitFor(() => expect(screen.getByText(/Loading flow samples…/i)).toBeInTheDocument());
  });

  // --------------------------------------------------------------------------
  // Error loading samples
  // --------------------------------------------------------------------------

  it('shows an error banner when getFlowSamples rejects', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockRejectedValue(new Error('Gateway timeout'));

    renderTab();

    await waitFor(() =>
      expect(screen.getByText(/Gateway timeout/i)).toBeInTheDocument(),
    );
  });

  // --------------------------------------------------------------------------
  // Collector dropdown
  // --------------------------------------------------------------------------

  it('renders all collectors in the dropdown including winning label', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A, COLLECTOR_B]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() => expect(screen.getByText(/primary-collector/i)).toBeInTheDocument());

    // Winning collector option should show "(winning)" suffix
    expect(screen.getByRole('option', { name: /primary-collector.*\(winning\)/i })).toBeInTheDocument();
    // Non-winning collector should not have the suffix
    expect(screen.getByRole('option', { name: /^backup-collector\s*$/ })).toBeInTheDocument();
  });

  it('re-fetches flow samples when the collector is changed', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A, COLLECTOR_B]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(1));

    // Change to backup collector
    const select = screen.getByDisplayValue(/primary-collector/i);
    fireEvent.change(select, { target: { value: 'col-b' } });

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(2));
    const [secondCallId] = mockGetFlowSamples.mock.calls[1] as [string, unknown];
    expect(secondCallId).toBe('col-b');
  });

  // --------------------------------------------------------------------------
  // Time range filter
  // --------------------------------------------------------------------------

  it('changes the time range and re-fetches with updated since value', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(1));

    const timeSelect = screen.getByDisplayValue(/Last 1 hour/i);
    fireEvent.change(timeSelect, { target: { value: '5' } });

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(2));

    const [, filters] = mockGetFlowSamples.mock.calls[1] as [
      string,
      { since: string; protocol: number | undefined; limit: number },
    ];
    // "Last 5 min" = 5 * 60s window, so `since` should be within ~10s of 5 minutes ago
    const sinceMs = new Date(filters.since).getTime();
    const expectedMs = Date.now() - 5 * 60_000;
    expect(Math.abs(sinceMs - expectedMs)).toBeLessThan(10_000);
  });

  it('renders all time range options', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() => expect(screen.getByDisplayValue(/Last 1 hour/i)).toBeInTheDocument());

    expect(screen.getByRole('option', { name: 'Last 5 min' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Last 1 hour' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Last 6 hours' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Last 24 hours' })).toBeInTheDocument();
  });

  // --------------------------------------------------------------------------
  // Protocol filter
  // --------------------------------------------------------------------------

  it('changes the protocol filter and re-fetches with numeric protocol value', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(1));

    const protocolSelect = screen.getByDisplayValue(/All protocols/i);
    fireEvent.change(protocolSelect, { target: { value: '6' } });

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(2));
    const [, filters] = mockGetFlowSamples.mock.calls[1] as [
      string,
      { since: string; protocol: number | undefined; limit: number },
    ];
    expect(filters.protocol).toBe(6);
  });

  it('sends protocol: undefined when "All protocols" is selected', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples
      .mockResolvedValueOnce(flowResponse([]))
      .mockResolvedValueOnce(flowResponse([]))
      .mockResolvedValueOnce(flowResponse([]));

    renderTab();

    // First select TCP to set a protocol filter
    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(1));
    const protocolSelect = screen.getByDisplayValue(/All protocols/i);
    fireEvent.change(protocolSelect, { target: { value: '6' } });

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(2));

    // Then reset back to "All protocols"
    fireEvent.change(screen.getByDisplayValue(/TCP/i), { target: { value: '' } });

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(3));
    const [, filters] = mockGetFlowSamples.mock.calls[2] as [
      string,
      { since: string; protocol: number | undefined; limit: number },
    ];
    expect(filters.protocol).toBeUndefined();
  });

  it('renders all protocol options', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([]));

    renderTab();

    await waitFor(() => expect(screen.getByDisplayValue(/All protocols/i)).toBeInTheDocument());

    expect(screen.getByRole('option', { name: 'All protocols' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'TCP' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'UDP' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'ICMP' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'ICMPv6' })).toBeInTheDocument();
  });

  // --------------------------------------------------------------------------
  // Refresh button
  // --------------------------------------------------------------------------

  it('re-fetches samples when the Refresh button is clicked', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([SAMPLE_A]));

    renderTab();

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(1));

    const refreshButton = screen.getByRole('button', { name: /refresh/i });
    fireEvent.click(refreshButton);

    await waitFor(() => expect(mockGetFlowSamples).toHaveBeenCalledTimes(2));
  });

  it('disables the Refresh button while samples are loading', async () => {
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    // Never resolve so button stays in "refreshing" state
    mockGetFlowSamples.mockReturnValue(new Promise(() => {}));

    renderTab();

    // Wait for collectors to load and first fetch to begin
    await waitFor(() =>
      expect(screen.queryByText(/Loading collectors/i)).not.toBeInTheDocument(),
    );

    // While loading, button should show "Refreshing…" and be disabled
    const btn = await screen.findByRole('button', { name: /refreshing/i });
    expect(btn).toBeDisabled();
  });

  // --------------------------------------------------------------------------
  // Protocol badge classes (smoke — verifies conditional CSS isn't broken)
  // --------------------------------------------------------------------------

  it('renders protocol badge for each sample row', async () => {
    const tcpSample = makeSample('tcp-s', { protocol: 6, protocol_label: 'tcp' });
    const udpSample = makeSample('udp-s', { protocol: 17, protocol_label: 'udp' });
    const icmpSample = makeSample('icmp-s', { protocol: 1, protocol_label: 'icmp' });
    mockGetIpfixCollectors.mockResolvedValue([COLLECTOR_A]);
    mockGetFlowSamples.mockResolvedValue(flowResponse([tcpSample, udpSample, icmpSample]));

    renderTab();

    await waitFor(() => expect(screen.getByText('tcp')).toBeInTheDocument());
    expect(screen.getByText('udp')).toBeInTheDocument();
    expect(screen.getByText('icmp')).toBeInTheDocument();
  });
});
