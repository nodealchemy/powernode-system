import { sdwanApi } from './sdwanApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet    = jest.fn();
const mockPost   = jest.fn();
const mockPut    = jest.fn();
const mockPatch  = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get:    (...args: unknown[]) => mockGet(...args),
    post:   (...args: unknown[]) => mockPost(...args),
    put:    (...args: unknown[]) => mockPut(...args),
    patch:  (...args: unknown[]) => mockPatch(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Fixture helpers
// =============================================================================

/** Wrap a payload in the standard API double-envelope. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

/** Paginated envelope — meta sits at the response body root, NOT inside data. */
function paginatedEnvelope<T>(data: T, meta?: Partial<{ current_page: number; per_page: number; total_count: number; total_pages: number; next_page: null; prev_page: null }>) {
  return {
    data: {
      success: true,
      data,
      meta: {
        current_page: 1,
        per_page: 50,
        total_count: 1,
        total_pages: 1,
        next_page: null,
        prev_page: null,
        ...meta,
      },
    },
  };
}

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK = {
  id: 'net-1',
  name: 'prod-mesh',
  slug: 'prod-mesh',
  status: 'active' as const,
  cidr_64: 'fd12:3456::/64',
  peer_count: 2,
  created_at: '2026-01-01T00:00:00Z',
};

const PEER = {
  id: 'peer-1',
  network_id: 'net-1',
  node_instance_id: 'ni-abc',
  assigned_address: 'fd12:3456::1',
  publicly_reachable: true,
  listen_port: 51820,
  status: 'active' as const,
};

const FIREWALL_RULE = {
  id: 'fr-1',
  network_id: 'net-1',
  name: 'allow-ssh',
  priority: 10,
  action: 'accept' as const,
  direction: 'ingress' as const,
  protocol: 'tcp' as const,
  enabled: true,
};

const ACCESS_GRANT = {
  id: 'ag-1',
  network_id: 'net-1',
  user_id: 'usr-1',
  user_email: 'alice@example.com',
  status: 'active' as const,
  tags: [],
  device_count: 0,
};

const USER_DEVICE = {
  id: 'ud-1',
  access_grant_id: 'ag-1',
  label: 'laptop',
  public_key: 'wg-pubkey==',
  assigned_address: 'fd12:3456::a',
  downloadable: true,
};

const FEDERATION_PEER = {
  id: 'fp-1',
  remote_instance_url: 'https://remote.example.com',
  status: 'active' as const,
};

const VIRTUAL_IP = {
  id: 'vip-1',
  network_id: 'net-1',
  name: 'k8s-api',
  cidr: '10.0.1.100/32',
  anycast: false,
  state: 'active' as const,
  holder_peer_ids: ['peer-1'],
  failover_holder_peer_ids: [],
  advertised_med: 100,
  advertised_local_pref: 100,
  tags: [],
};

const ROUTING_OVERVIEW = {
  account_bgp: null,
  summary: {
    total_networks: 2,
    ibgp_networks: 1,
    static_networks: 1,
    established_sessions: 3,
    total_sessions: 4,
  },
};

const ACCOUNT_BGP = {
  id: 'bgp-1',
  as_number: 65001,
  router_id_strategy: 'peer_overlay_ipv6_hash' as const,
  default_local_pref: 100,
  enabled: true,
};

const BGP_SESSION = {
  id: 'sess-1',
  peer_id: 'peer-1',
  network_id: 'net-1',
  neighbor_address: 'fd12:3456::2',
  state: 'established' as const,
  uptime_seconds: 3600,
  prefixes_received: 5,
  prefixes_sent: 3,
};

const ROUTE_POLICY = {
  id: 'rp-1',
  name: 'no-default-export',
  scope: 'account' as const,
  direction: 'export' as const,
  enabled: true,
  statement_count: 1,
  slug: 'no-default-export',
};

const PORT_MAPPING = {
  id: 'pm-1',
  network_id: 'net-1',
  hub_peer_id: 'peer-1',
  name: 'web-http',
  listen_port: 80,
  effective_target_port: 8080,
  protocol: 'tcp' as const,
  enabled: true,
};

const HOST_BRIDGE = {
  id: 'hb-1',
  node_instance_id: 'ni-abc',
  short_id: 1,
  bridge_name: 'br0',
  kind: 'linux' as const,
  state: 'active' as const,
};

const OVN_SUMMARY = {
  id: 'ovn-1',
  status: 'active' as const,
  nb_db_endpoint: 'tcp:192.168.1.10:6641',
  sb_db_endpoint: 'tcp:192.168.1.10:6642',
  switch_count: 2,
  port_count: 4,
};

const OVN_DEPLOYMENT = {
  ...OVN_SUMMARY,
  logical_switches: [],
};

const COMPILED_PLAN = {
  deployment_id: 'ovn-1',
  plan: [],
  compiled_at: '2026-01-01T00:00:00Z',
};

const IPFIX_COLLECTOR = {
  id: 'ic-1',
  name: 'main-collector',
  host: '10.0.0.10',
  port: 4739,
  target_endpoint: '10.0.0.10:4739',
  sampling_rate: 1000,
  state: 'active' as const,
  is_winning_collector: true,
};

const FLOW_SAMPLE = {
  id: 'fs-1',
  src_ip: '10.0.1.1',
  dst_ip: '10.0.1.2',
  src_port: 54321,
  dst_port: 443,
  protocol: 6,
  protocol_label: 'TCP',
  octet_count: 1024,
  packet_count: 10,
  flow_start_at: '2026-01-01T00:00:00Z',
  flow_end_at: '2026-01-01T00:00:01Z',
  observed_at: '2026-01-01T00:00:01Z',
};

// =============================================================================
// Test suite
// =============================================================================

beforeEach(() => {
  mockGet.mockReset();
  mockPost.mockReset();
  mockPut.mockReset();
  mockPatch.mockReset();
  mockDelete.mockReset();
});

// ──── Networks ────────────────────────────────────────────────────────────────

describe('sdwanApi.getNetworks', () => {
  it('GETs /system/sdwan/networks and returns networks + meta', async () => {
    mockGet.mockResolvedValue(
      paginatedEnvelope({ networks: [NETWORK], count: 1 })
    );

    const result = await sdwanApi.getNetworks();

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks', { params: undefined });
    expect(result.networks).toEqual([NETWORK]);
    expect(result.meta.total_count).toBe(1);
  });

  it('passes filter params through to the request', async () => {
    mockGet.mockResolvedValue(paginatedEnvelope({ networks: [], count: 0 }));

    await sdwanApi.getNetworks({ status: 'active', page: 2 });

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks', {
      params: { status: 'active', page: 2 },
    });
  });
});

describe('sdwanApi.getNetwork', () => {
  it('GETs a single network by id', async () => {
    mockGet.mockResolvedValue(envelope({ network: NETWORK }));

    const result = await sdwanApi.getNetwork('net-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks/net-1');
    expect(result).toEqual(NETWORK);
  });
});

describe('sdwanApi.createNetwork', () => {
  it('POSTs with the network wrapper and returns the created network', async () => {
    mockPost.mockResolvedValue(envelope({ network: NETWORK }));

    const result = await sdwanApi.createNetwork({ name: 'prod-mesh' });

    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/networks', {
      network: { name: 'prod-mesh' },
    });
    expect(result).toEqual(NETWORK);
  });

  it('includes optional fields when provided', async () => {
    mockPost.mockResolvedValue(envelope({ network: NETWORK }));

    await sdwanApi.createNetwork({
      name: 'prod-mesh',
      description: 'Production',
      tags: ['prod'],
      settings: { mtu: 1420 },
    });

    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/networks', {
      network: {
        name: 'prod-mesh',
        description: 'Production',
        tags: ['prod'],
        settings: { mtu: 1420 },
      },
    });
  });
});

describe('sdwanApi.updateNetwork', () => {
  it('PUTs with the network wrapper and returns the updated network', async () => {
    const updated = { ...NETWORK, status: 'suspended' as const };
    mockPut.mockResolvedValue(envelope({ network: updated }));

    const result = await sdwanApi.updateNetwork('net-1', { status: 'suspended' });

    expect(mockPut).toHaveBeenCalledWith('/system/sdwan/networks/net-1', {
      network: { status: 'suspended' },
    });
    expect(result.status).toBe('suspended');
  });
});

describe('sdwanApi.deleteNetwork', () => {
  it('DELETEs the network by id', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deleteNetwork('net-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/networks/net-1');
  });
});

describe('sdwanApi.getTopology', () => {
  it('GETs the topology for a network', async () => {
    const topo = {
      network_id: 'net-1',
      cidr_64: 'fd12:3456::/64',
      peer_count: 1,
      peers: [],
    };
    mockGet.mockResolvedValue(envelope(topo));

    const result = await sdwanApi.getTopology('net-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks/net-1/topology');
    expect(result.network_id).toBe('net-1');
  });
});

// ──── Peers ───────────────────────────────────────────────────────────────────

describe('sdwanApi.getPeers', () => {
  it('GETs peers for a network', async () => {
    mockGet.mockResolvedValue(envelope({ peers: [PEER], count: 1 }));

    const result = await sdwanApi.getPeers('net-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks/net-1/peers');
    expect(result.peers).toEqual([PEER]);
  });

  it('returns empty array when peers key is missing', async () => {
    mockGet.mockResolvedValue(envelope({ count: 0 }));

    const result = await sdwanApi.getPeers('net-1');

    expect(result.peers).toEqual([]);
  });
});

describe('sdwanApi.attachPeer', () => {
  it('POSTs with the peer wrapper and returns the created peer', async () => {
    mockPost.mockResolvedValue(envelope({ peer: PEER }));

    const result = await sdwanApi.attachPeer('net-1', {
      node_instance_id: 'ni-abc',
      publicly_reachable: true,
      endpoint_host_v6: '2001:db8::1',
      endpoint_port: 51820,
      lan_subnets: ['192.168.10.0/24'],
    });

    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/networks/net-1/peers', {
      peer: {
        node_instance_id: 'ni-abc',
        publicly_reachable: true,
        endpoint_host_v6: '2001:db8::1',
        endpoint_port: 51820,
        lan_subnets: ['192.168.10.0/24'],
      },
    });
    expect(result).toEqual(PEER);
  });
});

describe('sdwanApi.detachPeer', () => {
  it('DELETEs a peer from a network', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.detachPeer('net-1', 'peer-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/networks/net-1/peers/peer-1');
  });
});

// ──── Firewall Rules ─────────────────────────────────────────────────────────

describe('sdwanApi.getFirewallRules', () => {
  it('GETs firewall rules and maps them to the result shape', async () => {
    mockGet.mockResolvedValue(
      envelope({ firewall_rules: [FIREWALL_RULE], count: 1, network_default_policy: 'drop' })
    );

    const result = await sdwanApi.getFirewallRules('net-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks/net-1/firewall_rules');
    expect(result.rules).toEqual([FIREWALL_RULE]);
    expect(result.defaultPolicy).toBe('drop');
  });

  it('returns empty rules array when firewall_rules key is missing', async () => {
    mockGet.mockResolvedValue(
      envelope({ count: 0, network_default_policy: 'accept' })
    );

    const result = await sdwanApi.getFirewallRules('net-1');

    expect(result.rules).toEqual([]);
  });
});

describe('sdwanApi.createFirewallRule', () => {
  it('POSTs with the firewall_rule wrapper', async () => {
    mockPost.mockResolvedValue(envelope({ firewall_rule: FIREWALL_RULE }));

    const result = await sdwanApi.createFirewallRule('net-1', {
      name: 'allow-ssh',
      action: 'accept',
      direction: 'ingress',
      protocol: 'tcp',
      priority: 10,
      enabled: true,
    });

    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/networks/net-1/firewall_rules', {
      firewall_rule: {
        name: 'allow-ssh',
        action: 'accept',
        direction: 'ingress',
        protocol: 'tcp',
        priority: 10,
        enabled: true,
      },
    });
    expect(result).toEqual(FIREWALL_RULE);
  });
});

describe('sdwanApi.updateFirewallRule', () => {
  it('PUTs with the firewall_rule wrapper', async () => {
    const updated = { ...FIREWALL_RULE, enabled: false };
    mockPut.mockResolvedValue(envelope({ firewall_rule: updated }));

    const result = await sdwanApi.updateFirewallRule('net-1', 'fr-1', { enabled: false });

    expect(mockPut).toHaveBeenCalledWith('/system/sdwan/networks/net-1/firewall_rules/fr-1', {
      firewall_rule: { enabled: false },
    });
    expect(result.enabled).toBe(false);
  });
});

describe('sdwanApi.deleteFirewallRule', () => {
  it('DELETEs a firewall rule', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deleteFirewallRule('net-1', 'fr-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/networks/net-1/firewall_rules/fr-1');
  });
});

// ──── Access Grants ──────────────────────────────────────────────────────────

describe('sdwanApi.getAccessGrants', () => {
  it('GETs access grants for a network', async () => {
    mockGet.mockResolvedValue(envelope({ access_grants: [ACCESS_GRANT], count: 1 }));

    const result = await sdwanApi.getAccessGrants('net-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks/net-1/access_grants');
    expect(result.grants).toEqual([ACCESS_GRANT]);
  });

  it('returns empty grants when access_grants key is missing', async () => {
    mockGet.mockResolvedValue(envelope({ count: 0 }));

    const result = await sdwanApi.getAccessGrants('net-1');

    expect(result.grants).toEqual([]);
  });
});

describe('sdwanApi.createAccessGrant', () => {
  it('POSTs with the access_grant wrapper', async () => {
    mockPost.mockResolvedValue(envelope({ access_grant: ACCESS_GRANT }));

    const result = await sdwanApi.createAccessGrant('net-1', {
      user_id: 'usr-1',
      tags: ['vpn'],
    });

    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/networks/net-1/access_grants', {
      access_grant: { user_id: 'usr-1', tags: ['vpn'] },
    });
    expect(result).toEqual(ACCESS_GRANT);
  });
});

describe('sdwanApi.updateAccessGrant', () => {
  // Tags only: status is reachable solely through the approval-gated
  // revoke/delete verbs, so the server stopped permitting it on this route.
  it('PUTs with the access_grant wrapper', async () => {
    const updated = { ...ACCESS_GRANT, tags: ['contractor'] };
    mockPut.mockResolvedValue(envelope({ access_grant: updated }));

    const result = await sdwanApi.updateAccessGrant('net-1', 'ag-1', { tags: ['contractor'] });

    expect(mockPut).toHaveBeenCalledWith('/system/sdwan/networks/net-1/access_grants/ag-1', {
      access_grant: { tags: ['contractor'] },
    });
    expect(result.tags).toEqual(['contractor']);
  });
});

describe('sdwanApi.revokeAccessGrant', () => {
  it('POSTs to the revoke sub-action with reason', async () => {
    const revoked = { ...ACCESS_GRANT, status: 'revoked' as const };
    mockPost.mockResolvedValue(envelope({ access_grant: revoked }));

    const result = await sdwanApi.revokeAccessGrant('net-1', 'ag-1', 'policy violation');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/sdwan/networks/net-1/access_grants/ag-1/revoke',
      { reason: 'policy violation' }
    );
    expect(result.status).toBe('revoked');
  });

  it('posts without reason when omitted', async () => {
    mockPost.mockResolvedValue(envelope({ access_grant: ACCESS_GRANT }));

    await sdwanApi.revokeAccessGrant('net-1', 'ag-1');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/sdwan/networks/net-1/access_grants/ag-1/revoke',
      { reason: undefined }
    );
  });
});

describe('sdwanApi.deleteAccessGrant', () => {
  it('DELETEs an access grant', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deleteAccessGrant('net-1', 'ag-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/networks/net-1/access_grants/ag-1');
  });
});

// ──── User Devices ───────────────────────────────────────────────────────────

describe('sdwanApi.getUserDevices', () => {
  it('GETs user devices for an access grant', async () => {
    mockGet.mockResolvedValue(envelope({ user_devices: [USER_DEVICE], count: 1 }));

    const result = await sdwanApi.getUserDevices('net-1', 'ag-1');

    expect(mockGet).toHaveBeenCalledWith(
      '/system/sdwan/networks/net-1/access_grants/ag-1/user_devices'
    );
    expect(result.devices).toEqual([USER_DEVICE]);
  });

  it('returns empty devices when user_devices key is missing', async () => {
    mockGet.mockResolvedValue(envelope({ count: 0 }));

    const result = await sdwanApi.getUserDevices('net-1', 'ag-1');

    expect(result.devices).toEqual([]);
  });
});

describe('sdwanApi.issueUserDevice', () => {
  it('POSTs with the user_device wrapper and returns the issue response', async () => {
    const issueResponse = {
      user_device: USER_DEVICE,
      bootstrap: { token: 'tok', url: 'https://...', expires_at: '2026-01-02T00:00:00Z' },
    };
    mockPost.mockResolvedValue(envelope(issueResponse));

    const result = await sdwanApi.issueUserDevice('net-1', 'ag-1', { label: 'laptop' });

    expect(mockPost).toHaveBeenCalledWith(
      '/system/sdwan/networks/net-1/access_grants/ag-1/user_devices',
      { user_device: { label: 'laptop' } }
    );
    expect(result.user_device).toEqual(USER_DEVICE);
    expect(result.bootstrap.token).toBe('tok');
  });
});

describe('sdwanApi.revokeUserDevice', () => {
  it('POSTs to the revoke sub-action', async () => {
    const revoked = { ...USER_DEVICE, revoked_at: '2026-01-01T12:00:00Z' };
    mockPost.mockResolvedValue(envelope({ user_device: revoked }));

    const result = await sdwanApi.revokeUserDevice('net-1', 'ag-1', 'ud-1', 'lost device');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/sdwan/networks/net-1/access_grants/ag-1/user_devices/ud-1/revoke',
      { reason: 'lost device' }
    );
    expect(result.revoked_at).toBe('2026-01-01T12:00:00Z');
  });
});

describe('sdwanApi.deleteUserDevice', () => {
  it('DELETEs a user device', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deleteUserDevice('net-1', 'ag-1', 'ud-1');

    expect(mockDelete).toHaveBeenCalledWith(
      '/system/sdwan/networks/net-1/access_grants/ag-1/user_devices/ud-1'
    );
  });
});

// ──── Federation Peers ───────────────────────────────────────────────────────

describe('sdwanApi.getFederationPeers', () => {
  it('GETs all federation peers', async () => {
    mockGet.mockResolvedValue(envelope({ federation_peers: [FEDERATION_PEER], count: 1 }));

    const result = await sdwanApi.getFederationPeers();

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/federation_peers');
    expect(result.peers).toEqual([FEDERATION_PEER]);
  });

  it('returns empty peers when federation_peers key is missing', async () => {
    mockGet.mockResolvedValue(envelope({ count: 0 }));

    const result = await sdwanApi.getFederationPeers();

    expect(result.peers).toEqual([]);
  });
});

describe('sdwanApi.getFederationPeer', () => {
  it('GETs a single federation peer by id', async () => {
    mockGet.mockResolvedValue(envelope({ federation_peer: FEDERATION_PEER }));

    const result = await sdwanApi.getFederationPeer('fp-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/federation_peers/fp-1');
    expect(result).toEqual(FEDERATION_PEER);
  });
});

describe('sdwanApi.proposeFederationPeer', () => {
  it('POSTs with the federation_peer wrapper', async () => {
    mockPost.mockResolvedValue(envelope({ federation_peer: FEDERATION_PEER }));

    const result = await sdwanApi.proposeFederationPeer({
      remote_instance_url: 'https://remote.example.com',
      remote_instance_id: 'ri-1',
      remote_account_id: 'ra-1',
      remote_prefix_advertisement: '10.10.0.0/16',
    });

    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/federation_peers', {
      federation_peer: {
        remote_instance_url: 'https://remote.example.com',
        remote_instance_id: 'ri-1',
        remote_account_id: 'ra-1',
        remote_prefix_advertisement: '10.10.0.0/16',
      },
    });
    expect(result).toEqual(FEDERATION_PEER);
  });
});

describe('sdwanApi.revokeFederationPeer', () => {
  it('POSTs to the revoke sub-action', async () => {
    const revoked = { ...FEDERATION_PEER, status: 'revoked' as const };
    mockPost.mockResolvedValue(envelope({ federation_peer: revoked }));

    const result = await sdwanApi.revokeFederationPeer('fp-1', 'security breach');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/sdwan/federation_peers/fp-1/revoke',
      { reason: 'security breach' }
    );
    expect(result.status).toBe('revoked');
  });
});

describe('sdwanApi.deleteFederationPeer', () => {
  it('DELETEs a federation peer', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deleteFederationPeer('fp-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/federation_peers/fp-1');
  });
});

// ──── Virtual IPs ─────────────────────────────────────────────────────────────

describe('sdwanApi.listVirtualIps', () => {
  it('GETs virtual IPs for a network', async () => {
    mockGet.mockResolvedValue(envelope({ virtual_ips: [VIRTUAL_IP], count: 1 }));

    const result = await sdwanApi.listVirtualIps('net-1');

    // No filters → no query string appended
    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks/net-1/virtual_ips');
    expect(result.virtual_ips).toEqual([VIRTUAL_IP]);
    expect(result.count).toBe(1);
  });

  it('appends state filter as a query param', async () => {
    mockGet.mockResolvedValue(envelope({ virtual_ips: [], count: 0 }));

    await sdwanApi.listVirtualIps('net-1', { state: 'active' });

    expect(mockGet).toHaveBeenCalledWith(
      '/system/sdwan/networks/net-1/virtual_ips?state=active'
    );
  });

  it('returns empty array and zero count when virtual_ips key is missing', async () => {
    mockGet.mockResolvedValue(envelope({ count: 0 }));

    const result = await sdwanApi.listVirtualIps('net-1');

    expect(result.virtual_ips).toEqual([]);
    expect(result.count).toBe(0);
  });
});

describe('sdwanApi.getVirtualIp', () => {
  it('GETs a single virtual IP', async () => {
    mockGet.mockResolvedValue(envelope({ virtual_ip: VIRTUAL_IP }));

    const result = await sdwanApi.getVirtualIp('net-1', 'vip-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks/net-1/virtual_ips/vip-1');
    expect(result).toEqual(VIRTUAL_IP);
  });
});

describe('sdwanApi.createVirtualIp', () => {
  it('POSTs with the virtual_ip wrapper', async () => {
    mockPost.mockResolvedValue(envelope({ virtual_ip: VIRTUAL_IP }));

    const result = await sdwanApi.createVirtualIp('net-1', {
      name: 'k8s-api',
      cidr: '10.0.1.100/32',
      holder_peer_ids: ['peer-1'],
    });

    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/networks/net-1/virtual_ips', {
      virtual_ip: { name: 'k8s-api', cidr: '10.0.1.100/32', holder_peer_ids: ['peer-1'] },
    });
    expect(result).toEqual(VIRTUAL_IP);
  });
});

describe('sdwanApi.updateVirtualIp', () => {
  it('PATCHes with the virtual_ip wrapper', async () => {
    const updated = { ...VIRTUAL_IP, state: 'pending' as const };
    mockPatch.mockResolvedValue(envelope({ virtual_ip: updated }));

    const result = await sdwanApi.updateVirtualIp('net-1', 'vip-1', { state: 'pending' });

    expect(mockPatch).toHaveBeenCalledWith('/system/sdwan/networks/net-1/virtual_ips/vip-1', {
      virtual_ip: { state: 'pending' },
    });
    expect(result.state).toBe('pending');
  });
});

describe('sdwanApi.deleteVirtualIp', () => {
  it('DELETEs a virtual IP', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deleteVirtualIp('net-1', 'vip-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/networks/net-1/virtual_ips/vip-1');
  });
});

describe('sdwanApi.failoverVirtualIp', () => {
  it('POSTs to the failover sub-action with an empty body', async () => {
    const failingOver = { ...VIRTUAL_IP, state: 'failing_over' as const };
    mockPost.mockResolvedValue(envelope({ virtual_ip: failingOver }));

    const result = await sdwanApi.failoverVirtualIp('net-1', 'vip-1');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/sdwan/networks/net-1/virtual_ips/vip-1/failover',
      {}
    );
    expect(result.state).toBe('failing_over');
  });
});

// ──── Routing (BGP control plane) ────────────────────────────────────────────

describe('sdwanApi.getRoutingOverview', () => {
  it('GETs the routing overview', async () => {
    mockGet.mockResolvedValue(envelope(ROUTING_OVERVIEW));

    const result = await sdwanApi.getRoutingOverview();

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/routing');
    expect(result.summary.total_networks).toBe(2);
  });
});

describe('sdwanApi.allocateAccountAs', () => {
  it('POSTs to /routing/bgp with an empty body', async () => {
    mockPost.mockResolvedValue(envelope({ account_bgp: ACCOUNT_BGP, allocated: true }));

    const result = await sdwanApi.allocateAccountAs();

    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/routing/bgp', {});
    expect(result.allocated).toBe(true);
    expect(result.account_bgp).toEqual(ACCOUNT_BGP);
  });
});

describe('sdwanApi.getBgpSessions', () => {
  it('GETs BGP sessions without filters', async () => {
    mockGet.mockResolvedValue(envelope({ sessions: [BGP_SESSION], count: 1 }));

    const result = await sdwanApi.getBgpSessions();

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/routing/sessions');
    expect(result.sessions).toEqual([BGP_SESSION]);
    expect(result.count).toBe(1);
  });

  it('appends network_id and state filters as query params', async () => {
    mockGet.mockResolvedValue(envelope({ sessions: [], count: 0 }));

    await sdwanApi.getBgpSessions({ network_id: 'net-1', state: 'established' });

    expect(mockGet).toHaveBeenCalledWith(
      '/system/sdwan/routing/sessions?network_id=net-1&state=established'
    );
  });

  it('returns empty sessions when sessions key is missing', async () => {
    mockGet.mockResolvedValue(envelope({ count: 0 }));

    const result = await sdwanApi.getBgpSessions();

    expect(result.sessions).toEqual([]);
    expect(result.count).toBe(0);
  });
});

// ──── Route Policies ─────────────────────────────────────────────────────────

describe('sdwanApi.listRoutePolicies', () => {
  it('GETs route policies without filters', async () => {
    mockGet.mockResolvedValue(envelope({ route_policies: [ROUTE_POLICY], count: 1 }));

    const result = await sdwanApi.listRoutePolicies();

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/route_policies');
    expect(result.route_policies).toEqual([ROUTE_POLICY]);
    expect(result.count).toBe(1);
  });

  it('appends scope and direction filters', async () => {
    mockGet.mockResolvedValue(envelope({ route_policies: [], count: 0 }));

    await sdwanApi.listRoutePolicies({ scope: 'account', direction: 'export' });

    expect(mockGet).toHaveBeenCalledWith(
      '/system/sdwan/route_policies?scope=account&direction=export'
    );
  });

  it('returns empty route_policies when key is missing', async () => {
    mockGet.mockResolvedValue(envelope({ count: 0 }));

    const result = await sdwanApi.listRoutePolicies();

    expect(result.route_policies).toEqual([]);
  });
});

describe('sdwanApi.getRoutePolicy', () => {
  it('GETs a single route policy', async () => {
    mockGet.mockResolvedValue(envelope({ route_policy: ROUTE_POLICY }));

    const result = await sdwanApi.getRoutePolicy('rp-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/route_policies/rp-1');
    expect(result).toEqual(ROUTE_POLICY);
  });
});

describe('sdwanApi.createRoutePolicy', () => {
  it('POSTs with the route_policy wrapper', async () => {
    mockPost.mockResolvedValue(envelope({ route_policy: ROUTE_POLICY }));

    const result = await sdwanApi.createRoutePolicy({
      name: 'no-default-export',
      scope: 'account',
      direction: 'export',
      statements: [],
    });

    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/route_policies', {
      route_policy: {
        name: 'no-default-export',
        scope: 'account',
        direction: 'export',
        statements: [],
      },
    });
    expect(result).toEqual(ROUTE_POLICY);
  });
});

describe('sdwanApi.updateRoutePolicy', () => {
  it('PATCHes with the route_policy wrapper', async () => {
    const updated = { ...ROUTE_POLICY, enabled: false };
    mockPatch.mockResolvedValue(envelope({ route_policy: updated }));

    const result = await sdwanApi.updateRoutePolicy('rp-1', { enabled: false });

    expect(mockPatch).toHaveBeenCalledWith('/system/sdwan/route_policies/rp-1', {
      route_policy: { enabled: false },
    });
    expect(result.enabled).toBe(false);
  });
});

describe('sdwanApi.deleteRoutePolicy', () => {
  it('DELETEs a route policy', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deleteRoutePolicy('rp-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/route_policies/rp-1');
  });
});

describe('sdwanApi.compileRoutePolicy', () => {
  it('GETs the compiled route policy for a peer', async () => {
    const compiled = {
      prefix_lists: ['pl-export'],
      ipv6_prefix_lists: [],
      as_path_lists: [],
      community_lists: [],
      route_maps: ['rm-export'],
    };
    mockGet.mockResolvedValue(envelope({ compiled }));

    const result = await sdwanApi.compileRoutePolicy('rp-1', 'peer-1');

    expect(mockGet).toHaveBeenCalledWith(
      '/system/sdwan/route_policies/rp-1/compile?peer_id=peer-1'
    );
    expect(result.compiled).toEqual(compiled);
  });
});

// ──── Port Mappings ───────────────────────────────────────────────────────────

describe('sdwanApi.listPortMappings', () => {
  it('GETs port mappings for a network', async () => {
    mockGet.mockResolvedValue(envelope({ port_mappings: [PORT_MAPPING], count: 1 }));

    const result = await sdwanApi.listPortMappings('net-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks/net-1/port_mappings');
    expect(result.port_mappings).toEqual([PORT_MAPPING]);
  });

  it('appends hub_peer_id filter', async () => {
    mockGet.mockResolvedValue(envelope({ port_mappings: [], count: 0 }));

    await sdwanApi.listPortMappings('net-1', { hub_peer_id: 'peer-1' });

    expect(mockGet).toHaveBeenCalledWith(
      '/system/sdwan/networks/net-1/port_mappings?hub_peer_id=peer-1'
    );
  });

  it('appends enabled=false filter', async () => {
    mockGet.mockResolvedValue(envelope({ port_mappings: [], count: 0 }));

    await sdwanApi.listPortMappings('net-1', { enabled: false });

    expect(mockGet).toHaveBeenCalledWith(
      '/system/sdwan/networks/net-1/port_mappings?enabled=false'
    );
  });

  it('returns empty port_mappings when key is missing', async () => {
    mockGet.mockResolvedValue(envelope({ count: 0 }));

    const result = await sdwanApi.listPortMappings('net-1');

    expect(result.port_mappings).toEqual([]);
  });
});

describe('sdwanApi.getPortMapping', () => {
  it('GETs a single port mapping', async () => {
    mockGet.mockResolvedValue(envelope({ port_mapping: PORT_MAPPING }));

    const result = await sdwanApi.getPortMapping('net-1', 'pm-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/networks/net-1/port_mappings/pm-1');
    expect(result).toEqual(PORT_MAPPING);
  });
});

describe('sdwanApi.createPortMapping', () => {
  it('POSTs with the port_mapping wrapper', async () => {
    mockPost.mockResolvedValue(envelope({ port_mapping: PORT_MAPPING }));

    const result = await sdwanApi.createPortMapping('net-1', {
      name: 'web-http',
      sdwan_peer_id: 'peer-1',
      listen_port: 80,
      protocol: 'tcp',
      target_port: 8080,
    });

    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/networks/net-1/port_mappings', {
      port_mapping: {
        name: 'web-http',
        sdwan_peer_id: 'peer-1',
        listen_port: 80,
        protocol: 'tcp',
        target_port: 8080,
      },
    });
    expect(result).toEqual(PORT_MAPPING);
  });
});

describe('sdwanApi.updatePortMapping', () => {
  it('PATCHes with the port_mapping wrapper', async () => {
    const updated = { ...PORT_MAPPING, enabled: false };
    mockPatch.mockResolvedValue(envelope({ port_mapping: updated }));

    const result = await sdwanApi.updatePortMapping('net-1', 'pm-1', { enabled: false });

    expect(mockPatch).toHaveBeenCalledWith('/system/sdwan/networks/net-1/port_mappings/pm-1', {
      port_mapping: { enabled: false },
    });
    expect(result.enabled).toBe(false);
  });
});

describe('sdwanApi.deletePortMapping', () => {
  it('DELETEs a port mapping', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deletePortMapping('net-1', 'pm-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/networks/net-1/port_mappings/pm-1');
  });
});

// ──── Federation scan (server scanner, single source of truth) ──────────────

describe('sdwanApi.scanFederation', () => {
  // The scan used to re-fetch /federation_peers and re-derive two of the
  // server scanner's ~13 finding kinds in TypeScript, so the console reported
  // "no findings" for the other eleven. It now calls the server scanner's REST
  // endpoint — the same Sdwan::FederationGovernance.scan behind MCP's
  // system_sdwan_federation_scan (IMP-65f479ad8484).
  it('calls the server governance scan endpoint, not the peers list', async () => {
    mockGet.mockResolvedValue(
      envelope({ findings: [], finding_count: 0, severity_summary: {} })
    );

    await sdwanApi.scanFederation();

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/federation_governance/scan');
    expect(mockGet).not.toHaveBeenCalledWith('/system/sdwan/federation_peers');
  });

  it('passes the server findings through verbatim, including kinds no client check could derive', async () => {
    const findings = [
      {
        kind: 'prefix_overlap_with_install',
        severity: 'critical',
        federation_peer_id: 'fp-1',
        message: 'overlaps with this install',
        payload: { account_id: 'acct-1', status: 'proposed' },
      },
      {
        kind: 'migration_chain_failed',
        severity: 'high',
        federation_peer_id: null,
        message: 'chain failed',
        payload: { migration_chain_id: 'mc-1' },
      },
    ];
    mockGet.mockResolvedValue(
      envelope({ findings, finding_count: 2, severity_summary: { critical: 1, high: 1 } })
    );

    const result = await sdwanApi.scanFederation();

    expect(result.findings).toEqual(findings);
    expect(result.finding_count).toBe(2);
    expect(result.severity_summary).toEqual({ critical: 1, high: 1 });
  });

  it('defaults to an empty result when the envelope omits the keys', async () => {
    mockGet.mockResolvedValue(envelope({}));

    const result = await sdwanApi.scanFederation();

    expect(result.findings).toEqual([]);
    expect(result.finding_count).toBe(0);
    expect(result.severity_summary).toEqual({});
  });
});

// ──── Host Bridges ────────────────────────────────────────────────────────────

describe('sdwanApi.getHostBridges', () => {
  it('GETs host bridges without filters', async () => {
    mockGet.mockResolvedValue(envelope({ host_bridges: [HOST_BRIDGE] }));

    const result = await sdwanApi.getHostBridges();

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/host_bridges', { params: undefined });
    expect(result).toEqual([HOST_BRIDGE]);
  });

  it('passes filters as params', async () => {
    mockGet.mockResolvedValue(envelope({ host_bridges: [] }));

    await sdwanApi.getHostBridges({ node_instance_id: 'ni-abc', state: 'active' });

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/host_bridges', {
      params: { node_instance_id: 'ni-abc', state: 'active' },
    });
  });
});

describe('sdwanApi.getHostBridge', () => {
  it('GETs a single host bridge', async () => {
    mockGet.mockResolvedValue(envelope({ host_bridge: HOST_BRIDGE }));

    const result = await sdwanApi.getHostBridge('hb-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/host_bridges/hb-1');
    expect(result).toEqual(HOST_BRIDGE);
  });
});

describe('sdwanApi.deleteHostBridge', () => {
  // The absence of a force param is load-bearing, not incidental: the server
  // defaults to DRAINING, and sending force: false would be indistinguishable
  // from the default while sending force: true would silently restore the
  // pre-IMP-53a5c597ec8c hard release this call used to perform.
  it('DELETEs a host bridge without a force param, so the server default (drain) applies', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deleteHostBridge('hb-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/host_bridges/hb-1', undefined);
  });

  it('sends force when the caller explicitly opts into a hard release', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deleteHostBridge('hb-1', { force: true });

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/host_bridges/hb-1', {
      params: { force: true },
    });
  });
});

// ──── OVN Deployments ────────────────────────────────────────────────────────

describe('sdwanApi.getOvnDeployments', () => {
  it('GETs all OVN deployment summaries', async () => {
    mockGet.mockResolvedValue(envelope({ ovn_deployments: [OVN_SUMMARY] }));

    const result = await sdwanApi.getOvnDeployments();

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/ovn_deployments');
    expect(result).toEqual([OVN_SUMMARY]);
  });
});

describe('sdwanApi.getOvnDeployment', () => {
  it('GETs a single OVN deployment with compiled plan', async () => {
    mockGet.mockResolvedValue(
      envelope({ ovn_deployment: OVN_DEPLOYMENT, compiled_plan: COMPILED_PLAN })
    );

    const result = await sdwanApi.getOvnDeployment('ovn-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/ovn_deployments/ovn-1');
    expect(result.deployment).toEqual(OVN_DEPLOYMENT);
    expect(result.compiled_plan).toEqual(COMPILED_PLAN);
  });
});

// ──── IPFIX Collectors ────────────────────────────────────────────────────────

describe('sdwanApi.getIpfixCollectors', () => {
  it('GETs IPFIX collectors without filters', async () => {
    mockGet.mockResolvedValue(envelope({ ipfix_collectors: [IPFIX_COLLECTOR] }));

    const result = await sdwanApi.getIpfixCollectors();

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/ipfix_collectors', { params: undefined });
    expect(result).toEqual([IPFIX_COLLECTOR]);
  });

  it('passes state filter as params', async () => {
    mockGet.mockResolvedValue(envelope({ ipfix_collectors: [] }));

    await sdwanApi.getIpfixCollectors({ state: 'active' });

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/ipfix_collectors', {
      params: { state: 'active' },
    });
  });
});

describe('sdwanApi.getIpfixCollector', () => {
  it('GETs a single IPFIX collector', async () => {
    mockGet.mockResolvedValue(envelope({ ipfix_collector: IPFIX_COLLECTOR }));

    const result = await sdwanApi.getIpfixCollector('ic-1');

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/ipfix_collectors/ic-1');
    expect(result).toEqual(IPFIX_COLLECTOR);
  });
});

describe('sdwanApi.setIpfixCollectorState', () => {
  it('PATCHes the collector state to active', async () => {
    const updated = { ...IPFIX_COLLECTOR, state: 'active' as const };
    mockPatch.mockResolvedValue(envelope({ ipfix_collector: updated }));

    const result = await sdwanApi.setIpfixCollectorState('ic-1', 'active');

    expect(mockPatch).toHaveBeenCalledWith('/system/sdwan/ipfix_collectors/ic-1', {
      ipfix_collector: { state: 'active' },
    });
    expect(result.state).toBe('active');
  });

  it('PATCHes the collector state to disabled', async () => {
    const updated = { ...IPFIX_COLLECTOR, state: 'disabled' as const };
    mockPatch.mockResolvedValue(envelope({ ipfix_collector: updated }));

    const result = await sdwanApi.setIpfixCollectorState('ic-1', 'disabled');

    expect(mockPatch).toHaveBeenCalledWith('/system/sdwan/ipfix_collectors/ic-1', {
      ipfix_collector: { state: 'disabled' },
    });
    expect(result.state).toBe('disabled');
  });
});

describe('sdwanApi.deleteIpfixCollector', () => {
  it('DELETEs an IPFIX collector', async () => {
    mockDelete.mockResolvedValue({ data: { success: true } });

    await sdwanApi.deleteIpfixCollector('ic-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/sdwan/ipfix_collectors/ic-1');
  });
});

// ──── Flow Samples ────────────────────────────────────────────────────────────

describe('sdwanApi.getFlowSamples', () => {
  it('GETs flow samples for a collector', async () => {
    mockGet.mockResolvedValue(envelope({ flow_samples: [FLOW_SAMPLE], count: 1 }));

    const result = await sdwanApi.getFlowSamples('ic-1');

    expect(mockGet).toHaveBeenCalledWith(
      '/system/sdwan/ipfix_collectors/ic-1/flow_samples',
      { params: undefined }
    );
    expect(result.samples).toEqual([FLOW_SAMPLE]);
    expect(result.count).toBe(1);
  });

  it('passes since/until/protocol/limit filters', async () => {
    mockGet.mockResolvedValue(envelope({ flow_samples: [], count: 0 }));

    await sdwanApi.getFlowSamples('ic-1', {
      since: '2026-01-01T00:00:00Z',
      until: '2026-01-02T00:00:00Z',
      protocol: 6,
      limit: 100,
    });

    expect(mockGet).toHaveBeenCalledWith(
      '/system/sdwan/ipfix_collectors/ic-1/flow_samples',
      {
        params: {
          since: '2026-01-01T00:00:00Z',
          until: '2026-01-02T00:00:00Z',
          protocol: 6,
          limit: 100,
        },
      }
    );
  });
});

// ──── Gated mutations: 202 pending-approval passthrough (IMP-87ec6f651f07) ────
//
// Gated SDWAN verbs answer 202 with `{pending: true, deferred_operation_id,
// action_category, approval_request_id, message}` inside the standard envelope
// (core `render_pending_approval`). The API layer must surface that marker to
// callers instead of silently returning `undefined` (resource extraction) or
// discarding the body (deletes) — otherwise the UI toasts "saved"/"deleted"
// for an operation that is actually parked awaiting approval.

describe('gated mutations surface the 202 pending-approval marker', () => {
  const PENDING = {
    pending: true,
    deferred_operation_id: 'dop-1',
    action_category: 'sdwan.port_mapping_create',
    approval_request_id: 'ar-1',
    message: 'Approval required: sdwan.port_mapping_create',
  };

  const pendingEnvelope = (action_category: string) => ({
    status: 202,
    data: { success: true, data: { ...PENDING, action_category } },
  });

  it('createPortMapping returns the pending marker on 202', async () => {
    mockPost.mockResolvedValue(pendingEnvelope('sdwan.port_mapping_create'));

    const result = await sdwanApi.createPortMapping('net-1', {
      name: 'web-http', sdwan_peer_id: 'peer-1', listen_port: 80, protocol: 'tcp',
    });

    expect(result).toMatchObject({ pending: true, approval_request_id: 'ar-1' });
  });

  it('updatePortMapping returns the pending marker on 202', async () => {
    mockPatch.mockResolvedValue(pendingEnvelope('sdwan.port_mapping_update'));

    const result = await sdwanApi.updatePortMapping('net-1', 'pm-1', { enabled: false });

    expect(result).toMatchObject({ pending: true, deferred_operation_id: 'dop-1' });
  });

  it('deletePortMapping returns the pending marker on 202 instead of discarding the body', async () => {
    mockDelete.mockResolvedValue(pendingEnvelope('sdwan.port_mapping_delete'));

    const result = await sdwanApi.deletePortMapping('net-1', 'pm-1');

    expect(result).toMatchObject({ pending: true, approval_request_id: 'ar-1' });
  });

  it('deleteNetwork returns the pending marker on 202', async () => {
    mockDelete.mockResolvedValue(pendingEnvelope('sdwan.network_delete'));

    const result = await sdwanApi.deleteNetwork('net-1');

    expect(result).toMatchObject({ pending: true });
  });

  it('updateNetwork returns the pending marker on 202', async () => {
    mockPut.mockResolvedValue(pendingEnvelope('sdwan.network_update'));

    const result = await sdwanApi.updateNetwork('net-1', { name: 'renamed' });

    expect(result).toMatchObject({ pending: true });
  });

  it('createVirtualIp returns the pending marker on 202', async () => {
    mockPost.mockResolvedValue(pendingEnvelope('sdwan.virtual_ip_create'));

    const result = await sdwanApi.createVirtualIp('net-1', { name: 'vip', cidr: '192.0.2.1/32' });

    expect(result).toMatchObject({ pending: true });
  });

  it('deleteVirtualIp returns the pending marker on 202', async () => {
    mockDelete.mockResolvedValue(pendingEnvelope('sdwan.virtual_ip_delete'));

    const result = await sdwanApi.deleteVirtualIp('net-1', 'vip-1');

    expect(result).toMatchObject({ pending: true });
  });

  it('failoverVirtualIp returns the pending marker on 202', async () => {
    mockPost.mockResolvedValue(pendingEnvelope('system.sdwan_vip_failover'));

    const result = await sdwanApi.failoverVirtualIp('net-1', 'vip-1');

    expect(result).toMatchObject({ pending: true });
  });

  it('revokeAccessGrant returns the pending marker on 202', async () => {
    mockPost.mockResolvedValue(pendingEnvelope('sdwan.access_grant_revoke'));

    const result = await sdwanApi.revokeAccessGrant('net-1', 'ag-1');

    expect(result).toMatchObject({ pending: true });
  });

  it('proposeFederationPeer returns the pending marker on 202', async () => {
    mockPost.mockResolvedValue(pendingEnvelope('sdwan.federation_peer_propose'));

    const result = await sdwanApi.proposeFederationPeer({ remote_instance_url: 'https://peer.example' });

    expect(result).toMatchObject({ pending: true });
  });

  it('createRoutePolicy returns the pending marker on 202', async () => {
    mockPost.mockResolvedValue(pendingEnvelope('sdwan.route_policy_create'));

    const result = await sdwanApi.createRoutePolicy({ name: 'p', scope: 'network', direction: 'import' } as never);

    expect(result).toMatchObject({ pending: true });
  });

  it('deleteRoutePolicy returns the pending marker on 202', async () => {
    mockDelete.mockResolvedValue(pendingEnvelope('sdwan.route_policy_delete'));

    const result = await sdwanApi.deleteRoutePolicy('rp-1');

    expect(result).toMatchObject({ pending: true });
  });

  it('detachPeer returns the pending marker on 202', async () => {
    mockDelete.mockResolvedValue(pendingEnvelope('sdwan.peer_delete'));

    const result = await sdwanApi.detachPeer('net-1', 'peer-1');

    expect(result).toMatchObject({ pending: true });
  });

  // sdwan.peer_update is gated server-side but PeerEditModal bypassed the
  // shared API layer with a direct apiClient.put — updatePeer must exist here
  // so the pending contract covers the peer update path too.
  it('updatePeer PUTs through the shared layer and returns the pending marker on 202', async () => {
    mockPut.mockResolvedValue(pendingEnvelope('sdwan.peer_update'));

    const result = await sdwanApi.updatePeer('net-1', 'peer-1', { publicly_reachable: true });

    expect(mockPut).toHaveBeenCalledWith('/system/sdwan/networks/net-1/peers/peer-1', {
      peer: { publicly_reachable: true },
    });
    expect(result).toMatchObject({ pending: true });
  });

  it('updatePeer returns the peer on the non-pending branch', async () => {
    mockPut.mockResolvedValue(envelope({ peer: { ...PEER, publicly_reachable: false } }));

    const result = await sdwanApi.updatePeer('net-1', 'peer-1', { publicly_reachable: false });

    expect(result).toMatchObject({ id: 'peer-1', publicly_reachable: false });
  });
});
