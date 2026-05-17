// Federated Service Delivery types (mirror of System::Federation::ServiceOffering
// + ServiceSubscription Ruby models). Plan reference: Decentralized
// Federation §L + P4.6.

export type ServiceProtocol = 'https' | 'http' | 'tcp' | 'tls';
export type OfferingStatus = 'draft' | 'active' | 'deprecated' | 'retired';
export type SubscriptionStatus = 'pending' | 'active' | 'suspended' | 'cancelled';
export type GrantScope = 'read' | 'write' | 'admin' | 'migrate';

export interface CapacityMetadata {
  max_subscribers?: number;
  // Free-form for forward-compatibility; operators may add their own
  // capacity dimensions (max_concurrent_connections, region_support, etc.).
  [key: string]: unknown;
}

export interface LatencyMetadata {
  p50_ms?: number;
  p95_ms?: number;
  region?: string;
  [key: string]: unknown;
}

// === Operator-side: ServiceOffering ===

export interface ServiceOffering {
  id: string;
  slug: string;
  name: string;
  protocol: ServiceProtocol;
  status: OfferingStatus;
  backend_host: string | null;
  backend_port: number;
  backend_vip_id: string | null;
  default_grant_ttl_days: number;
  default_grant_scopes: GrantScope[];
  capacity_metadata: CapacityMetadata;
  latency_metadata: LatencyMetadata;
  accepting_new_subscriptions: boolean;
  active_subscription_count: number;
  created_at: string;
  updated_at: string;
  // Only present when fetched via the full-detail show endpoint
  description_markdown?: string | null;
  subscription_terms_markdown?: string | null;
  deprecated_at?: string | null;
  retired_at?: string | null;
  metadata?: Record<string, unknown>;
}

export interface ServiceOfferingCreate {
  slug: string;
  name: string;
  protocol: ServiceProtocol;
  backend_port: number;
  backend_host?: string;
  backend_vip_id?: string;
  description_markdown?: string;
  subscription_terms_markdown?: string;
  default_grant_ttl_days?: number;
  default_grant_scopes?: GrantScope[];
  capacity_metadata?: CapacityMetadata;
  latency_metadata?: LatencyMetadata;
  metadata?: Record<string, unknown>;
}

// slug is intentionally absent — server-side update permit-list omits it,
// since renaming the slug would orphan existing subscriptions.
export type ServiceOfferingUpdate = Omit<Partial<ServiceOfferingCreate>, 'slug'>;

export interface ServiceOfferingsListResponse {
  offerings: ServiceOffering[];
  count: number;
}

export interface ServiceOfferingFilters {
  status?: OfferingStatus | OfferingStatus[];
}

// === Subscriber-side: ServiceSubscription ===

export interface ServiceSubscription {
  id: string;
  service_offering_slug: string;
  service_offering_id: string | null;
  federation_peer_id: string;
  local_hostname: string;
  protocol: ServiceProtocol;
  backend_port: number;
  status: SubscriptionStatus;
  site_local: boolean;
  subscribed_at: string;
  activated_at: string | null;
  // Only present when fetched via the full-detail show endpoint
  backend_vip?: string | null;
  federation_grant_id?: string;
  acme_certificate_id?: string | null;
  suspended_at?: string | null;
  cancelled_at?: string | null;
  metadata?: Record<string, unknown>;
}

export interface ServiceSubscriptionsListResponse {
  subscriptions: ServiceSubscription[];
  count: number;
}

export interface ServiceSubscriptionFilters {
  status?: SubscriptionStatus | SubscriptionStatus[];
  peer_id?: string;
}

// === Catalog browse (subscriber view of a remote peer's offerings) ===
//
// This is the SHAPE the federation_api/service_catalog endpoint returns
// — not the same as the operator's own offerings list. Subscribers
// CAN see a subset of fields (no backend_host/backend_vip) and the
// catalog is fetched via a per-peer admin API that proxies to the
// remote operator's federation_api.

export interface RemoteCatalogOffering {
  slug: string;
  name: string;
  description_markdown: string | null;
  protocol: ServiceProtocol;
  backend_port: number;
  capacity_metadata: CapacityMetadata;
  latency_metadata: LatencyMetadata;
  subscription_terms_markdown: string | null;
  default_grant_ttl_days: number;
  default_grant_scopes: GrantScope[];
  status: OfferingStatus;
  accepting_new_subscriptions: boolean;
}

export interface RemoteCatalogResponse {
  offerings: RemoteCatalogOffering[];
  generated_at: string;
}
