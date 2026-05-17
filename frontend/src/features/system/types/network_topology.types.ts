// Shapes returned by GET /api/v1/system/network/topology
// Plan reference: Decentralized Federation §K.5 + P4.5.7.

export type TopologyNodeType = 'self' | 'peer-platform' | 'peer-sdwan' | 'network';

export type TopologyEdgeType = 'bridge' | 'membership' | 'grant_summary';

export interface TopologyNodePosition {
  x: number;
  y: number;
}

export interface TopologyNode {
  id: string;
  type: TopologyNodeType;
  position: TopologyNodePosition;
  data: TopologyNodeData;
}

export interface HandleCounts {
  source_top: number;
  source_bottom: number;
  target_top: number;
  target_bottom: number;
}

export interface TopologyNodeData {
  label: string;
  subtitle?: string;
  // self
  account_id?: string;
  // network
  slug?: string;
  cidr_64?: string;
  routing_protocol?: string;
  status?: string;
  // peer
  peer_kind?: 'platform' | 'sdwan_only';
  spawn_role?: 'parent' | 'child' | 'symmetric' | null;
  remote_instance_url?: string;
  bridge_count?: number;
  active_bridge_count?: number;
  grant_count?: number;
  last_heartbeat_at?: string | null;
  // multi-handle slot counts (computed server-side; renderer maps over them)
  handle_counts?: HandleCounts;
}

export interface TopologyEdgeData {
  label?: string;
  // bridge
  bridge_id?: string;
  state?: string;
  activated_at?: string | null;
  // grant_summary
  grant_count?: number;
  broad_scope_count?: number;
  unrestricted_count?: number;
  // Per-edge routing lane (Y-coordinate of the smoothstep horizontal
  // middle segment). Computed server-side per edge family so parallel
  // edges fan out vertically instead of stacking on one line.
  center_y?: number;
}

export interface TopologyEdge {
  id: string;
  source: string;
  target: string;
  // Multi-handle slot ids assigned server-side (e.g. "s_bot_3", "t_top_0").
  // Map to xyflow's `sourceHandle` / `targetHandle` Edge fields in buildFlow.
  source_handle?: string;
  target_handle?: string;
  type: TopologyEdgeType;
  data: TopologyEdgeData;
  animated?: boolean;
}

export interface TopologyStats {
  peer_count: number;
  platform_peer_count: number;
  sdwan_only_peer_count: number;
  network_count: number;
  bridge_count: number;
  active_bridge_count: number;
  grant_count: number;
  generated_at: string;
}

export interface NetworkTopologyResponse {
  self_id: string;
  self_label: string;
  nodes: TopologyNode[];
  edges: TopologyEdge[];
  stats: TopologyStats;
}
