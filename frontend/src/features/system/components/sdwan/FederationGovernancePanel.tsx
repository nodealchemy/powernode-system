import React, { useState } from 'react';
import { ShieldAlert, RefreshCw } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { sdwanApi } from '../../services/api/sdwanApi';
import type {
  SdwanFederationFinding,
  SdwanFederationFindingSeverity,
} from '../../types/sdwan.types';

/**
 * FederationGovernancePanel — runs the federation governance scan and renders
 * its findings. The scan is the server's
 * (GET /system/sdwan/federation_governance/scan →
 * Sdwan::FederationGovernance.scan), which is the same scanner behind the MCP
 * tool system_sdwan_federation_scan — so an operator and an agent see exactly
 * the same findings.
 *
 * This panel used to re-implement two of the scanner's finding kinds in
 * TypeScript and could not produce the other eleven (prefix overlap needs the
 * server's Sdwan::Configuration; the platform-peer and migration-chain checks
 * need rows the console never fetches), so it reported "no findings" on
 * accounts with critical ones. Fixed in IMP-65f479ad8484.
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

  React.useEffect(() => { run(); }, [refreshKey]);

  return (
    <div className="border border-theme rounded p-4">
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          <ShieldAlert size={18} className="text-theme-info-fg" />
          <h3 className="font-medium text-theme-primary">Governance scan</h3>
        </div>
        <Button variant="secondary" onClick={run} disabled={running}>
          <RefreshCw size={14} className={running ? 'animate-spin' : ''} />
          <span className="ml-1">{running ? 'Scanning…' : 'Re-scan'}</span>
        </Button>
      </div>

      {error && <div className="p-2 bg-theme-danger-bg text-theme-danger-fg rounded text-sm">{error}</div>}

      {findings === null ? (
        <div className="text-sm text-theme-secondary">Click "Re-scan" to run governance checks.</div>
      ) : findings.length === 0 ? (
        <div className="p-3 bg-theme-success-bg text-theme-success-fg rounded text-sm">
          No governance findings. Federation peers look healthy.
        </div>
      ) : (
        <ul className="space-y-2">
          {findings.map((f, i) => (
            <li key={`${f.federation_peer_id}-${f.kind}-${i}`} className="p-3 border border-theme rounded">
              <div className="flex items-center gap-2 mb-1">
                <span className={severityClass(f.severity)}>{f.severity}</span>
                <span className="text-xs text-theme-secondary font-mono">{f.kind}</span>
              </div>
              <p className="text-sm text-theme-primary">{f.message}</p>
              {f.federation_peer_id && (
                <p className="text-xs text-theme-secondary mt-1 font-mono">peer: {f.federation_peer_id}</p>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
};

function severityClass(s: SdwanFederationFindingSeverity): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium uppercase';
  switch (s) {
    case 'critical': return `${base} bg-theme-danger-bg text-theme-danger-fg`;
    case 'high':     return `${base} bg-theme-warning-bg text-theme-warning-fg`;
    case 'medium':   return `${base} bg-theme-info-bg text-theme-info-fg`;
    default:         return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}
