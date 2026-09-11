import { FC } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import type { ComponentStatusDetail } from '@/shared/types/platformStatus';
import { BootReplayTimeline } from './BootReplayTimeline';

interface BootReplayDrawerViewProps {
  row: ComponentStatusDetail;
}

/**
 * The component status drawer's boot-replay view for `node_instance`,
 * registered at `platform.status.drawer.node_instance.boot_replay`.
 *
 * INLINE, not BootReplayModal: the drawer is already a Modal (variant
 * "drawer"), and nesting a second Modal inside its Boot replay tab would
 * stack two overlays for what reads as one panel. This renders
 * BootReplayTimeline directly, carrying over BootReplayModal's permission
 * gate verbatim (see review-lane4 boot-replay ruling: "Boot replay inline,
 * with no nested Modal, is approved. Keep the inline refusal that names
 * system.fleet.read.").
 *
 * `instanceId` comes from `row.component_ref` — NodeInstanceContributor
 * defines `ref_for(record) = record.id.to_s`, so for kind "node_instance"
 * the ref IS the NodeInstance id. No `correlationId`: the drawer has no
 * notion of a specific boot session, so BootReplayTimeline shows every
 * session for the instance, exactly like BootReplayModal's own default
 * (undefined correlationId) when opened without one.
 */
export const BootReplayDrawerView: FC<BootReplayDrawerViewProps> = ({ row }) => {
  const { hasPermission } = usePermissions();

  if (!hasPermission('system.fleet.read')) {
    return (
      <div className="p-4 text-sm text-theme-tertiary">
        You don&apos;t have permission to view boot replays.
        Required: <code>system.fleet.read</code>
      </div>
    );
  }

  return (
    <div className="min-h-[40vh]">
      <BootReplayTimeline instanceId={row.component_ref} />
    </div>
  );
};

export default BootReplayDrawerView;
