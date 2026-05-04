import React, { useState, useEffect, useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';
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

// Phase B.1 — Compute hub. Consolidates 5 previously-standalone pages
// (Nodes, Unclaimed Devices, Volumes, Providers, Networks) into a single
// tabbed hub. Each tab orchestrator owns its own modal state but
// publishes a `{openCreate}` action handle via onActionsReady so the
// hub's PageContainer.actions array can render the right "Create X"
// button when the matching tab is active.
//
// Old routes (/system/nodes, /system/unclaimed-devices, /system/volumes,
// /system/providers, /system/networks) redirect here with ?tab=<key>
// to preserve deep links.

type TabKey = 'nodes' | 'unclaimed_devices' | 'volumes' | 'providers' | 'networks';

const TABS: { key: TabKey; label: string; permission: string }[] = [
  { key: 'nodes', label: 'Nodes', permission: 'system.nodes.read' },
  { key: 'unclaimed_devices', label: 'Unclaimed Devices', permission: 'system.unclaimed_devices.read' },
  { key: 'volumes', label: 'Volumes', permission: 'system.volumes.read' },
  { key: 'providers', label: 'Providers', permission: 'system.providers.read' },
  { key: 'networks', label: 'Networks', permission: 'system.networks.read' },
];

const ComputePage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const [searchParams, setSearchParams] = useSearchParams();

  // Initial tab from ?tab= query param so old deep links land on the
  // right place. Default to first visible tab if missing/invalid.
  const initialTab = useMemo<TabKey>(() => {
    const requested = searchParams.get('tab') as TabKey | null;
    if (requested && TABS.some((t) => t.key === requested)) return requested;
    const firstVisible = TABS.find((t) => hasPermission(t.permission));
    return (firstVisible?.key ?? 'nodes') as TabKey;
  }, [searchParams, hasPermission]);

  const [tab, setTab] = useState<TabKey>(initialTab);

  // Sync tab → query param so the URL reflects the active tab
  // (and refreshes preserve it).
  useEffect(() => {
    if (searchParams.get('tab') !== tab) {
      const next = new URLSearchParams(searchParams);
      next.set('tab', tab);
      setSearchParams(next, { replace: true });
    }
  }, [tab, searchParams, setSearchParams]);

  // Per-tab action handles published by the orchestrators on mount.
  const [nodesActions, setNodesActions] = useState<{ openCreate: () => void } | null>(null);
  const [volumesActions, setVolumesActions] = useState<{ openCreate: () => void } | null>(null);
  const [providersActions, setProvidersActions] = useState<{ openCreate: () => void } | null>(null);
  const [networksActions, setNetworksActions] = useState<{ openCreate: () => void } | null>(null);

  const canCreateNodes = hasPermission('system.nodes.create');
  const canCreateVolumes = hasPermission('system.volumes.create');
  const canCreateProviders = hasPermission('system.providers.create');
  const canCreateNetworks = hasPermission('system.networks.create');

  const pageActions = (() => {
    const actions: PageAction[] = [];
    if (tab === 'nodes' && canCreateNodes && nodesActions) {
      actions.push({ label: 'Create Node', onClick: nodesActions.openCreate, variant: 'primary', icon: Server });
    }
    if (tab === 'volumes' && canCreateVolumes && volumesActions) {
      actions.push({ label: 'Create Volume', onClick: volumesActions.openCreate, variant: 'primary', icon: HardDrive });
    }
    if (tab === 'providers' && canCreateProviders && providersActions) {
      actions.push({ label: 'Add Provider', onClick: providersActions.openCreate, variant: 'primary', icon: Cloud });
    }
    if (tab === 'networks' && canCreateNetworks && networksActions) {
      actions.push({ label: 'Create Network', onClick: networksActions.openCreate, variant: 'primary', icon: NetworkIcon });
    }
    return actions;
  })();

  const visibleTabs = TABS.filter((t) => hasPermission(t.permission));

  if (visibleTabs.length === 0) {
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
      <div className="border-b border-theme mb-4">
        <nav className="flex gap-2 flex-wrap">
          {visibleTabs.map((t) => (
            <button
              key={t.key}
              type="button"
              onClick={() => setTab(t.key)}
              className={
                'px-3 py-2 text-sm font-medium border-b-2 transition-colors ' +
                (tab === t.key
                  ? 'border-theme-focus text-theme-primary'
                  : 'border-transparent text-theme-secondary hover:text-theme-primary')
              }
            >
              {t.label}
            </button>
          ))}
        </nav>
      </div>

      {tab === 'nodes' && <NodesTab onActionsReady={setNodesActions} />}
      {tab === 'unclaimed_devices' && <UnclaimedDevicesTab />}
      {tab === 'volumes' && <VolumesTab onActionsReady={setVolumesActions} />}
      {tab === 'providers' && <ProvidersTab onActionsReady={setProvidersActions} />}
      {tab === 'networks' && <NetworksTab onActionsReady={setNetworksActions} />}
    </PageContainer>
  );
};

export default ComputePage;
