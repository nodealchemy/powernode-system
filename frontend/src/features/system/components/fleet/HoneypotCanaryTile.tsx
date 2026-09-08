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
/**
 * Severity ladder, worst last. Kept as a rank rather than a tone string so an
 * outage can be compared against the last known reading — the comparison is the
 * whole point of IMP-b80f2bc38419 and a class name cannot be ordered.
 */
type Severity = 0 | 1 | 2; // 0 clear, 1 warn, 2 alert

/** What the last SUCCESSFUL fetch observed. Survives a feed outage. */
interface LastKnown {
  severity: Severity;
  lastAccessAt: string | null;
}

export const HoneypotCanaryTile: React.FC = () => {
  const [accessEvents, setAccessEvents] = useState<FleetEvent[]>([]);
  const [loading, setLoading] = useState(true);
  const [unavailable, setUnavailable] = useState(false);
  const [unavailableSince, setUnavailableSince] = useState<Date | null>(null);
  const [lastKnown, setLastKnown] = useState<LastKnown | null>(null);
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
        setUnavailableSince(null);
        // Snapshot the severity this reading established. A later outage keeps
        // it rather than repainting the tile amber — see the render below.
        const now = Date.now();
        const within = (e: FleetEvent, ms: number) =>
          now - new Date(e.emitted_at).getTime() <= ms;
        const fresh24h = result.events.filter((e) => within(e, 24 * 60 * 60 * 1000));
        const fresh7d = result.events.filter((e) => within(e, 7 * 24 * 60 * 60 * 1000));
        setLastKnown({
          severity: fresh24h.length > 0 ? 2 : fresh7d.length > 0 ? 1 : 0,
          lastAccessAt: result.events[0]?.emitted_at ?? null,
        });
      } catch (err) {
        if (cancelled) return;
        // Drop any stale counts with the failure — showing the previous
        // window's numbers beside an "unavailable" notice invites the same
        // misreading in a subtler form.
        setAccessEvents([]);
        setUnavailable(true);
        // Stamp the START of the outage, not this retry: an operator needs to
        // know how long the canary has been blind, and a failing retry every
        // few seconds would otherwise keep resetting the clock to "just now".
        // `lastKnown` is deliberately NOT cleared here.
        setUnavailableSince((since) => since ?? new Date());
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

  const observed: Severity = last24h.length > 0 ? 2 : last7d.length > 0 ? 1 : 0;

  // A feed outage may RAISE the severity to "unknown" (amber beats a neutral
  // all-clear) but must never LOWER one already observed. Downgrading a red
  // tile to amber because the endpoint dropped makes a live intrusion less
  // conspicuous than it was a second earlier, which is the same defect class
  // IMP-a133d32b7e4e removed — a failure making the fleet look better than it
  // is — one rung down rather than gone. Note this is a different question
  // from whether to show the COUNTS during an outage: a stale number invites a
  // fresh reading and is still withheld below.
  const severity: Severity = unavailable
    ? (Math.max(lastKnown?.severity ?? 0, 1) as Severity)
    : observed;

  const alerting = severity === 2;
  const tone =
    severity === 2
      ? 'border-theme-error-border'
      : severity === 1
        ? 'border-theme-warning-border'
        : 'border-theme';

  // Severity wins the icon unconditionally: during an alerting outage the alert
  // icon renders and the question mark does NOT, because the badge and tone are
  // what an operator scans a dashboard for. The outage is carried by the body
  // panel and the "since" stamp instead, not by the icon.
  const icon = alerting ? (
    <ShieldAlert size={14} className="text-theme-error-fg" />
  ) : unavailable ? (
    <ShieldQuestion size={14} className="text-theme-warning-fg" />
  ) : (
    <Shield size={14} />
  );

  // Prefer the live event; fall back to the snapshot taken before the outage.
  const lastAccessAt = accessEvents[0]?.emitted_at ?? lastKnown?.lastAccessAt ?? null;

  return (
    <div className={`bg-theme-surface rounded-lg border ${tone} p-3`}>
      <div className="flex items-center justify-between text-xs">
        <div className="flex items-center gap-1 text-theme-tertiary">
          {icon}
          Honeypot Canaries
        </div>
        <div className="flex items-center gap-1">
          {alerting && <Badge variant="danger">ALERT</Badge>}
          {/* Without a re-fetch while mounted, the alerting-to-unavailable
              transition this component now handles could never occur: the tile
              fetched once and its only reload was the Retry button, which the
              unavailable branch alone renders. Suppressed there so exactly one
              refresh control exists at a time. */}
          {!unavailable && (
            <Button
              variant="ghost"
              size="xs"
              loading={loading}
              onClick={retry}
              aria-label="Refresh honeypot canaries"
            >
              <RefreshCw size={12} />
            </Button>
          )}
        </div>
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
                {alerting
                  ? 'Showing the last known state; it may have worsened since.'
                  : 'Honeypot status is unknown, not clear.'}
              </div>
              {unavailableSince && (
                <div className="text-xs text-theme-tertiary">
                  Feed unavailable since {unavailableSince.toLocaleString()}
                </div>
              )}
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
      {alerting && lastAccessAt && (
        <div className="mt-2 text-xs text-theme-error-fg">
          Last access: {new Date(lastAccessAt).toLocaleString()}
        </div>
      )}
    </div>
  );
};

export default HoneypotCanaryTile;
