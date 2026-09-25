// Unit tests for register.ts
//
// register() is a pure side-effect entry point. It calls:
//   1. featureRegistry.registerRoutes('system', [...])   — 12 routes
//   2. featureRegistry.registerNavSections('system', [...]) — 1 section, 12 items
//   3. registerSystemEntities()                          — cross-reference wiring
//   4. featureRegistry.registerComponentSlots({...})     — drawer views + the
//      devops.ci-cd.tab.module-builds CI/CD tab slot (fc-34, revised per review)
//   5. featureRegistry.registerSlotMeta({...})           — the Module Builds
//      slot's label + gating permission (fc-34 round 3)
//
// Strategy: mock the two dependencies so we can assert on exact payloads
// without touching the DOM, React lazy loading, or the entity sub-system.

// =============================================================================
// Mocks
// =============================================================================

const mockRegisterRoutes = jest.fn();
const mockRegisterNavSections = jest.fn();
const mockRegisterComponentSlots = jest.fn();
const mockRegisterSlotMeta = jest.fn();
const mockRegisterProviderCategoryHandlers = jest.fn();

jest.mock('@/shared/services/featureRegistry', () => ({
  featureRegistry: {
    registerRoutes: (...args: unknown[]) => mockRegisterRoutes(...args),
    registerNavSections: (...args: unknown[]) => mockRegisterNavSections(...args),
    registerComponentSlots: (...args: unknown[]) => mockRegisterComponentSlots(...args),
    registerSlotMeta: (...args: unknown[]) => mockRegisterSlotMeta(...args),
    registerProviderCategoryHandlers: (...args: unknown[]) =>
      mockRegisterProviderCategoryHandlers(...args),
    registerMentionSources: (...args: unknown[]) => mockRegisterMentionSources(...args),
    registerPolicyDomains: (...args: unknown[]) => mockRegisterPolicyDomains(...args),
  },
}));

const mockRegisterMentionSources = jest.fn();
const mockRegisterPolicyDomains = jest.fn();
const mockMentionable = jest.fn();

jest.mock('./features/system/services/api/nodeInstancePeersApi', () => ({
  nodeInstancePeersApi: { mentionable: (...args: unknown[]) => mockMentionable(...args) },
}));

const mockCreate = jest.fn();
const mockTest = jest.fn();

jest.mock('./features/system/services/api/providerCredentialsApi', () => ({
  providerCredentialsApi: {
    create: (...args: unknown[]) => mockCreate(...args),
    test: (...args: unknown[]) => mockTest(...args),
  },
}));

const mockRegisterSystemEntities = jest.fn();

jest.mock('./features/system/entityRegistry', () => ({
  registerSystemEntities: () => mockRegisterSystemEntities(),
}));

// =============================================================================
// Subject under test — import AFTER mocks
// =============================================================================

import { register } from './register';

// =============================================================================
// Setup
// =============================================================================

beforeEach(() => {
  mockRegisterRoutes.mockReset();
  mockRegisterNavSections.mockReset();
  mockRegisterSystemEntities.mockReset();
});

// =============================================================================
// register() — top-level behaviour
// =============================================================================

describe('register()', () => {
  it('calls registerRoutes, registerNavSections, registerComponentSlots, registerSlotMeta, and registerSystemEntities exactly once each', () => {
    register();

    expect(mockRegisterRoutes).toHaveBeenCalledTimes(1);
    expect(mockRegisterNavSections).toHaveBeenCalledTimes(1);
    expect(mockRegisterComponentSlots).toHaveBeenCalledTimes(1);
    expect(mockRegisterSlotMeta).toHaveBeenCalledTimes(1);
    expect(mockRegisterSystemEntities).toHaveBeenCalledTimes(1);
  });

  it('registers everything under the "system" namespace', () => {
    register();

    expect(mockRegisterRoutes).toHaveBeenCalledWith('system', expect.any(Array));
    expect(mockRegisterNavSections).toHaveBeenCalledWith('system', expect.any(Array));
  });

  it('is safe to call multiple times (each call registers routes again)', () => {
    register();
    register();

    expect(mockRegisterRoutes).toHaveBeenCalledTimes(2);
    expect(mockRegisterNavSections).toHaveBeenCalledTimes(2);
    expect(mockRegisterComponentSlots).toHaveBeenCalledTimes(2);
    expect(mockRegisterSystemEntities).toHaveBeenCalledTimes(2);
  });
});

// =============================================================================
// registerComponentSlots — component status drawer views
// =============================================================================

describe('registered component slots', () => {
  let slots: Record<string, unknown>;

  beforeEach(() => {
    mockRegisterComponentSlots.mockClear();
    register();
    slots = mockRegisterComponentSlots.mock.calls[0][0] as Record<string, unknown>;
  });

  it('registers the deployment wizard chat card, boot_replay, one signals view per filterable kind, the CI/CD Module Builds tab slot, and nothing else', () => {
    expect(Object.keys(slots).sort()).toEqual([
      'ai.chat.card.platform_deployment_wizard',
      'devops.ci-cd.tab.module-builds',
      'platform.status.drawer.acme_certificate.signals',
      'platform.status.drawer.node_instance.boot_replay',
      'platform.status.drawer.node_instance.signals',
      'platform.status.drawer.node_module.signals',
    ]);
  });

  // fc-34, revised per review: registered as a generic devops.ci-cd.tab.*
  // component slot (CiCdPage.tsx discovers it) instead of a standalone route
  // + sidebar nav item — see the "registered routes" and former "registered
  // nav items" coverage below/removed.
  it('the Module Builds CI/CD tab slot is a lazy component, not undefined', () => {
    expect(slots['devops.ci-cd.tab.module-builds']).toBeDefined();
  });

  it('the deployment wizard chat card slot is a lazy component, not undefined', () => {
    expect(slots['ai.chat.card.platform_deployment_wizard']).toBeDefined();
  });

  it('the boot_replay slot is a lazy component, not undefined', () => {
    expect(slots['platform.status.drawer.node_instance.boot_replay']).toBeDefined();
  });

  // One component serves every kind: it picks the column from the row's kind,
  // so the kind->column map has a single home (signalsFilterColumns.ts).
  it('points every signals slot at the same lazy component, distinct from boot_replay', () => {
    const signals = [
      slots['platform.status.drawer.node_instance.signals'],
      slots['platform.status.drawer.node_module.signals'],
      slots['platform.status.drawer.acme_certificate.signals'],
    ];
    signals.forEach((slot) => expect(slot).toBeDefined());
    expect(new Set(signals).size).toBe(1);
    expect(signals[0]).not.toBe(slots['platform.status.drawer.node_instance.boot_replay']);
  });
});

// =============================================================================
// registerSlotMeta — the Module Builds tab slot's label + gating permission
// =============================================================================

describe('registered slot metadata', () => {
  let meta: Record<string, { permissions?: string[]; label?: string }>;

  beforeEach(() => {
    mockRegisterSlotMeta.mockClear();
    register();
    meta = mockRegisterSlotMeta.mock.calls[0][0] as Record<string, { permissions?: string[]; label?: string }>;
  });

  it('is called exactly once', () => {
    expect(mockRegisterSlotMeta).toHaveBeenCalledTimes(1);
  });

  it('registers metadata for the Module Builds CI/CD tab slot, and nothing else', () => {
    expect(Object.keys(meta)).toEqual(['devops.ci-cd.tab.module-builds']);
  });

  it('labels it "Module Builds" in Title Case, matching the other CI/CD tabs', () => {
    expect(meta['devops.ci-cd.tab.module-builds'].label).toBe('Module Builds');
  });

  it('gates it on system.module_builds.read, matching the tab component\'s own check', () => {
    expect(meta['devops.ci-cd.tab.module-builds'].permissions).toEqual(['system.module_builds.read']);
  });
});

// =============================================================================
// registerRoutes — path coverage
// =============================================================================

describe('registered routes', () => {
  let routes: Array<{ path: string; component: unknown; permission?: string }>;

  beforeEach(() => {
    register();
    routes = mockRegisterRoutes.mock.calls[0][1] as typeof routes;
  });

  it('registers 12 routes in total', () => {
    expect(routes).toHaveLength(12);
  });

  // Primary pages
  it('registers /system (SystemOverviewPage lazy component)', () => {
    const r = routes.find((x) => x.path === '/system');
    expect(r).toBeDefined();
    expect(r!.component).toBeDefined();
    expect(r!.permission).toBeUndefined();
  });

  // /system/overview was a duplicate alias of /system (same component) —
  // deleted outright, not redirected (fc-25).
  it('does not register a duplicate /system/overview alias', () => {
    expect(routes.find((x) => x.path === '/system/overview')).toBeUndefined();
  });

  it('registers /system/templates/compose (TemplateComposerPage)', () => {
    const r = routes.find((x) => x.path === '/system/templates/compose');
    expect(r).toBeDefined();
    expect(r!.component).toBeDefined();
    expect(r!.permission).toBeUndefined();
  });

  it('registers /system/instance-pools (InstancePoolsPage)', () => {
    const r = routes.find((x) => x.path === '/system/instance-pools');
    expect(r).toBeDefined();
    expect(r!.component).toBeDefined();
    expect(r!.permission).toBeUndefined();
  });

  // My VPN — the recipient's own SDWAN devices. The UNGATED assertion is the
  // point of this test, not incidental: authorization is ownership, enforced
  // server-side, and there is no `system.sdwan.my_devices.*` permission. A
  // permission name that is not code-defined degrades to admin-only on this
  // platform, so adding a gate here would lock out exactly the ordinary users
  // the page serves. If this assertion ever fails, the fix is to delete the
  // permission, not to update the expectation.
  it('registers /system/my-vpn (MyVpnDevicesPage) with NO permission gate', () => {
    const r = routes.find((x) => x.path === '/system/my-vpn');
    expect(r).toBeDefined();
    expect(r!.component).toBeDefined();
    expect(r!.permission).toBeUndefined();
  });

  it('registers /system/topology (FleetTopologyPage) ungated', () => {
    const r = routes.find((x) => x.path === '/system/topology');
    expect(r).toBeDefined();
    expect(r!.component).toBeDefined();
    // Ungated like the Compute/Catalog/Operations hubs — each underlying
    // list API still enforces its own permission.
    expect(r!.permission).toBeUndefined();
  });

  // Hub routes
  it.each([
    ['/system/compute/*'],
    ['/system/catalog/*'],
    ['/system/operations/*'],
    ['/system/sdwan/*'],
    ['/system/service-delivery/*'],
    ['/system/acme/*'],
  ])('registers hub route %s without a permission gate', (path) => {
    const r = routes.find((x) => x.path === path);
    expect(r).toBeDefined();
    expect(r!.component).toBeDefined();
    expect(r!.permission).toBeUndefined();
  });

  // FederationHubPage was merged into ServiceDeliveryPage (fe-dupes.md §10
  // item 16); the old /system/federation path was deleted outright, not
  // redirected (fc-25) — /system/service-delivery[/peers] is the only way in.
  it('does not register /system/federation/* (deleted, not redirected)', () => {
    expect(routes.find((x) => x.path === '/system/federation/*')).toBeUndefined();
  });

  it('registers /system/ingress/* gated on system.ingress.read', () => {
    const r = routes.find((x) => x.path === '/system/ingress/*');
    expect(r).toBeDefined();
    expect(r!.permission).toBe('system.ingress.read');
  });

  // fc-34, revised per review: Module Builds is no longer a registered
  // route at all — it mounts as a devops.ci-cd.tab.* component slot inside
  // CiCdPage instead (see "registered component slots" above). Nothing in
  // core enforces FeatureRoute.permission, so a route registration's
  // `permission` field was never the real gate; ModuleBuildsCiCdTab's own
  // hasPermission check is.
  it('does not register a standalone /devops/ci-cd/module-builds route', () => {
    expect(routes.find((x) => x.path === '/devops/ci-cd/module-builds')).toBeUndefined();
  });

  // Phase B.5's legacy redirect routes (nodes, templates, modules, fleet,
  // federation, ...) were deleted outright in fc-25, not kept as aliases —
  // every caller was migrated to its canonical hub-tab path in the same
  // change. No route in this registry should be a redirect component.
  const deletedLegacyPaths = [
    '/system/overview',
    '/system/nodes',
    '/system/unclaimed-devices',
    '/system/volumes',
    '/system/providers',
    '/system/networks',
    '/system/templates',
    '/system/modules',
    '/system/puppet-modules',
    '/system/scripts',
    '/system/architectures',
    '/system/platforms',
    '/system/marketplace',
    '/system/fleet',
    '/system/tasks',
    '/system/ci-workers',
    '/system/disk-image-webhooks',
    '/system/federation/*',
  ];

  it.each(deletedLegacyPaths)('does not register deleted legacy path %s', (path) => {
    expect(routes.find((x) => x.path === path)).toBeUndefined();
  });

  it('no two routes share the same path', () => {
    const paths = routes.map((r) => r.path);
    const unique = new Set(paths);
    expect(unique.size).toBe(paths.length);
  });
});

// =============================================================================
// registerNavSections — shape and item coverage
// =============================================================================

describe('registered nav sections', () => {
  type NavItem = {
    label: string;
    path: string;
    icon: string;
    order: number;
    permission?: string;
  };
  type NavSection = {
    id: string;
    name: string;
    permissions: string[];
    collapsible: boolean;
    defaultExpanded: boolean;
    order: number;
    items: NavItem[];
  };

  let sections: NavSection[];
  let systemSection: NavSection;
  let items: NavItem[];

  beforeEach(() => {
    register();
    sections = mockRegisterNavSections.mock.calls[0][1] as NavSection[];
    systemSection = sections[0];
    items = systemSection.items;
  });

  it('registers exactly 1 nav section', () => {
    expect(sections).toHaveLength(1);
  });

  it('the section id is "system" and name is "System"', () => {
    expect(systemSection.id).toBe('system');
    expect(systemSection.name).toBe('System');
  });

  it('the section is collapsible and not expanded by default', () => {
    expect(systemSection.collapsible).toBe(true);
    expect(systemSection.defaultExpanded).toBe(false);
  });

  it('the section has order 8 and no permission restrictions', () => {
    expect(systemSection.order).toBe(8);
    expect(systemSection.permissions).toEqual([]);
  });

  // 12, not 13 — the 'Federation' nav item was removed when FederationHubPage
  // merged into ServiceDeliveryPage (fe-dupes.md §10 item 16): a separate nav
  // entry pointing at the same destination as 'Service Delivery' would be
  // redundant. Old /system/federation deep-links still redirect (see the
  // route registration tests above).
  it('registers 12 nav items', () => {
    expect(items).toHaveLength(12);
  });

  // Verify every item individually
  const expectedItems: Array<{
    label: string;
    path: string;
    icon: string;
    order: number;
    permission?: string;
  }> = [
    { label: 'Overview',          path: '/app/system',                icon: 'LayoutDashboard', order: 1 },
    { label: 'Topology',          path: '/app/system/topology',       icon: 'Network',         order: 2 },
    { label: 'Compute',           path: '/app/system/compute',        icon: 'Server',          order: 3 },
    { label: 'Catalog',           path: '/app/system/catalog',        icon: 'Boxes',           order: 4 },
    { label: 'Template Composer', path: '/app/system/templates/compose', icon: 'WandSparkles', order: 5 },
    { label: 'Operations',        path: '/app/system/operations',     icon: 'Activity',        order: 6 },
    { label: 'Instance Pools',    path: '/app/system/instance-pools', icon: 'Droplet',         order: 7 },
    { label: 'SDWAN',             path: '/app/system/sdwan',          icon: 'ShieldCheck',     order: 8 },
    { label: 'Service Delivery',  path: '/app/system/service-delivery', icon: 'Workflow',      order: 10 },
    { label: 'ACME',              path: '/app/system/acme',           icon: 'KeyRound',        order: 11 },
    { label: 'Ingress',           path: '/app/system/ingress',        icon: 'Globe',           order: 12, permission: 'system.ingress.read' },
    { label: 'My VPN',            path: '/app/system/my-vpn',         icon: 'Smartphone',      order: 13 },
  ];

  it('does not register a "Federation" nav item (merged into Service Delivery)', () => {
    expect(items.find((i) => i.label === 'Federation')).toBeUndefined();
  });

  it.each(expectedItems)(
    'nav item "%s" has correct path, icon, order, and permission',
    ({ label, path, icon, order, permission }) => {
      const item = items.find((i) => i.label === label);
      expect(item).toBeDefined();
      expect(item!.path).toBe(path);
      expect(item!.icon).toBe(icon);
      expect(item!.order).toBe(order);
      if (permission !== undefined) {
        expect(item!.permission).toBe(permission);
      } else {
        expect(item!.permission).toBeUndefined();
      }
    },
  );

  it('items are sorted in ascending order by their order field', () => {
    const orders = items.map((i) => i.order);
    const sorted = [...orders].sort((a, b) => a - b);
    expect(orders).toEqual(sorted);
  });

  it('only Ingress carries a permission gate', () => {
    const gated = items.filter((i) => i.permission !== undefined);
    expect(gated).toHaveLength(1);
    expect(gated.map((i) => i.label).sort()).toEqual(['Ingress']);
  });
});

// =============================================================================
// registerSystemEntities delegation
// =============================================================================

describe('registerSystemEntities delegation', () => {
  it('calls registerSystemEntities during register()', () => {
    register();
    expect(mockRegisterSystemEntities).toHaveBeenCalledTimes(1);
  });

  it('registerSystemEntities is called after routes and nav sections are registered', () => {
    const callOrder: string[] = [];
    mockRegisterRoutes.mockImplementation(() => callOrder.push('routes'));
    mockRegisterNavSections.mockImplementation(() => callOrder.push('navSections'));
    mockRegisterSystemEntities.mockImplementation(() => callOrder.push('entities'));

    register();

    expect(callOrder).toEqual(['routes', 'navSections', 'entities']);
  });
});

// =============================================================================
// Cloud provider credentials: the category core's setup wizard shows only
// when an extension serves it
// =============================================================================

describe('register() — cloud provider credentials', () => {
  beforeEach(() => {
    mockRegisterProviderCategoryHandlers.mockReset();
    mockCreate.mockReset();
    mockTest.mockReset();
  });

  it('registers create/test handlers for the cloud category exactly once', () => {
    register();

    expect(mockRegisterProviderCategoryHandlers).toHaveBeenCalledTimes(1);
    expect(mockRegisterProviderCategoryHandlers).toHaveBeenCalledWith('cloud', {
      createCredential: expect.any(Function),
      testCredential: expect.any(Function),
    });
  });

  it('creates through the extension client, resolving the provider from its type', async () => {
    mockCreate.mockResolvedValue('cred-1');
    register();
    const [, handlers] = mockRegisterProviderCategoryHandlers.mock.calls[0];

    await expect(
      handlers.createCredential({ providerType: 'hetzner', credentials: { api_token: 't' } })
    ).resolves.toBe('cred-1');
    expect(mockCreate).toHaveBeenCalledWith({
      providerId: 'hetzner',
      providerType: 'hetzner',
      credentials: { api_token: 't' },
    });
  });

  it('tests through the extension client', async () => {
    mockTest.mockResolvedValue({ valid: true });
    register();
    const [, handlers] = mockRegisterProviderCategoryHandlers.mock.calls[0];
    const request = { providerId: 'aws', providerType: 'aws', category: 'cloud', credentials: {} };

    await expect(handlers.testCredential(request)).resolves.toEqual({ valid: true });
    expect(mockTest).toHaveBeenCalledWith(request);
  });
});

// =============================================================================
// Chat @-mention members: peer operators, contributed to core's picker
// =============================================================================

describe('register() — mention sources', () => {
  beforeEach(() => {
    mockRegisterMentionSources.mockReset();
    mockMentionable.mockReset();
  });

  it('registers one mention source that reads the mentionable peers', async () => {
    const members = [{ id: 'a1', name: 'peer-op', role: 'operator', agent_type: 'peer', is_lead: false }];
    mockMentionable.mockResolvedValue(members);
    register();

    expect(mockRegisterMentionSources).toHaveBeenCalledTimes(1);
    const [namespace, sources] = mockRegisterMentionSources.mock.calls[0];
    expect(namespace).toBe('system');
    expect(sources).toHaveLength(1);
    await expect(sources[0]()).resolves.toEqual(members);
  });
});

// =============================================================================
// Intervention-policy domains: presented in core's policy panel
// =============================================================================

describe('register() — policy domains', () => {
  beforeEach(() => mockRegisterPolicyDomains.mockReset());

  // The server owns which category is in which domain
  // (System::Governance::PolicyDomainTable, registered with core at boot); this
  // side presents those keys. Every server domain gets a presentation, so no
  // section falls back to a humanised key.
  it('presents every domain the server table declares, once, under the system namespace', () => {
    register();

    expect(mockRegisterPolicyDomains).toHaveBeenCalledTimes(1);
    const [namespace, domains] = mockRegisterPolicyDomains.mock.calls[0];
    expect(namespace).toBe('system');
    const keys = (domains as Array<{ key: string }>).map((d) => d.key);
    expect(new Set(keys).size).toBe(keys.length);
    expect(keys).toEqual(expect.arrayContaining([
      'instance_pool', 'cve', 'topology', 'sdwan', 'container_runtime', 'disk_image', 'gitops',
      'packages', 'architecture', 'storage', 'ingress', 'platform', 'project', 'node_lifecycle',
    ]));
    expect(keys).toHaveLength(14);
  });

  it('opens on Node Lifecycle: presentation order is operator priority, not the server\'s match order', () => {
    register();

    const [, domains] = mockRegisterPolicyDomains.mock.calls[0];
    expect((domains as Array<{ key: string }>)[0].key).toBe('node_lifecycle');
  });
});
