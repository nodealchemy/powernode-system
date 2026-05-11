import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Activity, AlertTriangle, Clock, Cpu, GitBranch, Package, PlayCircle } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { wsManager } from '@/shared/services/WebSocketManager';
import { useAuth } from '@/shared/hooks/useAuth';
import { fleetApi, type FleetEvent } from '@system/features/system/services/api/fleetApi';
import { HoneypotCanaryTile } from './HoneypotCanaryTile';
import { DispatchLatencyTile } from './DispatchLatencyTile';
import { AttributionFeedbackButton } from './AttributionFeedbackButton';
import { BootReplayModal } from './boot-replay/BootReplayModal';

// Severity levels in increasing-urgency order. Used by the severity
// quick-filter chips below.
const SEVERITY_RANKS: Record<FleetEvent['severity'], number> = {
  low: 0, medium: 1, high: 2, critical: 3
};

// Common kind prefixes operators reach for. The kind input is still
// free-text (substring match), but these chips give one-click access
// to the most common drill-ins.
const QUICK_KIND_FILTERS: Array<{ label: string; match: string }> = [
  { label: 'All',                match: '' },
  { label: 'Module publish',     match: 'system.module_publish' },
  { label: 'Honeypot',           match: 'honeypot' },
  { label: 'Capacity / pressure', match: 'pressure' },
  { label: 'Decisions',          match: 'decision.' },
];

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

export function FleetDashboardPage(): React.JSX.Element {
  const { addNotification } = useNotifications();
  const { currentUser } = useAuth();
  const accountId = (currentUser as { account?: { id?: string } } | null)?.account?.id;

  const [events, setEvents] = useState<FleetEvent[]>([]);
  const [loading, setLoading] = useState(false);
  const [filterKind, setFilterKind] = useState<string>('');
  const [minSeverity, setMinSeverity] = useState<FleetEvent['severity'] | 'all'>('all');
  // Track the clicked event (full row) so the right pane can show
  // full payload + correlation chain. Previously we only stored
  // correlation_id, which left the pane empty when the clicked event
  // had no correlation_id (most common case) — clicking did nothing
  // visible.
  const [selectedEvent, setSelectedEvent] = useState<FleetEvent | null>(null);
  const selectedCorrelation = selectedEvent?.correlation_id ?? null;
  // Boot replay modal — opens with the selected event's NodeInstance +
  // (optional) correlation_id when the operator clicks "Boot Replay".
  // null instanceId keeps the modal closed.
  const [bootReplay, setBootReplay] = useState<{ instanceId: string; correlationId?: string } | null>(null);

  // Initial backlog
  const refreshBacklog = useCallback(async () => {
    if (!accountId) return;
    setLoading(true);
    try {
      const result = await fleetApi.recentSignals({ limit: 100, kind: filterKind || undefined });
      setEvents(result.events);
    } catch (err) {
      addNotification({ type: 'error', message: 'Failed to load fleet events' });
    } finally {
      setLoading(false);
    }
  }, [accountId, filterKind, addNotification]);

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
        addNotification({ type: 'warning', message: `Fleet channel error: ${err}` });
      }
    });

    return () => {
      unsubscribe();
    };
  }, [accountId, addNotification]);

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
    return events.filter((e) => {
      if (filterKind && !e.kind.includes(filterKind)) return false;
      if (minSeverity !== 'all') {
        const eventRank = SEVERITY_RANKS[e.severity] ?? 0;
        const minRank = SEVERITY_RANKS[minSeverity] ?? 0;
        if (eventRank < minRank) return false;
      }
      return true;
    });
  }, [events, filterKind, minSeverity]);

  const correlationEvents = useMemo(() => {
    if (!selectedCorrelation) return [];
    return events
      .filter((e) => e.correlation_id === selectedCorrelation)
      .sort((a, b) => a.emitted_at.localeCompare(b.emitted_at));
  }, [events, selectedCorrelation]);

  return (
    <div className="flex flex-col h-full bg-theme-background text-theme-foreground">
      <header className="px-6 py-4 border-b border-theme space-y-3">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-xl font-semibold">Fleet Dashboard</h1>
            <p className="text-sm text-theme-tertiary mt-1">
              Live observability of FleetAutonomyService — signals, decisions, ticks.
            </p>
          </div>
          <div className="flex items-center gap-2">
            <input
              type="text"
              value={filterKind}
              onChange={(e) => setFilterKind(e.target.value)}
              placeholder="Filter kind…"
              className="px-3 py-1.5 text-sm rounded border border-theme bg-theme-background"
            />
            <Button size="sm" variant="secondary" onClick={refreshBacklog} disabled={loading}>
              Refresh
            </Button>
          </div>
        </div>

        {/* Quick-filter chips. Kind chips set the kind substring filter;
            severity chips set the floor. Both compose with the free-text
            kind input above. */}
        <div className="flex items-center gap-2 flex-wrap text-xs">
          <span className="text-theme-tertiary">Kind:</span>
          {QUICK_KIND_FILTERS.map((chip) => {
            const active = filterKind === chip.match;
            return (
              <button
                key={chip.label}
                onClick={() => setFilterKind(chip.match)}
                className={
                  'px-2 py-0.5 rounded border transition-colors ' +
                  (active
                    ? 'bg-theme-info text-theme-on-accent border-theme-info'
                    : 'border-theme text-theme-primary hover:bg-theme-surface-hover')
                }
              >
                {chip.label}
              </button>
            );
          })}
          <span className="text-theme-tertiary ml-3">Min severity:</span>
          {(['all', 'low', 'medium', 'high', 'critical'] as const).map((sev) => {
            const active = minSeverity === sev;
            return (
              <button
                key={sev}
                onClick={() => setMinSeverity(sev)}
                className={
                  'px-2 py-0.5 rounded border transition-colors ' +
                  (active
                    ? 'bg-theme-info text-theme-on-accent border-theme-info'
                    : 'border-theme text-theme-primary hover:bg-theme-surface-hover')
                }
              >
                {sev}
              </button>
            );
          })}
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

      {/* Phase 10.7 polish — dispatch pipeline metrics tile (Phase 10.5 backend). */}
      <div className="px-4">
        <DispatchLatencyTile />
      </div>

      <div className="flex-1 grid grid-cols-1 md:grid-cols-3 gap-4 p-4 overflow-hidden">
        <section className="md:col-span-2 flex flex-col bg-theme-surface rounded-lg border border-theme overflow-hidden">
          <div className="px-4 py-2 border-b border-theme flex items-center justify-between">
            <h2 className="font-medium">Live Event Feed</h2>
            <span className="text-xs text-theme-tertiary">{filteredEvents.length} events</span>
          </div>
          <div className="flex-1 overflow-y-auto">
            {filteredEvents.length === 0 ? (
              <p className="p-4 text-sm text-theme-tertiary">No events yet.</p>
            ) : (
              <ul className="divide-y divide-theme-border text-sm">
                {filteredEvents.map((e) => (
                  <li
                    key={e.id}
                    className={`px-4 py-2 hover:bg-theme-surface-hover cursor-pointer ${selectedEvent?.id === e.id ? 'bg-theme-surface-hover' : ''}`}
                    onClick={() => setSelectedEvent(e)}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <div className="font-mono text-xs flex-1 truncate">{e.kind}</div>
                      <SeverityBadge severity={e.severity} />
                      <span className="text-xs text-theme-tertiary">
                        {new Date(e.emitted_at).toLocaleTimeString()}
                      </span>
                    </div>
                    <div className="flex items-center gap-3 mt-0.5 text-xs text-theme-tertiary">
                      {e.source && <span>source: {e.source}</span>}
                      {/* When an event references a specific module (e.g.
                          system.module_published), give the operator one-
                          click navigation to that module's detail page. */}
                      {e.node_module_id && (
                        <Link
                          to={`/app/system/modules?module_id=${e.node_module_id}`}
                          onClick={(ev) => ev.stopPropagation()}
                          className="inline-flex items-center gap-1 text-theme-link hover:underline"
                          title="View module"
                        >
                          <Package size={12} />
                          {(e.payload?.module_name as string | undefined) ?? 'view module'}
                        </Link>
                      )}
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </section>

        <section className="flex flex-col bg-theme-surface rounded-lg border border-theme overflow-hidden">
          <div className="px-4 py-2 border-b border-theme flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Clock size={14} />
              <h2 className="font-medium">{selectedEvent ? 'Event Detail' : 'Correlation Chain'}</h2>
            </div>
            {selectedEvent && (
              <button
                onClick={() => setSelectedEvent(null)}
                className="text-xs text-theme-tertiary hover:text-theme-primary"
              >
                clear
              </button>
            )}
          </div>
          <div className="flex-1 overflow-y-auto">
            {!selectedEvent ? (
              <p className="p-4 text-sm text-theme-tertiary">Click an event to view its details + correlation chain.</p>
            ) : (
              <div className="text-sm">
                {/* Selected event detail — was missing entirely before; clicking
                    only set selectedCorrelation, so events without a correlation_id
                    (most events) produced no visible response. */}
                <div className="px-4 py-3 border-b border-theme space-y-2">
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-xs">{selectedEvent.kind}</span>
                    <SeverityBadge severity={selectedEvent.severity} />
                  </div>
                  <div className="text-xs text-theme-tertiary space-y-0.5">
                    <div>id: <code className="font-mono">{selectedEvent.id}</code></div>
                    <div>emitted: {new Date(selectedEvent.emitted_at).toLocaleString()}</div>
                    {selectedEvent.source && <div>source: {selectedEvent.source}</div>}
                    {selectedEvent.correlation_id && (
                      <div>correlation_id: <code className="font-mono">{selectedEvent.correlation_id}</code></div>
                    )}
                    {selectedEvent.node_id && <div>node_id: <code className="font-mono">{selectedEvent.node_id}</code></div>}
                    {selectedEvent.node_instance_id && <div>instance_id: <code className="font-mono">{selectedEvent.node_instance_id}</code></div>}
                    {selectedEvent.node_module_id && <div>module_id: <code className="font-mono">{selectedEvent.node_module_id}</code></div>}
                  </div>
                  {selectedEvent.payload && Object.keys(selectedEvent.payload).length > 0 && (
                    <details className="text-xs" open>
                      <summary className="cursor-pointer text-theme-tertiary hover:text-theme-primary">payload</summary>
                      <pre className="mt-1 p-2 bg-theme-surface rounded text-xs overflow-x-auto font-mono">
{JSON.stringify(selectedEvent.payload, null, 2)}
                      </pre>
                    </details>
                  )}
                  {selectedEvent.node_instance_id && selectedEvent.node_module_id && (
                    <div className="pt-2">
                      <AttributionFeedbackButton
                        instanceId={selectedEvent.node_instance_id}
                        candidateModuleId={selectedEvent.node_module_id}
                        candidateKind="event_correlation"
                      />
                    </div>
                  )}
                  {/* Boot Replay — when the selected event references a
                      NodeInstance, opens the boot timeline modal for
                      that instance, scoped to this event's correlation_id
                      if present. */}
                  {selectedEvent.node_instance_id && (
                    <div className="pt-2">
                      <button
                        type="button"
                        onClick={() => setBootReplay({
                          instanceId: selectedEvent.node_instance_id!,
                          correlationId: selectedEvent.correlation_id ?? undefined,
                        })}
                        className="inline-flex items-center gap-1 text-xs text-theme-link hover:underline"
                        title="View boot timeline for this instance"
                      >
                        <PlayCircle size={12} />
                        Boot Replay
                      </button>
                    </div>
                  )}
                </div>

                {/* Correlation chain — separate section, only meaningful
                    when correlation_id is present AND there are multiple
                    events in the chain. */}
                {selectedCorrelation && (
                  <div>
                    <div className="px-4 py-2 border-b border-theme bg-theme-background">
                      <span className="text-xs font-medium text-theme-tertiary uppercase tracking-wide">Correlation Chain ({correlationEvents.length})</span>
                    </div>
                    {correlationEvents.length === 0 ? (
                      <p className="px-4 py-2 text-xs text-theme-tertiary">No other events with this correlation_id in the buffer.</p>
                    ) : (
                      <ul className="divide-y divide-theme-border">
                        {correlationEvents.map((e) => (
                          <li key={e.id} className={`px-4 py-2 space-y-0.5 cursor-pointer hover:bg-theme-surface-hover ${selectedEvent.id === e.id ? 'bg-theme-surface-hover' : ''}`} onClick={() => setSelectedEvent(e)}>
                            <div className="font-mono text-xs">{e.kind}</div>
                            <div className="text-xs text-theme-tertiary">
                              {new Date(e.emitted_at).toLocaleTimeString()}
                            </div>
                          </li>
                        ))}
                      </ul>
                    )}
                  </div>
                )}
              </div>
            )}
          </div>
        </section>
      </div>

      <BootReplayModal
        instanceId={bootReplay?.instanceId ?? null}
        correlationId={bootReplay?.correlationId}
        onClose={() => setBootReplay(null)}
      />
    </div>
  );
}

interface CounterProps {
  icon: React.ReactNode;
  label: string;
  value: number | string;
  highlight?: boolean;
}
function Counter({ icon, label, value, highlight }: CounterProps): React.JSX.Element {
  return (
    <div className={`bg-theme-surface rounded-lg border ${highlight ? 'border-theme-warning' : 'border-theme'} p-3`}>
      <div className="flex items-center justify-between">
        <div className="text-xs text-theme-tertiary flex items-center gap-1">
          {icon}
          {label}
        </div>
      </div>
      <div className="text-2xl font-semibold mt-1">{value}</div>
    </div>
  );
}

function SeverityBadge({ severity }: { severity: FleetEvent['severity'] }): React.JSX.Element {
  const variant = severity === 'critical' || severity === 'high' ? 'danger' : severity === 'medium' ? 'warning' : 'default';
  return <Badge variant={variant}>{severity}</Badge>;
}

export default FleetDashboardPage;
