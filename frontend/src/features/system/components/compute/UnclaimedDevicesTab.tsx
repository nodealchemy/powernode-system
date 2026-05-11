import React from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { UnclaimedDevicesPanel } from '@system/features/system/components/nodes/UnclaimedDevicesPanel';

// Phase B.1 — Compute hub tab. Read-only panel; no page-level actions
// (the panel itself has its own row-level claim/dismiss buttons).
export const UnclaimedDevicesTab: React.FC = () => {
  const { hasPermission } = usePermissions();

  if (!hasPermission('system.unclaimed_devices.read')) {
    return (
      <div className="p-6 text-sm text-theme-tertiary">
        You don&apos;t have permission to view unclaimed devices.
        Required: <code>system.unclaimed_devices.read</code>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-theme-secondary">
        Physical devices that have polled <code>/api/v1/system/node_api/claim</code> but
        haven&apos;t been bound to a NodeInstance yet. Confirm a device&apos;s identity
        to issue a single-use bootstrap token on its next poll.
      </p>
      <UnclaimedDevicesPanel />
    </div>
  );
};
