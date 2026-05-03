import { FC } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { BootReplayTimeline } from '../../../features/system/components/fleet/boot-replay/BootReplayTimeline';

// Boot Replay page wrapper. Accepts the NodeInstance UUID via the URL
// path (`/system/boot-replay/:instance_id`), with an optional
// `correlation_id` query param for filtering to a specific boot session.
//
// Permission gate: system.fleet.autonomy (same as the Fleet Dashboard).
//
// Reference: comprehensive stabilization sweep P7.1 — completes M-FE-3.
const BootReplayPage: FC = () => {
  const { hasPermission } = usePermissions();
  const { instance_id: instanceId } = useParams<{ instance_id: string }>();
  const [searchParams] = useSearchParams();
  const correlationId = searchParams.get('correlation_id') ?? undefined;

  if (!hasPermission('system.fleet.autonomy')) {
    return (
      <PageContainer title="Boot Replay">
        <div className="p-6 text-sm text-theme-muted">
          You don't have permission to view boot replays.
          Required: <code>system.fleet.autonomy</code>
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer title={instanceId ? `Boot Replay — ${instanceId.slice(0, 8)}…` : 'Boot Replay'}>
      <BootReplayTimeline instanceId={instanceId ?? null} correlationId={correlationId} />
    </PageContainer>
  );
};

export default BootReplayPage;
