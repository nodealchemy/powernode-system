// FederationCapability types — mirrors per-peer capabilities CRUD
// response shape for the CapabilitiesManagementModal at
// /app/system/compute/platform/peers → peer detail → Capabilities.
//
// Plan reference: Decentralized Federation §D + §I + P4 + P7.6.

export type CapabilityDirection =
  | 'push_local_to_remote'
  | 'pull_remote_to_local'
  | 'bidirectional'
  | 'migration_only';

export type CapabilityPolicy =
  | 'manual'
  | 'auto_on_change'
  | 'auto_periodic'
  | 'on_match_filter';

export type CapabilityConflictResolution =
  | 'local_wins'
  | 'remote_wins'
  | 'prompt'
  | 'newer_wins_logical_clock';

export interface FederationCapability {
  id: string;
  federation_peer_id: string;
  resource_kind: string;
  direction: CapabilityDirection;
  policy: CapabilityPolicy;
  filter: Record<string, unknown>;
  conflict_resolution: CapabilityConflictResolution;
  last_synced_at: string | null;
  sync_cursor: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

export interface CreateCapabilityRequest {
  resource_kind: string;
  direction: CapabilityDirection;
  policy: CapabilityPolicy;
  filter?: Record<string, unknown> | string;
  conflict_resolution?: CapabilityConflictResolution;
}

export interface CapabilitiesListResponse {
  capabilities: FederationCapability[];
  count: number;
}
