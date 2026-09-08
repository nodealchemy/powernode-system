import React, { useState, useEffect, useRef, useCallback } from 'react';
import {
  HardDrive,
  Link,
  Unlink,
  Camera,
  MapPin,
  Calendar,
  Shield,
  History,
  RotateCcw,
  AlertTriangle
} from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import Pagination from '@/shared/components/ui/Pagination';
import { EntityLink } from '@/shared/components/entity';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderVolume } from '@system/features/system/types/system.types';
import type {
  VolumeSnapshot,
  VolumeRestoreResult
} from '@system/features/system/services/api/volumesApi';
import { VolumeRestoreError } from '@system/features/system/services/api/volumesApi';

// The volume payload may carry the holding node id + instance display name
// alongside `node_instance_id`; a `node_id` is required to build the
// `node_instance` composite EntityLink id ("nodeId:instanceId"). These are
// optional/extension fields not yet on the shared type — widen locally rather
// than mutate the shared interface or use `any`. When `node_id` is absent the
// link is simply not rendered (existing text shown instead).
type VolumeWithAttachment = SystemProviderVolume & {
  node_id?: string;
  instance_name?: string;
};

/**
 * Body of the restore confirmation. Owns its own state and reports upward
 * because useConfirmation snapshots the `message` element when confirm() is
 * called: a controlled checkbox driven by VolumeDetailModal state would keep
 * the props from the render that opened the dialog and never tick.
 */
const RestorePrompt: React.FC<{
  snapshotName: string;
  volumeName: string;
  attached: boolean;
  onSwapChange: (swap: boolean) => void;
}> = ({ snapshotName, volumeName, attached, onSwapChange }) => {
  const [swap, setSwap] = useState(false);

  return (
    <div className="space-y-4">
      <p>
        Restore &quot;{volumeName}&quot; from snapshot &quot;{snapshotName}&quot;?
      </p>
      <p>
        Most providers restore by <strong>copying</strong> the snapshot into a new
        volume. On that path this volume is left untouched and the restored data
        arrives in a separate disk, which you then have to put into service
        yourself.
      </p>
      <label
        htmlFor="restore-swap-into-place"
        className="flex items-start gap-3 text-theme-primary cursor-pointer"
      >
        <input
          id="restore-swap-into-place"
          type="checkbox"
          checked={swap}
          onChange={(e) => { setSwap(e.target.checked); onSwapChange(e.target.checked); }}
          className="mt-1"
        />
        <span>
          <span className="font-medium">Swap the copy into place</span>
          <span className="block text-sm text-theme-secondary">
            {attached
              ? 'Detach this volume from its instance and attach the copy at the same device. The workload loses access while the swap runs.'
              : 'Only applies to an attached volume — this one is not attached, so the server will report the swap as skipped.'}
          </span>
        </span>
      </label>
    </div>
  );
};

interface VolumeDetailModalProps {
  /** Volume ID to display */
  volumeId: string | null;
  /** Whether the modal is open */
  isOpen: boolean;
  /** Callback when modal is closed */
  onClose: () => void;
  /** Callback when volume is updated */
  onVolumeUpdated?: () => void;
  /** Callback to edit the volume */
  onEdit?: (volume: SystemProviderVolume) => void;
}

const statusVariants: Record<string, 'success' | 'warning' | 'danger' | 'secondary' | 'info'> = {
  available: 'success',
  'in-use': 'info',
  creating: 'warning',
  deleting: 'warning',
  deleted: 'secondary',
  error: 'danger'
};

const volumeTypeLabels: Record<string, string> = {
  gp2: 'General Purpose SSD (gp2)',
  gp3: 'General Purpose SSD (gp3)',
  io1: 'Provisioned IOPS SSD (io1)',
  io2: 'Provisioned IOPS SSD (io2)',
  st1: 'Throughput Optimized HDD',
  sc1: 'Cold HDD',
  standard: 'Magnetic',
  ssd: 'SSD',
  hdd: 'HDD',
  custom: 'Custom'
};

/**
 * VolumeDetailModal - Modal showing volume details with actions
 */
export const VolumeDetailModal: React.FC<VolumeDetailModalProps> = ({
  volumeId,
  isOpen,
  onClose,
  onVolumeUpdated,
  onEdit
}) => {
  const { addNotification } = useNotifications();
  const { hasPermission } = usePermissions();
  const { confirm, ConfirmationDialog } = useConfirmation();
  // The volume currently loaded. useConfirmation snapshots the whole onConfirm
  // closure when confirm() is called, so reading `volume` from inside it yields
  // the object from THAT render — comparing it against the id captured in the
  // same render compares a value with itself. A ref is what lets the confirm
  // handler see the volume that is on screen now.
  const currentVolumeRef = useRef<VolumeWithAttachment | null>(null);

  const canUpdate = hasPermission('system.volumes.update');
  const canSnapshot = hasPermission('system.volumes.snapshot');
  // Restore is gated on `manage` server-side — the broadest volume grant,
  // because it is the broadest thing that can be done to a volume's contents.
  const canManage = hasPermission('system.volumes.manage');
  // Written by RestorePrompt while its dialog is open; read once on confirm.
  const swapIntoPlaceRef = useRef(false);

  // State
  const [volume, setVolume] = useState<SystemProviderVolume | null>(null);
  const [loading, setLoading] = useState(true);
  const [actionLoading, setActionLoading] = useState<string | null>(null);
  const [showSnapshotModal, setShowSnapshotModal] = useState(false);
  const [snapshotName, setSnapshotName] = useState('');
  const [snapshotDescription, setSnapshotDescription] = useState('');
  const [snapshots, setSnapshots] = useState<VolumeSnapshot[]>([]);
  const [snapshotsPage, setSnapshotsPage] = useState(1);
  const [snapshotsTotalPages, setSnapshotsTotalPages] = useState(1);
  const [snapshotsLoading, setSnapshotsLoading] = useState(false);
  // Distinguished from "no snapshots": a failed listing that rendered as an
  // empty list would tell an operator this volume has no restore points.
  const [snapshotsError, setSnapshotsError] = useState<string | null>(null);
  const [restoreResult, setRestoreResult] = useState<VolumeRestoreResult | null>(null);
  // A restore can fail AFTER the provider made a copy. The toast auto-dismisses;
  // the copy's id must not, or the operator is left with a billable disk they
  // cannot find.
  const [restoreFailure, setRestoreFailure] = useState<{
    message: string;
    details?: Record<string, unknown>;
  } | null>(null);
  // Guards against an out-of-order snapshot listing overwriting a newer one
  // when the modal switches volumes with a request in flight.
  const snapshotsReqRef = useRef(0);

  // Fetch volume
  useEffect(() => {
    const fetchVolume = async () => {
      if (!volumeId) return;

      try {
        const data = await systemApi.getVolume(volumeId);
        setVolume(data);
      } catch (error) {
        addNotification({
          type: 'error',
          message: 'Failed to load volume details'
        });
      } finally {
        setLoading(false);
      }
    };

    if (isOpen && volumeId) {
      setLoading(true);
      fetchVolume();
    }
  }, [isOpen, volumeId, addNotification]);

  useEffect(() => {
    currentVolumeRef.current = volume;
  }, [volume]);

  const loadSnapshots = useCallback(async (id: string, page: number) => {
    const req = ++snapshotsReqRef.current;
    setSnapshotsLoading(true);
    setSnapshotsError(null);
    try {
      const result = await systemApi.getVolumeSnapshots(id, { page });
      if (snapshotsReqRef.current !== req) return;
      setSnapshots(result.snapshots);
      setSnapshotsTotalPages(result.meta.total_pages);
    } catch (error) {
      if (snapshotsReqRef.current !== req) return;
      setSnapshots([]);
      setSnapshotsError(error instanceof Error ? error.message : 'An error occurred');
    } finally {
      if (snapshotsReqRef.current === req) setSnapshotsLoading(false);
    }
  }, []);

  // Anything derived from the previous volume must not outlive it — a restore
  // outcome shown under another volume's heading attributes a destructive
  // result to the wrong disk, and a carried-over page number renders a volume
  // that HAS restore points as having none.
  useEffect(() => {
    setRestoreResult(null);
    setRestoreFailure(null);
    setSnapshotsPage(1);
  }, [volumeId]);

  useEffect(() => {
    if (!isOpen || !volumeId) return;
    void loadSnapshots(volumeId, snapshotsPage);
  }, [isOpen, volumeId, snapshotsPage, loadSnapshots]);

  // Reset on close
  useEffect(() => {
    if (!isOpen) {
      setVolume(null);
      setShowSnapshotModal(false);
      setSnapshotName('');
      setSnapshotDescription('');
      setSnapshots([]);
      setSnapshotsPage(1);
      setSnapshotsTotalPages(1);
      setSnapshotsError(null);
      setRestoreResult(null);
      setRestoreFailure(null);
    }
  }, [isOpen]);

  // Handle detach — confirm-gated (IMP-443984320078): detaching a mounted
  // volume pulls storage out from under whatever is running on the holding
  // instance, and the only undo is a re-attach.
  const requestDetach = () => {
    if (!volume) return;
    const targetId = volume.id;
    confirm({
      title: 'Detach Volume',
      message: `Detach "${volume.name}" from the instance holding it? Anything running against this volume loses access immediately, and the only way back is to re-attach it.`,
      confirmLabel: 'Detach Volume',
      cancelLabel: 'Keep Attached',
      variant: 'danger',
      onConfirm: () => performDetach(targetId)
    });
  };

  const performDetach = async (targetId: string) => {
    // A confirmation left open outlives the modal's isOpen flag, so it must not
    // fire at whatever volume is loaded now.
    if (currentVolumeRef.current?.id !== targetId) return;

    setActionLoading('detach');
    try {
      await systemApi.detachVolume(targetId);
      addNotification({
        type: 'success',
        message: 'Volume detached successfully'
      });
      // Refresh volume
      const updated = await systemApi.getVolume(targetId);
      setVolume(updated);
      onVolumeUpdated?.();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: `Failed to detach volume: ${errorMessage}`
      });
    } finally {
      setActionLoading(null);
    }
  };

  // Restore this volume from one of its snapshots. Confirm-gated and explicit
  // about the copy-restore semantics, because the operator's mental model
  // ("restore puts my data back here") is wrong on the copy path.
  const requestRestore = (snapshot: VolumeSnapshot) => {
    if (!volume) return;
    const targetVolumeId = volume.id;
    const snapshotId = snapshot.id;
    swapIntoPlaceRef.current = false;

    confirm({
      title: 'Restore Snapshot',
      message: (
        <RestorePrompt
          snapshotName={snapshot.name || snapshot.id}
          volumeName={volume.name}
          attached={Boolean(volume.node_instance_id)}
          onSwapChange={(swap) => { swapIntoPlaceRef.current = swap; }}
        />
      ),
      confirmLabel: 'Restore Snapshot',
      cancelLabel: 'Leave As Is',
      variant: 'danger',
      onConfirm: () => performRestore(targetVolumeId, snapshotId)
    });
  };

  const performRestore = async (targetVolumeId: string, snapshotId: string) => {
    // The dialog outlives the modal's volumeId prop; do not restore whatever
    // volume happens to be loaded now.
    if (currentVolumeRef.current?.id !== targetVolumeId) return;

    setActionLoading('restore');
    setRestoreResult(null);
    setRestoreFailure(null);
    try {
      const result = await systemApi.restoreVolumeSnapshot(
        targetVolumeId,
        snapshotId,
        swapIntoPlaceRef.current
      );
      setRestoreResult(result);
      addNotification({
        type: 'success',
        message: result.restored_in_place
          ? 'Volume rolled back to the snapshot'
          : 'Snapshot restored into a new volume'
      });
      const updated = await systemApi.getVolume(targetVolumeId);
      setVolume(updated);
      onVolumeUpdated?.();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      setRestoreFailure({
        message: errorMessage,
        details: error instanceof VolumeRestoreError ? error.details : undefined
      });
      addNotification({
        type: 'error',
        message: `Failed to restore snapshot: ${errorMessage}`
      });
    } finally {
      setActionLoading(null);
    }
  };

  // Handle snapshot creation
  const handleCreateSnapshot = async () => {
    if (!volume) return;

    setActionLoading('snapshot');
    try {
      await systemApi.createVolumeSnapshot(
        volume.id,
        snapshotName || `${volume.name}-snapshot`,
        snapshotDescription
      );
      addNotification({
        type: 'success',
        message: 'Snapshot creation started'
      });
      setShowSnapshotModal(false);
      setSnapshotName('');
      setSnapshotDescription('');
      // `@volume.snapshots.recent` puts the new one on page 1, so an operator
      // deeper in the list would otherwise see nothing change.
      setSnapshotsPage(1);
      await loadSnapshots(volume.id, 1);
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: `Failed to create snapshot: ${errorMessage}`
      });
    } finally {
      setActionLoading(null);
    }
  };

  // Format size
  const formatSize = (sizeGb: number) => {
    if (sizeGb >= 1024) {
      return `${(sizeGb / 1024).toFixed(1)} TB`;
    }
    return `${sizeGb} GB`;
  };

  // Format date
  const formatDate = (dateString: string) => {
    return new Date(dateString).toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  };

  return (
    <>
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={loading ? 'Loading...' : volume?.name || 'Volume Details'}
      icon={<HardDrive className="w-6 h-6" />}
      maxWidth="2xl"
      // The snapshot dialog and the shared confirmation are both Modals
      // listening for Escape on document; suppress ours while either is up.
      closeOnEscape={!showSnapshotModal && ConfirmationDialog === null}
      subtitle={
        volume ? (
          <div className="flex items-center gap-2">
            <Badge
              variant={statusVariants[volume.status] || 'secondary'}
              size="sm"
              dot
              pulse={volume.status === 'creating'}
            >
              {volume.status}
            </Badge>
            {volume.encrypted && (
              <Badge variant="info" size="sm">
                <Shield className="w-3 h-3 mr-1" />
                Encrypted
              </Badge>
            )}
          </div>
        ) : undefined
      }
      footer={
        <>
          <Button variant="outline" onClick={onClose}>
            Close
          </Button>
          {canUpdate && onEdit && volume && (
            <Button variant="primary" onClick={() => onEdit(volume)}>
              Edit Volume
            </Button>
          )}
        </>
      }
    >
          {/* Content */}
          <div>
            {loading ? (
              <div className="flex items-center justify-center py-12">
                <LoadingSpinner size="lg" />
              </div>
            ) : volume ? (
              <div className="space-y-6">
                {/* Basic Info */}
                <div className="grid grid-cols-2 gap-6">
                  <div className="space-y-4">
                    <div>
                      <label className="block text-sm text-theme-secondary mb-1">Size</label>
                      <p className="text-theme-primary font-medium text-lg">{formatSize(volume.size_gb)}</p>
                    </div>
                    <div>
                      <label className="block text-sm text-theme-secondary mb-1">Volume Type</label>
                      <p className="text-theme-primary">
                        {volumeTypeLabels[volume.volume_type] || volume.volume_type}
                      </p>
                    </div>
                    {volume.iops && (
                      <div>
                        <label className="block text-sm text-theme-secondary mb-1">IOPS</label>
                        <p className="text-theme-primary font-mono">{volume.iops.toLocaleString()}</p>
                      </div>
                    )}
                    {volume.throughput && (
                      <div>
                        <label className="block text-sm text-theme-secondary mb-1">Throughput</label>
                        <p className="text-theme-primary font-mono">{volume.throughput} MB/s</p>
                      </div>
                    )}
                  </div>
                  <div className="space-y-4">
                    <div>
                      <label className="block text-sm text-theme-secondary mb-1">Region</label>
                      <div className="flex items-center gap-2 text-theme-primary">
                        <MapPin className="w-4 h-4 text-theme-tertiary" />
                        {volume.region_name || volume.provider_region_id || '—'}
                      </div>
                    </div>
                    <div>
                      <label className="block text-sm text-theme-secondary mb-1">Attachment</label>
                      {volume.node_instance_id ? (
                        <div className="flex items-center gap-2 text-theme-success-fg">
                          <Link className="w-4 h-4 flex-shrink-0" />
                          {(volume as VolumeWithAttachment).node_id ? (
                            <EntityLink
                              type="node_instance"
                              id={`${(volume as VolumeWithAttachment).node_id}:${volume.node_instance_id}`}
                              label={(volume as VolumeWithAttachment).instance_name || 'Attached'}
                            />
                          ) : (
                            <span>{(volume as VolumeWithAttachment).instance_name || 'Attached'}</span>
                          )}
                          {volume.device_name && (
                            <span className="text-theme-secondary font-mono">
                              ({volume.device_name})
                            </span>
                          )}
                        </div>
                      ) : (
                        <div className="flex items-center gap-2 text-theme-tertiary">
                          <Unlink className="w-4 h-4" />
                          <span>Not attached</span>
                        </div>
                      )}
                    </div>
                  </div>
                </div>

                {/* Description */}
                {volume.description && (
                  <div>
                    <label className="block text-sm text-theme-secondary mb-1">Description</label>
                    <p className="text-theme-primary bg-theme-background rounded-lg p-3 border border-theme">
                      {volume.description}
                    </p>
                  </div>
                )}

                {/* Timestamps */}
                <div className="flex items-center gap-6 text-sm text-theme-tertiary pt-4 border-t border-theme">
                  <div className="flex items-center gap-1">
                    <Calendar className="w-4 h-4" />
                    Created: {formatDate(volume.created_at)}
                  </div>
                  <div className="flex items-center gap-1">
                    <Calendar className="w-4 h-4" />
                    Updated: {formatDate(volume.updated_at)}
                  </div>
                </div>

                {/* Snapshots — list + restore (IMP-f17e2c0bae12). The create
                    form above can make a restore point; without this section
                    the only way to use one was the MCP verb. */}
                <div className="pt-4 border-t border-theme space-y-3">
                  <div className="flex items-center gap-2">
                    <History className="w-4 h-4 text-theme-tertiary" />
                    <h4 className="font-medium text-theme-primary">Snapshots</h4>
                  </div>

                  {restoreResult && (
                    <div className="bg-theme-background rounded-lg p-3 border border-theme space-y-1 text-sm">
                      {restoreResult.restored_in_place ? (
                        <p className="text-theme-primary">
                          This volume was <strong>rolled back</strong> to the snapshot. Every
                          write made since it was taken has been discarded.
                        </p>
                      ) : (
                        <p className="text-theme-primary">
                          The snapshot was copied into a <strong>new volume</strong>
                          {restoreResult.restored_volume
                            ? ` — ${restoreResult.restored_volume.name} (${restoreResult.restored_volume.id})`
                            : ''}
                          . This volume is unchanged.
                        </p>
                      )}
                      {restoreResult.swapped && (
                        <p className="text-theme-secondary">
                          Swapped into place at {restoreResult.swapped_device || 'the same device'}
                          {restoreResult.swapped_instance_id
                            ? ` on instance ${restoreResult.swapped_instance_id}`
                            : ''}
                          .
                        </p>
                      )}
                      {restoreResult.swap_skipped && (
                        <p className="text-theme-warning-fg flex items-start gap-1">
                          <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
                          <span>Swap skipped: {restoreResult.swap_skipped}</span>
                        </p>
                      )}
                    </div>
                  )}

                  {restoreFailure && (
                    <div className="bg-theme-danger-bg border border-theme-danger-border/30 rounded-lg p-3 space-y-1 text-sm">
                      <p className="text-theme-error-fg flex items-start gap-1">
                        <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
                        <span>Restore failed: {restoreFailure.message}</span>
                      </p>
                      {typeof restoreFailure.details?.restored_volume_id === 'string' && (
                        <p className="text-theme-error-fg">
                          A copy was already created and is still there — volume{' '}
                          {restoreFailure.details.restored_volume_id}. It is billable until you
                          attach or delete it.
                        </p>
                      )}
                      {typeof restoreFailure.details?.swap_stage === 'string' && (
                        <p className="text-theme-secondary">
                          The swap stopped at: {restoreFailure.details.swap_stage}.
                        </p>
                      )}
                    </div>
                  )}

                  {(() => {
                    if (snapshotsLoading) {
                      return (
                        <div className="flex items-center justify-center py-6">
                          <LoadingSpinner size="sm" />
                        </div>
                      );
                    }
                    if (snapshotsError) {
                      return (
                        <p className="text-sm text-theme-error-fg">
                          Could not load snapshots: {snapshotsError}
                        </p>
                      );
                    }
                    if (snapshots.length === 0) {
                      return (
                        <p className="text-sm text-theme-secondary">
                          No snapshots yet for this volume.
                        </p>
                      );
                    }
                    return (
                      <>
                        <ul className="divide-y divide-theme border border-theme rounded-lg">
                          {snapshots.map((snap) => (
                            <li
                              key={snap.id}
                              className="flex items-center justify-between gap-3 p-3"
                            >
                              <div className="min-w-0">
                                <p className="text-theme-primary font-medium truncate">
                                  {snap.name || snap.id}
                                </p>
                                <p className="text-xs text-theme-tertiary">
                                  {snap.created_at ? formatDate(snap.created_at) : '—'}
                                  {typeof snap.size_gb === 'number' ? ` · ${formatSize(snap.size_gb)}` : ''}
                                </p>
                              </div>
                              <div className="flex items-center gap-2 shrink-0">
                                {snap.status && (
                                  <Badge variant={snap.can_restore ? 'success' : 'secondary'} size="xs">
                                    {snap.status}
                                  </Badge>
                                )}
                                {canManage && snap.can_restore && (
                                  <Button
                                    variant="outline"
                                    size="sm"
                                    onClick={() => requestRestore(snap)}
                                    disabled={!!actionLoading}
                                  >
                                    <RotateCcw className="w-4 h-4 mr-2" />
                                    Restore
                                  </Button>
                                )}
                              </div>
                            </li>
                          ))}
                        </ul>
                        <Pagination
                          currentPage={snapshotsPage}
                          totalPages={snapshotsTotalPages}
                          onPageChange={setSnapshotsPage}
                        />
                      </>
                    );
                  })()}
                </div>

                {/* Actions */}
                {(volume.status === 'available' || volume.status === 'in-use') && (
                  <div className="flex items-center gap-3 pt-4 border-t border-theme">
                    {volume.status === 'in-use' && volume.node_instance_id && (
                      <Button
                        variant="outline"
                        onClick={requestDetach}
                        disabled={actionLoading === 'detach'}
                      >
                        {actionLoading === 'detach' ? (
                          <LoadingSpinner size="sm" className="mr-2" />
                        ) : (
                          <Unlink className="w-4 h-4 mr-2" />
                        )}
                        Detach Volume
                      </Button>
                    )}
                    {canSnapshot && (
                      <Button
                        variant="outline"
                        onClick={() => setShowSnapshotModal(true)}
                        disabled={!!actionLoading}
                      >
                        <Camera className="w-4 h-4 mr-2" />
                        Create Snapshot
                      </Button>
                    )}
                  </div>
                )}
              </div>
            ) : (
              <div className="text-center py-12">
                <HardDrive className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
                <p className="text-theme-secondary">Volume not found</p>
              </div>
            )}
          </div>
    </Modal>

      {/* Snapshot Modal — nested above the detail dialog. */}
      {showSnapshotModal && (
        <Modal
          isOpen
          onClose={() => {
            setShowSnapshotModal(false);
            setSnapshotName('');
            setSnapshotDescription('');
          }}
          title="Create Snapshot"
          icon={<Camera className="w-6 h-6" />}
          maxWidth="md"
          footer={
            <>
              <Button variant="outline" onClick={() => {
                setShowSnapshotModal(false);
                setSnapshotName('');
                setSnapshotDescription('');
              }}>
                Cancel
              </Button>
              <Button
                variant="primary"
                onClick={handleCreateSnapshot}
                disabled={actionLoading === 'snapshot'}
              >
                {actionLoading === 'snapshot' ? (
                  <>
                    <LoadingSpinner size="sm" className="mr-2" />
                    Creating...
                  </>
                ) : (
                  'Create Snapshot'
                )}
              </Button>
            </>
          }
        >
            <div className="space-y-4">
              <div>
                <label htmlFor="snapshot-name" className="block text-sm font-medium text-theme-primary mb-1">
                  Snapshot Name
                </label>
                <input
                  id="snapshot-name"
                  type="text"
                  value={snapshotName}
                  onChange={(e) => setSnapshotName(e.target.value)}
                  placeholder={`${volume?.name}-snapshot`}
                  className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                />
              </div>
              <div>
                <label htmlFor="snapshot-description" className="block text-sm font-medium text-theme-primary mb-1">
                  Description (optional)
                </label>
                <textarea
                  id="snapshot-description"
                  value={snapshotDescription}
                  onChange={(e) => setSnapshotDescription(e.target.value)}
                  placeholder="Snapshot description"
                  rows={2}
                  className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus resize-none"
                />
              </div>
            </div>
        </Modal>
      )}

      {ConfirmationDialog}
    </>
  );
};

export default VolumeDetailModal;
