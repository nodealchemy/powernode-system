// Behavioral tests for dnsRecordsApi.
//
// Covers every exported method: exact URL, params, payload shape, envelope
// unwrapping, and optional-argument edge cases.
//
// API double-envelope convention: apiClient.{get,post,patch,delete} resolve to
// an AxiosResponse whose body is { success: true, data: <payload> }.
// A mocked resolve is therefore { data: { success: true, data: <payload> } }.
// Pagination "meta" sits at the ROOT of the body — never inside data.

import { dnsRecordsApi } from './dnsRecordsApi';
import type {
  CloudflareZone,
  CreateRecordRequest,
  DnsRecord,
  UpdateRecordRequest,
} from '../../types/dns.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPatch = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
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

const CRED_ID = 'cred-cf-001';
const BASE = `/system/acme_dns_credentials/${CRED_ID}`;

const ZONE_A: CloudflareZone = {
  id: 'zone-aaa',
  name: 'example.com',
  status: 'active',
  type: 'full',
  paused: false,
  account: { id: 'acct-1', name: 'Acme Corp' },
};

const ZONE_B: CloudflareZone = {
  id: 'zone-bbb',
  name: 'staging.example.com',
  status: 'active',
  type: 'partial',
  paused: true,
};

const RECORD_A: DnsRecord = {
  id: 'rec-111',
  zone_id: 'zone-aaa',
  zone_name: 'example.com',
  type: 'A',
  name: 'www.example.com',
  content: '1.2.3.4',
  ttl: 300,
  proxied: true,
  comment: 'main www',
  tags: ['web'],
  created_on: '2026-01-01T00:00:00Z',
  modified_on: '2026-06-01T00:00:00Z',
};

const RECORD_B: DnsRecord = {
  id: 'rec-222',
  zone_id: 'zone-aaa',
  zone_name: 'example.com',
  type: 'TXT',
  name: '_dmarc.example.com',
  content: 'v=DMARC1; p=none',
  ttl: 1,
  proxied: false,
  comment: null,
  tags: [],
};

const MX_RECORD: DnsRecord = {
  id: 'rec-333',
  zone_id: 'zone-aaa',
  type: 'MX',
  name: 'example.com',
  content: 'mail.example.com',
  ttl: 3600,
  priority: 10,
};

// =============================================================================
// Tests
// =============================================================================

describe('dnsRecordsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPatch.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // listZones
  // ---------------------------------------------------------------------------

  describe('listZones()', () => {
    it('calls GET /{base}/zones without params when name is omitted', async () => {
      mockGet.mockResolvedValueOnce(envelope({ zones: [ZONE_A, ZONE_B] }));

      const result = await dnsRecordsApi.listZones(CRED_ID);

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/zones`, { params: {} });
      expect(result).toEqual([ZONE_A, ZONE_B]);
    });

    it('passes name as a query param when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ zones: [ZONE_A] }));

      await dnsRecordsApi.listZones(CRED_ID, 'example.com');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/zones`, { params: { name: 'example.com' } });
    });

    it('returns only the zones array from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ zones: [ZONE_A, ZONE_B] }));

      const result = await dnsRecordsApi.listZones(CRED_ID);

      expect(result).toHaveLength(2);
      expect(result[0].id).toBe('zone-aaa');
      expect(result[1].id).toBe('zone-bbb');
    });

    it('returns an empty array when the zones list is empty', async () => {
      mockGet.mockResolvedValueOnce(envelope({ zones: [] }));

      const result = await dnsRecordsApi.listZones(CRED_ID);

      expect(result).toEqual([]);
    });

    it('returns zone detail fields: id, name, status, type, paused, account', async () => {
      mockGet.mockResolvedValueOnce(envelope({ zones: [ZONE_A] }));

      const result = await dnsRecordsApi.listZones(CRED_ID);

      const zone = result[0];
      expect(zone.id).toBe('zone-aaa');
      expect(zone.name).toBe('example.com');
      expect(zone.status).toBe('active');
      expect(zone.type).toBe('full');
      expect(zone.paused).toBe(false);
      expect(zone.account).toEqual({ id: 'acct-1', name: 'Acme Corp' });
    });

    it('builds the base URL from the credentialId argument', async () => {
      const otherCredId = 'cred-other-999';
      mockGet.mockResolvedValueOnce(envelope({ zones: [] }));

      await dnsRecordsApi.listZones(otherCredId);

      expect(mockGet.mock.calls[0][0]).toBe(
        `/system/acme_dns_credentials/${otherCredId}/zones`,
      );
    });

    it('sends empty params object (not undefined) when name filter is omitted', async () => {
      mockGet.mockResolvedValueOnce(envelope({ zones: [] }));

      await dnsRecordsApi.listZones(CRED_ID);

      const [, options] = mockGet.mock.calls[0] as [string, { params: Record<string, string> }];
      expect(options.params).toEqual({});
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Unauthorized'));

      await expect(dnsRecordsApi.listZones(CRED_ID)).rejects.toThrow('Unauthorized');
    });
  });

  // ---------------------------------------------------------------------------
  // listRecords
  // ---------------------------------------------------------------------------

  describe('listRecords()', () => {
    it('calls GET /{base}/records with zone_id and no extra filters', async () => {
      mockGet.mockResolvedValueOnce(envelope({ records: [RECORD_A, RECORD_B] }));

      const result = await dnsRecordsApi.listRecords(CRED_ID, 'zone-aaa');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/records`, {
        params: { zone_id: 'zone-aaa' },
      });
      expect(result).toEqual([RECORD_A, RECORD_B]);
    });

    it('merges type filter into params when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ records: [RECORD_B] }));

      await dnsRecordsApi.listRecords(CRED_ID, 'zone-aaa', { type: 'TXT' });

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/records`, {
        params: { zone_id: 'zone-aaa', type: 'TXT' },
      });
    });

    it('merges name filter into params when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ records: [RECORD_A] }));

      await dnsRecordsApi.listRecords(CRED_ID, 'zone-aaa', { name: 'www.example.com' });

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/records`, {
        params: { zone_id: 'zone-aaa', name: 'www.example.com' },
      });
    });

    it('merges both type and name filters when both are provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ records: [RECORD_A] }));

      await dnsRecordsApi.listRecords(CRED_ID, 'zone-aaa', {
        type: 'A',
        name: 'www.example.com',
      });

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/records`, {
        params: { zone_id: 'zone-aaa', type: 'A', name: 'www.example.com' },
      });
    });

    it('sends only zone_id when filters is undefined (omitted)', async () => {
      mockGet.mockResolvedValueOnce(envelope({ records: [] }));

      await dnsRecordsApi.listRecords(CRED_ID, 'zone-bbb');

      const [, options] = mockGet.mock.calls[0] as [string, { params: Record<string, string> }];
      expect(options.params).toEqual({ zone_id: 'zone-bbb' });
    });

    it('sends only zone_id when filters is an empty object', async () => {
      mockGet.mockResolvedValueOnce(envelope({ records: [] }));

      await dnsRecordsApi.listRecords(CRED_ID, 'zone-bbb', {});

      const [, options] = mockGet.mock.calls[0] as [string, { params: Record<string, string> }];
      expect(options.params).toEqual({ zone_id: 'zone-bbb' });
    });

    it('returns only the records array from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ records: [RECORD_A, RECORD_B, MX_RECORD] }));

      const result = await dnsRecordsApi.listRecords(CRED_ID, 'zone-aaa');

      expect(result).toHaveLength(3);
      expect(result[0].id).toBe('rec-111');
      expect(result[1].id).toBe('rec-222');
      expect(result[2].id).toBe('rec-333');
    });

    it('returns an empty array when no records match', async () => {
      mockGet.mockResolvedValueOnce(envelope({ records: [] }));

      const result = await dnsRecordsApi.listRecords(CRED_ID, 'zone-aaa', { type: 'AAAA' });

      expect(result).toEqual([]);
    });

    it('returns record fields: id, zone_id, type, name, content, ttl, proxied, priority', async () => {
      mockGet.mockResolvedValueOnce(envelope({ records: [RECORD_A, MX_RECORD] }));

      const result = await dnsRecordsApi.listRecords(CRED_ID, 'zone-aaa');

      const a = result[0];
      expect(a.id).toBe('rec-111');
      expect(a.zone_id).toBe('zone-aaa');
      expect(a.type).toBe('A');
      expect(a.name).toBe('www.example.com');
      expect(a.content).toBe('1.2.3.4');
      expect(a.ttl).toBe(300);
      expect(a.proxied).toBe(true);

      const mx = result[1];
      expect(mx.priority).toBe(10);
    });

    it('builds the base URL from the credentialId argument', async () => {
      const otherId = 'cred-xyz';
      mockGet.mockResolvedValueOnce(envelope({ records: [] }));

      await dnsRecordsApi.listRecords(otherId, 'zone-aaa');

      expect(mockGet.mock.calls[0][0]).toBe(
        `/system/acme_dns_credentials/${otherId}/records`,
      );
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Forbidden'));

      await expect(dnsRecordsApi.listRecords(CRED_ID, 'zone-aaa')).rejects.toThrow('Forbidden');
    });
  });

  // ---------------------------------------------------------------------------
  // createRecord
  // ---------------------------------------------------------------------------

  describe('createRecord()', () => {
    const CREATE_A_REQUEST: CreateRecordRequest = {
      zone_id: 'zone-aaa',
      type: 'A',
      name: 'api.example.com',
      content: '10.0.0.1',
      ttl: 120,
      proxied: false,
      comment: 'API endpoint',
      tags: ['api'],
    };

    it('calls POST /{base}/records with the full request payload', async () => {
      mockPost.mockResolvedValueOnce(envelope({ record: RECORD_A }));

      await dnsRecordsApi.createRecord(CRED_ID, CREATE_A_REQUEST);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/records`, CREATE_A_REQUEST);
    });

    it('returns the created record from the nested envelope', async () => {
      mockPost.mockResolvedValueOnce(envelope({ record: RECORD_A }));

      const result = await dnsRecordsApi.createRecord(CRED_ID, CREATE_A_REQUEST);

      expect(result).toEqual(RECORD_A);
      expect(result.id).toBe('rec-111');
      expect(result.type).toBe('A');
      expect(result.name).toBe('www.example.com');
    });

    it('sends required fields: zone_id, type, name, content', async () => {
      const minimalRequest: CreateRecordRequest = {
        zone_id: 'zone-aaa',
        type: 'CNAME',
        name: 'mail.example.com',
        content: 'mail.google.com',
      };
      mockPost.mockResolvedValueOnce(envelope({ record: RECORD_A }));

      await dnsRecordsApi.createRecord(CRED_ID, minimalRequest);

      const [, body] = mockPost.mock.calls[0] as [string, CreateRecordRequest];
      expect(body.zone_id).toBe('zone-aaa');
      expect(body.type).toBe('CNAME');
      expect(body.name).toBe('mail.example.com');
      expect(body.content).toBe('mail.google.com');
    });

    it('passes optional ttl, proxied, priority, comment, tags through when provided', async () => {
      mockPost.mockResolvedValueOnce(envelope({ record: MX_RECORD }));

      const mxRequest: CreateRecordRequest = {
        zone_id: 'zone-aaa',
        type: 'MX',
        name: 'example.com',
        content: 'mail.example.com',
        ttl: 3600,
        priority: 10,
        comment: 'primary MX',
      };

      await dnsRecordsApi.createRecord(CRED_ID, mxRequest);

      const [, body] = mockPost.mock.calls[0] as [string, CreateRecordRequest];
      expect(body.ttl).toBe(3600);
      expect(body.priority).toBe(10);
      expect(body.comment).toBe('primary MX');
    });

    it('works with all supported record types', async () => {
      const types = ['A', 'AAAA', 'CNAME', 'TXT', 'MX', 'SRV', 'NS', 'CAA', 'PTR'] as const;

      for (const type of types) {
        mockPost.mockResolvedValueOnce(envelope({ record: { ...RECORD_A, type } }));

        const req: CreateRecordRequest = {
          zone_id: 'zone-aaa',
          type,
          name: 'test.example.com',
          content: '1.2.3.4',
        };
        const result = await dnsRecordsApi.createRecord(CRED_ID, req);
        expect(result.type).toBe(type);
      }
    });

    it('builds the base URL from the credentialId argument', async () => {
      const otherId = 'cred-alt';
      mockPost.mockResolvedValueOnce(envelope({ record: RECORD_A }));

      await dnsRecordsApi.createRecord(otherId, CREATE_A_REQUEST);

      expect(mockPost.mock.calls[0][0]).toBe(
        `/system/acme_dns_credentials/${otherId}/records`,
      );
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(dnsRecordsApi.createRecord(CRED_ID, CREATE_A_REQUEST)).rejects.toThrow(
        'Validation failed',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // updateRecord
  // ---------------------------------------------------------------------------

  describe('updateRecord()', () => {
    const UPDATE_REQUEST: UpdateRecordRequest = {
      zone_id: 'zone-aaa',
      content: '5.6.7.8',
      ttl: 600,
      proxied: true,
    };

    it('calls PATCH /{base}/records/:recordId with the update payload', async () => {
      const updated = { ...RECORD_A, content: '5.6.7.8', ttl: 600, proxied: true };
      mockPatch.mockResolvedValueOnce(envelope({ record: updated }));

      await dnsRecordsApi.updateRecord(CRED_ID, 'rec-111', UPDATE_REQUEST);

      expect(mockPatch).toHaveBeenCalledTimes(1);
      expect(mockPatch).toHaveBeenCalledWith(
        `${BASE}/records/rec-111`,
        UPDATE_REQUEST,
      );
    });

    it('returns the updated record from the nested envelope', async () => {
      const updated = { ...RECORD_A, content: '5.6.7.8' };
      mockPatch.mockResolvedValueOnce(envelope({ record: updated }));

      const result = await dnsRecordsApi.updateRecord(CRED_ID, 'rec-111', UPDATE_REQUEST);

      expect(result).toEqual(updated);
      expect(result.id).toBe('rec-111');
      expect(result.content).toBe('5.6.7.8');
    });

    it('includes zone_id in the update payload (required by Cloudflare)', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ record: RECORD_A }));

      await dnsRecordsApi.updateRecord(CRED_ID, 'rec-111', UPDATE_REQUEST);

      const [, body] = mockPatch.mock.calls[0] as [string, UpdateRecordRequest];
      expect(body.zone_id).toBe('zone-aaa');
    });

    it('sends only provided optional fields (partial update)', async () => {
      const partialUpdate: UpdateRecordRequest = {
        zone_id: 'zone-aaa',
        comment: 'updated comment',
      };
      mockPatch.mockResolvedValueOnce(envelope({ record: RECORD_A }));

      await dnsRecordsApi.updateRecord(CRED_ID, 'rec-111', partialUpdate);

      const [, body] = mockPatch.mock.calls[0] as [string, UpdateRecordRequest];
      expect(body.comment).toBe('updated comment');
      expect(body.content).toBeUndefined();
      expect(body.ttl).toBeUndefined();
    });

    it('uses the recordId in the URL path', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ record: RECORD_B }));

      await dnsRecordsApi.updateRecord(CRED_ID, 'rec-222', UPDATE_REQUEST);

      expect(mockPatch.mock.calls[0][0]).toBe(`${BASE}/records/rec-222`);
    });

    it('builds the base URL from the credentialId argument', async () => {
      const otherId = 'cred-alt-2';
      mockPatch.mockResolvedValueOnce(envelope({ record: RECORD_A }));

      await dnsRecordsApi.updateRecord(otherId, 'rec-111', UPDATE_REQUEST);

      expect(mockPatch.mock.calls[0][0]).toBe(
        `/system/acme_dns_credentials/${otherId}/records/rec-111`,
      );
    });

    it('supports updating priority for MX/SRV records', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ record: MX_RECORD }));

      await dnsRecordsApi.updateRecord(CRED_ID, 'rec-333', {
        zone_id: 'zone-aaa',
        priority: 20,
      });

      const [, body] = mockPatch.mock.calls[0] as [string, UpdateRecordRequest];
      expect(body.priority).toBe(20);
    });

    it('propagates API errors', async () => {
      mockPatch.mockRejectedValueOnce(new Error('Not found'));

      await expect(
        dnsRecordsApi.updateRecord(CRED_ID, 'rec-missing', UPDATE_REQUEST),
      ).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // deleteRecord
  // ---------------------------------------------------------------------------

  describe('deleteRecord()', () => {
    it('calls DELETE /{base}/records/:recordId with zone_id as a query param', async () => {
      mockDelete.mockResolvedValueOnce(envelope({ deleted: true }));

      await dnsRecordsApi.deleteRecord(CRED_ID, 'rec-111', 'zone-aaa');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/records/rec-111`, {
        params: { zone_id: 'zone-aaa' },
      });
    });

    it('resolves to void (returns undefined)', async () => {
      mockDelete.mockResolvedValueOnce(envelope({ deleted: true }));

      const result = await dnsRecordsApi.deleteRecord(CRED_ID, 'rec-111', 'zone-aaa');

      expect(result).toBeUndefined();
    });

    it('uses the recordId in the URL path', async () => {
      mockDelete.mockResolvedValueOnce(envelope({ deleted: true }));

      await dnsRecordsApi.deleteRecord(CRED_ID, 'rec-222', 'zone-aaa');

      expect(mockDelete.mock.calls[0][0]).toBe(`${BASE}/records/rec-222`);
    });

    it('passes the correct zone_id in query params', async () => {
      mockDelete.mockResolvedValueOnce(envelope({ deleted: true }));

      await dnsRecordsApi.deleteRecord(CRED_ID, 'rec-111', 'zone-bbb');

      const [, options] = mockDelete.mock.calls[0] as [string, { params: { zone_id: string } }];
      expect(options.params.zone_id).toBe('zone-bbb');
    });

    it('builds the base URL from the credentialId argument', async () => {
      const otherId = 'cred-del-99';
      mockDelete.mockResolvedValueOnce(envelope({ deleted: true }));

      await dnsRecordsApi.deleteRecord(otherId, 'rec-111', 'zone-aaa');

      expect(mockDelete.mock.calls[0][0]).toBe(
        `/system/acme_dns_credentials/${otherId}/records/rec-111`,
      );
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Record not found'));

      await expect(
        dnsRecordsApi.deleteRecord(CRED_ID, 'rec-missing', 'zone-aaa'),
      ).rejects.toThrow('Record not found');
    });

    it('does NOT use post/put/patch for deletion', async () => {
      mockDelete.mockResolvedValueOnce(envelope({ deleted: true }));

      await dnsRecordsApi.deleteRecord(CRED_ID, 'rec-111', 'zone-aaa');

      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPatch).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // URL construction — cross-method assertions
  // ---------------------------------------------------------------------------

  describe('URL construction', () => {
    it('uses exact base path /system/acme_dns_credentials/:credId for all routes', async () => {
      const credId = 'cred-url-test';
      const expectedBase = `/system/acme_dns_credentials/${credId}`;

      mockGet.mockResolvedValue(envelope({ zones: [], records: [] }));
      mockPost.mockResolvedValue(envelope({ record: RECORD_A }));
      mockPatch.mockResolvedValue(envelope({ record: RECORD_A }));
      mockDelete.mockResolvedValue(envelope({ deleted: true }));

      await dnsRecordsApi.listZones(credId);
      await dnsRecordsApi.listRecords(credId, 'zone-aaa');
      await dnsRecordsApi.createRecord(credId, {
        zone_id: 'zone-aaa',
        type: 'A',
        name: 'test.example.com',
        content: '1.2.3.4',
      });
      await dnsRecordsApi.updateRecord(credId, 'rec-111', { zone_id: 'zone-aaa' });
      await dnsRecordsApi.deleteRecord(credId, 'rec-111', 'zone-aaa');

      expect(mockGet.mock.calls[0][0]).toBe(`${expectedBase}/zones`);
      expect(mockGet.mock.calls[1][0]).toBe(`${expectedBase}/records`);
      expect(mockPost.mock.calls[0][0]).toBe(`${expectedBase}/records`);
      expect(mockPatch.mock.calls[0][0]).toBe(`${expectedBase}/records/rec-111`);
      expect(mockDelete.mock.calls[0][0]).toBe(`${expectedBase}/records/rec-111`);
    });

    it('listZones and listRecords both hit the GET verb, not post/patch/delete', async () => {
      mockGet.mockResolvedValue(envelope({ zones: [], records: [] }));

      await dnsRecordsApi.listZones(CRED_ID);
      await dnsRecordsApi.listRecords(CRED_ID, 'zone-aaa');

      expect(mockGet).toHaveBeenCalledTimes(2);
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPatch).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });

    it('createRecord hits the POST verb, not get/patch/delete', async () => {
      mockPost.mockResolvedValueOnce(envelope({ record: RECORD_A }));

      await dnsRecordsApi.createRecord(CRED_ID, {
        zone_id: 'zone-aaa',
        type: 'A',
        name: 'test.example.com',
        content: '1.2.3.4',
      });

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPatch).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });

    it('updateRecord hits the PATCH verb, not get/post/delete', async () => {
      mockPatch.mockResolvedValueOnce(envelope({ record: RECORD_A }));

      await dnsRecordsApi.updateRecord(CRED_ID, 'rec-111', { zone_id: 'zone-aaa' });

      expect(mockPatch).toHaveBeenCalledTimes(1);
      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping', () => {
    it('extracts zones array from double-envelope { data: { success, data: { zones } } }', async () => {
      const zones = [ZONE_A];
      mockGet.mockResolvedValueOnce({ data: { success: true, data: { zones } } });

      const result = await dnsRecordsApi.listZones(CRED_ID);

      expect(result).toEqual(zones);
      // Result must be the array, not the wrapper
      expect(Array.isArray(result)).toBe(true);
    });

    it('extracts records array from double-envelope { data: { success, data: { records } } }', async () => {
      const records = [RECORD_A, RECORD_B];
      mockGet.mockResolvedValueOnce({ data: { success: true, data: { records } } });

      const result = await dnsRecordsApi.listRecords(CRED_ID, 'zone-aaa');

      expect(result).toEqual(records);
      expect(Array.isArray(result)).toBe(true);
    });

    it('extracts record from double-envelope { data: { success, data: { record } } } for createRecord', async () => {
      mockPost.mockResolvedValueOnce({ data: { success: true, data: { record: RECORD_A } } });

      const result = await dnsRecordsApi.createRecord(CRED_ID, {
        zone_id: 'zone-aaa',
        type: 'A',
        name: 'test.example.com',
        content: '1.2.3.4',
      });

      expect(result).toEqual(RECORD_A);
      // Must NOT contain the envelope wrapper
      expect((result as unknown as Record<string, unknown>)['record']).toBeUndefined();
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('extracts record from double-envelope { data: { success, data: { record } } } for updateRecord', async () => {
      const updated = { ...RECORD_A, content: '9.9.9.9' };
      mockPatch.mockResolvedValueOnce({ data: { success: true, data: { record: updated } } });

      const result = await dnsRecordsApi.updateRecord(CRED_ID, 'rec-111', {
        zone_id: 'zone-aaa',
        content: '9.9.9.9',
      });

      expect(result).toEqual(updated);
      expect((result as unknown as Record<string, unknown>)['record']).toBeUndefined();
    });

    it('deleteRecord returns void even though the envelope contains { deleted: true }', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true, data: { deleted: true } } });

      const result = await dnsRecordsApi.deleteRecord(CRED_ID, 'rec-111', 'zone-aaa');

      expect(result).toBeUndefined();
    });
  });
});
