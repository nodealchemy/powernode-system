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
import { systemPolicyBucket } from '@system/features/system/autonomyBucket';
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

/**
 * The pivot's catch-all bucket, which this modal does not render.
 *
 * GET /api/v1/system/autonomy is an ACCOUNT-WIDE policy view: it returns every
 * `Ai::InterventionPolicy` row on the account, and it must keep doing so —
 * filtering rows out of an account-wide view is the same defect class as the
 * by_agent pivot silently dropping agents. Core seeds six of its own global
 * rows (`approval`, `proposal`, `escalation`, `status_update`, `issue_alert`,
 * `feedback` — server/db/seeds/autonomy_data_seed.rb) and every `dev.*`
 * category is core's too; none matches a DOMAIN_PREFIXES entry, so all of them
 * land here. They are not the System extension's to configure.
 *
 * So the split is: the API returns everything, and the extension's modal picks
 * what it owns. Do NOT move this filter into the endpoint.
 *
 * Dropping the bucket wholesale is safe only because no SYSTEM category can
 * reach it — spec/controllers/api/v1/system/autonomy_domain_pivot_spec.rb pins
 * that every seeded category files under a named domain, and that spec is what
 * fails if a new family ever lands without a prefix.
 */
const FOREIGN_DOMAIN_KEY = 'other';

/**
 * Sidebar order.
 *
 * The server's key order is DOMAIN_PREFIXES' order, which exists for
 * prefix-shadowing CORRECTNESS — an entry whose prefix extends another's has to
 * be declared first, which is why `instance_pool` leads and `node_lifecycle`
 * comes last. That is not operator priority, and reading it as a running order
 * opens the modal on Instance Pools. Order by this file's presentation order
 * instead and append anything it does not recognise; `sort` is stable, so
 * unknown keys keep the server's relative order among themselves.
 */
const SECTION_ORDER = Object.keys(DOMAIN_PRESENTATION);

function sectionRank(key: string): number {
  const index = SECTION_ORDER.indexOf(key);
  return index === -1 ? SECTION_ORDER.length : index;
}

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
  /**
   * Categories the payload did not let us place in any group. Kept apart from
   * `groups` so nothing can render them through the editor by accident, and so
   * they cannot collide with a group key — a group key is an agent's NAME, and
   * `Ai::Agent` validates no format, so any sentinel name we invented would be
   * one a real agent could hold.
   */
  unreadableActions: string[];
}

/**
 * One editor group per agent bucket present in the domain, because a policy row
 * is per (category, scope, agent): the same category is commonly seeded twice —
 * once agent-scoped and once for the operator path — and they can hold
 * different verbs.
 *
 * `systemPolicyBucket` is the single authority for which bucket a row is in —
 * the same function `useAutonomyConfig` reads verbs and row identities with, so
 * a group here always has a verb there. A MISSING `agent_bucket` is not
 * "Manual Operations" (IMP-82b43009d57b); see that function for the whole
 * argument, and for why a row can be unplaceable.
 *
 * Unplaceable rows are RETURNED, not dropped. Dropping would be the same silent
 * misrepresentation with fewer rows: the operator would read a complete-looking
 * modal that omits real policy. A category can appear both in a group and in
 * `unreadable` — that is the honest reading, since it means one row for the
 * category was placeable and another was not.
 */
function buildGroups(rows: AutonomyDomainPolicy[]): {
  groups: AgentGroup[];
  unreadable: string[];
} {
  const byBucket = new Map<string, string[]>();
  const unreadable: string[] = [];

  rows.forEach((row) => {
    const bucket = systemPolicyBucket(row);

    if (bucket === null) {
      if (!unreadable.includes(row.action_category)) unreadable.push(row.action_category);
      return;
    }

    const actions = byBucket.get(bucket) || [];
    if (!actions.includes(row.action_category)) actions.push(row.action_category);
    byBucket.set(bucket, actions);
  });

  return {
    groups: Array.from(byBucket, ([bucket, actions]) => ({ bucket, actions })),
    unreadable,
  };
}

/**
 * The degraded, honest rendering of rows whose bucket could not be read.
 *
 * DELIBERATELY NOT an editor, and deliberately not hidden either. Three
 * treatments were on the table for undeterminable posture — render it editable
 * at a default, hide it, or show it read-only — and the first is the dangerous
 * one: an editable control asserts both a current verb and a row to write it to,
 * and here we have neither. Hiding trades a visible wrong answer for an
 * invisible one, which is the defect class this whole change is about. So the
 * rows are named, their posture is stated as unknown rather than guessed, and no
 * control offers to change them.
 *
 * The degradation is PARTIAL on purpose: the rest of the modal stays editable.
 * Rows we could place are correctly attributed and safe to save, and refusing
 * every save would deny the operator the fix for the rows they can still reach.
 */
function UnreadablePolicyGroup({ label, actions }: { label: string; actions: string[] }) {
  return (
    <div className="rounded-lg border border-theme-warning-border overflow-hidden">
      <div className="px-4 py-2.5 bg-theme-warning-bg flex items-center justify-between">
        <span className="text-xs font-semibold text-theme-warning-fg">{label}</span>
        <span className="text-[10px] text-theme-warning-fg">{actions.length} actions</span>
      </div>
      <div className="p-3 space-y-2">
        <p className="text-[11px] text-theme-secondary">
          The server did not say which agent owns these policy rows, so this modal cannot show
          their current setting and will not offer to change it. Their policies are unchanged and
          still in force. Update the System extension on the server to configure them here.
        </p>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-3 gap-y-1">
          {actions.map((action) => (
            <div key={action} className="flex items-center gap-1.5 py-0.5">
              <span className="text-xs text-theme-primary truncate flex-1 min-w-0">{action}</span>
              <span className="text-[11px] text-theme-tertiary shrink-0 w-[100px]">Unknown</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

const CHAINS_KEY = 'chains';

export const SystemSettingsPanel: React.FC<SystemSettingsPanelProps> = ({ isOpen, onClose }) => {
  const autonomy = useSystemAutonomyConfig();
  const [activeKey, setActiveKey] = useState<string>('');

  // Which domains become sections: everything the server sent EXCEPT the
  // foreign catch-all, minus the empties (the pivot ships every declared domain
  // whether or not the account has a row in it, and a domain with no rows has
  // nothing for an operator to tune). Presented in SECTION_ORDER, not the
  // server's key order — see both constants for why each rule exists.
  const sections = useMemo<DomainSection[]>(
    () =>
      Object.entries(autonomy.domains)
        .filter(
          ([key, rows]) =>
            key !== FOREIGN_DOMAIN_KEY && Array.isArray(rows) && rows.length > 0
        )
        .sort(([a], [b]) => sectionRank(a) - sectionRank(b))
        .map(([key, rows]) => {
          const { groups, unreadable } = buildGroups(rows);
          return {
            key,
            ...presentationFor(key),
            // Rows LISTED, not distinct categories — the established meaning of
            // this badge, which already counts a category twice when two buckets
            // each carry a row for it. Unreadable rows are listed too, so they
            // count: an operator comparing the badge against what they can see
            // must not find rows missing from the total.
            actionCount:
              groups.reduce((sum, g) => sum + g.actions.length, 0) + unreadable.length,
            groups,
            unreadableActions: unreadable,
          };
        }),
    [autonomy.domains]
  );

  const activeSection =
    activeKey === CHAINS_KEY ? undefined : sections.find((s) => s.key === activeKey) || sections[0];

  // Whether ANY section holds rows this modal could not place — not just the one
  // on screen. An operator who never opens the affected section would otherwise
  // read the modal as complete, and a partially-readable view is exactly the
  // state in which a save looks safe and is not.
  const hasUnreadableRows = useMemo(
    () => sections.some((s) => s.unreadableActions.length > 0),
    [sections]
  );

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
          {activeKey !== CHAINS_KEY && hasUnreadableRows && (
            <div
              data-testid="autonomy-skew-warning"
              className="mb-3 rounded border border-theme-warning-border bg-theme-warning-bg px-3 py-2"
            >
              <p className="text-xs text-theme-warning-fg">
                This view is incomplete. The server returned policy rows without the agent they
                belong to — a sign its System extension is older than this interface. Those rows are
                listed as <span className="font-semibold">Posture unknown</span> and cannot be read
                or changed here; everything else on this screen is accurate and safe to save.
              </p>
            </div>
          )}

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

              {/* Outside the map, so no key it uses can collide with an agent's
                  name and no future edit can hand these rows to the editor. */}
              {activeSection.unreadableActions.length > 0 && (
                <UnreadablePolicyGroup
                  label={`${activeSection.label} · Posture unknown`}
                  actions={activeSection.unreadableActions}
                />
              )}
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
