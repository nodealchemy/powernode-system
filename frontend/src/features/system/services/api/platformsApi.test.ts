// Unit tests for platformsApi.
//
// Covers: every exported function, correct URL construction, request payload
// shaping, envelope unwrapping (single-record vs. list), edge cases (empty
// collections, optional fields, disk-image download), and error propagation.

import { platformsApi, type PlatformCreate } from './platformsApi';
import type { SystemNodePlatform } from '@system/features/system/types/system.types';

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
// Fixtures
// =============================================================================

const PLATFORM_ID = 'plat-abc-123';

function makePlatform(
  overrides: Partial<SystemNodePlatform> = {},
): SystemNodePlatform {
  return {
    id: PLATFORM_ID,
    name: 'ubuntu-22-x86',
    description: 'Ubuntu 22.04 LTS x86_64 base platform',
    enabled: true,
    public: false,
    build_script: '#!/bin/bash\napt-get update',
    init_script: '#!/bin/bash\nsystemctl start powernode-agent',
    sync_script: '#!/bin/bash\nrsync -a /src /dst',
    node_architecture_id: 'arch-x86-1',
    architecture_name: 'x86_64',
    template_count: 3,
    module_count: 12,
    disk_image_file_object_id: 'file-obj-42',
    disk_image_sha256: 'sha256:deadbeef',
    disk_image_size_bytes: 1073741824,
    disk_image_built_at: '2026-06-01T00:00:00Z',
    disk_image_oci_ref: 'registry.example.com/ubuntu-22-x86:latest',
    disk_image_git_sha: 'abc123def456',
    disk_image_publication_status: 'published',
    disk_image_retention_count: 3,
    cosign_identity_regexp: '^ci-builder@.*',
    cosign_issuer_regexp: '^https://token.actions.githubusercontent.com',
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-06-01T00:00:00Z',
    ...overrides,
  };
}

// Double-envelope helper — AxiosResponse.data is the body { success, data }.
function envelope<T>(data: T) {
  return { data: { success: true as const, data } };
}

// =============================================================================
// Tests
// =============================================================================

describe('platformsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // getPlatforms
  // ---------------------------------------------------------------------------
  describe('getPlatforms()', () => {
    it('calls GET /system/node_platforms', async () => {
      mockGet.mockResolvedValue(
        envelope({ node_platforms: [makePlatform()] }),
      );

      await platformsApi.getPlatforms();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/node_platforms');
    });

    it('returns an array of platforms from the nested data.node_platforms key', async () => {
      const plat1 = makePlatform({ id: 'p-1', name: 'ubuntu-22' });
      const plat2 = makePlatform({ id: 'p-2', name: 'debian-12' });
      mockGet.mockResolvedValue(
        envelope({ node_platforms: [plat1, plat2] }),
      );

      const result = await platformsApi.getPlatforms();

      expect(result).toHaveLength(2);
      expect(result[0]).toMatchObject({ id: 'p-1', name: 'ubuntu-22' });
      expect(result[1]).toMatchObject({ id: 'p-2', name: 'debian-12' });
    });

    it('returns an empty array when node_platforms is an empty list', async () => {
      mockGet.mockResolvedValue(
        envelope({ node_platforms: [] }),
      );

      const result = await platformsApi.getPlatforms();

      expect(result).toEqual([]);
    });

    it('returns an empty array when node_platforms key is absent from the response', async () => {
      mockGet.mockResolvedValue(
        envelope({} as { node_platforms: SystemNodePlatform[] }),
      );

      const result = await platformsApi.getPlatforms();

      expect(result).toEqual([]);
    });

    it('returns platforms with optional disk-image fields populated', async () => {
      const plat = makePlatform({
        disk_image_publication_status: 'published',
        disk_image_sha256: 'sha256:aabbcc',
        disk_image_size_bytes: 2147483648,
      });
      mockGet.mockResolvedValue(envelope({ node_platforms: [plat] }));

      const result = await platformsApi.getPlatforms();

      expect(result[0].disk_image_publication_status).toBe('published');
      expect(result[0].disk_image_sha256).toBe('sha256:aabbcc');
      expect(result[0].disk_image_size_bytes).toBe(2147483648);
    });

    it('returns platforms with disk_image_publication_status "none" for fresh platforms', async () => {
      const plat = makePlatform({
        disk_image_file_object_id: undefined,
        disk_image_sha256: undefined,
        disk_image_publication_status: 'none',
      });
      mockGet.mockResolvedValue(envelope({ node_platforms: [plat] }));

      const result = await platformsApi.getPlatforms();

      expect(result[0].disk_image_publication_status).toBe('none');
      expect(result[0].disk_image_file_object_id).toBeUndefined();
    });

    it('propagates API errors to the caller', async () => {
      const err = new Error('Network Error');
      mockGet.mockRejectedValue(err);

      await expect(platformsApi.getPlatforms()).rejects.toThrow('Network Error');
    });

    it('does not call POST, PUT, or DELETE for a list operation', async () => {
      mockGet.mockResolvedValue(envelope({ node_platforms: [] }));

      await platformsApi.getPlatforms();

      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });

    it('begins executing synchronously (before the first await) and registers the GET call immediately', () => {
      mockGet.mockResolvedValue(envelope({ node_platforms: [] }));

      const promise = platformsApi.getPlatforms();

      expect(mockGet).toHaveBeenCalledTimes(1);

      return promise;
    });
  });

  // ---------------------------------------------------------------------------
  // getPlatform
  // ---------------------------------------------------------------------------
  describe('getPlatform()', () => {
    it('calls GET /system/node_platforms/:id', async () => {
      mockGet.mockResolvedValue(envelope({ node_platform: makePlatform() }));

      await platformsApi.getPlatform(PLATFORM_ID);

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(`/system/node_platforms/${PLATFORM_ID}`);
    });

    it('returns the single platform extracted from the envelope', async () => {
      const plat = makePlatform({ name: 'arm-debian-12', enabled: false });
      mockGet.mockResolvedValue(envelope({ node_platform: plat }));

      const result = await platformsApi.getPlatform(PLATFORM_ID);

      expect(result).toMatchObject({ id: PLATFORM_ID, name: 'arm-debian-12', enabled: false });
    });

    it('uses the provided id in the URL path', async () => {
      const OTHER_ID = 'plat-other-999';
      const plat = makePlatform({ id: OTHER_ID });
      mockGet.mockResolvedValue(envelope({ node_platform: plat }));

      await platformsApi.getPlatform(OTHER_ID);

      expect(mockGet).toHaveBeenCalledWith(`/system/node_platforms/${OTHER_ID}`);
    });

    it('returns all optional disk-image fields when present', async () => {
      const plat = makePlatform({
        disk_image_publication_status: 'verifying',
        disk_image_oci_ref: 'registry.example.com/plat:sha256-abc',
        disk_image_git_sha: 'cafebabe',
        disk_image_retention_count: 5,
      });
      mockGet.mockResolvedValue(envelope({ node_platform: plat }));

      const result = await platformsApi.getPlatform(PLATFORM_ID);

      expect(result.disk_image_publication_status).toBe('verifying');
      expect(result.disk_image_oci_ref).toBe('registry.example.com/plat:sha256-abc');
      expect(result.disk_image_git_sha).toBe('cafebabe');
      expect(result.disk_image_retention_count).toBe(5);
    });

    it('returns a platform with publication_status "failed" and error details', async () => {
      const plat = makePlatform({
        disk_image_publication_status: 'failed',
        disk_image_publication_error: 'cosign verify failed: no matching signature',
      });
      mockGet.mockResolvedValue(envelope({ node_platform: plat }));

      const result = await platformsApi.getPlatform(PLATFORM_ID);

      expect(result.disk_image_publication_status).toBe('failed');
      expect(result.disk_image_publication_error).toBe(
        'cosign verify failed: no matching signature',
      );
    });

    it('returns cosign trust policy fields when present', async () => {
      const plat = makePlatform({
        cosign_identity_regexp: '^ci-runner@example.com',
        cosign_issuer_regexp: '^https://accounts.google.com',
      });
      mockGet.mockResolvedValue(envelope({ node_platform: plat }));

      const result = await platformsApi.getPlatform(PLATFORM_ID);

      expect(result.cosign_identity_regexp).toBe('^ci-runner@example.com');
      expect(result.cosign_issuer_regexp).toBe('^https://accounts.google.com');
    });

    it('propagates API errors to the caller', async () => {
      const err = new Error('Not Found');
      mockGet.mockRejectedValue(err);

      await expect(platformsApi.getPlatform(PLATFORM_ID)).rejects.toThrow('Not Found');
    });
  });

  // ---------------------------------------------------------------------------
  // createPlatform
  // ---------------------------------------------------------------------------
  describe('createPlatform()', () => {
    const CREATE_DATA: PlatformCreate = {
      name: 'fedora-38-arm',
      description: 'Fedora 38 ARM64',
      node_architecture_id: 'arch-arm-1',
      build_script: '#!/bin/bash\ndnf update -y',
      init_script: '#!/bin/bash\nsystemctl enable powernode-agent',
      sync_script: undefined,
      enabled: true,
      public: false,
    };

    it('calls POST /system/node_platforms', async () => {
      const newPlat = makePlatform({ id: 'plat-new', name: 'fedora-38-arm' });
      mockPost.mockResolvedValue(envelope({ node_platform: newPlat }));

      await platformsApi.createPlatform(CREATE_DATA);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        '/system/node_platforms',
        { node_platform: CREATE_DATA },
      );
    });

    it('wraps the payload under the node_platform key', async () => {
      const newPlat = makePlatform({ id: 'plat-new' });
      mockPost.mockResolvedValue(envelope({ node_platform: newPlat }));

      await platformsApi.createPlatform(CREATE_DATA);

      const [, body] = mockPost.mock.calls[0] as [string, { node_platform: PlatformCreate }];
      expect(body).toEqual({ node_platform: CREATE_DATA });
    });

    it('returns the created platform extracted from the envelope', async () => {
      const newPlat = makePlatform({ id: 'plat-new', name: 'fedora-38-arm' });
      mockPost.mockResolvedValue(envelope({ node_platform: newPlat }));

      const result = await platformsApi.createPlatform(CREATE_DATA);

      expect(result).toMatchObject({ id: 'plat-new', name: 'fedora-38-arm' });
    });

    it('sends a minimal payload (name-only) correctly', async () => {
      const minimalData: PlatformCreate = { name: 'minimal-platform' };
      const newPlat = makePlatform({ id: 'plat-min', name: 'minimal-platform' });
      mockPost.mockResolvedValue(envelope({ node_platform: newPlat }));

      await platformsApi.createPlatform(minimalData);

      expect(mockPost).toHaveBeenCalledWith(
        '/system/node_platforms',
        { node_platform: minimalData },
      );
    });

    it('sends enabled and public flags when provided', async () => {
      const data: PlatformCreate = { name: 'public-platform', enabled: true, public: true };
      const newPlat = makePlatform({ id: 'plat-pub', name: 'public-platform', public: true });
      mockPost.mockResolvedValue(envelope({ node_platform: newPlat }));

      await platformsApi.createPlatform(data);

      const [, body] = mockPost.mock.calls[0] as [string, { node_platform: PlatformCreate }];
      expect(body.node_platform.enabled).toBe(true);
      expect(body.node_platform.public).toBe(true);
    });

    it('propagates API errors to the caller', async () => {
      const err = new Error('Unprocessable Entity');
      mockPost.mockRejectedValue(err);

      await expect(platformsApi.createPlatform(CREATE_DATA)).rejects.toThrow(
        'Unprocessable Entity',
      );
    });

    it('does not call GET, PUT, or DELETE for a create operation', async () => {
      const newPlat = makePlatform({ id: 'plat-new' });
      mockPost.mockResolvedValue(envelope({ node_platform: newPlat }));

      await platformsApi.createPlatform(CREATE_DATA);

      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // updatePlatform
  // ---------------------------------------------------------------------------
  describe('updatePlatform()', () => {
    const UPDATE_DATA: Partial<PlatformCreate> = {
      name: 'ubuntu-22-updated',
      enabled: false,
    };

    it('calls PUT /system/node_platforms/:id', async () => {
      const updatedPlat = makePlatform({ name: 'ubuntu-22-updated', enabled: false });
      mockPut.mockResolvedValue(envelope({ node_platform: updatedPlat }));

      await platformsApi.updatePlatform(PLATFORM_ID, UPDATE_DATA);

      expect(mockPut).toHaveBeenCalledTimes(1);
      expect(mockPut).toHaveBeenCalledWith(
        `/system/node_platforms/${PLATFORM_ID}`,
        { node_platform: UPDATE_DATA },
      );
    });

    it('wraps the partial payload under the node_platform key', async () => {
      const updatedPlat = makePlatform({ enabled: false });
      mockPut.mockResolvedValue(envelope({ node_platform: updatedPlat }));

      await platformsApi.updatePlatform(PLATFORM_ID, UPDATE_DATA);

      const [, body] = mockPut.mock.calls[0] as [
        string,
        { node_platform: Partial<PlatformCreate> },
      ];
      expect(body).toEqual({ node_platform: UPDATE_DATA });
    });

    it('returns the updated platform extracted from the envelope', async () => {
      const updatedPlat = makePlatform({ name: 'ubuntu-22-updated', enabled: false });
      mockPut.mockResolvedValue(envelope({ node_platform: updatedPlat }));

      const result = await platformsApi.updatePlatform(PLATFORM_ID, UPDATE_DATA);

      expect(result).toMatchObject({ name: 'ubuntu-22-updated', enabled: false });
    });

    it('uses the provided id in the URL path', async () => {
      const OTHER_ID = 'plat-other-999';
      const updatedPlat = makePlatform({ id: OTHER_ID });
      mockPut.mockResolvedValue(envelope({ node_platform: updatedPlat }));

      await platformsApi.updatePlatform(OTHER_ID, UPDATE_DATA);

      expect(mockPut).toHaveBeenCalledWith(
        `/system/node_platforms/${OTHER_ID}`,
        { node_platform: UPDATE_DATA },
      );
    });

    it('sends a single-field partial update correctly', async () => {
      const singleField: Partial<PlatformCreate> = { enabled: true };
      const updatedPlat = makePlatform({ enabled: true });
      mockPut.mockResolvedValue(envelope({ node_platform: updatedPlat }));

      await platformsApi.updatePlatform(PLATFORM_ID, singleField);

      const [, body] = mockPut.mock.calls[0] as [
        string,
        { node_platform: Partial<PlatformCreate> },
      ];
      expect(body.node_platform).toEqual({ enabled: true });
    });

    it('sends cosign trust-policy fields when updating the policy', async () => {
      const policyUpdate: Partial<PlatformCreate> = {
        name: 'ubuntu-22-x86',
      };
      const updatedPlat = makePlatform({
        cosign_identity_regexp: '^ci@.*',
        cosign_issuer_regexp: '^https://token.actions.githubusercontent.com',
      });
      mockPut.mockResolvedValue(envelope({ node_platform: updatedPlat }));

      await platformsApi.updatePlatform(PLATFORM_ID, policyUpdate);

      expect(mockPut).toHaveBeenCalledWith(
        `/system/node_platforms/${PLATFORM_ID}`,
        { node_platform: policyUpdate },
      );
    });

    it('propagates API errors to the caller', async () => {
      const err = new Error('Conflict');
      mockPut.mockRejectedValue(err);

      await expect(platformsApi.updatePlatform(PLATFORM_ID, UPDATE_DATA)).rejects.toThrow(
        'Conflict',
      );
    });

    it('does not call GET, POST, or DELETE for an update operation', async () => {
      const updatedPlat = makePlatform();
      mockPut.mockResolvedValue(envelope({ node_platform: updatedPlat }));

      await platformsApi.updatePlatform(PLATFORM_ID, UPDATE_DATA);

      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // deletePlatform
  // ---------------------------------------------------------------------------
  describe('deletePlatform()', () => {
    it('calls DELETE /system/node_platforms/:id', async () => {
      mockDelete.mockResolvedValue({ data: { success: true } });

      await platformsApi.deletePlatform(PLATFORM_ID);

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith(`/system/node_platforms/${PLATFORM_ID}`);
    });

    it('uses the provided id in the URL path', async () => {
      const OTHER_ID = 'plat-delete-999';
      mockDelete.mockResolvedValue({ data: { success: true } });

      await platformsApi.deletePlatform(OTHER_ID);

      expect(mockDelete).toHaveBeenCalledWith(`/system/node_platforms/${OTHER_ID}`);
    });

    it('resolves to undefined (void return)', async () => {
      mockDelete.mockResolvedValue({ data: { success: true } });

      const result = await platformsApi.deletePlatform(PLATFORM_ID);

      expect(result).toBeUndefined();
    });

    it('propagates API errors to the caller', async () => {
      const err = new Error('Forbidden');
      mockDelete.mockRejectedValue(err);

      await expect(platformsApi.deletePlatform(PLATFORM_ID)).rejects.toThrow('Forbidden');
    });

    it('does not call GET, POST, or PUT for a delete operation', async () => {
      mockDelete.mockResolvedValue({ data: { success: true } });

      await platformsApi.deletePlatform(PLATFORM_ID);

      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // downloadDiskImage
  // ---------------------------------------------------------------------------
  describe('downloadDiskImage()', () => {
    // jsdom does not implement URL.createObjectURL / revokeObjectURL.
    // Install stub functions on the global URL object so jest.spyOn can wrap them.
    let createObjectURLSpy: jest.SpyInstance;
    let revokeObjectURLSpy: jest.SpyInstance;
    let appendChildSpy: jest.SpyInstance;
    let removeChildSpy: jest.SpyInstance;
    let clickSpy: jest.Mock;
    let fakeLink: HTMLAnchorElement;

    beforeEach(() => {
      // Ensure the methods exist on URL before spying (jsdom omits them).
      if (!URL.createObjectURL) {
        URL.createObjectURL = () => '';
      }
      if (!URL.revokeObjectURL) {
        URL.revokeObjectURL = () => undefined;
      }

      createObjectURLSpy = jest
        .spyOn(URL, 'createObjectURL')
        .mockReturnValue('blob:fake-object-url');
      revokeObjectURLSpy = jest
        .spyOn(URL, 'revokeObjectURL')
        .mockReturnValue(undefined);

      // Intercept the anchor element lifecycle so we can assert on it.
      clickSpy = jest.fn();
      fakeLink = Object.assign(document.createElement('a'), { click: clickSpy });
      jest.spyOn(document, 'createElement').mockReturnValue(fakeLink);

      appendChildSpy = jest.spyOn(document.body, 'appendChild').mockReturnValue(fakeLink);
      removeChildSpy = jest.spyOn(document.body, 'removeChild').mockReturnValue(fakeLink);
    });

    afterEach(() => {
      createObjectURLSpy.mockRestore();
      revokeObjectURLSpy.mockRestore();
      appendChildSpy.mockRestore();
      removeChildSpy.mockRestore();
      (document.createElement as jest.Mock).mockRestore();
    });

    it('calls GET /system/node_platforms/:id/disk_image with responseType blob', async () => {
      const fakeBlob = new Blob(['fake-image-bytes'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({
        data: fakeBlob,
        headers: { 'content-disposition': 'attachment; filename="powernode.img"' },
      });

      await platformsApi.downloadDiskImage(PLATFORM_ID);

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(
        `/system/node_platforms/${PLATFORM_ID}/disk_image`,
        { responseType: 'blob' },
      );
    });

    it('uses the provided id in the URL path', async () => {
      const OTHER_ID = 'plat-download-42';
      const fakeBlob = new Blob(['bytes'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({
        data: fakeBlob,
        headers: { 'content-disposition': `attachment; filename="powernode-${OTHER_ID}.img"` },
      });

      await platformsApi.downloadDiskImage(OTHER_ID);

      expect(mockGet).toHaveBeenCalledWith(
        `/system/node_platforms/${OTHER_ID}/disk_image`,
        { responseType: 'blob' },
      );
    });

    it('extracts the filename from Content-Disposition and sets link.download', async () => {
      const fakeBlob = new Blob(['img'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({
        data: fakeBlob,
        headers: { 'content-disposition': 'attachment; filename="custom-name.img"' },
      });

      await platformsApi.downloadDiskImage(PLATFORM_ID);

      expect(fakeLink.download).toBe('custom-name.img');
    });

    it('falls back to powernode-<id>.img when Content-Disposition header is absent', async () => {
      const fakeBlob = new Blob(['img'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({
        data: fakeBlob,
        headers: {},
      });

      await platformsApi.downloadDiskImage(PLATFORM_ID);

      expect(fakeLink.download).toBe(`powernode-${PLATFORM_ID}.img`);
    });

    it('falls back to powernode-<id>.img when Content-Disposition is an empty string', async () => {
      const fakeBlob = new Blob(['img'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({
        data: fakeBlob,
        headers: { 'content-disposition': '' },
      });

      await platformsApi.downloadDiskImage(PLATFORM_ID);

      expect(fakeLink.download).toBe(`powernode-${PLATFORM_ID}.img`);
    });

    it('triggers a click on the anchor element to initiate download', async () => {
      const fakeBlob = new Blob(['img'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({
        data: fakeBlob,
        headers: { 'content-disposition': 'attachment; filename="powernode.img"' },
      });

      await platformsApi.downloadDiskImage(PLATFORM_ID);

      expect(clickSpy).toHaveBeenCalledTimes(1);
    });

    it('appends then removes the anchor from document.body', async () => {
      const fakeBlob = new Blob(['img'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({
        data: fakeBlob,
        headers: { 'content-disposition': 'attachment; filename="powernode.img"' },
      });

      await platformsApi.downloadDiskImage(PLATFORM_ID);

      expect(appendChildSpy).toHaveBeenCalledWith(fakeLink);
      expect(removeChildSpy).toHaveBeenCalledWith(fakeLink);
    });

    it('creates an object URL from the blob and sets it as link.href', async () => {
      const fakeBlob = new Blob(['img'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({
        data: fakeBlob,
        headers: { 'content-disposition': 'attachment; filename="powernode.img"' },
      });

      await platformsApi.downloadDiskImage(PLATFORM_ID);

      expect(createObjectURLSpy).toHaveBeenCalledWith(fakeBlob);
      expect(fakeLink.href).toContain('blob:fake-object-url');
    });

    it('revokes the object URL after the click', async () => {
      const fakeBlob = new Blob(['img'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({
        data: fakeBlob,
        headers: { 'content-disposition': 'attachment; filename="powernode.img"' },
      });

      await platformsApi.downloadDiskImage(PLATFORM_ID);

      expect(revokeObjectURLSpy).toHaveBeenCalledWith('blob:fake-object-url');
    });

    it('wraps a non-Blob data response in a new Blob before creating the object URL', async () => {
      // The source handles the case where the API returns a non-Blob (e.g. an
      // ArrayBuffer or raw string) by wrapping it in a Blob manually.
      const rawData = 'raw-binary-data';
      mockGet.mockResolvedValue({
        data: rawData,
        headers: { 'content-disposition': 'attachment; filename="powernode.img"' },
      });

      await platformsApi.downloadDiskImage(PLATFORM_ID);

      // createObjectURL should have been called with a Blob (the wrapped form).
      const blobArg = createObjectURLSpy.mock.calls[0][0] as unknown;
      expect(blobArg).toBeInstanceOf(Blob);
    });

    it('resolves to undefined (void return)', async () => {
      const fakeBlob = new Blob(['img'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({
        data: fakeBlob,
        headers: { 'content-disposition': 'attachment; filename="powernode.img"' },
      });

      const result = await platformsApi.downloadDiskImage(PLATFORM_ID);

      expect(result).toBeUndefined();
    });

    it('propagates API errors to the caller', async () => {
      const err = new Error('Not Found');
      mockGet.mockRejectedValue(err);

      await expect(platformsApi.downloadDiskImage(PLATFORM_ID)).rejects.toThrow('Not Found');
    });
  });

  // ---------------------------------------------------------------------------
  // URL construction — spot-check that ids are correctly interpolated
  // ---------------------------------------------------------------------------
  describe('URL construction', () => {
    it('getPlatform: embeds the id in the URL path segment', async () => {
      const ID = 'plat-seg-check';
      mockGet.mockResolvedValue(envelope({ node_platform: makePlatform({ id: ID }) }));

      await platformsApi.getPlatform(ID);

      expect(mockGet.mock.calls[0][0]).toBe(`/system/node_platforms/${ID}`);
    });

    it('updatePlatform: embeds the id in the URL path segment', async () => {
      const ID = 'plat-upd-check';
      mockPut.mockResolvedValue(envelope({ node_platform: makePlatform({ id: ID }) }));

      await platformsApi.updatePlatform(ID, { name: 'x' });

      expect(mockPut.mock.calls[0][0]).toBe(`/system/node_platforms/${ID}`);
    });

    it('deletePlatform: embeds the id in the URL path segment', async () => {
      const ID = 'plat-del-check';
      mockDelete.mockResolvedValue({ data: { success: true } });

      await platformsApi.deletePlatform(ID);

      expect(mockDelete.mock.calls[0][0]).toBe(`/system/node_platforms/${ID}`);
    });

    it('downloadDiskImage: embeds the id in the URL path segment', async () => {
      const ID = 'plat-dl-check';
      const blob = new Blob(['x'], { type: 'application/octet-stream' });
      mockGet.mockResolvedValue({ data: blob, headers: {} });

      // Ensure stubs exist on URL before spying (jsdom omits them).
      if (!URL.createObjectURL) URL.createObjectURL = () => '';
      if (!URL.revokeObjectURL) URL.revokeObjectURL = () => undefined;

      const createSpy = jest.spyOn(URL, 'createObjectURL').mockReturnValue('blob:x');
      const revokeSpy = jest.spyOn(URL, 'revokeObjectURL').mockReturnValue(undefined);
      const appendSpy = jest
        .spyOn(document.body, 'appendChild')
        .mockReturnValue(document.createElement('a'));
      const removeSpy = jest
        .spyOn(document.body, 'removeChild')
        .mockReturnValue(document.createElement('a'));
      const createElSpy = jest
        .spyOn(document, 'createElement')
        .mockReturnValue(Object.assign(document.createElement('a'), { click: jest.fn() }));

      await platformsApi.downloadDiskImage(ID);

      expect(mockGet.mock.calls[0][0]).toBe(`/system/node_platforms/${ID}/disk_image`);

      createSpy.mockRestore();
      revokeSpy.mockRestore();
      appendSpy.mockRestore();
      removeSpy.mockRestore();
      createElSpy.mockRestore();
    });
  });

  // ---------------------------------------------------------------------------
  // disk_image_publication_status variants
  // ---------------------------------------------------------------------------
  describe('disk_image_publication_status variants', () => {
    const statuses: SystemNodePlatform['disk_image_publication_status'][] = [
      'none',
      'verifying',
      'published',
      'failed',
    ];

    for (const status of statuses) {
      it(`getPlatform returns a platform with status "${status}"`, async () => {
        const plat = makePlatform({ disk_image_publication_status: status });
        mockGet.mockResolvedValue(envelope({ node_platform: plat }));

        const result = await platformsApi.getPlatform(PLATFORM_ID);

        expect(result.disk_image_publication_status).toBe(status);
      });
    }
  });
});
