import React, { useEffect, useState } from 'react';
import { Target } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import {
  fleetApi,
  type RemediationOutcomesSummary,
} from '@system/features/system/services/api/fleetApi';

// IMP-01a05ae8 — whether the fleet's autonomous remediations actually clear
// their signals, and which fingerprints the DecisionEngine has given up on.
// Backed by GET /system/fleet/remediation_outcomes (RemediationOutcome rows).
const POLL_INTERVAL_MS = 60_000;
const WINDOW_DAYS = 7;
const KIND_ROWS = 5;
const STUCK_ROWS = 3;

function formatRate(rate: number | null): string {
  return rate === null ? '—' : `${Math.round(rate * 100)}%`;
}

export const RemediationEffectivenessTile: React.FC = () => {
  const [data, setData] = useState<RemediationOutcomesSummary | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    const fetchOnce = async () => {
      try {
        const res = await fleetApi.remediationOutcomes(WINDOW_DAYS);
        if (cancelled) return;
        setData(res);
        setError(null);
      } catch {
        if (!cancelled) setError('Failed to load remediation outcomes');
      } finally {
        if (!cancelled) setLoading(false);
      }
    };

    void fetchOnce();
    const interval = window.setInterval(fetchOnce, POLL_INTERVAL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, []);

  const stuck = data?.stuck.fingerprints ?? [];
  const kinds = [...(data?.kinds ?? [])].sort((a, b) => b.settled - a.settled).slice(0, KIND_ROWS);

  return (
    <div className="rounded-xl border border-theme bg-theme-surface p-4">
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          <Target className="h-4 w-4 text-theme-tertiary" />
          <h4 className="text-sm font-semibold text-theme-text-primary">Remediation effectiveness</h4>
        </div>
        <Badge variant={stuck.length > 0 ? 'danger' : 'default'}>{`${WINDOW_DAYS}d window`}</Badge>
      </div>

      {loading ? (
        <div className="text-xs text-theme-tertiary italic">Loading outcomes...</div>
      ) : error ? (
        <div className="text-xs text-theme-error-fg">{error}</div>
      ) : data ? (
        <>
          <div className="text-xs text-theme-tertiary mb-2">
            {data.totals.settled > 0 ? (
              <>
                Effective:{' '}
                <span className="text-theme-text-primary font-semibold">
                  {formatRate(data.totals.effectiveness_rate)}
                </span>{' '}
                of {data.totals.settled} settled
              </>
            ) : (
              'No settled remediations in this window'
            )}
          </div>

          <div className="grid grid-cols-4 gap-2 mb-3">
            {(['effective', 'ineffective', 'pending', 'inconclusive'] as const).map((status) => (
              <div key={status} className="rounded-md bg-theme-surface-hover p-2 text-center">
                <div className="text-[10px] uppercase tracking-wider text-theme-tertiary">{status}</div>
                <div className="text-lg font-semibold text-theme-text-primary mt-1">{data.totals[status]}</div>
              </div>
            ))}
          </div>

          {kinds.length > 0 && (
            <ul className="mb-3 space-y-1">
              {kinds.map((kind) => (
                <li key={kind.signal_kind} className="flex justify-between text-xs">
                  <span className="text-theme-text-primary truncate" title={kind.signal_kind}>
                    {kind.signal_kind}
                  </span>
                  <span className="text-theme-tertiary">
                    {formatRate(kind.effectiveness_rate)} · {kind.settled} settled
                  </span>
                </li>
              ))}
            </ul>
          )}

          {stuck.length > 0 ? (
            <div className="text-xs">
              <div className="text-theme-error-fg font-semibold mb-1">
                {stuck.length} stuck ({data.stuck.threshold}+ ineffective in a row)
              </div>
              <ul className="space-y-0.5">
                {stuck.slice(0, STUCK_ROWS).map((s) => (
                  <li key={s.fingerprint} className="text-theme-tertiary truncate" title={s.fingerprint}>
                    {s.fingerprint} · {s.streak}×
                  </li>
                ))}
              </ul>
            </div>
          ) : (
            <div className="text-xs text-theme-tertiary">No stuck remediations</div>
          )}
        </>
      ) : null}
    </div>
  );
};
