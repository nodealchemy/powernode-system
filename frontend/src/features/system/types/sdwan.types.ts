// SDWAN types — mirror the JSON contracts the Sdwan::* serializers emit.
// Cumulative across slices 3 + 4 (user VPN) + 6 (federation) + 7a (dual-stack
// endpoints) + 9a (static subnet routing).

export type SdwanNetworkStatus = 'registered' | 'active' | 'suspended' | 'archived';
export type SdwanFirewallPolicy = 'accept' | 'drop';
export type SdwanFirewallAction = 'accept' | 'drop' | 'reject';
export type SdwanFirewallDirection = 'ingress' | 'egress' | 'both';
export type SdwanFirewallProtocol = 'any' | 'tcp' | 'udp' | 'icmp6';
export type SdwanPeerStatus = 'pending' | 'active' | 'degraded' | 'disconnected';
export type SdwanRoutingProtocol = 'static' | 'ibgp';

export interface SdwanNetwork {
  id: string;
  name: string;
  slug: string;
  status: SdwanNetworkStatus;
  cidr_64: string;
  description?: string;
  tags?: string[];
  settings?: Record<string, unknown>;
  peer_count: number;
  hub_count?: number;
  spoke_count?: number;
  last_compiled_at?: string | null;
  created_at: string;
  // Slice 9a — routing layer
  routing_protocol?: SdwanRoutingProtocol;
  advertise_overlay_subnet?: boolean;
  route_reflector_redundancy?: number;
  advertised_prefix_count?: number;
}

export interface SdwanPeer {
  id: string;
  network_id: string;
  node_instance_id: string;
  assigned_address: string;
  publicly_reachable: boolean;
  endpoint?: string | null;
  endpoint_host?: string | null;
  // Slice 7a — dual-stack endpoint columns (v6-preferred).
  endpoint_host_v6?: string | null;
  endpoint_host_v4?: string | null;
  endpoint_port?: number | null;
  // Slice 7a — derived view of which endpoint the compiler will use plus
  // which one ships as fallback to the agent.
  effective_endpoint?: string | null;
  effective_endpoint_family?: 'v6' | 'v4' | null;
  fallback_endpoint?: string | null;
  listen_port: number;
  status: SdwanPeerStatus;
  public_key?: string | null;
  last_handshake_at?: string | null;
  capabilities?: Record<string, unknown>;
  created_at?: string;
  // Slice 9a — routing layer.
  lan_subnets?: string[];
  bgp_route_reflector_client?: boolean;
  bgp_router_id_override?: string | null;
  advertised_prefix_count?: number;
}

// Selectors mirror the Ruby model's grammar — exactly one of the four kinds.
export type SdwanSelector =
  | { peer_id: string }
  | { tag: string }
  | { cidr: string }
  | { all: true }
  | Record<string, never>;  // empty = wildcard (also accepted)

export interface SdwanPortRange {
  from: number;
  to: number;
}

export interface SdwanFirewallRule {
  id: string;
  network_id: string;
  name: string;
  priority: number;
  action: SdwanFirewallAction;
  direction: SdwanFirewallDirection;
  protocol: SdwanFirewallProtocol;
  src_selector?: SdwanSelector;
  dst_selector?: SdwanSelector;
  port_range?: SdwanPortRange | null;
  enabled: boolean;
  compiled_preview?: string;
  last_compiled_at?: string | null;
  metadata?: Record<string, unknown>;
  created_at?: string;
}

// One peer's compiled view — what the agent receives on the next config pull.
export interface SdwanCompiledPeerView {
  peer_id: string;
  interface: {
    name: string;
    address: string;
    listen_port: number;
    mtu: number;
    public_key?: string;
  };
  peers: SdwanCompiledPeerEdge[];
  firewall?: {
    table: string;
    chain: string;
    interface: string;
    policy: SdwanFirewallPolicy;
    rule_count: number;
    ruleset: string;
    compiled_at: string;
  };
  federation: unknown[];
}

export interface SdwanCompiledPeerEdge {
  peer_id: string;
  public_key: string;
  endpoint?: string | null;
  allowed_ips: string[];
  persistent_keepalive?: number | null;
}

export interface SdwanTopologyResponse {
  network_id: string;
  cidr_64: string;
  peer_count: number;
  peers: SdwanCompiledPeerView[];
}

// ──── Slice 4: User VPN ─────────────────────────────────────────────

export type SdwanAccessGrantStatus = 'active' | 'suspended' | 'revoked';

export interface SdwanAccessGrant {
  id: string;
  network_id: string;
  user_id: string;
  user_email?: string;
  status: SdwanAccessGrantStatus;
  tags: string[];
  granted_at?: string | null;
  granted_by_user_id?: string | null;
  revoked_at?: string | null;
  revocation_reason?: string | null;
  device_count: number;
  metadata?: Record<string, unknown>;
  created_at?: string;
}

export interface SdwanUserDevice {
  id: string;
  access_grant_id: string;
  network_id?: string;
  label: string;
  public_key: string;
  assigned_address: string;
  downloadable: boolean;
  last_downloaded_at?: string | null;
  last_seen_at?: string | null;
  revoked_at?: string | null;
  created_at?: string;
}

export interface SdwanBootstrapEnvelope {
  token: string;
  url: string;
  expires_at: string;
}

export interface SdwanIssueUserDeviceResponse {
  user_device: SdwanUserDevice;
  bootstrap: SdwanBootstrapEnvelope;
}

// ──── Slice 6: Federation ──────────────────────────────────────────

export type SdwanFederationStatus = 'proposed' | 'accepted' | 'active' | 'suspended' | 'revoked';

export interface SdwanFederationPeer {
  id: string;
  remote_instance_url: string;
  remote_instance_id?: string | null;
  remote_account_id?: string | null;
  remote_prefix_advertisement?: string | null;
  status: SdwanFederationStatus;
  v1_allowed_transitions?: string[];
  signed_at?: string | null;
  expires_at?: string | null;
  has_trust_jwt?: boolean;
  metadata?: Record<string, unknown>;
  created_at?: string;
}

export type SdwanFederationFindingKind =
  | 'prefix_overlap_with_install'
  | 'prefix_overlap_with_other_peer'
  | 'stale_accepted_without_handshake'
  | 'expired_trust_jwt';

export type SdwanFederationFindingSeverity = 'low' | 'medium' | 'high' | 'critical';

export interface SdwanFederationFinding {
  kind: SdwanFederationFindingKind;
  severity: SdwanFederationFindingSeverity;
  federation_peer_id: string;
  message: string;
  payload: Record<string, unknown>;
}

// ──── Slice 9a: Routing layer (static subnet routing baseline) ─────

export type SdwanAdvertisementSource = 'declared_lan_subnet' | 'virtual_ip' | 'learned_via_bgp';

export interface SdwanSubnetAdvertisement {
  id: string;
  peer_id: string;
  network_id: string;
  prefix: string;
  source: SdwanAdvertisementSource;
  origin_peer_id?: string | null;
  via_peer_id?: string | null;
  as_path?: string | null;
  med?: number | null;
  local_pref?: number | null;
  first_seen_at?: string | null;
  last_seen_at?: string | null;
  withdrawn_at?: string | null;
  active: boolean;
}

export interface SdwanRoutingSummary {
  network_id: string;
  routing_protocol: SdwanRoutingProtocol;
  advertise_overlay_subnet: boolean;
  route_reflector_redundancy: number;
  peer_count: number;
  hub_count: number;
  rr_count: number;
  advertised_prefix_count: number;
  declared_subnet_count: number;
  vip_count: number;
  learned_count: number;
}

// ──── Slice 9b: Virtual IPs (first-class) ──────────────────────────

export type SdwanVirtualIpState =
  | 'pending'
  | 'active'
  | 'failing_over'
  | 'unassigned'
  | 'error';

export type SdwanVirtualIpAssignmentReason =
  | 'initial'
  | 'manual_failover'
  | 'sensor_failover'
  | 'holder_changed'
  | 'revoked';

export interface SdwanVirtualIpAssignment {
  id: string;
  peer_id: string;
  assumed_at: string;
  released_at?: string | null;
  reason: SdwanVirtualIpAssignmentReason;
  triggered_by_user_id?: string | null;
  active: boolean;
}

export interface SdwanVirtualIp {
  id: string;
  network_id: string;
  name: string;
  cidr: string;
  anycast: boolean;
  state: SdwanVirtualIpState;
  holder_peer_ids: string[];
  failover_holder_peer_ids: string[];
  primary_holder_peer_id?: string | null;
  primary_holder_address?: string | null;
  advertised_med: number;
  advertised_local_pref: number;
  tags: string[];
  description?: string | null;
  metadata?: Record<string, unknown>;
  assignments?: SdwanVirtualIpAssignment[];
  created_at?: string | null;
}

export interface SdwanVirtualIpCreate {
  name: string;
  cidr: string;
  description?: string;
  anycast?: boolean;
  holder_peer_ids?: string[];
  failover_holder_peer_ids?: string[];
  advertised_med?: number;
  advertised_local_pref?: number;
  tags?: string[];
  metadata?: Record<string, unknown>;
}

export type SdwanVirtualIpUpdate = Partial<SdwanVirtualIpCreate> & { state?: SdwanVirtualIpState };

// ──── Slice 9c: iBGP routing control plane ─────────────────────────

export type SdwanRouterIdStrategy = 'peer_overlay_ipv6_hash' | 'explicit';

export interface SdwanAccountBgp {
  id: string;
  as_number: number;
  router_id_strategy: SdwanRouterIdStrategy;
  default_local_pref: number;
  enabled: boolean;
  created_at?: string | null;
}

export type SdwanBgpSessionState =
  | 'idle'
  | 'connect'
  | 'active'
  | 'opensent'
  | 'openconfirm'
  | 'established';

export interface SdwanBgpSession {
  id: string;
  peer_id: string;
  network_id: string;
  neighbor_peer_id?: string | null;
  neighbor_address: string;
  state: SdwanBgpSessionState;
  uptime_seconds: number;
  prefixes_received: number;
  prefixes_sent: number;
  last_state_change_at?: string | null;
  last_observed_at?: string | null;
  last_error?: string | null;
}

export interface SdwanRoutingOverview {
  account_bgp: SdwanAccountBgp | null;
  summary: {
    total_networks: number;
    ibgp_networks: number;
    static_networks: number;
    established_sessions: number;
    total_sessions: number;
  };
}

// Mirrors Sdwan::Bgp::ConfigCompiler#compile output. Used by the
// per-peer FRR config viewer (slice 9d operator UI).
export interface SdwanBgpNeighbor {
  neighbor_peer_id: string;
  neighbor_address: string;
  remote_as: number;
  route_reflector_client: boolean;
  description: string;
}

export interface SdwanBgpConfig {
  enabled: boolean;
  as_number?: number;
  router_id?: string;
  is_route_reflector?: boolean;
  route_reflector_client?: boolean;
  neighbors?: SdwanBgpNeighbor[];
  networks?: string[];
  hold_time_seconds?: number;
  keepalive_seconds?: number;
  graceful_restart?: boolean;
  frr_text?: string;
  policies?: SdwanRoutePolicyCompiled;
  neighbor_route_maps?: Record<string, { import?: string; export?: string }>;
}

// ──── Slice 9e: Route policies ────────────────────────────────────

export type SdwanRoutePolicyScope = 'account' | 'network' | 'peer';
export type SdwanRoutePolicyDirection = 'import' | 'export';
export type SdwanRoutePolicyActionType = 'accept' | 'reject';

export interface SdwanRoutePolicyMatch {
  prefix_in?: string[];
  as_path_regex?: string;
  community_in?: string[];
  tag_in?: string[];
  peer_in?: string[];
}

export interface SdwanRoutePolicyAction {
  type: SdwanRoutePolicyActionType;
  set_local_pref?: number;
  set_med?: number;
  prepend_as_path?: number;
  add_community?: string;
}

export interface SdwanRoutePolicyStatement {
  match: SdwanRoutePolicyMatch;
  action: SdwanRoutePolicyAction;
}

export interface SdwanRoutePolicy {
  id: string;
  name: string;
  description?: string | null;
  scope: SdwanRoutePolicyScope;
  scope_resource_id?: string | null;
  direction: SdwanRoutePolicyDirection;
  enabled: boolean;
  statement_count: number;
  slug: string;
  statements?: SdwanRoutePolicyStatement[];
  metadata?: Record<string, unknown>;
  created_at?: string | null;
  updated_at?: string | null;
}

export interface SdwanRoutePolicyCreate {
  name: string;
  scope: SdwanRoutePolicyScope;
  direction: SdwanRoutePolicyDirection;
  statements: SdwanRoutePolicyStatement[];
  scope_resource_id?: string | null;
  description?: string;
  enabled?: boolean;
  metadata?: Record<string, unknown>;
}

export type SdwanRoutePolicyUpdate = Partial<SdwanRoutePolicyCreate>;

// What the compiler emits — used by the "show me what FRR sees" preview.
export interface SdwanRoutePolicyCompiled {
  prefix_lists: string[];
  ipv6_prefix_lists: string[];
  as_path_lists: string[];
  community_lists: string[];
  route_maps: string[];
  neighbor_assignments?: Record<string, { import?: string; export?: string }>;
}

// ──── Slice 7b: Port mappings (hub DNAT) ──────────────────────────

export type SdwanPortMappingProtocol = 'tcp' | 'udp';

export interface SdwanPortMapping {
  id: string;
  network_id: string;
  hub_peer_id: string;
  target_peer_id?: string | null;
  target_virtual_ip_id?: string | null;
  name: string;
  listen_port: number;
  target_port?: number | null;
  effective_target_port: number;
  protocol: SdwanPortMappingProtocol;
  enabled: boolean;
  description?: string | null;
  metadata?: Record<string, unknown>;
  resolved_target_address?: string | null;
  last_compiled_at?: string | null;
  created_at?: string | null;
}

export interface SdwanPortMappingCreate {
  name: string;
  sdwan_peer_id: string;
  listen_port: number;
  protocol: SdwanPortMappingProtocol;
  target_peer_id?: string | null;
  target_virtual_ip_id?: string | null;
  target_port?: number | null;
  description?: string;
  enabled?: boolean;
}

export type SdwanPortMappingUpdate = Partial<SdwanPortMappingCreate>;

// ──────────────────────────────────────────────────────────────────
// Phase O6 — OVS+OVN dual-profile networking
// ──────────────────────────────────────────────────────────────────

export type SdwanHostBridgeKind  = 'linux' | 'ovs';
export type SdwanHostBridgeState = 'pending' | 'active' | 'draining' | 'removed';

export interface SdwanHostBridge {
  id: string;
  node_instance_id: string;
  node_instance_name?: string | null;
  network_profile?: string | null;
  short_id: number;
  bridge_name: string;
  kind: SdwanHostBridgeKind;
  state: SdwanHostBridgeState;
  applied_at?: string | null;
  draining_at?: string | null;
  removed_at?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
}

export type SdwanOvnDeploymentStatus = 'pending' | 'bootstrapping' | 'active' | 'degraded';
export type SdwanOvnSwitchState     = 'pending' | 'active' | 'removed';
export type SdwanOvnPortState       = 'pending' | 'active' | 'removed';
export type SdwanOvnPortKind        = 'vm' | 'container' | 'external';

export interface SdwanOvnLogicalSwitchPort {
  id: string;
  name: string;
  kind: SdwanOvnPortKind;
  state: SdwanOvnPortState;
  mac: string;
  addresses: string[];
  host_node_instance_id?: string | null;
  activated_at?: string | null;
  removed_at?: string | null;
}

export interface SdwanOvnLogicalSwitch {
  id: string;
  name: string;
  cidr?: string | null;
  state: SdwanOvnSwitchState;
  activated_at?: string | null;
  removed_at?: string | null;
  ports: SdwanOvnLogicalSwitchPort[];
}

export interface SdwanOvnDeploymentSummary {
  id: string;
  status: SdwanOvnDeploymentStatus;
  nb_db_endpoint: string;
  sb_db_endpoint: string;
  northd_host?: string | null;
  switch_count: number;
  port_count: number;
  bootstrapped_at?: string | null;
  activated_at?: string | null;
  degraded_at?: string | null;
}

export interface SdwanOvnDeployment extends SdwanOvnDeploymentSummary {
  created_at?: string | null;
  updated_at?: string | null;
  logical_switches: SdwanOvnLogicalSwitch[];
}

export interface SdwanOvnCompiledPlanStep {
  cmd: string;
  args: string[];
}

export interface SdwanOvnCompiledPlan {
  deployment_id?: string;
  plan?: SdwanOvnCompiledPlanStep[];
  compiled_at?: string;
  error?: string;
}

export type SdwanIpfixState = 'active' | 'disabled';

export interface SdwanIpfixCollector {
  id: string;
  name: string;
  host: string;
  port: number;
  target_endpoint: string;
  sampling_rate: number;
  state: SdwanIpfixState;
  is_winning_collector: boolean;
  created_at?: string | null;
  updated_at?: string | null;
}
