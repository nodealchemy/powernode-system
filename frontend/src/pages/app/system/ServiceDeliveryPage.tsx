import React, { useState } from 'react';
import { Routes, Route, Navigate } from 'react-router-dom';
import {
  Server,
  Network as NetworkIcon,
  Globe2,
  Share2,
  ClipboardCheck,
  MessageSquare,
  ShieldCheck,
} from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import {
  PathTabs,
  firstAccessibleTabPath,
  type PathTabSpec,
} from '@/shared/components/navigation/PathTabs';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { OfferingsTab } from '@system/features/system/components/federation_hub/OfferingsTab';
import { SubscriptionsTab } from '@system/features/system/components/federation_hub/SubscriptionsTab';
import { CatalogBrowserTab } from '@system/features/system/components/federation_hub/CatalogBrowserTab';
import { ChildrenTab } from '@system/features/system/components/federation_hub/ChildrenTab';
import { FulfillmentTab } from '@system/features/system/components/federation_hub/FulfillmentTab';
import { PeerControlPanel } from '@system/features/system/components/platform/PeerControlPanel';
import { FederationGovernancePanel } from '@system/features/system/components/sdwan/FederationGovernancePanel';
import { ConciergePanel } from '@system/features/system/components/concierge/ConciergePanel';

// Service Delivery hub. Six tabs:
//   - Offerings — operator manages this platform's catalog
//   - Subscriptions — subscriber views this platform's consumption
//   - Catalog Browser — per-peer view + subscribe flow
//   - Children — spawned child platforms (P6)
//   - Fulfillment — composed capability requests awaiting a human approval
//   - Peers — federation peer control (invite / grants / arm-and-confirm
//     revoke) + governance findings (trust expiry, stale peerings, prefix
//     overlap, cert expiry, peer health/drift, migration chains). Merged in
//     from the former FederationHubPage's Control tab (fe-dupes.md §10 item
//     16) — the mutate-side federation control surface belongs with the
//     other federation delivery surfaces on this page, not on a separate
//     /federation route. FederationHubPage's remaining, non-federation
//     content (peer liveness, topology, OVN isolation, service discovery)
//     moved to ComputePage's Platform tab instead.
//
// Plan reference: Decentralized Federation §L.7 + P4.6.8 + §H + P6.

const BASE_PATH = '/app/system/service-delivery';

type TabKey = 'offerings' | 'subscriptions' | 'catalog' | 'children' | 'fulfillment' | 'peers';

const TABS: PathTabSpec<TabKey>[] = [
  {
    key: 'offerings',
    label: 'Offerings',
    permission: 'system.service_offerings.read',
    icon: <Server className="w-4 h-4" />,
  },
  {
    key: 'subscriptions',
    label: 'Subscriptions',
    permission: 'system.service_subscriptions.read',
    icon: <NetworkIcon className="w-4 h-4" />,
  },
  {
    key: 'catalog',
    label: 'Catalog Browser',
    permission: 'system.service_subscriptions.read',
    icon: <Globe2 className="w-4 h-4" />,
  },
  {
    key: 'children',
    label: 'Children',
    permission: 'system.children.read',
    icon: <Share2 className="w-4 h-4" />,
  },
  {
    key: 'fulfillment',
    label: 'Fulfillment',
    permission: 'system.fulfillment_requests.read',
    icon: <ClipboardCheck className="w-4 h-4" />,
  },
  {
    key: 'peers',
    label: 'Peers',
    permission: 'system.peers.read',
    icon: <ShieldCheck className="w-4 h-4" />,
  },
];

export const ServiceDeliveryPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const firstPath = firstAccessibleTabPath(TABS, BASE_PATH, hasPermission);

  // Concierge mission flow — a single slide-out panel shared by the page,
  // toggled from the page action. Moved here from the former
  // FederationHubPage, same trigger permission.
  const [conciergeOpen, setConciergeOpen] = useState(false);
  const canManageFederation = hasPermission('system.sdwan.federation.manage');

  const pageActions: PageAction[] = [];
  if (canManageFederation) {
    pageActions.push({
      id: 'open-concierge',
      label: 'Ask Concierge',
      onClick: () => setConciergeOpen(true),
      variant: 'secondary',
      icon: MessageSquare,
    });
  }

  if (!firstPath) {
    return (
      <PageContainer title="Service Delivery" description="Federated service delivery">
        <div className="p-12 text-center text-theme-secondary text-sm">
          You don't have permission to view service delivery.
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer
      title="Service Delivery"
      description="Publish offerings + manage subscriptions across federated peers"
      actions={pageActions}
    >
      <PathTabs tabs={TABS} basePath={BASE_PATH} hasPermission={hasPermission}>
        <Routes>
          <Route index element={<Navigate to={firstPath} replace />} />
          <Route path="offerings" element={<OfferingsTab />} />
          <Route path="subscriptions" element={<SubscriptionsTab />} />
          <Route path="catalog" element={<CatalogBrowserTab />} />
          <Route path="children" element={<ChildrenTab />} />
          <Route path="fulfillment" element={<FulfillmentTab />} />
          <Route path="peers" element={<PeersTab hasPermission={hasPermission} />} />
          <Route path="*" element={<Navigate to={firstPath} replace />} />
        </Routes>
      </PathTabs>

      <ConciergePanel open={conciergeOpen} onClose={() => setConciergeOpen(false)} />
    </PageContainer>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Peers tab — federation peer control + governance findings. Merged in
// from FederationHubPage's Control/Monitor tabs.

const PeersTab: React.FC<{ hasPermission: (permission: string) => boolean }> = ({
  hasPermission,
}) => {
  const canManageFederation = hasPermission('system.sdwan.federation.manage');
  const canReadFederation = hasPermission('system.sdwan.federation.read');

  return (
    <div className="space-y-8" data-testid="service-delivery-peers-tab">
      <PeerControlPanel canManage={canManageFederation} />

      {canReadFederation && (
        <section>
          <h3 className="font-semibold text-theme-primary mb-2">Governance</h3>
          <p className="text-xs text-theme-secondary mb-3">
            Federation governance findings: trust expiry, stale peerings, prefix overlap, cert
            expiry, peer health and drift, migration chains.
          </p>
          <FederationGovernancePanel />
        </section>
      )}
    </div>
  );
};

export default ServiceDeliveryPage;
