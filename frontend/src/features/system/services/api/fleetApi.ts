// Fleet observability + autonomy API surface (Golden Eclipse M7 + M-FE-3).
// Operators consume this from the Fleet Dashboard. Live updates arrive
// via SystemFleetChannel ActionCable subscription; this surface is the
// REST/RPC fallback for backlog fetch + on-demand drill-in.
import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export interface FleetEvent {
  id: string;
  account_id: string;
  kind: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  payload: Record<string, unknown>;
  correlation_id: string | null;
  source: string | null;
  emitted_at: string;
  node_id?: string | null;
  node_instance_id?: string | null;
  node_module_id?: string | null;
  node_module_version_id?: string | null;
  certificate_id?: string | null;
  cve_id?: string | null;
}

export interface AttributionCandidate {
  kind: 'assignment_change' | 'promotion' | 'event_correlation';
  module_id: string;
  module_name: string | null;
  score: number;
  reasons: string[];
  changed_at?: string;
  module_version_id?: string;
}

export interface AttributionResult {
  candidates: AttributionCandidate[];
  top_candidate: AttributionCandidate | null;
  confidence: number;
  reasoning: string;
}

export const fleetApi = {
  // Fetch recent fleet events. Initial backlog before subscribing live.
  recentSignals: async (params: {
    limit?: number;
    kind?: string;
    correlation_id?: string;
  } = {}): Promise<{ events: FleetEvent[]; count: number; channel: string }> => {
    const response = await apiClient.post<ApiEnvelope<{
      events: FleetEvent[];
      count: number;
      channel: string;
    }>>('/system/fleet/signals', params);
    return extractData(response);
  },

  // Attribute a failed instance to its likely-cause changes.
  attributeFailure: async (instanceId: string, lookbackHours = 24): Promise<AttributionResult> => {
    const response = await apiClient.post<ApiEnvelope<AttributionResult>>(
      '/system/fleet/attribute_failure',
      { instance_id: instanceId, lookback_hours: lookbackHours }
    );
    return extractData(response);
  },
};
