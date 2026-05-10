import React, { useEffect, useState, useCallback } from 'react';
import { Activity, CheckCircle } from 'lucide-react';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type {
  SdwanIpfixCollector,
  SdwanIpfixState,
} from '@system/features/system/types/sdwan.types';

// Phase O6 — read-only operator view of registered IPFIX collectors.
// Creation happens through the SDWAN IPFIX Collector Compose skill /
// system_sdwan_create_ipfix_collector MCP action.
//
// Each row carries an is_winning_collector flag — the topology compiler
// picks the account's oldest active collector when stamping the ipfix
// payload onto OVS bridges, so even with multiple collector rows only
// one wires up. The "Winning" badge surfaces this at a glance.
export const IpfixCollectorsTab: React.FC = () => {
  const [collectors, setCollectors] = useState<SdwanIpfixCollector[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const result = await sdwanApi.getIpfixCollectors();
      setCollectors(result);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load IPFIX collectors');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  if (loading) {
    return <div className="p-8 text-center text-theme-secondary">Loading IPFIX collectors…</div>;
  }
  if (error) {
    return <div className="p-4 bg-theme-danger text-theme-danger rounded">{error}</div>;
  }
  if (collectors.length === 0) {
    return (
      <div className="p-12 text-center">
        <Activity className="mx-auto mb-4 text-theme-secondary" size={48} />
        <h3 className="text-lg font-medium text-theme-primary mb-2">No IPFIX collectors yet</h3>
        <p className="text-theme-secondary">
          IPFIX is heavyweight-profile only — lightweight (Linux-bridge) hosts ignore the
          payload. Register a collector via the SDWAN IPFIX Collector Compose skill or
          the <code className="text-xs">system_sdwan_create_ipfix_collector</code> MCP action.
        </p>
      </div>
    );
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full">
        <thead className="bg-theme-background-secondary text-theme-secondary text-sm">
          <tr>
            <th className="text-left p-3">Name</th>
            <th className="text-left p-3">Target</th>
            <th className="text-left p-3">Sampling</th>
            <th className="text-left p-3">State</th>
            <th className="text-left p-3">Compiler picks</th>
          </tr>
        </thead>
        <tbody>
          {collectors.map((c) => (
            <tr key={c.id} className="border-b border-theme-border">
              <td className="p-3">
                <div className="flex items-center gap-2">
                  <Activity size={14} className="text-theme-accent" />
                  <span className="font-medium text-theme-primary">{c.name}</span>
                </div>
              </td>
              <td className="p-3 font-mono text-xs text-theme-secondary">{c.target_endpoint}</td>
              <td className="p-3 text-theme-secondary text-sm">
                1 in {c.sampling_rate}
              </td>
              <td className="p-3">
                <span className={stateBadgeClass(c.state)}>{c.state}</span>
              </td>
              <td className="p-3">
                {c.is_winning_collector ? (
                  <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-theme-success text-theme-success">
                    <CheckCircle size={12} /> Winning
                  </span>
                ) : (
                  <span className="text-xs text-theme-secondary">—</span>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
};

function stateBadgeClass(state: SdwanIpfixState): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  return state === 'active'
    ? `${base} bg-theme-success text-theme-success`
    : `${base} bg-theme-background-secondary text-theme-secondary`;
}
