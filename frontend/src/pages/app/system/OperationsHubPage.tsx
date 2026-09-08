import React, { useState, useMemo } from 'react';
import { Routes, Route, Navigate, useLocation } from 'react-router-dom';
import { Plus, RefreshCw, Settings } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import {
  PathTabs,
  firstAccessibleTabPath,
  activeTabKeyFromPath,
  type PathTabSpec,
} from '@/shared/components/navigation/PathTabs';
import { usePermissions } from '@/shared/hooks/usePermissions';
import {
  FleetTab,
  TasksTab,
  CiWorkersTab,
  CiWebhooksTab,
  GitopsTab,
  CveTab,
  ModuleBuildsTab,
  AgentPeersTab,
} from '@system/features/system/components/operations';
import { SystemSettingsPanel } from '@system/features/system/components/settings/SystemSettingsPanel';

// Phase B.3 — Operations hub. Consolidates Fleet Dashboard, Tasks
// (formerly /system/tasks "Operations"), CI Workers, and CI Webhooks
// into one tabbed page. Path-based tabs match the canonical
// AdminSettingsPage pattern.

type TabKey = 'fleet' | 'tasks' | 'gitops' | 'cve' | 'agent-peers' | 'ci-workers' | 'ci-webhooks' | 'module-builds';

const TABS: PathTabSpec<TabKey>[] = [
  { key: 'fleet', label: 'Fleet', permission: 'system.fleet.read' },
  { key: 'tasks', label: 'Tasks', permission: 'system.tasks.read' },
  { key: 'gitops', label: 'GitOps', permission: 'system.gitops.read' },
  { key: 'cve', label: 'CVE', permission: 'system.cve.read' },
  // NodeInstance-as-Agent peers (IMP-20c082f9d519) — distinct from the
  // platform federation peers under Compute → Platform → Peers.
  { key: 'agent-peers', label: 'Agent Peers', permission: 'system.peers.read' },
  { key: 'ci-workers', label: 'CI Workers', permission: 'system.ci_workers.read' },
  { key: 'ci-webhooks', label: 'CI Webhooks', permission: 'system.disk_image_webhooks.read' },
  { key: 'module-builds', label: 'Module Builds', permission: 'system.module_builds.read' },
];

const BASE_PATH = '/app/system/operations';

const OperationsHubPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const location = useLocation();
  const firstPath = firstAccessibleTabPath(TABS, BASE_PATH, hasPermission);

  // Drives the page actions below. Uses PathTabs' own derivation so the
  // strip and the actions can never disagree. Falls back to the first
  // visible tab on the bare hub path, which the index route below is
  // about to redirect anyway.
  const activeTabKey = useMemo<TabKey>(
    () =>
      activeTabKeyFromPath(TABS, BASE_PATH, location.pathname) ??
      ((TABS.find((t) => hasPermission(t.permission))?.key ?? 'fleet') as TabKey),
    [location.pathname, hasPermission],
  );

  const [gitopsActions, setGitopsActions] = useState<{ openCreate: () => void } | null>(null);
  const [cveActions, setCveActions] = useState<{ refresh: () => void } | null>(null);
  const [ciWorkersActions, setCiWorkersActions] = useState<{ openCreate: () => void } | null>(null);
  const [ciWebhooksActions, setCiWebhooksActions] = useState<{ openCreate: () => void } | null>(null);
  const [moduleBuildsActions, setModuleBuildsActions] = useState<{ refresh: () => void } | null>(null);
  const [agentPeersActions, setAgentPeersActions] = useState<{ refresh: () => void } | null>(null);
  const [showSettings, setShowSettings] = useState(false);

  const canCreateGitops = hasPermission('system.gitops.write');
  const canCreateCiWorkers = hasPermission('system.ci_workers.create');
  const canCreateCiWebhooks = hasPermission('system.disk_image_webhooks.create');
  const canViewSettings = hasPermission('system.infra_tasks.read');

  const pageActions: PageAction[] = [];
  if (canViewSettings) {
    pageActions.push({ label: 'Settings', onClick: () => setShowSettings(true), variant: 'secondary', icon: Settings });
  }
  if (activeTabKey === 'gitops' && canCreateGitops && gitopsActions) {
    pageActions.push({ label: 'New repository', onClick: gitopsActions.openCreate, variant: 'primary', icon: Plus });
  } else if (activeTabKey === 'cve' && cveActions) {
    pageActions.push({ label: 'Refresh', onClick: cveActions.refresh, variant: 'secondary', icon: RefreshCw });
  } else if (activeTabKey === 'ci-workers' && canCreateCiWorkers && ciWorkersActions) {
    pageActions.push({ label: 'New CI worker', onClick: ciWorkersActions.openCreate, variant: 'primary', icon: Plus });
  } else if (activeTabKey === 'ci-webhooks' && canCreateCiWebhooks && ciWebhooksActions) {
    pageActions.push({ label: 'New webhook', onClick: ciWebhooksActions.openCreate, variant: 'primary', icon: Plus });
  } else if (activeTabKey === 'module-builds' && moduleBuildsActions) {
    pageActions.push({ label: 'Refresh', onClick: moduleBuildsActions.refresh, variant: 'secondary', icon: RefreshCw });
  } else if (activeTabKey === 'agent-peers' && agentPeersActions) {
    pageActions.push({ label: 'Refresh', onClick: agentPeersActions.refresh, variant: 'secondary', icon: RefreshCw });
  }

  if (!firstPath) {
    return (
      <PageContainer title="Operations">
        <div className="p-6 text-sm text-theme-secondary">
          You don&apos;t have permission to view any Operations resources.
        </div>
      </PageContainer>
    );
  }

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
      <PathTabs tabs={TABS} basePath={BASE_PATH} hasPermission={hasPermission}>
        <Routes>
          <Route index element={<Navigate to={firstPath} replace />} />
          <Route path="fleet" element={<FleetTab />} />
          <Route path="tasks" element={<TasksTab />} />
          <Route path="gitops" element={<GitopsTab onActionsReady={setGitopsActions} />} />
          <Route path="cve" element={<CveTab onActionsReady={setCveActions} />} />
          <Route path="agent-peers" element={<AgentPeersTab onActionsReady={setAgentPeersActions} />} />
          <Route path="ci-workers" element={<CiWorkersTab onActionsReady={setCiWorkersActions} />} />
          <Route path="ci-webhooks" element={<CiWebhooksTab onActionsReady={setCiWebhooksActions} />} />
          <Route path="module-builds" element={<ModuleBuildsTab onActionsReady={setModuleBuildsActions} />} />
          <Route path="*" element={<Navigate to={firstPath} replace />} />
        </Routes>
      </PathTabs>

      <SystemSettingsPanel isOpen={showSettings} onClose={() => setShowSettings(false)} />
    </PageContainer>
  );
};

export default OperationsHubPage;
