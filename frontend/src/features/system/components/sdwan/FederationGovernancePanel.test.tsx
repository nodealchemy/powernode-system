import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { FederationGovernancePanel } from './FederationGovernancePanel';
import type { SdwanFederationFinding } from '../../types/sdwan.types';

// =============================================================================
// Mocks
//
// The component calls sdwanApi.scanFederation() exclusively; sdwanApi itself
// calls the server governance scan endpoint, but we stub at the sdwanApi layer
// so we can return shaped findings directly.
// =============================================================================

const mockScanFederation = jest.fn();

jest.mock('../../services/api/sdwanApi', () => ({
  sdwanApi: {
    scanFederation: (...args: unknown[]) => mockScanFederation(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const FINDING_HIGH: SdwanFederationFinding = {
  kind: 'expired_trust_jwt',
  severity: 'high',
  federation_peer_id: 'peer-alpha',
  message: 'Trust JWT expired at 2026-01-01T00:00:00Z. Revoke and re-propose.',
  payload: { remote_instance_url: 'https://alpha.example.com', status: 'accepted' },
};

const FINDING_MEDIUM: SdwanFederationFinding = {
  kind: 'stale_accepted_without_handshake',
  severity: 'medium',
  federation_peer_id: 'peer-beta',
  message: 'Peer is accepted but the cross-CA handshake never completed.',
  payload: { remote_instance_url: 'https://beta.example.com' },
};

const FINDING_CRITICAL: SdwanFederationFinding = {
  kind: 'prefix_overlap_with_install',
  severity: 'critical',
  federation_peer_id: 'peer-gamma',
  message: 'Prefix overlaps with install address space.',
  payload: {},
};

function scanResult(findings: SdwanFederationFinding[]) {
  const severity_summary = findings.reduce<Record<string, number>>((acc, f) => {
    acc[f.severity] = (acc[f.severity] ?? 0) + 1;
    return acc;
  }, {});
  return { findings, finding_count: findings.length, severity_summary };
}

// =============================================================================
// Render helper
// =============================================================================

function renderPanel(props: { refreshKey?: number } = {}) {
  return render(<FederationGovernancePanel {...props} />);
}

// =============================================================================
// Tests
// =============================================================================

describe('FederationGovernancePanel', () => {
  beforeEach(() => {
    mockScanFederation.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Initial render + loading state
  // ---------------------------------------------------------------------------

  it('shows "Scanning…" while the initial scan is in progress', async () => {
    // Never resolve so we can observe the loading state
    mockScanFederation.mockReturnValue(new Promise(() => {}));

    renderPanel();

    expect(screen.getByText('Scanning…')).toBeInTheDocument();
    // Button is disabled while scanning
    expect(screen.getByRole('button', { name: /scanning/i })).toBeDisabled();
  });

  it('automatically runs the scan on mount (calls scanFederation once)', async () => {
    mockScanFederation.mockResolvedValue(scanResult([]));

    renderPanel();

    await waitFor(() => expect(mockScanFederation).toHaveBeenCalledTimes(1));
  });

  // ---------------------------------------------------------------------------
  // Empty findings state (healthy)
  // ---------------------------------------------------------------------------

  it('renders the healthy banner when the scan returns zero findings', async () => {
    mockScanFederation.mockResolvedValue(scanResult([]));

    renderPanel();

    await waitFor(() =>
      expect(
        screen.getByText(/No governance findings\. Federation peers look healthy\./i),
      ).toBeInTheDocument(),
    );
    // "Re-scan" button is back to its idle label
    expect(screen.getByRole('button', { name: /re-scan/i })).toBeEnabled();
  });

  // ---------------------------------------------------------------------------
  // Findings rendering
  // ---------------------------------------------------------------------------

  it('renders a finding row for each item returned by the scan', async () => {
    mockScanFederation.mockResolvedValue(
      scanResult([FINDING_HIGH, FINDING_MEDIUM]),
    );

    renderPanel();

    await waitFor(() =>
      expect(
        screen.getByText('Trust JWT expired at 2026-01-01T00:00:00Z. Revoke and re-propose.'),
      ).toBeInTheDocument(),
    );

    expect(
      screen.getByText('Peer is accepted but the cross-CA handshake never completed.'),
    ).toBeInTheDocument();

    // Severity badges
    expect(screen.getByText('high')).toBeInTheDocument();
    expect(screen.getByText('medium')).toBeInTheDocument();

    // Finding kind labels
    expect(screen.getByText('expired_trust_jwt')).toBeInTheDocument();
    expect(screen.getByText('stale_accepted_without_handshake')).toBeInTheDocument();

    // Peer ID footers
    expect(screen.getByText('peer: peer-alpha')).toBeInTheDocument();
    expect(screen.getByText('peer: peer-beta')).toBeInTheDocument();
  });

  it('applies the correct severity badge class for "critical" severity', async () => {
    mockScanFederation.mockResolvedValue(scanResult([FINDING_CRITICAL]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('critical')).toBeInTheDocument());

    const badge = screen.getByText('critical');
    expect(badge.className).toMatch(/bg-theme-danger-bg/);
  });

  it('applies the correct severity badge class for "high" severity', async () => {
    mockScanFederation.mockResolvedValue(scanResult([FINDING_HIGH]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('high')).toBeInTheDocument());

    const badge = screen.getByText('high');
    expect(badge.className).toMatch(/bg-theme-warning-bg/);
  });

  it('applies the correct severity badge class for "medium" severity', async () => {
    mockScanFederation.mockResolvedValue(scanResult([FINDING_MEDIUM]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('medium')).toBeInTheDocument());

    const badge = screen.getByText('medium');
    expect(badge.className).toMatch(/bg-theme-info-bg/);
  });

  it('applies the default badge class for "low" severity', async () => {
    const LOW_FINDING: SdwanFederationFinding = {
      kind: 'prefix_overlap_with_other_peer',
      severity: 'low',
      federation_peer_id: 'peer-delta',
      message: 'Low severity finding.',
      payload: {},
    };
    mockScanFederation.mockResolvedValue(scanResult([LOW_FINDING]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('low')).toBeInTheDocument());

    const badge = screen.getByText('low');
    expect(badge.className).toMatch(/bg-theme-background-secondary/);
  });

  it('renders multiple findings as a list', async () => {
    mockScanFederation.mockResolvedValue(
      scanResult([FINDING_HIGH, FINDING_MEDIUM, FINDING_CRITICAL]),
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getAllByText(/peer:/i)).toHaveLength(3),
    );
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error banner when scanFederation throws', async () => {
    mockScanFederation.mockRejectedValue(new Error('Network timeout'));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
    // Re-scan button returns to enabled after an error
    expect(screen.getByRole('button', { name: /re-scan/i })).toBeEnabled();
  });

  it('uses a generic "Scan failed" message when the thrown value is not an Error', async () => {
    mockScanFederation.mockRejectedValue('unexpected string rejection');

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('Scan failed')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Re-scan button interaction
  // ---------------------------------------------------------------------------

  it('re-runs the scan when the Re-scan button is clicked', async () => {
    mockScanFederation
      .mockResolvedValueOnce(scanResult([]))           // initial auto-scan
      .mockResolvedValueOnce(scanResult([FINDING_HIGH])); // manual re-scan

    renderPanel();

    // Wait for initial scan to finish
    await waitFor(() =>
      expect(
        screen.getByText(/No governance findings\./i),
      ).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /re-scan/i }));

    await waitFor(() =>
      expect(
        screen.getByText('Trust JWT expired at 2026-01-01T00:00:00Z. Revoke and re-propose.'),
      ).toBeInTheDocument(),
    );

    expect(mockScanFederation).toHaveBeenCalledTimes(2);
  });

  it('disables the Re-scan button while the re-scan is in progress', async () => {
    mockScanFederation
      .mockResolvedValueOnce(scanResult([]))  // initial scan resolves fast
      .mockReturnValueOnce(new Promise(() => {})); // re-scan hangs

    renderPanel();

    // Wait for initial scan to settle
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /re-scan/i })).toBeEnabled(),
    );

    fireEvent.click(screen.getByRole('button', { name: /re-scan/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /scanning/i })).toBeDisabled(),
    );
  });

  it('clears a previous error when a successful re-scan follows', async () => {
    mockScanFederation
      .mockRejectedValueOnce(new Error('Transient error'))
      .mockResolvedValueOnce(scanResult([]));

    renderPanel();

    // First scan errors
    await waitFor(() =>
      expect(screen.getByText('Transient error')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /re-scan/i }));

    // Error clears after successful re-scan
    await waitFor(() =>
      expect(screen.queryByText('Transient error')).not.toBeInTheDocument(),
    );
    expect(
      screen.getByText(/No governance findings\./i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // refreshKey prop — triggers re-scan when it changes
  // ---------------------------------------------------------------------------

  it('re-runs the scan when refreshKey changes', async () => {
    mockScanFederation.mockResolvedValue(scanResult([]));

    const { rerender } = renderPanel({ refreshKey: 0 });

    await waitFor(() => expect(mockScanFederation).toHaveBeenCalledTimes(1));

    rerender(<FederationGovernancePanel refreshKey={1} />);

    await waitFor(() => expect(mockScanFederation).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Static UI elements
  // ---------------------------------------------------------------------------

  it('renders the panel heading', () => {
    mockScanFederation.mockReturnValue(new Promise(() => {}));
    renderPanel();
    expect(screen.getByText('Governance scan')).toBeInTheDocument();
  });

  // The footer used to point operators at the MCP tool "for the full
  // server-side scan" — the panel IS the full server-side scan now
  // (IMP-65f479ad8484), so directing them elsewhere would be wrong.
  it('does not tell the operator to run the MCP tool for a fuller scan', () => {
    mockScanFederation.mockReturnValue(new Promise(() => {}));
    renderPanel();
    expect(screen.queryByText(/system_sdwan_federation_scan/i)).not.toBeInTheDocument();
  });

  // A migration-chain finding carries no peer, so the peer line must be
  // omitted rather than rendered blank.
  it('omits the peer line for a finding with no federation_peer_id', async () => {
    const CHAIN_FINDING: SdwanFederationFinding = {
      kind: 'migration_chain_failed',
      severity: 'high',
      federation_peer_id: null,
      message: 'Multi-hop migration chain failed at hop position 2.',
      payload: { migration_chain_id: 'mc-1' },
    };
    mockScanFederation.mockResolvedValue(scanResult([CHAIN_FINDING]));
    renderPanel();

    await waitFor(() => {
      expect(screen.getByText(/Multi-hop migration chain failed/)).toBeInTheDocument();
    });
    expect(screen.queryByText(/^peer:/)).not.toBeInTheDocument();
  });
});
