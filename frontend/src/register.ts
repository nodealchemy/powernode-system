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
// Slice 3 of the SDWAN plan.
const SdwanNetworksPage = lazyPage(() => import('./pages/app/system/SdwanNetworksPage'));
const SdwanNetworkDetailPage = lazyPage(() => import('./pages/app/system/SdwanNetworkDetailPage'));
// Slice 6 of the SDWAN plan — federation peers + governance scan.
const SdwanFederationPage = lazyPage(() => import('./pages/app/system/SdwanFederationPage'));
// Slice 9d of the SDWAN plan — account-level routing dashboard.
const SdwanRoutingPage = lazyPage(() => import('./pages/app/system/SdwanRoutingPage'));
// Phase B.1 — Compute hub. Consolidates Nodes, Unclaimed Devices,
// Volumes, Providers, and Networks into a single tabbed page.
const ComputePage = lazyPage(() => import('./pages/app/system/ComputePage'));
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
    // Slice 3 of the SDWAN plan.
    { path: '/system/sdwan', component: SdwanNetworksPage },
    // Slice 6: federation lives at a fixed sub-path; must register
    // before the catch-all /:id route so the literal "federation"
    // segment matches first.
    { path: '/system/sdwan/federation', component: SdwanFederationPage },
    // Slice 9d: account-level routing dashboard. Must precede /:id.
    // Wildcard /* enables path-based tabs (overview, sessions, policies).
    { path: '/system/sdwan/routing/*', component: SdwanRoutingPage },
    { path: '/system/sdwan/:id', component: SdwanNetworkDetailPage },
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
        // Slice 3 of the SDWAN plan.
        { label: 'SDWAN', path: '/app/system/sdwan', icon: 'ShieldCheck', order: 18 },
        // Slice 6: federation peers + governance scan.
        { label: 'SDWAN Federation', path: '/app/system/sdwan/federation', icon: 'Globe2', order: 19 },
        // Slice 9d: SDWAN routing dashboard (account-level iBGP control plane).
        { label: 'SDWAN Routing', path: '/app/system/sdwan/routing', icon: 'Route', order: 19.5 },
      ],
    },
  ]);
}
