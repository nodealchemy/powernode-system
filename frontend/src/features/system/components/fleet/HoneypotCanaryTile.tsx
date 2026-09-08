import React, { useCallback, useEffect, useState } from 'react';
import { ShieldAlert, Shield, ShieldQuestion, RefreshCw } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { logger } from '@/shared/utils/logger';
import { fleetApi, type FleetEvent } from '@system/features/system/services/api/fleetApi';

// Honeypot canary status tile for the operator dashboard (Track F-6).
// Polls recent FleetEvents tagged `system.honeypot_triggered` and shows
// counts. Designed to be embedded into FleetDashboardPage's counters
// strip or the SystemOverview page.
//
// A failed fetch renders its own state and NEVER the counts (IMP-a133d32b7e4e).
// This is a security canary: a swallowed error that falls back to zero says
// "no honeypot hits" when the truth is "we could not ask", and those two are
// the states an operator most needs to tell apart.
export const HoneypotCanaryTile: React.FC = () => {
  const [accessEvents, setAccessEvents] = useState<FleetEvent[]>([]);
  const [loading, setLoading] = useState(true);
  const [unavailable, setUnavailable] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);

  const retry = useCallback(() => setReloadKey((k) => k + 1), []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const result = await fleetApi.recentSignals({ kind: 'system.honeypot_triggered', limit: 100 });
        if (cancelled) return;
        // A 200 is not proof of a usable payload: extractData falls back to the
        // raw body, so a `{success:false, error:…}` or trimmed response yields
        // no `events`. Left unchecked that reaches the render as
        // `undefined.filter(...)`, which throws and takes the whole tile off
        // the dashboard — a canary that has vanished reads as "all clear" even
        // more completely than a zero does. Route it to the catch instead.
        if (!Array.isArray(result?.events)) {
          throw new Error('malformed signals payload: events is not an array');
        }
        setAccessEvents(result.events);
        setUnavailable(false);
      } catch (err) {
        if (cancelled) return;
        // Drop any stale counts with the failure — showing the previous
        // window's numbers beside an "unavailable" notice invites the same
        // misreading in a subtler form.
        setAccessEvents([]);
        setUnavailable(true);
        logger.warn('Honeypot canary signal fetch failed', {
          kind: 'system.honeypot_triggered',
          error: err instanceof Error ? err.message : String(err),
        });
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [reloadKey]);

  const last7d = accessEvents.filter((e) => {
    const t = new Date(e.emitted_at).getTime();
    return Date.now() - t <= 7 * 24 * 60 * 60 * 1000;
  });
  const last24h = accessEvents.filter((e) => {
    const t = new Date(e.emitted_at).getTime();
    return Date.now() - t <= 24 * 60 * 60 * 1000;
  });

  const alerting = !unavailable && last24h.length > 0;
  const tone = unavailable
    ? 'border-theme-warning-border'
    : last24h.length > 0
      ? 'border-theme-error-border'
      : last7d.length > 0
        ? 'border-theme-warning-border'
        : 'border-theme';

  const icon = unavailable ? (
    <ShieldQuestion size={14} className="text-theme-warning-fg" />
  ) : alerting ? (
    <ShieldAlert size={14} className="text-theme-error-fg" />
  ) : (
    <Shield size={14} />
  );

  return (
    <div className={`bg-theme-surface rounded-lg border ${tone} p-3`}>
      <div className="flex items-center justify-between text-xs">
        <div className="flex items-center gap-1 text-theme-tertiary">
          {icon}
          Honeypot Canaries
        </div>
        {alerting && <Badge variant="danger">ALERT</Badge>}
      </div>
      <div className="mt-1">
        {/* `unavailable` is checked BEFORE `loading` so a retry in flight keeps
            the explanation and the button on screen. Letting the loading branch
            win would blank both for the length of the request — exactly when an
            operator arriving mid-retry needs to know the feed is down. */}
        {unavailable ? (
          <div className="flex items-center justify-between gap-2">
            <div className="text-sm text-theme-warning-fg">
              Signal feed unavailable
              <div className="text-xs text-theme-tertiary">
                Honeypot status is unknown, not clear.
              </div>
            </div>
            <Button variant="ghost" size="xs" loading={loading} onClick={retry}>
              <RefreshCw size={12} /> Retry
            </Button>
          </div>
        ) : loading ? (
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
      {alerting && (
        <div className="mt-2 text-xs text-theme-error-fg">
          Last access: {accessEvents[0] && new Date(accessEvents[0].emitted_at).toLocaleString()}
        </div>
      )}
    </div>
  );
};

export default HoneypotCanaryTile;
