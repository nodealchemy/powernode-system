// Behavioral tests for serviceCatalogApi.
//
// Covers every exported method: exact URL construction, query params,
// request payloads, envelope unwrapping, and optional-argument edge cases.
//
// Plan reference: Decentralized Federation §L.7 + P4.6.8.

import { serviceCatalogApi } from './serviceCatalogApi';
import type { RemoteSubscribeRequest } from './serviceCatalogApi';
import type {
  ServiceOffering,
  ServiceOfferingCreate,
  ServiceOfferingUpdate,
  ServiceOfferingsListResponse,
  ServiceSubscription,
  ServiceSubscriptionsListResponse,
  RemoteCatalogResponse,
  RemoteCatalogOffering,
} from '../../types/service_delivery.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();
const mockPatch = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/**
 * Build a double-envelope AxiosResponse body.
 * Mirrors the backend's `render_success` shape:
 *   { data: { success: true, data: <payload> } }
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const OFFERINGS_BASE = '/system/federation/service_offerings';
const SUBSCRIPTIONS_BASE = '/system/federation/service_subscriptions';
const PEER_ID = 'peer-fed-001';

const OFFERING: ServiceOffering = {
  id: 'off-aaa-111',
  slug: 'my-api-service',
  name: 'My API Service',
  protocol: 'https',
  status: 'active',
  backend_host: '10.0.0.5',
  backend_port: 8443,
  backend_vip_id: 'vip-xyz',
  default_grant_ttl_days: 30,
  default_grant_scopes: ['read', 'write'],
  capacity_metadata: { max_subscribers: 50 },
  latency_metadata: { p50_ms: 10, p95_ms: 50, region: 'us-east' },
  accepting_new_subscriptions: true,
  active_subscription_count: 3,
  created_at: '2026-01-10T00:00:00Z',
  updated_at: '2026-03-01T00:00:00Z',
};

const OFFERING_DRAFT: ServiceOffering = {
  ...OFFERING,
  id: 'off-bbb-222',
  slug: 'draft-service',
  name: 'Draft Service',
  status: 'draft',
  active_subscription_count: 0,
};

const OFFERING_RETIRED: ServiceOffering = {
  ...OFFERING,
  id: 'off-ccc-333',
  slug: 'retired-service',
  name: 'Retired Service',
  status: 'retired',
  accepting_new_subscriptions: false,
  retired_at: '2026-02-15T00:00:00Z',
};

const OFFERINGS_LIST: ServiceOfferingsListResponse = {
  offerings: [OFFERING, OFFERING_DRAFT],
  count: 2,
};

const SUBSCRIPTION: ServiceSubscription = {
  id: 'sub-zzz-999',
  service_offering_slug: 'my-api-service',
  service_offering_id: 'off-aaa-111',
  federation_peer_id: PEER_ID,
  local_hostname: 'node-local.example.com',
  protocol: 'https',
  backend_port: 8443,
  status: 'active',
  site_local: false,
  subscribed_at: '2026-02-01T00:00:00Z',
  activated_at: '2026-02-02T00:00:00Z',
};

const SUBSCRIPTION_CANCELLED: ServiceSubscription = {
  ...SUBSCRIPTION,
  id: 'sub-yyy-888',
  status: 'cancelled',
  cancelled_at: '2026-03-15T00:00:00Z',
};

const SUBSCRIPTIONS_LIST: ServiceSubscriptionsListResponse = {
  subscriptions: [SUBSCRIPTION, SUBSCRIPTION_CANCELLED],
  count: 2,
};

const REMOTE_OFFERING: RemoteCatalogOffering = {
  slug: 'remote-db',
  name: 'Remote Database',
  description_markdown: '# Remote DB',
  protocol: 'tcp',
  backend_port: 5432,
  capacity_metadata: { max_subscribers: 10 },
  latency_metadata: { p50_ms: 5, region: 'eu-west' },
  subscription_terms_markdown: 'Terms here.',
  default_grant_ttl_days: 90,
  default_grant_scopes: ['read'],
  status: 'active',
  accepting_new_subscriptions: true,
};

const REMOTE_CATALOG: RemoteCatalogResponse = {
  offerings: [REMOTE_OFFERING],
  generated_at: '2026-04-01T12:00:00Z',
};

const CREATE_PAYLOAD: ServiceOfferingCreate = {
  slug: 'new-service',
  name: 'New Service',
  protocol: 'https',
  backend_port: 9000,
  backend_host: '10.1.2.3',
  default_grant_ttl_days: 60,
  default_grant_scopes: ['read'],
  description_markdown: '## New',
  capacity_metadata: { max_subscribers: 100 },
  latency_metadata: { region: 'us-west' },
};

// =============================================================================
// Tests
// =============================================================================

describe('serviceCatalogApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockPatch.mockReset();
  });

  // ---------------------------------------------------------------------------
  // listOfferings()
  // ---------------------------------------------------------------------------

  describe('listOfferings()', () => {
    it('calls GET /system/federation/service_offerings with empty params when no filters provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(OFFERINGS_LIST));

      const result = await serviceCatalogApi.listOfferings();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(OFFERINGS_BASE, { params: {} });
      expect(result).toEqual(OFFERINGS_LIST);
    });

    it('passes status as a string param when filter is a single string', async () => {
      mockGet.mockResolvedValueOnce(envelope({ offerings: [OFFERING], count: 1 }));

      await serviceCatalogApi.listOfferings({ status: 'active' });

      expect(mockGet).toHaveBeenCalledWith(OFFERINGS_BASE, { params: { status: 'active' } });
    });

    it('passes status as comma-joined string when filter is an array', async () => {
      mockGet.mockResolvedValueOnce(envelope(OFFERINGS_LIST));

      await serviceCatalogApi.listOfferings({ status: ['active', 'draft'] });

      expect(mockGet).toHaveBeenCalledWith(OFFERINGS_BASE, { params: { status: 'active,draft' } });
    });

    it('omits status param when the array filter is empty', async () => {
      mockGet.mockResolvedValueOnce(envelope({ offerings: [], count: 0 }));

      await serviceCatalogApi.listOfferings({ status: [] as never[] });

      const [, opts] = mockGet.mock.calls[0] as [string, { params: Record<string, unknown> }];
      expect(opts.params['status']).toBeUndefined();
    });

    it('returns the full ServiceOfferingsListResponse including count', async () => {
      mockGet.mockResolvedValueOnce(envelope(OFFERINGS_LIST));

      const result = await serviceCatalogApi.listOfferings();

      expect(result.offerings).toHaveLength(2);
      expect(result.count).toBe(2);
      expect(result.offerings[0]).toEqual(OFFERING);
    });

    it('returns an empty offerings list when the API returns none', async () => {
      mockGet.mockResolvedValueOnce(envelope({ offerings: [], count: 0 }));

      const result = await serviceCatalogApi.listOfferings();

      expect(result.offerings).toHaveLength(0);
      expect(result.count).toBe(0);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Forbidden'));

      await expect(serviceCatalogApi.listOfferings()).rejects.toThrow('Forbidden');
    });
  });

  // ---------------------------------------------------------------------------
  // getOffering()
  // ---------------------------------------------------------------------------

  describe('getOffering()', () => {
    it('calls GET /system/federation/service_offerings/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      await serviceCatalogApi.getOffering('off-aaa-111');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-aaa-111`);
    });

    it('interpolates the offering id correctly into the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ offering: OFFERING_DRAFT }));

      await serviceCatalogApi.getOffering('off-bbb-222');

      expect(mockGet).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-bbb-222`);
    });

    it('returns the unwrapped ServiceOffering (not the { offering: ... } wrapper)', async () => {
      mockGet.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      const result = await serviceCatalogApi.getOffering('off-aaa-111');

      expect(result).toEqual(OFFERING);
      expect(result.id).toBe('off-aaa-111');
      expect(result.slug).toBe('my-api-service');
      expect((result as unknown as Record<string, unknown>)['offering']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not Found'));

      await expect(serviceCatalogApi.getOffering('no-such-id')).rejects.toThrow('Not Found');
    });
  });

  // ---------------------------------------------------------------------------
  // createOffering()
  // ---------------------------------------------------------------------------

  describe('createOffering()', () => {
    it('calls POST /system/federation/service_offerings with the full payload', async () => {
      mockPost.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      await serviceCatalogApi.createOffering(CREATE_PAYLOAD);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(OFFERINGS_BASE, CREATE_PAYLOAD);
    });

    it('returns the unwrapped ServiceOffering (not the wrapper object)', async () => {
      mockPost.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      const result = await serviceCatalogApi.createOffering(CREATE_PAYLOAD);

      expect(result).toEqual(OFFERING);
      expect(result.id).toBe('off-aaa-111');
      expect((result as unknown as Record<string, unknown>)['offering']).toBeUndefined();
    });

    it('sends slug, name, protocol and backend_port in the request body', async () => {
      mockPost.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      await serviceCatalogApi.createOffering(CREATE_PAYLOAD);

      const [, body] = mockPost.mock.calls[0] as [string, ServiceOfferingCreate];
      expect(body.slug).toBe('new-service');
      expect(body.name).toBe('New Service');
      expect(body.protocol).toBe('https');
      expect(body.backend_port).toBe(9000);
    });

    it('sends optional fields when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      await serviceCatalogApi.createOffering(CREATE_PAYLOAD);

      const [, body] = mockPost.mock.calls[0] as [string, ServiceOfferingCreate];
      expect(body.backend_host).toBe('10.1.2.3');
      expect(body.default_grant_ttl_days).toBe(60);
      expect(body.default_grant_scopes).toEqual(['read']);
      expect(body.description_markdown).toBe('## New');
    });

    it('works with a minimal payload (only required fields)', async () => {
      const minimal: ServiceOfferingCreate = {
        slug: 'minimal-svc',
        name: 'Minimal',
        protocol: 'tcp',
        backend_port: 3306,
      };
      mockPost.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      await serviceCatalogApi.createOffering(minimal);

      const [, body] = mockPost.mock.calls[0] as [string, ServiceOfferingCreate];
      expect(body.slug).toBe('minimal-svc');
      expect(body.backend_host).toBeUndefined();
      expect(body.backend_vip_id).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Unprocessable Entity'));

      await expect(serviceCatalogApi.createOffering(CREATE_PAYLOAD)).rejects.toThrow('Unprocessable Entity');
    });
  });

  // ---------------------------------------------------------------------------
  // updateOffering()
  // ---------------------------------------------------------------------------

  describe('updateOffering()', () => {
    it('calls PATCH /system/federation/service_offerings/:id with the update payload', async () => {
      const update: ServiceOfferingUpdate = { name: 'Renamed Service' };
      mockPatch.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      await serviceCatalogApi.updateOffering('off-aaa-111', update);

      expect(mockPatch).toHaveBeenCalledTimes(1);
      expect(mockPatch).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-aaa-111`, update);
    });

    it('interpolates the offering id into the URL', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ offering: OFFERING_DRAFT }));

      await serviceCatalogApi.updateOffering('off-bbb-222', { name: 'Updated Draft' });

      expect(mockPatch).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-bbb-222`, { name: 'Updated Draft' });
    });

    it('returns the unwrapped ServiceOffering (not the wrapper)', async () => {
      const updated: ServiceOffering = { ...OFFERING, name: 'Renamed Service' };
      mockPatch.mockResolvedValueOnce(envelope({ offering: updated }));

      const result = await serviceCatalogApi.updateOffering('off-aaa-111', { name: 'Renamed Service' });

      expect(result).toEqual(updated);
      expect(result.name).toBe('Renamed Service');
      expect((result as unknown as Record<string, unknown>)['offering']).toBeUndefined();
    });

    it('does not allow slug in the update payload (slug is omitted from ServiceOfferingUpdate type)', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      const update: ServiceOfferingUpdate = { name: 'No slug update', backend_port: 9001 };
      await serviceCatalogApi.updateOffering('off-aaa-111', update);

      const [, body] = mockPatch.mock.calls[0] as [string, ServiceOfferingUpdate];
      expect((body as Record<string, unknown>)['slug']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPatch.mockRejectedValueOnce(new Error('Conflict'));

      await expect(serviceCatalogApi.updateOffering('off-aaa-111', {})).rejects.toThrow('Conflict');
    });
  });

  // ---------------------------------------------------------------------------
  // retireOffering() — DELETE-as-retire
  // ---------------------------------------------------------------------------

  describe('retireOffering()', () => {
    it('calls DELETE /system/federation/service_offerings/:id with no body when reason is absent', async () => {
      mockDelete.mockResolvedValueOnce(envelope({ offering: OFFERING_RETIRED }));

      await serviceCatalogApi.retireOffering('off-aaa-111');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-aaa-111`, { data: undefined });
    });

    it('calls DELETE with { data: { reason } } when reason is provided', async () => {
      mockDelete.mockResolvedValueOnce(envelope({ offering: OFFERING_RETIRED }));

      await serviceCatalogApi.retireOffering('off-ccc-333', 'end-of-life');

      expect(mockDelete).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-ccc-333`, {
        data: { reason: 'end-of-life' },
      });
    });

    it('calls DELETE with { data: undefined } when reason is empty string (falsy)', async () => {
      mockDelete.mockResolvedValueOnce(envelope({ offering: OFFERING_RETIRED }));

      await serviceCatalogApi.retireOffering('off-aaa-111', '');

      expect(mockDelete).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-aaa-111`, { data: undefined });
    });

    it('interpolates the offering id into the URL', async () => {
      mockDelete.mockResolvedValueOnce(envelope({ offering: OFFERING_RETIRED }));

      await serviceCatalogApi.retireOffering('off-ccc-333');

      expect(mockDelete).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-ccc-333`, expect.any(Object));
    });

    it('returns the unwrapped retired ServiceOffering', async () => {
      mockDelete.mockResolvedValueOnce(envelope({ offering: OFFERING_RETIRED }));

      const result = await serviceCatalogApi.retireOffering('off-ccc-333');

      expect(result).toEqual(OFFERING_RETIRED);
      expect(result.status).toBe('retired');
      expect((result as unknown as Record<string, unknown>)['offering']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Cannot retire active offering with subscribers'));

      await expect(serviceCatalogApi.retireOffering('off-aaa-111')).rejects.toThrow(
        'Cannot retire active offering with subscribers',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // activateOffering()
  // ---------------------------------------------------------------------------

  describe('activateOffering()', () => {
    it('calls POST /system/federation/service_offerings/:id/activate with empty body', async () => {
      const activated: ServiceOffering = { ...OFFERING_DRAFT, status: 'active' };
      mockPost.mockResolvedValueOnce(envelope({ offering: activated }));

      await serviceCatalogApi.activateOffering('off-bbb-222');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-bbb-222/activate`, {});
    });

    it('interpolates the offering id into the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      await serviceCatalogApi.activateOffering('off-aaa-111');

      expect(mockPost).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-aaa-111/activate`, {});
    });

    it('returns the unwrapped activated ServiceOffering', async () => {
      const activated: ServiceOffering = { ...OFFERING_DRAFT, status: 'active' };
      mockPost.mockResolvedValueOnce(envelope({ offering: activated }));

      const result = await serviceCatalogApi.activateOffering('off-bbb-222');

      expect(result.status).toBe('active');
      expect(result.id).toBe('off-bbb-222');
      expect((result as unknown as Record<string, unknown>)['offering']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('State transition not allowed'));

      await expect(serviceCatalogApi.activateOffering('off-aaa-111')).rejects.toThrow(
        'State transition not allowed',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // deprecateOffering()
  // ---------------------------------------------------------------------------

  describe('deprecateOffering()', () => {
    it('calls POST /system/federation/service_offerings/:id/deprecate with empty body when no reason', async () => {
      const deprecated: ServiceOffering = { ...OFFERING, status: 'deprecated' };
      mockPost.mockResolvedValueOnce(envelope({ offering: deprecated }));

      await serviceCatalogApi.deprecateOffering('off-aaa-111');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-aaa-111/deprecate`, {});
    });

    it('includes reason in body when provided', async () => {
      const deprecated: ServiceOffering = { ...OFFERING, status: 'deprecated' };
      mockPost.mockResolvedValueOnce(envelope({ offering: deprecated }));

      await serviceCatalogApi.deprecateOffering('off-aaa-111', 'superseded by v2');

      expect(mockPost).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-aaa-111/deprecate`, {
        reason: 'superseded by v2',
      });
    });

    it('sends empty body ({}) when reason is empty string (falsy)', async () => {
      const deprecated: ServiceOffering = { ...OFFERING, status: 'deprecated' };
      mockPost.mockResolvedValueOnce(envelope({ offering: deprecated }));

      await serviceCatalogApi.deprecateOffering('off-aaa-111', '');

      expect(mockPost).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-aaa-111/deprecate`, {});
    });

    it('interpolates the offering id into the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope({ offering: OFFERING }));

      await serviceCatalogApi.deprecateOffering('off-bbb-222');

      expect(mockPost).toHaveBeenCalledWith(`${OFFERINGS_BASE}/off-bbb-222/deprecate`, {});
    });

    it('returns the unwrapped deprecated ServiceOffering', async () => {
      const deprecated: ServiceOffering = { ...OFFERING, status: 'deprecated' };
      mockPost.mockResolvedValueOnce(envelope({ offering: deprecated }));

      const result = await serviceCatalogApi.deprecateOffering('off-aaa-111');

      expect(result.status).toBe('deprecated');
      expect((result as unknown as Record<string, unknown>)['offering']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Already deprecated'));

      await expect(serviceCatalogApi.deprecateOffering('off-aaa-111')).rejects.toThrow('Already deprecated');
    });
  });

  // ---------------------------------------------------------------------------
  // listSubscriptions()
  // ---------------------------------------------------------------------------

  describe('listSubscriptions()', () => {
    it('calls GET /system/federation/service_subscriptions with empty params when no filters', async () => {
      mockGet.mockResolvedValueOnce(envelope(SUBSCRIPTIONS_LIST));

      const result = await serviceCatalogApi.listSubscriptions();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(SUBSCRIPTIONS_BASE, { params: {} });
      expect(result).toEqual(SUBSCRIPTIONS_LIST);
    });

    it('passes status as string param when filter is a single value', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subscriptions: [SUBSCRIPTION], count: 1 }));

      await serviceCatalogApi.listSubscriptions({ status: 'active' });

      expect(mockGet).toHaveBeenCalledWith(SUBSCRIPTIONS_BASE, { params: { status: 'active' } });
    });

    it('passes status as comma-joined string when filter is an array', async () => {
      mockGet.mockResolvedValueOnce(envelope(SUBSCRIPTIONS_LIST));

      await serviceCatalogApi.listSubscriptions({ status: ['active', 'cancelled'] });

      expect(mockGet).toHaveBeenCalledWith(SUBSCRIPTIONS_BASE, { params: { status: 'active,cancelled' } });
    });

    it('passes peer_id filter when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subscriptions: [SUBSCRIPTION], count: 1 }));

      await serviceCatalogApi.listSubscriptions({ peer_id: PEER_ID });

      expect(mockGet).toHaveBeenCalledWith(SUBSCRIPTIONS_BASE, { params: { peer_id: PEER_ID } });
    });

    it('passes combined filters (status + peer_id) as separate params', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subscriptions: [SUBSCRIPTION], count: 1 }));

      await serviceCatalogApi.listSubscriptions({ status: 'active', peer_id: 'peer-x' });

      expect(mockGet).toHaveBeenCalledWith(SUBSCRIPTIONS_BASE, {
        params: { status: 'active', peer_id: 'peer-x' },
      });
    });

    it('omits status param when array filter is empty', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subscriptions: [], count: 0 }));

      await serviceCatalogApi.listSubscriptions({ status: [] as never[] });

      const [, opts] = mockGet.mock.calls[0] as [string, { params: Record<string, unknown> }];
      expect(opts.params['status']).toBeUndefined();
    });

    it('returns the full ServiceSubscriptionsListResponse including count', async () => {
      mockGet.mockResolvedValueOnce(envelope(SUBSCRIPTIONS_LIST));

      const result = await serviceCatalogApi.listSubscriptions();

      expect(result.subscriptions).toHaveLength(2);
      expect(result.count).toBe(2);
      expect(result.subscriptions[0]).toEqual(SUBSCRIPTION);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Unauthorized'));

      await expect(serviceCatalogApi.listSubscriptions()).rejects.toThrow('Unauthorized');
    });
  });

  // ---------------------------------------------------------------------------
  // getSubscription()
  // ---------------------------------------------------------------------------

  describe('getSubscription()', () => {
    it('calls GET /system/federation/service_subscriptions/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION }));

      await serviceCatalogApi.getSubscription('sub-zzz-999');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${SUBSCRIPTIONS_BASE}/sub-zzz-999`);
    });

    it('interpolates the subscription id into the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION_CANCELLED }));

      await serviceCatalogApi.getSubscription('sub-yyy-888');

      expect(mockGet).toHaveBeenCalledWith(`${SUBSCRIPTIONS_BASE}/sub-yyy-888`);
    });

    it('returns the unwrapped ServiceSubscription (not the { subscription: ... } wrapper)', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION }));

      const result = await serviceCatalogApi.getSubscription('sub-zzz-999');

      expect(result).toEqual(SUBSCRIPTION);
      expect(result.id).toBe('sub-zzz-999');
      expect(result.status).toBe('active');
      expect((result as unknown as Record<string, unknown>)['subscription']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not Found'));

      await expect(serviceCatalogApi.getSubscription('no-such')).rejects.toThrow('Not Found');
    });
  });

  // ---------------------------------------------------------------------------
  // cancelSubscription()
  // ---------------------------------------------------------------------------

  describe('cancelSubscription()', () => {
    it('calls POST /system/federation/service_subscriptions/:id/cancel with empty body when no reason', async () => {
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION_CANCELLED }));

      await serviceCatalogApi.cancelSubscription('sub-zzz-999');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${SUBSCRIPTIONS_BASE}/sub-zzz-999/cancel`, {});
    });

    it('includes reason in body when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION_CANCELLED }));

      await serviceCatalogApi.cancelSubscription('sub-zzz-999', 'no longer needed');

      expect(mockPost).toHaveBeenCalledWith(`${SUBSCRIPTIONS_BASE}/sub-zzz-999/cancel`, {
        reason: 'no longer needed',
      });
    });

    it('sends empty body ({}) when reason is empty string (falsy)', async () => {
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION_CANCELLED }));

      await serviceCatalogApi.cancelSubscription('sub-zzz-999', '');

      expect(mockPost).toHaveBeenCalledWith(`${SUBSCRIPTIONS_BASE}/sub-zzz-999/cancel`, {});
    });

    it('interpolates the subscription id into the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION_CANCELLED }));

      await serviceCatalogApi.cancelSubscription('sub-yyy-888');

      expect(mockPost).toHaveBeenCalledWith(`${SUBSCRIPTIONS_BASE}/sub-yyy-888/cancel`, {});
    });

    it('returns the unwrapped cancelled ServiceSubscription', async () => {
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION_CANCELLED }));

      const result = await serviceCatalogApi.cancelSubscription('sub-zzz-999', 'done');

      expect(result.status).toBe('cancelled');
      expect(result.cancelled_at).toBe('2026-03-15T00:00:00Z');
      expect((result as unknown as Record<string, unknown>)['subscription']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Already cancelled'));

      await expect(serviceCatalogApi.cancelSubscription('sub-zzz-999')).rejects.toThrow('Already cancelled');
    });
  });

  // ---------------------------------------------------------------------------
  // fetchPeerCatalog()
  // ---------------------------------------------------------------------------

  describe('fetchPeerCatalog()', () => {
    it('calls GET /system/federation/peers/:peerId/catalog', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ catalog: REMOTE_CATALOG, peer_id: PEER_ID }),
      );

      await serviceCatalogApi.fetchPeerCatalog(PEER_ID);

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`/system/federation/peers/${PEER_ID}/catalog`);
    });

    it('interpolates the peerId into the URL', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ catalog: REMOTE_CATALOG, peer_id: 'peer-other-456' }),
      );

      await serviceCatalogApi.fetchPeerCatalog('peer-other-456');

      expect(mockGet).toHaveBeenCalledWith('/system/federation/peers/peer-other-456/catalog');
    });

    it('returns the unwrapped RemoteCatalogResponse (not the { catalog, peer_id } wrapper)', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ catalog: REMOTE_CATALOG, peer_id: PEER_ID }),
      );

      const result = await serviceCatalogApi.fetchPeerCatalog(PEER_ID);

      expect(result).toEqual(REMOTE_CATALOG);
      expect(result.offerings).toHaveLength(1);
      expect(result.generated_at).toBe('2026-04-01T12:00:00Z');
      expect((result as unknown as Record<string, unknown>)['catalog']).toBeUndefined();
      expect((result as unknown as Record<string, unknown>)['peer_id']).toBeUndefined();
    });

    it('returns the remote offerings with correct fields', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ catalog: REMOTE_CATALOG, peer_id: PEER_ID }),
      );

      const result = await serviceCatalogApi.fetchPeerCatalog(PEER_ID);

      expect(result.offerings[0].slug).toBe('remote-db');
      expect(result.offerings[0].protocol).toBe('tcp');
      expect(result.offerings[0].backend_port).toBe(5432);
      // Remote catalog should NOT expose backend_host (subscriber cannot see it)
      expect((result.offerings[0] as unknown as Record<string, unknown>)['backend_host']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Peer unreachable'));

      await expect(serviceCatalogApi.fetchPeerCatalog(PEER_ID)).rejects.toThrow('Peer unreachable');
    });
  });

  // ---------------------------------------------------------------------------
  // subscribeToPeer()
  // ---------------------------------------------------------------------------

  describe('subscribeToPeer()', () => {
    const SUBSCRIBE_BODY: RemoteSubscribeRequest = {
      slug: 'remote-db',
      local_hostname: 'node-local.example.com',
      ttl_days: 90,
      dns_credential_id: 'cred-dns-001',
    };

    it('calls POST /system/federation/peers/:peerId/subscriptions with the request body', async () => {
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION }));

      await serviceCatalogApi.subscribeToPeer(PEER_ID, SUBSCRIBE_BODY);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        `/system/federation/peers/${PEER_ID}/subscriptions`,
        SUBSCRIBE_BODY,
      );
    });

    it('interpolates the peerId into the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION }));

      await serviceCatalogApi.subscribeToPeer('peer-alt-777', SUBSCRIBE_BODY);

      expect(mockPost).toHaveBeenCalledWith(
        '/system/federation/peers/peer-alt-777/subscriptions',
        SUBSCRIBE_BODY,
      );
    });

    it('returns the unwrapped ServiceSubscription (not the { subscription: ... } wrapper)', async () => {
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION }));

      const result = await serviceCatalogApi.subscribeToPeer(PEER_ID, SUBSCRIBE_BODY);

      expect(result).toEqual(SUBSCRIPTION);
      expect(result.id).toBe('sub-zzz-999');
      expect((result as unknown as Record<string, unknown>)['subscription']).toBeUndefined();
    });

    it('sends slug and local_hostname in the request body', async () => {
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION }));

      await serviceCatalogApi.subscribeToPeer(PEER_ID, SUBSCRIBE_BODY);

      const [, body] = mockPost.mock.calls[0] as [string, RemoteSubscribeRequest];
      expect(body.slug).toBe('remote-db');
      expect(body.local_hostname).toBe('node-local.example.com');
    });

    it('sends optional ttl_days and dns_credential_id when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION }));

      await serviceCatalogApi.subscribeToPeer(PEER_ID, SUBSCRIBE_BODY);

      const [, body] = mockPost.mock.calls[0] as [string, RemoteSubscribeRequest];
      expect(body.ttl_days).toBe(90);
      expect(body.dns_credential_id).toBe('cred-dns-001');
    });

    it('works with a minimal body (only slug + local_hostname)', async () => {
      const minimal: RemoteSubscribeRequest = {
        slug: 'remote-db',
        local_hostname: 'my-node.local',
      };
      mockPost.mockResolvedValueOnce(envelope({ subscription: SUBSCRIPTION }));

      await serviceCatalogApi.subscribeToPeer(PEER_ID, minimal);

      const [, body] = mockPost.mock.calls[0] as [string, RemoteSubscribeRequest];
      expect(body.ttl_days).toBeUndefined();
      expect(body.dns_credential_id).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Offering not available'));

      await expect(serviceCatalogApi.subscribeToPeer(PEER_ID, SUBSCRIBE_BODY)).rejects.toThrow(
        'Offering not available',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // paramsFromFilters() — internal behavior through public API
  // ---------------------------------------------------------------------------

  describe('filter param construction (via public API)', () => {
    it('coerces undefined filter values to absent params', async () => {
      mockGet.mockResolvedValueOnce(envelope({ offerings: [], count: 0 }));

      // Passing an explicit undefined for status should be a no-op in params
      await serviceCatalogApi.listOfferings({ status: undefined });

      const [, opts] = mockGet.mock.calls[0] as [string, { params: Record<string, unknown> }];
      expect(Object.keys(opts.params)).toHaveLength(0);
    });

    it('converts non-array filter values to strings', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subscriptions: [], count: 0 }));

      await serviceCatalogApi.listSubscriptions({ peer_id: 'peer-123' });

      const [, opts] = mockGet.mock.calls[0] as [string, { params: Record<string, string> }];
      // Value must be a string, not a number or object
      expect(typeof opts.params['peer_id']).toBe('string');
      expect(opts.params['peer_id']).toBe('peer-123');
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract verification
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('correctly extracts data from double-envelope for listOfferings()', async () => {
      const payload: ServiceOfferingsListResponse = { offerings: [OFFERING], count: 1 };
      mockGet.mockResolvedValueOnce({ data: { success: true, data: payload } });

      const result = await serviceCatalogApi.listOfferings();

      expect(result).toEqual(payload);
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('correctly extracts nested .offering from createOffering() envelope', async () => {
      mockPost.mockResolvedValueOnce({ data: { success: true, data: { offering: OFFERING } } });

      const result = await serviceCatalogApi.createOffering(CREATE_PAYLOAD);

      expect(result.id).toBe('off-aaa-111');
      expect((result as unknown as Record<string, unknown>)['offering']).toBeUndefined();
    });

    it('correctly extracts nested .subscription from cancelSubscription() envelope', async () => {
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: { subscription: SUBSCRIPTION_CANCELLED } },
      });

      const result = await serviceCatalogApi.cancelSubscription('sub-zzz-999');

      expect(result.status).toBe('cancelled');
      expect((result as unknown as Record<string, unknown>)['subscription']).toBeUndefined();
    });

    it('correctly extracts nested .catalog from fetchPeerCatalog() envelope', async () => {
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { catalog: REMOTE_CATALOG, peer_id: PEER_ID } },
      });

      const result = await serviceCatalogApi.fetchPeerCatalog(PEER_ID);

      expect(result.offerings).toHaveLength(1);
      expect((result as unknown as Record<string, unknown>)['catalog']).toBeUndefined();
    });
  });
});
