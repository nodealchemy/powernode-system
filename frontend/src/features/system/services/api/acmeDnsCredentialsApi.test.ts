import { acmeDnsCredentialsApi } from './acmeDnsCredentialsApi';
import type {
  AcmeDnsCredentialCreateRequest,
  AcmeDnsCredentialDetail,
  AcmeDnsCredentialRotateRequest,
  AcmeDnsCredentialSummary,
  AcmeDnsCredentialsListResponse,
  AcmeDnsCredentialTestResponse,
} from '../../types/acme.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockPatch = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Wrap a payload in the double-envelope Axios response shape. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// =============================================================================
// Fixtures
// =============================================================================

const CREDENTIAL_SUMMARY: AcmeDnsCredentialSummary = {
  id: 'cred-001',
  name: 'cloudflare-prod',
  provider: 'cloudflare',
  status: 'valid',
  last_validated_at: '2026-06-01T10:00:00Z',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-06-01T10:00:00Z',
  needs_revalidation: false,
};

const CREDENTIAL_DETAIL: AcmeDnsCredentialDetail = {
  ...CREDENTIAL_SUMMARY,
  metadata: { region: 'us-east-1' },
  certificates_count: 3,
  required_fields: ['api_token'],
};

const CREDENTIAL_SUMMARY_2: AcmeDnsCredentialSummary = {
  id: 'cred-002',
  name: 'route53-staging',
  provider: 'route53',
  status: 'untested',
  last_validated_at: null,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
  needs_revalidation: true,
};

const LIST_RESPONSE: AcmeDnsCredentialsListResponse = {
  credentials: [CREDENTIAL_SUMMARY, CREDENTIAL_SUMMARY_2],
  count: 2,
  supported_providers: [
    { slug: 'cloudflare', required_fields: ['api_token'], description: 'Cloudflare DNS' },
    { slug: 'route53', required_fields: ['access_key_id', 'secret_access_key', 'region'], description: 'AWS Route53' },
  ],
};

const TEST_RESPONSE: AcmeDnsCredentialTestResponse = {
  ok: true,
  reason: 'DNS propagation confirmed',
  details: { propagation_ms: 120 },
  credential: CREDENTIAL_DETAIL,
};

// =============================================================================
// Tests
// =============================================================================

describe('acmeDnsCredentialsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockPatch.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list
  // ---------------------------------------------------------------------------

  describe('list', () => {
    it('calls GET /system/acme_dns_credentials without params when no provider given', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await acmeDnsCredentialsApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/acme_dns_credentials', { params: undefined });
      expect(result).toEqual(LIST_RESPONSE);
    });

    it('calls GET /system/acme_dns_credentials with provider param when provider is given', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await acmeDnsCredentialsApi.list('cloudflare');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/acme_dns_credentials', { params: { provider: 'cloudflare' } });
      expect(result).toEqual(LIST_RESPONSE);
    });

    it('returns credentials and count from envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await acmeDnsCredentialsApi.list();

      expect(result.credentials).toHaveLength(2);
      expect(result.count).toBe(2);
      expect(result.credentials[0].id).toBe('cred-001');
      expect(result.credentials[1].id).toBe('cred-002');
    });

    it('returns supported_providers from envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await acmeDnsCredentialsApi.list();

      expect(result.supported_providers).toHaveLength(2);
      expect(result.supported_providers[0].slug).toBe('cloudflare');
    });

    it('returns empty list when no credentials exist', async () => {
      const emptyResponse: AcmeDnsCredentialsListResponse = {
        credentials: [],
        count: 0,
        supported_providers: [],
      };
      mockGet.mockResolvedValueOnce(envelope(emptyResponse));

      const result = await acmeDnsCredentialsApi.list();

      expect(result.credentials).toHaveLength(0);
      expect(result.count).toBe(0);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(acmeDnsCredentialsApi.list()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // get
  // ---------------------------------------------------------------------------

  describe('get', () => {
    it('calls GET /system/acme_dns_credentials/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      await acmeDnsCredentialsApi.get('cred-001');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/acme_dns_credentials/cred-001');
    });

    it('unwraps the nested credential from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      const result = await acmeDnsCredentialsApi.get('cred-001');

      expect(result).toEqual(CREDENTIAL_DETAIL);
      expect(result.id).toBe('cred-001');
      expect(result.name).toBe('cloudflare-prod');
      expect(result.provider).toBe('cloudflare');
    });

    it('returns detail-specific fields: metadata, certificates_count, required_fields', async () => {
      mockGet.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      const result = await acmeDnsCredentialsApi.get('cred-001');

      expect(result.metadata).toEqual({ region: 'us-east-1' });
      expect(result.certificates_count).toBe(3);
      expect(result.required_fields).toEqual(['api_token']);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(acmeDnsCredentialsApi.get('nonexistent')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // create
  // ---------------------------------------------------------------------------

  describe('create', () => {
    const CREATE_REQUEST: AcmeDnsCredentialCreateRequest = {
      name: 'new-cloudflare',
      provider: 'cloudflare',
      credentials: { api_token: 'cf_token_abc123' },
      metadata: { note: 'production' },
    };

    it('calls POST /system/acme_dns_credentials with the full request payload', async () => {
      mockPost.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      await acmeDnsCredentialsApi.create(CREATE_REQUEST);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith('/system/acme_dns_credentials', CREATE_REQUEST);
    });

    it('returns the created credential detail from envelope', async () => {
      mockPost.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      const result = await acmeDnsCredentialsApi.create(CREATE_REQUEST);

      expect(result).toEqual(CREDENTIAL_DETAIL);
      expect(result.id).toBe('cred-001');
    });

    it('sends credentials payload including provider-specific token fields', async () => {
      mockPost.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      await acmeDnsCredentialsApi.create(CREATE_REQUEST);

      const call = mockPost.mock.calls[0];
      const body = call[1] as AcmeDnsCredentialCreateRequest;
      expect(body.credentials).toEqual({ api_token: 'cf_token_abc123' });
    });

    it('works without optional metadata field', async () => {
      const requestWithoutMeta: AcmeDnsCredentialCreateRequest = {
        name: 'bare-cred',
        provider: 'digitalocean',
        credentials: { auth_token: 'do_token_xyz' },
      };
      mockPost.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      await acmeDnsCredentialsApi.create(requestWithoutMeta);

      const call = mockPost.mock.calls[0];
      const body = call[1] as AcmeDnsCredentialCreateRequest;
      expect(body.metadata).toBeUndefined();
    });

    it('sends Route53 multi-field credentials', async () => {
      const route53Request: AcmeDnsCredentialCreateRequest = {
        name: 'route53-prod',
        provider: 'route53',
        credentials: {
          access_key_id: 'AKIAIOSFODNN7EXAMPLE',
          secret_access_key: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
          region: 'us-east-1',
        },
      };
      mockPost.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      await acmeDnsCredentialsApi.create(route53Request);

      const call = mockPost.mock.calls[0];
      const body = call[1] as AcmeDnsCredentialCreateRequest;
      expect(body.credentials.access_key_id).toBe('AKIAIOSFODNN7EXAMPLE');
      expect(body.credentials.secret_access_key).toBe('wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY');
      expect(body.credentials.region).toBe('us-east-1');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Unprocessable entity'));

      await expect(acmeDnsCredentialsApi.create(CREATE_REQUEST)).rejects.toThrow('Unprocessable entity');
    });
  });

  // ---------------------------------------------------------------------------
  // updateName
  // ---------------------------------------------------------------------------

  describe('updateName', () => {
    it('calls PATCH /system/acme_dns_credentials/:id with only the name field', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      await acmeDnsCredentialsApi.updateName('cred-001', 'renamed-cred');

      expect(mockPatch).toHaveBeenCalledTimes(1);
      expect(mockPatch).toHaveBeenCalledWith(
        '/system/acme_dns_credentials/cred-001',
        { name: 'renamed-cred' },
      );
    });

    it('returns the updated credential detail', async () => {
      const updatedDetail = { ...CREDENTIAL_DETAIL, name: 'renamed-cred' };
      mockPatch.mockResolvedValueOnce(envelope({ credential: updatedDetail }));

      const result = await acmeDnsCredentialsApi.updateName('cred-001', 'renamed-cred');

      expect(result.name).toBe('renamed-cred');
      expect(result.id).toBe('cred-001');
    });

    it('sends only the name — no credentials or provider in payload', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      await acmeDnsCredentialsApi.updateName('cred-001', 'only-name');

      const call = mockPatch.mock.calls[0];
      const body = call[1] as Record<string, unknown>;
      expect(Object.keys(body)).toEqual(['name']);
    });

    it('propagates API errors', async () => {
      mockPatch.mockRejectedValueOnce(new Error('Not found'));

      await expect(acmeDnsCredentialsApi.updateName('bad-id', 'name')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // destroy
  // ---------------------------------------------------------------------------

  describe('destroy', () => {
    it('calls DELETE /system/acme_dns_credentials/:id', async () => {
      mockDelete.mockResolvedValueOnce(envelope(null));

      await acmeDnsCredentialsApi.destroy('cred-001');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith('/system/acme_dns_credentials/cred-001');
    });

    it('resolves to void (returns nothing)', async () => {
      mockDelete.mockResolvedValueOnce(envelope(null));

      const result = await acmeDnsCredentialsApi.destroy('cred-001');

      expect(result).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Forbidden'));

      await expect(acmeDnsCredentialsApi.destroy('cred-001')).rejects.toThrow('Forbidden');
    });
  });

  // ---------------------------------------------------------------------------
  // testConnectivity
  // ---------------------------------------------------------------------------

  describe('testConnectivity', () => {
    it('calls POST /system/acme_dns_credentials/:id/test_connectivity with empty body', async () => {
      mockPost.mockResolvedValueOnce(envelope(TEST_RESPONSE));

      await acmeDnsCredentialsApi.testConnectivity('cred-001');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        '/system/acme_dns_credentials/cred-001/test_connectivity',
        {},
      );
    });

    it('returns full test response including ok, reason, details, and credential', async () => {
      mockPost.mockResolvedValueOnce(envelope(TEST_RESPONSE));

      const result = await acmeDnsCredentialsApi.testConnectivity('cred-001');

      expect(result.ok).toBe(true);
      expect(result.reason).toBe('DNS propagation confirmed');
      expect(result.details).toEqual({ propagation_ms: 120 });
      expect(result.credential).toEqual(CREDENTIAL_DETAIL);
    });

    it('returns response with ok=false on connectivity failure', async () => {
      const failResponse: AcmeDnsCredentialTestResponse = {
        ok: false,
        reason: 'Invalid API token',
        credential: { ...CREDENTIAL_DETAIL, status: 'invalid' },
      };
      mockPost.mockResolvedValueOnce(envelope(failResponse));

      const result = await acmeDnsCredentialsApi.testConnectivity('cred-001');

      expect(result.ok).toBe(false);
      expect(result.reason).toBe('Invalid API token');
    });

    it('returns response without optional details field', async () => {
      const responseNoDetails: AcmeDnsCredentialTestResponse = {
        ok: true,
        reason: 'OK',
        credential: CREDENTIAL_DETAIL,
      };
      mockPost.mockResolvedValueOnce(envelope(responseNoDetails));

      const result = await acmeDnsCredentialsApi.testConnectivity('cred-001');

      expect(result.details).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Service unavailable'));

      await expect(acmeDnsCredentialsApi.testConnectivity('cred-001')).rejects.toThrow('Service unavailable');
    });
  });

  // ---------------------------------------------------------------------------
  // rotate
  // ---------------------------------------------------------------------------

  describe('rotate', () => {
    const ROTATE_REQUEST: AcmeDnsCredentialRotateRequest = {
      credentials: { api_token: 'new_cf_token_xyz789' },
    };

    it('calls POST /system/acme_dns_credentials/:id/rotate with credentials payload', async () => {
      mockPost.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_SUMMARY }));

      await acmeDnsCredentialsApi.rotate('cred-001', ROTATE_REQUEST);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        '/system/acme_dns_credentials/cred-001/rotate',
        ROTATE_REQUEST,
      );
    });

    it('returns updated credential summary from nested envelope', async () => {
      const updatedSummary: AcmeDnsCredentialSummary = {
        ...CREDENTIAL_SUMMARY,
        status: 'untested',
        last_validated_at: null,
        updated_at: '2026-06-05T12:00:00Z',
      };
      mockPost.mockResolvedValueOnce(envelope({ credential: updatedSummary }));

      const result = await acmeDnsCredentialsApi.rotate('cred-001', ROTATE_REQUEST);

      expect(result).toEqual(updatedSummary);
      expect(result.id).toBe('cred-001');
    });

    it('sends new credentials in the rotate request body', async () => {
      mockPost.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_SUMMARY }));

      await acmeDnsCredentialsApi.rotate('cred-001', ROTATE_REQUEST);

      const call = mockPost.mock.calls[0];
      const body = call[1] as AcmeDnsCredentialRotateRequest;
      expect(body.credentials).toEqual({ api_token: 'new_cf_token_xyz789' });
    });

    it('supports rotating multi-field credentials (e.g. Route53)', async () => {
      const route53Rotate: AcmeDnsCredentialRotateRequest = {
        credentials: {
          access_key_id: 'NEWAKIAXXX',
          secret_access_key: 'newSecretKey',
          region: 'eu-west-1',
        },
      };
      mockPost.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_SUMMARY_2 }));

      const result = await acmeDnsCredentialsApi.rotate('cred-002', route53Rotate);

      expect(mockPost).toHaveBeenCalledWith(
        '/system/acme_dns_credentials/cred-002/rotate',
        route53Rotate,
      );
      expect(result.id).toBe('cred-002');
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Unprocessable entity'));

      await expect(acmeDnsCredentialsApi.rotate('cred-001', ROTATE_REQUEST)).rejects.toThrow('Unprocessable entity');
    });
  });

  // ---------------------------------------------------------------------------
  // URL construction edge cases
  // ---------------------------------------------------------------------------

  describe('URL construction', () => {
    it('uses exact BASE path /system/acme_dns_credentials for all collection routes', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));
      mockPost.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));

      await acmeDnsCredentialsApi.list();
      await acmeDnsCredentialsApi.create({
        name: 'test',
        provider: 'cloudflare',
        credentials: { api_token: 'tok' },
      });

      expect(mockGet.mock.calls[0][0]).toBe('/system/acme_dns_credentials');
      expect(mockPost.mock.calls[0][0]).toBe('/system/acme_dns_credentials');
    });

    it('uses exact resource path /system/acme_dns_credentials/:id for single-resource routes', async () => {
      mockGet.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));
      mockPatch.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_DETAIL }));
      mockDelete.mockResolvedValueOnce(envelope(null));

      await acmeDnsCredentialsApi.get('cred-xyz');
      await acmeDnsCredentialsApi.updateName('cred-xyz', 'n');
      await acmeDnsCredentialsApi.destroy('cred-xyz');

      expect(mockGet.mock.calls[0][0]).toBe('/system/acme_dns_credentials/cred-xyz');
      expect(mockPatch.mock.calls[0][0]).toBe('/system/acme_dns_credentials/cred-xyz');
      expect(mockDelete.mock.calls[0][0]).toBe('/system/acme_dns_credentials/cred-xyz');
    });

    it('builds sub-action URLs correctly for test_connectivity and rotate', async () => {
      mockPost.mockResolvedValueOnce(envelope(TEST_RESPONSE));
      mockPost.mockResolvedValueOnce(envelope({ credential: CREDENTIAL_SUMMARY }));

      await acmeDnsCredentialsApi.testConnectivity('cred-abc');
      await acmeDnsCredentialsApi.rotate('cred-abc', { credentials: { api_token: 'tok' } });

      expect(mockPost.mock.calls[0][0]).toBe('/system/acme_dns_credentials/cred-abc/test_connectivity');
      expect(mockPost.mock.calls[1][0]).toBe('/system/acme_dns_credentials/cred-abc/rotate');
    });
  });
});
