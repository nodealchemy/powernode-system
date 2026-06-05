// Behavioral tests for acmeCertificatesApi.
//
// Covers every exported method: exact URL, params, payload, envelope
// unwrapping, timeout option, and optional-argument edge cases.

import { acmeCertificatesApi } from './acmeCertificatesApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Build a double-envelope AxiosResponse body for a generic success. */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const CERT_SUMMARY = {
  id: 'cert-1',
  common_name: 'example.com',
  sans: ['www.example.com'],
  status: 'valid' as const,
  issuer: 'letsencrypt-prod' as const,
  challenge_type: 'dns-01' as const,
  dns_credential_id: 'cred-1',
  issued_at: '2026-01-01T00:00:00Z',
  expires_at: '2026-04-01T00:00:00Z',
  days_until_expiry: 90,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
  vault_paths_present: true,
  terminal: false,
  last_renewal_error: null,
};

const CERT_DETAIL = {
  ...CERT_SUMMARY,
  dns_credential_name: 'my-cloudflare',
  dns_credential_provider: 'cloudflare',
  traefik_resolver_name: 'le-prod',
  metadata: {},
};

const LIST_RESPONSE = {
  certificates: [CERT_SUMMARY],
  count: 1,
  issuers: ['letsencrypt-prod'],
};

const ACTION_RESPONSE = {
  ok: true,
  certificate: CERT_DETAIL,
};

const BASE = '/system/acme_certificates';

// =============================================================================
// Tests
// =============================================================================

describe('acmeCertificatesApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('calls GET /system/acme_certificates with no params when no status provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      const result = await acmeCertificatesApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: undefined });
      expect(result).toEqual(LIST_RESPONSE);
    });

    it('passes status as a query param when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      await acmeCertificatesApi.list('valid');

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { status: 'valid' } });
    });

    it('passes "pending" status correctly', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      await acmeCertificatesApi.list('pending');

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { status: 'pending' } });
    });

    it('passes "expired" status correctly', async () => {
      mockGet.mockResolvedValueOnce(envelope(LIST_RESPONSE));

      await acmeCertificatesApi.list('expired');

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { status: 'expired' } });
    });

    it('returns the unwrapped list payload', async () => {
      const customList = {
        certificates: [CERT_SUMMARY, { ...CERT_SUMMARY, id: 'cert-2', common_name: 'other.com' }],
        count: 2,
        issuers: ['letsencrypt-prod', 'letsencrypt-staging'],
      };
      mockGet.mockResolvedValueOnce(envelope(customList));

      const result = await acmeCertificatesApi.list();

      expect(result.certificates).toHaveLength(2);
      expect(result.count).toBe(2);
      expect(result.issuers).toEqual(['letsencrypt-prod', 'letsencrypt-staging']);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(acmeCertificatesApi.list()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // get
  // ---------------------------------------------------------------------------

  describe('get()', () => {
    it('calls GET /system/acme_certificates/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ certificate: CERT_DETAIL }));

      await acmeCertificatesApi.get('cert-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/cert-1`);
    });

    it('unwraps the nested .certificate from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ certificate: CERT_DETAIL }));

      const result = await acmeCertificatesApi.get('cert-1');

      expect(result).toEqual(CERT_DETAIL);
      expect(result.dns_credential_name).toBe('my-cloudflare');
      expect(result.traefik_resolver_name).toBe('le-prod');
    });

    it('uses the supplied id in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ certificate: CERT_DETAIL }));

      await acmeCertificatesApi.get('cert-abc-999');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/cert-abc-999`);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(acmeCertificatesApi.get('missing')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // create
  // ---------------------------------------------------------------------------

  describe('create()', () => {
    const CREATE_REQUEST = {
      common_name: 'example.com',
      dns_credential_id: 'cred-1',
      issuer: 'letsencrypt-prod' as const,
      acme_email: 'admin@example.com',
      sans: ['www.example.com'],
      traefik_resolver_name: 'le-prod',
    };

    it('calls POST /system/acme_certificates with the full request body', async () => {
      mockPost.mockResolvedValueOnce(envelope({ certificate: CERT_DETAIL }));

      await acmeCertificatesApi.create(CREATE_REQUEST);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(BASE, CREATE_REQUEST);
    });

    it('returns the unwrapped certificate detail', async () => {
      mockPost.mockResolvedValueOnce(envelope({ certificate: CERT_DETAIL }));

      const result = await acmeCertificatesApi.create(CREATE_REQUEST);

      expect(result).toEqual(CERT_DETAIL);
      expect(result.id).toBe('cert-1');
      expect(result.common_name).toBe('example.com');
    });

    it('works without optional sans and traefik_resolver_name', async () => {
      const minimalRequest = {
        common_name: 'minimal.com',
        dns_credential_id: 'cred-2',
        issuer: 'letsencrypt-staging' as const,
        acme_email: 'admin@minimal.com',
      };
      mockPost.mockResolvedValueOnce(envelope({ certificate: CERT_DETAIL }));

      await acmeCertificatesApi.create(minimalRequest);

      expect(mockPost).toHaveBeenCalledWith(BASE, minimalRequest);
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(acmeCertificatesApi.create(CREATE_REQUEST)).rejects.toThrow('Validation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // requestIssue
  // ---------------------------------------------------------------------------

  describe('requestIssue()', () => {
    it('calls POST /system/acme_certificates/:id/request_issue with empty body', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      await acmeCertificatesApi.requestIssue('cert-1');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        `${BASE}/cert-1/request_issue`,
        {},
        { timeout: 240_000 },
      );
    });

    it('sets a 240-second timeout to accommodate DNS propagation', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      await acmeCertificatesApi.requestIssue('cert-1');

      const [, , options] = mockPost.mock.calls[0] as [string, object, { timeout: number }];
      expect(options.timeout).toBe(240_000);
    });

    it('returns the unwrapped action response', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      const result = await acmeCertificatesApi.requestIssue('cert-1');

      expect(result.ok).toBe(true);
      expect(result.certificate).toEqual(CERT_DETAIL);
    });

    it('uses the supplied id in the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      await acmeCertificatesApi.requestIssue('cert-xyz');

      expect(mockPost).toHaveBeenCalledWith(
        `${BASE}/cert-xyz/request_issue`,
        {},
        { timeout: 240_000 },
      );
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('ACME error'));

      await expect(acmeCertificatesApi.requestIssue('cert-1')).rejects.toThrow('ACME error');
    });
  });

  // ---------------------------------------------------------------------------
  // renew
  // ---------------------------------------------------------------------------

  describe('renew()', () => {
    it('calls POST /system/acme_certificates/:id/renew with empty body and 240s timeout', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      await acmeCertificatesApi.renew('cert-1');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        `${BASE}/cert-1/renew`,
        {},
        { timeout: 240_000 },
      );
    });

    it('sets a 240-second timeout matching the ACME ceremony duration', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      await acmeCertificatesApi.renew('cert-1');

      const [, , options] = mockPost.mock.calls[0] as [string, object, { timeout: number }];
      expect(options.timeout).toBe(240_000);
    });

    it('returns the unwrapped action response', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      const result = await acmeCertificatesApi.renew('cert-1');

      expect(result.ok).toBe(true);
      expect(result.certificate.id).toBe('cert-1');
    });

    it('uses the supplied id in the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      await acmeCertificatesApi.renew('cert-99');

      expect(mockPost).toHaveBeenCalledWith(
        `${BASE}/cert-99/renew`,
        {},
        { timeout: 240_000 },
      );
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Renewal failed'));

      await expect(acmeCertificatesApi.renew('cert-1')).rejects.toThrow('Renewal failed');
    });
  });

  // ---------------------------------------------------------------------------
  // revoke
  // ---------------------------------------------------------------------------

  describe('revoke()', () => {
    it('calls POST /system/acme_certificates/:id/revoke with empty body when no reason', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      await acmeCertificatesApi.revoke('cert-1');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/cert-1/revoke`, {});
    });

    it('includes the reason in the body when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      await acmeCertificatesApi.revoke('cert-1', 'superseded');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/cert-1/revoke`, { reason: 'superseded' });
    });

    it('does NOT pass a timeout option (unlike requestIssue/renew)', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      await acmeCertificatesApi.revoke('cert-1');

      // revoke call should have only 2 arguments — no options object
      expect(mockPost.mock.calls[0]).toHaveLength(2);
    });

    it('returns the unwrapped action response', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      const result = await acmeCertificatesApi.revoke('cert-1', 'key-compromise');

      expect(result.ok).toBe(true);
      expect(result.certificate).toEqual(CERT_DETAIL);
    });

    it('uses the supplied id in the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope(ACTION_RESPONSE));

      await acmeCertificatesApi.revoke('cert-abc');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/cert-abc/revoke`, {});
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Revocation failed'));

      await expect(acmeCertificatesApi.revoke('cert-1')).rejects.toThrow('Revocation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // destroy
  // ---------------------------------------------------------------------------

  describe('destroy()', () => {
    it('calls DELETE /system/acme_certificates/:id', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await acmeCertificatesApi.destroy('cert-1');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/cert-1`);
    });

    it('resolves to void (returns undefined)', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      const result = await acmeCertificatesApi.destroy('cert-1');

      expect(result).toBeUndefined();
    });

    it('uses the supplied id in the URL', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await acmeCertificatesApi.destroy('cert-xyz-999');

      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/cert-xyz-999`);
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Delete failed'));

      await expect(acmeCertificatesApi.destroy('cert-1')).rejects.toThrow('Delete failed');
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('correctly extracts data from double-envelope { data: { success, data: payload } }', async () => {
      // The API client returns AxiosResponse<ApiEnvelope<T>> — body is
      // { success: true, data: <payload> }. extractData() must reach the
      // inner data, not return the envelope wrapper itself.
      const payload = { certificates: [], count: 0, issuers: [] };
      mockGet.mockResolvedValueOnce({ data: { success: true, data: payload } });

      const result = await acmeCertificatesApi.list();

      expect(result).toEqual(payload);
      // Must NOT contain envelope keys
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('correctly extracts nested .certificate from get() envelope', async () => {
      // get() envelope shape: { success: true, data: { certificate: AcmeCertificateDetail } }
      // The method must unwrap data.certificate, not return the wrapper object.
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { certificate: CERT_DETAIL } },
      });

      const result = await acmeCertificatesApi.get('cert-1');

      expect(result.id).toBe('cert-1');
      // Must NOT be the { certificate: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['certificate']).toBeUndefined();
    });
  });
});
