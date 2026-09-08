import { apiClient } from '@/shared/services/apiClient';
import type { SystemNode, SystemNodeInstance } from '../../types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface NodeFilters extends PaginationParams {
  enabled?: boolean;
}

export interface NodeCreate {
  name: string;
  description?: string;
  enabled?: boolean;
  allocate_public_ip?: boolean;
  node_template_id?: string;
  config?: Record<string, unknown>;
}

export interface NodeInstanceCreate {
  name: string;
  description?: string;
  variety?: 'cloud' | 'physical' | 'dynamic';
  status?: string;
  private_ip_address?: string;
  public_ip_address?: string;
  vpn_ip_address?: string;
  config?: Record<string, unknown>;
}

export const nodesApi = {
  getNodes: async (params?: NodeFilters): Promise<{ nodes: SystemNode[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<PaginatedEnvelope<{ nodes: SystemNode[] }>>(
      '/system/nodes',
      { params }
    );
    return extractPaginated(response);
  },

  getNode: async (id: string): Promise<SystemNode> => {
    const response = await apiClient.get<ApiEnvelope<{ node: SystemNode }>>(
      `/system/nodes/${id}`
    );
    return extractData(response).node;
  },

  createNode: async (data: NodeCreate): Promise<SystemNode> => {
    const response = await apiClient.post<ApiEnvelope<{ node: SystemNode }>>(
      '/system/nodes',
      { node: data }
    );
    return extractData(response).node;
  },

  updateNode: async (id: string, data: Partial<NodeCreate>): Promise<SystemNode> => {
    const response = await apiClient.put<ApiEnvelope<{ node: SystemNode }>>(
      `/system/nodes/${id}`,
      { node: data }
    );
    return extractData(response).node;
  },

  deleteNode: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/nodes/${id}`);
  },

  getNodeInstances: async (nodeId: string): Promise<{ node_instances: SystemNodeInstance[] }> => {
    const response = await apiClient.get<ApiEnvelope<{ node_instances: SystemNodeInstance[] }>>(
      `/system/nodes/${nodeId}/node_instances`
    );
    return { node_instances: extractData(response).node_instances ?? [] };
  },

  getNodeInstance: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.get<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}`
    );
    return extractData(response).node_instance;
  },

  createNodeInstance: async (nodeId: string, data: NodeInstanceCreate): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances`,
      { node_instance: data }
    );
    return extractData(response).node_instance;
  },

  updateNodeInstance: async (
    nodeId: string,
    instanceId: string,
    data: Partial<NodeInstanceCreate>
  ): Promise<SystemNodeInstance> => {
    const response = await apiClient.put<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}`,
      { node_instance: data }
    );
    return extractData(response).node_instance;
  },

  deleteNodeInstance: async (nodeId: string, instanceId: string): Promise<void> => {
    await apiClient.delete(`/system/nodes/${nodeId}/node_instances/${instanceId}`);
  },

  startInstance: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/start`
    );
    return extractData(response).node_instance;
  },

  stopInstance: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/stop`
    );
    return extractData(response).node_instance;
  },

  rebootInstance: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/reboot`
    );
    return extractData(response).node_instance;
  },

  terminateInstance: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/terminate`
    );
    return extractData(response).node_instance;
  },

  associatePublicIp: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/associate_public_ip`
    );
    return extractData(response).node_instance;
  },

  disassociatePublicIp: async (nodeId: string, instanceId: string): Promise<SystemNodeInstance> => {
    const response = await apiClient.post<ApiEnvelope<{ node_instance: SystemNodeInstance }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/disassociate_public_ip`
    );
    return extractData(response).node_instance;
  },

  /**
   * Re-apply the node's template: materializes any TemplateModule the node is
   * missing, and — only when `purge_stale` is set — removes assignments the
   * template no longer carries.
   *
   * Both flags are always sent explicitly rather than omitted. The backend
   * casts them with ActiveModel::Type::Boolean, where a missing key and a
   * `false` both read as false today, but a destructive flag should never
   * depend on that equivalence holding.
   *
   * `dry_run: true` computes the same plan and persists nothing, which is what
   * makes the mandatory preview step real rather than advisory.
   */
  applyTemplate: async (
    id: string,
    options: { dry_run?: boolean; purge_stale?: boolean } = {}
  ): Promise<TemplateApplyResult> => {
    const response = await apiClient.post<ApiEnvelope<TemplateApplyResult>>(
      `/system/nodes/${id}/apply_template`,
      { dry_run: options.dry_run ?? false, purge_stale: options.purge_stale ?? false }
    );
    return extractData(response);
  },

  /**
   * Read the instance's Claude Code credential INDEX CARD — id, kind,
   * presence and timestamps. The plaintext is never in this response: the
   * controller's serializer deliberately omits it and the Vault path both.
   *
   * A 404 means "no credential configured", which is an ordinary state, so it
   * becomes `null`. Nothing else is swallowed — in particular a 403 says the
   * caller may not READ the credential, and reporting that as "not configured"
   * would tell the operator the opposite of the truth.
   */
  getClaudeCodeCredential: async (
    nodeId: string,
    instanceId: string
  ): Promise<ClaudeCodeCredential | null> => {
    try {
      const response = await apiClient.get<ApiEnvelope<{ credential: ClaudeCodeCredential }>>(
        `/system/nodes/${nodeId}/node_instances/${instanceId}/claude_code_credential`
      );
      return extractData(response).credential;
    } catch (error) {
      // Only the CREDENTIAL's own 404 means "not configured". set_node and
      // set_instance render 404 too, and so does a wrong path — collapsing
      // those into `null` would offer a Set button that then fails, and would
      // hide a genuinely missing instance.
      const { status, data } = (error as {
        response?: { status?: number; data?: { error?: string } };
      })?.response ?? {};
      if (status === 404 && /credential/i.test(data?.error ?? '')) return null;
      throw error;
    }
  },

  /**
   * Create the credential. WRITE-ONLY by construction: the payload carries the
   * plaintext one way and the response carries only the index card back, so
   * there is no round trip a caller could read a secret out of.
   *
   * Exactly one of `api_key` / `oauth` selects the kind, matching the
   * controller's own rule; sending both is refused server-side.
   */
  setClaudeCodeCredential: async (
    nodeId: string,
    instanceId: string,
    payload: ClaudeCodeCredentialPayload
  ): Promise<ClaudeCodeCredential> => {
    const response = await apiClient.post<ApiEnvelope<{ credential: ClaudeCodeCredential }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/claude_code_credential`,
      payload
    );
    return extractData(response).credential;
  },

  /**
   * Replace the stored secret in place. The server refuses a rotation that
   * changes the KIND, because the old kind's Vault entry lives under a
   * different type path and would be orphaned — that switch is a delete plus a
   * create.
   */
  rotateClaudeCodeCredential: async (
    nodeId: string,
    instanceId: string,
    payload: ClaudeCodeCredentialPayload
  ): Promise<ClaudeCodeCredential> => {
    const response = await apiClient.post<ApiEnvelope<{ credential: ClaudeCodeCredential }>>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/claude_code_credential/rotate`,
      payload
    );
    return extractData(response).credential;
  },

  deleteClaudeCodeCredential: async (nodeId: string, instanceId: string): Promise<void> => {
    await apiClient.delete(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/claude_code_credential`
    );
  },

  /**
   * Download the per-instance claim-by-ID boot config (identity.cfg) for the
   * generic-image fleet flow. Triggers a browser save using the filename from
   * the backend's Content-Disposition. Valid only for physical, unclaimed
   * instances — the endpoint returns 409 once the device has claimed it.
   */
  downloadInstanceBootConfig: async (nodeId: string, instanceId: string): Promise<void> => {
    const response = await apiClient.get<Blob>(
      `/system/nodes/${nodeId}/node_instances/${instanceId}/boot_config`,
      { responseType: 'blob' }
    );
    const disposition = response.headers?.['content-disposition'] || '';
    const match = disposition.match(/filename="?([^";]+)"?/i);
    const filename = match?.[1] || `identity-${instanceId}.cfg`;
    const blob = response.data instanceof Blob
      ? response.data
      : new Blob([String(response.data)], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  },
};

/** Outcome of POST /system/nodes/:id/apply_template, for a dry run or a real apply. */
export interface TemplateApplyResult {
  dry_run: boolean;
  created_count: number;
  skipped_count: number;
  purged_count: number;
  warnings: string[];
  errors: string[];
  created: { node_module_id: string; source_template_module_id: string | null }[];
  purged_module_ids: string[];
}

/**
 * The credential index card. Everything the operator surface may know about a
 * stored secret: that it exists, which kind it is, and when it last changed.
 * There is deliberately no field here that could hold plaintext or the Vault
 * path — the controller's serializer omits both.
 */
export interface ClaudeCodeCredential {
  id: string;
  node_instance_id: string;
  credential_kind: 'api_key' | 'oauth';
  configured: boolean;
  created_at: string;
  /** Also the rotation timestamp: a rotate writes to Vault and touches the row. */
  updated_at: string;
}

/**
 * The claudeAiOauth object out of ~/.claude/.credentials.json. `expiresAt` is
 * epoch MILLISECONDS — the server rejects an epoch-seconds value rather than
 * storing a credential that expires in 1970.
 */
export interface ClaudeCodeOauthPayload {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  refreshTokenExpiresAt?: number;
  scopes?: string[];
  subscriptionType?: string;
  [key: string]: unknown;
}

/** Exactly one of the two, matching the controller's kind selection. */
export type ClaudeCodeCredentialPayload =
  | { api_key: string; oauth?: never }
  | { oauth: ClaudeCodeOauthPayload; api_key?: never };

/**
 * The operator-facing text out of a rejected API call.
 *
 * `apiClient` rejects with the raw AxiosError, whose `.message` is only
 * "Request failed with status code 422" — the server's own sentence lives in
 * the error envelope. Reading `err.message` therefore throws away exactly the
 * field-level feedback these endpoints are careful to produce (and, for the
 * credential endpoints, are careful to write naming FIELDS rather than values).
 *
 * Local rather than core's getErrorMessage: `@/shared/services/errorHandler` is
 * not in the host-app allowlist, so importing it would pass tsc and jest and
 * then break the extension's module build.
 */
export function apiErrorMessage(error: unknown, fallback: string): string {
  const serverMessage = (error as { response?: { data?: { error?: string } } })?.response?.data?.error;
  if (typeof serverMessage === 'string' && serverMessage.trim()) return serverMessage;
  return error instanceof Error && error.message ? error.message : fallback;
}
