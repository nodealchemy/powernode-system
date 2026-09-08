import React, { useState, useMemo } from 'react';
import { Routes, Route, Navigate, useLocation } from 'react-router-dom';
import { FileText, Package, FileCode, Cpu, Layers, FolderTree, Database } from 'lucide-react';
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
  TemplatesTab,
  ModulesTab,
  PuppetModulesTab,
  ScriptsTab,
  ArchitecturesTab,
  PlatformsTab,
  MarketplaceTab,
  PackageRepositoriesTab,
} from '@system/features/system/components/catalog';

// Phase B.2 — Catalog hub. Consolidates 7 build-time registry pages
// (Templates, Modules, Puppet Modules, Scripts, Architectures,
// Platforms, Marketplace) into a single tabbed page following the
// canonical platform pattern (path-based tabs, AdminSettingsPage).

type TabKey =
  | 'templates'
  | 'modules'
  | 'package-repositories'
  | 'puppet-modules'
  | 'scripts'
  | 'architectures'
  | 'platforms'
  | 'marketplace';

const TABS: PathTabSpec<TabKey>[] = [
  { key: 'templates', label: 'Templates', permission: 'system.templates.read' },
  { key: 'modules', label: 'Modules', permission: 'system.modules.read' },
  { key: 'package-repositories', label: 'Package Repositories', permission: 'system.package_repositories.view' },
  { key: 'puppet-modules', label: 'Puppet Modules', permission: 'system.puppet.read' },
  { key: 'scripts', label: 'Scripts', permission: 'system.scripts.read' },
  { key: 'architectures', label: 'Architectures', permission: 'system.architectures.read' },
  { key: 'platforms', label: 'Platforms', permission: 'system.platforms.read' },
  { key: 'marketplace', label: 'Marketplace', permission: 'system.marketplace.read' },
];

const BASE_PATH = '/app/system/catalog';

const CatalogPage: React.FC = () => {
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
      ((TABS.find((t) => hasPermission(t.permission))?.key ?? 'templates') as TabKey),
    [location.pathname, hasPermission],
  );

  const [templatesActions, setTemplatesActions] = useState<{ openCreate: () => void } | null>(null);
  const [modulesActions, setModulesActions] = useState<
    { openCreate: () => void; openCreateCategory: () => void } | null
  >(null);
  const [puppetActions, setPuppetActions] = useState<{ openCreate: () => void } | null>(null);
  const [packageRepoActions, setPackageRepoActions] = useState<{ openCreate: () => void } | null>(null);
  const [scriptsActions, setScriptsActions] = useState<{ openCreate: () => void } | null>(null);
  const [architecturesActions, setArchitecturesActions] = useState<{ openCreate: () => void } | null>(null);
  const [platformsActions, setPlatformsActions] = useState<{ openCreate: () => void } | null>(null);

  const canCreateTemplates = hasPermission('system.templates.create');
  const canCreateModules = hasPermission('system.modules.create');
  const canCreatePuppet = hasPermission('system.puppet.create');
  const canCreatePackageRepo = hasPermission('system.package_repositories.create');
  const canCreateScripts = hasPermission('system.scripts.create');
  const canCreateArchitectures = hasPermission('system.architectures.create');
  const canCreatePlatforms = hasPermission('system.platforms.create');

  const pageActions: PageAction[] = [];
  if (activeTabKey === 'templates' && canCreateTemplates && templatesActions) {
    pageActions.push({ label: 'Create Template', onClick: templatesActions.openCreate, variant: 'primary', icon: FileText });
  } else if (activeTabKey === 'modules' && canCreateModules && modulesActions) {
    pageActions.push({ label: 'Create Module', onClick: modulesActions.openCreate, variant: 'primary', icon: Package });
    pageActions.push({ label: 'New Category', onClick: modulesActions.openCreateCategory, variant: 'secondary', icon: FolderTree });
  } else if (activeTabKey === 'package-repositories' && canCreatePackageRepo && packageRepoActions) {
    pageActions.push({ label: 'Add Repository', onClick: packageRepoActions.openCreate, variant: 'primary', icon: Database });
  } else if (activeTabKey === 'puppet-modules' && canCreatePuppet && puppetActions) {
    pageActions.push({ label: 'Add Puppet Module', onClick: puppetActions.openCreate, variant: 'primary', icon: Package });
  } else if (activeTabKey === 'scripts' && canCreateScripts && scriptsActions) {
    pageActions.push({ label: 'Create Script', onClick: scriptsActions.openCreate, variant: 'primary', icon: FileCode });
  } else if (activeTabKey === 'architectures' && canCreateArchitectures && architecturesActions) {
    pageActions.push({ label: 'Create Architecture', onClick: architecturesActions.openCreate, variant: 'primary', icon: Cpu });
  } else if (activeTabKey === 'platforms' && canCreatePlatforms && platformsActions) {
    pageActions.push({ label: 'Create Platform', onClick: platformsActions.openCreate, variant: 'primary', icon: Layers });
  }

  if (!firstPath) {
    return (
      <PageContainer title="Catalog">
        <div className="p-6 text-sm text-theme-secondary">
          You don&apos;t have permission to view any Catalog resources.
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer
      title="Catalog"
      description="Build-time registry: templates, modules, scripts, architectures, platforms, and the module marketplace — the components that compose your fleet."
      breadcrumbs={[
        { label: 'System', href: '/app/system' },
        { label: 'Catalog' },
      ]}
      actions={pageActions}
    >
      <PathTabs tabs={TABS} basePath={BASE_PATH} hasPermission={hasPermission}>
        <Routes>
          <Route index element={<Navigate to={firstPath} replace />} />
          <Route path="templates" element={<TemplatesTab onActionsReady={setTemplatesActions} />} />
          <Route path="modules" element={<ModulesTab onActionsReady={setModulesActions} />} />
          <Route path="package-repositories" element={<PackageRepositoriesTab onActionsReady={setPackageRepoActions} />} />
          <Route path="puppet-modules" element={<PuppetModulesTab onActionsReady={setPuppetActions} />} />
          <Route path="scripts" element={<ScriptsTab onActionsReady={setScriptsActions} />} />
          <Route path="architectures" element={<ArchitecturesTab onActionsReady={setArchitecturesActions} />} />
          <Route path="platforms" element={<PlatformsTab onActionsReady={setPlatformsActions} />} />
          <Route path="marketplace" element={<MarketplaceTab />} />
          <Route path="*" element={<Navigate to={firstPath} replace />} />
        </Routes>
      </PathTabs>
    </PageContainer>
  );
};

export default CatalogPage;
