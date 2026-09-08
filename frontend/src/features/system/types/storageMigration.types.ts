// Storage migration types — mirrors the
// /api/v1/system/platform/storage_migrations response shape.
//
// Distinct from federation migrations (which transfer records between
// peer platforms): a storage migration moves a stateful component's
// data from one ProviderVolume to another on a single instance.
//
// Plan reference: E8 follow-on / E8.2 (operator UI).

export type StorageMigrationStatus =
  | 'planned'
  | 'approved'
  | 'preparing'
  | 'syncing'
  | 'verifying'
  | 'cutover'
  | 'completed'
  | 'failed'
  | 'cancelled';

export interface StorageMigrationSummary {
  id: string;
  status: StorageMigrationStatus;
  role: string;
  node_instance_id: string;
  source_volume_id: string;
  target_volume_id: string;
  source_subpath: string | null;
  target_subpath: string | null;
  bytes_copied: number | null;
  bytes_total: number | null;
  terminal: boolean;
  error_message: string | null;
  created_at: string;
  approved_at: string | null;
  started_at: string | null;
  completed_at: string | null;
  failed_at: string | null;
  cancelled_at: string | null;
}

export interface StorageMigrationAuditEntry {
  at?: string;
  message?: string;
  status_before?: string;
  status_after?: string;
  details?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface StorageMigrationDetail extends StorageMigrationSummary {
  plan: Record<string, unknown>;
  audit_log: StorageMigrationAuditEntry[];
  metadata: Record<string, unknown>;
  snapshot_subpath: string | null;
  initiated_by_user_id: string | null;
  // Per-progress-tick rsync counter surfaced in StorageMigrationDetailDrawer.
  // Nullable (not just optional) because ByteCounters explicitly types
  // verified as `number | null` and the backend returns null for
  // pre-verify-phase migrations.
  bytes_verified?: number | null;
}

/**
 * What POST :id/revert and :id/cleanup actually return.
 *
 * Those two controller actions render `result[:storage_migration]` straight
 * from the MCP tool's own serializer, NOT the controller's `serialize_full`.
 * That serializer omits `terminal` and `initiated_by_user_id`, so typing the
 * response as StorageMigrationDetail would promise two fields that are not on
 * the wire — and the first caller to read `.terminal` off one would get
 * undefined with no type error. Callers should treat the result as an
 * acknowledgement and refetch for display.
 */
export type StorageMigrationActionResult = Omit<
  StorageMigrationDetail,
  'terminal' | 'initiated_by_user_id'
>;

export interface StorageMigrationListResponse {
  storage_migrations: StorageMigrationSummary[];
  count: number;
}

export interface StorageMigrationListFilters {
  status?: StorageMigrationStatus | StorageMigrationStatus[];
  node_instance_id?: string;
  active_only?: boolean;
}

export interface CreateStorageMigrationParams {
  node_instance_id: string;
  source_volume_id: string;
  target_volume_id: string;
  role: string;
}
