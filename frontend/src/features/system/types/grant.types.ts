// FederationGrant types — mirrors per-peer grants CRUD response shape
// for the GrantsManagementModal at /app/system/compute/platform/peers
// → peer detail → Grants.
//
// Plan reference: Decentralized Federation §E + §I + P4 + P7.5.

export type GrantScope = 'read' | 'write' | 'admin' | 'migrate';
export type GrantLifecycle = 'active' | 'expired' | 'revoked' | 'archived';

export interface FederationGrant {
  id: string;
  federation_peer_id: string;
  remote_subject: string;
  resource_kind: string;
  resource_id: string | null;
  permission_scopes: GrantScope[];
  lifecycle: GrantLifecycle;
  issued_at: string;
  expires_at: string;
  revoked_at: string | null;
  revocation_reason: string | null;
  archived_at: string | null;
  node_instance_ids: string[];
  sdwan_network_ids: string[];
  source_cidrs: string[];
  unrestricted: boolean;
  grantor_user_id: string | null;
  bearer_token_preview: string | null;
}

export interface IssueGrantRequest {
  resource_kind: string;
  resource_id?: string;
  remote_subject: string;
  permission_scopes: GrantScope[];
  ttl_days?: number;
  node_instance_ids?: string[];
  sdwan_network_ids?: string[];
  source_cidrs?: string[];
}

export interface GrantsListResponse {
  grants: FederationGrant[];
  count: number;
}
