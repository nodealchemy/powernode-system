/**
 * Behavioral tests for unclaimedDevicesApi.
 *
 * Covers every exported function: request shaping (URLs, payloads, query
 * params), response unwrapping (single-record and paginated envelopes),
 * pagination meta extraction, void deletes, edge cases (missing optional
 * fields, empty collections, null values), and error propagation.
 *
 * API double-envelope: apiClient.{get,post,put,delete} resolve to an
 * AxiosResponse whose body is { success: true, data: <payload>, meta?: ... }.
 * A mocked resolve is therefore { data: { success: true, data: <payload> } } —
 * the outer `data` key is the AxiosResponse body, inner `data` is the API
 * envelope. Pagination `meta` sits at the response root alongside `data`.
 */

import { unclaimedDevicesApi } from './unclaimedDevicesApi';
import type { UnclaimedDeviceListResponse, ClaimResponse } from './unclaimedDevicesApi';
import type {
  SystemUnclaimedDevice,
  SystemDiskImage,
} from '@system/features/system/types/system.types';
import type { PaginationMeta, PaginationParams } from './types';

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
// Helpers & Fixtures
// =============================================================================

/**
 * Build a double-envelope AxiosResponse mock for single-record endpoints.
 * Shape: { data: { success: true, data: <payload> } }
 */
function envelope<T>(payload: T) {
  return { data: { success: true as const, data: payload } };
}

/**
 * Build a paginated envelope — meta sits at the ROOT of the response body,
 * NOT inside data.
 * Shape: { data: { success: true, data: <payload>, meta: <meta> } }
 */
function paginatedEnvelope<T>(payload: T, meta?: Partial<PaginationMeta>) {
  const fullMeta: PaginationMeta = {
    current_page: 1,
    per_page: 20,
    total_count: 1,
    total_pages: 1,
    next_page: null,
    prev_page: null,
    ...meta,
  };
  return { data: { success: true as const, data: payload, meta: fullMeta } };
}

function makeDevice(overrides: Partial<SystemUnclaimedDevice> = {}): SystemUnclaimedDevice {
  return {
    id: 'dev-1',
    claim_code: 'ABCD-1234',
    discovered_mac: 'aa:bb:cc:dd:ee:ff',
    first_seen_at: '2026-01-01T00:00:00Z',
    last_seen_at: '2026-01-01T01:00:00Z',
    expires_at: '2026-01-02T00:00:00Z',
    ...overrides,
  };
}

function makeDiskImage(overrides: Partial<SystemDiskImage> = {}): SystemDiskImage {
  return {
    url: 'https://storage.example.com/images/powernode-arm64.img?token=abc123',
    expires_at: '2026-06-05T12:00:00Z',
    sha256: 'deadbeef00000000deadbeef00000000deadbeef00000000deadbeef00000000',
    size_bytes: 2147483648,
    filename: 'powernode-arm64.img',
    ...overrides,
  };
}

const DEVICE_A = makeDevice({ id: 'dev-a', claim_code: 'AAAA-0001', discovered_mac: 'aa:bb:cc:11:22:33' });
const DEVICE_B = makeDevice({
  id: 'dev-b',
  claim_code: 'BBBB-0002',
  discovered_mac: 'aa:bb:cc:44:55:66',
  discovered_hostname: 'worker-node-02',
  agent_version: '1.2.3',
  architecture: 'arm64',
  platform_hint: 'raspberrypi5',
  discovered_dmi_uuid: 'dmi-uuid-b',
});

// =============================================================================
// Test Setup
// =============================================================================

beforeEach(() => {
  mockGet.mockReset();
  mockPost.mockReset();
  mockDelete.mockReset();
});

// =============================================================================
// unclaimedDevicesApi.list
// =============================================================================

describe('unclaimedDevicesApi.list', () => {
  it('calls GET /system/unclaimed_devices without params when called with no arguments', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ unclaimed_devices: [DEVICE_A, DEVICE_B] }, { total_count: 2 }),
    );

    const result = await unclaimedDevicesApi.list();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/unclaimed_devices', { params: undefined });
    expect(result.devices).toHaveLength(2);
    expect(result.devices[0]).toEqual(DEVICE_A);
    expect(result.devices[1]).toEqual(DEVICE_B);
  });

  it('passes pagination params when provided', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ unclaimed_devices: [DEVICE_A] }, { current_page: 2, per_page: 10 }),
    );

    const params: PaginationParams = { page: 2, per_page: 10 };
    await unclaimedDevicesApi.list(params);

    expect(mockGet).toHaveBeenCalledWith('/system/unclaimed_devices', { params });
  });

  it('returns meta from the paginated envelope root alongside devices', async () => {
    const meta: PaginationMeta = {
      current_page: 1,
      per_page: 20,
      total_count: 42,
      total_pages: 3,
      next_page: 2,
      prev_page: null,
    };
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ unclaimed_devices: [DEVICE_A] }, meta),
    );

    const result = await unclaimedDevicesApi.list();

    expect(result.meta).toEqual(meta);
    expect(result.meta.total_count).toBe(42);
    expect(result.meta.total_pages).toBe(3);
    expect(result.meta.next_page).toBe(2);
  });

  it('returns an empty devices array when the collection is empty', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ unclaimed_devices: [] }, { total_count: 0, total_pages: 1 }),
    );

    const result = await unclaimedDevicesApi.list();

    expect(result.devices).toEqual([]);
    expect(result.meta.total_count).toBe(0);
  });

  it('returns empty devices array and synthesizes default meta when backend omits meta', async () => {
    mockGet.mockResolvedValueOnce({
      data: { success: true, data: { unclaimed_devices: [DEVICE_A] } },
    });

    const result = await unclaimedDevicesApi.list();

    expect(result.devices).toHaveLength(1);
    // defaultMeta synthesizes from item count
    expect(result.meta.total_count).toBe(1);
    expect(result.meta.current_page).toBe(1);
    expect(result.meta.total_pages).toBe(1);
    expect(result.meta.next_page).toBeNull();
  });

  it('returns empty devices array when unclaimed_devices key is missing from payload', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({} as { unclaimed_devices: SystemUnclaimedDevice[] }),
    );

    const result = await unclaimedDevicesApi.list();

    expect(result.devices).toEqual([]);
  });

  it('returns a device with all optional fields present', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ unclaimed_devices: [DEVICE_B] }),
    );

    const result = await unclaimedDevicesApi.list();

    const device = result.devices[0];
    expect(device.discovered_hostname).toBe('worker-node-02');
    expect(device.agent_version).toBe('1.2.3');
    expect(device.architecture).toBe('arm64');
    expect(device.platform_hint).toBe('raspberrypi5');
    expect(device.discovered_dmi_uuid).toBe('dmi-uuid-b');
  });

  it('returns a device with only required fields when optional fields are absent', async () => {
    const minimalDevice = makeDevice({
      id: 'dev-minimal',
      claim_code: 'MIN-0001',
      discovered_mac: 'aa:bb:cc:ff:ee:dd',
    });
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ unclaimed_devices: [minimalDevice] }),
    );

    const result = await unclaimedDevicesApi.list();

    const device = result.devices[0];
    expect(device.id).toBe('dev-minimal');
    expect(device.discovered_hostname).toBeUndefined();
    expect(device.agent_version).toBeUndefined();
    expect(device.platform_hint).toBeUndefined();
  });

  it('returns a device that has already been claimed (claimed_at populated)', async () => {
    const claimed = makeDevice({
      id: 'dev-claimed',
      claimed_at: '2026-06-01T10:00:00Z',
      claimed_node_instance_id: 'inst-xyz',
    });
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ unclaimed_devices: [claimed] }),
    );

    const result = await unclaimedDevicesApi.list();

    expect(result.devices[0].claimed_at).toBe('2026-06-01T10:00:00Z');
    expect(result.devices[0].claimed_node_instance_id).toBe('inst-xyz');
  });

  it('propagates network errors to the caller', async () => {
    mockGet.mockRejectedValueOnce(new Error('Network failure'));

    await expect(unclaimedDevicesApi.list()).rejects.toThrow('Network failure');
  });

  it('propagates API 401 errors to the caller', async () => {
    mockGet.mockRejectedValueOnce(new Error('Unauthorized'));

    await expect(unclaimedDevicesApi.list()).rejects.toThrow('Unauthorized');
  });

  it('returns the correct total result shape (devices + meta keys)', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ unclaimed_devices: [DEVICE_A] }, { total_count: 1 }),
    );

    const result: UnclaimedDeviceListResponse = await unclaimedDevicesApi.list();

    expect(result).toHaveProperty('devices');
    expect(result).toHaveProperty('meta');
    expect(Array.isArray(result.devices)).toBe(true);
    expect(typeof result.meta.total_count).toBe('number');
  });
});

// =============================================================================
// unclaimedDevicesApi.get
// =============================================================================

describe('unclaimedDevicesApi.get', () => {
  it('calls GET /system/unclaimed_devices/:id and returns the device', async () => {
    mockGet.mockResolvedValueOnce(envelope({ unclaimed_device: DEVICE_A }));

    const result = await unclaimedDevicesApi.get('dev-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/unclaimed_devices/dev-a');
    expect(result).toEqual(DEVICE_A);
  });

  it('interpolates the id correctly into the URL', async () => {
    mockGet.mockResolvedValueOnce(envelope({ unclaimed_device: DEVICE_B }));

    await unclaimedDevicesApi.get('dev-b');

    expect(mockGet).toHaveBeenCalledWith('/system/unclaimed_devices/dev-b');
  });

  it('unwraps the unclaimed_device field from the single-record envelope', async () => {
    const device = makeDevice({
      id: 'dev-xyz',
      claim_code: 'XYZ-9999',
      discovered_mac: '00:11:22:33:44:55',
      discovered_hostname: 'edge-node-xyz',
      architecture: 'x86_64',
    });
    mockGet.mockResolvedValueOnce(envelope({ unclaimed_device: device }));

    const result = await unclaimedDevicesApi.get('dev-xyz');

    expect(result.id).toBe('dev-xyz');
    expect(result.claim_code).toBe('XYZ-9999');
    expect(result.discovered_hostname).toBe('edge-node-xyz');
    expect(result.architecture).toBe('x86_64');
  });

  it('returns a device whose expires_at timestamp is populated', async () => {
    const device = makeDevice({ id: 'dev-expiring', expires_at: '2026-06-06T00:00:00Z' });
    mockGet.mockResolvedValueOnce(envelope({ unclaimed_device: device }));

    const result = await unclaimedDevicesApi.get('dev-expiring');

    expect(result.expires_at).toBe('2026-06-06T00:00:00Z');
  });

  it('propagates API errors (e.g. 404 Not Found) to the caller', async () => {
    mockGet.mockRejectedValueOnce(new Error('Not found'));

    await expect(unclaimedDevicesApi.get('nonexistent')).rejects.toThrow('Not found');
  });

  it('propagates server errors to the caller', async () => {
    mockGet.mockRejectedValueOnce(new Error('Internal Server Error'));

    await expect(unclaimedDevicesApi.get('dev-a')).rejects.toThrow('Internal Server Error');
  });
});

// =============================================================================
// unclaimedDevicesApi.claim
// =============================================================================

describe('unclaimedDevicesApi.claim', () => {
  const DEVICE_ID = 'dev-a';
  const NODE_INSTANCE_ID = 'inst-target-1';

  it('calls POST /system/unclaimed_devices/:id/claim with the node_instance_id body', async () => {
    const claimResponse: ClaimResponse = {
      unclaimed_device: DEVICE_A,
      node_instance_id: NODE_INSTANCE_ID,
      node_instance_name: 'edge-server-01',
    };
    mockPost.mockResolvedValueOnce(envelope(claimResponse));

    const result = await unclaimedDevicesApi.claim(DEVICE_ID, NODE_INSTANCE_ID);

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      `/system/unclaimed_devices/${DEVICE_ID}/claim`,
      { node_instance_id: NODE_INSTANCE_ID },
    );
    expect(result).toEqual(claimResponse);
  });

  it('interpolates the device id into the POST URL', async () => {
    const claimResponse: ClaimResponse = {
      unclaimed_device: DEVICE_B,
      node_instance_id: 'inst-b-target',
      node_instance_name: 'rack-server-02',
    };
    mockPost.mockResolvedValueOnce(envelope(claimResponse));

    await unclaimedDevicesApi.claim('dev-b', 'inst-b-target');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/unclaimed_devices/dev-b/claim',
      { node_instance_id: 'inst-b-target' },
    );
  });

  it('sends the node_instance_id as the only body key', async () => {
    const claimResponse: ClaimResponse = {
      unclaimed_device: DEVICE_A,
      node_instance_id: NODE_INSTANCE_ID,
      node_instance_name: 'edge-server-01',
    };
    mockPost.mockResolvedValueOnce(envelope(claimResponse));

    await unclaimedDevicesApi.claim(DEVICE_ID, NODE_INSTANCE_ID);

    const callBody = mockPost.mock.calls[0][1] as Record<string, unknown>;
    expect(Object.keys(callBody)).toEqual(['node_instance_id']);
    expect(callBody.node_instance_id).toBe(NODE_INSTANCE_ID);
  });

  it('returns the unclaimed_device from the claim response', async () => {
    const claimResponse: ClaimResponse = {
      unclaimed_device: DEVICE_A,
      node_instance_id: NODE_INSTANCE_ID,
      node_instance_name: 'edge-server-01',
    };
    mockPost.mockResolvedValueOnce(envelope(claimResponse));

    const result = await unclaimedDevicesApi.claim(DEVICE_ID, NODE_INSTANCE_ID);

    expect(result.unclaimed_device).toEqual(DEVICE_A);
    expect(result.unclaimed_device.claim_code).toBe('AAAA-0001');
  });

  it('returns the node_instance_id from the claim response', async () => {
    const claimResponse: ClaimResponse = {
      unclaimed_device: DEVICE_A,
      node_instance_id: NODE_INSTANCE_ID,
      node_instance_name: 'edge-server-01',
    };
    mockPost.mockResolvedValueOnce(envelope(claimResponse));

    const result = await unclaimedDevicesApi.claim(DEVICE_ID, NODE_INSTANCE_ID);

    expect(result.node_instance_id).toBe(NODE_INSTANCE_ID);
  });

  it('returns the node_instance_name from the claim response', async () => {
    const claimResponse: ClaimResponse = {
      unclaimed_device: DEVICE_B,
      node_instance_id: 'inst-b-target',
      node_instance_name: 'physical-rack-3',
    };
    mockPost.mockResolvedValueOnce(envelope(claimResponse));

    const result = await unclaimedDevicesApi.claim('dev-b', 'inst-b-target');

    expect(result.node_instance_name).toBe('physical-rack-3');
  });

  it('propagates API errors (e.g. 409 Conflict — already claimed) to the caller', async () => {
    mockPost.mockRejectedValueOnce(new Error('409 Conflict — device already claimed'));

    await expect(unclaimedDevicesApi.claim(DEVICE_ID, NODE_INSTANCE_ID)).rejects.toThrow(
      '409 Conflict — device already claimed',
    );
  });

  it('propagates validation errors (e.g. 422 node_instance_id blank) to the caller', async () => {
    mockPost.mockRejectedValueOnce(new Error('Unprocessable Entity'));

    await expect(unclaimedDevicesApi.claim(DEVICE_ID, '')).rejects.toThrow('Unprocessable Entity');
  });

  it('does not call GET or DELETE for a claim operation', async () => {
    const claimResponse: ClaimResponse = {
      unclaimed_device: DEVICE_A,
      node_instance_id: NODE_INSTANCE_ID,
      node_instance_name: 'edge-server-01',
    };
    mockPost.mockResolvedValueOnce(envelope(claimResponse));

    await unclaimedDevicesApi.claim(DEVICE_ID, NODE_INSTANCE_ID);

    expect(mockGet).not.toHaveBeenCalled();
    expect(mockDelete).not.toHaveBeenCalled();
  });
});

// =============================================================================
// unclaimedDevicesApi.discard
// =============================================================================

describe('unclaimedDevicesApi.discard', () => {
  it('calls DELETE /system/unclaimed_devices/:id', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await unclaimedDevicesApi.discard('dev-a');

    expect(mockDelete).toHaveBeenCalledTimes(1);
    expect(mockDelete).toHaveBeenCalledWith('/system/unclaimed_devices/dev-a');
  });

  it('interpolates arbitrary device IDs into the delete URL', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await unclaimedDevicesApi.discard('dev-stale-uuid-xyz');

    expect(mockDelete).toHaveBeenCalledWith('/system/unclaimed_devices/dev-stale-uuid-xyz');
  });

  it('resolves to void (returns undefined)', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    const result = await unclaimedDevicesApi.discard('dev-a');

    expect(result).toBeUndefined();
  });

  it('does not call GET or POST for a discard operation', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await unclaimedDevicesApi.discard('dev-a');

    expect(mockGet).not.toHaveBeenCalled();
    expect(mockPost).not.toHaveBeenCalled();
  });

  it('propagates API errors (e.g. 404 device not found) to the caller', async () => {
    mockDelete.mockRejectedValueOnce(new Error('Not found'));

    await expect(unclaimedDevicesApi.discard('nonexistent-dev')).rejects.toThrow('Not found');
  });

  it('propagates authorization errors to the caller', async () => {
    mockDelete.mockRejectedValueOnce(new Error('Forbidden'));

    await expect(unclaimedDevicesApi.discard('dev-a')).rejects.toThrow('Forbidden');
  });
});

// =============================================================================
// unclaimedDevicesApi.downloadDiskImage
// =============================================================================

describe('unclaimedDevicesApi.downloadDiskImage', () => {
  const PLATFORM_ID = 'platform-rpi5';

  it('calls GET /system/node_platforms/:platformId/disk_image and returns the disk image', async () => {
    const diskImage = makeDiskImage();
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    const result = await unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID);

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith(
      `/system/node_platforms/${PLATFORM_ID}/disk_image`,
    );
    expect(result).toEqual(diskImage);
  });

  it('interpolates the platformId into the GET URL', async () => {
    const diskImage = makeDiskImage();
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    await unclaimedDevicesApi.downloadDiskImage('platform-x86-server');

    expect(mockGet).toHaveBeenCalledWith(
      '/system/node_platforms/platform-x86-server/disk_image',
    );
  });

  it('returns the signed URL from the disk image response', async () => {
    const diskImage = makeDiskImage({
      url: 'https://cdn.example.com/powernode.img?sig=abc&expires=1234567890',
    });
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    const result = await unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID);

    expect(result.url).toBe('https://cdn.example.com/powernode.img?sig=abc&expires=1234567890');
  });

  it('returns the expires_at TTL from the disk image response', async () => {
    const diskImage = makeDiskImage({ expires_at: '2026-06-05T13:30:00Z' });
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    const result = await unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID);

    expect(result.expires_at).toBe('2026-06-05T13:30:00Z');
  });

  it('returns the sha256 checksum from the disk image response', async () => {
    const sha = 'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
    const diskImage = makeDiskImage({ sha256: sha });
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    const result = await unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID);

    expect(result.sha256).toBe(sha);
  });

  it('returns the size_bytes from the disk image response', async () => {
    const diskImage = makeDiskImage({ size_bytes: 4294967296 });
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    const result = await unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID);

    expect(result.size_bytes).toBe(4294967296);
  });

  it('returns the filename from the disk image response', async () => {
    const diskImage = makeDiskImage({ filename: 'powernode-arm64-v2.3.1.img' });
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    const result = await unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID);

    expect(result.filename).toBe('powernode-arm64-v2.3.1.img');
  });

  it('returns the built_at timestamp when present', async () => {
    const diskImage = makeDiskImage({ built_at: '2026-06-04T08:00:00Z' });
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    const result = await unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID);

    expect(result.built_at).toBe('2026-06-04T08:00:00Z');
  });

  it('returns undefined built_at when the backend omits it', async () => {
    const diskImage = makeDiskImage();
    delete (diskImage as Partial<SystemDiskImage>).built_at;
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    const result = await unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID);

    expect(result.built_at).toBeUndefined();
  });

  it('does not call POST or DELETE for a disk image download', async () => {
    const diskImage = makeDiskImage();
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    await unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID);

    expect(mockPost).not.toHaveBeenCalled();
    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('propagates API errors (e.g. 404 platform not found) to the caller', async () => {
    mockGet.mockRejectedValueOnce(new Error('Not found'));

    await expect(unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID)).rejects.toThrow('Not found');
  });

  it('propagates errors when no disk image has been published', async () => {
    mockGet.mockRejectedValueOnce(new Error('No published disk image for this platform'));

    await expect(unclaimedDevicesApi.downloadDiskImage(PLATFORM_ID)).rejects.toThrow(
      'No published disk image for this platform',
    );
  });
});

// =============================================================================
// URL construction — ensure IDs are correctly interpolated across all methods
// =============================================================================

describe('URL construction', () => {
  it('list: always uses /system/unclaimed_devices regardless of params', async () => {
    mockGet.mockResolvedValueOnce(
      paginatedEnvelope({ unclaimed_devices: [] }),
    );

    await unclaimedDevicesApi.list({ page: 99, per_page: 5 });

    expect(mockGet).toHaveBeenCalledWith('/system/unclaimed_devices', {
      params: { page: 99, per_page: 5 },
    });
  });

  it('get: uses the provided device ID in the URL path', async () => {
    const device = makeDevice({ id: 'uuid-custom-dev' });
    mockGet.mockResolvedValueOnce(envelope({ unclaimed_device: device }));

    await unclaimedDevicesApi.get('uuid-custom-dev');

    expect(mockGet).toHaveBeenCalledWith('/system/unclaimed_devices/uuid-custom-dev');
  });

  it('claim: uses both the device ID and the instance ID in the correct places', async () => {
    const claimResponse: ClaimResponse = {
      unclaimed_device: DEVICE_A,
      node_instance_id: 'inst-special',
      node_instance_name: 'srv-01',
    };
    mockPost.mockResolvedValueOnce(envelope(claimResponse));

    await unclaimedDevicesApi.claim('dev-special', 'inst-special');

    expect(mockPost).toHaveBeenCalledWith(
      '/system/unclaimed_devices/dev-special/claim',
      { node_instance_id: 'inst-special' },
    );
  });

  it('discard: uses the provided device ID in the delete URL', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await unclaimedDevicesApi.discard('dev-to-purge');

    expect(mockDelete).toHaveBeenCalledWith('/system/unclaimed_devices/dev-to-purge');
  });

  it('downloadDiskImage: uses the provided platform ID in the URL path', async () => {
    const diskImage = makeDiskImage();
    mockGet.mockResolvedValueOnce(envelope(diskImage));

    await unclaimedDevicesApi.downloadDiskImage('platform-custom-99');

    expect(mockGet).toHaveBeenCalledWith(
      '/system/node_platforms/platform-custom-99/disk_image',
    );
  });
});

// =============================================================================
// Method isolation — each function only calls its expected HTTP verb
// =============================================================================

describe('method isolation', () => {
  it('list only calls GET, never POST or DELETE', async () => {
    mockGet.mockResolvedValueOnce(paginatedEnvelope({ unclaimed_devices: [] }));

    await unclaimedDevicesApi.list();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockPost).not.toHaveBeenCalled();
    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('get only calls GET, never POST or DELETE', async () => {
    mockGet.mockResolvedValueOnce(envelope({ unclaimed_device: DEVICE_A }));

    await unclaimedDevicesApi.get('dev-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockPost).not.toHaveBeenCalled();
    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('claim only calls POST, never GET or DELETE', async () => {
    const claimResponse: ClaimResponse = {
      unclaimed_device: DEVICE_A,
      node_instance_id: 'inst-1',
      node_instance_name: 'srv-1',
    };
    mockPost.mockResolvedValueOnce(envelope(claimResponse));

    await unclaimedDevicesApi.claim('dev-a', 'inst-1');

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockGet).not.toHaveBeenCalled();
    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('discard only calls DELETE, never GET or POST', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await unclaimedDevicesApi.discard('dev-a');

    expect(mockDelete).toHaveBeenCalledTimes(1);
    expect(mockGet).not.toHaveBeenCalled();
    expect(mockPost).not.toHaveBeenCalled();
  });

  it('downloadDiskImage only calls GET, never POST or DELETE', async () => {
    mockGet.mockResolvedValueOnce(envelope(makeDiskImage()));

    await unclaimedDevicesApi.downloadDiskImage('platform-1');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockPost).not.toHaveBeenCalled();
    expect(mockDelete).not.toHaveBeenCalled();
  });
});
