import React, { useEffect, useState } from 'react';
import { ShieldAlert, Shield } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { fleetApi, type FleetEvent } from '@system/features/system/services/api/fleetApi';

// Honeypot canary status tile for the operator dashboard (Track F-6).
// Polls recent FleetEvents tagged `system.honeypot_triggered` and shows
// counts. Designed to be embedded into FleetDashboardPage's counters
// strip or the SystemOverview page.
export const HoneypotCanaryTile: React.FC = () => {
  const [accessEvents, setAccessEvents] = useState<FleetEvent[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const result = await fleetApi.recentSignals({ kind: 'system.honeypot_triggered', limit: 100 });
        if (!cancelled) setAccessEvents(result.events);
      } catch {
        if (!cancelled) setAccessEvents([]);
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  const last7d = accessEvents.filter((e) => {
    const t = new Date(e.emitted_at).getTime();
    return Date.now() - t <= 7 * 24 * 60 * 60 * 1000;
  });
  const last24h = accessEvents.filter((e) => {
    const t = new Date(e.emitted_at).getTime();
    return Date.now() - t <= 24 * 60 * 60 * 1000;
  });

  const tone = last24h.length > 0 ? 'border-theme-error' : last7d.length > 0 ? 'border-theme-warning' : 'border-theme';

  return (
    <div className={`bg-theme-surface rounded-lg border ${tone} p-3`}>
      <div className="flex items-center justify-between text-xs">
        <div className="flex items-center gap-1 text-theme-tertiary">
          {last24h.length > 0 ? <ShieldAlert size={14} className="text-theme-error" /> : <Shield size={14} />}
          Honeypot Canaries
        </div>
        {last24h.length > 0 && <Badge variant="danger">ALERT</Badge>}
      </div>
      <div className="mt-1">
        {loading ? (
          <span className="text-sm text-theme-tertiary">Loading…</span>
        ) : (
          <div className="flex items-baseline gap-3">
            <div>
              <div className="text-2xl font-semibold">{last24h.length}</div>
              <div className="text-xs text-theme-tertiary">last 24h</div>
            </div>
            <div>
              <div className="text-base text-theme-tertiary">{last7d.length}</div>
              <div className="text-xs text-theme-tertiary">last 7d</div>
            </div>
          </div>
        )}
      </div>
      {last24h.length > 0 && (
        <div className="mt-2 text-xs text-theme-error">
          Last access: {accessEvents[0] && new Date(accessEvents[0].emitted_at).toLocaleString()}
        </div>
      )}
    </div>
  );
};

export default HoneypotCanaryTile;
