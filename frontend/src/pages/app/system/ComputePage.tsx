import React, { useState, useMemo } from 'react';
import { Routes, Route, Link, Navigate, useLocation } from 'react-router-dom';
import { Server, HardDrive, Cloud, Network as NetworkIcon } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import {
  NodesTab,
  UnclaimedDevicesTab,
  VolumesTab,
  ProvidersTab,
  NetworksTab,
} from '@system/features/system/components/compute';
import { PlatformInfraTab } from '@system/features/system/components/platform/PlatformInfraTab';

// Phase B.1 — Compute hub. Path-based tabs (matches the canonical
// platform pattern from AdminSettingsPage): each tab has its own URL
// segment under /app/system/compute/<slug>. Parent route registered
// with /system/compute/* wildcard so React Router delegates path
// matching to this page's nested <Routes>.

type TabKey = 'nodes' | 'unclaimed-devices' | 'volumes' | 'providers' | 'networks' | 'platform';

const TABS: { key: TabKey; label: string; permission: string }[] = [
  { key: 'nodes', label: 'Nodes', permission: 'system.nodes.read' },
  { key: 'unclaimed-devices', label: 'Unclaimed Devices', permission: 'system.unclaimed_devices.read' },
  { key: 'volumes', label: 'Volumes', permission: 'system.volumes.read' },
  { key: 'providers', label: 'Providers', permission: 'system.providers.read' },
  { key: 'networks', label: 'Networks', permission: 'system.networks.read' },
  // P7 — unified platform-ops dashboard: peers + children + services
  // + migrations + scaling + health under one path-based hub.
  { key: 'platform', label: 'Platform', permission: 'system.platform.read' },
];

const BASE_PATH = '/app/system/compute';

const ComputePage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const location = useLocation();

  const visibleTabs = useMemo(
    () => TABS.filter((t) => hasPermission(t.permission)),
    [hasPermission]
  );

  // Active tab derived from URL path. Falls back to first visible tab
  // when on the bare /compute path (the inner <Route path="/"> below
  // also redirects to that fallback).
  const activeTabKey = useMemo<TabKey>(() => {
    // Match any path segment to a tab key — handles both flat tabs
    // (`/compute/nodes` → nodes) and tabs that own their own nested
    // sub-routes (`/compute/platform/services` → platform).
    const segments = location.pathname.split('/').filter(Boolean);
    for (const seg of segments) {
      const match = TABS.find((t) => t.key === seg);
      if (match) return match.key;
    }
    return (visibleTabs[0]?.key ?? 'nodes') as TabKey;
  }, [location.pathname, visibleTabs]);

  // Per-tab action handles published by orchestrators on mount.
  const [nodesActions, setNodesActions] = useState<{ openCreate: () => void } | null>(null);
  const [volumesActions, setVolumesActions] = useState<{ openCreate: () => void } | null>(null);
  const [providersActions, setProvidersActions] = useState<{ openCreate: () => void } | null>(null);
  const [networksActions, setNetworksActions] = useState<{ openCreate: () => void } | null>(null);

  const canCreateNodes = hasPermission('system.nodes.create');
  const canCreateVolumes = hasPermission('system.volumes.create');
  const canCreateProviders = hasPermission('system.providers.create');
  const canCreateNetworks = hasPermission('system.networks.create');

  const pageActions: PageAction[] = [];
  if (activeTabKey === 'nodes' && canCreateNodes && nodesActions) {
    pageActions.push({ label: 'Create Node', onClick: nodesActions.openCreate, variant: 'primary', icon: Server });
  } else if (activeTabKey === 'volumes' && canCreateVolumes && volumesActions) {
    pageActions.push({ label: 'Create Volume', onClick: volumesActions.openCreate, variant: 'primary', icon: HardDrive });
  } else if (activeTabKey === 'providers' && canCreateProviders && providersActions) {
    pageActions.push({ label: 'Add Provider', onClick: providersActions.openCreate, variant: 'primary', icon: Cloud });
  } else if (activeTabKey === 'networks' && canCreateNetworks && networksActions) {
    pageActions.push({ label: 'Create Network', onClick: networksActions.openCreate, variant: 'primary', icon: NetworkIcon });
  }

  if (visibleTabs.length === 0) {
    return (
      <PageContainer title="Compute">
        <div className="p-6 text-sm text-theme-secondary">
          You don&apos;t have permission to view any Compute resources.
        </div>
      </PageContainer>
    );
  }

  const defaultTabKey = visibleTabs[0].key;

  return (
    <PageContainer
      title="Compute"
      description="Nodes, instances, storage volumes, providers, and virtual networks — the resources that run and connect your workloads."
      breadcrumbs={[
        { label: 'System', href: '/app/system' },
        { label: 'Compute' },
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
        <Route path="nodes" element={<NodesTab onActionsReady={setNodesActions} />} />
        <Route path="unclaimed-devices" element={<UnclaimedDevicesTab />} />
        <Route path="volumes" element={<VolumesTab onActionsReady={setVolumesActions} />} />
        <Route path="providers" element={<ProvidersTab onActionsReady={setProvidersActions} />} />
        <Route path="networks" element={<NetworksTab onActionsReady={setNetworksActions} />} />
        {/* P7: platform tab owns its own nested sub-routes (services /
            peers / children / migrations / scaling / health). The `/*`
            suffix delegates further path matching to PlatformInfraTab's
            inner <Routes>. */}
        <Route path="platform/*" element={<PlatformInfraTab />} />
        <Route path="*" element={<Navigate to={defaultTabKey} replace />} />
      </Routes>
    </PageContainer>
  );
};

export default ComputePage;
