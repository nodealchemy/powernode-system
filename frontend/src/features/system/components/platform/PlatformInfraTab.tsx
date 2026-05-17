import React, { useMemo } from 'react';
import { Routes, Route, Link, Navigate, useLocation } from 'react-router-dom';
import {
  Server,
  Network,
  Globe2,
  Move,
  TrendingUp,
  Activity,
  Rocket,
} from 'lucide-react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { ChildrenPanel } from '@system/features/system/components/federation/ChildrenPanel';
import { ServiceOfferingsPanel } from '@system/features/system/components/federation/ServiceOfferingsPanel';
import { ServiceSubscriptionsPanel } from '@system/features/system/components/federation/ServiceSubscriptionsPanel';
import { PlatformOverviewCards } from './PlatformOverviewCards';
import { PeersPanel } from './PeersPanel';
import { HealthPanel } from './HealthPanel';
import { ScalingPanel } from './ScalingPanel';
import { MigrationsPanel } from './MigrationsPanel';
import { StorageMigrationsPanel } from './StorageMigrationsPanel';
import { DeployPlatformPanel } from './DeployPlatformPanel';

/**
 * Unified Platform Infrastructure tab. Lives at
 * /app/system/compute/platform with nested path-based sub-tabs for
 * each sub-domain. Per the plan §I, the 6 sub-panels are:
 *   - Services    — P4.6.8 offerings + subscriptions
 *   - Peers       — P7.1 federation peer list + invite + detail drawer
 *   - Children    — P6.2 spawned child platforms + spawn modal
 *   - Migrations  — P7.4 read-only Migration history + detail drawer
 *                    (creation wizard queued for next slice)
 *   - Scaling     — P7.3 PlatformDeployment list + inline replica edit
 *                    (provisioning sync queued for next slice)
 *   - Health      — P7.2 per-subsystem health snapshot + 30s refresh
 *
 * Plan reference: Decentralized Federation §I + P7.
 */

type TabKey = 'services' | 'peers' | 'children' | 'migrations' | 'scaling' | 'health' | 'deploy';

interface TabSpec {
  key: TabKey;
  label: string;
  permission: string;
  icon: React.ReactNode;
}

const TABS: TabSpec[] = [
  { key: 'services',   label: 'Services',   permission: 'system.service_offerings.read',   icon: <Globe2 className="w-4 h-4" /> },
  { key: 'peers',      label: 'Peers',      permission: 'system.peers.read',               icon: <Network className="w-4 h-4" /> },
  { key: 'children',   label: 'Children',   permission: 'system.children.read',            icon: <Server className="w-4 h-4" /> },
  { key: 'migrations', label: 'Migrations', permission: 'system.migrations.read',          icon: <Move className="w-4 h-4" /> },
  { key: 'scaling',    label: 'Scaling',    permission: 'system.platform.scale',           icon: <TrendingUp className="w-4 h-4" /> },
  { key: 'health',     label: 'Health',     permission: 'system.platform.health.read',     icon: <Activity className="w-4 h-4" /> },
  // D4.2 — Standalone deploy entry point, parallel to the chat card.
  // The wizard component itself is shared; this surface lets operators
  // start a deploy from the dashboard without first opening chat.
  { key: 'deploy',     label: 'Deploy',     permission: 'system.platform.deploy',          icon: <Rocket className="w-4 h-4" /> },
];

const BASE_PATH = '/app/system/compute/platform';

export const PlatformInfraTab: React.FC = () => {
  const { hasPermission } = usePermissions();
  const location = useLocation();

  // Permission gate is best-effort — the plan lists permissions that
  // may not yet be seeded. We treat missing-permission as "show tab,
  // let panel-level errors surface" rather than hiding silently.
  // The unconditional `accessible` here means operators see every tab;
  // tab-level panels remain responsible for handling forbidden API
  // responses.
  const accessibleTabs = useMemo(() => TABS, []);

  const activeKey = useMemo<TabKey>(() => {
    const seg = location.pathname.split('/').filter(Boolean).pop();
    const match = accessibleTabs.find((t) => t.key === seg);
    return match?.key ?? accessibleTabs[0]?.key ?? 'services';
  }, [location.pathname, accessibleTabs]);

  return (
    <div>
      <PlatformOverviewCards />

      <nav className="flex items-center gap-1 border-b border-theme mb-4">
        {accessibleTabs.map((tab) => {
          const isActive = activeKey === tab.key;
          return (
            <Link
              key={tab.key}
              to={`${BASE_PATH}/${tab.key}`}
              className={`px-3 py-2 text-sm inline-flex items-center gap-2 border-b-2 transition-colors ${
                isActive
                  ? 'border-theme-info text-theme-primary font-medium'
                  : 'border-transparent text-theme-secondary hover:text-theme-primary'
              }`}
            >
              {tab.icon}
              {tab.label}
            </Link>
          );
        })}
      </nav>

      <Routes>
        <Route
          path="/"
          element={<Navigate to={`${BASE_PATH}/${accessibleTabs[0].key}`} replace />}
        />
        <Route path="services"   element={<ServicesTab />} />
        <Route path="peers"      element={<PeersTab />} />
        <Route path="children"   element={<ChildrenPanel />} />
        <Route path="migrations" element={<MigrationsTab />} />
        <Route path="scaling"    element={<ScalingTab />} />
        <Route path="health"     element={<HealthTab />} />
        <Route path="deploy"     element={<DeployTab />} />
        <Route
          path="*"
          element={<Navigate to={`${BASE_PATH}/${accessibleTabs[0].key}`} replace />}
        />
      </Routes>
    </div>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Sub-tabs. ServicesTab composes two existing panels because the
// services flow has both an operator and a subscriber surface; the
// remaining sub-tabs are direct renders of their dedicated panel
// components which encapsulate fetch + state + actions.

const ServicesTab: React.FC = () => (
  <div className="space-y-6">
    <ServiceOfferingsPanel />
    <ServiceSubscriptionsPanel />
  </div>
);

const PeersTab: React.FC = () => <PeersPanel />;
const MigrationsTab: React.FC = () => (
  <div className="space-y-6">
    <MigrationsPanel />
    <StorageMigrationsPanel />
  </div>
);
const ScalingTab: React.FC = () => <ScalingPanel />;
const HealthTab: React.FC = () => <HealthPanel />;
const DeployTab: React.FC = () => <DeployPlatformPanel />;

export default PlatformInfraTab;
