import React, { ComponentType, lazy } from 'react';
import { Navigate } from 'react-router-dom';
import { featureRegistry } from '@/shared/services/featureRegistry';

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
// Phase B hubs.
const ComputePage = lazyPage(() => import('./pages/app/system/ComputePage'));
const CatalogPage = lazyPage(() => import('./pages/app/system/CatalogPage'));
const OperationsHubPage = lazyPage(() => import('./pages/app/system/OperationsHubPage'));
const SdwanHubPage = lazyPage(() => import('./pages/app/system/SdwanHubPage'));
const FederationHubPage = lazyPage(() => import('./pages/app/system/FederationHubPage'));
// ACME — DNS provider credentials + Let's Encrypt cert lifecycle.
// Plan reference: Decentralized Federation §J + P2.5.8.
const AcmePage = lazyPage(() => import('./pages/app/system/AcmePage'));
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

    // Phase B hubs — path-based tabs delegate to nested <Routes>.
    { path: '/system/compute/*', component: ComputePage },
    { path: '/system/catalog/*', component: CatalogPage },
    { path: '/system/operations/*', component: OperationsHubPage },

    // SDWAN — single hub route. Network detail surfaces as a modal
    // triggered from the Networks tab; no standalone detail page.
    // P4.5.8 adds the `topology` tab (system-wide SDWAN + federation
    // graph via @xyflow/react).
    { path: '/system/sdwan/*', component: SdwanHubPage },

    // Federation Services hub (Offerings + Subscriptions + Catalog
    // Browser). P4.6.8 — operator-facing surfaces for federated
    // service delivery. Plan reference: §L.7.
    { path: '/system/federation/*', component: FederationHubPage },

    // ACME hub — tabs: DNS Credentials (P2.5.8), Certificates (P2.5.9).
    // `/*` wildcard so path-based sub-tabs render.
    { path: '/system/acme/*', component: AcmePage },
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
        { label: 'Compute',        path: '/app/system/compute',        icon: 'Server',          order: 2 },
        { label: 'Catalog',        path: '/app/system/catalog',        icon: 'Boxes',           order: 3 },
        { label: 'Operations',     path: '/app/system/operations',     icon: 'Activity',        order: 4 },
        { label: 'Instance Pools', path: '/app/system/instance-pools', icon: 'Droplet',         order: 5 },
        { label: 'SDWAN',          path: '/app/system/sdwan',          icon: 'ShieldCheck',     order: 6 },
        { label: 'Federation',     path: '/app/system/federation',     icon: 'Share2',          order: 7 },
        { label: 'ACME',           path: '/app/system/acme',           icon: 'KeyRound',        order: 8 },
      ],
    },
  ]);
}
