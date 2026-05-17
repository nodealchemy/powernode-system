import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  ServiceOffering,
  ServiceOfferingCreate,
  ServiceOfferingUpdate,
  ServiceOfferingFilters,
  ServiceOfferingsListResponse,
  ServiceSubscription,
  ServiceSubscriptionFilters,
  ServiceSubscriptionsListResponse,
  RemoteCatalogResponse,
} from '../../types/service_delivery.types';

export interface RemoteSubscribeRequest {
  slug: string;
  local_hostname: string;
  ttl_days?: number;
  dns_credential_id?: string;
}

// Federated Service Delivery API client.
//
// Surfaces:
//   1. Operator's own offerings catalog — CRUD + state transitions
//   2. Subscriber's own subscriptions — read + cancel
//
// Plan reference: Decentralized Federation §L.7 + P4.6.8.

const OFFERINGS_BASE = '/system/federation/service_offerings';
const SUBSCRIPTIONS_BASE = '/system/federation/service_subscriptions';

function paramsFromFilters<T extends Record<string, unknown>>(filters?: T): Record<string, string> {
  if (!filters) return {};
  const out: Record<string, string> = {};
  Object.entries(filters).forEach(([key, value]) => {
    if (value === undefined || value === null) return;
    if (Array.isArray(value)) {
      if (value.length > 0) out[key] = value.join(',');
    } else {
      out[key] = String(value);
    }
  });
  return out;
}

export const serviceCatalogApi = {
  // === ServiceOffering (operator side) ===

  listOfferings: async (filters?: ServiceOfferingFilters): Promise<ServiceOfferingsListResponse> => {
    const response = await apiClient.get<ApiEnvelope<ServiceOfferingsListResponse>>(
      OFFERINGS_BASE,
      { params: paramsFromFilters(filters) },
    );
    return extractData(response);
  },

  getOffering: async (id: string): Promise<ServiceOffering> => {
    const response = await apiClient.get<ApiEnvelope<{ offering: ServiceOffering }>>(
      `${OFFERINGS_BASE}/${id}`,
    );
    return extractData(response).offering;
  },

  createOffering: async (data: ServiceOfferingCreate): Promise<ServiceOffering> => {
    const response = await apiClient.post<ApiEnvelope<{ offering: ServiceOffering }>>(
      OFFERINGS_BASE,
      data,
    );
    return extractData(response).offering;
  },

  updateOffering: async (id: string, data: ServiceOfferingUpdate): Promise<ServiceOffering> => {
    const response = await apiClient.patch<ApiEnvelope<{ offering: ServiceOffering }>>(
      `${OFFERINGS_BASE}/${id}`,
      data,
    );
    return extractData(response).offering;
  },

  // DELETE-as-retire (soft delete). Server-side returns the retired
  // offering for UI confirmation.
  retireOffering: async (id: string, reason?: string): Promise<ServiceOffering> => {
    const response = await apiClient.delete<ApiEnvelope<{ offering: ServiceOffering }>>(
      `${OFFERINGS_BASE}/${id}`,
      { data: reason ? { reason } : undefined },
    );
    return extractData(response).offering;
  },

  activateOffering: async (id: string): Promise<ServiceOffering> => {
    const response = await apiClient.post<ApiEnvelope<{ offering: ServiceOffering }>>(
      `${OFFERINGS_BASE}/${id}/activate`,
      {},
    );
    return extractData(response).offering;
  },

  deprecateOffering: async (id: string, reason?: string): Promise<ServiceOffering> => {
    const response = await apiClient.post<ApiEnvelope<{ offering: ServiceOffering }>>(
      `${OFFERINGS_BASE}/${id}/deprecate`,
      reason ? { reason } : {},
    );
    return extractData(response).offering;
  },

  // === ServiceSubscription (subscriber side) ===

  listSubscriptions: async (
    filters?: ServiceSubscriptionFilters,
  ): Promise<ServiceSubscriptionsListResponse> => {
    const response = await apiClient.get<ApiEnvelope<ServiceSubscriptionsListResponse>>(
      SUBSCRIPTIONS_BASE,
      { params: paramsFromFilters(filters) },
    );
    return extractData(response);
  },

  getSubscription: async (id: string): Promise<ServiceSubscription> => {
    const response = await apiClient.get<ApiEnvelope<{ subscription: ServiceSubscription }>>(
      `${SUBSCRIPTIONS_BASE}/${id}`,
    );
    return extractData(response).subscription;
  },

  cancelSubscription: async (id: string, reason?: string): Promise<ServiceSubscription> => {
    const response = await apiClient.post<ApiEnvelope<{ subscription: ServiceSubscription }>>(
      `${SUBSCRIPTIONS_BASE}/${id}/cancel`,
      reason ? { reason } : {},
    );
    return extractData(response).subscription;
  },

  // === Per-peer catalog browse + remote subscribe ===
  //
  // These proxy through the operator-admin endpoints which in turn
  // call the remote peer's federation_api via Federation::PeerClient.

  fetchPeerCatalog: async (peerId: string): Promise<RemoteCatalogResponse> => {
    const response = await apiClient.get<ApiEnvelope<{ catalog: RemoteCatalogResponse; peer_id: string }>>(
      `/system/federation/peers/${peerId}/catalog`,
    );
    return extractData(response).catalog;
  },

  subscribeToPeer: async (
    peerId: string,
    body: RemoteSubscribeRequest,
  ): Promise<ServiceSubscription> => {
    const response = await apiClient.post<ApiEnvelope<{ subscription: ServiceSubscription }>>(
      `/system/federation/peers/${peerId}/subscriptions`,
      body,
    );
    return extractData(response).subscription;
  },
};
