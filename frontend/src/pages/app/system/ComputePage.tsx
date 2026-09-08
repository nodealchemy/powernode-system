import React, { useState, useMemo } from 'react';
import { Routes, Route, Navigate, useLocation } from 'react-router-dom';
import { Server, HardDrive, Cloud, Network as NetworkIcon } from 'lucide-react';
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

const TABS: PathTabSpec<TabKey>[] = [
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
  const firstPath = firstAccessibleTabPath(TABS, BASE_PATH, hasPermission);

  // Drives the page actions below. Uses PathTabs' own derivation so the
  // strip and the actions can never disagree — which matters here because
  // the Platform tab owns nested sub-routes (`/compute/platform/services`
  // must resolve to `platform`, not to the trailing `services` segment).
  // Falls back to the first visible tab on the bare /compute path, which
  // the index route below is about to redirect anyway.
  const activeTabKey = useMemo<TabKey>(
    () =>
      activeTabKeyFromPath(TABS, BASE_PATH, location.pathname) ??
      ((TABS.find((t) => hasPermission(t.permission))?.key ?? 'nodes') as TabKey),
    [location.pathname, hasPermission],
  );

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

  if (!firstPath) {
    return (
      <PageContainer title="Compute">
        <div className="p-6 text-sm text-theme-secondary">
          You don&apos;t have permission to view any Compute resources.
        </div>
      </PageContainer>
    );
  }

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
      <PathTabs tabs={TABS} basePath={BASE_PATH} hasPermission={hasPermission}>
        <Routes>
          <Route index element={<Navigate to={firstPath} replace />} />
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
          <Route path="*" element={<Navigate to={firstPath} replace />} />
        </Routes>
      </PathTabs>
    </PageContainer>
  );
};

export default ComputePage;
