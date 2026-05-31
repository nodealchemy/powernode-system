import { apiClient } from '@/shared/services/apiClient';
import type { SystemNodePlatform } from '../../types/system.types';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export interface PlatformCreate {
  name: string;
  description?: string;
  node_architecture_id?: string;
  build_script?: string;
  init_script?: string;
  sync_script?: string;
  enabled?: boolean;
  public?: boolean;
}

export const platformsApi = {
  getPlatforms: async (): Promise<SystemNodePlatform[]> => {
    const response = await apiClient.get<ApiEnvelope<{ node_platforms: SystemNodePlatform[] }>>(
      '/system/node_platforms'
    );
    return extractData(response).node_platforms ?? [];
  },

  getPlatform: async (id: string): Promise<SystemNodePlatform> => {
    const response = await apiClient.get<ApiEnvelope<{ node_platform: SystemNodePlatform }>>(
      `/system/node_platforms/${id}`
    );
    return extractData(response).node_platform;
  },

  createPlatform: async (data: PlatformCreate): Promise<SystemNodePlatform> => {
    const response = await apiClient.post<ApiEnvelope<{ node_platform: SystemNodePlatform }>>(
      '/system/node_platforms',
      { node_platform: data }
    );
    return extractData(response).node_platform;
  },

  updatePlatform: async (
    id: string,
    data: Partial<PlatformCreate>
  ): Promise<SystemNodePlatform> => {
    const response = await apiClient.put<ApiEnvelope<{ node_platform: SystemNodePlatform }>>(
      `/system/node_platforms/${id}`,
      { node_platform: data }
    );
    return extractData(response).node_platform;
  },

  deletePlatform: async (id: string): Promise<void> => {
    await apiClient.delete(`/system/node_platforms/${id}`);
  },

  /**
   * Download the platform's published generic disk image (.img) for the
   * claim-by-ID fleet flow. Triggers a browser save using the backend's
   * Content-Disposition filename. Only meaningful when the platform's
   * disk_image_publication_status is "published" (else the endpoint 404s).
   */
  downloadDiskImage: async (id: string): Promise<void> => {
    const response = await apiClient.get<Blob>(
      `/system/node_platforms/${id}/disk_image`,
      { responseType: 'blob' }
    );
    const disposition = response.headers?.['content-disposition'] || '';
    const match = disposition.match(/filename="?([^";]+)"?/i);
    const filename = match?.[1] || `powernode-${id}.img`;
    const blob = response.data instanceof Blob
      ? response.data
      : new Blob([response.data as BlobPart], { type: 'application/octet-stream' });
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
