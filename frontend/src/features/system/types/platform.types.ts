// Types for the /app/system/compute/platform unified-ops dashboard.
// Plan reference: Decentralized Federation §I + P7.

export interface PlatformPeersSummary {
  count: number;
  by_status: Record<string, number>;
  last_handshake_at: string | null;
}

export interface PlatformChildrenSummary {
  count: number;
  by_spawn_mode?: Record<string, number>;
  by_status?: Record<string, number>;
}

export interface PlatformServicesSummary {
  offerings: number;
  subscriptions: number;
}

export interface PlatformMigrationsSummary {
  count: number;
  by_status?: Record<string, number>;
}

export interface PlatformCertificatesSummary {
  count: number;
  by_status?: Record<string, number>;
  near_expiry: number;
}

export interface PlatformOverview {
  peers: PlatformPeersSummary;
  children: PlatformChildrenSummary;
  services: PlatformServicesSummary;
  migrations: PlatformMigrationsSummary;
  certificates: PlatformCertificatesSummary;
  generated_at: string;
}
