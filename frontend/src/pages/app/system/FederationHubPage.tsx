import React, { useState } from 'react';
import { Routes, Route, Navigate, Link } from 'react-router-dom';
import {
  Activity,
  SlidersHorizontal,
  Network,
  Share2,
  ShieldCheck,
  Globe2,
  Layers,
  MessageSquare,
  KeyRound,
  Route as RouteIcon,
} from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import {
  PathTabs,
  firstAccessibleTabPath,
  type PathTabSpec,
} from '@/shared/components/navigation/PathTabs';
import { usePermissions } from '@/shared/hooks/usePermissions';

import { PeerLivenessMonitor } from '@system/features/system/components/platform/PeerLivenessMonitor';
import { PeerControlPanel } from '@system/features/system/components/platform/PeerControlPanel';
import { NetworkVipPicker } from '@system/features/system/components/platform/NetworkVipPicker';
import { SystemTopology } from '@system/features/system/components/network/SystemTopology';
import { OvnDeploymentsTab } from '@system/features/system/components/sdwan_hub/OvnDeploymentsTab';
import { FederationGovernancePanel } from '@system/features/system/components/sdwan/FederationGovernancePanel';
import { ServiceSubscriptionsPanel } from '@system/features/system/components/federation/ServiceSubscriptionsPanel';
import { ServiceOfferingsPanel } from '@system/features/system/components/federation/ServiceOfferingsPanel';
import { ServiceOfferingEditorModal } from '@system/features/system/components/federation/ServiceOfferingEditorModal';
import { CatalogBrowserTab } from '@system/features/system/components/federation_hub/CatalogBrowserTab';
import { ConciergePanel } from '@system/features/system/components/concierge/ConciergePanel';
import type { ServiceOffering } from '@system/features/system/types/service_delivery.types';

/**
 * FederationHubPage — the platform multi-site hub. Two top-level, path-based
 * tabs (Monitor | Control) per the Phase 3 contract, mirroring AcmePage /
 * IngressPage scaffolding via the shared PathTabs.
 *
 * The hub is a *composer of composers*: it reuses the existing federation,
 * SDWAN, topology, OVN, and service-delivery surfaces rather than rebuilding
 * any of them. Net-new pieces are limited to (a) a real-time peer-liveness
 * monitor (SystemFleetChannel), (b) an arm-and-confirm peer-revoke control,
 * and (c) a per-network VIP picker — all thin wrappers over existing APIs.
 *
 * Isolation + service discovery are delivered through the SDWAN overlay
 * (OVN logical switches + ACLs, VIPs advertised via iBGP) per the SDWAN-first
 * directive. Public-internet DNS records have no SDWAN substitute and are
 * managed via the existing ACME DNS-credentials surface, linked from here.
 *
 *   Monitor (`/app/system/federation/monitor`)
 *     - Peer liveness (real-time)
 *     - Topology graph (SDWAN + federation)
 *     - Tenant-isolation status (OVN switches + ACLs)
 *     - Service discovery (VIPs)
 *     - Grant / subscription status (subscriptions + governance findings)
 *
 *   Control (`/app/system/federation/control`)
 *     - Propose / accept peers, peer detail, REVOKE (arm-and-confirm)
 *     - Grant management (per-peer)
 *     - Service offerings (operator catalog) + subscription wizard (catalog browser)
 *     - VIP / isolation / DNS-record management (links + per-network VIP CRUD)
 *     - Concierge mission flow
 *
 * Plan reference: Phase 3 (Federation & Multi-Site).
 */

const BASE_PATH = '/app/system/federation';

type TabKey = 'monitor' | 'control';

const TABS: PathTabSpec<TabKey>[] = [
  {
    key: 'monitor',
    label: 'Monitor',
    permission: 'system.peers.read',
    icon: <Activity className="w-4 h-4" />,
  },
  {
    key: 'control',
    label: 'Control',
    permission: 'system.sdwan.federation.manage',
    icon: <SlidersHorizontal className="w-4 h-4" />,
  },
];

export const FederationHubPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const firstPath = firstAccessibleTabPath(TABS, BASE_PATH, hasPermission);

  // Concierge mission flow — a single slide-out panel shared by the page,
  // toggled from the Control tab's action.
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
      <PageContainer
        title="Federation"
        description="Multi-site federation — peers, isolation, service discovery, and delivery."
      >
        <div className="p-12 text-center text-theme-secondary text-sm">
          You don't have permission to view the federation hub. Ask an admin to grant
          <code className="mx-1 font-mono">system.peers.read</code> or
          <code className="mx-1 font-mono">sdwan.federation.manage</code>.
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer
      title="Federation"
      description="Multi-site federation control plane — peer liveness, SDWAN topology + tenant isolation, service discovery, and approval-gated delivery."
      breadcrumbs={[{ label: 'System', href: '/app/system' }, { label: 'Federation' }]}
      actions={pageActions}
    >
      <PathTabs tabs={TABS} basePath={BASE_PATH} hasPermission={hasPermission}>
        <Routes>
          <Route path="/" element={<Navigate to={firstPath} replace />} />
          <Route path="monitor" element={<MonitorTab hasPermission={hasPermission} />} />
          <Route path="control" element={<ControlTab hasPermission={hasPermission} />} />
          <Route path="*" element={<Navigate to={firstPath} replace />} />
        </Routes>
      </PathTabs>

      <ConciergePanel open={conciergeOpen} onClose={() => setConciergeOpen(false)} />
    </PageContainer>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Monitor tab — read-only observability.

interface TabProps {
  hasPermission: (permission: string) => boolean;
}

const MonitorTab: React.FC<TabProps> = ({ hasPermission }) => {
  const canReadPeers = hasPermission('system.peers.read');
  const canReadNetworks = hasPermission('system.sdwan.networks.read');
  const canReadOvn = hasPermission('system.sdwan.ovn.read');
  const canReadVips = hasPermission('system.sdwan.vips.manage');
  const canReadSubscriptions = hasPermission('system.service_subscriptions.read');
  const canReadFederation = hasPermission('system.sdwan.federation.read');

  return (
    <div className="space-y-8" data-testid="federation-monitor-tab">
      {canReadPeers && (
        <Section icon={<Network className="w-4 h-4" />} title="Peer liveness">
          <PeerLivenessMonitor />
        </Section>
      )}

      {canReadNetworks && (
        <Section icon={<Share2 className="w-4 h-4" />} title="Topology">
          <SystemTopology />
        </Section>
      )}

      {canReadOvn && (
        <Section
          icon={<Layers className="w-4 h-4" />}
          title="Tenant isolation"
          subtitle="OVN logical switches + ACLs (multi-tenant firewall) backing the overlay."
        >
          <OvnDeploymentsTab />
        </Section>
      )}

      {canReadVips && (
        <Section
          icon={<Globe2 className="w-4 h-4" />}
          title="Service discovery"
          subtitle="Virtual IPs advertised across the federation via iBGP / overlay AllowedIPs."
        >
          <NetworkVipPicker readOnly />
        </Section>
      )}

      {canReadSubscriptions && (
        <Section icon={<ShieldCheck className="w-4 h-4" />} title="Subscriptions">
          <ServiceSubscriptionsPanel />
        </Section>
      )}

      {canReadFederation && (
        <Section
          icon={<ShieldCheck className="w-4 h-4" />}
          title="Governance"
          subtitle="Federation governance findings: trust expiry, stale peerings, prefix overlap, cert expiry, peer health and drift, migration chains."
        >
          <FederationGovernancePanel />
        </Section>
      )}
    </div>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Control tab — mutation surfaces.

const ControlTab: React.FC<TabProps> = ({ hasPermission }) => {
  const canReadPeers = hasPermission('system.peers.read');
  const canManageFederation = hasPermission('system.sdwan.federation.manage');
  const canReadOfferings = hasPermission('system.service_offerings.read');
  const canSubscribe = hasPermission('system.service_subscriptions.read');
  const canManageVips = hasPermission('system.sdwan.vips.manage');
  const canReadAcmeDns = hasPermission('system.acme_dns.read');

  const [offeringEditorOpen, setOfferingEditorOpen] = useState(false);
  const [editingOffering, setEditingOffering] = useState<ServiceOffering | null>(null);
  const [offeringsRefreshKey, setOfferingsRefreshKey] = useState(0);

  return (
    <div className="space-y-8" data-testid="federation-control-tab">
      {canReadPeers && (
        <Section
          icon={<Network className="w-4 h-4" />}
          title="Peers"
          subtitle="Propose, inspect, grant, and revoke federation peers. Revoke is arm-and-confirm."
        >
          <PeerControlPanel canManage={canManageFederation} />
        </Section>
      )}

      {canReadOfferings && (
        <Section
          icon={<ShieldCheck className="w-4 h-4" />}
          title="Service offerings"
          subtitle="This platform's published catalog of federated services."
        >
          <ServiceOfferingsPanel
            refreshKey={offeringsRefreshKey}
            onCreateClick={() => {
              setEditingOffering(null);
              setOfferingEditorOpen(true);
            }}
            onSelect={(offering) => {
              setEditingOffering(offering);
              setOfferingEditorOpen(true);
            }}
          />
          <ServiceOfferingEditorModal
            isOpen={offeringEditorOpen}
            onClose={() => setOfferingEditorOpen(false)}
            editOffering={editingOffering}
            onSaved={() => setOfferingsRefreshKey((k) => k + 1)}
          />
        </Section>
      )}

      {canSubscribe && (
        <Section
          icon={<Globe2 className="w-4 h-4" />}
          title="Subscribe to a peer service"
          subtitle="Browse a peer's catalog and subscribe — provisions a local Traefik route + ACME cert."
        >
          <CatalogBrowserTab />
        </Section>
      )}

      {canManageVips && (
        <Section
          icon={<Globe2 className="w-4 h-4" />}
          title="Virtual IP management"
          subtitle="Create, fail over, and delete per-network virtual IPs (service-discovery addresses)."
        >
          <NetworkVipPicker />
        </Section>
      )}

      <Section
        icon={<RouteIcon className="w-4 h-4" />}
        title="Isolation & DNS records"
        subtitle="Tenant isolation and overlay routing live in the SDWAN hub; public DNS records use ACME DNS credentials."
      >
        <div className="flex flex-wrap gap-2">
          <LinkPill to="/app/system/sdwan/ovn" icon={<Layers className="w-4 h-4" />} label="OVN isolation (SDWAN)" />
          <LinkPill to="/app/system/sdwan/routing" icon={<RouteIcon className="w-4 h-4" />} label="Route policies (SDWAN)" />
          {canReadAcmeDns && (
            <LinkPill
              to="/app/system/acme/dns-credentials"
              icon={<KeyRound className="w-4 h-4" />}
              label="DNS credentials (ACME)"
            />
          )}
        </div>
      </Section>
    </div>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Presentational helpers.

interface SectionProps {
  icon: React.ReactNode;
  title: string;
  subtitle?: string;
  children: React.ReactNode;
}

const Section: React.FC<SectionProps> = ({ icon, title, subtitle, children }) => (
  <section>
    <div className="flex items-center gap-2 mb-2">
      <span className="text-theme-info-fg">{icon}</span>
      <h3 className="font-semibold text-theme-primary">{title}</h3>
    </div>
    {subtitle && <p className="text-xs text-theme-secondary mb-3">{subtitle}</p>}
    {children}
  </section>
);

const LinkPill: React.FC<{ to: string; icon: React.ReactNode; label: string }> = ({ to, icon, label }) => (
  <Link
    to={to}
    className="inline-flex items-center gap-2 px-3 py-2 rounded-md border border-theme bg-theme-surface text-sm text-theme-primary hover:bg-theme-surface-hover transition-colors"
  >
    <span className="text-theme-secondary">{icon}</span>
    {label}
  </Link>
);

export default FederationHubPage;
