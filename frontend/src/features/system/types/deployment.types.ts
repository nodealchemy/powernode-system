// PlatformDeployment types — mirrors
// /api/v1/system/platform/deployments response shape.
//
// Plan reference: Decentralized Federation §G + §I + P7.3.

export type ServiceRole =
  | 'api'
  | 'worker'
  | 'frontend'
  | 'postgres'
  | 'redis'
  | 'reverse-proxy'
  | 'satellite-runtime';

export interface DeploymentSummary {
  id: string;
  name: string;
  service_role: ServiceRole;
  target_replicas: number;
  actual_replicas: number;
  actual_by_status: Record<string, number>;
  public_dns_hostname: string | null;
  satellite_extension_slug: string | null;
  node_template: {
    id: string;
    name: string;
    slug: string | null;
  } | null;
  virtual_ip: {
    id: string;
    cidr: string;
    preferred_endpoint: string | null;
  } | null;
  metadata: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

export interface DeploymentListResponse {
  deployments: DeploymentSummary[];
  count: number;
}

export interface DeploymentUpdateRequest {
  target_replicas?: number;
  public_dns_hostname?: string | null;
}
