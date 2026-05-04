import React, { useState, useMemo } from 'react';
import { Routes, Route, Link, Navigate, useLocation } from 'react-router-dom';
import { Plus } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import {
  FleetTab,
  TasksTab,
  CiWorkersTab,
  CiWebhooksTab,
} from '@system/features/system/components/operations';

// Phase B.3 — Operations hub. Consolidates Fleet Dashboard, Tasks
// (formerly /system/tasks "Operations"), CI Workers, and CI Webhooks
// into one tabbed page. Path-based tabs match the canonical
// AdminSettingsPage pattern.

type TabKey = 'fleet' | 'tasks' | 'ci-workers' | 'ci-webhooks';

const TABS: { key: TabKey; label: string; permission: string }[] = [
  { key: 'fleet', label: 'Fleet', permission: 'system.fleet.autonomy' },
  { key: 'tasks', label: 'Tasks', permission: 'system.tasks.read' },
  { key: 'ci-workers', label: 'CI Workers', permission: 'system.ci_workers.read' },
  { key: 'ci-webhooks', label: 'CI Webhooks', permission: 'system.disk_image_webhooks.read' },
];

const BASE_PATH = '/app/system/operations';

const OperationsHubPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const location = useLocation();

  const visibleTabs = useMemo(
    () => TABS.filter((t) => hasPermission(t.permission)),
    [hasPermission]
  );

  const activeTabKey = useMemo<TabKey>(() => {
    const match = TABS.find((t) => location.pathname.endsWith(`/${t.key}`));
    if (match) return match.key;
    return (visibleTabs[0]?.key ?? 'fleet') as TabKey;
  }, [location.pathname, visibleTabs]);

  const [ciWorkersActions, setCiWorkersActions] = useState<{ openCreate: () => void } | null>(null);
  const [ciWebhooksActions, setCiWebhooksActions] = useState<{ openCreate: () => void } | null>(null);

  const canCreateCiWorkers = hasPermission('system.ci_workers.create');
  const canCreateCiWebhooks = hasPermission('system.disk_image_webhooks.create');

  const pageActions: PageAction[] = [];
  if (activeTabKey === 'ci-workers' && canCreateCiWorkers && ciWorkersActions) {
    pageActions.push({ label: 'New CI worker', onClick: ciWorkersActions.openCreate, variant: 'primary', icon: Plus });
  } else if (activeTabKey === 'ci-webhooks' && canCreateCiWebhooks && ciWebhooksActions) {
    pageActions.push({ label: 'New webhook', onClick: ciWebhooksActions.openCreate, variant: 'primary', icon: Plus });
  }

  if (visibleTabs.length === 0) {
    return (
      <PageContainer title="Operations">
        <div className="p-6 text-sm text-theme-secondary">
          You don&apos;t have permission to view any Operations resources.
        </div>
      </PageContainer>
    );
  }

  const defaultTabKey = visibleTabs[0].key;

  return (
    <PageContainer
      title="Operations"
      description="Live fleet autonomy, the system-task queue, and CI integration tokens — what's running and how it integrates with your build pipeline."
      breadcrumbs={[
        { label: 'System', href: '/app/system' },
        { label: 'Operations' },
      ]}
      actions={pageActions}
    >
      <div className="border-b border-theme mb-4">
        <nav className="flex gap-2 flex-wrap">
          {visibleTabs.map((t) => {
            const active = activeTabKey === t.key;
            return (
              <Link
                key={t.key}
                to={`${BASE_PATH}/${t.key}`}
                className={
                  'px-3 py-2 text-sm font-medium border-b-2 transition-colors ' +
                  (active
                    ? 'border-theme-focus text-theme-primary'
                    : 'border-transparent text-theme-secondary hover:text-theme-primary')
                }
              >
                {t.label}
              </Link>
            );
          })}
        </nav>
      </div>

      <Routes>
        <Route index element={<Navigate to={defaultTabKey} replace />} />
        <Route path="fleet" element={<FleetTab />} />
        <Route path="tasks" element={<TasksTab />} />
        <Route path="ci-workers" element={<CiWorkersTab onActionsReady={setCiWorkersActions} />} />
        <Route path="ci-webhooks" element={<CiWebhooksTab onActionsReady={setCiWebhooksActions} />} />
        <Route path="*" element={<Navigate to={defaultTabKey} replace />} />
      </Routes>
    </PageContainer>
  );
};

export default OperationsHubPage;
