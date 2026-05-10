import React, { useEffect, useState, useCallback, useMemo } from 'react';
import { Activity, ArrowRight } from 'lucide-react';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type {
  SdwanFlowSample,
  SdwanIpfixCollector,
} from '@system/features/system/types/sdwan.types';

// Phase O6 follow-up — read-only operator view of ingested IPFIX flow
// records. Distributed-sidecar architecture: operator runs vector or
// fluent-bit per-host (or centrally) to parse OVS IPFIX exports and
// POST batched JSON to the platform's ingest endpoint. This tab
// surfaces the resulting Sdwan::FlowSample rows so operators can
// verify ingestion is working + spot-check flow patterns.
//
// The tab fetches the account's IPFIX collectors first, then fetches
// recent flows for the operator-selected collector. Default selection
// is the winning collector (the one the topology compiler will pick),
// because that's the row whose flows operators most often want to see.
const SINCE_OPTIONS: { label: string; minutes: number }[] = [
  { label: 'Last 5 min', minutes: 5 },
  { label: 'Last 1 hour', minutes: 60 },
  { label: 'Last 6 hours', minutes: 360 },
  { label: 'Last 24 hours', minutes: 1440 },
];

const PROTOCOL_OPTIONS: { label: string; value: number | undefined }[] = [
  { label: 'All protocols', value: undefined },
  { label: 'TCP', value: 6 },
  { label: 'UDP', value: 17 },
  { label: 'ICMP', value: 1 },
  { label: 'ICMPv6', value: 58 },
];

export const FlowSamplesTab: React.FC = () => {
  const [collectors, setCollectors] = useState<SdwanIpfixCollector[]>([]);
  const [collectorsLoading, setCollectorsLoading] = useState(true);
  const [selectedCollectorId, setSelectedCollectorId] = useState<string | null>(null);
  const [sinceMinutes, setSinceMinutes] = useState<number>(60);
  const [protocol, setProtocol] = useState<number | undefined>(undefined);

  const [samples, setSamples] = useState<SdwanFlowSample[]>([]);
  const [samplesLoading, setSamplesLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Load collectors once on mount; default-select the winning collector
  // (or the first one) so the operator sees flows immediately rather
  // than having to pick from the dropdown.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        setCollectorsLoading(true);
        const result = await sdwanApi.getIpfixCollectors();
        if (cancelled) return;
        setCollectors(result);
        const winning = result.find((c) => c.is_winning_collector);
        setSelectedCollectorId(winning?.id ?? result[0]?.id ?? null);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : 'Failed to load collectors');
      } finally {
        if (!cancelled) setCollectorsLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const sinceIso = useMemo(() => {
    return new Date(Date.now() - sinceMinutes * 60_000).toISOString();
  }, [sinceMinutes]);

  const loadSamples = useCallback(async () => {
    if (!selectedCollectorId) return;
    try {
      setSamplesLoading(true);
      setError(null);
      const result = await sdwanApi.getFlowSamples(selectedCollectorId, {
        since: sinceIso,
        protocol,
        limit: 200,
      });
      setSamples(result.samples);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load flow samples');
    } finally {
      setSamplesLoading(false);
    }
  }, [selectedCollectorId, sinceIso, protocol]);

  useEffect(() => {
    loadSamples();
  }, [loadSamples]);

  if (collectorsLoading) {
    return <div className="p-8 text-center text-theme-secondary">Loading collectors…</div>;
  }
  if (collectors.length === 0) {
    return (
      <div className="p-12 text-center">
        <Activity className="mx-auto mb-4 text-theme-secondary" size={48} />
        <h3 className="text-lg font-medium text-theme-primary mb-2">No IPFIX collectors yet</h3>
        <p className="text-theme-secondary">
          Register an IPFIX collector first (use the IPFIX tab or the SDWAN IPFIX
          Collector Compose skill). Then point a vector or fluent-bit sidecar at the
          platform&apos;s ingest endpoint to start receiving flows.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        <FilterField label="Collector">
          <select
            className="bg-theme-surface border border-theme rounded px-2 py-1 text-sm text-theme-primary"
            value={selectedCollectorId ?? ''}
            onChange={(e) => setSelectedCollectorId(e.target.value || null)}
          >
            {collectors.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name} {c.is_winning_collector ? '(winning)' : ''}
              </option>
            ))}
          </select>
        </FilterField>

        <FilterField label="Time range">
          <select
            className="bg-theme-surface border border-theme rounded px-2 py-1 text-sm text-theme-primary"
            value={sinceMinutes}
            onChange={(e) => setSinceMinutes(parseInt(e.target.value, 10))}
          >
            {SINCE_OPTIONS.map((o) => (
              <option key={o.minutes} value={o.minutes}>{o.label}</option>
            ))}
          </select>
        </FilterField>

        <FilterField label="Protocol">
          <select
            className="bg-theme-surface border border-theme rounded px-2 py-1 text-sm text-theme-primary"
            value={protocol ?? ''}
            onChange={(e) => setProtocol(e.target.value ? parseInt(e.target.value, 10) : undefined)}
          >
            {PROTOCOL_OPTIONS.map((o) => (
              <option key={o.label} value={o.value ?? ''}>{o.label}</option>
            ))}
          </select>
        </FilterField>

        <button
          type="button"
          onClick={loadSamples}
          disabled={samplesLoading}
          className="ml-auto px-3 py-1.5 rounded text-sm bg-theme-accent text-theme-on-accent hover:opacity-90 disabled:opacity-50"
        >
          {samplesLoading ? 'Refreshing…' : 'Refresh'}
        </button>
      </div>

      {error && (
        <div className="p-4 bg-theme-danger text-theme-danger rounded">{error}</div>
      )}

      {samplesLoading && samples.length === 0 ? (
        <div className="p-8 text-center text-theme-secondary">Loading flow samples…</div>
      ) : samples.length === 0 ? (
        <div className="p-12 text-center">
          <Activity className="mx-auto mb-4 text-theme-secondary" size={48} />
          <h3 className="text-lg font-medium text-theme-primary mb-2">No flow samples in this range</h3>
          <p className="text-theme-secondary">
            Either no traffic was sampled in the selected time range, or the sidecar
            collector hasn&apos;t POSTed any records yet. Verify the sidecar is running
            and pointing at <code className="text-xs">/api/v1/system/sdwan/ipfix_collectors/{selectedCollectorId}/flow_samples</code>.
          </p>
        </div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-theme-background-secondary text-theme-secondary">
              <tr>
                <th className="text-left p-3">Source</th>
                <th className="text-left p-3"></th>
                <th className="text-left p-3">Destination</th>
                <th className="text-left p-3">Protocol</th>
                <th className="text-right p-3">Bytes</th>
                <th className="text-right p-3">Packets</th>
                <th className="text-left p-3">Observed</th>
              </tr>
            </thead>
            <tbody>
              {samples.map((s) => (
                <tr key={s.id} className="border-b border-theme-border">
                  <td className="p-3 font-mono text-xs text-theme-primary">
                    {s.src_ip}{s.src_port != null ? `:${s.src_port}` : ''}
                  </td>
                  <td className="p-3 text-theme-secondary">
                    <ArrowRight size={14} />
                  </td>
                  <td className="p-3 font-mono text-xs text-theme-primary">
                    {s.dst_ip}{s.dst_port != null ? `:${s.dst_port}` : ''}
                  </td>
                  <td className="p-3">
                    <span className={protocolBadgeClass(s.protocol_label)}>{s.protocol_label}</span>
                  </td>
                  <td className="p-3 text-right text-theme-secondary">
                    {formatBytes(s.octet_count)}
                  </td>
                  <td className="p-3 text-right text-theme-secondary">
                    {s.packet_count.toLocaleString()}
                  </td>
                  <td className="p-3 text-xs text-theme-secondary">
                    {new Date(s.observed_at).toLocaleString()}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="text-xs text-theme-secondary mt-2 text-right">
            Showing {samples.length} sample{samples.length === 1 ? '' : 's'} (limit 200).
          </div>
        </div>
      )}
    </div>
  );
};

interface FilterFieldProps {
  label: string;
  children: React.ReactNode;
}

const FilterField: React.FC<FilterFieldProps> = ({ label, children }) => (
  <div className="flex flex-col gap-1">
    <label className="text-xs text-theme-secondary uppercase tracking-wide">{label}</label>
    {children}
  </div>
);

function protocolBadgeClass(label: string): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  switch (label) {
    case 'tcp':
      return `${base} bg-theme-info text-theme-info`;
    case 'udp':
      return `${base} bg-theme-success text-theme-success`;
    case 'icmp':
    case 'icmpv6':
      return `${base} bg-theme-warning text-theme-warning`;
    default:
      return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}
