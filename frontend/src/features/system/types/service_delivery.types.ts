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

// ---------------------------------------------------------------------------
// Capability fulfillment (campaign 019f6084 inc-M)
// ---------------------------------------------------------------------------
//
// A FulfillmentRequest is composed with its plan FROZEN. Every state after
// `approved` is driven by the 60s worker sweep; `composed` is deliberately
// excluded from it, because that edge waits on a human. Approving releases the
// frozen plan verbatim — it is never re-composed — so the operator has to be
// able to read those exact bytes first (IMP-3fd7f5c67a7b).

export type FulfillmentRequestState =
  | 'composed'
  | 'approved'
  | 'materializing'
  | 'building'
  | 'templated'
  | 'provisioning'
  | 'smoking'
  | 'ready'
  | 'failed'
  | 'expired';

/**
 * A park the executor recorded — including a withheld autonomous approval.
 * This is a CUMULATIVE trail: add_park! appends and never clears, so a
 * non-empty `parked` says something was noted at some point, NOT that the
 * latest advance parked. `step` names which stage recorded it.
 */
export interface FulfillmentPark {
  step?: string;
  reason?: string;
  at?: string;
  [key: string]: unknown;
}

/** A capability the composer could not resolve. Shown to the approver, never filtered. */
export interface FulfillmentUnresolvedGap {
  capability?: string;
  reason?: string;
  [key: string]: unknown;
}

/** The replayable context approve releases as-is. */
export interface FulfillmentExecutionPlan {
  base_os_module_id?: string;
  reused_module_ids?: string[];
  gaps?: Array<Record<string, unknown>>;
  template_name?: string;
  [key: string]: unknown;
}

export interface FulfillmentPlan {
  execution?: FulfillmentExecutionPlan;
  unresolved_gaps?: FulfillmentUnresolvedGap[];
  [key: string]: unknown;
}

/** List row. Carries no plan — the plan is a per-request read. */
export interface FulfillmentRequestSummary {
  id: string;
  state: FulfillmentRequestState;
  request: string;
  reused_count: number;
  materialized_count: number;
  instance_count: number;
  build_batch_id: string | null;
  template_id: string | null;
  node_instance_ids: string[];
  expires_at: string | null;
  error: string | null;
  parked: FulfillmentPark[] | null;
  smoke: Record<string, unknown> | null;
  approved_at: string | null;
  approved_by_user_id: string | null;
  created_at: string;
}

export interface FulfillmentRequestDetail extends FulfillmentRequestSummary {
  plan: FulfillmentPlan;
  /** sha256 of the frozen plan; the approval FleetEvent carries the same value. */
  plan_digest: string;
  cost_estimate: Record<string, unknown>;
}

export interface FulfillmentRequestsListResponse {
  fulfillment_requests: FulfillmentRequestSummary[];
  awaiting_approval_count: number;
}

export interface FulfillmentRequestFilters {
  state?: FulfillmentRequestState;
}

/** What one inline advance reported back, so a capped request says so immediately. */
export interface FulfillmentAdvanceResult {
  ok: boolean;
  state: string;
  advanced: number | null;
  waiting: boolean;
  parked: FulfillmentPark[] | null;
  error: string | null;
  already_advancing: boolean;
}

export interface FulfillmentApproveResponse {
  fulfillment_request: FulfillmentRequestSummary;
  advance: FulfillmentAdvanceResult;
}
