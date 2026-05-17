import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type { PlatformHealth } from '../../types/platform-health.types';

// Aggregate platform-health snapshot for the
// /app/system/compute/platform/health panel.
//
// Plan reference: Decentralized Federation §I + P7.2.

export const platformHealthApi = {
  show: async (): Promise<PlatformHealth> => {
    const response = await apiClient.get<ApiEnvelope<{ health: PlatformHealth }>>(
      '/system/platform/health',
    );
    return extractData(response).health;
  },
};
