// Unit tests for register.ts
//
// register() is a pure side-effect entry point. It calls:
//   1. featureRegistry.registerRoutes('system', [...])   — 12 routes
//   2. featureRegistry.registerNavSections('system', [...]) — 1 section, 13 items
//   3. registerSystemEntities()                          — cross-reference wiring
//   4. featureRegistry.registerComponentSlots({...})     — drawer views
//
// Strategy: mock the two dependencies so we can assert on exact payloads
// without touching the DOM, React lazy loading, or the entity sub-system.

// =============================================================================
// Mocks
// =============================================================================

const mockRegisterRoutes = jest.fn();
const mockRegisterNavSections = jest.fn();
const mockRegisterComponentSlots = jest.fn();

jest.mock('@/shared/services/featureRegistry', () => ({
  featureRegistry: {
    registerRoutes: (...args: unknown[]) => mockRegisterRoutes(...args),
    registerNavSections: (...args: unknown[]) => mockRegisterNavSections(...args),
    registerComponentSlots: (...args: unknown[]) => mockRegisterComponentSlots(...args),
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
  it('calls registerRoutes, registerNavSections, registerComponentSlots, and registerSystemEntities exactly once each', () => {
    register();

    expect(mockRegisterRoutes).toHaveBeenCalledTimes(1);
    expect(mockRegisterNavSections).toHaveBeenCalledTimes(1);
    expect(mockRegisterComponentSlots).toHaveBeenCalledTimes(1);
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

  it('registers boot_replay and one signals view per filterable kind, and nothing else', () => {
    expect(Object.keys(slots).sort()).toEqual([
      'platform.status.drawer.acme_certificate.signals',
      'platform.status.drawer.node_instance.boot_replay',
      'platform.status.drawer.node_instance.signals',
      'platform.status.drawer.node_module.signals',
    ]);
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
