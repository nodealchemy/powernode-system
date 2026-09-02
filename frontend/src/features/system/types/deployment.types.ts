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

/**
 * What System::Platform::ReplicaReconciler did after a target_replicas write.
 * Present on the PATCH response only when target_replicas actually changed.
 *
 * `ok: false` is a REFUSAL, not a transport error — the target was recorded
 * and nothing converged (missing system.instances.create, no node carrying the
 * deployment's template, no provider shape to provision into). `ok: true` with
 * `actual_after < target_replicas` is a partial pass: the reconciler clamps
 * each pass, and a scale-in whose intervention policy does not auto-execute
 * reports its victims under pending_removal_instance_ids instead of removing
 * them. Both cases must be surfaced — a save is not a scale.
 */
export interface DeploymentReconcileOutcome {
  ok: boolean;
  refused_reason: string | null;
  message: string | null;
  actual_before: number | null;
  actual_after: number | null;
  target_replicas: number | null;
  provisioned_instance_ids: string[];
  terminated_instance_ids: string[];
  pending_removal_instance_ids: string[];
  failures: Array<{ instance_id: string | null; error: string }>;
}

export interface DeploymentUpdateResponse {
  deployment: DeploymentSummary;
  reconciled?: DeploymentReconcileOutcome;
}
