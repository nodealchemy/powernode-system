import React from 'react';
import { Badge } from '@/shared/components/ui/Badge';
import type { SystemTask } from '@system/features/system/types/system.types';

/**
 * Status badge for a node or instance. Status values come from
 * System::NodeInstance::STATUSES: pending | provisioning | starting |
 * running | stopping | stopped | rebooting | terminated | error.
 * Pure — no closure over NodeDetailModal state — shared by InfoTab and
 * InstancesTab.
 */
export function getStatusBadge(status?: string, enabled?: boolean): React.ReactElement {
  if (enabled === false) {
    return <Badge variant="secondary">Disabled</Badge>;
  }
  switch (status) {
    case 'running':
      return <Badge variant="success" dot pulse>Running</Badge>;
    case 'stopped':
      return <Badge variant="secondary">Stopped</Badge>;
    case 'pending':
      return <Badge variant="warning" dot pulse>Pending</Badge>;
    case 'provisioning':
      return <Badge variant="info" dot pulse>Provisioning</Badge>;
    case 'starting':
      return <Badge variant="info" dot pulse>Starting</Badge>;
    case 'stopping':
      return <Badge variant="warning" dot pulse>Stopping</Badge>;
    case 'rebooting':
      return <Badge variant="warning" dot pulse>Rebooting</Badge>;
    case 'terminated':
      return <Badge variant="secondary">Terminated</Badge>;
    case 'error':
    case 'failed':
      return <Badge variant="danger">Failed</Badge>;
    default:
      return enabled ? <Badge variant="success">Enabled</Badge> : <Badge variant="secondary">Unknown</Badge>;
  }
}

/** Operation status badge. Pure, shared with OperationsTab. */
export function getOperationStatusBadge(status: SystemTask['status']): React.ReactElement {
  switch (status) {
    case 'pending':
      return <Badge variant="warning">Pending</Badge>;
    case 'scheduled':
      return <Badge variant="info">Scheduled</Badge>;
    case 'running':
      return <Badge variant="primary" dot pulse>Running</Badge>;
    case 'complete':
      return <Badge variant="success">Complete</Badge>;
    case 'failed':
      return <Badge variant="danger">Failed</Badge>;
    case 'aborted':
    case 'cancelled':
      return <Badge variant="secondary">{status.charAt(0).toUpperCase() + status.slice(1)}</Badge>;
    default:
      return <Badge variant="default">{status}</Badge>;
  }
}
