import React, { useCallback, useState } from 'react';
import { RefreshCw } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { ModuleBuildsTab } from '@system/features/system/components/operations/ModuleBuildsTab';

/**
 * Module Builds — standalone page (fc-34).
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
 * Registered at the SAME URL the core tab used
 * (/app/devops/ci-cd/module-builds) so existing bookmarks and links keep
 * resolving — a real route, not a redirect. It no longer lives inside
 * CiCdPage's tab strip (core must not host an extension component), so it is
 * reachable instead from the DevOps sidebar section (registered nav item,
 * see register.ts) as its own page, with its own breadcrumbs back to CI/CD.
 */
export const ModuleBuildsPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const canRead = hasPermission('system.module_builds.read');
  const [actions, setActions] = useState<PageAction[]>([]);

  const handleActionsReady = useCallback((handle: { refresh: () => void } | null) => {
    setActions(
      handle
        ? [{ label: 'Refresh', onClick: handle.refresh, variant: 'secondary', icon: RefreshCw }]
        : [],
    );
  }, []);

  const breadcrumbs = [
    { label: 'Dashboard', href: '/app' },
    { label: 'DevOps', href: '/app/devops' },
    { label: 'CI/CD', href: '/app/devops/ci-cd' },
    { label: 'Module Builds' },
  ];

  if (!canRead) {
    return (
      <PageContainer title="Module Builds" breadcrumbs={breadcrumbs}>
        <div className="p-6 text-sm text-theme-secondary">
          You don&apos;t have permission to view module build batches.
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer
      title="Module Builds"
      description="Operator-visible unit of a native module-build run — platform rebuilds (push/manual/CVE) and on-demand package-closure builds."
      breadcrumbs={breadcrumbs}
      actions={actions}
    >
      <ModuleBuildsTab onActionsReady={handleActionsReady} />
    </PageContainer>
  );
};

export default ModuleBuildsPage;
