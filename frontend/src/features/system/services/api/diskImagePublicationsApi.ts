// API client for the disk-image publication history surface.
//
// Operators use this to:
//   - List a platform's publication history (DiskImageHistoryTab)
//   - View a specific publication's full payload + attestation
//   - Roll back the platform pointer to a prior publication
//
// Plan: docs/plans/wondrous-yawning-anchor.md (Phase 2 — Chunk 4).
import { apiClient } from '@/shared/services/apiClient';
import type {
  SystemDiskImagePublication,
} from '@system/features/system/types/system.types';
import { extractData, extractPaginated } from './helpers';
import type { ApiEnvelope, PaginatedEnvelope, PaginationMeta, PaginationParams } from './types';

export interface ListPublicationsResponse {
  publications: SystemDiskImagePublication[];
  meta?: PaginationMeta;
}

export const diskImagePublicationsApi = {
  list: async (
    platformId: string,
    params?: PaginationParams,
  ): Promise<ListPublicationsResponse> => {
    const response = await apiClient.get<PaginatedEnvelope<{
      disk_image_publications: SystemDiskImagePublication[];
    }>>(
      `/system/node_platforms/${platformId}/disk_image_publications`,
      { params },
    );
    const result = extractPaginated(response);
    return {
      publications: result.disk_image_publications ?? [],
      meta: result.meta,
    };
  },

  get: async (platformId: string, publicationId: string): Promise<SystemDiskImagePublication> => {
    const response = await apiClient.get<ApiEnvelope<{
      disk_image_publication: SystemDiskImagePublication;
    }>>(
      `/system/node_platforms/${platformId}/disk_image_publications/${publicationId}`,
    );
    return extractData(response).disk_image_publication;
  },

  // POST /api/v1/system/node_platforms/:platform_id/rollback_disk_image
  // Activates a prior publication. Refuses purged publications.
  rollback: async (
    platformId: string,
    publicationId: string,
  ): Promise<{ activated_publication_id: string; prior_file_object_id?: string }> => {
    const response = await apiClient.post<ApiEnvelope<{
      activated_publication_id: string;
      prior_file_object_id?: string;
    }>>(
      `/system/node_platforms/${platformId}/rollback_disk_image`,
      { publication_id: publicationId },
    );
    return extractData(response);
  },
};
