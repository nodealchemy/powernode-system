import React, { useEffect, useState } from 'react';
import { Activity } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { metricsApi, type DispatchMetricsResponse } from '@system/features/system/services/api/metricsApi';

// Phase 10.7 polish — renders aggregated counters for the dispatch
// pipeline (claimed/started/completed/failed) and fleet event rate over
// a 5min window. Backed by Phase 10.5's Metrics::Aggregator endpoint.
//
// Design: counter-only (no histograms in v1). p50/p95/p99 latency requires
// a v2 storage shift to ZSET — see Phase 10.5 plan footnote.
const POLL_INTERVAL_MS = 30_000;
const WINDOW_SECONDS = 300;

const TRACKED: Array<{ key: string; label: string }> = [
  { key: 'system.dispatch.claimed', label: 'Claimed' },
  { key: 'system.dispatch.started', label: 'Started' },
  { key: 'system.dispatch.completed', label: 'Completed' },
  { key: 'system.dispatch.failed', label: 'Failed' },
  { key: 'system.fleet.event', label: 'Fleet events' },
];

function formatRate(rate: number): string {
  if (rate <= 0) return '0/s';
  if (rate < 0.1) return `${(rate * 60).toFixed(1)}/min`;
  return `${rate.toFixed(2)}/s`;
}

export const DispatchLatencyTile: React.FC = () => {
  const [data, setData] = useState<DispatchMetricsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    const fetchOnce = async () => {
      try {
        const res = await metricsApi.dispatch({ window: WINDOW_SECONDS });
        if (cancelled) return;
        setData(res);
        setError(null);
      } catch {
        if (!cancelled) setError('Failed to load dispatch metrics');
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

  const failureRate = data?.metrics['system.dispatch.failed']?.rate_per_sec ?? 0;
  const completedRate = data?.metrics['system.dispatch.completed']?.rate_per_sec ?? 0;
  const failurePercent =
    completedRate + failureRate > 0
      ? (failureRate / (completedRate + failureRate)) * 100
      : 0;

  return (
    <div className="rounded-xl border border-theme-border-default bg-theme-bg-card p-4">
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          <Activity className="h-4 w-4 text-theme-text-muted" />
          <h4 className="text-sm font-semibold text-theme-text-primary">Dispatch pipeline</h4>
        </div>
        <Badge variant={failurePercent > 5 ? 'danger' : 'default'}>
          {`${WINDOW_SECONDS / 60}m window`}
        </Badge>
      </div>

      {loading ? (
        <div className="text-xs text-theme-text-muted italic">Loading metrics...</div>
      ) : error ? (
        <div className="text-xs text-theme-error">{error}</div>
      ) : data ? (
        <>
          <div className="grid grid-cols-5 gap-2 mb-3">
            {TRACKED.map(({ key, label }) => {
              const stat = data.metrics[key];
              const count = stat?.count ?? 0;
              const rate = stat?.rate_per_sec ?? 0;
              return (
                <div key={key} className="rounded-md bg-theme-bg-hover p-2 text-center">
                  <div className="text-[10px] uppercase tracking-wider text-theme-text-muted">
                    {label}
                  </div>
                  <div className="text-lg font-semibold text-theme-text-primary mt-1">{count}</div>
                  <div className="text-[10px] text-theme-text-muted">{formatRate(rate)}</div>
                </div>
              );
            })}
          </div>
          {completedRate + failureRate > 0 && (
            <div className="text-xs text-theme-text-muted">
              Failure rate:{' '}
              <span className={failurePercent > 5 ? 'text-theme-error' : 'text-theme-text-primary'}>
                {failurePercent.toFixed(2)}%
              </span>
            </div>
          )}
        </>
      ) : null}
    </div>
  );
};
