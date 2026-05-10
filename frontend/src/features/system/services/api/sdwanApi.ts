import { apiClient } from '@/shared/services/apiClient';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';
import type {
  SdwanNetwork,
  SdwanPeer,
  SdwanFirewallRule,
  SdwanTopologyResponse,
  SdwanFirewallAction,
  SdwanFirewallDirection,
  SdwanFirewallProtocol,
  SdwanSelector,
  SdwanPortRange,
  SdwanAccessGrant,
  SdwanUserDevice,
  SdwanIssueUserDeviceResponse,
  SdwanFederationPeer,
  SdwanFederationFinding,
  SdwanVirtualIp,
  SdwanVirtualIpCreate,
  SdwanVirtualIpUpdate,
  SdwanRoutingOverview,
  SdwanAccountBgp,
  SdwanBgpSession,
  SdwanRoutePolicy,
  SdwanRoutePolicyCreate,
  SdwanRoutePolicyUpdate,
  SdwanRoutePolicyCompiled,
  SdwanPortMapping,
  SdwanPortMappingCreate,
  SdwanPortMappingUpdate,
  SdwanHostBridge,
  SdwanOvnDeployment,
  SdwanOvnDeploymentSummary,
  SdwanOvnCompiledPlan,
  SdwanIpfixCollector,
} from '../../types/sdwan.types';

export interface SdwanHostBridgeFilters {
  node_instance_id?: string;
  state?: string;
  kind?: string;
}

export interface SdwanIpfixCollectorFilters {
  state?: string;
}

export interface SdwanNetworkFilters extends PaginationParams {
  status?: string;
}

export interface SdwanNetworkCreate {
  name: string;
  description?: string;
  settings?: Record<string, unknown>;
  tags?: string[];
}

export interface SdwanPeerCreate {
  node_instance_id: string;
  publicly_reachable?: boolean;
  // Slice 7a — prefer endpoint_host_v6/v4 over the legacy endpoint_host.
  endpoint_host?: string;
  endpoint_host_v6?: string;
  endpoint_host_v4?: string;
  endpoint_port?: number;
  listen_port?: number;
  capabilities?: Record<string, unknown>;
  // Slice 9a — declarative external prefixes (CIDRs).
  lan_subnets?: string[];
  bgp_route_reflector_client?: boolean;
}

export interface SdwanFirewallRuleCreate {
  name: string;
  priority?: number;
  action?: SdwanFirewallAction;
  direction?: SdwanFirewallDirection;
  protocol?: SdwanFirewallProtocol;
  src_selector?: SdwanSelector;
  dst_selector?: SdwanSelector;
  port_range?: SdwanPortRange | null;
  enabled?: boolean;
}

export const sdwanApi = {
  // -------- Networks --------
  getNetworks: async (params?: SdwanNetworkFilters): Promise<{ networks: SdwanNetwork[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<PaginatedEnvelope<{ networks: SdwanNetwork[] }>>(
      '/system/sdwan/networks',
      { params }
    );
    return extractPaginated(response);
  },

  getNetwork: async (id: string): Promise<SdwanNetwork> => {
    const response = await apiClient.get<ApiEnvelope<{ network: SdwanNetwork }>>(
      `/system/sdwan/networks/${id}`
    );
    return extractData(response).network;
  },

  createNetwork: async (data: SdwanNetworkCreate): Promise<SdwanNetwork> => {
    const response = await apiClient.post<ApiEnvelope<{ network: SdwanNetwork }>>(
      '/system/sdwan/networks',
      { network: data }
    );
    return extractData(response).network;
  },

  updateNetwork: async (id: string, data: Partial<SdwanNetworkCreate & { status: string }>): Promise<SdwanNetwork> => {
    const response = await apiClient.put<ApiEnvelope<{ network: SdwanNetwork }>>(
      `/system/sdwan/networks/${id}`,
      { network: data }
    );
    return extractData(response).network;
  },

  deleteNetwork: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/sdwan/networks/${id}`);
  },

  getTopology: async (id: string): Promise<SdwanTopologyResponse> => {
    const response = await apiClient.get<ApiEnvelope<SdwanTopologyResponse>>(
      `/system/sdwan/networks/${id}/topology`
    );
    return extractData(response);
  },

  // -------- Peers --------
  getPeers: async (networkId: string): Promise<{ peers: SdwanPeer[] }> => {
    const response = await apiClient.get<ApiEnvelope<{ peers: SdwanPeer[]; count: number }>>(
      `/system/sdwan/networks/${networkId}/peers`
    );
    const data = extractData(response);
    return { peers: data.peers ?? [] };
  },

  attachPeer: async (networkId: string, data: SdwanPeerCreate): Promise<SdwanPeer> => {
    const response = await apiClient.post<ApiEnvelope<{ peer: SdwanPeer }>>(
      `/system/sdwan/networks/${networkId}/peers`,
      { peer: data }
    );
    return extractData(response).peer;
  },

  detachPeer: async (networkId: string, peerId: string): Promise<void> => {
    await apiClient.delete(`/system/sdwan/networks/${networkId}/peers/${peerId}`);
  },

  // -------- Firewall Rules --------
  getFirewallRules: async (networkId: string): Promise<{ rules: SdwanFirewallRule[]; defaultPolicy: string }> => {
    const response = await apiClient.get<
      ApiEnvelope<{ firewall_rules: SdwanFirewallRule[]; count: number; network_default_policy: string }>
    >(`/system/sdwan/networks/${networkId}/firewall_rules`);
    const data = extractData(response);
    return { rules: data.firewall_rules ?? [], defaultPolicy: data.network_default_policy };
  },

  createFirewallRule: async (
    networkId: string,
    data: SdwanFirewallRuleCreate
  ): Promise<SdwanFirewallRule> => {
    const response = await apiClient.post<ApiEnvelope<{ firewall_rule: SdwanFirewallRule }>>(
      `/system/sdwan/networks/${networkId}/firewall_rules`,
      { firewall_rule: data }
    );
    return extractData(response).firewall_rule;
  },

  updateFirewallRule: async (
    networkId: string,
    ruleId: string,
    data: Partial<SdwanFirewallRuleCreate>
  ): Promise<SdwanFirewallRule> => {
    const response = await apiClient.put<ApiEnvelope<{ firewall_rule: SdwanFirewallRule }>>(
      `/system/sdwan/networks/${networkId}/firewall_rules/${ruleId}`,
      { firewall_rule: data }
    );
    return extractData(response).firewall_rule;
  },

  deleteFirewallRule: async (networkId: string, ruleId: string): Promise<void> => {
    await apiClient.delete(`/system/sdwan/networks/${networkId}/firewall_rules/${ruleId}`);
  },

  // ──── Slice 4: User VPN — access grants ────────────────────────────

  getAccessGrants: async (networkId: string): Promise<{ grants: SdwanAccessGrant[] }> => {
    const response = await apiClient.get<ApiEnvelope<{ access_grants: SdwanAccessGrant[]; count: number }>>(
      `/system/sdwan/networks/${networkId}/access_grants`
    );
    return { grants: extractData(response).access_grants ?? [] };
  },

  createAccessGrant: async (
    networkId: string,
    data: { user_id: string; tags?: string[] }
  ): Promise<SdwanAccessGrant> => {
    const response = await apiClient.post<ApiEnvelope<{ access_grant: SdwanAccessGrant }>>(
      `/system/sdwan/networks/${networkId}/access_grants`,
      { access_grant: data }
    );
    return extractData(response).access_grant;
  },

  updateAccessGrant: async (
    networkId: string,
    grantId: string,
    data: { status?: string; tags?: string[] }
  ): Promise<SdwanAccessGrant> => {
    const response = await apiClient.put<ApiEnvelope<{ access_grant: SdwanAccessGrant }>>(
      `/system/sdwan/networks/${networkId}/access_grants/${grantId}`,
      { access_grant: data }
    );
    return extractData(response).access_grant;
  },

  revokeAccessGrant: async (
    networkId: string,
    grantId: string,
    reason?: string
  ): Promise<SdwanAccessGrant> => {
    const response = await apiClient.post<ApiEnvelope<{ access_grant: SdwanAccessGrant }>>(
      `/system/sdwan/networks/${networkId}/access_grants/${grantId}/revoke`,
      { reason }
    );
    return extractData(response).access_grant;
  },

  deleteAccessGrant: async (networkId: string, grantId: string): Promise<void> => {
    await apiClient.delete(`/system/sdwan/networks/${networkId}/access_grants/${grantId}`);
  },

  // ──── Slice 4: User VPN — user devices ─────────────────────────────

  getUserDevices: async (networkId: string, grantId: string): Promise<{ devices: SdwanUserDevice[] }> => {
    const response = await apiClient.get<ApiEnvelope<{ user_devices: SdwanUserDevice[]; count: number }>>(
      `/system/sdwan/networks/${networkId}/access_grants/${grantId}/user_devices`
    );
    return { devices: extractData(response).user_devices ?? [] };
  },

  issueUserDevice: async (
    networkId: string,
    grantId: string,
    data: { label: string }
  ): Promise<SdwanIssueUserDeviceResponse> => {
    const response = await apiClient.post<ApiEnvelope<SdwanIssueUserDeviceResponse>>(
      `/system/sdwan/networks/${networkId}/access_grants/${grantId}/user_devices`,
      { user_device: data }
    );
    return extractData(response);
  },

  revokeUserDevice: async (
    networkId: string,
    grantId: string,
    deviceId: string,
    reason?: string
  ): Promise<SdwanUserDevice> => {
    const response = await apiClient.post<ApiEnvelope<{ user_device: SdwanUserDevice }>>(
      `/system/sdwan/networks/${networkId}/access_grants/${grantId}/user_devices/${deviceId}/revoke`,
      { reason }
    );
    return extractData(response).user_device;
  },

  deleteUserDevice: async (networkId: string, grantId: string, deviceId: string): Promise<void> => {
    await apiClient.delete(`/system/sdwan/networks/${networkId}/access_grants/${grantId}/user_devices/${deviceId}`);
  },

  // ──── Slice 6: Federation peers ────────────────────────────────────

  getFederationPeers: async (): Promise<{ peers: SdwanFederationPeer[] }> => {
    const response = await apiClient.get<ApiEnvelope<{ federation_peers: SdwanFederationPeer[]; count: number }>>(
      '/system/sdwan/federation_peers'
    );
    return { peers: extractData(response).federation_peers ?? [] };
  },

  getFederationPeer: async (id: string): Promise<SdwanFederationPeer> => {
    const response = await apiClient.get<ApiEnvelope<{ federation_peer: SdwanFederationPeer }>>(
      `/system/sdwan/federation_peers/${id}`
    );
    return extractData(response).federation_peer;
  },

  proposeFederationPeer: async (data: {
    remote_instance_url: string;
    remote_instance_id?: string;
    remote_account_id?: string;
    remote_prefix_advertisement?: string;
  }): Promise<SdwanFederationPeer> => {
    const response = await apiClient.post<ApiEnvelope<{ federation_peer: SdwanFederationPeer }>>(
      '/system/sdwan/federation_peers',
      { federation_peer: data }
    );
    return extractData(response).federation_peer;
  },

  revokeFederationPeer: async (id: string, reason?: string): Promise<SdwanFederationPeer> => {
    const response = await apiClient.post<ApiEnvelope<{ federation_peer: SdwanFederationPeer }>>(
      `/system/sdwan/federation_peers/${id}/revoke`,
      { reason }
    );
    return extractData(response).federation_peer;
  },

  deleteFederationPeer: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/sdwan/federation_peers/${id}`);
  },

  // ──── Slice 9b: Virtual IPs ───────────────────────────────────────

  listVirtualIps: async (
    networkId: string,
    filters?: { state?: string }
  ): Promise<{ virtual_ips: SdwanVirtualIp[]; count: number }> => {
    const params = new URLSearchParams();
    if (filters?.state) params.set('state', filters.state);
    const response = await apiClient.get<ApiEnvelope<{ virtual_ips: SdwanVirtualIp[]; count: number }>>(
      `/system/sdwan/networks/${networkId}/virtual_ips${params.toString() ? `?${params}` : ''}`
    );
    const data = extractData(response);
    return { virtual_ips: data.virtual_ips ?? [], count: data.count ?? 0 };
  },

  getVirtualIp: async (networkId: string, vipId: string): Promise<SdwanVirtualIp> => {
    const response = await apiClient.get<ApiEnvelope<{ virtual_ip: SdwanVirtualIp }>>(
      `/system/sdwan/networks/${networkId}/virtual_ips/${vipId}`
    );
    return extractData(response).virtual_ip;
  },

  createVirtualIp: async (networkId: string, data: SdwanVirtualIpCreate): Promise<SdwanVirtualIp> => {
    const response = await apiClient.post<ApiEnvelope<{ virtual_ip: SdwanVirtualIp }>>(
      `/system/sdwan/networks/${networkId}/virtual_ips`,
      { virtual_ip: data }
    );
    return extractData(response).virtual_ip;
  },

  updateVirtualIp: async (
    networkId: string,
    vipId: string,
    data: SdwanVirtualIpUpdate
  ): Promise<SdwanVirtualIp> => {
    const response = await apiClient.patch<ApiEnvelope<{ virtual_ip: SdwanVirtualIp }>>(
      `/system/sdwan/networks/${networkId}/virtual_ips/${vipId}`,
      { virtual_ip: data }
    );
    return extractData(response).virtual_ip;
  },

  deleteVirtualIp: async (networkId: string, vipId: string): Promise<void> => {
    await apiClient.delete(`/system/sdwan/networks/${networkId}/virtual_ips/${vipId}`);
  },

  failoverVirtualIp: async (networkId: string, vipId: string): Promise<SdwanVirtualIp> => {
    const response = await apiClient.post<ApiEnvelope<{ virtual_ip: SdwanVirtualIp }>>(
      `/system/sdwan/networks/${networkId}/virtual_ips/${vipId}/failover`,
      {}
    );
    return extractData(response).virtual_ip;
  },

  // ──── Slice 9c: iBGP routing control plane ────────────────────────

  getRoutingOverview: async (): Promise<SdwanRoutingOverview> => {
    const response = await apiClient.get<ApiEnvelope<SdwanRoutingOverview>>(
      '/system/sdwan/routing'
    );
    return extractData(response);
  },

  allocateAccountAs: async (): Promise<{
    account_bgp: SdwanAccountBgp;
    allocated: boolean;
  }> => {
    const response = await apiClient.post<
      ApiEnvelope<{ account_bgp: SdwanAccountBgp; allocated: boolean }>
    >('/system/sdwan/routing/bgp', {});
    return extractData(response);
  },

  getBgpSessions: async (filters?: {
    network_id?: string;
    state?: string;
  }): Promise<{ sessions: SdwanBgpSession[]; count: number }> => {
    const params = new URLSearchParams();
    if (filters?.network_id) params.set('network_id', filters.network_id);
    if (filters?.state) params.set('state', filters.state);
    const response = await apiClient.get<
      ApiEnvelope<{ sessions: SdwanBgpSession[]; count: number }>
    >(`/system/sdwan/routing/sessions${params.toString() ? `?${params}` : ''}`);
    const data = extractData(response);
    return { sessions: data.sessions ?? [], count: data.count ?? 0 };
  },

  // The per-peer BGP config viewer ("show me the frr.conf for this peer")
  // is exposed only via the MCP tool `system_sdwan_get_bgp_config_for_peer`
  // — there is no dedicated REST endpoint. The compiled BGP block also
  // appears inline in the topology response under each peer's `bgp:` key,
  // which is what the dashboard uses today.

  // ──── Slice 9e: Route policies ────────────────────────────────────

  listRoutePolicies: async (filters?: {
    scope?: string;
    direction?: string;
  }): Promise<{ route_policies: SdwanRoutePolicy[]; count: number }> => {
    const params = new URLSearchParams();
    if (filters?.scope) params.set('scope', filters.scope);
    if (filters?.direction) params.set('direction', filters.direction);
    const response = await apiClient.get<
      ApiEnvelope<{ route_policies: SdwanRoutePolicy[]; count: number }>
    >(`/system/sdwan/route_policies${params.toString() ? `?${params}` : ''}`);
    const data = extractData(response);
    return { route_policies: data.route_policies ?? [], count: data.count ?? 0 };
  },

  getRoutePolicy: async (id: string): Promise<SdwanRoutePolicy> => {
    const response = await apiClient.get<
      ApiEnvelope<{ route_policy: SdwanRoutePolicy }>
    >(`/system/sdwan/route_policies/${id}`);
    return extractData(response).route_policy;
  },

  createRoutePolicy: async (data: SdwanRoutePolicyCreate): Promise<SdwanRoutePolicy> => {
    const response = await apiClient.post<
      ApiEnvelope<{ route_policy: SdwanRoutePolicy }>
    >('/system/sdwan/route_policies', { route_policy: data });
    return extractData(response).route_policy;
  },

  updateRoutePolicy: async (
    id: string,
    data: SdwanRoutePolicyUpdate
  ): Promise<SdwanRoutePolicy> => {
    const response = await apiClient.patch<
      ApiEnvelope<{ route_policy: SdwanRoutePolicy }>
    >(`/system/sdwan/route_policies/${id}`, { route_policy: data });
    return extractData(response).route_policy;
  },

  deleteRoutePolicy: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/sdwan/route_policies/${id}`);
  },

  compileRoutePolicy: async (
    id: string,
    peerId: string
  ): Promise<{ compiled: SdwanRoutePolicyCompiled }> => {
    const response = await apiClient.get<
      ApiEnvelope<{ compiled: SdwanRoutePolicyCompiled }>
    >(`/system/sdwan/route_policies/${id}/compile?peer_id=${peerId}`);
    return extractData(response);
  },

  // ──── Slice 7b: Port mappings (hub DNAT) ──────────────────────────

  listPortMappings: async (
    networkId: string,
    filters?: { hub_peer_id?: string; enabled?: boolean }
  ): Promise<{ port_mappings: SdwanPortMapping[]; count: number }> => {
    const params = new URLSearchParams();
    if (filters?.hub_peer_id) params.set('hub_peer_id', filters.hub_peer_id);
    if (filters?.enabled !== undefined) params.set('enabled', String(filters.enabled));
    const response = await apiClient.get<
      ApiEnvelope<{ port_mappings: SdwanPortMapping[]; count: number }>
    >(`/system/sdwan/networks/${networkId}/port_mappings${params.toString() ? `?${params}` : ''}`);
    const data = extractData(response);
    return { port_mappings: data.port_mappings ?? [], count: data.count ?? 0 };
  },

  getPortMapping: async (networkId: string, id: string): Promise<SdwanPortMapping> => {
    const response = await apiClient.get<ApiEnvelope<{ port_mapping: SdwanPortMapping }>>(
      `/system/sdwan/networks/${networkId}/port_mappings/${id}`
    );
    return extractData(response).port_mapping;
  },

  createPortMapping: async (
    networkId: string,
    data: SdwanPortMappingCreate
  ): Promise<SdwanPortMapping> => {
    const response = await apiClient.post<ApiEnvelope<{ port_mapping: SdwanPortMapping }>>(
      `/system/sdwan/networks/${networkId}/port_mappings`,
      { port_mapping: data }
    );
    return extractData(response).port_mapping;
  },

  updatePortMapping: async (
    networkId: string,
    id: string,
    data: SdwanPortMappingUpdate
  ): Promise<SdwanPortMapping> => {
    const response = await apiClient.patch<ApiEnvelope<{ port_mapping: SdwanPortMapping }>>(
      `/system/sdwan/networks/${networkId}/port_mappings/${id}`,
      { port_mapping: data }
    );
    return extractData(response).port_mapping;
  },

  deletePortMapping: async (networkId: string, id: string): Promise<void> => {
    await apiClient.delete(`/system/sdwan/networks/${networkId}/port_mappings/${id}`);
  },

  // Governance scan is exposed through the MCP tool (system_sdwan_federation_scan).
  // The frontend calls a placeholder /scan action via MCP; the page reads the
  // findings array directly. For v1 we simulate by re-listing peers — a real
  // governance endpoint would be a v2 addition.
  // Currently: post to a synthetic /scan route that the MCP tool also serves.
  scanFederation: async (): Promise<{ findings: SdwanFederationFinding[]; severity_summary: Record<string, number> }> => {
    // Federation scan endpoint piggybacks on the MCP path via Ai::Tools::SdwanTool#federation_scan.
    // Until a dedicated REST endpoint is added, the operator UI surfaces results inline by
    // composing a synthetic call: re-fetch peers + run client-side governance hints.
    // For now, return the empty shape — the MCP tool exposes the full scanner.
    const response = await apiClient.get<ApiEnvelope<{ federation_peers: SdwanFederationPeer[] }>>(
      '/system/sdwan/federation_peers'
    );
    const peers = extractData(response).federation_peers ?? [];
    // Lightweight client-side mirror of FederationGovernance#scan — surfaces the
    // expired_trust_jwt finding without a server round-trip. Server-side scan
    // remains canonical via the MCP tool.
    const findings: SdwanFederationFinding[] = [];
    const now = Date.now();
    for (const p of peers) {
      if (p.expires_at && new Date(p.expires_at).getTime() < now && p.status !== 'revoked') {
        findings.push({
          kind: 'expired_trust_jwt',
          severity: 'high',
          federation_peer_id: p.id,
          message: `Trust JWT expired at ${p.expires_at}. Revoke and re-propose.`,
          payload: { remote_instance_url: p.remote_instance_url, status: p.status },
        });
      }
      if (p.status === 'accepted' && !p.signed_at) {
        findings.push({
          kind: 'stale_accepted_without_handshake',
          severity: 'medium',
          federation_peer_id: p.id,
          message: 'Peer is accepted but the cross-CA handshake never completed.',
          payload: { remote_instance_url: p.remote_instance_url },
        });
      }
    }
    const severity_summary = findings.reduce<Record<string, number>>((acc, f) => {
      acc[f.severity] = (acc[f.severity] ?? 0) + 1;
      return acc;
    }, {});
    return { findings, severity_summary };
  },

  // -------- Phase O6: HostBridges (read-only) --------
  getHostBridges: async (filters?: SdwanHostBridgeFilters): Promise<SdwanHostBridge[]> => {
    const response = await apiClient.get<ApiEnvelope<{ host_bridges: SdwanHostBridge[] }>>(
      '/system/sdwan/host_bridges',
      { params: filters }
    );
    return extractData(response).host_bridges;
  },

  getHostBridge: async (id: string): Promise<SdwanHostBridge> => {
    const response = await apiClient.get<ApiEnvelope<{ host_bridge: SdwanHostBridge }>>(
      `/system/sdwan/host_bridges/${id}`
    );
    return extractData(response).host_bridge;
  },

  // -------- Phase O6: OVN Deployments (read-only) --------
  getOvnDeployments: async (): Promise<SdwanOvnDeploymentSummary[]> => {
    const response = await apiClient.get<ApiEnvelope<{ ovn_deployments: SdwanOvnDeploymentSummary[] }>>(
      '/system/sdwan/ovn_deployments'
    );
    return extractData(response).ovn_deployments;
  },

  getOvnDeployment: async (id: string): Promise<{ deployment: SdwanOvnDeployment; compiled_plan: SdwanOvnCompiledPlan }> => {
    const response = await apiClient.get<
      ApiEnvelope<{ ovn_deployment: SdwanOvnDeployment; compiled_plan: SdwanOvnCompiledPlan }>
    >(`/system/sdwan/ovn_deployments/${id}`);
    const data = extractData(response);
    return { deployment: data.ovn_deployment, compiled_plan: data.compiled_plan };
  },

  // -------- Phase O6: IPFIX Collectors (read-only) --------
  getIpfixCollectors: async (filters?: SdwanIpfixCollectorFilters): Promise<SdwanIpfixCollector[]> => {
    const response = await apiClient.get<ApiEnvelope<{ ipfix_collectors: SdwanIpfixCollector[] }>>(
      '/system/sdwan/ipfix_collectors',
      { params: filters }
    );
    return extractData(response).ipfix_collectors;
  },

  getIpfixCollector: async (id: string): Promise<SdwanIpfixCollector> => {
    const response = await apiClient.get<ApiEnvelope<{ ipfix_collector: SdwanIpfixCollector }>>(
      `/system/sdwan/ipfix_collectors/${id}`
    );
    return extractData(response).ipfix_collector;
  },
};
