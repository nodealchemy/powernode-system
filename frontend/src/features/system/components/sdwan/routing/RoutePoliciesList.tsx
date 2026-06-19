import React, { useEffect, useState, useCallback } from 'react';
import { Filter, Pencil, Trash2, Power, PowerOff, ChevronRight, ChevronDown } from 'lucide-react';
import { EntityLink } from '@/shared/components/entity';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanRoutePolicy, SdwanRoutePolicyStatement } from '../../../types/sdwan.types';

interface RoutePoliciesListProps {
  refreshKey?: number;
  onEdit?: (policy: SdwanRoutePolicy) => void;
  onDelete?: (policy: SdwanRoutePolicy) => void;
  onToggle?: (policy: SdwanRoutePolicy) => void;
}

const scopeColor = (scope: string) => {
  switch (scope) {
    case 'account':
      return 'bg-theme-background-secondary text-theme-primary';
    case 'network':
      return 'bg-theme-info-bg text-theme-info-fg';
    case 'peer':
      return 'bg-theme-warning-bg text-theme-warning-fg';
    default:
      return 'bg-theme-background-secondary';
  }
};

// Map a policy's scope to the registry entity type for its scope_resource_id.
// `network` → the SDWAN network detail surface (registered). `peer` has no
// registered type yet, so EntityLink degrades to plain text automatically.
// `account` scope carries no resource id.
const scopeResourceType = (scope: SdwanRoutePolicy['scope']): string | undefined => {
  switch (scope) {
    case 'network':
      return 'sdwan_network';
    case 'peer':
      return 'sdwan_peer';
    default:
      return undefined;
  }
};

// Render one match/action statement as a compact, human-readable line.
const matchSummary = (s: SdwanRoutePolicyStatement): string => {
  const m = s.match;
  const parts: string[] = [];
  if (m.prefix_in?.length) parts.push(`prefix ∈ [${m.prefix_in.join(', ')}]`);
  if (m.as_path_regex) parts.push(`as-path ~ /${m.as_path_regex}/`);
  if (m.community_in?.length) parts.push(`community ∈ [${m.community_in.join(', ')}]`);
  if (m.tag_in?.length) parts.push(`tag ∈ [${m.tag_in.join(', ')}]`);
  if (m.peer_in?.length) parts.push(`peer ∈ [${m.peer_in.join(', ')}]`);
  return parts.length ? parts.join(' AND ') : 'any';
};

const actionSummary = (s: SdwanRoutePolicyStatement): string => {
  const a = s.action;
  const parts: string[] = [a.type];
  if (a.set_local_pref !== undefined) parts.push(`local-pref ${a.set_local_pref}`);
  if (a.set_med !== undefined) parts.push(`med ${a.set_med}`);
  if (a.prepend_as_path !== undefined) parts.push(`prepend-as ${a.prepend_as_path}`);
  if (a.add_community) parts.push(`+community ${a.add_community}`);
  return parts.join(', ');
};

export const RoutePoliciesList: React.FC<RoutePoliciesListProps> = ({
  refreshKey,
  onEdit,
  onDelete,
  onToggle,
}) => {
  const [policies, setPolicies] = useState<SdwanRoutePolicy[]>([]);
  const [scopeFilter, setScopeFilter] = useState<string>('');
  const [directionFilter, setDirectionFilter] = useState<string>('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Expansion state — Set<id> so multiple rows can stay open at once.
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  // Lazily-fetched full policy detail (statements) keyed by policy id. The
  // list endpoint returns statement_count but not the statements array, so we
  // fetch the single policy on first expand and cache it.
  const [detailById, setDetailById] = useState<Record<string, SdwanRoutePolicy>>({});
  const [detailLoading, setDetailLoading] = useState<Set<string>>(new Set());
  const [detailError, setDetailError] = useState<Record<string, string>>({});

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const result = await sdwanApi.listRoutePolicies({
        scope: scopeFilter || undefined,
        direction: directionFilter || undefined,
      });
      setPolicies(result.route_policies);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load route policies');
    } finally {
      setLoading(false);
    }
  }, [scopeFilter, directionFilter]);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  const fetchDetail = useCallback(async (id: string) => {
    setDetailLoading((prev) => new Set(prev).add(id));
    setDetailError((prev) => {
      const next = { ...prev };
      delete next[id];
      return next;
    });
    try {
      const full = await sdwanApi.getRoutePolicy(id);
      setDetailById((prev) => ({ ...prev, [id]: full }));
    } catch (err) {
      setDetailError((prev) => ({
        ...prev,
        [id]: err instanceof Error ? err.message : 'Failed to load statements',
      }));
    } finally {
      setDetailLoading((prev) => {
        const next = new Set(prev);
        next.delete(id);
        return next;
      });
    }
  }, []);

  const toggleExpanded = useCallback(
    (policy: SdwanRoutePolicy) => {
      const id = policy.id;
      setExpandedIds((prev) => {
        const next = new Set(prev);
        if (next.has(id)) {
          next.delete(id);
        } else {
          next.add(id);
          // Fetch statements on first expand if not already cached and the
          // list item didn't carry them inline.
          if (!detailById[id] && !policy.statements) {
            void fetchDetail(id);
          }
        }
        return next;
      });
    },
    [detailById, fetchDetail],
  );

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-3">
        <Filter size={14} className="text-theme-secondary" />
        <select
          value={scopeFilter}
          onChange={(e) => setScopeFilter(e.target.value)}
          className="px-2 py-1.5 rounded bg-theme-surface border border-theme text-sm text-theme-primary"
        >
          <option value="">All scopes</option>
          <option value="account">Account</option>
          <option value="network">Network</option>
          <option value="peer">Peer</option>
        </select>
        <select
          value={directionFilter}
          onChange={(e) => setDirectionFilter(e.target.value)}
          className="px-2 py-1.5 rounded bg-theme-surface border border-theme text-sm text-theme-primary"
        >
          <option value="">Both directions</option>
          <option value="import">Import (inbound)</option>
          <option value="export">Export (outbound)</option>
        </select>
        <div className="text-xs text-theme-secondary ml-auto">
          {policies.length} polic{policies.length === 1 ? 'y' : 'ies'}
        </div>
      </div>

      {loading ? (
        <div className="p-4 text-theme-secondary text-sm">Loading…</div>
      ) : error ? (
        <div className="p-3 bg-theme-danger-bg text-theme-danger-fg rounded text-sm">{error}</div>
      ) : policies.length === 0 ? (
        <div className="p-8 text-center text-theme-secondary text-sm">
          No route policies yet.
          <div className="mt-2 text-xs">
            Route policies control which prefixes get distributed via iBGP and what BGP attributes (local-pref, MED,
            communities) are applied. Create one to filter or shape route distribution.
          </div>
        </div>
      ) : (
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-theme-secondary border-b border-theme">
              <th className="w-8 px-2 py-2"></th>
              <th className="px-3 py-2">Name</th>
              <th className="px-3 py-2">Scope</th>
              <th className="px-3 py-2">Direction</th>
              <th className="px-3 py-2">Statements</th>
              <th className="px-3 py-2">Enabled</th>
              <th className="px-3 py-2 text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            {policies.map((p) => {
              const expanded = expandedIds.has(p.id);
              const detail = detailById[p.id];
              const statements = detail?.statements ?? p.statements;
              const loadingDetail = detailLoading.has(p.id);
              const errDetail = detailError[p.id];
              const resourceType = scopeResourceType(p.scope);
              return (
                <React.Fragment key={p.id}>
                  <tr className="border-b border-theme hover:bg-theme-background-secondary/30">
                    <td className="px-2 py-2 align-top">
                      <button
                        type="button"
                        onClick={() => toggleExpanded(p)}
                        className="p-1 text-theme-secondary hover:text-theme-primary"
                        title={expanded ? 'Collapse details' : 'Expand details'}
                      >
                        {expanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                      </button>
                    </td>
                    <td className="px-3 py-2">
                      <div className="font-medium text-theme-primary">{p.name}</div>
                      {p.description && <div className="text-xs text-theme-secondary">{p.description}</div>}
                    </td>
                    <td className="px-3 py-2">
                      <span className={`text-xs font-medium px-2 py-0.5 rounded ${scopeColor(p.scope)}`}>
                        {p.scope}
                      </span>
                      {p.scope_resource_id && (
                        <div className="font-mono text-xs mt-0.5">
                          {resourceType ? (
                            <EntityLink
                              type={resourceType}
                              id={p.scope_resource_id}
                              label={p.scope_resource_id.slice(0, 8)}
                            />
                          ) : (
                            <span className="text-theme-secondary">{p.scope_resource_id.slice(0, 8)}</span>
                          )}
                        </div>
                      )}
                    </td>
                    <td className="px-3 py-2 text-xs">
                      <span className={p.direction === 'import' ? 'text-theme-info-fg' : 'text-theme-success-fg'}>
                        {p.direction}
                      </span>
                    </td>
                    <td className="px-3 py-2 text-xs">{p.statement_count}</td>
                    <td className="px-3 py-2">
                      {p.enabled ? (
                        <Power size={14} className="text-theme-success-fg" />
                      ) : (
                        <PowerOff size={14} className="text-theme-secondary" />
                      )}
                    </td>
                    <td className="px-3 py-2">
                      <div className="flex justify-end gap-1">
                        {onToggle && (
                          <button
                            type="button"
                            onClick={() => onToggle(p)}
                            className="p-1 hover:bg-theme-background-secondary rounded text-theme-secondary"
                            title={p.enabled ? 'Disable' : 'Enable'}
                          >
                            {p.enabled ? <PowerOff size={14} /> : <Power size={14} />}
                          </button>
                        )}
                        {onEdit && (
                          <button
                            type="button"
                            onClick={() => onEdit(p)}
                            className="p-1 hover:bg-theme-background-secondary rounded text-theme-secondary"
                            title="Edit"
                          >
                            <Pencil size={14} />
                          </button>
                        )}
                        {onDelete && (
                          <button
                            type="button"
                            onClick={() => onDelete(p)}
                            className="p-1 hover:bg-theme-background-secondary rounded text-theme-danger-fg"
                            title="Delete"
                          >
                            <Trash2 size={14} />
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                  {expanded && (
                    <tr className="bg-theme-background border-b border-theme">
                      <td></td>
                      <td colSpan={6} className="px-3 py-3">
                        <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Scope</label>
                            <p className="text-theme-primary">{p.scope}</p>
                          </div>
                          {p.scope_resource_id && (
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Scope resource</label>
                              {resourceType ? (
                                <EntityLink
                                  type={resourceType}
                                  id={p.scope_resource_id}
                                  label={p.scope_resource_id}
                                  className="font-mono text-xs break-all"
                                />
                              ) : (
                                <p className="text-theme-primary font-mono text-xs break-all">{p.scope_resource_id}</p>
                              )}
                            </div>
                          )}
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Direction</label>
                            <p className="text-theme-primary">{p.direction}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Enabled</label>
                            <p className="text-theme-primary">{p.enabled ? 'Yes' : 'No'}</p>
                          </div>
                          <div>
                            <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Slug</label>
                            <p className="text-theme-primary font-mono text-xs">{p.slug}</p>
                          </div>
                          {p.created_at && (
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                              <p className="text-theme-primary text-xs">{new Date(p.created_at).toLocaleString()}</p>
                            </div>
                          )}
                          {p.updated_at && (
                            <div>
                              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
                              <p className="text-theme-primary text-xs">{new Date(p.updated_at).toLocaleString()}</p>
                            </div>
                          )}
                        </div>

                        {/* Statements (match → action pairs) — the policy's own
                            compiled BGP route-map intent. Fetched lazily on
                            first expand. */}
                        <div className="mt-4">
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                            Statements ({p.statement_count})
                          </label>
                          {loadingDetail ? (
                            <div className="text-xs text-theme-secondary">Loading statements…</div>
                          ) : errDetail ? (
                            <div className="text-xs text-theme-danger-fg">{errDetail}</div>
                          ) : statements && statements.length > 0 ? (
                            <ol className="space-y-1">
                              {statements.map((s, idx) => (
                                <li
                                  key={idx}
                                  className="font-mono text-xs bg-theme-surface border border-theme rounded px-2 py-1"
                                >
                                  <span className="text-theme-secondary">{idx + 1}.</span>{' '}
                                  <span className="text-theme-info-fg">match</span> {matchSummary(s)}{' '}
                                  <span className="text-theme-success-fg">then</span> {actionSummary(s)}
                                </li>
                              ))}
                            </ol>
                          ) : (
                            <div className="text-xs text-theme-secondary">No statements defined.</div>
                          )}
                          <div className="mt-2 text-xs text-theme-secondary">
                            The compiled FRR route-map is rendered per neighbor at config-compile time. Use the MCP tool{' '}
                            <code className="font-mono">system_sdwan_compile_route_policy</code> with a peer to preview the
                            exact prefix-lists / route-maps FRR receives.
                          </div>
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
