import React, { useCallback, useEffect, useState } from 'react';
import {
  Server,
  AlertTriangle,
  X,
  Plus,
  Clock,
  Trash2,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { childrenApi } from '../../services/api/childrenApi';
import type {
  ChildPeerSummary,
  ChildPeerStatus,
  SpawnMode,
} from '../../types/spawn.types';

/**
 * Operator-side panel: list this platform's spawned children +
 * launch new spawns. Plan reference: Decentralized Federation §H + P6.
 */

interface ChildrenPanelProps {
  refreshKey?: number;
  onSpawnClick?: () => void;
  onSelect?: (child: ChildPeerSummary) => void;
}

export const ChildrenPanel: React.FC<ChildrenPanelProps> = ({
  refreshKey = 0,
  onSpawnClick,
  onSelect,
}) => {
  const [children, setChildren] = useState<ChildPeerSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<ChildPeerStatus | null>(null);
  const [revokingId, setRevokingId] = useState<string | null>(null);

  const fetchChildren = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await childrenApi.listChildren(
        statusFilter ? { status: statusFilter } : undefined,
      );
      setChildren(result.children);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load children');
    } finally {
      setLoading(false);
    }
  }, [statusFilter]);

  useEffect(() => {
    void fetchChildren();
  }, [fetchChildren, refreshKey]);

  const handleRevoke = async (child: ChildPeerSummary) => {
    const reason = window.prompt(
      `Revoke spawned child "${child.remote_instance_url}"?\n\n` +
        'This is terminal: subsequent federation_api calls from the child fail. ' +
        'Optional reason:',
      '',
    );
    if (reason === null) return;
    setRevokingId(child.id);
    try {
      await childrenApi.revoke(child.id, reason || undefined);
      await fetchChildren();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to revoke child');
    } finally {
      setRevokingId(null);
    }
  };

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Server className="w-5 h-5 text-theme-info" />
          <h2 className="font-semibold text-theme-primary">Children</h2>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${children.length} ${children.length === 1 ? 'child' : 'children'}`}
          </span>
        </div>
        <div className="flex items-center gap-2">
          <StatusFilterBar value={statusFilter} onChange={setStatusFilter} />
          {onSpawnClick && (
            <Button variant="primary" onClick={onSpawnClick}>
              <Plus className="w-4 h-4" />
              Spawn Platform
            </Button>
          )}
        </div>
      </header>

      {error && (
        <div className="p-3 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm">
          <AlertTriangle className="w-4 h-4 flex-shrink-0" />
          <span className="flex-1">{error}</span>
          <button type="button" onClick={() => setError(null)} className="p-1">
            <X className="w-3 h-3" />
          </button>
        </div>
      )}

      {!loading && children.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm">
          No spawned children yet. Click "Spawn Platform" to provision one.
        </div>
      )}

      {children.length > 0 && (
        <table className="w-full text-sm">
          <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
            <tr>
              <th className="text-left px-4 py-2 font-medium">Instance URL</th>
              <th className="text-left px-4 py-2 font-medium">Spawn Mode</th>
              <th className="text-left px-4 py-2 font-medium">Status</th>
              <th className="text-left px-4 py-2 font-medium">Spawn Pending</th>
              <th className="text-left px-4 py-2 font-medium">Last Heartbeat</th>
              <th className="text-right px-4 py-2 font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {children.map((child) => (
              <ChildRow
                key={child.id}
                child={child}
                onSelect={onSelect}
                onRevoke={() => handleRevoke(child)}
                isRevoking={revokingId === child.id}
              />
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
};

interface ChildRowProps {
  child: ChildPeerSummary;
  onSelect?: (child: ChildPeerSummary) => void;
  onRevoke: () => void;
  isRevoking: boolean;
}

const ChildRow: React.FC<ChildRowProps> = ({ child, onSelect, onRevoke, isRevoking }) => {
  const isTerminal = child.status === 'revoked';

  return (
    <tr
      className={`border-t border-theme ${onSelect ? 'cursor-pointer hover:bg-theme-surface-hover' : ''}`}
      onClick={() => onSelect?.(child)}
    >
      <td className="px-4 py-3 text-theme-primary font-mono text-xs">{child.remote_instance_url}</td>
      <td className="px-4 py-3 text-theme-secondary">
        <SpawnModeBadge mode={child.spawn_mode} />
      </td>
      <td className="px-4 py-3">
        <StatusPill status={child.status} />
      </td>
      <td className="px-4 py-3 text-xs text-theme-secondary">
        {child.acceptance_pending ? (
          <span className="text-theme-warning">
            yes (expires {child.acceptance_expires_at ? new Date(child.acceptance_expires_at).toLocaleString() : '—'})
          </span>
        ) : (
          <span className="text-theme-tertiary">no</span>
        )}
      </td>
      <td className="px-4 py-3 text-xs text-theme-secondary">
        {child.last_heartbeat_at ? (
          <span className="inline-flex items-center gap-1">
            <Clock className="w-3 h-3" />
            {new Date(child.last_heartbeat_at).toLocaleString()}
          </span>
        ) : (
          <span className="text-theme-tertiary">—</span>
        )}
      </td>
      <td className="px-4 py-3 text-right" onClick={(e) => e.stopPropagation()}>
        {!isTerminal && (
          <button
            type="button"
            onClick={onRevoke}
            disabled={isRevoking}
            title="Revoke child"
            className="px-2 py-1 rounded text-xs text-theme-danger hover:bg-theme-danger disabled:opacity-40 inline-flex items-center gap-1"
          >
            <Trash2 className="w-3 h-3" />
            {isRevoking ? 'Revoking…' : 'Revoke'}
          </button>
        )}
      </td>
    </tr>
  );
};

const SPAWN_MODE_LABELS: Record<SpawnMode, string> = {
  managed_child: 'managed',
  autonomous_peer: 'autonomous',
  cluster_member: 'cluster',
};

const SpawnModeBadge: React.FC<{ mode: SpawnMode }> = ({ mode }) => (
  <span className="px-1.5 py-0.5 bg-theme-background-secondary rounded text-xs font-mono">
    {SPAWN_MODE_LABELS[mode]}
  </span>
);

const STATUS_FILTERS: Array<{ value: ChildPeerStatus | null; label: string }> = [
  { value: null, label: 'All' },
  { value: 'proposed', label: 'Proposed' },
  { value: 'accepted', label: 'Accepted' },
  { value: 'enrolled', label: 'Enrolled' },
  { value: 'active', label: 'Active' },
  { value: 'degraded', label: 'Degraded' },
  { value: 'revoked', label: 'Revoked' },
];

const StatusFilterBar: React.FC<{
  value: ChildPeerStatus | null;
  onChange: (v: ChildPeerStatus | null) => void;
}> = ({ value, onChange }) => (
  <div className="inline-flex items-center gap-1 text-xs">
    {STATUS_FILTERS.map((f) => (
      <button
        type="button"
        key={f.label}
        onClick={() => onChange(f.value)}
        className={`px-2 py-1 rounded ${
          value === f.value
            ? 'bg-theme-info-solid text-white'
            : 'text-theme-secondary hover:bg-theme-surface-hover'
        }`}
      >
        {f.label}
      </button>
    ))}
  </div>
);

const StatusPill: React.FC<{ status: ChildPeerStatus }> = ({ status }) => {
  const styleByStatus: Record<ChildPeerStatus, string> = {
    proposed: 'bg-theme-background-tertiary text-theme-secondary',
    accepted: 'bg-theme-info text-theme-info',
    enrolled: 'bg-theme-info text-theme-info',
    active: 'bg-theme-success text-theme-success',
    degraded: 'bg-theme-warning text-theme-warning',
    suspended: 'bg-theme-warning text-theme-warning',
    revoked: 'bg-theme-danger text-theme-danger',
  };
  return (
    <span className={`inline-block px-2 py-0.5 rounded text-xs font-medium ${styleByStatus[status]}`}>
      {status}
    </span>
  );
};
