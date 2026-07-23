import React, { useCallback, useEffect, useState } from 'react';
import { Bot, ChevronDown, ChevronRight, Play, Power, PowerOff } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { nodeInstancePeersApi } from '@system/features/system/services/api/nodeInstancePeersApi';
import type { SystemNodeInstancePeer } from '@system/features/system/types/system.types';

// NodeInstance-as-Agent peers operator surface (IMP-20c082f9d519).
// Peers auto-register on first heartbeat; operators activate explicitly
// before remote-task delegation (see docs/agent-peering.md). Distinct from
// the Compute → Platform → Peers tab, which manages platform federation
// peers (/system/platform/peers) — these are per-instance agent peers.

interface AgentPeersTabProps {
  onActionsReady?: (handle: { refresh: () => void } | null) => void;
}

export const AgentPeersTab: React.FC<AgentPeersTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canActivate = hasPermission('system.peers.activate');
  const canExecute = hasPermission('system.peers.execute');

  const [peers, setPeers] = useState<SystemNodeInstancePeer[]>([]);
  const [totalCount, setTotalCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [delegateTarget, setDelegateTarget] = useState<SystemNodeInstancePeer | null>(null);

  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  const toggleExpanded = useCallback((id: string) => {
    setExpandedIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      // Paginated endpoint (default per_page 20); fetch a large page so the
      // operator surface doesn't silently truncate — accounts with 100s of
      // peers see an explicit "showing N of M" hint below the list.
      const result = await nodeInstancePeersApi.list({ per_page: 100 });
      setPeers(result.peers);
      setTotalCount(result.meta.total_count);
    } catch {
      addNotification({ type: 'error', message: 'Failed to load agent peers' });
    } finally {
      setLoading(false);
    }
  }, [addNotification]);

  useEffect(() => { void refresh(); }, [refresh]);

  useEffect(() => {
    onActionsReady?.({ refresh: () => void refresh() });
    return () => onActionsReady?.(null);
  }, [onActionsReady, refresh]);

  const handleActivate = useCallback(async (peer: SystemNodeInstancePeer) => {
    try {
      await nodeInstancePeersApi.activate(peer.id);
      addNotification({ type: 'success', message: `Peer @${peer.handle} activated` });
      void refresh();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Activate failed' });
    }
  }, [addNotification, refresh]);

  const handleDeactivate = useCallback(async (peer: SystemNodeInstancePeer) => {
    try {
      await nodeInstancePeersApi.deactivate(peer.id);
      addNotification({ type: 'success', message: `Peer @${peer.handle} deactivated` });
      void refresh();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Deactivate failed' });
    }
  }, [addNotification, refresh]);

  return (
    <div className="space-y-4">
      <p className="text-sm text-theme-secondary">
        Node instances acting as delegable agents. Peers register themselves on
        first heartbeat; activate a peer before delegating tasks to the skills
        it declares. Distinct from platform federation peers (Compute →
        Platform → Peers).
      </p>

      <section className="bg-theme-surface rounded-lg border border-theme">
        <header className="px-4 py-3 border-b border-theme flex items-center gap-2">
          <Bot size={16} className="text-theme-info-fg" />
          <h2 className="font-medium text-theme-primary">Agent peers</h2>
          {totalCount > 0 && (
            <Badge variant="info" size="xs">{totalCount}</Badge>
          )}
        </header>
        <div className="p-2">
          {loading ? (
            <p className="text-sm text-theme-tertiary p-3">Loading…</p>
          ) : peers.length === 0 ? (
            <p className="text-sm text-theme-secondary p-3">
              No agent peers yet. Peers appear here automatically once an
              instance announces itself.
            </p>
          ) : (
            <ul className="divide-y divide-theme">
              {peers.map((peer) => {
                const expanded = expandedIds.has(peer.id);
                const skillNames = (peer.declared_skills ?? [])
                  .map((s) => s.name)
                  .filter(Boolean);
                return (
                  <li key={peer.id} className="px-3 py-2.5">
                    <div className="flex items-start justify-between gap-3">
                      <button
                        type="button"
                        onClick={() => toggleExpanded(peer.id)}
                        className="p-1 -ml-1 mt-0.5 text-theme-secondary hover:text-theme-primary rounded transition-colors flex-shrink-0"
                        title={expanded ? 'Collapse details' : 'Expand details'}
                      >
                        {expanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
                      </button>
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center gap-2 text-sm">
                          <span className="font-medium text-theme-primary">@{peer.handle}</span>
                          <Badge variant={peer.status === 'active' ? 'success' : 'secondary'} size="xs">
                            {peer.status}
                          </Badge>
                          {!peer.enabled && (
                            <Badge variant="secondary" size="xs">disabled</Badge>
                          )}
                        </div>
                        <div className="mt-1 text-xs text-theme-tertiary">
                          Trust {peer.trust_score.toFixed(2)} · Budget{' '}
                          {peer.daily_decision_used}/{peer.daily_decision_budget} ·{' '}
                          {peer.last_announced_at
                            ? <>Last announced {new Date(peer.last_announced_at).toLocaleString()}</>
                            : 'Never announced'}
                        </div>

                        {expanded && (
                          <div className="mt-2 pt-2 border-t border-theme grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Instance</label>
                              <p className="text-theme-primary font-mono text-xs truncate" title={peer.node_instance_id}>{peer.node_instance_id}</p>
                            </div>
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Executions</label>
                              <p className="text-theme-primary text-xs">
                                {peer.execution_count} total · {peer.execution_failure_count} failed
                              </p>
                            </div>
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last executed</label>
                              <p className="text-theme-primary text-xs">
                                {peer.last_executed_at ? new Date(peer.last_executed_at).toLocaleString() : 'Never'}
                              </p>
                            </div>
                            {skillNames.length > 0 && (
                              <div className="col-span-full">
                                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Declared skills</label>
                                <div className="flex flex-wrap gap-1">
                                  {skillNames.map((name) => (
                                    <Badge key={name} variant="secondary" size="xs">{name}</Badge>
                                  ))}
                                </div>
                              </div>
                            )}
                            {peer.addresses && peer.addresses.length > 0 && (
                              <div className="col-span-full">
                                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Addresses</label>
                                <p className="text-theme-primary font-mono text-xs break-all">{peer.addresses.join(', ')}</p>
                              </div>
                            )}
                          </div>
                        )}
                      </div>
                      <div className="flex items-center gap-1">
                        {canExecute && peer.enabled && (
                          <Button size="sm" variant="outline" onClick={() => setDelegateTarget(peer)} title="Delegate task">
                            <Play size={14} />
                          </Button>
                        )}
                        {canActivate && !peer.enabled && (
                          <Button size="sm" variant="outline" onClick={() => handleActivate(peer)} title="Activate peer">
                            <Power size={14} />
                          </Button>
                        )}
                        {canActivate && peer.enabled && (
                          <Button size="sm" variant="ghost" onClick={() => handleDeactivate(peer)} title="Deactivate peer">
                            <PowerOff size={14} className="text-theme-danger-fg" />
                          </Button>
                        )}
                      </div>
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
          {!loading && totalCount > peers.length && (
            <p className="text-xs text-theme-tertiary px-3 pb-2">
              Showing {peers.length} of {totalCount} peers.
            </p>
          )}
        </div>
      </section>

      {delegateTarget && (
        <DelegateTaskModal
          peer={delegateTarget}
          onClose={() => setDelegateTarget(null)}
          onDispatched={(taskId) => {
            setDelegateTarget(null);
            addNotification({
              type: 'success',
              message: `Task dispatched to @${delegateTarget.handle} (${taskId})`,
            });
            void refresh();
          }}
        />
      )}
    </div>
  );
};

const DelegateTaskModal: React.FC<{
  peer: SystemNodeInstancePeer;
  onClose: () => void;
  onDispatched: (taskId: string) => void;
}> = ({ peer, onClose, onDispatched }) => {
  const { addNotification } = useNotifications();
  const skillNames = (peer.declared_skills ?? []).map((s) => s.name).filter(Boolean);
  const [skill, setSkill] = useState(skillNames[0] ?? '');
  const [inputRaw, setInputRaw] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async () => {
    if (!skill) return;
    setSubmitting(true);
    try {
      // Backend strong params accept input as a hash or a scalar only —
      // other JSON (arrays, numbers, booleans) would be silently dropped
      // server-side, so anything but a plain object is sent as the raw
      // string scalar.
      let input: Record<string, unknown> | string | undefined;
      const trimmed = inputRaw.trim();
      if (trimmed) {
        let parsed: unknown;
        try {
          parsed = JSON.parse(trimmed);
        } catch {
          parsed = undefined;
        }
        input =
          parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
            ? (parsed as Record<string, unknown>)
            : trimmed;
      }
      const result = await nodeInstancePeersApi.execute(peer.id, {
        skill,
        ...(input !== undefined ? { input } : {}),
      });
      onDispatched(result.task_id);
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Dispatch failed' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-black/50 flex items-center justify-center p-4">
      <div className="bg-theme-surface rounded-lg shadow-xl w-full max-w-md p-6">
        <h3 className="text-lg font-semibold mb-3 text-theme-primary">
          Delegate task to @{peer.handle}
        </h3>

        {skillNames.length === 0 ? (
          <p className="text-sm text-theme-secondary mb-4">
            This peer declares no skills — nothing can be delegated to it.
          </p>
        ) : (
          <>
            <label className="block text-sm text-theme-secondary mb-1" htmlFor="peer-delegate-skill">Skill</label>
            <select
              id="peer-delegate-skill"
              value={skill}
              onChange={(e) => setSkill(e.target.value)}
              className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary mb-4"
            >
              {skillNames.map((name) => (
                <option key={name} value={name}>{name}</option>
              ))}
            </select>

            <label className="block text-sm text-theme-secondary mb-1" htmlFor="peer-delegate-input">Input (optional JSON or text)</label>
            <textarea
              id="peer-delegate-input"
              value={inputRaw}
              onChange={(e) => setInputRaw(e.target.value)}
              placeholder='{"key": "value"}'
              rows={4}
              className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary font-mono text-sm mb-4"
            />
            <p className="text-xs text-theme-tertiary mb-4">
              Dispatched asynchronously as an a2a_call task; the result arrives
              via the peer&apos;s agent loop. Uses one of the peer&apos;s{' '}
              {peer.daily_decision_budget - peer.daily_decision_used} remaining
              daily decisions.
            </p>
          </>
        )}

        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button
            variant="primary"
            onClick={handleSubmit}
            disabled={!skill || submitting || skillNames.length === 0}
          >
            {submitting ? 'Dispatching…' : 'Dispatch'}
          </Button>
        </div>
      </div>
    </div>
  );
};
