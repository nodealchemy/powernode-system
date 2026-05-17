import React, { useEffect, useMemo, useState } from 'react';
import { Database, AlertCircle } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { storageMigrationsApi } from '../../services/api/storageMigrationsApi';
import { volumesApi } from '../../services/api/volumesApi';
import type { SystemProviderVolume } from '../../types/system.types';
import type { StorageMigrationSummary } from '../../types/storageMigration.types';

/**
 * Plan a new storage migration. The operator picks source/target
 * volumes (drawn from this account's ProviderVolume rows), the
 * stateful role being migrated (free-text — matches a module_service
 * name like "postgres"), and the NodeInstance whose binding is
 * being swapped.
 *
 * Plan reference: E8 follow-on (operator UI / planning wizard).
 */

interface PlanStorageMigrationModalProps {
  isOpen: boolean;
  onClose: () => void;
  onPlanned?: (m: StorageMigrationSummary) => void;
  // Optional pre-filled context — when the operator opens the modal
  // from an instance detail page, these arrive populated.
  defaultInstanceId?: string;
  defaultRole?: string;
}

export const PlanStorageMigrationModal: React.FC<PlanStorageMigrationModalProps> = ({
  isOpen,
  onClose,
  onPlanned,
  defaultInstanceId,
  defaultRole,
}) => {
  const [instanceId, setInstanceId] = useState(defaultInstanceId ?? '');
  const [role, setRole] = useState(defaultRole ?? '');
  const [sourceId, setSourceId] = useState('');
  const [targetId, setTargetId] = useState('');
  const [volumes, setVolumes] = useState<SystemProviderVolume[]>([]);
  const [loadingVolumes, setLoadingVolumes] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isOpen) return;
    setInstanceId(defaultInstanceId ?? '');
    setRole(defaultRole ?? '');
    setSourceId('');
    setTargetId('');
    setError(null);
    setLoadingVolumes(true);
    void volumesApi
      .getVolumes({ page_size: 200 })
      .then((r) => setVolumes(r.volumes))
      .catch((err: unknown) => {
        setError(err instanceof Error ? err.message : 'Failed to load volumes');
      })
      .finally(() => setLoadingVolumes(false));
  }, [isOpen, defaultInstanceId, defaultRole]);

  const canSubmit = useMemo(
    () =>
      instanceId.trim().length > 0 &&
      role.trim().length > 0 &&
      sourceId.length > 0 &&
      targetId.length > 0 &&
      sourceId !== targetId &&
      !submitting,
    [instanceId, role, sourceId, targetId, submitting],
  );

  const handleSubmit = async () => {
    if (!canSubmit) return;
    setSubmitting(true);
    setError(null);
    try {
      const migration = await storageMigrationsApi.create({
        node_instance_id: instanceId.trim(),
        source_volume_id: sourceId,
        target_volume_id: targetId,
        role: role.trim(),
      });
      onPlanned?.(migration);
      onClose();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Plan failed');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Plan Storage Migration" size="md">
      <div className="space-y-4">
        <div className="flex items-start gap-3 p-3 bg-theme-info/10 text-theme-info rounded text-sm">
          <Database className="w-4 h-4 flex-shrink-0 mt-0.5" />
          <div>
            Move a stateful component's data from one volume to another. The
            operator approves the plan; the on-node agent runs rsync, verifies
            checksums, then atomically swaps the canonical mount during cutover.
          </div>
        </div>

        {error && (
          <div className="flex items-center gap-2 p-3 bg-theme-danger/10 text-theme-danger rounded text-sm">
            <AlertCircle className="w-4 h-4 flex-shrink-0" />
            <span>{error}</span>
          </div>
        )}

        <div className="space-y-3">
          <div>
            <label className="block text-xs uppercase text-theme-secondary mb-1">
              Node Instance ID
            </label>
            <input
              type="text"
              value={instanceId}
              onChange={(e) => setInstanceId(e.target.value)}
              disabled={submitting}
              placeholder="UUID of the instance holding the stateful module"
              className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-theme-primary text-sm font-mono"
            />
          </div>

          <div>
            <label className="block text-xs uppercase text-theme-secondary mb-1">Role</label>
            <input
              type="text"
              value={role}
              onChange={(e) => setRole(e.target.value)}
              disabled={submitting}
              placeholder="postgres, redis, …"
              className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-theme-primary text-sm"
            />
            <p className="text-xs text-theme-tertiary mt-1">
              Matches a module_service name on the instance; used to compute the
              source + target subpath under each volume's export.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs uppercase text-theme-secondary mb-1">Source Volume</label>
              <VolumeSelect
                value={sourceId}
                onChange={setSourceId}
                volumes={volumes}
                loading={loadingVolumes}
                disabled={submitting}
              />
            </div>
            <div>
              <label className="block text-xs uppercase text-theme-secondary mb-1">Target Volume</label>
              <VolumeSelect
                value={targetId}
                onChange={setTargetId}
                volumes={volumes}
                loading={loadingVolumes}
                disabled={submitting}
                excludeId={sourceId}
              />
            </div>
          </div>
          {sourceId === targetId && sourceId !== '' && (
            <div className="text-xs text-theme-warning">Source and target must differ.</div>
          )}
        </div>

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="ghost" onClick={onClose} disabled={submitting}>
            Cancel
          </Button>
          <Button onClick={() => void handleSubmit()} disabled={!canSubmit}>
            {submitting ? 'Planning…' : 'Plan Migration'}
          </Button>
        </div>
      </div>
    </Modal>
  );
};

interface VolumeSelectProps {
  value: string;
  onChange: (id: string) => void;
  volumes: SystemProviderVolume[];
  loading: boolean;
  disabled: boolean;
  excludeId?: string;
}

const VolumeSelect: React.FC<VolumeSelectProps> = ({
  value,
  onChange,
  volumes,
  loading,
  disabled,
  excludeId,
}) => {
  const visible = useMemo(
    () => volumes.filter((v) => v.id !== excludeId),
    [volumes, excludeId],
  );
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      disabled={disabled || loading}
      className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-theme-primary text-sm"
    >
      <option value="">{loading ? 'Loading…' : 'Select a volume…'}</option>
      {visible.map((v) => (
        <option key={v.id} value={v.id}>
          {v.name} ({v.size_gb} GB · {v.status})
        </option>
      ))}
    </select>
  );
};
