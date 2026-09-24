import { ComponentType, lazy } from 'react';
import { featureRegistry } from '@/shared/services/featureRegistry';
import { registerSystemEntities } from './features/system/entityRegistry';
import { SIGNAL_FILTER_COLUMN_BY_KIND } from './features/system/components/fleet/signalsFilterColumns';
import { providerCredentialsApi } from './features/system/services/api/providerCredentialsApi';
import { nodeInstancePeersApi } from './features/system/services/api/nodeInstancePeersApi';

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
// Service Delivery — federated service catalog + federation control surfaces
// (Offerings, Subscriptions, Catalog Browser, Children, Fulfillment, Peers).
// FederationHubPage (Phase 3's standalone multi-site hub) was merged into
// this page (fe-dupes.md §10 item 16): its federation control surfaces (peer
// control, governance findings) moved into a new Peers tab here; its
// non-federation content (peer liveness, topology, OVN isolation, service
// discovery) moved to ComputePage's Platform tab instead. The old
// /system/federation path was deleted outright, not aliased (fc-25) —
// /system/service-delivery[/peers] is the only way in now.
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

    // Service Delivery — federated service catalog (Offerings +
    // Subscriptions + Catalog Browser + Children + Fulfillment) plus, since
    // the FederationHubPage merge, federation peer control + governance
    // (Peers tab).
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
  // resources via the hub's tab nav; the old standalone paths were
  // deleted outright (fc-25), not aliased.
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
        // 'Federation' nav entry removed — FederationHubPage was merged into
        // ServiceDeliveryPage (fe-dupes.md §10 item 16); a separate nav item
        // pointing at the same destination would be redundant. The old
        // /system/federation path is gone outright (fc-25), not redirected.
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

  // Component status drawer views: one registration per
  // `platform.status.drawer.<kind>.<view>` id (design §4, C4 rev 3). Core
  // never enumerates kinds or views — it lists whatever sits under a kind's
  // derived prefix and renders each as its own tab.
  //
  // node_instance.boot_replay: BootReplayModal's content minus the outer
  // Modal (the drawer already IS one) — see BootReplayDrawerView's own doc
  // for the ruling this follows.
  //
  // <kind>.signals: that component's recent fleet events, filtered by the
  // event's TYPED column (design §6, signals ruling) — never payload keys.
  // One slot per kind in SIGNAL_FILTER_COLUMN_BY_KIND, all served by the one
  // SignalsDrawerView, which reads the row's kind to pick the column.
  const signalsView = lazyPage(
    () => import('./features/system/components/fleet/SignalsDrawerView')
  );
  featureRegistry.registerComponentSlots({
    // The concierge chat's platform deployment wizard card: core renders a
    // card kind it does not own through 'ai.chat.card.<kind>'.
    'ai.chat.card.platform_deployment_wizard': lazyPage(
      () => import('./features/system/components/platform/PlatformDeploymentWizardCard')
    ),
    'platform.status.drawer.node_instance.boot_replay': lazyPage(
      () => import('./features/system/components/fleet/boot-replay/BootReplayDrawerView')
    ),
    ...Object.fromEntries(
      Object.keys(SIGNAL_FILTER_COLUMN_BY_KIND).map((kind) => [
        `platform.status.drawer.${kind}.signals`,
        signalsView,
      ])
    ),
  });

  // Cloud provider credentials. Core's setup wizard shows the cloud category
  // only while these are registered, and saves/tests through them rather than
  // naming this extension's route. A first-run save has no provider row yet,
  // so the type slug stands in for the id and the server creates the provider.
  featureRegistry.registerProviderCategoryHandlers('cloud', {
    createCredential: ({ providerType, credentials }) =>
      providerCredentialsApi.create({ providerId: providerType, providerType, credentials }),
    testCredential: (request) => providerCredentialsApi.test(request),
  });

  // Peer operators join the chat @-mention picker through a mention source,
  // so core's conversation view names no route of this extension.
  featureRegistry.registerMentionSources('system', [() => nodeInstancePeersApi.mentionable()]);
}
