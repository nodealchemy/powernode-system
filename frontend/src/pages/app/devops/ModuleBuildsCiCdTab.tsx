import React, { useCallback } from 'react';
import { RefreshCw } from 'lucide-react';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { ModuleBuildsTab } from '@system/features/system/components/operations/ModuleBuildsTab';

/**
 * Module Builds — CI/CD tab slot component (fc-34, revised per review).
 *
 * Was previously TWO surfaces: a DevOps → CI/CD tab in core
 * (ModuleBuildsPage/ModuleBuildDetailPage — a URL-only cross-boundary seam
 * onto this extension's System::ModuleBuildBatch API, no code crossing the
 * boundary) and this extension's read-only Operations → Module Builds tab
 * (ModuleBuildsTab, live via SystemFleetChannel). The core surface is deleted
 * as the duplicate; this extension's tab absorbed its Cancel action and
 * permission gating (system.module_builds.cancel — see ModuleBuildsTab's own
 * header comment) and is now the one canonical surface.
 *
 * Review fix: an EARLIER version of this fc-34 slice registered this as a
 * standalone route (featureRegistry.registerRoutes) plus a DevOps sidebar
 * nav item, pulling the tab OUT of CiCdPage entirely. Review found that
 * broke the CI/CD tab strip's own affordance and left the surface with no
 * page chrome (breadcrumbs, page-level actions) unless duplicated here. This
 * component instead registers as a `devops.ci-cd.tab.module-builds`
 * COMPONENT SLOT (CiCdPage.tsx's generic `devops.ci-cd.tab.*` seam — the same
 * `registerComponentSlots` + `getComponentSlotIds(prefix)` pattern
 * ComponentStatusDrawer.tsx uses), so it mounts INSIDE CiCdPage's existing
 * tab strip and PageContainer at /app/devops/ci-cd/module-builds — a real,
 * URL-addressable tab, discovered generically without core importing or
 * naming this extension. No separate route or nav-item registration: nothing
 * in core enforces FeatureRoute.permission, so this component's own
 * `hasPermission` check below is the actual gate, same as it would have been
 * on a standalone route.
 */
export const ModuleBuildsCiCdTab: React.FC<{ onActionsReady?: (actions: PageAction[]) => void }> = ({
  onActionsReady,
}) => {
  const { hasPermission } = usePermissions();
  const canRead = hasPermission('system.module_builds.read');

  const handleActionsReady = useCallback(
    (handle: { refresh: () => void } | null) => {
      onActionsReady?.(
        handle
          ? [{ label: 'Refresh', onClick: handle.refresh, variant: 'secondary', icon: RefreshCw }]
          : [],
      );
    },
    [onActionsReady],
  );

  if (!canRead) {
    return (
      <div className="p-6 text-sm text-theme-secondary">
        You don&apos;t have permission to view module build batches.
      </div>
    );
  }

  return <ModuleBuildsTab onActionsReady={handleActionsReady} />;
};

export default ModuleBuildsCiCdTab;
