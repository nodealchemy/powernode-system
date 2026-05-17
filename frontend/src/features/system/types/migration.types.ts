// Migration types — mirrors /api/v1/system/platform/migrations
// response shape. Operator-facing read-only in v1; full creation
// wizard ships in a follow-up slice.
//
// Plan reference: Decentralized Federation §F + §I + P5 + P7.4.

export type MigrationOperation = 'duplicate' | 'migrate';

export type MigrationStatus =
  | 'planned'
  | 'validating'
  | 'transferring'
  | 'conflict'
  | 'applying'
  | 'completed'
  | 'failed'
  | 'cancelled';

export interface MigrationSummary {
  id: string;
  operation: MigrationOperation;
  status: MigrationStatus;
  root_resource_kind: string;
  root_resource_id: string | null;
  dry_run: boolean;
  destination_peer_id: string | null;
  step_count: number;
  total_steps: number;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  failed_at: string | null;
  cancelled_at: string | null;
  terminal: boolean;
  error_message: string | null;
}

export interface MigrationConflictEntry {
  kind?: string;
  message?: string;
  resource_kind?: string;
  resource_id?: string;
  detected_at?: string;
  [key: string]: unknown;
}

export interface MigrationAuditEntry {
  at?: string;
  event?: string;
  message?: string;
  [key: string]: unknown;
}

export interface MigrationDetail extends MigrationSummary {
  plan_summary: Record<string, unknown>;
  conflict_log: MigrationConflictEntry[];
  audit_log: MigrationAuditEntry[];
  metadata: Record<string, unknown>;
  initiated_by_user_id: string | null;
}

export interface MigrationListResponse {
  migrations: MigrationSummary[];
  count: number;
}

export interface MigrationListFilters {
  status?: MigrationStatus | MigrationStatus[];
  operation?: MigrationOperation;
}
