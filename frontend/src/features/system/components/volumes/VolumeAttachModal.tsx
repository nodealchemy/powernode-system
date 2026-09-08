import React, { useState, useEffect } from 'react';
import { Link, Server, AlertCircle } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { FormField } from '@/shared/components/ui/FormField';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { EntityLink } from '@/shared/components/entity';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderVolume, SystemNodeInstance } from '@system/features/system/types/system.types';

interface VolumeAttachModalProps {
  /** Volume to attach */
  volume: SystemProviderVolume | null;
  /** Whether the modal is open */
  isOpen: boolean;
  /** Callback when modal is closed */
  onClose: () => void;
  /** Callback when volume is attached */
  onVolumeAttached?: () => void;
}

/**
 * VolumeAttachModal - Modal for attaching a volume to an instance
 */
export const VolumeAttachModal: React.FC<VolumeAttachModalProps> = ({
  volume,
  isOpen,
  onClose,
  onVolumeAttached
}) => {
  const { addNotification } = useNotifications();

  // State
  const [instances, setInstances] = useState<SystemNodeInstance[]>([]);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [selectedInstanceId, setSelectedInstanceId] = useState<string>('');
  const [deviceName, setDeviceName] = useState<string>('');
  const [error, setError] = useState<string>('');

  // Fetch instances
  useEffect(() => {
    const fetchInstances = async () => {
      try {
        // Get all nodes and their instances
        const nodesResult = await systemApi.getNodes({ per_page: 100, enabled: true });
        const allInstances: SystemNodeInstance[] = [];

        for (const node of nodesResult.nodes) {
          const instancesResult = await systemApi.getNodeInstances(node.id);
          // Only include running instances
          const runningInstances = instancesResult.node_instances.filter(
            i => i.status === 'running'
          ).map(i => ({
            ...i,
            node_name: node.name
          }));
          allInstances.push(...runningInstances);
        }

        setInstances(allInstances);
      } catch (error) {
        addNotification({
          type: 'error',
          message: 'Failed to load instances'
        });
      } finally {
        setLoading(false);
      }
    };

    if (isOpen && volume) {
      setLoading(true);
      setSelectedInstanceId('');
      setDeviceName('');
      setError('');
      fetchInstances();
    }
  }, [isOpen, volume, addNotification]);

  // Handle attach
  const handleAttach = async () => {
    if (!volume || !selectedInstanceId) {
      setError('Please select an instance');
      return;
    }

    setSubmitting(true);
    setError('');

    try {
      await systemApi.attachVolume(volume.id, selectedInstanceId, deviceName || undefined);
      addNotification({
        type: 'success',
        message: `Volume attached successfully`
      });
      onVolumeAttached?.();
      onClose();
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Failed to attach volume';
      setError(errorMessage);
      addNotification({
        type: 'error',
        message: errorMessage
      });
    } finally {
      setSubmitting(false);
    }
  };

  if (!volume) return null;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Attach Volume"
      icon={<Link className="w-6 h-6" />}
      maxWidth="md"
    >
          {/* Content */}
          <div className="space-y-4">
            {/* Volume Info */}
            <div className="bg-theme-background rounded-lg p-3 border border-theme">
              <p className="text-sm text-theme-secondary">Attaching volume:</p>
              <p className="font-medium text-theme-primary">{volume.name}</p>
              <p className="text-sm text-theme-tertiary">
                {volume.size_gb} GB • {volume.volume_type}
              </p>
            </div>

            {/* Instance Selection */}
            <div>
              {loading ? (
                <>
                  <label className="block text-sm font-medium text-theme-primary mb-1">
                    Select Instance <span className="text-theme-error-fg">*</span>
                  </label>
                  <div className="flex items-center justify-center py-4">
                    <LoadingSpinner size="sm" />
                  </div>
                </>
              ) : instances.length === 0 ? (
                <>
                  <label className="block text-sm font-medium text-theme-primary mb-1">
                    Select Instance <span className="text-theme-error-fg">*</span>
                  </label>
                  <div className="text-center py-4">
                    <Server className="w-8 h-8 text-theme-tertiary mx-auto mb-2" />
                    <p className="text-sm text-theme-secondary">No running instances available</p>
                  </div>
                </>
              ) : (
                <FormField
                  label="Select Instance"
                  type="select"
                  required
                  disabled={submitting}
                  value={selectedInstanceId}
                  onChange={setSelectedInstanceId}
                  options={[
                    { value: '', label: 'Select an instance' },
                    ...instances.map((instance) => {
                      const nodeName = (instance as SystemNodeInstance & { node_name?: string }).node_name;
                      return {
                        value: instance.id,
                        label: `${nodeName ? `${nodeName} / ` : ''}${instance.name} (${instance.status})`,
                      };
                    }),
                  ]}
                />
              )}
              {/* View the selected instance's detail surface (node_instance uses a
                  composite "nodeId:instanceId" id; the fetched instance carries
                  its node_id). EntityLink degrades to text if unresolved. */}
              {(() => {
                const selected = instances.find((i) => i.id === selectedInstanceId);
                if (!selected || !selected.node_id) return null;
                return (
                  <p className="mt-1 text-xs">
                    <EntityLink
                      type="node_instance"
                      id={`${selected.node_id}:${selected.id}`}
                      label="View instance details"
                    />
                  </p>
                );
              })()}
            </div>

            {/* Device Name */}
            <FormField
              label="Device Name (optional)"
              disabled={submitting}
              value={deviceName}
              onChange={setDeviceName}
              placeholder="e.g., /dev/sdf"
              helpText="Leave empty for auto-assignment"
            />

            {/* Error */}
            {error && (
              <div className="flex items-center gap-2 text-theme-error-fg text-sm">
                <AlertCircle className="w-4 h-4" />
                {error}
              </div>
            )}
          </div>

          {/* Footer */}
          <div className="flex justify-end gap-3 p-4 border-t border-theme">
            <Button variant="outline" onClick={onClose} disabled={submitting}>
              Cancel
            </Button>
            <Button
              variant="primary"
              onClick={handleAttach}
              disabled={submitting || !selectedInstanceId}
            >
              {submitting ? (
                <>
                  <LoadingSpinner size="sm" className="mr-2" />
                  Attaching...
                </>
              ) : (
                <>
                  <Link className="w-4 h-4 mr-2" />
                  Attach Volume
                </>
              )}
            </Button>
          </div>
    </Modal>
  );
};

export default VolumeAttachModal;
