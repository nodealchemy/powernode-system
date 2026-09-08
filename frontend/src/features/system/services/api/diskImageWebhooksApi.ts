// API client for per-account, per-pipeline disk-image webhook secrets.
//
// Operators provision one of these per CI repo. The plaintext secret
// is returned EXACTLY ONCE on create + rotate — UI must capture and
// display it for the operator to copy into their CI's secret manager.
// Subsequent list/show responses only include secret_preview (first
// 8 chars) for disambiguation.
//
// Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 4).
import { apiClient } from '@/shared/services/apiClient';
import type {
  SystemDiskImageWebhook,
  SystemDiskImageWebhookCreatedResponse,
} from '@system/features/system/types/system.types';
import { extractData, extractGated } from './helpers';
import type { Deleted, Gated } from './helpers';
import type { ApiEnvelope } from './types';

export const diskImageWebhooksApi = {
  list: async (): Promise<SystemDiskImageWebhook[]> => {
    const response = await apiClient.get<ApiEnvelope<{
      disk_image_webhooks: SystemDiskImageWebhook[];
    }>>('/system/disk_image_webhooks');
    return extractData(response).disk_image_webhooks ?? [];
  },

  get: async (id: string): Promise<SystemDiskImageWebhook> => {
    const response = await apiClient.get<ApiEnvelope<{
      disk_image_webhook: SystemDiskImageWebhook;
    }>>(`/system/disk_image_webhooks/${id}`);
    return extractData(response).disk_image_webhook;
  },

  // Returns plaintext secret + absolute webhook URL EXACTLY ONCE.
  // Caller MUST display these to the operator and confirm save before
  // dismissing the modal — there's no recovery path.
  create: async (label: string): Promise<SystemDiskImageWebhookCreatedResponse> => {
    const response = await apiClient.post<ApiEnvelope<SystemDiskImageWebhookCreatedResponse>>(
      '/system/disk_image_webhooks',
      { label },
    );
    return extractData(response);
  },

  // GATED, same as rotateSecret. The body was discarded entirely, so a revoke
  // parked awaiting approval was indistinguishable from one that happened and
  // the caller toasted "revoked" over a still-live credential.
  destroy: async (id: string): Promise<Gated<Deleted>> => {
    const response = await apiClient.delete<ApiEnvelope<Deleted>>(
      `/system/disk_image_webhooks/${id}`,
    );
    return extractGated(response, (): Deleted => ({ deleted: true }));
  },

  // Returns NEW plaintext secret EXACTLY ONCE. Old secret is revoked
  // immediately — operator must update CI before the next webhook fires.
  //
  // GATED: the server wraps this in gate!, so under a require_approval policy it
  // answers 202 with the approval envelope and no secret at all.
  //
  // The runtime behaviour here is unchanged — extractData already passed the
  // envelope through. What was wrong was the declared TYPE: this claimed a
  // created-response unconditionally, so the caller could feed the envelope to
  // the one-time secret modal with no compile error and crash on the absent
  // webhook. extractGated states the contract the server actually has
  // (IMP-50d629fafd45).
  rotateSecret: async (
    id: string,
  ): Promise<Gated<SystemDiskImageWebhookCreatedResponse>> => {
    const response = await apiClient.post<ApiEnvelope<SystemDiskImageWebhookCreatedResponse>>(
      `/system/disk_image_webhooks/${id}/rotate_secret`,
      {},
    );
    return extractGated(response, (d) => d);
  },
};
