// Spawn flow types — mirrors System::SpawnPlatformService +
// the federation/children admin endpoints.
//
// Plan reference: Decentralized Federation §H + P6.

export type SpawnMode = 'managed_child' | 'autonomous_peer' | 'cluster_member';

export type ChildPeerStatus =
  | 'proposed'
  | 'accepted'
  | 'enrolled'
  | 'active'
  | 'degraded'
  | 'suspended'
  | 'revoked';

export interface SpawnTarget {
  template_id: string;
  region?: string;
  instance_size?: string;
  [key: string]: unknown;
}

export interface ChildPeerSummary {
  id: string;
  remote_instance_url: string;
  spawn_mode: SpawnMode;
  status: ChildPeerStatus;
  created_at: string;
  last_heartbeat_at: string | null;
  acceptance_pending: boolean;
  acceptance_expires_at: string | null;
}

export interface ChildPeerDetail extends ChildPeerSummary {
  endpoints: Array<Record<string, unknown>>;
  capabilities: Record<string, unknown>;
  metadata: Record<string, unknown>;
  signed_at: string | null;
}

export interface SpawnRequest {
  spawn_mode: SpawnMode;
  parent_url: string;
  spawn_target: SpawnTarget;
  token_ttl_seconds?: number;
}

export interface SpawnResponse {
  child: ChildPeerDetail;
  // Single-use; UI must capture immediately because the plaintext
  // isn't re-fetchable.
  acceptance_token: string;
  spawn_payload: Record<string, unknown>;
}

export interface ChildrenListResponse {
  children: ChildPeerSummary[];
  count: number;
}

export interface ChildrenFilters {
  spawn_mode?: SpawnMode;
  status?: ChildPeerStatus | ChildPeerStatus[];
}
