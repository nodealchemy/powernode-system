import React, { useState, useCallback, useEffect } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { NodeList, NodeDetailModal, CreateNodeModal, EditNodeModal } from '@system/features/system/components/nodes';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNode } from '@system/features/system/types/system.types';

interface NodesTabProps {
  // Phase B.1 — page-owned action handle. Parent hub wires {openCreate}
  // into PageContainer.actions when this tab is active.
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
}

export const NodesTab: React.FC<NodesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();

  const canCreate = hasPermission('system.nodes.create');
  const canUpdate = hasPermission('system.nodes.update');
  const canDelete = hasPermission('system.nodes.delete');

  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [editNode, setEditNode] = useState<SystemNode | null>(null);
  const [deleteConfirmNode, setDeleteConfirmNode] = useState<SystemNode | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);
  const triggerRefresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  useEffect(() => {
    onActionsReady?.({ openCreate: () => setShowCreateModal(true) });
    return () => onActionsReady?.(null);
  }, [onActionsReady]);

  const handleViewNode = useCallback((node: SystemNode) => {
    setSelectedNodeId(node.id);
    setShowDetailModal(true);
  }, []);
  const handleEditNode = useCallback((node: SystemNode) => setEditNode(node), []);
  const handleNodeEditComplete = useCallback(() => { setEditNode(null); triggerRefresh(); }, [triggerRefresh]);
  const handleDeleteNode = useCallback((nodeId: string) => {
    systemApi.getNode(nodeId).then((n) => setDeleteConfirmNode(n)).catch(() => {
      addNotification({ type: 'error', message: 'Failed to load node details for deletion' });
    });
  }, [addNotification]);
  const handleConfirmDelete = useCallback(async () => {
    if (!deleteConfirmNode) return;
    setDeleting(true);
    try {
      await systemApi.deleteNode(deleteConfirmNode.id);
      addNotification({ type: 'success', message: `Node "${deleteConfirmNode.name}" deleted successfully` });
      setDeleteConfirmNode(null);
      triggerRefresh();
    } catch (error) {
      addNotification({ type: 'error', message: error instanceof Error ? error.message : 'Failed to delete node' });
    } finally {
      setDeleting(false);
    }
  }, [deleteConfirmNode, addNotification, triggerRefresh]);
  const handleToggleEnabled = useCallback(async (node: SystemNode) => {
    try {
      await systemApi.updateNode(node.id, { enabled: !node.enabled });
      addNotification({ type: 'success', message: `Node "${node.name}" ${node.enabled ? 'disabled' : 'enabled'} successfully` });
      triggerRefresh();
    } catch (error) {
      addNotification({ type: 'error', message: error instanceof Error ? error.message : 'Failed to update node' });
    }
  }, [addNotification, triggerRefresh]);

  return (
    <>
      <NodeList
        onView={handleViewNode}
        onEdit={canUpdate ? handleEditNode : undefined}
        onDelete={canDelete ? handleDeleteNode : undefined}
        onCreate={canCreate ? () => setShowCreateModal(true) : undefined}
        onToggleEnabled={canUpdate ? handleToggleEnabled : undefined}
        refreshKey={refreshKey}
      />

      <NodeDetailModal
        nodeId={selectedNodeId}
        isOpen={showDetailModal}
        onClose={() => { setShowDetailModal(false); setSelectedNodeId(null); }}
        onNodeUpdated={triggerRefresh}
      />

      <CreateNodeModal
        isOpen={showCreateModal}
        onClose={() => setShowCreateModal(false)}
        onNodeCreated={triggerRefresh}
      />

      <EditNodeModal
        node={editNode}
        isOpen={!!editNode}
        onClose={() => setEditNode(null)}
        onNodeUpdated={handleNodeEditComplete}
      />

      <Modal
        isOpen={!!deleteConfirmNode}
        onClose={() => setDeleteConfirmNode(null)}
        title="Delete Node"
        subtitle="This action cannot be undone"
        size="md"
        footer={
          <div className="flex items-center justify-end gap-3">
            <Button variant="ghost" onClick={() => setDeleteConfirmNode(null)} disabled={deleting}>Cancel</Button>
            <Button variant="danger" onClick={handleConfirmDelete} disabled={deleting}>
              {deleting ? 'Deleting...' : 'Delete Node'}
            </Button>
          </div>
        }
      >
        <div className="space-y-4">
          <p className="text-theme-primary">
            Are you sure you want to delete the node <strong>{deleteConfirmNode?.name}</strong>?
          </p>
          {deleteConfirmNode && (deleteConfirmNode.instance_count || 0) > 0 && (
            <div className="p-3 bg-theme-warning/10 border border-theme-warning/30 rounded-lg">
              <p className="text-theme-warning text-sm">
                <strong>Warning:</strong> This node has {deleteConfirmNode.instance_count} instance(s).
                Deleting this node will also remove all associated instances.
              </p>
            </div>
          )}
        </div>
      </Modal>
    </>
  );
};
