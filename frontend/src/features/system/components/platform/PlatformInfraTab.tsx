import React, { useMemo } from 'react';
import { Routes, Route, Link, Navigate, useLocation } from 'react-router-dom';
import {
  Network,
  Globe2,
  Move,
  TrendingUp,
  Rocket,
} from 'lucide-react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { PlatformOverviewCards } from './PlatformOverviewCards';
import { PeerLivenessMonitor } from './PeerLivenessMonitor';
import { NetworkVipPicker } from './NetworkVipPicker';
import { ScalingPanel } from './ScalingPanel';
import { MigrationsPanel } from './MigrationsPanel';
import { StorageMigrationsPanel } from './StorageMigrationsPanel';
import { MigrationChainsPanel } from './MigrationChainsPanel';
import { DeployPlatformPanel } from './DeployPlatformPanel';

/**
 * Unified Platform Infrastructure tab. Lives at
 * /app/system/compute/platform with nested path-based sub-tabs for
 * each sub-domain:
 *   - Peer Liveness — P7.1 real-time federation peer liveness monitor
 *   - Migrations    — P7.4 migration history, chains and storage migrations
 *   - Scaling       — P7.3 PlatformDeployment list + inline replica edit
 *   - Deploy        — D4.2 standalone deploy entry point
 *   - Service Discovery — virtual IPs across the federation
 *
 * fc-47: Health moved to /app/status (the platform_subsystem contributor).
 * Services (offerings + subscriptions) and Children were the same panels as
 * Service Delivery's Offerings, Subscriptions and Children tabs, which are
 * now their one home.
 *
 * The Peers sub-tab carries a real-time liveness monitor (SystemFleetChannel),
 * and a new Service Discovery sub-tab carries virtual-IP management — both
 * relocated from the former FederationHubPage (fe-dupes.md §10 item 16):
 * that page's non-federation content (peer liveness, topology, OVN isolation,
 * service discovery) belongs here rather than on a standalone /federation
 * route. Topology and OVN isolation already had a home in the SDWAN hub
 * (`/app/system/sdwan/topology`, `/app/system/sdwan/ovn`), so they didn't
 * need relocating.
 *
 * fc-35: this Peers sub-tab's own peer list/invite/revoke panel (PeersPanel)
 * was deleted as a duplicate of PeerControlPanel on ServiceDeliveryPage's
 * Peers tab, which is now the one canonical peer-management surface — this
 * sub-tab keeps only the liveness monitor and links out to it (gated on
 * system.peers.read, like the liveness monitor above it — see PeersTab).
 * PeersPanel's Role/Mode/Endpoints columns and status filter (the divergence
 * C13 had deliberately kept both surfaces to preserve) were ported into
 * PeerControlPanel — see PeerControlPanel.tsx's own header comment — but the
 * consolidation is not purely additive: PeerControlPanel gates Invite on
 * system.peers.invite and Revoke/Grants on system.peers.manage (review fix;
 * PeersPanel had no such gating), and PeersPanel's plain row click into a
 * detail drawer became an explicit "Detail" button per row.
 *
 * Plan reference: Decentralized Federation §I + P7.
 */

type TabKey = 'peers' | 'migrations' | 'scaling' | 'deploy' | 'discovery';

interface TabSpec {
  key: TabKey;
  label: string;
  permission: string;
  icon: React.ReactNode;
}

const TABS: TabSpec[] = [
  { key: 'peers',      label: 'Peer Liveness', permission: 'system.peers.read',              icon: <Network className="w-4 h-4" /> },
  { key: 'migrations', label: 'Migrations', permission: 'system.migrations.read',          icon: <Move className="w-4 h-4" /> },
  { key: 'scaling',    label: 'Scaling',    permission: 'system.platform.scale',           icon: <TrendingUp className="w-4 h-4" /> },
  // D4.2 — Standalone deploy entry point, parallel to the chat card.
  // The wizard component itself is shared; this surface lets operators
  // start a deploy from the dashboard without first opening chat.
  { key: 'deploy',     label: 'Deploy',     permission: 'system.platform.deploy',          icon: <Rocket className="w-4 h-4" /> },
  // Relocated from FederationHubPage's Monitor/Control tabs (fe-dupes.md §10
  // item 16) — virtual IPs advertised across the federation via iBGP/overlay.
  { key: 'discovery',  label: 'Service Discovery', permission: 'system.sdwan.vips.manage', icon: <Globe2 className="w-4 h-4" /> },
];

const BASE_PATH = '/app/system/compute/platform';

export const PlatformInfraTab: React.FC = () => {
  // The tab STRIP stays best-effort (see `accessibleTabs` below) — every
  // operator sees every tab regardless of permission. That is deliberate
  // for the original sub-tabs. It is NOT the gate for the two panels
  // relocated from FederationHubPage inside the Peers/Discovery tabs
  // (`PeerLivenessMonitor`, `NetworkVipPicker`): those carried a REAL JSX
  // `{cond && …}` gate on the old page, and C10 review FIX-1 found the
  // relocation had silently dropped it, exposing peer liveness + the VIP
  // list to any `system.platform.read` holder. `PeersTab`/`DiscoveryTab`
  // below restore that real gate locally, independent of the tab strip.
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
    return match?.key ?? accessibleTabs[0]?.key ?? 'peers';
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
                  ? 'border-theme-info-border text-theme-primary font-medium'
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
        <Route path="peers"      element={<PeersTab />} />
        <Route path="migrations" element={<MigrationsTab />} />
        <Route path="scaling"    element={<ScalingTab />} />
        <Route path="deploy"     element={<DeployTab />} />
        <Route path="discovery"  element={<DiscoveryTab />} />
        <Route
          path="*"
          element={<Navigate to={`${BASE_PATH}/${accessibleTabs[0].key}`} replace />}
        />
      </Routes>
    </div>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Sub-tabs: each renders its dedicated panel components, which encapsulate
// fetch + state + actions.

const PeersTab: React.FC = () => {
  const { hasPermission } = usePermissions();
  const canReadPeers = hasPermission('system.peers.read');
  return (
    <div className="space-y-6">
      {/* Real-time liveness (SystemFleetChannel), relocated from
          FederationHubPage's Monitor tab. Real gate (C10 review FIX-1): the
          old page required system.peers.read to render this; the relocation
          had dropped that check. */}
      {canReadPeers && <PeerLivenessMonitor />}
      {/* fc-35: the peer list/invite/revoke panel that used to render here
          (PeersPanel) was deleted as a duplicate of PeerControlPanel, which
          is now the one canonical peer-management surface (its Role/Mode/
          Endpoints columns and status filter, plus Invite/Revoke/Grants
          gated on system.peers.invite / system.peers.manage — see
          PeerControlPanel.tsx). Gated on the SAME system.peers.read as the
          liveness monitor above (review fix): showing it to someone without
          that permission was a dead end — the link's own destination
          (ServiceDeliveryPage's Peers tab) requires it too. */}
      {canReadPeers && (
        <div className="bg-theme-surface border border-theme rounded-lg p-4 text-sm text-theme-secondary">
          Manage federation peers (invite, revoke, grants) on{' '}
          <Link to="/app/system/service-delivery/peers" className="text-theme-info-fg hover:text-theme-info-fg/80">
            Service Delivery → Federation Peers
          </Link>
          .
        </div>
      )}
    </div>
  );
};
const DiscoveryTab: React.FC = () => {
  const { hasPermission } = usePermissions();
  // Real gate (C10 review FIX-1): the old FederationHubPage required
  // system.sdwan.vips.manage to render the VIP list/picker in both its
  // Monitor (read-only) and Control (full) modes; the relocation had
  // dropped that check, leaving only the (inert) tab-strip permission.
  return hasPermission('system.sdwan.vips.manage') ? <NetworkVipPicker /> : null;
};
const MigrationsTab: React.FC = () => (
  <div className="space-y-6">
    <MigrationsPanel />
    <MigrationChainsPanel />
    <StorageMigrationsPanel />
  </div>
);
const ScalingTab: React.FC = () => <ScalingPanel />;
const DeployTab: React.FC = () => <DeployPlatformPanel />;

export default PlatformInfraTab;
