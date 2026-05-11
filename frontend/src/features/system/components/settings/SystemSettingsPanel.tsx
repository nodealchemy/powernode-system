import React, { useState } from 'react';
import {
  Server,
  Network,
  Container,
  HardDrive,
  Layers,
  ShieldAlert,
  UserCog,
  GitBranch,
} from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { AutonomyPolicyGroup } from '@/shared/components/autonomy/AutonomyPolicyGroup';
import { ApprovalChainList } from '@/shared/components/approval-chains/ApprovalChainList';
import { useSystemAutonomyConfig } from '@system/features/system/hooks/useSystemAutonomyConfig';

interface SystemSettingsPanelProps {
  isOpen: boolean;
  onClose: () => void;
}

interface DomainSection {
  key: string;
  label: string;
  agentName: string;
  icon: React.ElementType;
  description: string;
  actions: string[];
}

/**
 * 7-domain Settings modal for the System extension's autonomy framework.
 * Sidebar nav (left) + content pane (right) — at 5xl width with 8 sections
 * the horizontal tab strip wrapped awkwardly. Sidebar gives every section
 * the full content area for its policy table without cramming icons into
 * a 100%-width nav.
 */
const DOMAIN_SECTIONS: DomainSection[] = [
  {
    key: 'node_lifecycle',
    label: 'Node Lifecycle',
    agentName: 'Fleet Autonomy',
    icon: Server,
    description: 'Cert rotation, module assignment, instance reboot/reprovision/terminate, fleet-wide upgrades.',
    actions: [
      'system.cert_rotate', 'system.cert_revoke',
      'system.module_assign', 'system.module_promote_to_live',
      'system.instance_reboot', 'system.instance_reprovision', 'system.instance_terminate',
      'system.fleet_rolling_upgrade', 'system.region_expansion', 'system.capacity_resize',
    ],
  },
  {
    key: 'sdwan',
    label: 'SDWAN',
    agentName: 'SDWAN Manager',
    icon: Network,
    description: 'Networks, peers, firewall rules, VIPs, route policies, port mappings, access grants, federation.',
    actions: [
      'system.sdwan_peer_remediate', 'system.sdwan_key_rotate', 'system.sdwan_failover',
      'system.sdwan_user_device_revoke', 'system.sdwan_bgp_session_remediate',
      'system.sdwan_vip_failover', 'system.sdwan_route_policy_audit',
      'sdwan.network_create', 'sdwan.network_update', 'sdwan.network_delete',
      'sdwan.peer_create', 'sdwan.peer_update', 'sdwan.peer_delete',
      'sdwan.firewall_rule_create', 'sdwan.firewall_rule_update', 'sdwan.firewall_rule_delete',
      'sdwan.virtual_ip_create', 'sdwan.virtual_ip_update', 'sdwan.virtual_ip_delete',
      'sdwan.route_policy_create', 'sdwan.route_policy_update', 'sdwan.route_policy_delete',
      'sdwan.port_mapping_create', 'sdwan.port_mapping_update', 'sdwan.port_mapping_delete',
      'sdwan.access_grant_create', 'sdwan.access_grant_revoke',
      'sdwan.user_device_create',
      'sdwan.federation_peer_propose', 'sdwan.federation_peer_accept', 'sdwan.federation_peer_revoke',
    ],
  },
  {
    key: 'runtime',
    label: 'Container Runtimes',
    agentName: 'Runtime Manager',
    icon: Container,
    description: 'Docker daemon + K3s cluster lifecycle. TLS rotation, node join/drain, runtime upgrades.',
    actions: [
      'system.runtime_docker_provision', 'system.runtime_docker_decommission',
      'system.runtime_docker_tls_rotate',
      'system.runtime_k8s_cluster_bootstrap', 'system.runtime_k8s_cluster_decommission',
      'system.runtime_k8s_node_join', 'system.runtime_k8s_node_drain',
      'system.runtime_k8s_runtime_upgrade',
    ],
  },
  {
    key: 'disk_image',
    label: 'Disk Image CI',
    agentName: 'Disk Image Manager',
    icon: HardDrive,
    description: 'Publication promotion, rollback, retention, webhook lifecycle.',
    actions: [
      'system.disk_image_publication_promote',
      'system.disk_image_publication_rollback',
      'system.disk_image_retention_update',
      'system.disk_image_webhook_trigger',
      'system.disk_image_webhook_revoke',
      'system.disk_image_webhook_rotate_secret',
    ],
  },
  {
    key: 'instance_pool',
    label: 'Instance Pools',
    agentName: 'Fleet Autonomy',
    icon: Layers,
    description: 'Warm-pool create / update / delete / replenish / drain / acquire.',
    actions: [
      'system.instance_pool_create', 'system.instance_pool_update', 'system.instance_pool_delete',
      'system.instance_pool_replenish', 'system.instance_pool_drain', 'system.instance_pool_acquire',
    ],
  },
  {
    key: 'cve',
    label: 'CVE & Compliance',
    agentName: 'CVE Responder',
    icon: ShieldAlert,
    description: 'SBOM ingest, exposure scan, remediation orchestration.',
    actions: [
      'system.cve_remediate', 'system.cve_sbom_ingest',
      'system.cve_exposure_scan', 'system.cve_auto_remediate',
    ],
  },
  {
    key: 'manual',
    label: 'Manual Operations',
    agentName: 'Manual Operations',
    icon: UserCog,
    description: 'Operator-initiated System::Task commands (terminate, deprovision, snapshot, ssh_command, etc.).',
    actions: [
      'system.task.start', 'system.task.stop', 'system.task.restart', 'system.task.reboot',
      'system.task.terminate', 'system.task.provision', 'system.task.deprovision',
      'system.task.associate_public_ip', 'system.task.disassociate_public_ip',
      'system.task.create_volume', 'system.task.delete_volume',
      'system.task.attach_volume', 'system.task.detach_volume',
      'system.task.create_snapshot', 'system.task.delete_snapshot', 'system.task.restore_snapshot',
      'system.task.create_network', 'system.task.delete_network',
      'system.task.sync', 'system.task.sync_modules', 'system.task.apply_config',
      'system.task.build_module', 'system.task.commit_module',
      'system.task.ssh_command', 'system.task.backup', 'system.task.restore', 'system.task.custom',
    ],
  },
];

const CHAINS_KEY = 'chains';

export const SystemSettingsPanel: React.FC<SystemSettingsPanelProps> = ({ isOpen, onClose }) => {
  const autonomy = useSystemAutonomyConfig();
  const [activeKey, setActiveKey] = useState<string>('node_lifecycle');

  const activeSection = DOMAIN_SECTIONS.find((s) => s.key === activeKey);
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
      subtitle="Configure per-action intervention policies and approval chains"
    >
      <div className="flex gap-4 min-h-[60vh]">
        {/* Sidebar nav */}
        <nav className="w-56 shrink-0 border-r border-theme pr-2 -mr-2">
          <ul className="space-y-0.5">
            {DOMAIN_SECTIONS.map((s) => {
              const Icon = s.icon;
              const isActive = activeKey === s.key;
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
                    <Icon size={16} className={isActive ? 'text-theme-info' : 'text-theme-tertiary'} />
                    <span className="flex-1 truncate">{s.label}</span>
                    <span className="text-[10px] text-theme-tertiary tabular-nums">
                      {s.actions.length}
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
                  className={activeKey === CHAINS_KEY ? 'text-theme-info' : 'text-theme-tertiary'}
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
          ) : activeSection ? (
            <div className="space-y-3">
              <div>
                <div className="flex items-center gap-2">
                  <h3 className="text-sm font-semibold text-theme-primary">{activeSection.label}</h3>
                  <span className="text-xs px-2 py-0.5 rounded bg-theme-background-secondary text-theme-tertiary">
                    {activeSection.agentName}
                  </span>
                </div>
                <p className="text-xs text-theme-tertiary mt-1">{activeSection.description}</p>
              </div>

              {autonomy.loading ? (
                <p className="text-sm text-theme-tertiary py-6 text-center">Loading…</p>
              ) : (
                <AutonomyPolicyGroup
                  label={`${activeSection.label} policies`}
                  agentName={activeSection.agentName}
                  actions={activeSection.actions}
                  getPolicy={autonomy.getPolicy}
                  updatePolicy={autonomy.updatePolicy}
                  onDirty={() => { /* tracked via autonomy.isDirty */ }}
                  onSave={handleSave}
                  isDirty={autonomy.isDirty}
                />
              )}
            </div>
          ) : null}
        </div>
      </div>
    </Modal>
  );
};

export default SystemSettingsPanel;
