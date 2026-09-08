import React, { useState, useMemo } from 'react';
import { Routes, Route, Navigate, useLocation } from 'react-router-dom';
import { Network as NetworkIcon, Globe2 } from 'lucide-react';
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
  NetworksTab,
  FederationTab,
  HostBridgesTab,
  OvnDeploymentsTab,
  IpfixCollectorsTab,
  FlowSamplesTab,
  TopologyTab,
} from '@system/features/system/components/sdwan_hub';
import SdwanRoutingPage from './SdwanRoutingPage';

// Phase B.4 — SDWAN hub. Consolidates 3 SDWAN sidebar entries (SDWAN,
// SDWAN Federation, SDWAN Routing) into one tabbed page following the
// canonical AdminSettingsPage pattern.
//
// Architecture note: per-network detail surfaces as a modal triggered
// from the Networks tab (eye icon on each row). NetworkDetailModal
// hosts the full management UX (7 tabs: topology, peers, firewall,
// access, VIPs, routing, port mappings) so operators stay in the hub
// throughout. No standalone per-network page exists.

type TabKey = 'topology' | 'networks' | 'routing' | 'federation' | 'host_bridges' | 'ovn' | 'ipfix' | 'flows';

const TABS: PathTabSpec<TabKey>[] = [
  // P4.5.8 — system-wide federation + SDWAN graph. Lands first because
  // it's the operator's at-a-glance view; deeper drill-down lives in
  // the kind-specific tabs that follow.
  { key: 'topology', label: 'Topology', permission: 'system.sdwan.networks.read' },
  { key: 'networks', label: 'Networks', permission: 'system.sdwan.networks.read' },
  { key: 'routing', label: 'Routing', permission: 'system.sdwan.routing.read' },
  { key: 'federation', label: 'Federation', permission: 'system.sdwan.federation.read' },
  { key: 'host_bridges', label: 'Host Bridges', permission: 'system.sdwan.host_bridges.read' },
  { key: 'ovn', label: 'OVN', permission: 'system.sdwan.ovn.read' },
  { key: 'ipfix', label: 'IPFIX', permission: 'system.sdwan.ipfix.read' },
  { key: 'flows', label: 'Flows', permission: 'system.sdwan.ipfix.read' },
];

const BASE_PATH = '/app/system/sdwan';

const SdwanHubPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const location = useLocation();
  const firstPath = firstAccessibleTabPath(TABS, BASE_PATH, hasPermission);

  // Drives the page actions below. Uses PathTabs' own derivation so the
  // strip and the actions can never disagree — which matters here because
  // the Routing tab owns nested sub-routes (`/sdwan/routing/policies` must
  // resolve to `routing`, not to the trailing `policies` segment). Falls
  // back to the first visible tab on the bare /sdwan path, which the index
  // route below is about to redirect anyway.
  const activeTabKey = useMemo<TabKey>(
    () =>
      activeTabKeyFromPath(TABS, BASE_PATH, location.pathname) ??
      ((TABS.find((t) => hasPermission(t.permission))?.key ?? 'networks') as TabKey),
    [location.pathname, hasPermission],
  );

  const [networksActions, setNetworksActions] = useState<{ openCreate: () => void } | null>(null);
  const [federationActions, setFederationActions] = useState<{ openPropose: () => void } | null>(null);

  const canManageNetworks = hasPermission('system.sdwan.networks.manage');
  const canManageFederation = hasPermission('system.sdwan.federation.manage');

  const pageActions: PageAction[] = [];
  if (activeTabKey === 'networks' && canManageNetworks && networksActions) {
    pageActions.push({ label: 'Create network', onClick: networksActions.openCreate, variant: 'primary', icon: NetworkIcon });
  } else if (activeTabKey === 'federation' && canManageFederation && federationActions) {
    pageActions.push({ label: 'Propose peer', onClick: federationActions.openPropose, variant: 'primary', icon: Globe2 });
  }
  // Routing tab's "New policy" button is rendered inline by the
  // embedded SdwanRoutingPage (it knows when it's on the policies tab).

  if (!firstPath) {
    return (
      <PageContainer title="SDWAN">
        <div className="p-6 text-sm text-theme-secondary">
          You don&apos;t have permission to view any SDWAN resources.
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer
      title="SDWAN"
      description="IPv6 overlay networks, iBGP routing, and cross-instance federation. Per-network detail (peers, firewall, VIPs, port mappings) lives in a drill-down page."
      breadcrumbs={[
        { label: 'System', href: '/app/system' },
        { label: 'SDWAN' },
      ]}
      actions={pageActions}
    >
      <PathTabs tabs={TABS} basePath={BASE_PATH} hasPermission={hasPermission}>
        <Routes>
          <Route index element={<Navigate to={firstPath} replace />} />
          <Route path="topology" element={<TopologyTab />} />
          <Route path="networks" element={<NetworksTab onActionsReady={setNetworksActions} />} />
          <Route path="routing/*" element={<SdwanRoutingPage embedded />} />
          <Route path="federation" element={<FederationTab onActionsReady={setFederationActions} />} />
          <Route path="host_bridges" element={<HostBridgesTab />} />
          <Route path="ovn" element={<OvnDeploymentsTab />} />
          <Route path="ipfix" element={<IpfixCollectorsTab />} />
          <Route path="flows" element={<FlowSamplesTab />} />
          <Route path="*" element={<Navigate to={firstPath} replace />} />
        </Routes>
      </PathTabs>
    </PageContainer>
  );
};

export default SdwanHubPage;
