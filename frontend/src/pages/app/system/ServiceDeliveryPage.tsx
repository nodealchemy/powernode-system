import React from 'react';
import { Routes, Route, Navigate } from 'react-router-dom';
import { Server, Network as NetworkIcon, Globe2, Share2, ClipboardCheck } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
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

// Service Delivery hub. Five tabs:
//   - Offerings — operator manages this platform's catalog
//   - Subscriptions — subscriber views this platform's consumption
//   - Catalog Browser — per-peer view + subscribe flow
//   - Children — spawned child platforms (P6)
//   - Fulfillment — composed capability requests awaiting a human approval
//
// Plan reference: Decentralized Federation §L.7 + P4.6.8 + §H + P6.

const BASE_PATH = '/app/system/service-delivery';

type TabKey = 'offerings' | 'subscriptions' | 'catalog' | 'children' | 'fulfillment';

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
];

export const ServiceDeliveryPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const firstPath = firstAccessibleTabPath(TABS, BASE_PATH, hasPermission);

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
    >
      <PathTabs tabs={TABS} basePath={BASE_PATH} hasPermission={hasPermission}>
        <Routes>
          <Route index element={<Navigate to={firstPath} replace />} />
          <Route path="offerings" element={<OfferingsTab />} />
          <Route path="subscriptions" element={<SubscriptionsTab />} />
          <Route path="catalog" element={<CatalogBrowserTab />} />
          <Route path="children" element={<ChildrenTab />} />
          <Route path="fulfillment" element={<FulfillmentTab />} />
          <Route path="*" element={<Navigate to={firstPath} replace />} />
        </Routes>
      </PathTabs>
    </PageContainer>
  );
};

export default ServiceDeliveryPage;
