import React, { useState, useMemo } from 'react';
import { Routes, Route, Link, Navigate, useLocation } from 'react-router-dom';
import { FileText, Package, FileCode, Cpu, Layers, FolderTree } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import {
  TemplatesTab,
  ModulesTab,
  PuppetModulesTab,
  ScriptsTab,
  ArchitecturesTab,
  PlatformsTab,
  MarketplaceTab,
} from '@system/features/system/components/catalog';

// Phase B.2 — Catalog hub. Consolidates 7 build-time registry pages
// (Templates, Modules, Puppet Modules, Scripts, Architectures,
// Platforms, Marketplace) into a single tabbed page following the
// canonical platform pattern (path-based tabs, AdminSettingsPage).

type TabKey =
  | 'templates'
  | 'modules'
  | 'puppet-modules'
  | 'scripts'
  | 'architectures'
  | 'platforms'
  | 'marketplace';

const TABS: { key: TabKey; label: string; permission: string }[] = [
  { key: 'templates', label: 'Templates', permission: 'system.templates.read' },
  { key: 'modules', label: 'Modules', permission: 'system.modules.read' },
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

  const visibleTabs = useMemo(
    () => TABS.filter((t) => hasPermission(t.permission)),
    [hasPermission]
  );

  const activeTabKey = useMemo<TabKey>(() => {
    const match = TABS.find((t) => location.pathname.endsWith(`/${t.key}`));
    if (match) return match.key;
    return (visibleTabs[0]?.key ?? 'templates') as TabKey;
  }, [location.pathname, visibleTabs]);

  const [templatesActions, setTemplatesActions] = useState<{ openCreate: () => void } | null>(null);
  const [modulesActions, setModulesActions] = useState<
    { openCreate: () => void; openCreateCategory: () => void } | null
  >(null);
  const [puppetActions, setPuppetActions] = useState<{ openCreate: () => void } | null>(null);
  const [scriptsActions, setScriptsActions] = useState<{ openCreate: () => void } | null>(null);
  const [architecturesActions, setArchitecturesActions] = useState<{ openCreate: () => void } | null>(null);
  const [platformsActions, setPlatformsActions] = useState<{ openCreate: () => void } | null>(null);

  const canCreateTemplates = hasPermission('system.templates.create');
  const canCreateModules = hasPermission('system.modules.create');
  const canCreatePuppet = hasPermission('system.puppet.create');
  const canCreateScripts = hasPermission('system.scripts.create');
  const canCreateArchitectures = hasPermission('system.architectures.create');
  const canCreatePlatforms = hasPermission('system.platforms.create');

  const pageActions: PageAction[] = [];
  if (activeTabKey === 'templates' && canCreateTemplates && templatesActions) {
    pageActions.push({ label: 'Create Template', onClick: templatesActions.openCreate, variant: 'primary', icon: FileText });
  } else if (activeTabKey === 'modules' && canCreateModules && modulesActions) {
    pageActions.push({ label: 'Create Module', onClick: modulesActions.openCreate, variant: 'primary', icon: Package });
    pageActions.push({ label: 'New Category', onClick: modulesActions.openCreateCategory, variant: 'secondary', icon: FolderTree });
  } else if (activeTabKey === 'puppet-modules' && canCreatePuppet && puppetActions) {
    pageActions.push({ label: 'Add Puppet Module', onClick: puppetActions.openCreate, variant: 'primary', icon: Package });
  } else if (activeTabKey === 'scripts' && canCreateScripts && scriptsActions) {
    pageActions.push({ label: 'Create Script', onClick: scriptsActions.openCreate, variant: 'primary', icon: FileCode });
  } else if (activeTabKey === 'architectures' && canCreateArchitectures && architecturesActions) {
    pageActions.push({ label: 'Create Architecture', onClick: architecturesActions.openCreate, variant: 'primary', icon: Cpu });
  } else if (activeTabKey === 'platforms' && canCreatePlatforms && platformsActions) {
    pageActions.push({ label: 'Create Platform', onClick: platformsActions.openCreate, variant: 'primary', icon: Layers });
  }

  if (visibleTabs.length === 0) {
    return (
      <PageContainer title="Catalog">
        <div className="p-6 text-sm text-theme-secondary">
          You don&apos;t have permission to view any Catalog resources.
        </div>
      </PageContainer>
    );
  }

  const defaultTabKey = visibleTabs[0].key;

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
        <Route path="templates" element={<TemplatesTab onActionsReady={setTemplatesActions} />} />
        <Route path="modules" element={<ModulesTab onActionsReady={setModulesActions} />} />
        <Route path="puppet-modules" element={<PuppetModulesTab onActionsReady={setPuppetActions} />} />
        <Route path="scripts" element={<ScriptsTab onActionsReady={setScriptsActions} />} />
        <Route path="architectures" element={<ArchitecturesTab onActionsReady={setArchitecturesActions} />} />
        <Route path="platforms" element={<PlatformsTab onActionsReady={setPlatformsActions} />} />
        <Route path="marketplace" element={<MarketplaceTab />} />
        <Route path="*" element={<Navigate to={defaultTabKey} replace />} />
      </Routes>
    </PageContainer>
  );
};

export default CatalogPage;
