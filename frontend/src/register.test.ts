// Unit tests for register.ts
//
// register() is a pure side-effect entry point. It calls:
//   1. featureRegistry.registerRoutes('system', [...])   — 30 routes
//   2. featureRegistry.registerNavSections('system', [...]) — 1 section, 13 items
//   3. registerSystemEntities()                          — cross-reference wiring
//
// Strategy: mock the two dependencies so we can assert on exact payloads
// without touching the DOM, React lazy loading, or the entity sub-system.

// =============================================================================
// Mocks
// =============================================================================

const mockRegisterRoutes = jest.fn();
const mockRegisterNavSections = jest.fn();

jest.mock('@/shared/services/featureRegistry', () => ({
  featureRegistry: {
    registerRoutes: (...args: unknown[]) => mockRegisterRoutes(...args),
    registerNavSections: (...args: unknown[]) => mockRegisterNavSections(...args),
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
  it('calls registerRoutes, registerNavSections, and registerSystemEntities exactly once each', () => {
    register();

    expect(mockRegisterRoutes).toHaveBeenCalledTimes(1);
    expect(mockRegisterNavSections).toHaveBeenCalledTimes(1);
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
    expect(mockRegisterSystemEntities).toHaveBeenCalledTimes(2);
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

  it('registers 30 routes in total', () => {
    expect(routes).toHaveLength(30);
  });

  // Primary pages
  it('registers /system (SystemOverviewPage lazy component)', () => {
    const r = routes.find((x) => x.path === '/system');
    expect(r).toBeDefined();
    expect(r!.component).toBeDefined();
    expect(r!.permission).toBeUndefined();
  });

  it('registers /system/overview (SystemOverviewPage)', () => {
    const r = routes.find((x) => x.path === '/system/overview');
    expect(r).toBeDefined();
    expect(r!.component).toBeDefined();
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

  // Permission-gated hub routes
  it('registers /system/federation/* gated on system.peers.read', () => {
    const r = routes.find((x) => x.path === '/system/federation/*');
    expect(r).toBeDefined();
    expect(r!.permission).toBe('system.peers.read');
  });

  it('registers /system/ingress/* gated on system.ingress.read', () => {
    const r = routes.find((x) => x.path === '/system/ingress/*');
    expect(r).toBeDefined();
    expect(r!.permission).toBe('system.ingress.read');
  });

  // Legacy redirect routes — exact list from Phase B.5
  const legacyRedirects: Array<[string, string]> = [
    ['/system/nodes', '/app/system/compute/nodes'],
    ['/system/unclaimed-devices', '/app/system/compute/unclaimed-devices'],
    ['/system/volumes', '/app/system/compute/volumes'],
    ['/system/providers', '/app/system/compute/providers'],
    ['/system/networks', '/app/system/compute/networks'],
    ['/system/templates', '/app/system/catalog/templates'],
    ['/system/modules', '/app/system/catalog/modules'],
    ['/system/puppet-modules', '/app/system/catalog/puppet-modules'],
    ['/system/scripts', '/app/system/catalog/scripts'],
    ['/system/architectures', '/app/system/catalog/architectures'],
    ['/system/platforms', '/app/system/catalog/platforms'],
    ['/system/marketplace', '/app/system/catalog/marketplace'],
    ['/system/fleet', '/app/system/operations/fleet'],
    ['/system/tasks', '/app/system/operations/tasks'],
    ['/system/ci-workers', '/app/system/operations/ci-workers'],
    ['/system/disk-image-webhooks', '/app/system/operations/ci-webhooks'],
  ];

  it(`registers all ${legacyRedirects.length} legacy redirect paths (Phase B.5)`, () => {
    for (const [path] of legacyRedirects) {
      const r = routes.find((x) => x.path === path);
      expect(r).toBeDefined();
    }
  });

  it.each(legacyRedirects)(
    'legacy redirect %s has a component (the LegacyRedirect function)',
    (path) => {
      const r = routes.find((x) => x.path === path);
      expect(r).toBeDefined();
      // Each redirect is a plain ComponentType function, not a lazy wrapper
      expect(typeof r!.component).toBe('function');
    },
  );

  it('legacy redirect components render a Navigate element (redirect behaviour)', () => {
    // Spot-check one redirect: calling the component function should return
    // a React element whose type is Navigate.
    const { Navigate } = jest.requireActual('react-router-dom') as typeof import('react-router-dom');
    const r = routes.find((x) => x.path === '/system/nodes');
    const LegacyRedirect = r!.component as () => React.ReactElement;
    const el = LegacyRedirect();
    // The element type should be Navigate from react-router-dom
    expect(el.type).toBe(Navigate);
    // props.to must be the target path and replace must be true
    expect((el.props as { to: string; replace: boolean }).to).toBe(
      '/app/system/compute/nodes',
    );
    expect((el.props as { to: string; replace: boolean }).replace).toBe(true);
  });

  it('all 16 legacy redirect paths target canonical /app/system/* destinations', () => {
    for (const [path, target] of legacyRedirects) {
      const r = routes.find((x) => x.path === path);
      // The component is a function — call it and inspect the element
      const el = (r!.component as () => React.ReactElement)();
      expect((el.props as { to: string }).to).toBe(target);
    }
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

  it('registers 13 nav items', () => {
    expect(items).toHaveLength(13);
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
    { label: 'Federation',        path: '/app/system/federation',     icon: 'Share2',          order: 9, permission: 'system.peers.read' },
    { label: 'Service Delivery',  path: '/app/system/service-delivery', icon: 'Workflow',      order: 10 },
    { label: 'ACME',              path: '/app/system/acme',           icon: 'KeyRound',        order: 11 },
    { label: 'Ingress',           path: '/app/system/ingress',        icon: 'Globe',           order: 12, permission: 'system.ingress.read' },
    { label: 'My VPN',            path: '/app/system/my-vpn',         icon: 'Smartphone',      order: 13 },
  ];

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

  it('only Federation and Ingress items carry a permission gate', () => {
    const gated = items.filter((i) => i.permission !== undefined);
    expect(gated).toHaveLength(2);
    expect(gated.map((i) => i.label).sort()).toEqual(['Federation', 'Ingress']);
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
