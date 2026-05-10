import React, { useEffect, useState, useCallback } from 'react';
import { Layers } from 'lucide-react';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type {
  SdwanOvnDeploymentStatus,
  SdwanOvnDeploymentSummary,
} from '@system/features/system/types/sdwan.types';

// Phase O6 — read-only operator view of the per-account OVN deployment.
// Composition happens through the SDWAN OVN Compose Topology skill /
// system_sdwan_create_ovn_deployment MCP action.
//
// OvnDeployment is per-account by DB unique index, so this tab renders
// at most one card. Future work: drill-down to a deployment-detail page
// that shows nested switches, ports, and the compiled ovn-nbctl plan.
// For now operators wanting that view can hit the API directly:
//   GET /api/v1/system/sdwan/ovn_deployments/:id
export const OvnDeploymentsTab: React.FC = () => {
  const [deployment, setDeployment] = useState<SdwanOvnDeploymentSummary | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const result = await sdwanApi.getOvnDeployments();
      setDeployment(result[0] ?? null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load OVN deployment');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  if (loading) {
    return <div className="p-8 text-center text-theme-secondary">Loading OVN deployment…</div>;
  }
  if (error) {
    return <div className="p-4 bg-theme-danger text-theme-danger rounded">{error}</div>;
  }
  if (!deployment) {
    return (
      <div className="p-12 text-center">
        <Layers className="mx-auto mb-4 text-theme-secondary" size={48} />
        <h3 className="text-lg font-medium text-theme-primary mb-2">No OVN deployment yet</h3>
        <p className="text-theme-secondary">
          OVN deployments are heavyweight-profile only. Compose one with the SDWAN OVN
          Compose Topology skill or the <code className="text-xs">system_sdwan_create_ovn_deployment</code>{' '}
          MCP action.
        </p>
      </div>
    );
  }

  return (
    <div className="bg-theme-surface border border-theme rounded-lg p-6 space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <Layers className="text-theme-accent" size={24} />
          <div>
            <h3 className="text-lg font-medium text-theme-primary">OVN Deployment</h3>
            <p className="text-xs text-theme-secondary font-mono">{deployment.id}</p>
          </div>
        </div>
        <span className={statusBadgeClass(deployment.status)}>{deployment.status}</span>
      </div>

      <dl className="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
        <DetailField label="NB DB endpoint" value={deployment.nb_db_endpoint} mono />
        <DetailField label="SB DB endpoint" value={deployment.sb_db_endpoint} mono />
        <DetailField label="northd host" value={deployment.northd_host ?? '—'} mono />
        <DetailField
          label="Logical topology"
          value={`${deployment.switch_count} switch${deployment.switch_count === 1 ? '' : 'es'} · ${deployment.port_count} port${deployment.port_count === 1 ? '' : 's'}`}
        />
        {deployment.bootstrapped_at && (
          <DetailField label="Bootstrapped" value={new Date(deployment.bootstrapped_at).toLocaleString()} />
        )}
        {deployment.activated_at && (
          <DetailField label="Activated" value={new Date(deployment.activated_at).toLocaleString()} />
        )}
        {deployment.degraded_at && (
          <DetailField label="Degraded since" value={new Date(deployment.degraded_at).toLocaleString()} />
        )}
      </dl>
    </div>
  );
};

interface DetailFieldProps {
  label: string;
  value: string;
  mono?: boolean;
}

const DetailField: React.FC<DetailFieldProps> = ({ label, value, mono }) => (
  <div>
    <dt className="text-theme-secondary text-xs uppercase tracking-wide">{label}</dt>
    <dd className={'text-theme-primary mt-1 ' + (mono ? 'font-mono text-xs' : '')}>{value}</dd>
  </div>
);

function statusBadgeClass(status: SdwanOvnDeploymentStatus): string {
  const base = 'px-3 py-1 rounded text-sm font-medium';
  switch (status) {
    case 'active':
      return `${base} bg-theme-success text-theme-success`;
    case 'bootstrapping':
      return `${base} bg-theme-info text-theme-info`;
    case 'pending':
      return `${base} bg-theme-background-secondary text-theme-secondary`;
    case 'degraded':
      return `${base} bg-theme-danger text-theme-danger`;
    default:
      return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}
