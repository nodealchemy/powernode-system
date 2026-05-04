import React, { useState } from 'react';
import { ShieldAlert, RefreshCw } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { sdwanApi } from '../../services/api/sdwanApi';
import type {
  SdwanFederationFinding,
  SdwanFederationFindingSeverity,
} from '../../types/sdwan.types';

/**
 * FederationGovernancePanel — runs the client-side federation governance
 * scan and renders findings. The canonical scanner lives server-side
 * (Sdwan::FederationGovernance#scan, also exposed via MCP), but this
 * panel re-implements the cheap subset (expired_trust_jwt + stale_accepted)
 * client-side so operators see findings without an extra round-trip.
 *
 * Heavier checks (prefix overlap with install) require the server
 * Sdwan::Configuration; the operator UI defers to the MCP tool button
 * for those.
 */
export const FederationGovernancePanel: React.FC<{ refreshKey?: number }> = ({ refreshKey }) => {
  const [findings, setFindings] = useState<SdwanFederationFinding[] | null>(null);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const run = async () => {
    setRunning(true);
    setError(null);
    try {
      const result = await sdwanApi.scanFederation();
      setFindings(result.findings);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Scan failed');
    } finally {
      setRunning(false);
    }
  };

  React.useEffect(() => { run(); /* eslint-disable-line react-hooks/exhaustive-deps */ }, [refreshKey]);

  return (
    <div className="border border-theme-border rounded p-4">
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          <ShieldAlert size={18} className="text-theme-accent" />
          <h3 className="font-medium text-theme-primary">Governance scan</h3>
        </div>
        <Button variant="secondary" onClick={run} disabled={running}>
          <RefreshCw size={14} className={running ? 'animate-spin' : ''} />
          <span className="ml-1">{running ? 'Scanning…' : 'Re-scan'}</span>
        </Button>
      </div>

      {error && <div className="p-2 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>}

      {findings === null ? (
        <div className="text-sm text-theme-secondary">Click "Re-scan" to run governance checks.</div>
      ) : findings.length === 0 ? (
        <div className="p-3 bg-theme-success text-theme-success rounded text-sm">
          No governance findings. Federation peers look healthy.
        </div>
      ) : (
        <ul className="space-y-2">
          {findings.map((f, i) => (
            <li key={`${f.federation_peer_id}-${f.kind}-${i}`} className="p-3 border border-theme-border rounded">
              <div className="flex items-center gap-2 mb-1">
                <span className={severityClass(f.severity)}>{f.severity}</span>
                <span className="text-xs text-theme-secondary font-mono">{f.kind}</span>
              </div>
              <p className="text-sm text-theme-primary">{f.message}</p>
              <p className="text-xs text-theme-secondary mt-1 font-mono">peer: {f.federation_peer_id}</p>
            </li>
          ))}
        </ul>
      )}

      <p className="text-xs text-theme-secondary mt-3">
        For the full server-side scan (including prefix overlap with this install's address space),
        invoke <code className="font-mono">system_sdwan_federation_scan</code> via the MCP tool.
      </p>
    </div>
  );
};

function severityClass(s: SdwanFederationFindingSeverity): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium uppercase';
  switch (s) {
    case 'critical': return `${base} bg-theme-danger text-theme-danger`;
    case 'high':     return `${base} bg-theme-warning text-theme-warning`;
    case 'medium':   return `${base} bg-theme-info text-theme-info`;
    default:         return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}
