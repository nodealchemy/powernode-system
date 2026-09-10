import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Server, Cpu, Box, Activity, Layers } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { TabContainer, Tab } from '@/shared/components/ui/TabContainer';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import {
  useSystemWebSocket,
  type OperationProgressPayload,
  type OperationUpdatePayload,
  type InstanceUpdatePayload,
  type NodeUpdatePayload
} from '@system/features/system/hooks/useSystemWebSocket';
import type { SystemNode, SystemNodeInstance, SystemNodeModule, SystemTask } from '@system/features/system/types/system.types';
import { EditNodeModal } from './EditNodeModal';
import { CreateInstanceModal } from './CreateInstanceModal';
import { EditInstanceModal } from './EditInstanceModal';
import { ApplyTemplateModal } from './ApplyTemplateModal';
import { NodeInfoTab } from './NodeInfoTab';
import { NodeInstancesTab } from './NodeInstancesTab';
import { NodeModulesTab } from './NodeModulesTab';
import { NodeOperationsTab } from './NodeOperationsTab';

interface NodeDetailModalProps {
  /** Node ID to display */
  nodeId: string | null;
  /** Whether the modal is open */
  isOpen: boolean;
  /** Callback when modal is closed */
  onClose: () => void;
  /** Callback when node is updated (e.g., after an action) */
  onNodeUpdated?: () => void;
}

/**
 * NodeDetailModal - Multi-tab modal for viewing node details
 *
 * Displays node information, instances, modules, and operations
 * with real-time WebSocket updates for operation progress.
 *
 * C12 (component-status-plane campaign): the four tabs used to be
 * defined inline as nested closures in this file (1287 lines total).
 * Split onto section components — NodeInfoTab, NodeInstancesTab,
 * NodeModulesTab, NodeOperationsTab — each taking the state/handlers it
 * needs as props; the two pure status-badge helpers moved to
 * nodeDetailHelpers.tsx. This file is now purely the orchestrator: data
 * fetching, WebSocket wiring, mutation handlers, and composing the
 * TabContainer + the four drill-down modals.
 */
export const NodeDetailModal: React.FC<NodeDetailModalProps> = ({
  nodeId,
  isOpen,
  onClose,
  onNodeUpdated
}) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();

  // State
  const [node, setNode] = useState<SystemNode | null>(null);
  const [instances, setInstances] = useState<SystemNodeInstance[]>([]);
  const [modules, setModules] = useState<SystemNodeModule[]>([]);
  const [operations, setOperations] = useState<SystemTask[]>([]);
  const [loading, setLoading] = useState(true);
  const [activeTab, setActiveTab] = useState('info');
  const [copiedField, setCopiedField] = useState<string | null>(null);
  const [showEditModal, setShowEditModal] = useState(false);
  const [showCreateInstanceModal, setShowCreateInstanceModal] = useState(false);
  const [editInstance, setEditInstance] = useState<SystemNodeInstance | null>(null);

  // Click-to-expand state for the Modules and Instances tabs. Operator
  // clicks a row to reveal the rest of the detail (version, lifecycle
  // hooks, agent metadata, etc.) without opening a separate modal.
  // Set<id> so multiple rows can be open at once.
  const [expandedModuleIds, setExpandedModuleIds] = useState<Set<string>>(new Set());
  const [expandedInstanceIds, setExpandedInstanceIds] = useState<Set<string>>(new Set());

  const toggleExpanded = useCallback((set: Set<string>, setter: React.Dispatch<React.SetStateAction<Set<string>>>, id: string) => {
    const next = new Set(set);
    if (next.has(id)) { next.delete(id); } else { next.add(id); }
    setter(next);
  }, []);
  const toggleExpandedModule = useCallback(
    (id: string) => toggleExpanded(expandedModuleIds, setExpandedModuleIds, id),
    [toggleExpanded, expandedModuleIds],
  );
  const toggleExpandedInstance = useCallback(
    (id: string) => toggleExpanded(expandedInstanceIds, setExpandedInstanceIds, id),
    [toggleExpanded, expandedInstanceIds],
  );

  // Arm-and-confirm pattern for destructive actions in this view (currently
  // disassociate public IP). First click arms the action with a 5s window;
  // second click within that window fires. Keyed by `${action}:${instanceId}`
  // so multiple instances can be armed independently.
  const [armedAction, setArmedAction] = useState<string | null>(null);
  const armActionTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const armOrFire = useCallback((key: string, fire: () => void) => {
    if (armedAction === key) {
      if (armActionTimeoutRef.current) clearTimeout(armActionTimeoutRef.current);
      setArmedAction(null);
      fire();
      return;
    }
    setArmedAction(key);
    if (armActionTimeoutRef.current) clearTimeout(armActionTimeoutRef.current);
    armActionTimeoutRef.current = setTimeout(() => setArmedAction(null), 5000);
  }, [armedAction]);

  // Permissions
  const canViewInstances = hasPermission('system.instances.read');
  const canViewModules = hasPermission('system.modules.read');
  const canViewOperations = hasPermission('system.infra_tasks.read');
  const canControlInstances = hasPermission('system.instances.control');
  const canCreateInstances = hasPermission('system.instances.create');
  const canUpdateInstances = hasPermission('system.instances.update');
  const canDeleteInstances = hasPermission('system.instances.delete');
  const canUpdateNode = hasPermission('system.nodes.update');
  const canUpdateModules = hasPermission('system.modules.update');

  // Apply-template drill-down. The shared Modal listens for Escape on
  // `document` rather than on its own subtree, so this modal stands down for
  // the whole time a Modal is stacked above it — not only while that modal's
  // own confirmation is up, which would still let one Escape press close both.
  const [showApplyTemplateModal, setShowApplyTemplateModal] = useState(false);

  // Per-(node, module) assignment toggle (IMP-3e9620967632). Assignment
  // rows arrive embedded on the node-scoped module listing; enable/disable
  // are idempotent POSTs keyed by assignment id.
  const [togglingAssignmentId, setTogglingAssignmentId] = useState<string | null>(null);
  const handleToggleAssignment = useCallback(async (module: SystemNodeModule) => {
    const assignment = module.node_assignment;
    if (!assignment || !nodeId) return;
    setTogglingAssignmentId(assignment.id);
    try {
      if (assignment.enabled) {
        await systemApi.disableModuleAssignment(assignment.id);
      } else {
        await systemApi.enableModuleAssignment(assignment.id);
      }
      // Refetch BEFORE announcing success — if the refetch throws, the
      // operator gets one honest error instead of success + error toasts
      // over a stale row.
      const data = await systemApi.getNodeModules({ node_id: nodeId });
      setModules(data.node_modules || []);
      addNotification({
        type: 'success',
        message: `${module.name} ${assignment.enabled ? 'disabled' : 'enabled'} on this node`,
      });
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Toggle failed' });
    } finally {
      setTogglingAssignmentId(null);
    }
  }, [nodeId, addNotification]);

  // Delete instance state
  const [deleteInstanceConfirm, setDeleteInstanceConfirm] = useState<SystemNodeInstance | null>(null);
  // Raised by ClaudeCodeCredentialPanel's revoke/replace confirmation, whose
  // state lives two components away.
  const [credentialDialogOpen, setCredentialDialogOpen] = useState(false);
  const [deletingInstance, setDeletingInstance] = useState(false);

  // WebSocket for real-time updates
  useSystemWebSocket({
    onOperationProgress: useCallback((progress: OperationProgressPayload) => {
      setOperations(prev => prev.map(op =>
        op.id === progress.operation_id
          ? { ...op, status: progress.status, progress: progress.progress, description: progress.description }
          : op
      ));
    }, []),
    onOperationUpdate: useCallback((operation: OperationUpdatePayload) => {
      setOperations(prev => {
        const exists = prev.some(op => op.id === operation.id);
        if (exists) {
          return prev.map(op => op.id === operation.id ? { ...op, ...operation } as SystemTask : op);
        }
        // New operation for this node - add if it belongs to this node
        if (operation.operable_type === 'System::Node' && operation.operable_id === nodeId) {
          return [operation as unknown as SystemTask, ...prev];
        }
        return prev;
      });
    }, [nodeId]),
    onInstanceUpdate: useCallback((instance: InstanceUpdatePayload) => {
      if (instance.node_id === nodeId) {
        setInstances(prev => prev.map(i => i.id === instance.id ? { ...i, ...instance } as SystemNodeInstance : i));
      }
    }, [nodeId]),
    onNodeUpdate: useCallback((updatedNode: NodeUpdatePayload) => {
      if (updatedNode.id === nodeId) {
        setNode(prev => prev ? { ...prev, ...updatedNode } as SystemNode : null);
      }
    }, [nodeId])
  });

  // Fetch node data
  const fetchNodeData = useCallback(async () => {
    if (!nodeId) return;

    setLoading(true);
    try {
      // Fetch node details
      const nodeData = await systemApi.getNode(nodeId);
      setNode(nodeData);

      // Fetch related data in parallel
      const fetchPromises: Promise<void>[] = [];

      if (canViewInstances) {
        fetchPromises.push(
          systemApi.getNodeInstances(nodeId).then(data => setInstances(data.node_instances || []))
        );
      }

      if (canViewModules) {
        fetchPromises.push(
          systemApi.getNodeModules({ node_id: nodeId }).then(data => setModules(data.node_modules || []))
        );
      }

      if (canViewOperations) {
        fetchPromises.push(
          systemApi.getTasks({ per_page: 50 })
            .then(data => {
              // Filter operations that belong to this node
              const nodeOps = data.tasks.filter(op =>
                op.operable_type === 'System::Node' && op.operable_id === nodeId
              );
              setOperations(nodeOps || []);
            })
        );
      }

      await Promise.all(fetchPromises);
    } catch (error) {
      addNotification({
        type: 'error',
        message: 'Failed to load node details'
      });
    } finally {
      setLoading(false);
    }
  }, [nodeId, canViewInstances, canViewModules, canViewOperations, addNotification]);

  // Load data when modal opens
  useEffect(() => {
    if (isOpen && nodeId) {
      fetchNodeData();
      setActiveTab('info');
    }
  }, [isOpen, nodeId, fetchNodeData]);

  // Copy to clipboard helper
  const copyToClipboard = useCallback(async (text: string, field: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedField(field);
      setTimeout(() => setCopiedField(null), 2000);
    } catch {
      addNotification({ type: 'error', message: 'Failed to copy to clipboard' });
    }
  }, [addNotification]);

  // Handle instance action completion
  const handleInstanceActionComplete = useCallback(() => {
    fetchNodeData();
    onNodeUpdated?.();
  }, [fetchNodeData, onNodeUpdated]);

  // Apply-template completion: the applied plan creates (and may purge) module
  // assignments, so the Modules tab and the parent list are both refetched.
  const handleTemplateApplied = useCallback(() => {
    fetchNodeData();
    onNodeUpdated?.();
  }, [fetchNodeData, onNodeUpdated]);

  // Handle node edit completion
  const handleNodeEditComplete = useCallback((updatedNode: SystemNode) => {
    setNode(updatedNode);
    setShowEditModal(false);
    onNodeUpdated?.();
  }, [onNodeUpdated]);

  // Handle instance created
  const handleInstanceCreated = useCallback((newInstance: SystemNodeInstance) => {
    setInstances(prev => [...prev, newInstance]);
    setShowCreateInstanceModal(false);
    onNodeUpdated?.();
  }, [onNodeUpdated]);

  // Handle instance edit completion
  const handleInstanceEditComplete = useCallback((updatedInstance: SystemNodeInstance) => {
    setInstances(prev => prev.map(i => i.id === updatedInstance.id ? updatedInstance : i));
    setEditInstance(null);
    onNodeUpdated?.();
  }, [onNodeUpdated]);

  // Handle instance delete
  const handleDeleteInstance = useCallback(async () => {
    if (!deleteInstanceConfirm || !nodeId) return;

    setDeletingInstance(true);
    try {
      await systemApi.deleteNodeInstance(nodeId, deleteInstanceConfirm.id);
      setInstances(prev => prev.filter(i => i.id !== deleteInstanceConfirm.id));
      addNotification({
        type: 'success',
        message: `Instance "${deleteInstanceConfirm.name}" deleted successfully`
      });
      setDeleteInstanceConfirm(null);
      onNodeUpdated?.();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Failed to delete instance';
      addNotification({ type: 'error', message: errorMessage });
    } finally {
      setDeletingInstance(false);
    }
  }, [deleteInstanceConfirm, nodeId, addNotification, onNodeUpdated]);

  // Copy IP to clipboard for instances
  const copyInstanceIp = useCallback(async (ip: string, type: string, instanceId: string) => {
    try {
      await navigator.clipboard.writeText(ip);
      setCopiedField(`${instanceId}-${type}`);
      setTimeout(() => setCopiedField(null), 2000);
    } catch {
      addNotification({ type: 'error', message: 'Failed to copy to clipboard' });
    }
  }, [addNotification]);

  // Track in-flight IP allocation/release per-instance to gate the buttons.
  // Keyed by `${instanceId}-associate` or `${instanceId}-disassociate`.
  const [ipActionInFlight, setIpActionInFlight] = useState<string | null>(null);

  const handleIpAction = useCallback(async (
    instance: SystemNodeInstance,
    action: 'associate' | 'disassociate'
  ) => {
    if (!canControlInstances || !nodeId) return;
    const key = `${instance.id}-${action}`;
    setIpActionInFlight(key);
    try {
      if (action === 'associate') {
        await systemApi.associatePublicIp(nodeId, instance.id);
        addNotification({ type: 'success', message: `Allocating public IP for ${instance.name}...` });
      } else {
        await systemApi.disassociatePublicIp(nodeId, instance.id);
        addNotification({ type: 'success', message: `Releasing public IP from ${instance.name}...` });
      }
      onNodeUpdated?.();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Operation failed';
      addNotification({ type: 'error', message: `Failed to ${action} public IP: ${errorMessage}` });
    } finally {
      setIpActionInFlight(null);
    }
  }, [canControlInstances, nodeId, addNotification, onNodeUpdated]);

  // Claim-by-ID fleet flow: download a physical instance's boot config
  // (identity.cfg) to drop onto the device's BOOT partition. Read-level
  // action; only offered for physical instances that aren't yet claimed
  // (the endpoint returns 409 once a device has bound to the instance).
  const [bootConfigInFlight, setBootConfigInFlight] = useState<string | null>(null);
  const handleDownloadBootConfig = useCallback(async (instance: SystemNodeInstance) => {
    if (!nodeId) return;
    setBootConfigInFlight(instance.id);
    try {
      await systemApi.downloadInstanceBootConfig(nodeId, instance.id);
      addNotification({
        type: 'success',
        message: `Boot config downloaded for ${instance.name}. Copy it to the device's BOOT partition as identity.cfg.`
      });
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Failed to download boot config';
      addNotification({ type: 'error', message: errorMessage });
    } finally {
      setBootConfigInFlight(null);
    }
  }, [nodeId, addNotification]);

  // Build tabs array
  const tabs: Tab[] = [
    {
      id: 'info',
      label: 'Information',
      icon: <Server className="w-4 h-4" />,
      content: <NodeInfoTab node={node} instances={instances} copiedField={copiedField} onCopy={copyToClipboard} />
    }
  ];

  if (canViewInstances) {
    tabs.push({
      id: 'instances',
      label: 'Instances',
      icon: <Cpu className="w-4 h-4" />,
      badge: instances.length,
      content: (
        <NodeInstancesTab
          nodeId={nodeId}
          instances={instances}
          expandedInstanceIds={expandedInstanceIds}
          onToggleExpand={toggleExpandedInstance}
          canCreateInstances={canCreateInstances}
          canUpdateInstances={canUpdateInstances}
          canDeleteInstances={canDeleteInstances}
          canControlInstances={canControlInstances}
          onAddInstance={() => setShowCreateInstanceModal(true)}
          onEditInstance={setEditInstance}
          onInstanceActionComplete={handleInstanceActionComplete}
          bootConfigInFlight={bootConfigInFlight}
          onDownloadBootConfig={handleDownloadBootConfig}
          copiedField={copiedField}
          onCopyIp={copyInstanceIp}
          armedAction={armedAction}
          onArmOrFire={armOrFire}
          ipActionInFlight={ipActionInFlight}
          onIpAction={handleIpAction}
          onCredentialDialogChange={setCredentialDialogOpen}
          deleteInstanceConfirm={deleteInstanceConfirm}
          onDeleteRequest={setDeleteInstanceConfirm}
          onDeleteCancel={() => setDeleteInstanceConfirm(null)}
          deletingInstance={deletingInstance}
          onConfirmDelete={handleDeleteInstance}
        />
      )
    });
  }

  if (canViewModules) {
    tabs.push({
      id: 'modules',
      label: 'Modules',
      icon: <Box className="w-4 h-4" />,
      badge: modules.length,
      content: (
        <NodeModulesTab
          modules={modules}
          expandedModuleIds={expandedModuleIds}
          onToggleExpand={toggleExpandedModule}
          canUpdateModules={canUpdateModules}
          togglingAssignmentId={togglingAssignmentId}
          onToggleAssignment={handleToggleAssignment}
        />
      )
    });
  }

  if (canViewOperations) {
    tabs.push({
      id: 'operations',
      label: 'Operations',
      icon: <Activity className="w-4 h-4" />,
      badge: operations.filter(op => ['pending', 'running'].includes(op.status)).length || undefined,
      content: <NodeOperationsTab operations={operations} />
    });
  }

  return (
    <>
      <Modal
        isOpen={isOpen}
        onClose={onClose}
        title={node?.name || 'Node Details'}
        subtitle={node?.node_template_name ? `Template: ${node.node_template_name}` : undefined}
        icon={<Server className="w-6 h-6" />}
        size="4xl"
        // Every nested dialog is a core Modal listening for Escape on document.
        // The guard has to name ALL of them: one that is missing means a single
        // keypress closes the child AND this dialog underneath it.
        closeOnEscape={
          !showApplyTemplateModal &&
          !showEditModal &&
          !showCreateInstanceModal &&
          !editInstance &&
          deleteInstanceConfirm === null &&
          !credentialDialogOpen
        }
        footer={
          <div className="flex items-center gap-3">
            {canUpdateNode && node && (
              <Button
                variant="secondary"
                onClick={() => setShowEditModal(true)}
              >
                Edit Node
              </Button>
            )}
            {/* apply_template requires system.modules.update, and there is
                nothing to apply on a node with no template bound. */}
            {canUpdateModules && node?.node_template_id && (
              <Button
                variant="secondary"
                onClick={() => setShowApplyTemplateModal(true)}
              >
                <Layers className="w-4 h-4 mr-2" />
                Apply Template
              </Button>
            )}
            <Button variant="ghost" onClick={onClose}>
              Close
            </Button>
          </div>
        }
      >
        {loading ? (
          <div className="flex items-center justify-center py-12">
            <LoadingSpinner size="lg" />
          </div>
        ) : node ? (
          <TabContainer
            tabs={tabs}
            activeTab={activeTab}
            onTabChange={setActiveTab}
            variant="underline"
          />
        ) : (
          <div className="text-center py-8 text-theme-secondary">
            <Server className="w-12 h-12 mx-auto mb-3 opacity-50" />
            <p>Node not found</p>
          </div>
        )}
      </Modal>

      {/* Edit Node Modal */}
      <EditNodeModal
        node={node}
        isOpen={showEditModal}
        onClose={() => setShowEditModal(false)}
        onNodeUpdated={handleNodeEditComplete}
      />

      {/* Create Instance Modal */}
      <CreateInstanceModal
        node={node}
        isOpen={showCreateInstanceModal}
        onClose={() => setShowCreateInstanceModal(false)}
        onInstanceCreated={handleInstanceCreated}
      />

      {/* Apply Template Modal */}
      <ApplyTemplateModal
        node={node}
        isOpen={showApplyTemplateModal}
        onClose={() => setShowApplyTemplateModal(false)}
        onApplied={handleTemplateApplied}
      />

      {/* Edit Instance Modal */}
      <EditInstanceModal
        nodeId={nodeId}
        instance={editInstance}
        isOpen={!!editInstance}
        onClose={() => setEditInstance(null)}
        onInstanceUpdated={handleInstanceEditComplete}
      />
    </>
  );
};

export default NodeDetailModal;
