import { FC } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { BootReplayTimeline } from './BootReplayTimeline';

interface BootReplayModalProps {
  // null/undefined keeps the modal closed; passing an instanceId opens
  // it. correlationId optionally narrows to a specific boot session.
  instanceId: string | null;
  correlationId?: string;
  onClose: () => void;
}

/**
 * BootReplayModal — modal-based boot timeline viewer for a NodeInstance.
 * Replaces the prior standalone /system/boot-replay/:instance_id page;
 * operators reach this from the Fleet Dashboard's event detail panel
 * (and any future entry points) without leaving their context.
 *
 * Permission gate: system.fleet.autonomy (mirrors the prior page's
 * gate). Operators without the permission see a clear refusal rather
 * than an empty modal.
 */
export const BootReplayModal: FC<BootReplayModalProps> = ({
  instanceId,
  correlationId,
  onClose,
}) => {
  const { hasPermission } = usePermissions();
  const isOpen = instanceId !== null;
  const subtitle = instanceId
    ? `Instance ${instanceId.slice(0, 8)}${correlationId ? ` · session ${correlationId.slice(0, 8)}` : ''}`
    : undefined;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Boot Replay"
      subtitle={subtitle}
      size="6xl"
    >
      <div className="min-h-[60vh]">
        {!hasPermission('system.fleet.autonomy') ? (
          <div className="p-6 text-sm text-theme-tertiary">
            You don&apos;t have permission to view boot replays.
            Required: <code>system.fleet.autonomy</code>
          </div>
        ) : (
          <BootReplayTimeline instanceId={instanceId} correlationId={correlationId} />
        )}
      </div>
    </Modal>
  );
};
