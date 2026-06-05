import { providersApi } from './providersApi';
import type { ProviderCreate, ProviderRegionCreate, ProviderConnectionCreate } from './providersApi';
import type {
  SystemProvider,
  SystemProviderRegion,
  SystemProviderConnection,
  SystemProviderInstanceType,
  SystemProviderAvailabilityZone,
} from '../../types/system.types';

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
// Double-envelope helper
// The backend wraps responses: { success: true, data: <payload> }
// AxiosResponse exposes the body as response.data, so:
//   mockGet.mockResolvedValue(envelope({ providers: [...] }))
//   → response.data = { success: true, data: { providers: [...] } }
//   → extractData(response) = { providers: [...] }
// =============================================================================

function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const PROVIDER_A: SystemProvider = {
  id: 'prov-1',
  name: 'AWS Primary',
  description: 'Primary AWS account',
  provider_type: 'aws',
  enabled: true,
  public: false,
  config: { region: 'us-east-1' },
  capabilities: { gpu: false },
  region_count: 3,
  connection_count: 1,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PROVIDER_B: SystemProvider = {
  id: 'prov-2',
  name: 'GCP Staging',
  provider_type: 'gcp',
  enabled: false,
  public: true,
  config: {},
  capabilities: {},
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

const REGION_A: SystemProviderRegion = {
  id: 'region-1',
  name: 'US East 1',
  description: 'Northern Virginia',
  endpoint_url: 'https://ec2.us-east-1.amazonaws.com',
  region_code: 'us-east-1',
  capabilities: {},
  provider_id: 'prov-1',
  provider_name: 'AWS Primary',
  zone_count: 3,
  instance_type_count: 42,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CONNECTION_A: SystemProviderConnection = {
  id: 'conn-1',
  name: 'AWS Prod Creds',
  description: 'Production access key',
  endpoint_url: undefined,
  config: {},
  provider_id: 'prov-1',
  provider_name: 'AWS Primary',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const INSTANCE_TYPE_A: SystemProviderInstanceType = {
  id: 'itype-1',
  name: 'General Purpose Medium',
  instance_type_code: 't3.medium',
  vcpus: 2,
  memory_mb: 4096,
  memory_gb: 4,
  storage_gb: 50,
  hourly_price: 0.0416,
  enabled: true,
  specs: { network: '5 Gbps' },
  display_name: 't3.medium (2 vCPU, 4 GB)',
  provider_id: 'prov-1',
  provider_name: 'AWS Primary',
  region_count: 2,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const AZ_A: SystemProviderAvailabilityZone = {
  id: 'az-1',
  name: 'us-east-1a',
  zone_code: 'use1-az1',
  status: 'available',
  enabled: true,
  capabilities: {},
  provider_region_id: 'region-1',
  region_name: 'US East 1',
  provider_name: 'AWS Primary',
  operational: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Tests
// =============================================================================

describe('providersApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ===========================================================================
  // Providers
  // ===========================================================================

  describe('getProviders', () => {
    it('calls GET /system/providers and returns the providers array', async () => {
      mockGet.mockResolvedValue(envelope({ providers: [PROVIDER_A, PROVIDER_B] }));

      const result = await providersApi.getProviders();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/providers');
      expect(result).toHaveLength(2);
      expect(result[0].id).toBe('prov-1');
      expect(result[1].id).toBe('prov-2');
    });

    it('returns an empty array when providers key is missing from data', async () => {
      mockGet.mockResolvedValue(envelope({}));

      const result = await providersApi.getProviders();

      expect(result).toEqual([]);
    });

    it('returns an empty array when providers is null', async () => {
      mockGet.mockResolvedValue(envelope({ providers: null }));

      const result = await providersApi.getProviders();

      expect(result).toEqual([]);
    });
  });

  describe('getProvider', () => {
    it('calls GET /system/providers/:id and returns the provider', async () => {
      mockGet.mockResolvedValue(envelope({ provider: PROVIDER_A }));

      const result = await providersApi.getProvider('prov-1');

      expect(mockGet).toHaveBeenCalledWith('/system/providers/prov-1');
      expect(result.id).toBe('prov-1');
      expect(result.name).toBe('AWS Primary');
      expect(result.provider_type).toBe('aws');
    });

    it('uses the id verbatim in the URL', async () => {
      mockGet.mockResolvedValue(envelope({ provider: PROVIDER_B }));

      await providersApi.getProvider('prov-2');

      expect(mockGet).toHaveBeenCalledWith('/system/providers/prov-2');
    });
  });

  describe('createProvider', () => {
    it('calls POST /system/providers with a wrapped payload and returns the provider', async () => {
      mockPost.mockResolvedValue(envelope({ provider: PROVIDER_A }));

      const data: ProviderCreate = {
        name: 'AWS Primary',
        description: 'Primary AWS account',
        provider_type: 'aws',
        enabled: true,
        public: false,
        config: { region: 'us-east-1' },
        capabilities: { gpu: false },
      };

      const result = await providersApi.createProvider(data);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith('/system/providers', { provider: data });
      expect(result.id).toBe('prov-1');
    });

    it('wraps the payload under the "provider" key', async () => {
      mockPost.mockResolvedValue(envelope({ provider: PROVIDER_B }));

      const data: ProviderCreate = { name: 'GCP Staging', provider_type: 'gcp' };
      await providersApi.createProvider(data);

      const [, body] = mockPost.mock.calls[0] as [string, Record<string, unknown>];
      expect(body).toEqual({ provider: data });
      expect(body).not.toHaveProperty('name');
    });

    it('accepts a minimal payload (only required fields)', async () => {
      mockPost.mockResolvedValue(envelope({ provider: PROVIDER_B }));

      const data: ProviderCreate = { name: 'Minimal', provider_type: 'libvirt' };
      const result = await providersApi.createProvider(data);

      expect(mockPost).toHaveBeenCalledWith('/system/providers', { provider: data });
      expect(result).toBeDefined();
    });
  });

  describe('updateProvider', () => {
    it('calls PUT /system/providers/:id with a wrapped partial payload', async () => {
      const updated = { ...PROVIDER_A, enabled: false };
      mockPut.mockResolvedValue(envelope({ provider: updated }));

      const patch = { enabled: false };
      const result = await providersApi.updateProvider('prov-1', patch);

      expect(mockPut).toHaveBeenCalledTimes(1);
      expect(mockPut).toHaveBeenCalledWith('/system/providers/prov-1', { provider: patch });
      expect(result.enabled).toBe(false);
    });

    it('wraps the partial under the "provider" key', async () => {
      mockPut.mockResolvedValue(envelope({ provider: PROVIDER_A }));

      await providersApi.updateProvider('prov-1', { description: 'Updated' });

      const [, body] = mockPut.mock.calls[0] as [string, Record<string, unknown>];
      expect(body).toEqual({ provider: { description: 'Updated' } });
    });
  });

  describe('deleteProvider', () => {
    it('calls DELETE /system/providers/:id and resolves void', async () => {
      mockDelete.mockResolvedValue({ data: { success: true } });

      await expect(providersApi.deleteProvider('prov-1')).resolves.toBeUndefined();
      expect(mockDelete).toHaveBeenCalledWith('/system/providers/prov-1');
    });

    it('uses the id verbatim in the URL', async () => {
      mockDelete.mockResolvedValue({ data: { success: true } });

      await providersApi.deleteProvider('prov-2');

      expect(mockDelete).toHaveBeenCalledWith('/system/providers/prov-2');
    });
  });

  // ===========================================================================
  // Provider Regions
  // ===========================================================================

  describe('getProviderRegions', () => {
    it('calls GET /system/providers/:providerId/regions and returns the regions array', async () => {
      mockGet.mockResolvedValue(envelope({ regions: [REGION_A] }));

      const result = await providersApi.getProviderRegions('prov-1');

      expect(mockGet).toHaveBeenCalledWith('/system/providers/prov-1/regions');
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('region-1');
    });

    it('returns an empty array when regions key is missing', async () => {
      mockGet.mockResolvedValue(envelope({}));

      const result = await providersApi.getProviderRegions('prov-1');

      expect(result).toEqual([]);
    });
  });

  describe('getProviderRegion', () => {
    it('calls GET /system/providers/:providerId/regions/:regionId', async () => {
      mockGet.mockResolvedValue(envelope({ region: REGION_A }));

      const result = await providersApi.getProviderRegion('prov-1', 'region-1');

      expect(mockGet).toHaveBeenCalledWith('/system/providers/prov-1/regions/region-1');
      expect(result.id).toBe('region-1');
      expect(result.region_code).toBe('us-east-1');
    });
  });

  describe('createProviderRegion', () => {
    it('calls POST /system/providers/:providerId/regions with a wrapped payload', async () => {
      mockPost.mockResolvedValue(envelope({ region: REGION_A }));

      const data: ProviderRegionCreate = {
        name: 'US East 1',
        description: 'Northern Virginia',
        region_code: 'us-east-1',
        endpoint_url: 'https://ec2.us-east-1.amazonaws.com',
      };

      const result = await providersApi.createProviderRegion('prov-1', data);

      expect(mockPost).toHaveBeenCalledWith('/system/providers/prov-1/regions', { region: data });
      expect(result.id).toBe('region-1');
    });

    it('wraps the payload under the "region" key', async () => {
      mockPost.mockResolvedValue(envelope({ region: REGION_A }));

      const data: ProviderRegionCreate = { name: 'EU West' };
      await providersApi.createProviderRegion('prov-1', data);

      const [, body] = mockPost.mock.calls[0] as [string, Record<string, unknown>];
      expect(body).toEqual({ region: data });
    });
  });

  describe('updateProviderRegion', () => {
    it('calls PUT /system/providers/:providerId/regions/:regionId with a wrapped partial', async () => {
      const updated = { ...REGION_A, description: 'N. Virginia Updated' };
      mockPut.mockResolvedValue(envelope({ region: updated }));

      const patch = { description: 'N. Virginia Updated' };
      const result = await providersApi.updateProviderRegion('prov-1', 'region-1', patch);

      expect(mockPut).toHaveBeenCalledWith(
        '/system/providers/prov-1/regions/region-1',
        { region: patch }
      );
      expect(result.description).toBe('N. Virginia Updated');
    });
  });

  describe('deleteProviderRegion', () => {
    it('calls DELETE /system/providers/:providerId/regions/:regionId', async () => {
      mockDelete.mockResolvedValue({ data: { success: true } });

      await expect(
        providersApi.deleteProviderRegion('prov-1', 'region-1')
      ).resolves.toBeUndefined();

      expect(mockDelete).toHaveBeenCalledWith('/system/providers/prov-1/regions/region-1');
    });
  });

  // ===========================================================================
  // Provider Connections
  // ===========================================================================

  describe('getProviderConnections', () => {
    it('calls GET /system/provider_connections and returns the connections array', async () => {
      mockGet.mockResolvedValue(envelope({ provider_connections: [CONNECTION_A] }));

      const result = await providersApi.getProviderConnections();

      expect(mockGet).toHaveBeenCalledWith('/system/provider_connections');
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('conn-1');
    });

    it('returns an empty array when provider_connections key is missing', async () => {
      mockGet.mockResolvedValue(envelope({}));

      const result = await providersApi.getProviderConnections();

      expect(result).toEqual([]);
    });
  });

  describe('getProviderConnection', () => {
    it('calls GET /system/provider_connections/:id and returns the connection', async () => {
      mockGet.mockResolvedValue(envelope({ provider_connection: CONNECTION_A }));

      const result = await providersApi.getProviderConnection('conn-1');

      expect(mockGet).toHaveBeenCalledWith('/system/provider_connections/conn-1');
      expect(result.id).toBe('conn-1');
      expect(result.provider_id).toBe('prov-1');
    });
  });

  describe('createProviderConnection', () => {
    it('calls POST /system/provider_connections with a wrapped payload', async () => {
      mockPost.mockResolvedValue(envelope({ provider_connection: CONNECTION_A }));

      const data: ProviderConnectionCreate = {
        name: 'AWS Prod Creds',
        description: 'Production access key',
        provider_id: 'prov-1',
        access_key: 'AKIAIOSFODNN7EXAMPLE',
        secret_key: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
      };

      const result = await providersApi.createProviderConnection(data);

      expect(mockPost).toHaveBeenCalledWith('/system/provider_connections', {
        provider_connection: data,
      });
      expect(result.id).toBe('conn-1');
    });

    it('wraps the payload under the "provider_connection" key', async () => {
      mockPost.mockResolvedValue(envelope({ provider_connection: CONNECTION_A }));

      const data: ProviderConnectionCreate = {
        name: 'Minimal',
        provider_id: 'prov-1',
      };
      await providersApi.createProviderConnection(data);

      const [, body] = mockPost.mock.calls[0] as [string, Record<string, unknown>];
      expect(body).toEqual({ provider_connection: data });
    });
  });

  describe('updateProviderConnection', () => {
    it('calls PUT /system/provider_connections/:id with a wrapped partial', async () => {
      const updated = { ...CONNECTION_A, name: 'AWS Prod Creds v2' };
      mockPut.mockResolvedValue(envelope({ provider_connection: updated }));

      const patch = { name: 'AWS Prod Creds v2' };
      const result = await providersApi.updateProviderConnection('conn-1', patch);

      expect(mockPut).toHaveBeenCalledWith('/system/provider_connections/conn-1', {
        provider_connection: patch,
      });
      expect(result.name).toBe('AWS Prod Creds v2');
    });
  });

  describe('deleteProviderConnection', () => {
    it('calls DELETE /system/provider_connections/:id', async () => {
      mockDelete.mockResolvedValue({ data: { success: true } });

      await expect(providersApi.deleteProviderConnection('conn-1')).resolves.toBeUndefined();

      expect(mockDelete).toHaveBeenCalledWith('/system/provider_connections/conn-1');
    });
  });

  describe('testProviderConnection', () => {
    it('calls POST /system/provider_connections/:id/test and returns the result', async () => {
      const testResult = { success: true, message: 'Connection successful' };
      mockPost.mockResolvedValue(envelope(testResult));

      const result = await providersApi.testProviderConnection('conn-1');

      expect(mockPost).toHaveBeenCalledWith('/system/provider_connections/conn-1/test');
      expect(result.success).toBe(true);
      expect(result.message).toBe('Connection successful');
    });

    it('returns the full test result object including failure details', async () => {
      const testResult = { success: false, message: 'Authentication failed: invalid credentials' };
      mockPost.mockResolvedValue(envelope(testResult));

      const result = await providersApi.testProviderConnection('conn-1');

      expect(result.success).toBe(false);
      expect(result.message).toContain('Authentication failed');
    });
  });

  // ===========================================================================
  // Provider Instance Types
  // ===========================================================================

  describe('getProviderInstanceTypes', () => {
    it('calls GET /system/providers/:providerId/instance_types when providerId is given', async () => {
      mockGet.mockResolvedValue(envelope({ instance_types: [INSTANCE_TYPE_A] }));

      const result = await providersApi.getProviderInstanceTypes('prov-1');

      expect(mockGet).toHaveBeenCalledWith('/system/providers/prov-1/instance_types');
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('itype-1');
    });

    it('calls GET /system/provider_instance_types when no providerId is given', async () => {
      mockGet.mockResolvedValue(envelope({ instance_types: [INSTANCE_TYPE_A] }));

      const result = await providersApi.getProviderInstanceTypes();

      expect(mockGet).toHaveBeenCalledWith('/system/provider_instance_types');
      expect(result).toHaveLength(1);
    });

    it('returns an empty array when instance_types key is missing', async () => {
      mockGet.mockResolvedValue(envelope({}));

      const result = await providersApi.getProviderInstanceTypes('prov-1');

      expect(result).toEqual([]);
    });

    it('returns an empty array when called without arguments and data is empty', async () => {
      mockGet.mockResolvedValue(envelope({ instance_types: null }));

      const result = await providersApi.getProviderInstanceTypes();

      expect(result).toEqual([]);
    });
  });

  describe('getProviderInstanceType', () => {
    it('calls GET /system/providers/:providerId/instance_types/:instanceTypeId', async () => {
      mockGet.mockResolvedValue(envelope({ instance_type: INSTANCE_TYPE_A }));

      const result = await providersApi.getProviderInstanceType('prov-1', 'itype-1');

      expect(mockGet).toHaveBeenCalledWith('/system/providers/prov-1/instance_types/itype-1');
      expect(result.id).toBe('itype-1');
      expect(result.instance_type_code).toBe('t3.medium');
    });
  });

  describe('getInstanceTypesForRegion', () => {
    it('calls GET /system/provider_instance_types/for_region with region_id param', async () => {
      mockGet.mockResolvedValue(envelope({ instance_types: [INSTANCE_TYPE_A] }));

      const result = await providersApi.getInstanceTypesForRegion('region-1');

      expect(mockGet).toHaveBeenCalledWith('/system/provider_instance_types/for_region', {
        params: { region_id: 'region-1' },
      });
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('itype-1');
    });

    it('returns an empty array when instance_types is missing for a region', async () => {
      mockGet.mockResolvedValue(envelope({}));

      const result = await providersApi.getInstanceTypesForRegion('region-99');

      expect(result).toEqual([]);
    });
  });

  // ===========================================================================
  // Provider Availability Zones
  // ===========================================================================

  describe('getProviderAvailabilityZones', () => {
    it('calls GET /system/providers/:providerId/regions/:regionId/availability_zones', async () => {
      mockGet.mockResolvedValue(envelope({ availability_zones: [AZ_A] }));

      const result = await providersApi.getProviderAvailabilityZones('prov-1', 'region-1');

      expect(mockGet).toHaveBeenCalledWith(
        '/system/providers/prov-1/regions/region-1/availability_zones'
      );
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('az-1');
    });

    it('returns an empty array when availability_zones key is missing', async () => {
      mockGet.mockResolvedValue(envelope({}));

      const result = await providersApi.getProviderAvailabilityZones('prov-1', 'region-1');

      expect(result).toEqual([]);
    });

    it('returns an empty array when availability_zones is null', async () => {
      mockGet.mockResolvedValue(envelope({ availability_zones: null }));

      const result = await providersApi.getProviderAvailabilityZones('prov-1', 'region-99');

      expect(result).toEqual([]);
    });
  });

  describe('getProviderAvailabilityZone', () => {
    it('calls GET /system/providers/:providerId/regions/:regionId/availability_zones/:zoneId', async () => {
      mockGet.mockResolvedValue(envelope({ availability_zone: AZ_A }));

      const result = await providersApi.getProviderAvailabilityZone('prov-1', 'region-1', 'az-1');

      expect(mockGet).toHaveBeenCalledWith(
        '/system/providers/prov-1/regions/region-1/availability_zones/az-1'
      );
      expect(result.id).toBe('az-1');
      expect(result.zone_code).toBe('use1-az1');
      expect(result.status).toBe('available');
      expect(result.operational).toBe(true);
    });
  });

  // ===========================================================================
  // Error propagation
  // ===========================================================================

  describe('error propagation', () => {
    it('rejects with the network error when getProviders fails', async () => {
      const err = new Error('Network Error');
      mockGet.mockRejectedValue(err);

      await expect(providersApi.getProviders()).rejects.toThrow('Network Error');
    });

    it('rejects with the network error when createProvider fails', async () => {
      const err = new Error('503 Service Unavailable');
      mockPost.mockRejectedValue(err);

      await expect(
        providersApi.createProvider({ name: 'X', provider_type: 'aws' })
      ).rejects.toThrow('503 Service Unavailable');
    });

    it('rejects with the network error when testProviderConnection fails', async () => {
      const err = new Error('Connection timed out');
      mockPost.mockRejectedValue(err);

      await expect(providersApi.testProviderConnection('conn-1')).rejects.toThrow(
        'Connection timed out'
      );
    });

    it('rejects when deleteProvider encounters an error', async () => {
      const err = new Error('404 Not Found');
      mockDelete.mockRejectedValue(err);

      await expect(providersApi.deleteProvider('prov-bad')).rejects.toThrow('404 Not Found');
    });
  });
});
