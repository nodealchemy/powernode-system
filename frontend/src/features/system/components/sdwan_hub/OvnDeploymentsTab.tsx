import React, { useEffect, useState, useCallback } from 'react';
import { Layers, Shield } from 'lucide-react';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type {
  SdwanOvnAcl,
  SdwanOvnAclAction,
  SdwanOvnDeployment,
  SdwanOvnDeploymentStatus,
  SdwanOvnLogicalSwitch,
} from '@system/features/system/types/sdwan.types';

// Phase O6 — read-only operator view of the per-account OVN deployment.
// Phase O6 follow-up — extended to show nested logical switches with
// their ACLs (multi-tenant firewall rules) so operators have a single
// pane for "what does my OVN deployment actually look like".
//
// Composition happens through the SDWAN OVN Compose Topology / Apply
// ACL skills bound to the System Topology Designer agent, or via the
// system_sdwan_create_ovn_* MCP actions.
//
// OvnDeployment is per-account (DB-unique), so the tab fetches the
// summary list (max 1 row) and then drills into the full detail
// endpoint to get nested switches + ACLs in a single round trip.
export const OvnDeploymentsTab: React.FC = () => {
  const [deployment, setDeployment] = useState<SdwanOvnDeployment | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const summary = await sdwanApi.getOvnDeployments();
      const head = summary[0];
      if (!head) {
        setDeployment(null);
        return;
      }
      const { deployment: full } = await sdwanApi.getOvnDeployment(head.id);
      setDeployment(full);
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

  const totalAclCount = deployment.logical_switches.reduce((acc, s) => acc + (s.acls?.length ?? 0), 0);

  return (
    <div className="space-y-6">
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
            value={`${deployment.switch_count} switch${deployment.switch_count === 1 ? '' : 'es'} · ${deployment.port_count} port${deployment.port_count === 1 ? '' : 's'} · ${totalAclCount} ACL${totalAclCount === 1 ? '' : 's'}`}
          />
        </dl>
      </div>

      {deployment.logical_switches.length > 0 && (
        <div className="space-y-4">
          <h3 className="text-md font-medium text-theme-primary">Logical Switches</h3>
          {deployment.logical_switches.map((s) => (
            <SwitchCard key={s.id} switchData={s} />
          ))}
        </div>
      )}
    </div>
  );
};

interface SwitchCardProps {
  switchData: SdwanOvnLogicalSwitch;
}

const SwitchCard: React.FC<SwitchCardProps> = ({ switchData: s }) => {
  return (
    <div className="bg-theme-surface border border-theme rounded-lg p-4 space-y-3">
      <div className="flex items-center justify-between">
        <div>
          <span className="font-medium text-theme-primary">{s.name}</span>
          {s.cidr && <span className="ml-2 text-xs font-mono text-theme-secondary">{s.cidr}</span>}
        </div>
        <div className="flex items-center gap-2 text-xs text-theme-secondary">
          <span>{s.ports.length} port{s.ports.length === 1 ? '' : 's'}</span>
          <span>·</span>
          <span>{s.acls?.length ?? 0} ACL{(s.acls?.length ?? 0) === 1 ? '' : 's'}</span>
        </div>
      </div>

      {s.acls && s.acls.length > 0 && (
        <div className="border-t border-theme pt-3">
          <div className="flex items-center gap-2 mb-2">
            <Shield size={14} className="text-theme-accent" />
            <span className="text-xs uppercase tracking-wide text-theme-secondary">Firewall ACLs</span>
          </div>
          <table className="w-full text-xs">
            <thead className="text-theme-secondary">
              <tr>
                <th className="text-left p-1">Name</th>
                <th className="text-left p-1">Direction</th>
                <th className="text-right p-1">Priority</th>
                <th className="text-left p-1">Match</th>
                <th className="text-left p-1">Action</th>
              </tr>
            </thead>
            <tbody>
              {s.acls.map((acl) => (
                <AclRow key={acl.id} acl={acl} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
};

interface AclRowProps {
  acl: SdwanOvnAcl;
}

const AclRow: React.FC<AclRowProps> = ({ acl }) => (
  <tr className="border-t border-theme-border">
    <td className="p-1 text-theme-primary">{acl.name}</td>
    <td className="p-1 text-theme-secondary">{acl.direction}</td>
    <td className="p-1 text-right text-theme-secondary">{acl.priority}</td>
    <td className="p-1 font-mono text-theme-secondary truncate max-w-md" title={acl.match}>
      {acl.match}
    </td>
    <td className="p-1">
      <span className={actionBadgeClass(acl.action)}>{acl.action}</span>
    </td>
  </tr>
);

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

function actionBadgeClass(action: SdwanOvnAclAction): string {
  const base = 'px-1.5 py-0.5 rounded text-xs font-medium';
  switch (action) {
    case 'allow':
    case 'allow-related':
      return `${base} bg-theme-success text-theme-success`;
    case 'drop':
      return `${base} bg-theme-warning text-theme-warning`;
    case 'reject':
      return `${base} bg-theme-danger text-theme-danger`;
    default:
      return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}
