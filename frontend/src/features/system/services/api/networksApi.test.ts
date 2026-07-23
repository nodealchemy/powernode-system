// Behavioral tests for networksApi.
//
// Covers every exported method: exact URL, params, payload, envelope
// unwrapping, optional-argument edge cases, and API error propagation.

import { networksApi } from './networksApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Build a double-envelope AxiosResponse body for a non-paginated success. */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

/** Build a double-envelope AxiosResponse body for a paginated success.
 *  meta lives at the root of the body — NOT inside data. */
function paginatedEnvelope<T>(payload: T, meta?: Partial<PaginationMetaShape>) {
  const defaultMeta: PaginationMetaShape = {
    current_page: 1,
    per_page: 25,
    total_count: 1,
    total_pages: 1,
    next_page: null,
    prev_page: null,
  };
  return {
    data: {
      success: true,
      data: payload,
      meta: { ...defaultMeta, ...meta },
    },
  };
}

interface PaginationMetaShape {
  current_page: number;
  per_page: number;
  total_count: number;
  total_pages: number;
  next_page: number | null;
  prev_page: number | null;
}

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_A = {
  id: 'net-1',
  name: 'primary-vpc',
  description: 'Main VPC',
  cidr_block: '10.0.0.0/16',
  status: 'active',
  is_default: true,
  dns_support: true,
  dns_hostnames: true,
  config: {},
  provider_region_id: 'region-1',
  provider_region_name: 'us-east-1',
  region_name: 'US East',
  subnet_count: 3,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const NETWORK_B = {
  id: 'net-2',
  name: 'secondary-vpc',
  description: undefined,
  cidr_block: '172.16.0.0/12',
  status: 'inactive',
  is_default: false,
  dns_support: false,
  dns_hostnames: false,
  config: { mtu: 9001 },
  provider_region_id: 'region-2',
  provider_region_name: 'eu-west-1',
  region_name: 'EU West',
  subnet_count: 0,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-02T00:00:00Z',
};

const SUBNET_A = {
  id: 'subnet-1',
  name: 'public-a',
  description: 'Public subnet AZ-a',
  cidr_block: '10.0.1.0/24',
  status: 'available',
  is_public: true,
  enabled: true,
  config: {},
  provider_network_id: 'net-1',
  network_name: 'primary-vpc',
  provider_availability_zone_id: 'az-1',
  availability_zone_name: 'us-east-1a',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const SUBNET_B = {
  id: 'subnet-2',
  name: 'private-b',
  description: 'Private subnet AZ-b',
  cidr_block: '10.0.2.0/24',
  status: 'available',
  is_public: false,
  enabled: true,
  config: {},
  provider_network_id: 'net-1',
  network_name: 'primary-vpc',
  provider_availability_zone_id: 'az-2',
  availability_zone_name: 'us-east-1b',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const BASE = '/system/provider_networks';

// =============================================================================
// Tests
// =============================================================================

describe('networksApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // getNetworks
  // ---------------------------------------------------------------------------

  describe('getNetworks()', () => {
    it('calls GET /system/provider_networks with no params when called without arguments', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ networks: [NETWORK_A, NETWORK_B] }, { total_count: 2, total_pages: 1 })
      );

      await networksApi.getNetworks();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: undefined });
    });

    it('passes filter params when provided', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ networks: [NETWORK_A] }));

      await networksApi.getNetworks({ provider_region_id: 'region-1', search: 'primary', page: 2, per_page: 10 });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { provider_region_id: 'region-1', search: 'primary', page: 2, per_page: 10 },
      });
    });

    it('passes only provider_region_id when that is the sole filter', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ networks: [NETWORK_A] }));

      await networksApi.getNetworks({ provider_region_id: 'region-2' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { provider_region_id: 'region-2' } });
    });

    it('passes only search when that is the sole filter', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ networks: [] }, { total_count: 0 }));

      await networksApi.getNetworks({ search: 'vpc' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { search: 'vpc' } });
    });

    it('returns { networks, meta } from the paginated envelope', async () => {
      const meta = {
        current_page: 1,
        per_page: 25,
        total_count: 2,
        total_pages: 1,
        next_page: null,
        prev_page: null,
      };
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ networks: [NETWORK_A, NETWORK_B] }, { total_count: 2 }));

      const result = await networksApi.getNetworks();

      expect(result.networks).toHaveLength(2);
      expect(result.networks[0].id).toBe('net-1');
      expect(result.networks[1].id).toBe('net-2');
      expect(result.meta.total_count).toBe(2);
      expect(result.meta.current_page).toBe(meta.current_page);
    });

    it('meta is NOT nested inside data — it lives at the response body root', async () => {
      // This asserts the double-envelope contract: meta is in response.data.meta
      // not response.data.data.meta — the extractPaginated helper enforces this.
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ networks: [NETWORK_A] }, { total_pages: 3, total_count: 75 }));

      const result = await networksApi.getNetworks();

      expect(result.meta.total_pages).toBe(3);
      expect(result.meta.total_count).toBe(75);
      // networks should be the data payload, not the wrapper
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('returns empty networks array and synthesized meta when no results', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ networks: [] }, { total_count: 0, total_pages: 1 }));

      const result = await networksApi.getNetworks();

      expect(result.networks).toEqual([]);
      expect(result.meta.total_count).toBe(0);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(networksApi.getNetworks()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // getNetwork
  // ---------------------------------------------------------------------------

  describe('getNetwork()', () => {
    it('calls GET /system/provider_networks/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      await networksApi.getNetwork('net-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/net-1`);
    });

    it('uses the supplied id in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ network: NETWORK_B }));

      await networksApi.getNetwork('net-abc-999');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/net-abc-999`);
    });

    it('unwraps the nested .network from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      const result = await networksApi.getNetwork('net-1');

      expect(result).toEqual(NETWORK_A);
      expect(result.id).toBe('net-1');
      expect(result.name).toBe('primary-vpc');
      expect(result.cidr_block).toBe('10.0.0.0/16');
    });

    it('does NOT return the { network: ... } wrapper — must unwrap', async () => {
      mockGet.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      const result = await networksApi.getNetwork('net-1');

      expect((result as unknown as Record<string, unknown>)['network']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(networksApi.getNetwork('missing')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // createNetwork
  // ---------------------------------------------------------------------------

  describe('createNetwork()', () => {
    const FULL_CREATE = {
      name: 'my-vpc',
      description: 'A test VPC',
      provider_region_id: 'region-1',
      cidr_block: '192.168.0.0/16',
      is_public: false,
      enabled: true,
      config: { dhcp_options: true },
    };

    const MINIMAL_CREATE = {
      name: 'bare-vpc',
      provider_region_id: 'region-1',
    };

    it('calls POST /system/provider_networks with network wrapper', async () => {
      mockPost.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      await networksApi.createNetwork(FULL_CREATE);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(BASE, { network: FULL_CREATE });
    });

    it('wraps the payload in { network: data } before sending', async () => {
      mockPost.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      await networksApi.createNetwork(FULL_CREATE);

      const [, body] = mockPost.mock.calls[0] as [string, { network: typeof FULL_CREATE }];
      expect(body).toEqual({ network: FULL_CREATE });
      expect(body.network.name).toBe('my-vpc');
      expect(body.network.provider_region_id).toBe('region-1');
    });

    it('works with only required fields (name + provider_region_id)', async () => {
      mockPost.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      await networksApi.createNetwork(MINIMAL_CREATE);

      expect(mockPost).toHaveBeenCalledWith(BASE, { network: MINIMAL_CREATE });
    });

    it('returns the unwrapped network from the response', async () => {
      mockPost.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      const result = await networksApi.createNetwork(FULL_CREATE);

      expect(result).toEqual(NETWORK_A);
      expect(result.id).toBe('net-1');
    });

    it('does NOT return the { network: ... } wrapper', async () => {
      mockPost.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      const result = await networksApi.createNetwork(FULL_CREATE);

      expect((result as unknown as Record<string, unknown>)['network']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(networksApi.createNetwork(FULL_CREATE)).rejects.toThrow('Validation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // updateNetwork
  // ---------------------------------------------------------------------------

  describe('updateNetwork()', () => {
    const FULL_UPDATE = {
      name: 'renamed-vpc',
      description: 'Updated description',
      cidr_block: '10.1.0.0/16',
      is_public: true,
      enabled: false,
      config: { updated: true },
    };

    it('calls PUT /system/provider_networks/:id with network wrapper', async () => {
      mockPut.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      await networksApi.updateNetwork('net-1', FULL_UPDATE);

      expect(mockPut).toHaveBeenCalledTimes(1);
      expect(mockPut).toHaveBeenCalledWith(`${BASE}/net-1`, { network: FULL_UPDATE });
    });

    it('uses the supplied id in the URL', async () => {
      mockPut.mockResolvedValueOnce(envelope({ network: NETWORK_B }));

      await networksApi.updateNetwork('net-abc-xyz', FULL_UPDATE);

      expect(mockPut).toHaveBeenCalledWith(`${BASE}/net-abc-xyz`, { network: FULL_UPDATE });
    });

    it('wraps the payload in { network: data } before sending', async () => {
      mockPut.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      await networksApi.updateNetwork('net-1', FULL_UPDATE);

      const [, body] = mockPut.mock.calls[0] as [string, { network: typeof FULL_UPDATE }];
      expect(body).toEqual({ network: FULL_UPDATE });
    });

    it('works with a partial update (only name)', async () => {
      mockPut.mockResolvedValueOnce(envelope({ network: { ...NETWORK_A, name: 'new-name' } }));

      await networksApi.updateNetwork('net-1', { name: 'new-name' });

      expect(mockPut).toHaveBeenCalledWith(`${BASE}/net-1`, { network: { name: 'new-name' } });
    });

    it('works with a partial update (only enabled flag)', async () => {
      mockPut.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      await networksApi.updateNetwork('net-1', { enabled: false });

      expect(mockPut).toHaveBeenCalledWith(`${BASE}/net-1`, { network: { enabled: false } });
    });

    it('returns the unwrapped updated network', async () => {
      const updated = { ...NETWORK_A, name: 'renamed-vpc' };
      mockPut.mockResolvedValueOnce(envelope({ network: updated }));

      const result = await networksApi.updateNetwork('net-1', { name: 'renamed-vpc' });

      expect(result).toEqual(updated);
      expect(result.name).toBe('renamed-vpc');
    });

    it('does NOT return the { network: ... } wrapper', async () => {
      mockPut.mockResolvedValueOnce(envelope({ network: NETWORK_A }));

      const result = await networksApi.updateNetwork('net-1', { name: 'x' });

      expect((result as unknown as Record<string, unknown>)['network']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPut.mockRejectedValueOnce(new Error('Update failed'));

      await expect(networksApi.updateNetwork('net-1', { name: 'x' })).rejects.toThrow('Update failed');
    });
  });

  // ---------------------------------------------------------------------------
  // deleteNetwork
  // ---------------------------------------------------------------------------

  describe('deleteNetwork()', () => {
    it('calls DELETE /system/provider_networks/:id', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await networksApi.deleteNetwork('net-1');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/net-1`);
    });

    it('uses the supplied id in the URL', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await networksApi.deleteNetwork('net-xyz-999');

      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/net-xyz-999`);
    });

    it('resolves to void (returns undefined)', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      const result = await networksApi.deleteNetwork('net-1');

      expect(result).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Delete failed'));

      await expect(networksApi.deleteNetwork('net-1')).rejects.toThrow('Delete failed');
    });
  });

  // ---------------------------------------------------------------------------
  // getNetworkSubnets
  // ---------------------------------------------------------------------------

  describe('getNetworkSubnets()', () => {
    it('calls GET /system/provider_networks/:networkId/provider_network_subnets with empty params when no AZ filter', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnets: [SUBNET_A, SUBNET_B] }));

      await networksApi.getNetworkSubnets('net-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/net-1/provider_network_subnets`, { params: {} });
    });

    it('passes availability_zone_id param when provided', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnets: [SUBNET_A] }));

      await networksApi.getNetworkSubnets('net-1', 'az-1');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/net-1/provider_network_subnets`, {
        params: { availability_zone_id: 'az-1' },
      });
    });

    it('does NOT pass availability_zone_id when omitted', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnets: [] }));

      await networksApi.getNetworkSubnets('net-1');

      const [, options] = mockGet.mock.calls[0] as [string, { params: Record<string, unknown> }];
      expect(options.params).toEqual({});
      expect(options.params['availability_zone_id']).toBeUndefined();
    });

    it('uses the supplied networkId in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnets: [] }));

      await networksApi.getNetworkSubnets('net-abc-789');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/net-abc-789/provider_network_subnets`, expect.any(Object));
    });

    it('returns the array of subnets unwrapped from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnets: [SUBNET_A, SUBNET_B] }));

      const result = await networksApi.getNetworkSubnets('net-1');

      expect(result).toHaveLength(2);
      expect(result[0]).toEqual(SUBNET_A);
      expect(result[1]).toEqual(SUBNET_B);
    });

    it('returns an empty array when subnets is undefined in the response', async () => {
      // Backend may omit the subnets key — the ?? [] guard should handle this.
      mockGet.mockResolvedValueOnce(envelope({}));

      const result = await networksApi.getNetworkSubnets('net-1');

      expect(result).toEqual([]);
    });

    it('returns an empty array when subnets is an empty array', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnets: [] }));

      const result = await networksApi.getNetworkSubnets('net-1');

      expect(result).toEqual([]);
    });

    it('filters to the specified AZ when availability_zone_id is given', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnets: [SUBNET_A] }));

      const result = await networksApi.getNetworkSubnets('net-1', 'az-1');

      expect(result).toHaveLength(1);
      expect(result[0].provider_availability_zone_id).toBe('az-1');
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/net-1/provider_network_subnets`, {
        params: { availability_zone_id: 'az-1' },
      });
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Subnet fetch failed'));

      await expect(networksApi.getNetworkSubnets('net-1')).rejects.toThrow('Subnet fetch failed');
    });
  });

  // ---------------------------------------------------------------------------
  // getNetworkSubnet
  // ---------------------------------------------------------------------------

  describe('getNetworkSubnet()', () => {
    it('calls GET /system/provider_networks/:networkId/provider_network_subnets/:subnetId', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnet: SUBNET_A }));

      await networksApi.getNetworkSubnet('net-1', 'subnet-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/net-1/provider_network_subnets/subnet-1`);
    });

    it('uses both networkId and subnetId in the URL path', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnet: SUBNET_B }));

      await networksApi.getNetworkSubnet('net-999', 'subnet-abc');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/net-999/provider_network_subnets/subnet-abc`);
    });

    it('unwraps the nested .subnet from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnet: SUBNET_A }));

      const result = await networksApi.getNetworkSubnet('net-1', 'subnet-1');

      expect(result).toEqual(SUBNET_A);
      expect(result.id).toBe('subnet-1');
      expect(result.name).toBe('public-a');
      expect(result.cidr_block).toBe('10.0.1.0/24');
    });

    it('does NOT return the { subnet: ... } wrapper — must unwrap', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnet: SUBNET_A }));

      const result = await networksApi.getNetworkSubnet('net-1', 'subnet-1');

      expect((result as unknown as Record<string, unknown>)['subnet']).toBeUndefined();
    });

    it('returns the private subnet correctly', async () => {
      mockGet.mockResolvedValueOnce(envelope({ subnet: SUBNET_B }));

      const result = await networksApi.getNetworkSubnet('net-1', 'subnet-2');

      expect(result).toEqual(SUBNET_B);
      expect(result.is_public).toBe(false);
      expect(result.availability_zone_name).toBe('us-east-1b');
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Subnet not found'));

      await expect(networksApi.getNetworkSubnet('net-1', 'missing')).rejects.toThrow('Subnet not found');
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping contract', () => {
    it('getNetworks correctly extracts data from paginated double-envelope', async () => {
      // The API client returns AxiosResponse<PaginatedEnvelope<T>> — body is
      // { success: true, data: <payload>, meta: <PaginationMeta> }.
      // extractPaginated() must reach the inner data and merge with root meta.
      const payload = { networks: [NETWORK_A] };
      const meta = {
        current_page: 2,
        per_page: 10,
        total_count: 15,
        total_pages: 2,
        next_page: null,
        prev_page: 1,
      };
      mockGet.mockResolvedValueOnce({ data: { success: true, data: payload, meta } });

      const result = await networksApi.getNetworks({ page: 2, per_page: 10 });

      expect(result.networks).toHaveLength(1);
      expect(result.meta).toEqual(meta);
      // Must NOT contain envelope keys
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('getNetwork correctly extracts data from non-paginated double-envelope', async () => {
      // get() envelope shape: { success: true, data: { network: SystemProviderNetwork } }
      // The method must unwrap data.network, not return the wrapper object.
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { network: NETWORK_A } },
      });

      const result = await networksApi.getNetwork('net-1');

      expect(result.id).toBe('net-1');
      // Must NOT be the { network: ... } wrapper
      expect((result as unknown as Record<string, unknown>)['network']).toBeUndefined();
    });

    it('createNetwork correctly extracts data from the post response envelope', async () => {
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: { network: NETWORK_B } },
      });

      const result = await networksApi.createNetwork({ name: 'x', provider_region_id: 'r-1' });

      expect(result.id).toBe('net-2');
      expect((result as unknown as Record<string, unknown>)['network']).toBeUndefined();
    });

    it('updateNetwork correctly extracts data from the put response envelope', async () => {
      const updated = { ...NETWORK_A, name: 'updated' };
      mockPut.mockResolvedValueOnce({
        data: { success: true, data: { network: updated } },
      });

      const result = await networksApi.updateNetwork('net-1', { name: 'updated' });

      expect(result.name).toBe('updated');
      expect((result as unknown as Record<string, unknown>)['network']).toBeUndefined();
    });

    it('getNetworkSubnets correctly extracts data from non-paginated double-envelope', async () => {
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { subnets: [SUBNET_A] } },
      });

      const result = await networksApi.getNetworkSubnets('net-1');

      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('subnet-1');
      expect((result as unknown as Record<string, unknown>)['subnets']).toBeUndefined();
    });
  });
});
