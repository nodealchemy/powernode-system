import React, { ComponentType, lazy } from 'react';
import { Navigate } from 'react-router-dom';
import { featureRegistry } from '@/shared/services/featureRegistry';
import { registerSystemEntities } from './features/system/entityRegistry';

// Helper: widen the lazy-loaded module's default-export type from the
// concrete `FC<P>` it was authored as to the `ComponentType<unknown>`
// that `featureRegistry.FeatureRoute.component` expects. This is the
// boundary where strict type variance bites — every page component is
// a different `FC<P>`, but the registry stores them in a single typed
// list. The cast happens here, once, instead of at every call site.
const lazyPage = <P,>(
  loader: () => Promise<{ default: ComponentType<P> }>
) => lazy(loader as () => Promise<{ default: ComponentType<unknown> }>);

// Phase B.5 — redirect helper for legacy URLs. Each old standalone
// route (e.g. /system/nodes) now maps to its hub equivalent (e.g.
// /system/compute/nodes) with `replace` so the URL bar updates and
// back-button doesn't loop. Bookmarks and external links survive.
//
// Cast to `ComponentType<unknown>` matches the `lazyPage` boundary —
// FeatureRoute.component stores all routes in one typed list and
// `FC<{}>` doesn't satisfy `FC<unknown>` due to React's strict prop
// variance. The cast happens here, once, instead of at every call site.
const redirectTo = (to: string): ComponentType<unknown> =>
  function LegacyRedirect() {
    return React.createElement(Navigate, { to, replace: true });
  } as ComponentType<unknown>;

const SystemOverviewPage = lazyPage(() => import('./pages/app/system/SystemOverviewPage'));
// Drill-down pages still routed standalone (no tab equivalent).
const TemplateComposerPage = lazyPage(() => import('./pages/app/system/TemplateComposerPage'));
const InstancePoolsPage = lazyPage(() => import('./pages/app/system/InstancePoolsPage'));
// Fleet Topology — the fleet's containment graph (provider/platform groups
// → nodes → instances → SDWAN networks) on @xyflow/react, live off
// SystemFleetChannel. Gap G3 + G9 in the dashboard gap analysis; the
// Compute hub's five tables show the same objects with no relationships.
const FleetTopologyPage = lazyPage(() => import('./pages/app/system/FleetTopologyPage'));
// Phase B hubs.
const ComputePage = lazyPage(() => import('./pages/app/system/ComputePage'));
const CatalogPage = lazyPage(() => import('./pages/app/system/CatalogPage'));
const OperationsHubPage = lazyPage(() => import('./pages/app/system/OperationsHubPage'));
const SdwanHubPage = lazyPage(() => import('./pages/app/system/SdwanHubPage'));
// Federation Hub — Phase 3 multi-site control plane (Monitor | Control
// PathTabs: peer liveness, topology, OVN isolation, VIP discovery,
// subscriptions/governance, peer mgmt, offerings, isolation/DNS links).
const FederationHubPage = lazyPage(() => import('./pages/app/system/FederationHubPage'));
// Service Delivery — federated service catalog surfaces (Offerings,
// Subscriptions, Catalog Browser, Children). Renamed from the former
// FederationHubPage in Phase 3e; the multi-site hub above now owns the
// /federation path, so service delivery moves to its own /service-delivery.
const ServiceDeliveryPage = lazyPage(() => import('./pages/app/system/ServiceDeliveryPage'));
// ACME — DNS provider credentials + Let's Encrypt cert lifecycle.
// Plan reference: Decentralized Federation §J + P2.5.8.
const AcmePage = lazyPage(() => import('./pages/app/system/AcmePage'));
// My VPN — the RECIPIENT's self-service surface for SDWAN user devices.
// Deliberately NOT lazy-gated on a permission (see the route below).
const MyVpnDevicesPage = lazyPage(() => import('./pages/app/system/MyVpnDevicesPage'));
// Ingress — derived Traefik routes + approval-gated Expose Service wizard.
// Plan reference: Phase 2c (Ingress).
const IngressPage = lazyPage(() => import('./pages/app/system/IngressPage'));
// ServicesPage, WorkersPage, AuditLogsPage, StorageProvidersPage all removed:
// each was a near-identical copy of an admin/* page with only import paths
// differing. Functionality lives at /app/admin/* — operators with the
// relevant platform permissions land there directly.

export function register(): void {
  // Routes: keep the /system/* URL prefix since deep-links and existing
  // bookmarks use it. Internal namespace ID stays "system"; user-facing label
  // is "System" (set on nav sections below).
  featureRegistry.registerRoutes('system', [
    { path: '/system', component: SystemOverviewPage },
    { path: '/system/overview', component: SystemOverviewPage },

    // Phase B.5 — legacy redirects to hub-tab equivalents. Old
    // bookmarks + external links survive; URL bar updates to canonical
    // path on land. Underlying page files remain on disk for now (no
    // deletions in this commit) since the hub tab orchestrators import
    // their inner list/modal components.
    { path: '/system/nodes', component: redirectTo('/app/system/compute/nodes') },
    { path: '/system/unclaimed-devices', component: redirectTo('/app/system/compute/unclaimed-devices') },
    { path: '/system/volumes', component: redirectTo('/app/system/compute/volumes') },
    { path: '/system/providers', component: redirectTo('/app/system/compute/providers') },
    { path: '/system/networks', component: redirectTo('/app/system/compute/networks') },
    { path: '/system/templates', component: redirectTo('/app/system/catalog/templates') },
    { path: '/system/modules', component: redirectTo('/app/system/catalog/modules') },
    { path: '/system/puppet-modules', component: redirectTo('/app/system/catalog/puppet-modules') },
    { path: '/system/scripts', component: redirectTo('/app/system/catalog/scripts') },
    { path: '/system/architectures', component: redirectTo('/app/system/catalog/architectures') },
    { path: '/system/platforms', component: redirectTo('/app/system/catalog/platforms') },
    { path: '/system/marketplace', component: redirectTo('/app/system/catalog/marketplace') },
    { path: '/system/fleet', component: redirectTo('/app/system/operations/fleet') },
    { path: '/system/tasks', component: redirectTo('/app/system/operations/tasks') },
    { path: '/system/ci-workers', component: redirectTo('/app/system/operations/ci-workers') },
    { path: '/system/disk-image-webhooks', component: redirectTo('/app/system/operations/ci-webhooks') },

    // Drill-down pages routed standalone (no tab equivalent).
    { path: '/system/templates/compose', component: TemplateComposerPage },
    { path: '/system/instance-pools', component: InstancePoolsPage },

    // Fleet topology graph. Ungated like the Compute/Catalog/Operations
    // hubs — it reads the same node/instance lists those tabs render, and
    // each underlying API still enforces its own permission.
    { path: '/system/topology', component: FleetTopologyPage },

    // Phase B hubs — path-based tabs delegate to nested <Routes>.
    { path: '/system/compute/*', component: ComputePage },
    { path: '/system/catalog/*', component: CatalogPage },
    { path: '/system/operations/*', component: OperationsHubPage },

    // SDWAN — single hub route. Network detail surfaces as a modal
    // triggered from the Networks tab; no standalone detail page.
    // P4.5.8 adds the `topology` tab (system-wide SDWAN + federation
    // graph via @xyflow/react).
    { path: '/system/sdwan/*', component: SdwanHubPage },

    // Federation Hub — Phase 3 multi-site control plane. Monitor | Control
    // path-based sub-tabs, so the `/*` wildcard is required. Gated on
    // system.peers.read (the page also renders its own permission-denied
    // empty state). Mirrors the Ingress hub's route-level permission gate.
    { path: '/system/federation/*', component: FederationHubPage, permission: 'system.peers.read' },

    // Service Delivery — federated service catalog (Offerings +
    // Subscriptions + Catalog Browser + Children). Renamed/moved from the
    // former /system/federation in Phase 3e so the multi-site hub above can
    // own /federation. Old /system/federation deep-links land on the new
    // hub directly (no redirect — the hub now owns that path).
    { path: '/system/service-delivery/*', component: ServiceDeliveryPage },

    // ACME hub — tabs: DNS Credentials (P2.5.8), Certificates (P2.5.9).
    // `/*` wildcard so path-based sub-tabs render.
    { path: '/system/acme/*', component: AcmePage },

    // Ingress hub — tabs: Routes (read-only monitor), Expose Service
    // (approval-gated Concierge wizard). `/*` wildcard so path-based
    // sub-tabs render. Plan reference: Phase 2c (Ingress).
    { path: '/system/ingress/*', component: IngressPage, permission: 'system.ingress.read' },

    // My VPN — one user's OWN SDWAN devices + config download. UNGATED, and
    // that is the design, not an oversight: the backend authorizes by
    // OWNERSHIP (the caller's own access grants), every authenticated user
    // may see their own devices, and there is no corresponding permission
    // string. Adding one would degrade to admin-only on this platform and
    // lock out exactly the ordinary users the page exists to serve.
    { path: '/system/my-vpn', component: MyVpnDevicesPage },
  ]);

  // Top-level "System" nav section. Phase B.5 collapses the previous
  // 21 entries to 6 hubs + drill-downs. Operators reach individual
  // resources via the hub's tab nav; old paths still resolve via the
  // redirects above.
  featureRegistry.registerNavSections('system', [
    {
      id: 'system',
      name: 'System',
      permissions: [],
      collapsible: true,
      defaultExpanded: false,
      order: 8,
      items: [
        { label: 'Overview',       path: '/app/system',                icon: 'LayoutDashboard', order: 1 },
        // Topology sits directly under Overview: it is the fleet-wide
        // "where does everything live" view the hubs' tables can't show.
        { label: 'Topology',       path: '/app/system/topology',       icon: 'Network',         order: 2 },
        { label: 'Compute',        path: '/app/system/compute',        icon: 'Server',          order: 3 },
        { label: 'Catalog',        path: '/app/system/catalog',        icon: 'Boxes',           order: 4 },
        // Template Composer was route-only (no nav entry, no in-app link)
        // — reachable solely by typing the URL. Gap G6.
        // Icon names must exist in lucide's `icons` map or the host falls
        // back to Puzzle — this build has WandSparkles, not Wand2.
        { label: 'Template Composer', path: '/app/system/templates/compose', icon: 'WandSparkles', order: 5 },
        { label: 'Operations',     path: '/app/system/operations',     icon: 'Activity',        order: 6 },
        { label: 'Instance Pools', path: '/app/system/instance-pools', icon: 'Droplet',         order: 7 },
        { label: 'SDWAN',            path: '/app/system/sdwan',            icon: 'ShieldCheck',     order: 8 },
        { label: 'Federation',       path: '/app/system/federation',       icon: 'Share2',          order: 9, permission: 'system.peers.read' },
        { label: 'Service Delivery', path: '/app/system/service-delivery', icon: 'Workflow',        order: 10 },
        { label: 'ACME',             path: '/app/system/acme',             icon: 'KeyRound',        order: 11 },
        { label: 'Ingress',          path: '/app/system/ingress',          icon: 'Globe',           order: 12, permission: 'system.ingress.read' },
        // My VPN is the one entry here aimed at a NON-operator: it is a
        // recipient's own devices, so it carries no permission (see the
        // route registration above).
        { label: 'My VPN',           path: '/app/system/my-vpn',           icon: 'Smartphone',      order: 13 },
      ],
    },
  ]);

  // Cross-reference entity types: wires the system extension's detail modals +
  // read APIs into the core entity registry so <EntityLink> / the global
  // <EntityReferenceHost> can resolve a `?entity=<type>&eid=<id>` to the right
  // detail surface. Owner-keyed under "system"; core stays ignorant of them.
  registerSystemEntities();
}
