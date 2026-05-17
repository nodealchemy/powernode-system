import React, { useCallback, useEffect, useState } from 'react';
import {
  TrendingUp,
  AlertTriangle,
  X,
  RefreshCw,
  Check,
  Edit2,
  Minus,
  Plus,
} from 'lucide-react';
import { platformDeploymentsApi } from '../../services/api/platformDeploymentsApi';
import type {
  DeploymentSummary,
  ServiceRole,
} from '../../types/deployment.types';

/**
 * Scaling panel — operator surface for adjusting platform-component
 * replica counts. Lists PlatformDeployment rows with target vs actual
 * replicas; supports inline target_replicas editing. Actual provisioning
 * orchestration (when target > actual) is queued for a follow-up slice
 * — for now the panel records intent + emits a FleetEvent the operator
 * follows up on via existing provisioning surfaces.
 *
 * Plan reference: Decentralized Federation §G + §I + P7.3.
 */
export const ScalingPanel: React.FC = () => {
  const [deployments, setDeployments] = useState<DeploymentSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [pendingValue, setPendingValue] = useState<string>('');
  const [savingId, setSavingId] = useState<string | null>(null);

  const fetchDeployments = useCallback(async () => {
    setError(null);
    try {
      const result = await platformDeploymentsApi.list();
      setDeployments(result.deployments);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load deployments');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void fetchDeployments();
  }, [fetchDeployments]);

  const handleStartEdit = (deployment: DeploymentSummary) => {
    setEditingId(deployment.id);
    setPendingValue(String(deployment.target_replicas));
  };

  const handleCancelEdit = () => {
    setEditingId(null);
    setPendingValue('');
  };

  const handleSave = async (deployment: DeploymentSummary) => {
    const next = parseInt(pendingValue, 10);
    if (!Number.isFinite(next) || next < 0) {
      setError('target_replicas must be a non-negative integer');
      return;
    }
    if (next === deployment.target_replicas) {
      handleCancelEdit();
      return;
    }
    setSavingId(deployment.id);
    setError(null);
    try {
      await platformDeploymentsApi.update(deployment.id, { target_replicas: next });
      await fetchDeployments();
      handleCancelEdit();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Update failed');
    } finally {
      setSavingId(null);
    }
  };

  const handleNudge = async (deployment: DeploymentSummary, delta: number) => {
    const next = Math.max(0, deployment.target_replicas + delta);
    if (next === deployment.target_replicas) return;
    setSavingId(deployment.id);
    setError(null);
    try {
      await platformDeploymentsApi.update(deployment.id, { target_replicas: next });
      await fetchDeployments();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Update failed');
    } finally {
      setSavingId(null);
    }
  };

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <TrendingUp className="w-5 h-5 text-theme-info" />
          <h2 className="font-semibold text-theme-primary">Deployments</h2>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${deployments.length} component${deployments.length === 1 ? '' : 's'}`}
          </span>
        </div>
        <button
          type="button"
          onClick={() => void fetchDeployments()}
          disabled={loading}
          title="Refresh"
          className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
        >
          <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
        </button>
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

      {!loading && deployments.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm">
          No platform deployments declared yet. Deployments are created when
          you provision a platform-component NodeInstance — e.g. via
          <code className="font-mono mx-1">powernode-hub-api</code> template.
        </div>
      )}

      {deployments.length > 0 && (
        <table className="w-full text-sm">
          <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
            <tr>
              <th className="text-left px-4 py-2 font-medium">Name</th>
              <th className="text-left px-4 py-2 font-medium">Role</th>
              <th className="text-left px-4 py-2 font-medium">Template</th>
              <th className="text-left px-4 py-2 font-medium">VIP</th>
              <th className="text-left px-4 py-2 font-medium">Replicas</th>
              <th className="text-right px-4 py-2 font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {deployments.map((deployment) => (
              <DeploymentRow
                key={deployment.id}
                deployment={deployment}
                isEditing={editingId === deployment.id}
                isSaving={savingId === deployment.id}
                pendingValue={pendingValue}
                onStartEdit={() => handleStartEdit(deployment)}
                onCancelEdit={handleCancelEdit}
                onPendingChange={setPendingValue}
                onSave={() => handleSave(deployment)}
                onNudge={(delta) => handleNudge(deployment, delta)}
              />
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
};

interface DeploymentRowProps {
  deployment: DeploymentSummary;
  isEditing: boolean;
  isSaving: boolean;
  pendingValue: string;
  onStartEdit: () => void;
  onCancelEdit: () => void;
  onPendingChange: (v: string) => void;
  onSave: () => void;
  onNudge: (delta: number) => void;
}

const DeploymentRow: React.FC<DeploymentRowProps> = ({
  deployment,
  isEditing,
  isSaving,
  pendingValue,
  onStartEdit,
  onCancelEdit,
  onPendingChange,
  onSave,
  onNudge,
}) => {
  const drift = deployment.actual_replicas - deployment.target_replicas;
  const driftClass =
    drift === 0
      ? 'text-theme-secondary'
      : drift > 0
        ? 'text-theme-warning'
        : 'text-theme-danger';

  return (
    <tr className="border-t border-theme">
      <td className="px-4 py-3 text-theme-primary font-mono text-xs">{deployment.name}</td>
      <td className="px-4 py-3"><RoleBadge role={deployment.service_role} /></td>
      <td className="px-4 py-3 text-xs text-theme-secondary">
        {deployment.node_template?.slug || deployment.node_template?.name || (
          <span className="text-theme-tertiary">—</span>
        )}
      </td>
      <td className="px-4 py-3 text-xs text-theme-secondary font-mono">
        {deployment.virtual_ip?.cidr || <span className="text-theme-tertiary">—</span>}
      </td>
      <td className="px-4 py-3 text-xs">
        <div className="flex items-center gap-3">
          {isEditing ? (
            <input
              type="number"
              min={0}
              value={pendingValue}
              onChange={(e) => onPendingChange(e.target.value)}
              disabled={isSaving}
              autoFocus
              className="w-16 px-2 py-1 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-xs"
              onKeyDown={(e) => {
                if (e.key === 'Enter') onSave();
                if (e.key === 'Escape') onCancelEdit();
              }}
            />
          ) : (
            <div className="inline-flex items-center gap-1">
              <button
                type="button"
                onClick={() => onNudge(-1)}
                disabled={isSaving || deployment.target_replicas === 0}
                className="p-0.5 rounded text-theme-secondary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
                title="Decrement target"
              >
                <Minus className="w-3 h-3" />
              </button>
              <span className="font-mono text-theme-primary tabular-nums w-6 text-center">
                {deployment.target_replicas}
              </span>
              <button
                type="button"
                onClick={() => onNudge(+1)}
                disabled={isSaving}
                className="p-0.5 rounded text-theme-secondary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
                title="Increment target"
              >
                <Plus className="w-3 h-3" />
              </button>
            </div>
          )}
          <span className="text-theme-tertiary">target</span>
          <span className={`font-mono tabular-nums ${driftClass}`} title="actual replicas">
            ({deployment.actual_replicas} live)
          </span>
        </div>
      </td>
      <td className="px-4 py-3 text-right">
        {isEditing ? (
          <div className="inline-flex items-center gap-1">
            <button
              type="button"
              onClick={onSave}
              disabled={isSaving}
              className="px-2 py-1 rounded text-xs text-theme-success hover:bg-theme-surface-hover inline-flex items-center gap-1 transition-colors"
            >
              <Check className="w-3 h-3" />
              {isSaving ? 'Saving…' : 'Save'}
            </button>
            <button
              type="button"
              onClick={onCancelEdit}
              disabled={isSaving}
              className="px-2 py-1 rounded text-xs text-theme-secondary hover:bg-theme-surface-hover transition-colors"
            >
              Cancel
            </button>
          </div>
        ) : (
          <button
            type="button"
            onClick={onStartEdit}
            className="p-1 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors"
            title="Edit target_replicas"
          >
            <Edit2 className="w-3 h-3" />
          </button>
        )}
      </td>
    </tr>
  );
};

const ROLE_LABELS: Record<ServiceRole, string> = {
  api: 'api',
  worker: 'worker',
  frontend: 'frontend',
  postgres: 'postgres',
  redis: 'redis',
  'reverse-proxy': 'reverse-proxy',
  'satellite-runtime': 'satellite',
};

const RoleBadge: React.FC<{ role: ServiceRole }> = ({ role }) => (
  <span className="px-1.5 py-0.5 bg-theme-background-secondary rounded text-xs font-mono">
    {ROLE_LABELS[role]}
  </span>
);
