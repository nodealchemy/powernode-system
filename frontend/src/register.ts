import { lazy } from 'react';
import { featureRegistry } from '@/shared/services/featureRegistry';

// Lazy-loaded system page components.
// Paths are relative to this register.ts so the @system/ alias is not required here.
const SystemOverviewPage = lazy(() => import('./pages/app/system/SystemOverviewPage').then(m => ({ default: m.default || m.SystemOverviewPage })));
const NodesPage = lazy(() => import('./pages/app/system/NodesPage').then(m => ({ default: m.default || m.NodesPage })));
const OperationsPage = lazy(() => import('./pages/app/system/OperationsPage').then(m => ({ default: m.default || m.OperationsPage })));
const ProvidersPage = lazy(() => import('./pages/app/system/ProvidersPage').then(m => ({ default: m.default || m.ProvidersPage })));
const ArchitecturesPage = lazy(() => import('./pages/app/system/ArchitecturesPage').then(m => ({ default: m.default || m.ArchitecturesPage })));
const PlatformsPage = lazy(() => import('./pages/app/system/PlatformsPage').then(m => ({ default: m.default || m.PlatformsPage })));
const TemplatesPage = lazy(() => import('./pages/app/system/TemplatesPage').then(m => ({ default: m.default || m.TemplatesPage })));
const VolumesPage = lazy(() => import('./pages/app/system/VolumesPage').then(m => ({ default: m.default || m.VolumesPage })));
const NetworksPage = lazy(() => import('./pages/app/system/NetworksPage').then(m => ({ default: m.default || m.NetworksPage })));
const ScriptsPage = lazy(() => import('./pages/app/system/ScriptsPage').then(m => ({ default: m.default || m.ScriptsPage })));
const ModulesPage = lazy(() => import('./pages/app/system/ModulesPage').then(m => ({ default: m.default || m.ModulesPage })));
const PuppetModulesPage = lazy(() => import('./pages/app/system/PuppetModulesPage').then(m => ({ default: m.default || m.PuppetModulesPage })));
const FleetDashboardPage = lazy(() => import('./pages/app/system/FleetDashboardPage').then(m => ({ default: m.default || m.FleetDashboardPage })));
const TemplateComposerPage = lazy(() => import('./pages/app/system/TemplateComposerPage').then(m => ({ default: m.default || m.TemplateComposerPage })));
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
    // services / audit-logs / storage-providers / workers all removed —
    // see comment above for rationale.
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
        { label: 'Nodes', path: '/app/system/nodes', icon: 'Server', order: 3 },
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
        // Workers / Audit Logs / Storage / Services removed — these
        // duplicated admin/* pages and live at /app/admin/{workers,audit-logs,
        // storage-providers,services}.
      ],
    },
  ]);
}
