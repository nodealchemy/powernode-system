import React, { useMemo } from 'react';
import { Routes, Route, Link, Navigate, useLocation } from 'react-router-dom';
import { Server, Network as NetworkIcon, Globe2, Share2 } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { OfferingsTab } from '@system/features/system/components/federation_hub/OfferingsTab';
import { SubscriptionsTab } from '@system/features/system/components/federation_hub/SubscriptionsTab';
import { CatalogBrowserTab } from '@system/features/system/components/federation_hub/CatalogBrowserTab';
import { ChildrenTab } from '@system/features/system/components/federation_hub/ChildrenTab';

// Federated Service Delivery hub. Four tabs:
//   - Offerings — operator manages this platform's catalog
//   - Subscriptions — subscriber views this platform's consumption
//   - Catalog Browser — per-peer view + subscribe flow
//   - Children — spawned child platforms (P6)
//
// Plan reference: Decentralized Federation §L.7 + P4.6.8 + §H + P6.

type TabKey = 'offerings' | 'subscriptions' | 'catalog' | 'children';

interface TabSpec {
  key: TabKey;
  label: string;
  permission: string;
  icon: React.ReactNode;
}

const TABS: TabSpec[] = [
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
];

export const FederationHubPage: React.FC = () => {
  const location = useLocation();
  const { hasPermission } = usePermissions();

  const visibleTabs = useMemo(
    () => TABS.filter((t) => hasPermission(t.permission)),
    [hasPermission],
  );

  const activeTab: TabKey = useMemo(() => {
    const m = location.pathname.match(/\/federation\/(offerings|subscriptions|catalog|children)/);
    return (m?.[1] as TabKey) ?? visibleTabs[0]?.key ?? 'offerings';
  }, [location.pathname, visibleTabs]);

  if (visibleTabs.length === 0) {
    return (
      <PageContainer title="Federation Services" subtitle="Federated service delivery">
        <div className="p-12 text-center text-theme-secondary text-sm">
          You don't have permission to view federation services.
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer
      title="Federation Services"
      subtitle="Publish offerings + manage subscriptions across federated peers"
    >
      <nav className="border-b border-theme flex items-center gap-1 mb-4">
        {visibleTabs.map((tab) => (
          <Link
            key={tab.key}
            to={`/app/system/federation/${tab.key}`}
            className={`px-3 py-2 text-sm border-b-2 inline-flex items-center gap-2 -mb-px ${
              activeTab === tab.key
                ? 'border-theme-info text-theme-info font-medium'
                : 'border-transparent text-theme-secondary hover:text-theme-primary'
            }`}
          >
            {tab.icon}
            {tab.label}
          </Link>
        ))}
      </nav>

      <Routes>
        <Route index element={<Navigate to={visibleTabs[0].key} replace />} />
        <Route path="offerings" element={<OfferingsTab />} />
        <Route path="subscriptions" element={<SubscriptionsTab />} />
        <Route path="catalog" element={<CatalogBrowserTab />} />
        <Route path="children" element={<ChildrenTab />} />
        <Route path="*" element={<Navigate to={visibleTabs[0].key} replace />} />
      </Routes>
    </PageContainer>
  );
};

export default FederationHubPage;
