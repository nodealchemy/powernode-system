import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Activity, AlertTriangle, Clock, Cpu, GitBranch } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { wsManager } from '@/shared/services/WebSocketManager';
import { useAuth } from '@/shared/hooks/useAuth';
import { fleetApi, type FleetEvent } from '@system/features/system/services/api/fleetApi';
import { HoneypotCanaryTile } from './HoneypotCanaryTile';
import { AttributionFeedbackButton } from './AttributionFeedbackButton';

// Fleet Dashboard (Golden Eclipse plan M-FE-3).
//
// Three panels:
//   - Top: counters (signal rate, decisions/min, instances, modules)
//   - Middle: live event feed (subscribes to SystemFleetChannel)
//   - Bottom-left: pending decisions queue
//   - Bottom-right: correlation chain viewer (click an event → see its tick)
//
// Live updates land via wsManager.subscribe('SystemFleetChannel'). Initial
// backlog comes from POST /system/fleet/signals so the operator sees
// recent state on page load before live events start arriving.
const MAX_EVENT_BUFFER = 200;

export function FleetDashboardPage(): JSX.Element {
  const { showNotification } = useNotifications();
  const { currentUser } = useAuth();
  const accountId = (currentUser as { account?: { id?: string } } | null)?.account?.id;

  const [events, setEvents] = useState<FleetEvent[]>([]);
  const [loading, setLoading] = useState(false);
  const [filterKind, setFilterKind] = useState<string>('');
  const [selectedCorrelation, setSelectedCorrelation] = useState<string | null>(null);

  // Initial backlog
  const refreshBacklog = useCallback(async () => {
    if (!accountId) return;
    setLoading(true);
    try {
      const result = await fleetApi.recentSignals({ limit: 100, kind: filterKind || undefined });
      setEvents(result.events);
    } catch (err) {
      showNotification({ type: 'error', message: 'Failed to load fleet events' });
    } finally {
      setLoading(false);
    }
  }, [accountId, filterKind, showNotification]);

  useEffect(() => {
    void refreshBacklog();
  }, [refreshBacklog]);

  // Live subscription to SystemFleetChannel — pushes new events to the head of the buffer.
  useEffect(() => {
    if (!accountId) return;

    const unsubscribe = wsManager.subscribe({
      channel: 'SystemFleetChannel',
      params: { account_id: accountId },
      onMessage: (data: unknown) => {
        const message = data as Partial<FleetEvent> & { type?: string };
        if (!message || message.type === 'connection_established' || message.type === 'pong') return;
        // Channel sends a single event payload as the object itself
        if (message.id && message.kind && message.severity) {
          setEvents((prev) => [message as FleetEvent, ...prev].slice(0, MAX_EVENT_BUFFER));
        }
      },
      onError: (err: string) => {
        showNotification({ type: 'warning', message: `Fleet channel error: ${err}` });
      }
    });

    return () => {
      unsubscribe();
    };
  }, [accountId, showNotification]);

  // Counters derived from buffer + a short-window rate
  const counters = useMemo(() => {
    const last5min = events.filter((e) => {
      const t = new Date(e.emitted_at).getTime();
      return Date.now() - t <= 5 * 60 * 1000;
    });
    const decisions = last5min.filter((e) => e.kind.startsWith('decision.'));
    const signals = last5min.filter((e) => e.kind.startsWith('system.'));
    const critical = last5min.filter((e) => e.severity === 'critical' || e.severity === 'high');
    return {
      signalsPer5min: signals.length,
      decisionsPer5min: decisions.length,
      criticalPer5min: critical.length,
      bufferSize: events.length
    };
  }, [events]);

  const filteredEvents = useMemo(() => {
    if (!filterKind) return events;
    return events.filter((e) => e.kind.includes(filterKind));
  }, [events, filterKind]);

  const correlationEvents = useMemo(() => {
    if (!selectedCorrelation) return [];
    return events
      .filter((e) => e.correlation_id === selectedCorrelation)
      .sort((a, b) => a.emitted_at.localeCompare(b.emitted_at));
  }, [events, selectedCorrelation]);

  return (
    <div className="flex flex-col h-full bg-theme-background text-theme-foreground">
      <header className="px-6 py-4 border-b border-theme-border flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">Fleet Dashboard</h1>
          <p className="text-sm text-theme-muted mt-1">
            Live observability of FleetAutonomyService — signals, decisions, ticks.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <input
            type="text"
            value={filterKind}
            onChange={(e) => setFilterKind(e.target.value)}
            placeholder="Filter kind…"
            className="px-3 py-1.5 text-sm rounded border border-theme-border bg-theme-background"
          />
          <Button size="sm" variant="secondary" onClick={refreshBacklog} disabled={loading}>
            Refresh
          </Button>
        </div>
      </header>

      <div className="grid grid-cols-1 md:grid-cols-5 gap-3 p-4">
        <Counter icon={<Activity size={16} />} label="Signals (5m)" value={counters.signalsPer5min} />
        <Counter icon={<GitBranch size={16} />} label="Decisions (5m)" value={counters.decisionsPer5min} />
        <Counter icon={<AlertTriangle size={16} />} label="High/Critical (5m)" value={counters.criticalPer5min} highlight={counters.criticalPer5min > 0} />
        <Counter icon={<Cpu size={16} />} label="Buffer" value={`${counters.bufferSize}/${MAX_EVENT_BUFFER}`} />
        {/* Track F-6 honeypot canary status — alerts on any access in last 24h. */}
        <HoneypotCanaryTile />
      </div>

      <div className="flex-1 grid grid-cols-1 md:grid-cols-3 gap-4 p-4 overflow-hidden">
        <section className="md:col-span-2 flex flex-col bg-theme-surface rounded-lg border border-theme-border overflow-hidden">
          <div className="px-4 py-2 border-b border-theme-border flex items-center justify-between">
            <h2 className="font-medium">Live Event Feed</h2>
            <span className="text-xs text-theme-muted">{filteredEvents.length} events</span>
          </div>
          <div className="flex-1 overflow-y-auto">
            {filteredEvents.length === 0 ? (
              <p className="p-4 text-sm text-theme-muted">No events yet.</p>
            ) : (
              <ul className="divide-y divide-theme-border text-sm">
                {filteredEvents.map((e) => (
                  <li
                    key={e.id}
                    className="px-4 py-2 hover:bg-theme-hover cursor-pointer"
                    onClick={() => setSelectedCorrelation(e.correlation_id)}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <div className="font-mono text-xs flex-1 truncate">{e.kind}</div>
                      <SeverityBadge severity={e.severity} />
                      <span className="text-xs text-theme-muted">
                        {new Date(e.emitted_at).toLocaleTimeString()}
                      </span>
                    </div>
                    {e.source && (
                      <div className="text-xs text-theme-muted mt-0.5">source: {e.source}</div>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </div>
        </section>

        <section className="flex flex-col bg-theme-surface rounded-lg border border-theme-border overflow-hidden">
          <div className="px-4 py-2 border-b border-theme-border flex items-center gap-2">
            <Clock size={14} />
            <h2 className="font-medium">Correlation Chain</h2>
          </div>
          <div className="flex-1 overflow-y-auto">
            {!selectedCorrelation ? (
              <p className="p-4 text-sm text-theme-muted">Click an event to view its tick chain.</p>
            ) : correlationEvents.length === 0 ? (
              <p className="p-4 text-sm text-theme-muted">No matching events in the buffer.</p>
            ) : (
              <ul className="divide-y divide-theme-border text-sm">
                {correlationEvents.map((e) => (
                  <li key={e.id} className="px-4 py-2 space-y-1">
                    <div className="font-mono text-xs">{e.kind}</div>
                    <div className="text-xs text-theme-muted">
                      {new Date(e.emitted_at).toLocaleTimeString()}
                    </div>
                    {/* Attribution feedback button surfaces when the event */}
                    {/* references a specific instance + module — operator can */}
                    {/* confirm/reject the autonomy's attribution and feed the */}
                    {/* learning loop. */}
                    {e.node_instance_id && e.node_module_id && (
                      <AttributionFeedbackButton
                        instanceId={e.node_instance_id}
                        candidateModuleId={e.node_module_id}
                        candidateKind="event_correlation"
                      />
                    )}
                  </li>
                ))}
              </ul>
            )}
          </div>
        </section>
      </div>
    </div>
  );
}

interface CounterProps {
  icon: React.ReactNode;
  label: string;
  value: number | string;
  highlight?: boolean;
}
function Counter({ icon, label, value, highlight }: CounterProps): JSX.Element {
  return (
    <div className={`bg-theme-surface rounded-lg border ${highlight ? 'border-theme-warning' : 'border-theme-border'} p-3`}>
      <div className="flex items-center justify-between">
        <div className="text-xs text-theme-muted flex items-center gap-1">
          {icon}
          {label}
        </div>
      </div>
      <div className="text-2xl font-semibold mt-1">{value}</div>
    </div>
  );
}

function SeverityBadge({ severity }: { severity: FleetEvent['severity'] }): JSX.Element {
  const variant = severity === 'critical' || severity === 'high' ? 'error' : severity === 'medium' ? 'warning' : 'default';
  return <Badge variant={variant}>{severity}</Badge>;
}

export default FleetDashboardPage;
