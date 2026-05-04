import { ComponentType, lazy } from 'react';
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

const SystemOverviewPage = lazyPage(() => import('./pages/app/system/SystemOverviewPage'));
const NodesPage = lazyPage(() => import('./pages/app/system/NodesPage'));
const OperationsPage = lazyPage(() => import('./pages/app/system/OperationsPage'));
const ProvidersPage = lazyPage(() => import('./pages/app/system/ProvidersPage'));
const ArchitecturesPage = lazyPage(() => import('./pages/app/system/ArchitecturesPage'));
const PlatformsPage = lazyPage(() => import('./pages/app/system/PlatformsPage'));
const TemplatesPage = lazyPage(() => import('./pages/app/system/TemplatesPage'));
const VolumesPage = lazyPage(() => import('./pages/app/system/VolumesPage'));
const NetworksPage = lazyPage(() => import('./pages/app/system/NetworksPage'));
const ScriptsPage = lazyPage(() => import('./pages/app/system/ScriptsPage'));
const ModulesPage = lazyPage(() => import('./pages/app/system/ModulesPage'));
const PuppetModulesPage = lazyPage(() => import('./pages/app/system/PuppetModulesPage'));
const FleetDashboardPage = lazyPage(() => import('./pages/app/system/FleetDashboardPage'));
const TemplateComposerPage = lazyPage(() => import('./pages/app/system/TemplateComposerPage'));
const UnclaimedDevicesPage = lazyPage(() => import('./pages/app/system/UnclaimedDevicesPage'));
const DiskImageWebhooksPage = lazyPage(() => import('./pages/app/system/DiskImageWebhooksPage'));
const CiWorkersPage = lazyPage(() => import('./pages/app/system/CiWorkersPage'));
// Comprehensive stabilization sweep P7.2 — Module Marketplace.
const MarketplacePage = lazyPage(() => import('./pages/app/system/MarketplacePage'));
// Comprehensive stabilization sweep P7.1 — Boot Replay viewer (M-FE-3 completion).
const BootReplayPage = lazyPage(() => import('./pages/app/system/BootReplayPage'));
// SdwanNetworkDetailPage is the per-network drill-down (own
// PageContainer + 7 internal tabs). The list, federation, and
// routing pages were absorbed into SdwanHubPage as tab content
// (Phase B.4) — those page files still exist on disk because
// SdwanHubPage / its tab orchestrators import the underlying
// components, but they are no longer top-level routed.
const SdwanNetworkDetailPage = lazyPage(() => import('./pages/app/system/SdwanNetworkDetailPage'));
// Phase B.1 — Compute hub. Consolidates Nodes, Unclaimed Devices,
// Volumes, Providers, and Networks into a single tabbed page.
const ComputePage = lazyPage(() => import('./pages/app/system/ComputePage'));
// Phase B.2 — Catalog hub. Consolidates Templates, Modules, Puppet
// Modules, Scripts, Architectures, Platforms, and Marketplace.
const CatalogPage = lazyPage(() => import('./pages/app/system/CatalogPage'));
// Phase B.3 — Operations hub. Consolidates Fleet Dashboard, Tasks,
// CI Workers, and CI Webhooks. Named OperationsHubPage to avoid
// colliding with the existing OperationsPage (legacy /system/tasks
// page that becomes the Tasks tab).
const OperationsHubPage = lazyPage(() => import('./pages/app/system/OperationsHubPage'));
// Phase B.4 — SDWAN hub. Consolidates Networks list, Routing, and
// Federation. Per-network detail (peers/firewall/topology) lives at
// the sibling route /sdwan/networks/:id/* (registered first so React
// Router matches the more specific path before the hub catch-all).
const SdwanHubPage = lazyPage(() => import('./pages/app/system/SdwanHubPage'));
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
    { path: '/system/nodes', component: NodesPage },
    { path: '/system/tasks', component: OperationsPage },
    { path: '/system/providers', component: ProvidersPage },
    { path: '/system/architectures', component: ArchitecturesPage },
    { path: '/system/platforms', component: PlatformsPage },
    { path: '/system/templates', component: TemplatesPage },
    { path: '/system/volumes', component: VolumesPage },
    { path: '/system/networks', component: NetworksPage },
    { path: '/system/scripts', component: ScriptsPage },
    { path: '/system/modules', component: ModulesPage },
    { path: '/system/puppet-modules', component: PuppetModulesPage },
    { path: '/system/fleet', component: FleetDashboardPage },
    { path: '/system/templates/compose', component: TemplateComposerPage },
    { path: '/system/unclaimed-devices', component: UnclaimedDevicesPage },
    { path: '/system/disk-image-webhooks', component: DiskImageWebhooksPage },
    { path: '/system/ci-workers', component: CiWorkersPage },
    { path: '/system/marketplace', component: MarketplacePage },
    { path: '/system/boot-replay/:instance_id', component: BootReplayPage },
    // Phase B.1 — Compute hub: Nodes / Unclaimed Devices / Volumes /
    // Providers / Networks consolidated under one tabbed page. The
    // wildcard /* delegates path matching to ComputePage's nested
    // <Routes>, so each tab gets its own URL
    // (/app/system/compute/nodes, /app/system/compute/volumes, etc.)
    // matching the canonical platform tab pattern from
    // AdminSettingsPage. Old standalone routes (above) still work;
    // sidebar cleanup happens in Phase B.5.
    { path: '/system/compute/*', component: ComputePage },
    // Phase B.2 — Catalog hub: Templates / Modules / Puppet Modules /
    // Scripts / Architectures / Platforms / Marketplace consolidated
    // under one tabbed page with path-based tabs.
    { path: '/system/catalog/*', component: CatalogPage },
    // Phase B.3 — Operations hub: Fleet Dashboard / Tasks / CI Workers /
    // CI Webhooks consolidated under one tabbed page.
    { path: '/system/operations/*', component: OperationsHubPage },
    // Phase B.4 — SDWAN hub at /system/sdwan/* with 3 tabs (networks,
    // routing, federation). The detail page registers FIRST as a more
    // specific sibling so /sdwan/networks/:id/topology routes to the
    // detail page (which has its own PageContainer + 7 internal tabs)
    // rather than into the hub. Standalone SDWAN page routes from the
    // pre-B.4 era are removed; their imports below remain because they
    // are still referenced by the legacy sidebar entries that B.5
    // cleanup will remove together.
    { path: '/system/sdwan/networks/:id/*', component: SdwanNetworkDetailPage },
    { path: '/system/sdwan/*', component: SdwanHubPage },
  ]);

  // Top-level "System" nav section. Label, section ID, namespace, route
  // prefix, and extension slug are all "System"/"system" — single source
  // of truth, no decoupling.
  featureRegistry.registerNavSections('system', [
    {
      id: 'system',
      name: 'System',
      permissions: [],
      collapsible: true,
      defaultExpanded: false,
      order: 8,
      items: [
        { label: 'Overview', path: '/app/system', icon: 'LayoutDashboard', order: 1 },
        { label: 'Fleet Dashboard', path: '/app/system/fleet', icon: 'Activity', order: 2 },
        // Phase B.1 — Compute hub (consolidates Nodes/Unclaimed/Volumes/
        // Providers/Networks). Standalone entries below remain for
        // direct access until Phase B.5 cleanup.
        { label: 'Compute', path: '/app/system/compute', icon: 'Server', order: 2.5 },
        // Phase B.2 — Catalog hub (consolidates Templates/Modules/
        // Puppet/Scripts/Architectures/Platforms/Marketplace).
        { label: 'Catalog', path: '/app/system/catalog', icon: 'Boxes', order: 2.6 },
        // Phase B.3 — Operations hub (consolidates Fleet Dashboard /
        // Tasks / CI Workers / CI Webhooks).
        { label: 'Operations', path: '/app/system/operations', icon: 'Activity', order: 2.7 },
        { label: 'Nodes', path: '/app/system/nodes', icon: 'Server', order: 3 },
        // Physical-device claim queue (plan wondrous-yawning-anchor.md).
        { label: 'Unclaimed Devices', path: '/app/system/unclaimed-devices', icon: 'Cpu', order: 3.5 },
        { label: 'Operations', path: '/app/system/tasks', icon: 'Activity', order: 4 },
        { label: 'Providers', path: '/app/system/providers', icon: 'Cloud', order: 5 },
        { label: 'Templates', path: '/app/system/templates', icon: 'LayoutTemplate', order: 6 },
        { label: 'Template Composer', path: '/app/system/templates/compose', icon: 'PaintBucket', order: 7 },
        { label: 'Architectures', path: '/app/system/architectures', icon: 'Cpu', order: 8 },
        { label: 'Platforms', path: '/app/system/platforms', icon: 'HardDrive', order: 9 },
        { label: 'Volumes', path: '/app/system/volumes', icon: 'Database', order: 10 },
        { label: 'Networks', path: '/app/system/networks', icon: 'Network', order: 11 },
        { label: 'Modules', path: '/app/system/modules', icon: 'Boxes', order: 12 },
        { label: 'Puppet Modules', path: '/app/system/puppet-modules', icon: 'PackageOpen', order: 13 },
        { label: 'Scripts', path: '/app/system/scripts', icon: 'FileCode', order: 14 },
        // Disk-image CI registration (plan wondrous-yawning-anchor.md Phase 2).
        { label: 'CI Webhooks', path: '/app/system/disk-image-webhooks', icon: 'Webhook', order: 15 },
        { label: 'CI Workers', path: '/app/system/ci-workers', icon: 'Bot', order: 16 },
        // Module Marketplace (P7.2 / M-FE-2 — comprehensive stabilization sweep).
        { label: 'Marketplace', path: '/app/system/marketplace', icon: 'Store', order: 17 },
        // Phase B.4 — consolidated SDWAN hub. Networks list, Routing
        // dashboard, and Federation peers all become tabs of one hub
        // page. The previous separate "SDWAN Federation" and "SDWAN
        // Routing" sidebar entries are removed.
        { label: 'SDWAN', path: '/app/system/sdwan', icon: 'ShieldCheck', order: 18 },
      ],
    },
  ]);
}
