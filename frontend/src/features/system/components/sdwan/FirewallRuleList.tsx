import React, { useEffect, useState, useCallback } from 'react';
import { Trash2, Shield, Pencil, ChevronRight, ChevronDown } from 'lucide-react';
import { sdwanApi } from '../../services/api/sdwanApi';
import type { SdwanFirewallRule, SdwanSelector, SdwanPortRange } from '../../types/sdwan.types';

interface FirewallRuleListProps {
  networkId: string;
  onDelete?: (rule: SdwanFirewallRule) => void;
  onEdit?: (rule: SdwanFirewallRule) => void;
  refreshKey?: number;
}

export const FirewallRuleList: React.FC<FirewallRuleListProps> = ({ networkId, onDelete, onEdit, refreshKey }) => {
  const [rules, setRules] = useState<SdwanFirewallRule[]>([]);
  const [defaultPolicy, setDefaultPolicy] = useState<string>('accept');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());

  const toggleExpanded = useCallback((id: string) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) { next.delete(id); } else { next.add(id); }
      return next;
    });
  }, []);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const result = await sdwanApi.getFirewallRules(networkId);
      setRules(result.rules);
      setDefaultPolicy(result.defaultPolicy);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load firewall rules');
    } finally {
      setLoading(false);
    }
  }, [networkId]);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  if (loading) return <div className="p-4 text-theme-secondary">Loading firewall rules…</div>;
  if (error) return <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>;

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2 px-3 py-2 bg-theme-background-secondary rounded text-sm">
        <Shield size={16} className={defaultPolicy === 'drop' ? 'text-theme-danger' : 'text-theme-success'} />
        <span className="text-theme-secondary">Default policy:</span>
        <span className={`font-medium ${defaultPolicy === 'drop' ? 'text-theme-danger' : 'text-theme-success'}`}>
          {defaultPolicy === 'drop' ? 'Drop all (allowlist mode)' : 'Allow all'}
        </span>
        <span className="text-theme-secondary text-xs ml-auto">
          {rules.length} rule{rules.length === 1 ? '' : 's'}
        </span>
      </div>

      {rules.length === 0 ? (
        <div className="p-8 text-center text-theme-secondary text-sm">
          {defaultPolicy === 'drop'
            ? 'No rules — all traffic is dropped. Add rules to allow specific traffic.'
            : 'No rules — all traffic is accepted by default. Add rules to refine policy.'}
        </div>
      ) : (
        <table className="w-full">
          <thead className="bg-theme-background-secondary text-theme-secondary text-sm">
            <tr>
              <th className="w-8 p-3"></th>
              <th className="text-left p-3">Priority</th>
              <th className="text-left p-3">Name</th>
              <th className="text-left p-3">Action</th>
              <th className="text-left p-3">Match</th>
              <th className="text-right p-3">Actions</th>
            </tr>
          </thead>
          <tbody>
            {rules.map((r) => {
              const expanded = expandedIds.has(r.id);
              return (
              <React.Fragment key={r.id}>
              <tr className="border-b border-theme">
                <td className="p-3 align-middle">
                  <button
                    type="button"
                    onClick={() => toggleExpanded(r.id)}
                    className="p-1 text-theme-secondary hover:text-theme-primary"
                    title={expanded ? 'Collapse details' : 'Expand details'}
                    aria-label={expanded ? `Collapse rule ${r.name}` : `Expand rule ${r.name}`}
                  >
                    {expanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
                  </button>
                </td>
                <td className="p-3 text-theme-secondary text-sm">{r.priority}</td>
                <td className="p-3">
                  <div className="font-medium text-theme-primary">{r.name}</div>
                  <div className="text-xs text-theme-secondary">
                    {r.direction} · {r.protocol}
                    {!r.enabled ? ' · disabled' : ''}
                  </div>
                </td>
                <td className="p-3">
                  <span className={actionBadgeClass(r.action)}>{r.action}</span>
                </td>
                <td className="p-3 text-xs text-theme-secondary font-mono">
                  {describeMatch(r.src_selector, r.dst_selector, r.port_range)}
                </td>
                <td className="p-3 text-right">
                  {onEdit && (
                    <button
                      type="button"
                      onClick={() => onEdit(r)}
                      className="text-theme-secondary hover:bg-theme-surface-hover p-1 rounded mr-1"
                      aria-label={`Edit rule ${r.name}`}
                    >
                      <Pencil size={16} />
                    </button>
                  )}
                  {onDelete && (
                    <button
                      type="button"
                      onClick={() => onDelete(r)}
                      className="text-theme-danger hover:bg-theme-danger p-1 rounded"
                      aria-label={`Delete rule ${r.name}`}
                    >
                      <Trash2 size={16} />
                    </button>
                  )}
                </td>
              </tr>
              {expanded && (
                <tr className="bg-theme-background border-b border-theme">
                  <td></td>
                  <td colSpan={5} className="p-3">
                    <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Priority</label>
                        <p className="text-theme-primary">{r.priority}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Action</label>
                        <p className="text-theme-primary">{r.action}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Enabled</label>
                        <p className="text-theme-primary">{r.enabled ? 'Yes' : 'No (disabled)'}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Direction</label>
                        <p className="text-theme-primary">{r.direction}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Protocol</label>
                        <p className="text-theme-primary">{r.protocol}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Port Range</label>
                        <p className="text-theme-primary font-mono text-xs">{describePortRange(r.port_range)}</p>
                      </div>
                      <div className="col-span-2 md:col-span-3">
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Source Selector</label>
                        <p className="text-theme-primary font-mono text-xs break-all">{fullSelector(r.src_selector)}</p>
                      </div>
                      <div className="col-span-2 md:col-span-3">
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Destination Selector</label>
                        <p className="text-theme-primary font-mono text-xs break-all">{fullSelector(r.dst_selector)}</p>
                      </div>
                      {r.last_compiled_at && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last Compiled</label>
                          <p className="text-theme-primary text-xs">{new Date(r.last_compiled_at).toLocaleString()}</p>
                        </div>
                      )}
                      {r.created_at && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                          <p className="text-theme-primary text-xs">{new Date(r.created_at).toLocaleString()}</p>
                        </div>
                      )}
                      <div className="col-span-2 md:col-span-3">
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Compiled Preview</label>
                        {r.compiled_preview ? (
                          <pre className="text-theme-primary font-mono text-xs whitespace-pre-wrap break-all bg-theme-background-secondary rounded p-2">{r.compiled_preview}</pre>
                        ) : (
                          <p className="text-theme-secondary text-xs">No compiled preview available — recompile the network to generate one.</p>
                        )}
                      </div>
                      {r.metadata && Object.keys(r.metadata).length > 0 && (
                        <div className="col-span-2 md:col-span-3">
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Metadata</label>
                          <pre className="text-theme-primary font-mono text-xs whitespace-pre-wrap break-all bg-theme-background-secondary rounded p-2">{JSON.stringify(r.metadata, null, 2)}</pre>
                        </div>
                      )}
                    </div>
                  </td>
                </tr>
              )}
              </React.Fragment>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
};

function actionBadgeClass(action: string): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  switch (action) {
    case 'accept': return `${base} bg-theme-success text-theme-success`;
    case 'drop':   return `${base} bg-theme-danger text-theme-danger`;
    case 'reject': return `${base} bg-theme-warning text-theme-warning`;
    default:       return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}

function describeMatch(
  src?: SdwanSelector,
  dst?: SdwanSelector,
  port?: { from: number; to: number } | null
): string {
  const parts: string[] = [];
  const from = describeSelector(src);
  const to = describeSelector(dst);
  if (from) parts.push(`from ${from}`);
  if (to)   parts.push(`to ${to}`);
  if (port) {
    parts.push(port.from === port.to ? `port ${port.from}` : `ports ${port.from}-${port.to}`);
  }
  return parts.length ? parts.join(' · ') : 'any';
}

function describeSelector(sel?: SdwanSelector): string | null {
  if (!sel) return null;
  if ('all' in sel && (sel as { all: true }).all) return 'any';
  if ('peer_id' in sel) return `peer ${(sel as { peer_id: string }).peer_id.slice(0, 8)}…`;
  if ('cidr' in sel)    return (sel as { cidr: string }).cidr;
  if ('tag' in sel)     return `tag ${(sel as { tag: string }).tag} (deferred)`;
  return null;
}

// Full (untruncated) selector text for the expanded row. The peer reference is
// a bare `peer_id` (no node id) and `sdwan_peer` is not a registered entity
// type, so it stays plain text — never an invented link.
function fullSelector(sel?: SdwanSelector): string {
  if (!sel || Object.keys(sel).length === 0) return 'any (wildcard)';
  if ('all' in sel && (sel as { all: true }).all) return 'any (wildcard)';
  if ('peer_id' in sel) return `peer ${(sel as { peer_id: string }).peer_id}`;
  if ('cidr' in sel)    return `cidr ${(sel as { cidr: string }).cidr}`;
  if ('tag' in sel)     return `tag ${(sel as { tag: string }).tag} (deferred)`;
  return 'any (wildcard)';
}

function describePortRange(port?: SdwanPortRange | null): string {
  if (!port) return 'any port';
  return port.from === port.to ? `port ${port.from}` : `ports ${port.from}–${port.to}`;
}
