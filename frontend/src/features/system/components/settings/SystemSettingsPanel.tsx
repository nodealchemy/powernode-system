import React, { useState } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/shared/components/ui/Tabs';
import { AutonomyPolicyGroup } from '@/shared/components/autonomy/AutonomyPolicyGroup';
import { ApprovalChainList } from '@/shared/components/approval-chains/ApprovalChainList';
import { useSystemAutonomyConfig } from '@system/features/system/hooks/useSystemAutonomyConfig';

interface SystemSettingsPanelProps {
  isOpen: boolean;
  onClose: () => void;
}

/**
 * 7-domain Settings modal for the System extension's autonomy framework.
 * Operators configure per-action intervention policies + assign multi-step
 * approval chains. Tabs are organized by domain (Node Lifecycle / SDWAN /
 * Container Runtimes / Disk Image / Instance Pools / CVE / Approval Chains)
 * — the per-action UI is identical across tabs.
 */
const DOMAIN_TABS: Array<{ key: string; label: string; agentName: string; actions: string[] }> = [
  {
    key: 'node_lifecycle',
    label: 'Node Lifecycle',
    agentName: 'Fleet Autonomy',
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
    actions: [
      'system.disk_image_publication_promote',
      'system.disk_image_publication_rollback',
      'system.disk_image_retention_update',
      'system.disk_image_webhook_trigger',
    ],
  },
  {
    key: 'instance_pool',
    label: 'Instance Pools',
    agentName: 'Fleet Autonomy',
    actions: [
      'system.instance_pool_create', 'system.instance_pool_update', 'system.instance_pool_delete',
      'system.instance_pool_replenish', 'system.instance_pool_drain', 'system.instance_pool_acquire',
    ],
  },
  {
    key: 'cve',
    label: 'CVE & Compliance',
    agentName: 'CVE Responder',
    actions: [
      'system.cve_remediate', 'system.cve_sbom_ingest',
      'system.cve_exposure_scan', 'system.cve_auto_remediate',
    ],
  },
  {
    key: 'manual',
    label: 'Manual Operations',
    agentName: 'Manual Operations',
    actions: [
      'system.task.terminate', 'system.task.deprovision',
      'system.task.delete_volume', 'system.task.delete_snapshot',
      'system.task.restore_snapshot', 'system.task.delete_network',
      'system.task.ssh_command', 'system.task.restore', 'system.task.custom',
      'system.task.start', 'system.task.stop', 'system.task.restart',
    ],
  },
];

export const SystemSettingsPanel: React.FC<SystemSettingsPanelProps> = ({ isOpen, onClose }) => {
  const autonomy = useSystemAutonomyConfig();
  const [activeTab, setActiveTab] = useState<string>('node_lifecycle');

  const handleSave = async () => {
    await autonomy.save();
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      variant="centered"
      size="3xl"
      title="System Autonomy Settings"
      subtitle="Configure per-action intervention policies and approval chains"
    >
      <Tabs value={activeTab} onValueChange={setActiveTab}>
        <TabsList className="mb-4 flex-wrap">
          {DOMAIN_TABS.map((t) => (
            <TabsTrigger key={t.key} value={t.key}>
              {t.label}
            </TabsTrigger>
          ))}
          <TabsTrigger value="chains">Approval Chains</TabsTrigger>
        </TabsList>

        {DOMAIN_TABS.map((tab) => (
          <TabsContent key={tab.key} value={tab.key}>
            {autonomy.loading ? (
              <p className="text-sm text-theme-tertiary py-6 text-center">Loading…</p>
            ) : (
              <AutonomyPolicyGroup
                label={`${tab.label} (owner: ${tab.agentName})`}
                agentName={tab.agentName}
                actions={tab.actions}
                getPolicy={autonomy.getPolicy}
                updatePolicy={autonomy.updatePolicy}
                onDirty={() => { /* tracked via autonomy.isDirty */ }}
                onSave={handleSave}
                isDirty={autonomy.isDirty}
              />
            )}
          </TabsContent>
        ))}

        <TabsContent value="chains">
          <ApprovalChainList />
        </TabsContent>
      </Tabs>
    </Modal>
  );
};

export default SystemSettingsPanel;
