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
  // null when nothing was measured (AttributeFailureExecutor) -- never 0,
  // which would claim "looked and found nothing". Renderers must show "not
  // measured" for null, never coalesce it to 0 or a 0% badge.
  confidence: number | null;
  reasoning: string;
}

// IMP-01a05ae8 — GET /system/fleet/remediation_outcomes. effectiveness_rate is
// effective / (effective + ineffective); null when nothing has settled yet.
export interface RemediationStatusCounts {
  pending: number;
  effective: number;
  ineffective: number;
  inconclusive: number;
  settled: number;
  effectiveness_rate: number | null;
}

export interface RemediationKindSummary extends RemediationStatusCounts {
  signal_kind: string;
}

// A fingerprint the DecisionEngine is escalating as stuck right now (its
// consecutive-ineffective streak has reached the threshold).
export interface StuckRemediation {
  fingerprint: string;
  signal_kind: string;
  streak: number;
  last_validated_at: string | null;
}

export interface RemediationOutcomesSummary {
  window_days: number;
  since: string;
  kinds: RemediationKindSummary[];
  totals: RemediationStatusCounts;
  stuck: { threshold: number; fingerprints: StuckRemediation[] };
}

export const fleetApi = {
  // Fetch recent fleet events. Initial backlog before subscribing live.
  // The three id filters match the event's TYPED column (never a payload
  // key) and narrow the caller's account scope; several combine with AND.
  // The server refuses a malformed id with 422 rather than matching the
  // events that recorded no entity.
  recentSignals: async (params: {
    limit?: number;
    kind?: string;
    correlation_id?: string;
    node_instance_id?: string;
    node_module_id?: string;
    certificate_id?: string;
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

  // Remediation effectiveness per signal kind + currently stuck fingerprints.
  remediationOutcomes: async (windowDays = 7): Promise<RemediationOutcomesSummary> => {
    const response = await apiClient.get<ApiEnvelope<RemediationOutcomesSummary>>(
      `/system/fleet/remediation_outcomes?window_days=${encodeURIComponent(String(windowDays))}`
    );
    return extractData(response);
  },
};
