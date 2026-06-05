// Behavioral tests for volumesApi.
//
// Covers every exported method: exact URL, params, payload, envelope
// unwrapping, optional-argument edge cases, and API error propagation.

import { volumesApi } from './volumesApi';

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

interface PaginationMetaShape {
  current_page: number;
  per_page: number;
  total_count: number;
  total_pages: number;
  next_page: number | null;
  prev_page: number | null;
}

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

// =============================================================================
// Fixtures
// =============================================================================

const VOLUME_A = {
  id: 'vol-1',
  name: 'data-volume-1',
  description: 'Primary data volume',
  size_gb: 100,
  status: 'available',
  volume_type: 'gp3',
  device_name: undefined,
  iops: 3000,
  throughput: 125,
  encrypted: true,
  config: {},
  volume_type_id: 'vt-1',
  volume_type_name: 'gp3',
  provider_region_id: 'region-1',
  provider_region_name: 'us-east-1',
  region_name: 'US East',
  node_instance_id: undefined,
  attached_instance_id: undefined,
  snapshot_count: 2,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const VOLUME_B = {
  id: 'vol-2',
  name: 'backup-volume',
  description: undefined,
  size_gb: 500,
  status: 'in-use',
  volume_type: 'io2',
  device_name: '/dev/sdf',
  iops: 10000,
  throughput: 500,
  encrypted: false,
  config: { multi_attach: true },
  volume_type_id: 'vt-2',
  volume_type_name: 'io2',
  provider_region_id: 'region-2',
  provider_region_name: 'eu-west-1',
  region_name: 'EU West',
  node_instance_id: 'inst-99',
  attached_instance_id: 'inst-99',
  snapshot_count: 0,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-02T00:00:00Z',
};

const SNAPSHOT_A = {
  id: 'snap-1',
  name: 'manual-snap',
  description: 'Nightly backup snapshot',
  status: 'completed',
  created_at: '2026-03-01T00:00:00Z',
};

const BASE = '/system/provider_volumes';

// =============================================================================
// Tests
// =============================================================================

describe('volumesApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // getVolumes
  // ---------------------------------------------------------------------------

  describe('getVolumes()', () => {
    it('calls GET /system/provider_volumes with no params when called without arguments', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ volumes: [VOLUME_A, VOLUME_B] }, { total_count: 2, total_pages: 1 })
      );

      await volumesApi.getVolumes();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(BASE, { params: undefined });
    });

    it('passes filter params when provided', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ volumes: [VOLUME_A] }));

      await volumesApi.getVolumes({ status: 'available', attached: false, encrypted: true, search: 'data', page: 2, per_page: 10 });

      expect(mockGet).toHaveBeenCalledWith(BASE, {
        params: { status: 'available', attached: false, encrypted: true, search: 'data', page: 2, per_page: 10 },
      });
    });

    it('passes only status when that is the sole filter', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ volumes: [VOLUME_A] }));

      await volumesApi.getVolumes({ status: 'available' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { status: 'available' } });
    });

    it('passes only attached filter when provided', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ volumes: [VOLUME_B] }));

      await volumesApi.getVolumes({ attached: true });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { attached: true } });
    });

    it('passes only encrypted filter when provided', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ volumes: [VOLUME_A] }));

      await volumesApi.getVolumes({ encrypted: true });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { encrypted: true } });
    });

    it('passes page_size for PlanStorageMigrationModal override', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ volumes: [VOLUME_A] }));

      await volumesApi.getVolumes({ page_size: 200 });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { page_size: 200 } });
    });

    it('passes only search when that is the sole filter', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ volumes: [] }, { total_count: 0 }));

      await volumesApi.getVolumes({ search: 'backup' });

      expect(mockGet).toHaveBeenCalledWith(BASE, { params: { search: 'backup' } });
    });

    it('returns { volumes, meta } from the paginated envelope', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ volumes: [VOLUME_A, VOLUME_B] }, { total_count: 2, total_pages: 1 })
      );

      const result = await volumesApi.getVolumes();

      expect(result.volumes).toHaveLength(2);
      expect(result.volumes[0].id).toBe('vol-1');
      expect(result.volumes[1].id).toBe('vol-2');
      expect(result.meta.total_count).toBe(2);
      expect(result.meta.current_page).toBe(1);
    });

    it('meta is NOT nested inside data — it lives at the response body root', async () => {
      mockGet.mockResolvedValueOnce(
        paginatedEnvelope({ volumes: [VOLUME_A] }, { total_pages: 5, total_count: 125 })
      );

      const result = await volumesApi.getVolumes();

      expect(result.meta.total_pages).toBe(5);
      expect(result.meta.total_count).toBe(125);
      // volumes should be the data payload, not the wrapper
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('returns empty volumes array and synthesized meta when no results', async () => {
      mockGet.mockResolvedValueOnce(paginatedEnvelope({ volumes: [] }, { total_count: 0, total_pages: 1 }));

      const result = await volumesApi.getVolumes();

      expect(result.volumes).toEqual([]);
      expect(result.meta.total_count).toBe(0);
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Network error'));

      await expect(volumesApi.getVolumes()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // getVolume
  // ---------------------------------------------------------------------------

  describe('getVolume()', () => {
    it('calls GET /system/provider_volumes/:id', async () => {
      mockGet.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      await volumesApi.getVolume('vol-1');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`${BASE}/vol-1`);
    });

    it('uses the supplied id in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ volume: VOLUME_B }));

      await volumesApi.getVolume('vol-abc-999');

      expect(mockGet).toHaveBeenCalledWith(`${BASE}/vol-abc-999`);
    });

    it('unwraps the nested .volume from the envelope', async () => {
      mockGet.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      const result = await volumesApi.getVolume('vol-1');

      expect(result).toEqual(VOLUME_A);
      expect(result.id).toBe('vol-1');
      expect(result.name).toBe('data-volume-1');
      expect(result.size_gb).toBe(100);
    });

    it('does NOT return the { volume: ... } wrapper — must unwrap', async () => {
      mockGet.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      const result = await volumesApi.getVolume('vol-1');

      expect((result as unknown as Record<string, unknown>)['volume']).toBeUndefined();
    });

    it('returns the attached volume with correct fields', async () => {
      mockGet.mockResolvedValueOnce(envelope({ volume: VOLUME_B }));

      const result = await volumesApi.getVolume('vol-2');

      expect(result).toEqual(VOLUME_B);
      expect(result.status).toBe('in-use');
      expect(result.attached_instance_id).toBe('inst-99');
      expect(result.device_name).toBe('/dev/sdf');
    });

    it('propagates API errors', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(volumesApi.getVolume('missing')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // createVolume
  // ---------------------------------------------------------------------------

  describe('createVolume()', () => {
    const FULL_CREATE = {
      name: 'new-volume',
      description: 'A test volume',
      size_gb: 200,
      volume_type_id: 'vt-1',
      provider_region_id: 'region-1',
      availability_zone_id: 'az-1',
      iops: 6000,
      throughput: 250,
      encrypted: true,
      delete_on_termination: false,
      config: { tags: { env: 'prod' } },
    };

    const MINIMAL_CREATE = {
      name: 'bare-volume',
      size_gb: 50,
    };

    it('calls POST /system/provider_volumes with volume wrapper', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      await volumesApi.createVolume(FULL_CREATE);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(BASE, { volume: FULL_CREATE });
    });

    it('wraps the payload in { volume: data } before sending', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      await volumesApi.createVolume(FULL_CREATE);

      const [, body] = mockPost.mock.calls[0] as [string, { volume: typeof FULL_CREATE }];
      expect(body).toEqual({ volume: FULL_CREATE });
      expect(body.volume.name).toBe('new-volume');
      expect(body.volume.size_gb).toBe(200);
    });

    it('works with only required fields (name + size_gb)', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      await volumesApi.createVolume(MINIMAL_CREATE);

      expect(mockPost).toHaveBeenCalledWith(BASE, { volume: MINIMAL_CREATE });
    });

    it('returns the unwrapped volume from the response', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      const result = await volumesApi.createVolume(FULL_CREATE);

      expect(result).toEqual(VOLUME_A);
      expect(result.id).toBe('vol-1');
    });

    it('does NOT return the { volume: ... } wrapper', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      const result = await volumesApi.createVolume(FULL_CREATE);

      expect((result as unknown as Record<string, unknown>)['volume']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(volumesApi.createVolume(FULL_CREATE)).rejects.toThrow('Validation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // updateVolume
  // ---------------------------------------------------------------------------

  describe('updateVolume()', () => {
    const FULL_UPDATE = {
      name: 'renamed-volume',
      description: 'Updated description',
      size_gb: 250,
      iops: 8000,
      throughput: 400,
      delete_on_termination: true,
      config: { updated: true },
    };

    it('calls PUT /system/provider_volumes/:id with volume wrapper', async () => {
      mockPut.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      await volumesApi.updateVolume('vol-1', FULL_UPDATE);

      expect(mockPut).toHaveBeenCalledTimes(1);
      expect(mockPut).toHaveBeenCalledWith(`${BASE}/vol-1`, { volume: FULL_UPDATE });
    });

    it('uses the supplied id in the URL', async () => {
      mockPut.mockResolvedValueOnce(envelope({ volume: VOLUME_B }));

      await volumesApi.updateVolume('vol-abc-xyz', FULL_UPDATE);

      expect(mockPut).toHaveBeenCalledWith(`${BASE}/vol-abc-xyz`, { volume: FULL_UPDATE });
    });

    it('wraps the payload in { volume: data } before sending', async () => {
      mockPut.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      await volumesApi.updateVolume('vol-1', FULL_UPDATE);

      const [, body] = mockPut.mock.calls[0] as [string, { volume: typeof FULL_UPDATE }];
      expect(body).toEqual({ volume: FULL_UPDATE });
    });

    it('works with a partial update (only name)', async () => {
      mockPut.mockResolvedValueOnce(envelope({ volume: { ...VOLUME_A, name: 'new-name' } }));

      await volumesApi.updateVolume('vol-1', { name: 'new-name' });

      expect(mockPut).toHaveBeenCalledWith(`${BASE}/vol-1`, { volume: { name: 'new-name' } });
    });

    it('works with a partial update (only size_gb)', async () => {
      mockPut.mockResolvedValueOnce(envelope({ volume: { ...VOLUME_A, size_gb: 300 } }));

      await volumesApi.updateVolume('vol-1', { size_gb: 300 });

      expect(mockPut).toHaveBeenCalledWith(`${BASE}/vol-1`, { volume: { size_gb: 300 } });
    });

    it('works with a partial update (only delete_on_termination)', async () => {
      mockPut.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      await volumesApi.updateVolume('vol-1', { delete_on_termination: true });

      expect(mockPut).toHaveBeenCalledWith(`${BASE}/vol-1`, { volume: { delete_on_termination: true } });
    });

    it('returns the unwrapped updated volume', async () => {
      const updated = { ...VOLUME_A, name: 'renamed-volume', size_gb: 250 };
      mockPut.mockResolvedValueOnce(envelope({ volume: updated }));

      const result = await volumesApi.updateVolume('vol-1', { name: 'renamed-volume', size_gb: 250 });

      expect(result).toEqual(updated);
      expect(result.name).toBe('renamed-volume');
      expect(result.size_gb).toBe(250);
    });

    it('does NOT return the { volume: ... } wrapper', async () => {
      mockPut.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      const result = await volumesApi.updateVolume('vol-1', { name: 'x' });

      expect((result as unknown as Record<string, unknown>)['volume']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPut.mockRejectedValueOnce(new Error('Update failed'));

      await expect(volumesApi.updateVolume('vol-1', { name: 'x' })).rejects.toThrow('Update failed');
    });
  });

  // ---------------------------------------------------------------------------
  // deleteVolume
  // ---------------------------------------------------------------------------

  describe('deleteVolume()', () => {
    it('calls DELETE /system/provider_volumes/:id', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await volumesApi.deleteVolume('vol-1');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/vol-1`);
    });

    it('uses the supplied id in the URL', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await volumesApi.deleteVolume('vol-xyz-999');

      expect(mockDelete).toHaveBeenCalledWith(`${BASE}/vol-xyz-999`);
    });

    it('resolves to void (returns undefined)', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      const result = await volumesApi.deleteVolume('vol-1');

      expect(result).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Delete failed'));

      await expect(volumesApi.deleteVolume('vol-1')).rejects.toThrow('Delete failed');
    });
  });

  // ---------------------------------------------------------------------------
  // attachVolume
  // ---------------------------------------------------------------------------

  describe('attachVolume()', () => {
    it('calls POST /system/provider_volumes/:id/attach with node_instance_id and device_name', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: { ...VOLUME_A, status: 'in-use', attached_instance_id: 'inst-5' } }));

      await volumesApi.attachVolume('vol-1', 'inst-5', '/dev/sdf');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/vol-1/attach`, {
        node_instance_id: 'inst-5',
        device_name: '/dev/sdf',
      });
    });

    it('calls POST /system/provider_volumes/:id/attach without device_name when omitted', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: { ...VOLUME_A, status: 'in-use' } }));

      await volumesApi.attachVolume('vol-1', 'inst-5');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/vol-1/attach`, {
        node_instance_id: 'inst-5',
        device_name: undefined,
      });
    });

    it('uses the supplied volume id in the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: VOLUME_B }));

      await volumesApi.attachVolume('vol-abc', 'inst-10', '/dev/sdg');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/vol-abc/attach`, expect.any(Object));
    });

    it('returns the unwrapped volume from the response', async () => {
      const attached = { ...VOLUME_A, status: 'in-use', attached_instance_id: 'inst-5', device_name: '/dev/sdf' };
      mockPost.mockResolvedValueOnce(envelope({ volume: attached }));

      const result = await volumesApi.attachVolume('vol-1', 'inst-5', '/dev/sdf');

      expect(result).toEqual(attached);
      expect(result.status).toBe('in-use');
      expect(result.attached_instance_id).toBe('inst-5');
      expect(result.device_name).toBe('/dev/sdf');
    });

    it('does NOT return the { volume: ... } wrapper', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      const result = await volumesApi.attachVolume('vol-1', 'inst-5');

      expect((result as unknown as Record<string, unknown>)['volume']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Instance not found'));

      await expect(volumesApi.attachVolume('vol-1', 'missing-inst')).rejects.toThrow('Instance not found');
    });
  });

  // ---------------------------------------------------------------------------
  // detachVolume
  // ---------------------------------------------------------------------------

  describe('detachVolume()', () => {
    it('calls POST /system/provider_volumes/:id/detach', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: { ...VOLUME_B, status: 'available', attached_instance_id: undefined } }));

      await volumesApi.detachVolume('vol-2');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/vol-2/detach`);
    });

    it('uses the supplied id in the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      await volumesApi.detachVolume('vol-abc-xyz');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/vol-abc-xyz/detach`);
    });

    it('does NOT send a request body', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      await volumesApi.detachVolume('vol-1');

      expect(mockPost).toHaveBeenCalledTimes(1);
      const callArgs = mockPost.mock.calls[0] as unknown[];
      // Second argument should be absent — post called with only the URL
      expect(callArgs).toHaveLength(1);
      expect(callArgs[0]).toBe(`${BASE}/vol-1/detach`);
    });

    it('returns the unwrapped volume from the response', async () => {
      const detached = { ...VOLUME_B, status: 'available', attached_instance_id: undefined, device_name: undefined };
      mockPost.mockResolvedValueOnce(envelope({ volume: detached }));

      const result = await volumesApi.detachVolume('vol-2');

      expect(result).toEqual(detached);
      expect(result.status).toBe('available');
    });

    it('does NOT return the { volume: ... } wrapper', async () => {
      mockPost.mockResolvedValueOnce(envelope({ volume: VOLUME_A }));

      const result = await volumesApi.detachVolume('vol-1');

      expect((result as unknown as Record<string, unknown>)['volume']).toBeUndefined();
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Volume not attached'));

      await expect(volumesApi.detachVolume('vol-1')).rejects.toThrow('Volume not attached');
    });
  });

  // ---------------------------------------------------------------------------
  // createVolumeSnapshot
  // ---------------------------------------------------------------------------

  describe('createVolumeSnapshot()', () => {
    it('calls POST /system/provider_volumes/:id/snapshot with name and description', async () => {
      mockPost.mockResolvedValueOnce(envelope({ snapshot: SNAPSHOT_A }));

      await volumesApi.createVolumeSnapshot('vol-1', 'manual-snap', 'Nightly backup snapshot');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(`${BASE}/vol-1/snapshot`, {
        name: 'manual-snap',
        description: 'Nightly backup snapshot',
      });
    });

    it('calls POST /system/provider_volumes/:id/snapshot with only name (no description)', async () => {
      mockPost.mockResolvedValueOnce(envelope({ snapshot: SNAPSHOT_A }));

      await volumesApi.createVolumeSnapshot('vol-1', 'snap-no-desc');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/vol-1/snapshot`, {
        name: 'snap-no-desc',
        description: undefined,
      });
    });

    it('calls POST /system/provider_volumes/:id/snapshot with no name or description', async () => {
      mockPost.mockResolvedValueOnce(envelope({ snapshot: { id: 'snap-2', status: 'pending' } }));

      await volumesApi.createVolumeSnapshot('vol-1');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/vol-1/snapshot`, {
        name: undefined,
        description: undefined,
      });
    });

    it('uses the supplied volume id in the URL', async () => {
      mockPost.mockResolvedValueOnce(envelope({ snapshot: SNAPSHOT_A }));

      await volumesApi.createVolumeSnapshot('vol-abc-456', 'my-snap');

      expect(mockPost).toHaveBeenCalledWith(`${BASE}/vol-abc-456/snapshot`, expect.any(Object));
    });

    it('returns the unwrapped snapshot from the response', async () => {
      mockPost.mockResolvedValueOnce(envelope({ snapshot: SNAPSHOT_A }));

      const result = await volumesApi.createVolumeSnapshot('vol-1', 'manual-snap', 'Nightly backup snapshot');

      expect(result).toEqual(SNAPSHOT_A);
      expect(result.id).toBe('snap-1');
      expect(result.name).toBe('manual-snap');
      expect(result.status).toBe('completed');
    });

    it('does NOT return the { snapshot: ... } wrapper', async () => {
      mockPost.mockResolvedValueOnce(envelope({ snapshot: SNAPSHOT_A }));

      const result = await volumesApi.createVolumeSnapshot('vol-1', 'snap');

      expect((result as unknown as Record<string, unknown>)['snapshot']).toBeUndefined();
    });

    it('handles snapshots with extra provider-specific fields (permissive type)', async () => {
      const extendedSnap = {
        ...SNAPSHOT_A,
        provider_snapshot_id: 'snap-abc-123',
        size_gb: 100,
        encrypted: true,
      };
      mockPost.mockResolvedValueOnce(envelope({ snapshot: extendedSnap }));

      const result = await volumesApi.createVolumeSnapshot('vol-1', 'extended-snap');

      expect(result.id).toBe('snap-1');
      expect((result as Record<string, unknown>)['provider_snapshot_id']).toBe('snap-abc-123');
      expect((result as Record<string, unknown>)['size_gb']).toBe(100);
    });

    it('propagates API errors', async () => {
      mockPost.mockRejectedValueOnce(new Error('Snapshot limit exceeded'));

      await expect(volumesApi.createVolumeSnapshot('vol-1', 'failed-snap')).rejects.toThrow('Snapshot limit exceeded');
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope unwrapping — shared contract
  // ---------------------------------------------------------------------------

  describe('envelope unwrapping contract', () => {
    it('getVolumes correctly extracts data from paginated double-envelope', async () => {
      const payload = { volumes: [VOLUME_A] };
      const meta = {
        current_page: 2,
        per_page: 10,
        total_count: 15,
        total_pages: 2,
        next_page: null,
        prev_page: 1,
      };
      mockGet.mockResolvedValueOnce({ data: { success: true, data: payload, meta } });

      const result = await volumesApi.getVolumes({ page: 2, per_page: 10 });

      expect(result.volumes).toHaveLength(1);
      expect(result.meta).toEqual(meta);
      // Must NOT contain envelope keys
      expect((result as unknown as Record<string, unknown>)['success']).toBeUndefined();
    });

    it('getVolume correctly extracts data from non-paginated double-envelope', async () => {
      mockGet.mockResolvedValueOnce({
        data: { success: true, data: { volume: VOLUME_A } },
      });

      const result = await volumesApi.getVolume('vol-1');

      expect(result.id).toBe('vol-1');
      expect((result as unknown as Record<string, unknown>)['volume']).toBeUndefined();
    });

    it('createVolume correctly extracts data from the post response envelope', async () => {
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: { volume: VOLUME_B } },
      });

      const result = await volumesApi.createVolume({ name: 'test', size_gb: 50 });

      expect(result.id).toBe('vol-2');
      expect((result as unknown as Record<string, unknown>)['volume']).toBeUndefined();
    });

    it('updateVolume correctly extracts data from the put response envelope', async () => {
      const updated = { ...VOLUME_A, name: 'updated-name' };
      mockPut.mockResolvedValueOnce({
        data: { success: true, data: { volume: updated } },
      });

      const result = await volumesApi.updateVolume('vol-1', { name: 'updated-name' });

      expect(result.name).toBe('updated-name');
      expect((result as unknown as Record<string, unknown>)['volume']).toBeUndefined();
    });

    it('attachVolume correctly extracts data from the post response envelope', async () => {
      const attached = { ...VOLUME_A, status: 'in-use', attached_instance_id: 'inst-7' };
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: { volume: attached } },
      });

      const result = await volumesApi.attachVolume('vol-1', 'inst-7', '/dev/sdg');

      expect(result.attached_instance_id).toBe('inst-7');
      expect((result as unknown as Record<string, unknown>)['volume']).toBeUndefined();
    });

    it('detachVolume correctly extracts data from the post response envelope', async () => {
      const detached = { ...VOLUME_B, status: 'available' };
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: { volume: detached } },
      });

      const result = await volumesApi.detachVolume('vol-2');

      expect(result.status).toBe('available');
      expect((result as unknown as Record<string, unknown>)['volume']).toBeUndefined();
    });

    it('createVolumeSnapshot correctly extracts snapshot from the post response envelope', async () => {
      mockPost.mockResolvedValueOnce({
        data: { success: true, data: { snapshot: SNAPSHOT_A } },
      });

      const result = await volumesApi.createVolumeSnapshot('vol-1', 'snap');

      expect(result.id).toBe('snap-1');
      expect((result as unknown as Record<string, unknown>)['snapshot']).toBeUndefined();
    });
  });
});
