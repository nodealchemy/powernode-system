import { apiClient } from '@/shared/services/apiClient';
import { extractData, paramsFromFilters } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  MigrationChainAdvanceResult,
  MigrationChainDetail,
  MigrationChainListFilters,
  MigrationChainListResponse,
} from '../../types/migrationChain.types';

// Operator-side API client for multi-hop migration chains (P9.5).
//
// Permissions, per the controller:
//   system.platform.read     — list + get
//   system.migrations.apply  — create + advance + run
//   system.migrations.cancel — cancel
//
// None of these routes are routed through Ai::AutonomyGate — the controller
// renders its success body directly rather than through gate!, so there is no
// pending-approval branch to model here and no Gated<T>.
//
// The composer route (POST, `system.migrations.apply`) is deliberately NOT
// wired here. Nothing composes a chain from the console yet, and its contract
// has a trap worth building against rather than guessing at: hop_peer_ids
// carries destinations only and the origin is prepended server-side, because
// ActionDispatch deep-munges a leading null out of the array. An untested
// client method encoding that would rot before it had a caller.
//
// Plan reference: Decentralized Federation §F + P9.5.

const BASE = '/system/platform/migration_chains';

export const platformMigrationChainsApi = {
  list: async (filters?: MigrationChainListFilters): Promise<MigrationChainListResponse> => {
    const response = await apiClient.get<ApiEnvelope<MigrationChainListResponse>>(BASE, {
      params: paramsFromFilters(filters),
    });
    return extractData(response);
  },

  get: async (id: string): Promise<MigrationChainDetail> => {
    const response = await apiClient.get<ApiEnvelope<{ migration_chain: MigrationChainDetail }>>(
      `${BASE}/${id}`,
    );
    return extractData(response).migration_chain;
  },

  /** Advance by exactly one hop. */
  advance: async (id: string): Promise<MigrationChainAdvanceResult> => {
    const response = await apiClient.post<ApiEnvelope<MigrationChainAdvanceResult>>(
      `${BASE}/${id}/advance`,
      {},
    );
    return extractData(response);
  },

  /**
   * Walk to completion, or to the first failure. SYNCHRONOUS on the server —
   * the controller's own comment says it expects short chains and that long
   * ones should be left to the worker's 60s advance tick.
   */
  run: async (id: string): Promise<MigrationChainAdvanceResult> => {
    const response = await apiClient.post<ApiEnvelope<MigrationChainAdvanceResult>>(
      `${BASE}/${id}/run`,
      {},
    );
    return extractData(response);
  },

  /** planned → cancelled (terminal). in_flight is refused with 422 — MigrationChain::TRANSITIONS is the authority. */
  cancel: async (id: string): Promise<MigrationChainDetail> => {
    const response = await apiClient.post<ApiEnvelope<{ migration_chain: MigrationChainDetail }>>(
      `${BASE}/${id}/cancel`,
      {},
    );
    return extractData(response).migration_chain;
  },
};
