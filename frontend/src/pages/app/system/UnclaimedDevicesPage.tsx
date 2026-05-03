import React from 'react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { UnclaimedDevicesPanel } from '@system/features/system/components/nodes/UnclaimedDevicesPanel';

// Top-level page wrapper around UnclaimedDevicesPanel.
// Operators land here from the System nav to see physical devices
// polling /node_api/claim that haven't been bound yet.
//
// Plan: docs/plans/wondrous-yawning-anchor.md §7.
const UnclaimedDevicesPageWrapper: React.FC = () => {
  const { hasPermission } = usePermissions();

  if (!hasPermission('system.unclaimed_devices.read')) {
    return (
      <PageContainer title="Unclaimed Devices">
        <div className="p-6 text-sm text-theme-muted">
          You don&apos;t have permission to view unclaimed devices.
          Required: <code>system.unclaimed_devices.read</code>
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer title="Unclaimed Devices">
      <div className="p-4 space-y-4">
        <p className="text-sm text-theme-secondary">
          Physical devices that have polled <code>/api/v1/system/node_api/claim</code> but
          haven&apos;t been bound to a NodeInstance yet. Confirm a device&apos;s identity
          to issue a single-use bootstrap token on its next poll.
        </p>
        <UnclaimedDevicesPanel />
      </div>
    </PageContainer>
  );
};

export default UnclaimedDevicesPageWrapper;
export { UnclaimedDevicesPageWrapper as UnclaimedDevicesPage };
