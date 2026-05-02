import React from 'react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { FleetDashboardPage as FleetDashboardComponent } from '@system/features/system/components/fleet/FleetDashboardPage';

// Page-level wrapper for the FleetDashboard. The PageContainer provides
// the standard chrome (breadcrumb, action bar slot) that operator pages
// share; the FleetDashboardComponent renders the live grid + correlation
// chain inside.
//
// Reference: Golden Eclipse plan M-FE-3.
const FleetDashboardPageWrapper: React.FC = () => {
  const { hasPermission } = usePermissions();

  if (!hasPermission('system.fleet.autonomy')) {
    return (
      <PageContainer title="Fleet Dashboard">
        <div className="p-6 text-sm text-theme-muted">
          You don't have permission to view the fleet dashboard.
          Required: <code>system.fleet.autonomy</code>
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer title="Fleet Dashboard">
      <FleetDashboardComponent />
    </PageContainer>
  );
};

export default FleetDashboardPageWrapper;
export { FleetDashboardPageWrapper as FleetDashboardPage };
