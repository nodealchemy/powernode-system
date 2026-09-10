import React from 'react';
import { Cpu, Plus, Copy, Check, Link2, Unlink, Loader2, ChevronRight, ChevronDown, Download, Edit, Trash2 } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import type { SystemNodeInstance } from '@system/features/system/types/system.types';
import { getStatusBadge } from './nodeDetailHelpers';
import NodeInstanceControls from './NodeInstanceControls';
import { BootImageDriftBadge } from './BootImageDriftBadge';
import { ClaudeCodeCredentialPanel } from './ClaudeCodeCredentialPanel';

export interface NodeInstancesTabProps {
  nodeId: string | null;
  instances: SystemNodeInstance[];
  expandedInstanceIds: Set<string>;
  onToggleExpand: (id: string) => void;
  canCreateInstances: boolean;
  canUpdateInstances: boolean;
  canDeleteInstances: boolean;
  canControlInstances: boolean;
  onAddInstance: () => void;
  onEditInstance: (instance: SystemNodeInstance) => void;
  onInstanceActionComplete: () => void;
  bootConfigInFlight: string | null;
  onDownloadBootConfig: (instance: SystemNodeInstance) => void;
  copiedField: string | null;
  onCopyIp: (ip: string, type: string, instanceId: string) => void;
  armedAction: string | null;
  onArmOrFire: (key: string, fire: () => void) => void;
  ipActionInFlight: string | null;
  onIpAction: (instance: SystemNodeInstance, action: 'associate' | 'disassociate') => void;
  onCredentialDialogChange: (open: boolean) => void;
  deleteInstanceConfirm: SystemNodeInstance | null;
  onDeleteRequest: (instance: SystemNodeInstance) => void;
  onDeleteCancel: () => void;
  deletingInstance: boolean;
  onConfirmDelete: () => void;
}

export const NodeInstancesTab: React.FC<NodeInstancesTabProps> = ({
  nodeId,
  instances,
  expandedInstanceIds,
  onToggleExpand,
  canCreateInstances,
  canUpdateInstances,
  canDeleteInstances,
  canControlInstances,
  onAddInstance,
  onEditInstance,
  onInstanceActionComplete,
  bootConfigInFlight,
  onDownloadBootConfig,
  copiedField,
  onCopyIp,
  armedAction,
  onArmOrFire,
  ipActionInFlight,
  onIpAction,
  onCredentialDialogChange,
  deleteInstanceConfirm,
  onDeleteRequest,
  onDeleteCancel,
  deletingInstance,
  onConfirmDelete,
}) => (
  <div className="space-y-4">
    {/* Header with Add button */}
    {canCreateInstances && (
      <div className="flex justify-end">
        <Button
          variant="primary"
          size="sm"
          onClick={onAddInstance}
        >
          <Plus className="w-4 h-4 mr-1" />
          Add Instance
        </Button>
      </div>
    )}

    {instances.length === 0 ? (
      <div className="text-center py-8 text-theme-secondary">
        <Cpu className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p>No instances found</p>
        {canCreateInstances && (
          <p className="text-sm mt-2">Click "Add Instance" to create one</p>
        )}
      </div>
    ) : (
      <div className="space-y-3">
        {instances.map(instance => {
          const expanded = expandedInstanceIds.has(instance.id);
          const primaryIp = instance.public_ip_address || instance.private_ip_address || instance.vpn_ip_address;
          return (
          <div
            key={instance.id}
            className="bg-theme-surface-hover rounded-lg p-4 border border-theme hover:border-theme-info-border/50 transition-colors"
          >
            <div className="flex items-center justify-between gap-2">
              <button
                type="button"
                onClick={() => onToggleExpand(instance.id)}
                className="flex items-center gap-3 min-w-0 flex-1 text-left hover:opacity-90 transition-opacity"
              >
                {expanded ? <ChevronDown className="w-4 h-4 text-theme-secondary flex-shrink-0" /> : <ChevronRight className="w-4 h-4 text-theme-secondary flex-shrink-0" />}
                <h4 className="font-medium text-theme-primary truncate">{instance.name}</h4>
                {getStatusBadge(instance.status)}
                <Badge variant="outline" size="xs">{instance.variety}</Badge>
                <BootImageDriftBadge instance={instance} />
                {primaryIp && (
                  <code className="hidden md:inline text-xs text-theme-secondary font-mono truncate">{primaryIp}</code>
                )}
              </button>
              {/* Actions — compact icon buttons so the name has room to breathe */}
              <div className="flex items-center gap-1 ml-2 flex-shrink-0">
                {instance.variety === 'physical' && !instance.claimed && (
                  <button
                    type="button"
                    onClick={() => onDownloadBootConfig(instance)}
                    disabled={bootConfigInFlight === instance.id}
                    title="Download claim-by-ID boot config (identity.cfg) — drop on the device's BOOT partition"
                    className="p-1.5 text-theme-secondary hover:text-theme-primary hover:bg-theme-surface rounded transition-colors disabled:opacity-50"
                  >
                    {bootConfigInFlight === instance.id ? <Loader2 className="w-4 h-4 animate-spin" /> : <Download className="w-4 h-4" />}
                  </button>
                )}
                {canUpdateInstances && (
                  <button
                    type="button"
                    onClick={() => onEditInstance(instance)}
                    title="Edit Instance"
                    className="p-1.5 text-theme-secondary hover:text-theme-primary hover:bg-theme-surface rounded transition-colors"
                  >
                    <Edit className="w-4 h-4" />
                  </button>
                )}
                {canDeleteInstances && (
                  <button
                    type="button"
                    onClick={() => onDeleteRequest(instance)}
                    title="Delete Instance"
                    className="p-1.5 text-theme-secondary hover:text-theme-error-fg hover:bg-theme-surface rounded transition-colors"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                )}
                {canControlInstances && (
                  <NodeInstanceControls
                    instance={instance}
                    onActionComplete={onInstanceActionComplete}
                    compact
                  />
                )}
              </div>
            </div>

            {/* Expanded body — IPs, agent runtime metadata, identity, audit */}
            {expanded && (
              <div className="mt-3 pt-3 border-t border-theme space-y-3">
                {instance.variety === 'physical' && !instance.claimed && (
                  <div className="text-xs text-theme-secondary bg-theme-surface rounded p-2 border border-theme">
                    <span className="font-semibold text-theme-primary">Claim-by-ID provisioning:</span> download this
                    instance's boot config (the <Download className="inline w-3 h-3" /> button above), copy it to the
                    device's <code>BOOT</code> partition as <code>identity.cfg</code>, then boot — the device claims as
                    this instance and auto-enrolls. The file carries no secret and is single-use (download is disabled
                    once claimed). Runbook: <code>fleet-imaging-claim-by-id.md</code>.
                  </div>
                )}
                {/* IP Addresses with copy buttons + associate/disassociate */}
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Network</label>
                  <div className="flex flex-wrap gap-2">
                    {instance.private_ip_address && (
                      <div className="flex items-center gap-1 bg-theme-surface px-2 py-1 rounded border border-theme">
                        <span className="text-xs text-theme-secondary">Private:</span>
                        <code className="text-sm text-theme-primary font-mono">{instance.private_ip_address}</code>
                        <button
                          onClick={() => onCopyIp(instance.private_ip_address!, 'private', instance.id)}
                          className="ml-1 p-0.5 text-theme-secondary hover:text-theme-primary rounded"
                          title="Copy IP"
                        >
                          {copiedField === `${instance.id}-private` ? <Check className="w-3 h-3 text-theme-success-fg" /> : <Copy className="w-3 h-3" />}
                        </button>
                      </div>
                    )}
                    {instance.public_ip_address && (
                      <div className="flex items-center gap-1 bg-theme-surface px-2 py-1 rounded border border-theme">
                        <span className="text-xs text-theme-secondary">Public:</span>
                        <code className="text-sm text-theme-primary font-mono">{instance.public_ip_address}</code>
                        <button
                          onClick={() => onCopyIp(instance.public_ip_address!, 'public', instance.id)}
                          className="ml-1 p-0.5 text-theme-secondary hover:text-theme-primary rounded"
                          title="Copy IP"
                        >
                          {copiedField === `${instance.id}-public` ? <Check className="w-3 h-3 text-theme-success-fg" /> : <Copy className="w-3 h-3" />}
                        </button>
                        {canControlInstances && instance.variety === 'cloud' && (() => {
                          const key = `disassociate:${instance.id}`;
                          const armed = armedAction === key;
                          return (
                            <button
                              onClick={() => onArmOrFire(key, () => onIpAction(instance, 'disassociate'))}
                              disabled={ipActionInFlight !== null}
                              className={`ml-1 p-0.5 rounded disabled:opacity-50 ${armed ? 'text-theme-error-fg font-medium' : 'text-theme-secondary hover:text-theme-error-fg'}`}
                              title={armed ? 'Click again to confirm release' : 'Release public IP'}
                            >
                              {ipActionInFlight === `${instance.id}-disassociate`
                                ? <Loader2 className="w-3 h-3 animate-spin" />
                                : armed ? <span className="text-xs px-1">Confirm?</span> : <Unlink className="w-3 h-3" />}
                            </button>
                          );
                        })()}
                      </div>
                    )}
                    {!instance.public_ip_address && instance.variety === 'cloud' && canControlInstances && (
                      <button
                        onClick={() => onIpAction(instance, 'associate')}
                        disabled={ipActionInFlight !== null}
                        className="flex items-center gap-1 bg-theme-surface px-2 py-1 rounded border border-theme text-xs text-theme-secondary hover:text-theme-primary hover:border-theme-info-border disabled:opacity-50"
                        title="Allocate and associate a public IP"
                      >
                        {ipActionInFlight === `${instance.id}-associate`
                          ? <Loader2 className="w-3 h-3 animate-spin" />
                          : <Link2 className="w-3 h-3" />}
                        <span>Associate Public IP</span>
                      </button>
                    )}
                    {instance.vpn_ip_address && (
                      <div className="flex items-center gap-1 bg-theme-surface px-2 py-1 rounded border border-theme">
                        <span className="text-xs text-theme-secondary">VPN:</span>
                        <code className="text-sm text-theme-primary font-mono">{instance.vpn_ip_address}</code>
                        <button
                          onClick={() => onCopyIp(instance.vpn_ip_address!, 'vpn', instance.id)}
                          className="ml-1 p-0.5 text-theme-secondary hover:text-theme-primary rounded"
                          title="Copy IP"
                        >
                          {copiedField === `${instance.id}-vpn` ? <Check className="w-3 h-3 text-theme-success-fg" /> : <Copy className="w-3 h-3" />}
                        </button>
                      </div>
                    )}
                    {!instance.private_ip_address && !instance.public_ip_address && !instance.vpn_ip_address && (
                      <span className="text-sm text-theme-tertiary italic">No IP addresses assigned</span>
                    )}
                  </div>
                </div>

                <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
                {instance.description && (
                  <div className="col-span-full">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
                    <p className="text-theme-primary">{instance.description}</p>
                  </div>
                )}
                {instance.agent_version && (
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Agent Version</label>
                    <p className="text-theme-primary font-mono text-xs">{instance.agent_version}</p>
                  </div>
                )}
                {instance.last_heartbeat_at && (
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Last Heartbeat</label>
                    <p className="text-theme-primary text-xs">{new Date(instance.last_heartbeat_at).toLocaleString()}</p>
                  </div>
                )}
                {instance.architecture && (
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Architecture</label>
                    <p className="text-theme-primary font-mono">{instance.architecture}</p>
                  </div>
                )}
                {instance.mac_address && (
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">MAC</label>
                    <p className="text-theme-primary font-mono text-xs">{instance.mac_address}</p>
                  </div>
                )}
                {instance.boot_id && (
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Boot ID</label>
                    <p className="text-theme-primary font-mono text-xs truncate" title={instance.boot_id}>{instance.boot_id}</p>
                  </div>
                )}
                {instance.booted_image_git_sha && (
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Boot Image</label>
                    <p className="text-theme-primary font-mono text-xs truncate" title={instance.booted_image_git_sha}>
                      {instance.booted_image_git_sha.slice(0, 12)}
                    </p>
                    {instance.boot_image_drifted && (
                      <div className="mt-1">
                        <BootImageDriftBadge instance={instance} />
                      </div>
                    )}
                  </div>
                )}
                {instance.mtls_subject && (
                  <div className="col-span-full">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">mTLS Subject</label>
                    <p className="text-theme-primary font-mono text-xs truncate" title={instance.mtls_subject}>{instance.mtls_subject}</p>
                  </div>
                )}
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                  <p className="text-theme-primary text-xs">{new Date(instance.created_at).toLocaleString()}</p>
                </div>
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Updated</label>
                  <p className="text-theme-primary text-xs">{new Date(instance.updated_at).toLocaleString()}</p>
                </div>
                </div>

                {/* Claude Code credential — write-only. Mounted only while the
                    row is expanded so the status GET is one request per
                    instance the operator actually opened, and the panel gates
                    itself on system.node_instance_credentials.read. */}
                {nodeId && (
                  <ClaudeCodeCredentialPanel
                    nodeId={nodeId}
                    instanceId={instance.id}
                    onNestedDialogChange={onCredentialDialogChange}
                  />
                )}
              </div>
            )}
          </div>
        );
        })}
      </div>
    )}

    {/* Delete Instance Confirmation */}
    {deleteInstanceConfirm && (
      <Modal
        isOpen
        onClose={onDeleteCancel}
        title="Delete Instance"
        icon={<Trash2 className="w-6 h-6" />}
        maxWidth="md"
        footer={
          <>
            <Button
              variant="ghost"
              onClick={onDeleteCancel}
              disabled={deletingInstance}
            >
              Cancel
            </Button>
            <Button
              variant="danger"
              onClick={onConfirmDelete}
              disabled={deletingInstance}
            >
              {deletingInstance ? 'Deleting...' : 'Delete'}
            </Button>
          </>
        }
      >
        <p className="text-theme-secondary">
          Are you sure you want to delete <strong>{deleteInstanceConfirm.name}</strong>? This action cannot be undone.
        </p>
      </Modal>
    )}
  </div>
);

export default NodeInstancesTab;
