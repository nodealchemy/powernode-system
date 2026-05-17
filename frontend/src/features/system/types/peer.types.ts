// Platform Peers — types for the /app/system/compute/platform/peers
// panel and supporting modals.
//
// Plan reference: Decentralized Federation §I + P7.1.

export type PeerKind = 'platform' | 'sdwan_only';
export type SpawnRole = 'parent' | 'child' | 'symmetric';
export type SpawnMode =
  | 'managed_child'
  | 'autonomous_peer'
  | 'cluster_member'
  | 'out_of_band';

export type PeerStatus =
  | 'proposed'
  | 'accepted'
  | 'enrolled'
  | 'active'
  | 'degraded'
  | 'suspended'
  | 'revoked';

export type EndpointScope = 'lan' | 'sdwan' | 'wan';

export interface PeerEndpoint {
  url: string;
  scope: EndpointScope;
  priority: number;
  cidr_hint?: string | null;
  last_verified_at?: string | null;
  last_failure_at?: string | null;
  status?: 'reachable' | 'unreachable' | 'unknown';
}

export interface PlatformPeerSummary {
  id: string;
  remote_instance_url: string;
  remote_instance_id: string | null;
  peer_kind: PeerKind;
  spawn_role: SpawnRole | null;
  spawn_mode: SpawnMode | null;
  status: PeerStatus;
  created_at: string;
  last_heartbeat_at: string | null;
  last_handshake_at: string | null;
  endpoints_count: number;
  acceptance_pending: boolean;
  acceptance_expires_at: string | null;
}

export interface PlatformPeerDetail extends PlatformPeerSummary {
  endpoints: PeerEndpoint[];
  capabilities: Record<string, unknown>;
  extension_slugs: string[];
  metadata: Record<string, unknown>;
  signed_at: string | null;
  contract_version_agreed: string | null;
  parent_peer_id: string | null;
  allowed_transitions: PeerStatus[];
  grants_count: number;
  capabilities_count: number;
  bridges_count: number;
}

export interface InvitePeerRequest {
  remote_instance_url: string;
  spawn_role?: SpawnRole;
  spawn_mode?: SpawnMode;
  endpoints?: Array<Pick<PeerEndpoint, 'url' | 'scope' | 'priority'>>;
  token_ttl_seconds?: number;
}

export interface InvitePeerResponse {
  peer: PlatformPeerDetail;
  // Plaintext single-use acceptance token. Server never returns this
  // again — the modal MUST surface it for capture before navigating
  // away.
  acceptance_token: string;
}

export interface PeerListResponse {
  peers: PlatformPeerSummary[];
  count: number;
}

export interface PeerListFilters {
  status?: PeerStatus | PeerStatus[];
  spawn_mode?: SpawnMode;
}
