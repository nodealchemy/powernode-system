/**
 * Unit tests for ingressApi — the read-only operator view of derived Traefik
 * ingress routes (one per System::AcmeCertificate). Every exported function is
 * covered, including edge cases (optional status filter, empty routes array,
 * missing routes key, API error propagation).
 */

import { ingressApi, IngressRouteStatus } from './ingressApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Wrap a payload in the standard API double-envelope used by the backend. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// =============================================================================
// Fixtures
// =============================================================================

const ROUTER_A = {
  name: 'node-api',
  path_prefix: '/api',
  backend_service: 'powernode-backend',
  backend_url: 'http://backend:3000',
  entrypoint: 'websecure',
  tls_resolver: 'letsencrypt',
};

const ROUTER_B = {
  name: 'frontend-catchall',
  path_prefix: null,
  backend_service: 'powernode-frontend',
  backend_url: 'http://frontend:3001',
  entrypoint: 'websecure',
  tls_resolver: 'letsencrypt',
};

const ROUTE_VALID = {
  id: 'route-valid-1',
  common_name: 'app.example.com',
  sans: ['www.example.com'],
  host_rule: "Host(`app.example.com`) || Host(`www.example.com`)",
  status: 'valid' as IngressRouteStatus,
  active: true,
  issuer: "Let's Encrypt",
  issued_at: '2026-01-01T00:00:00Z',
  expires_at: '2026-04-01T00:00:00Z',
  days_until_expiry: 90,
  routers: [ROUTER_A, ROUTER_B],
  public_endpoints: ['https://app.example.com/', 'https://www.example.com/'],
};

const ROUTE_PENDING = {
  id: 'route-pending-2',
  common_name: 'staging.example.com',
  sans: [],
  host_rule: 'Host(`staging.example.com`)',
  status: 'pending' as IngressRouteStatus,
  active: false,
  issuer: null,
  issued_at: null,
  expires_at: null,
  days_until_expiry: null,
  routers: [],
  public_endpoints: [],
};

const ROUTE_REVOKED = {
  id: 'route-revoked-3',
  common_name: 'old.example.com',
  sans: [],
  host_rule: 'Host(`old.example.com`)',
  status: 'revoked' as IngressRouteStatus,
  active: false,
  issuer: "Let's Encrypt",
  issued_at: '2025-06-01T00:00:00Z',
  expires_at: null,
  days_until_expiry: null,
  routers: [],
  public_endpoints: [],
};

// =============================================================================
// Tests — ingressApi.listRoutes
// =============================================================================

describe('ingressApi.listRoutes', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  describe('fetches from the correct URL', () => {
    it('calls GET /system/ingress_routes without params when no status is provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [] }));

      await ingressApi.listRoutes();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/ingress_routes', {
        params: undefined,
      });
    });

    it('passes ?status=valid when status is provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [] }));

      await ingressApi.listRoutes('valid');

      expect(mockGet).toHaveBeenCalledWith('/system/ingress_routes', {
        params: { status: 'valid' },
      });
    });

    it('passes ?status=pending', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [] }));

      await ingressApi.listRoutes('pending');

      expect(mockGet).toHaveBeenCalledWith('/system/ingress_routes', {
        params: { status: 'pending' },
      });
    });

    it('passes ?status=issuing', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [] }));

      await ingressApi.listRoutes('issuing');

      expect(mockGet).toHaveBeenCalledWith('/system/ingress_routes', {
        params: { status: 'issuing' },
      });
    });

    it('passes ?status=renewing', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [] }));

      await ingressApi.listRoutes('renewing');

      expect(mockGet).toHaveBeenCalledWith('/system/ingress_routes', {
        params: { status: 'renewing' },
      });
    });

    it('passes ?status=revoked', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [] }));

      await ingressApi.listRoutes('revoked');

      expect(mockGet).toHaveBeenCalledWith('/system/ingress_routes', {
        params: { status: 'revoked' },
      });
    });
  });

  describe('returns the unwrapped routes array', () => {
    it('returns an empty array when routes is empty', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [] }));

      const result = await ingressApi.listRoutes();

      expect(result).toEqual([]);
    });

    it('returns a single route with all fields intact', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [ROUTE_VALID] }));

      const result = await ingressApi.listRoutes();

      expect(result).toHaveLength(1);
      expect(result[0]).toEqual(ROUTE_VALID);
    });

    it('returns multiple routes preserving order', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ routes: [ROUTE_VALID, ROUTE_PENDING, ROUTE_REVOKED] })
      );

      const result = await ingressApi.listRoutes();

      expect(result).toHaveLength(3);
      expect(result[0].id).toBe('route-valid-1');
      expect(result[1].id).toBe('route-pending-2');
      expect(result[2].id).toBe('route-revoked-3');
    });

    it('preserves nested router objects inside each route', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [ROUTE_VALID] }));

      const result = await ingressApi.listRoutes();

      expect(result[0].routers).toHaveLength(2);
      expect(result[0].routers[0]).toEqual(ROUTER_A);
      expect(result[0].routers[1]).toEqual(ROUTER_B);
    });

    it('preserves null fields on a pending route', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [ROUTE_PENDING] }));

      const result = await ingressApi.listRoutes();

      expect(result[0].issuer).toBeNull();
      expect(result[0].issued_at).toBeNull();
      expect(result[0].expires_at).toBeNull();
      expect(result[0].days_until_expiry).toBeNull();
      expect(result[0].active).toBe(false);
      expect(result[0].routers).toEqual([]);
      expect(result[0].public_endpoints).toEqual([]);
    });

    it('preserves null path_prefix on catchall router', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [ROUTE_VALID] }));

      const result = await ingressApi.listRoutes();
      const catchall = result[0].routers.find((r) => r.name === 'frontend-catchall');

      expect(catchall).toBeDefined();
      expect(catchall!.path_prefix).toBeNull();
    });

    it('returns routes filtered by status when status param is given', async () => {
      // The server does the filtering; we just confirm the correct subset is returned
      mockGet.mockResolvedValueOnce(envelope({ routes: [ROUTE_VALID] }));

      const result = await ingressApi.listRoutes('valid');

      expect(result).toHaveLength(1);
      expect(result[0].status).toBe('valid');
    });
  });

  describe('edge cases', () => {
    it('returns an empty array when routes key is missing (nullish coalescing)', async () => {
      // The backend may return {} or omit routes if there are none
      mockGet.mockResolvedValueOnce(envelope({} as { routes: never[] }));

      const result = await ingressApi.listRoutes();

      expect(result).toEqual([]);
    });

    it('propagates API errors as thrown exceptions', async () => {
      const error = new Error('Network Error');
      mockGet.mockRejectedValueOnce(error);

      await expect(ingressApi.listRoutes()).rejects.toThrow('Network Error');
    });

    it('propagates 404 errors from the API', async () => {
      const notFound = Object.assign(new Error('Request failed with status code 404'), {
        response: { status: 404, data: { success: false, error: 'Not Found' } },
      });
      mockGet.mockRejectedValueOnce(notFound);

      await expect(ingressApi.listRoutes()).rejects.toThrow('Request failed with status code 404');
    });

    it('propagates 403 errors from the API', async () => {
      const forbidden = Object.assign(new Error('Request failed with status code 403'), {
        response: { status: 403, data: { success: false, error: 'Forbidden' } },
      });
      mockGet.mockRejectedValueOnce(forbidden);

      await expect(ingressApi.listRoutes()).rejects.toThrow('Request failed with status code 403');
    });

    it('does not add extra query params when status is undefined', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [ROUTE_PENDING] }));

      await ingressApi.listRoutes(undefined);

      expect(mockGet).toHaveBeenCalledWith('/system/ingress_routes', {
        params: undefined,
      });
    });

    it('returns a route with sans array preserved', async () => {
      const routeWithSans = {
        ...ROUTE_VALID,
        sans: ['www.example.com', 'api.example.com', 'cdn.example.com'],
      };
      mockGet.mockResolvedValueOnce(envelope({ routes: [routeWithSans] }));

      const result = await ingressApi.listRoutes();

      expect(result[0].sans).toEqual(['www.example.com', 'api.example.com', 'cdn.example.com']);
    });

    it('returns a route with public_endpoints array preserved', async () => {
      mockGet.mockResolvedValueOnce(envelope({ routes: [ROUTE_VALID] }));

      const result = await ingressApi.listRoutes();

      expect(result[0].public_endpoints).toEqual([
        'https://app.example.com/',
        'https://www.example.com/',
      ]);
    });
  });
});
