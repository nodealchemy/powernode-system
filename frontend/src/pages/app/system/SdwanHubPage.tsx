import React, { useState, useMemo } from 'react';
import { Routes, Route, Link, Navigate, useLocation } from 'react-router-dom';
import { Network as NetworkIcon, Globe2 } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import {
  NetworksTab,
  FederationTab,
  HostBridgesTab,
  OvnDeploymentsTab,
  IpfixCollectorsTab,
  FlowSamplesTab,
} from '@system/features/system/components/sdwan_hub';
import SdwanRoutingPage from './SdwanRoutingPage';

// Phase B.4 — SDWAN hub. Consolidates 3 SDWAN sidebar entries (SDWAN,
// SDWAN Federation, SDWAN Routing) into one tabbed page following the
// canonical AdminSettingsPage pattern.
//
// Architecture note: per-network detail (SdwanNetworkDetailPage) lives
// at the SIBLING route /app/system/sdwan/networks/:id/* — registered
// BEFORE this hub in register.ts so React Router matches the more
// specific path first. Detail page keeps its own PageContainer + 7
// internal tabs; clicking back returns to the hub's Networks tab.

type TabKey = 'networks' | 'routing' | 'federation' | 'host_bridges' | 'ovn' | 'ipfix' | 'flows';

const TABS: { key: TabKey; label: string; permission: string }[] = [
  { key: 'networks', label: 'Networks', permission: 'sdwan.networks.read' },
  { key: 'routing', label: 'Routing', permission: 'sdwan.routing.read' },
  { key: 'federation', label: 'Federation', permission: 'sdwan.federation.read' },
  { key: 'host_bridges', label: 'Host Bridges', permission: 'sdwan.host_bridges.read' },
  { key: 'ovn', label: 'OVN', permission: 'sdwan.ovn.read' },
  { key: 'ipfix', label: 'IPFIX', permission: 'sdwan.ipfix.read' },
  { key: 'flows', label: 'Flows', permission: 'sdwan.ipfix.read' },
];

const BASE_PATH = '/app/system/sdwan';

const SdwanHubPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const location = useLocation();

  const visibleTabs = useMemo(
    () => TABS.filter((t) => hasPermission(t.permission)),
    [hasPermission]
  );

  // Active tab matches the URL segment that follows /sdwan/. The
  // routing tab matches when the URL contains /sdwan/routing/anything.
  const activeTabKey = useMemo<TabKey>(() => {
    const path = location.pathname;
    if (path.includes('/sdwan/routing')) return 'routing';
    if (path.includes('/sdwan/federation')) return 'federation';
    if (path.includes('/sdwan/host_bridges')) return 'host_bridges';
    if (path.includes('/sdwan/flows')) return 'flows';
    if (path.includes('/sdwan/ovn')) return 'ovn';
    if (path.includes('/sdwan/ipfix')) return 'ipfix';
    if (path.includes('/sdwan/networks')) return 'networks';
    return (visibleTabs[0]?.key ?? 'networks') as TabKey;
  }, [location.pathname, visibleTabs]);

  const [networksActions, setNetworksActions] = useState<{ openCreate: () => void } | null>(null);
  const [federationActions, setFederationActions] = useState<{ openPropose: () => void } | null>(null);

  const canManageNetworks = hasPermission('sdwan.networks.manage');
  const canManageFederation = hasPermission('sdwan.federation.manage');

  const pageActions: PageAction[] = [];
  if (activeTabKey === 'networks' && canManageNetworks && networksActions) {
    pageActions.push({ label: 'Create network', onClick: networksActions.openCreate, variant: 'primary', icon: NetworkIcon });
  } else if (activeTabKey === 'federation' && canManageFederation && federationActions) {
    pageActions.push({ label: 'Propose peer', onClick: federationActions.openPropose, variant: 'primary', icon: Globe2 });
  }
  // Routing tab's "New policy" button is rendered inline by the
  // embedded SdwanRoutingPage (it knows when it's on the policies tab).

  if (visibleTabs.length === 0) {
    return (
      <PageContainer title="SDWAN">
        <div className="p-6 text-sm text-theme-secondary">
          You don&apos;t have permission to view any SDWAN resources.
        </div>
      </PageContainer>
    );
  }

  const defaultTabKey = visibleTabs[0].key;

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
        <Route path="networks" element={<NetworksTab onActionsReady={setNetworksActions} />} />
        <Route path="routing/*" element={<SdwanRoutingPage embedded />} />
        <Route path="federation" element={<FederationTab onActionsReady={setFederationActions} />} />
        <Route path="host_bridges" element={<HostBridgesTab />} />
        <Route path="ovn" element={<OvnDeploymentsTab />} />
        <Route path="ipfix" element={<IpfixCollectorsTab />} />
        <Route path="flows" element={<FlowSamplesTab />} />
        <Route path="*" element={<Navigate to={defaultTabKey} replace />} />
      </Routes>
    </PageContainer>
  );
};

export default SdwanHubPage;
