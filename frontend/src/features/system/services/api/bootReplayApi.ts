import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export interface BootEvent {
  id: string;
  kind: string;
  severity: string;
  payload: Record<string, unknown>;
  emitted_at: string;
  correlation_id?: string | null;
  source?: string | null;
}

export interface BootPhaseSummary {
  first_at: string;
  last_at: string;
  count: number;
}

export interface BootReplayResponse {
  events: BootEvent[];
  instance_id: string;
  phase_summary: Record<string, BootPhaseSummary>;
}

export interface BootReplayParams {
  instance_id: string;
  correlation_id?: string;
  limit?: number;
}

export const bootReplayApi = {
  async fetch(params: BootReplayParams): Promise<BootReplayResponse> {
    const search = new URLSearchParams();
    search.set('instance_id', params.instance_id);
    if (params.correlation_id) search.set('correlation_id', params.correlation_id);
    if (params.limit) search.set('limit', String(params.limit));
    const url = `/system/fleet/boot_replay?${search.toString()}`;
    const response = await apiClient.get<ApiEnvelope<BootReplayResponse>>(url);
    return extractData(response);
  },
};
