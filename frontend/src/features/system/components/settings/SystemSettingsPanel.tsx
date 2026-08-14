import React, { useMemo, useState } from 'react';
import {
  Server,
  Network,
  Container,
  HardDrive,
  Layers,
  ShieldAlert,
  GitBranch,
  Package,
  Boxes,
  Database,
  FolderKanban,
  Settings,
} from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { AutonomyPolicyGroup } from '@/shared/components/autonomy/AutonomyPolicyGroup';
import { ApprovalChainList } from '@/shared/components/approval-chains/ApprovalChainList';
import { useSystemAutonomyConfig } from '@system/features/system/hooks/useSystemAutonomyConfig';
import type { AutonomyDomainPolicy } from '@/shared/types/autonomy';

interface SystemSettingsPanelProps {
  isOpen: boolean;
  onClose: () => void;
}

interface DomainPresentation {
  label: string;
  icon: React.ElementType;
  description: string;
}

/**
 * PRESENTATION ONLY — label, icon and blurb per domain key.
 *
 * This map is deliberately NOT the source of truth for which actions exist. The
 * action categories are defined and seeded server-side; the modal's sections
 * and their rows come from the `by_domain` view of GET /api/v1/system/autonomy
 * (see `System::AutonomyActions::DOMAIN_PREFIXES`, which owns the bucketing).
 *
 * That split is the whole point. Until IMP-0874acd5b50c this file carried a
 * literal `actions: string[]` per section, and it had drifted to omit 28 of the
 * 119 seeded categories — every `project.*`, every `system.gitops_*`, every
 * `system.architecture.*` — while still rendering one control
 * (`system.runtime_docker_tls_rotate`) whose seed the 2026-05-19 audit deleted.
 * An operator could not view, tune or save any of the 28 from this modal, and
 * the ghost mapped to nothing. A hardcoded copy of a server-owned set drifts
 * again the day someone seeds a policy, so it is gone.
 *
 * A MISSING entry here is now cosmetic: an unrecognised domain key still renders
 * under a humanised label (see `presentationFor`), because losing the pretty
 * name is survivable and losing the rows is not. If a domain should be hidden
 * from operators, that curation belongs in DOMAIN_PREFIXES where the categories
 * are defined — not here.
 */
const DOMAIN_PRESENTATION: Record<string, DomainPresentation> = {
  node_lifecycle: {
    label: 'Node Lifecycle',
    icon: Server,
    description: 'Cert rotation, module assignment, instance reboot/reprovision/terminate, fleet-wide upgrades, operator tasks.',
  },
  sdwan: {
    label: 'SDWAN',
    icon: Network,
    description: 'Networks, peers, firewall rules, VIPs, route policies, port mappings, access grants, federation.',
  },
  container_runtime: {
    label: 'Container Runtimes',
    icon: Container,
    description: 'Docker daemon + K3s cluster lifecycle. Node join/drain, runtime upgrades.',
  },
  disk_image: {
    label: 'Disk Image CI',
    icon: HardDrive,
    description: 'Publication promotion, rollback, retention, webhook lifecycle.',
  },
  instance_pool: {
    label: 'Instance Pools',
    icon: Layers,
    description: 'Warm-pool create / update / delete / replenish / drain / acquire.',
  },
  cve: {
    label: 'CVE & Compliance',
    icon: ShieldAlert,
    description: 'SBOM ingest, exposure scan, remediation orchestration, critical-upgrade rollout.',
  },
  gitops: {
    label: 'GitOps',
    icon: GitBranch,
    description: 'Declarative fleet state: repository registration, sync, drift proposals and their application.',
  },
  packages: {
    label: 'Packages',
    icon: Package,
    description: 'Package repository sync and package-backed module create / refresh.',
  },
  architecture: {
    label: 'Architectures',
    icon: Boxes,
    description: 'Reference architecture catalog: propose, create, update, delete.',
  },
  storage: {
    label: 'Storage',
    icon: Database,
    description: 'Volume assignment reconciliation and storage ownership.',
  },
  project: {
    label: 'Project Adaptation',
    icon: FolderKanban,
    description: 'Provisioned-workload evolution: scale, cost control, relocation, schema and security changes.',
  },
};

/** Title-cases an unknown domain key so a new server bucket still reads as a name. */
function humanizeDomainKey(key: string): string {
  return key
    .split('_')
    .filter(Boolean)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');
}

function presentationFor(key: string): DomainPresentation {
  return (
    DOMAIN_PRESENTATION[key] || {
      label: humanizeDomainKey(key),
      icon: Settings,
      description: 'Policies the server groups under this domain.',
    }
  );
}

interface AgentGroup {
  bucket: string;
  actions: string[];
}

interface DomainSection extends DomainPresentation {
  key: string;
  actionCount: number;
  groups: AgentGroup[];
}

/**
 * One editor group per agent bucket present in the domain, because a policy row
 * is per (category, scope, agent): the same category is commonly seeded twice —
 * once agent-scoped and once for the operator path — and they can hold
 * different verbs. `agent_bucket` is the server's own by_agent grouping key,
 * shipped on the row so this does not re-derive it.
 */
function buildGroups(rows: AutonomyDomainPolicy[]): AgentGroup[] {
  const byBucket = new Map<string, string[]>();

  rows.forEach((row) => {
    const bucket = row.agent_bucket || 'Manual Operations';
    const actions = byBucket.get(bucket) || [];
    if (!actions.includes(row.action_category)) actions.push(row.action_category);
    byBucket.set(bucket, actions);
  });

  return Array.from(byBucket, ([bucket, actions]) => ({ bucket, actions }));
}

const CHAINS_KEY = 'chains';

export const SystemSettingsPanel: React.FC<SystemSettingsPanelProps> = ({ isOpen, onClose }) => {
  const autonomy = useSystemAutonomyConfig();
  const [activeKey, setActiveKey] = useState<string>('');

  // Sections follow the server's key order. An EMPTY bucket is dropped: the
  // pivot always ships every declared domain plus the "other" catch-all, and a
  // domain with no policy rows has nothing for an operator to tune.
  const sections = useMemo<DomainSection[]>(
    () =>
      Object.entries(autonomy.domains)
        .filter(([, rows]) => Array.isArray(rows) && rows.length > 0)
        .map(([key, rows]) => {
          const groups = buildGroups(rows);
          return {
            key,
            ...presentationFor(key),
            actionCount: groups.reduce((sum, g) => sum + g.actions.length, 0),
            groups,
          };
        }),
    [autonomy.domains]
  );

  const activeSection =
    activeKey === CHAINS_KEY ? undefined : sections.find((s) => s.key === activeKey) || sections[0];

  const handleSave = async () => {
    await autonomy.save();
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      variant="centered"
      size="6xl"
      title="System Autonomy Settings"
      icon={<Settings className="w-6 h-6" />}
      subtitle="Configure per-action intervention policies and approval chains"
    >
      <div className="flex gap-4 min-h-[60vh]">
        {/* Sidebar nav */}
        <nav className="w-56 shrink-0 border-r border-theme pr-2 -mr-2">
          <ul className="space-y-0.5">
            {sections.map((s) => {
              const Icon = s.icon;
              const isActive = activeSection?.key === s.key;
              return (
                <li key={s.key}>
                  <button
                    type="button"
                    onClick={() => setActiveKey(s.key)}
                    className={
                      'w-full flex items-center gap-2 px-3 py-2 rounded text-sm text-left transition-colors ' +
                      (isActive
                        ? 'bg-theme-surface-selected text-theme-primary font-medium'
                        : 'text-theme-secondary hover:bg-theme-surface-hover hover:text-theme-primary')
                    }
                  >
                    <Icon size={16} className={isActive ? 'text-theme-info-fg' : 'text-theme-tertiary'} />
                    <span className="flex-1 truncate">{s.label}</span>
                    <span className="text-[10px] text-theme-tertiary tabular-nums">
                      {s.actionCount}
                    </span>
                  </button>
                </li>
              );
            })}

            <li className="pt-2 mt-2 border-t border-theme">
              <button
                type="button"
                onClick={() => setActiveKey(CHAINS_KEY)}
                className={
                  'w-full flex items-center gap-2 px-3 py-2 rounded text-sm text-left transition-colors ' +
                  (activeKey === CHAINS_KEY
                    ? 'bg-theme-surface-selected text-theme-primary font-medium'
                    : 'text-theme-secondary hover:bg-theme-surface-hover hover:text-theme-primary')
                }
              >
                <GitBranch
                  size={16}
                  className={activeKey === CHAINS_KEY ? 'text-theme-info-fg' : 'text-theme-tertiary'}
                />
                <span className="flex-1 truncate">Approval Chains</span>
              </button>
            </li>
          </ul>
        </nav>

        {/* Content pane */}
        <div className="flex-1 min-w-0">
          {activeKey === CHAINS_KEY ? (
            <ApprovalChainList />
          ) : autonomy.loading ? (
            <p className="text-sm text-theme-tertiary py-6 text-center">Loading…</p>
          ) : activeSection ? (
            <div className="space-y-3">
              <div>
                <h3 className="text-sm font-semibold text-theme-primary">{activeSection.label}</h3>
                <p className="text-xs text-theme-tertiary mt-1">{activeSection.description}</p>
              </div>

              {activeSection.groups.map((group) => (
                <AutonomyPolicyGroup
                  key={group.bucket}
                  label={`${activeSection.label} · ${group.bucket}`}
                  agentName={group.bucket}
                  actions={group.actions}
                  getPolicy={autonomy.getPolicy}
                  updatePolicy={autonomy.updatePolicy}
                  onDirty={() => { /* tracked via autonomy.isDirty */ }}
                  onSave={handleSave}
                  isDirty={autonomy.isDirty}
                />
              ))}
            </div>
          ) : (
            <p className="text-sm text-theme-tertiary py-6 text-center">
              No autonomy policies are configured for this account yet.
            </p>
          )}
        </div>
      </div>
    </Modal>
  );
};

export default SystemSettingsPanel;
