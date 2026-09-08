// Multi-hop migration chain types (P9.5) — mirrors
// /api/v1/system/platform/migration_chains.
//
// A chain envelopes N-1 ordinary System::Migration rows, one per hop. The
// composer creates the envelope plus its hop rows in `planned`; the worker
// (MigrationChainAdvanceJob) sweeps active chains every 60s and advances them
// one hop at a time. Operators can also advance, run to completion, or cancel
// on demand.
//
// Plan reference: Decentralized Federation §F + P9.5.

import type { MigrationOperation, MigrationStatus } from './migration.types';

/**
 * Chain lifecycle. This is NOT the migration lifecycle: a chain has one extra
 * state (`in_flight`) and lacks the per-migration working states
 * (validating / transferring / conflict / applying), which belong to the hop
 * rows the chain envelopes.
 *
 * Mirrors System::MigrationChain::STATUSES.
 */
export type MigrationChainStatus =
  | 'planned'
  | 'in_flight'
  | 'completed'
  | 'failed'
  | 'cancelled';

export interface MigrationChainSummary {
  id: string;
  operation: MigrationOperation;
  status: MigrationChainStatus;
  root_resource_kind: string;
  root_resource_id: string | null;
  /** 0-based index of the hop the chain is at; `total_hops` when finished. */
  current_hop_index: number;
  total_hops: number;
  terminal: boolean;
  error_message: string | null;
  created_at: string | null;
  started_at: string | null;
  completed_at: string | null;
  failed_at: string | null;
}

/**
 * One hop: a System::Migration row, serialized down to the fields the chain
 * view needs. `status` is the MIGRATION lifecycle, which is why the hop list
 * reuses the migrations panel's own status pill rather than the chain one.
 */
export interface MigrationChainHop {
  id: string;
  chain_position: number;
  status: MigrationStatus;
  destination_peer_id: string | null;
  started_at: string | null;
  completed_at: string | null;
  failed_at: string | null;
  error_message: string | null;
}

export interface MigrationChainAuditEntry {
  at?: string;
  event?: string;
  message?: string;
  [key: string]: unknown;
}

export interface MigrationChainDetail extends MigrationChainSummary {
  /**
   * Peers in hop order, INCLUDING the implicit origin at position 0, which the
   * server serializes as null ("self"). The create endpoint takes only the
   * destinations and prepends the origin itself.
   */
  hop_peer_ids: Array<string | null>;
  hops: MigrationChainHop[];
  audit_log: MigrationChainAuditEntry[];
  metadata: Record<string, unknown>;
  initiated_by_user_id: string | null;
}

export interface MigrationChainListResponse {
  migration_chains: MigrationChainSummary[];
  count: number;
}

export interface MigrationChainListFilters {
  status?: MigrationChainStatus | MigrationChainStatus[];
  operation?: MigrationOperation;
}

/** advance / run answer with the chain plus how far it got. */
export interface MigrationChainAdvanceResult {
  migration_chain: MigrationChainDetail;
  advanced_to: number | null;
}
