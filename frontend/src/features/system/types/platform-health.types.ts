// Platform Health snapshot types — mirrors
// /api/v1/system/platform/health response shape.
//
// Plan reference: Decentralized Federation §I + P7.2.

export type SubsystemStatus = 'ok' | 'degraded' | 'down' | 'unknown';

export interface RailsHealth {
  status: SubsystemStatus;
  uptime_seconds?: number;
  uptime_human?: string;
  db_connected?: boolean;
  rails_env?: string;
  ruby_version?: string;
  error?: string;
}

export interface WorkerHealth {
  status: SubsystemStatus;
  stats: {
    processed?: number;
    failed?: number;
    enqueued?: number;
    scheduled?: number;
    retry_size?: number;
    dead_size?: number;
    processes?: number;
    default_queue_latency?: number;
  };
  last_seen_at?: string | null;
  error?: string;
}

export interface RedisHealth {
  status: SubsystemStatus;
  cache_store?: string;
  probe_at?: string;
  error?: string;
}

export interface PostgresHealth {
  status: SubsystemStatus;
  database?: string;
  size_bytes?: number;
  size_human?: string;
  active_connections?: number;
  error?: string;
}

export interface AcmeHealth {
  status: SubsystemStatus;
  count?: number;
  by_status?: Record<string, number>;
  expiring_within_30d?: number;
  expiring_within_7d?: number;
  failed_count?: number;
  nearest_expiry_at?: string | null;
  error?: string;
}

export interface SdwanHealth {
  status: SubsystemStatus;
  networks_count?: number;
  virtual_ips?: { count: number; assigned: number };
  bgp?: { total: number | null; established: number | null };
  error?: string;
}

export interface FederationHealth {
  status: SubsystemStatus;
  total?: number;
  active?: number;
  degraded?: number;
  suspended?: number;
  heartbeat_stale?: number;
  last_handshake_at?: string | null;
  error?: string;
}

export interface PlatformHealth {
  rails: RailsHealth;
  worker: WorkerHealth;
  redis: RedisHealth;
  postgres: PostgresHealth;
  acme: AcmeHealth;
  sdwan: SdwanHealth;
  federation: FederationHealth;
  generated_at: string;
}
