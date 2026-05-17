import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type { PlatformOverview } from '../../types/platform.types';

// Aggregate read for the Platform dashboard's header.
// Plan reference: Decentralized Federation §I + P7.

export const platformApi = {
  overview: async (): Promise<PlatformOverview> => {
    const response = await apiClient.get<ApiEnvelope<{ overview: PlatformOverview }>>(
      '/system/platform/overview',
    );
    return extractData(response).overview;
  },
};
