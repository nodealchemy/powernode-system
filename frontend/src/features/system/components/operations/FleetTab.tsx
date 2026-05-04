import React from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { FleetDashboardPage as FleetDashboardComponent } from '@system/features/system/components/fleet/FleetDashboardPage';

// Phase B.3 — Operations hub tab. Read-only fleet dashboard
// (autonomy grid + correlation chains). No page-level actions.
export const FleetTab: React.FC = () => {
  const { hasPermission } = usePermissions();

  if (!hasPermission('system.fleet.autonomy')) {
    return (
      <div className="p-6 text-sm text-theme-secondary">
        You don&apos;t have permission to view the fleet dashboard.
        Required: <code>system.fleet.autonomy</code>
      </div>
    );
  }

  return <FleetDashboardComponent />;
};
