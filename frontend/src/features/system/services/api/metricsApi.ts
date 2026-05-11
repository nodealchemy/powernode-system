import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export interface MetricBucket {
  ts: number;
  count: number;
}

export interface MetricStats {
  count: number;
  rate_per_sec: number;
  window_seconds: number;
  buckets: MetricBucket[];
}

export interface DispatchMetricsResponse {
  window_seconds: number;
  metrics: Record<string, MetricStats>;
}

export interface DispatchMetricsParams {
  window?: number; // seconds; capped at 3600
}

export const metricsApi = {
  async dispatch(params: DispatchMetricsParams = {}): Promise<DispatchMetricsResponse> {
    const search = new URLSearchParams();
    if (params.window) search.set('window', String(params.window));
    const qs = search.toString();
    // apiClient base URL already includes /api/v1 — sibling files use bare
    // /system/... paths. Prefixing with /api/v1 here would double the segment.
    const url = `/system/metrics/dispatch${qs ? `?${qs}` : ''}`;
    const response = await apiClient.get<ApiEnvelope<DispatchMetricsResponse>>(url);
    return extractData(response);
  },
};
