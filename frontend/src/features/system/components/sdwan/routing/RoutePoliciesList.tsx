import React, { useEffect, useState, useCallback } from 'react';
import { Filter, Pencil, Trash2, Power, PowerOff } from 'lucide-react';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanRoutePolicy } from '../../../types/sdwan.types';

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
      return 'bg-theme-info text-theme-info';
    case 'peer':
      return 'bg-theme-warning text-theme-warning';
    default:
      return 'bg-theme-background-secondary';
  }
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
        <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>
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
              <th className="px-3 py-2">Name</th>
              <th className="px-3 py-2">Scope</th>
              <th className="px-3 py-2">Direction</th>
              <th className="px-3 py-2">Statements</th>
              <th className="px-3 py-2">Enabled</th>
              <th className="px-3 py-2 text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            {policies.map((p) => (
              <tr key={p.id} className="border-b border-theme hover:bg-theme-background-secondary/30">
                <td className="px-3 py-2">
                  <div className="font-medium text-theme-primary">{p.name}</div>
                  {p.description && <div className="text-xs text-theme-secondary">{p.description}</div>}
                </td>
                <td className="px-3 py-2">
                  <span className={`text-xs font-medium px-2 py-0.5 rounded ${scopeColor(p.scope)}`}>
                    {p.scope}
                  </span>
                  {p.scope_resource_id && (
                    <div className="font-mono text-xs text-theme-secondary mt-0.5">
                      {p.scope_resource_id.slice(0, 8)}
                    </div>
                  )}
                </td>
                <td className="px-3 py-2 text-xs">
                  <span className={p.direction === 'import' ? 'text-theme-info' : 'text-theme-success'}>
                    {p.direction}
                  </span>
                </td>
                <td className="px-3 py-2 text-xs">{p.statement_count}</td>
                <td className="px-3 py-2">
                  {p.enabled ? (
                    <Power size={14} className="text-theme-success" />
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
                        className="p-1 hover:bg-theme-background-secondary rounded text-theme-danger"
                        title="Delete"
                      >
                        <Trash2 size={14} />
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
};
