// Unit tests for diskImagePublicationsApi.
//
// Covers: every exported function, correct URL construction, payload shaping,
// envelope unwrapping (including paginated vs. single-record paths), edge
// cases (empty collections, missing optional fields, purged publications),
// and error propagation.

import { diskImagePublicationsApi } from './diskImagePublicationsApi';
import type {
  SystemDiskImagePublication,
  SystemDiskImagePublicationStatus,
} from '@system/features/system/types/system.types';
import type { PaginationMeta } from './types';

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

const PLATFORM_ID = 'platform-abc';
const PUBLICATION_ID = 'pub-123';

const META: PaginationMeta = {
  current_page: 1,
  per_page: 25,
  total_count: 2,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

function makePublication(
  overrides: Partial<SystemDiskImagePublication> = {},
): SystemDiskImagePublication {
  return {
    id: PUBLICATION_ID,
    platform_id: PLATFORM_ID,
    account_id: 'acct-1',
    status: 'published',
    active: true,
    git_sha: 'abc123def456abc123def456abc123def456abc1',
    git_sha_short: 'abc123d',
    sha256: 'sha256:deadbeef0000deadbeef0000deadbeef0000deadbeef0000deadbeef0000dead',
    sha256_short: 'deadbeef',
    oci_ref: 'registry.example.com/platform:abc123d',
    size_bytes: 1073741824,
    arch: 'x86_64',
    attempt_count: 1,
    attestation_present: true,
    cosign_bundle_present: true,
    firmware_ref: undefined,
    file_object_id: 'file-obj-1',
    prior_file_object_id: 'file-obj-0',
    webhook_id: 'wh-1',
    webhook_label: 'CI webhook',
    triggered_by_worker_id: 'worker-1',
    attestation_predicate: { buildType: 'https://tekton.dev/chains/v2' },
    verified_at: '2026-06-01T00:00:00Z',
    published_at: '2026-06-01T00:01:00Z',
    created_at: '2026-06-01T00:00:00Z',
    updated_at: '2026-06-01T00:01:00Z',
    ...overrides,
  };
}

// Double-envelope helper — mirrors the backend `render_success` body that
// AxiosResponse.data exposes.  For paginated calls meta sits at the body root.
function envelope<T>(data: T, meta?: PaginationMeta) {
  return {
    data: {
      success: true as const,
      data,
      ...(meta ? { meta } : {}),
    },
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('diskImagePublicationsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list
  // ---------------------------------------------------------------------------
  describe('list', () => {
    it('calls GET with the correct URL for a given platform', async () => {
      const pub = makePublication();
      mockGet.mockResolvedValue(
        envelope({ disk_image_publications: [pub] }, META),
      );

      await diskImagePublicationsApi.list(PLATFORM_ID);

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(
        `/system/node_platforms/${PLATFORM_ID}/disk_image_publications`,
        { params: undefined },
      );
    });

    it('forwards pagination params to the API', async () => {
      const pub = makePublication();
      mockGet.mockResolvedValue(
        envelope({ disk_image_publications: [pub] }, META),
      );

      await diskImagePublicationsApi.list(PLATFORM_ID, { page: 2, per_page: 10 });

      expect(mockGet).toHaveBeenCalledWith(
        `/system/node_platforms/${PLATFORM_ID}/disk_image_publications`,
        { params: { page: 2, per_page: 10 } },
      );
    });

    it('returns the publications array extracted from the paginated envelope', async () => {
      const pub1 = makePublication({ id: 'pub-1', active: true });
      const pub2 = makePublication({ id: 'pub-2', active: false, status: 'retired' });
      mockGet.mockResolvedValue(
        envelope({ disk_image_publications: [pub1, pub2] }, META),
      );

      const result = await diskImagePublicationsApi.list(PLATFORM_ID);

      expect(result.publications).toHaveLength(2);
      expect(result.publications[0]).toMatchObject({ id: 'pub-1', active: true });
      expect(result.publications[1]).toMatchObject({ id: 'pub-2', status: 'retired' });
    });

    it('returns meta from the paginated envelope root (not from inside data)', async () => {
      const pub = makePublication();
      const customMeta: PaginationMeta = {
        current_page: 3,
        per_page: 5,
        total_count: 17,
        total_pages: 4,
        next_page: 4,
        prev_page: 2,
      };
      mockGet.mockResolvedValue(
        envelope({ disk_image_publications: [pub] }, customMeta),
      );

      const result = await diskImagePublicationsApi.list(PLATFORM_ID);

      expect(result.meta).toEqual(customMeta);
    });

    it('returns an empty array and synthesized meta when the collection is empty', async () => {
      mockGet.mockResolvedValue(
        envelope(
          { disk_image_publications: [] },
          {
            current_page: 1,
            per_page: 25,
            total_count: 0,
            total_pages: 1,
            next_page: null,
            prev_page: null,
          },
        ),
      );

      const result = await diskImagePublicationsApi.list(PLATFORM_ID);

      expect(result.publications).toEqual([]);
    });

    it('falls back to an empty array when disk_image_publications key is missing', async () => {
      // Backend might return a partial shape during an error recovery path.
      mockGet.mockResolvedValue(
        envelope({} as { disk_image_publications: SystemDiskImagePublication[] }),
      );

      const result = await diskImagePublicationsApi.list(PLATFORM_ID);

      expect(result.publications).toEqual([]);
    });

    it('propagates API errors to the caller', async () => {
      const err = new Error('Network error');
      mockGet.mockRejectedValue(err);

      await expect(diskImagePublicationsApi.list(PLATFORM_ID)).rejects.toThrow('Network error');
    });

    it('handles publications in every status variant', async () => {
      const statuses: SystemDiskImagePublicationStatus[] = [
        'queued',
        'awaiting_upload',
        'verifying',
        'published',
        'failed',
        'retired',
        'purged',
      ];
      const publications = statuses.map((status, i) =>
        makePublication({ id: `pub-${i}`, status }),
      );
      mockGet.mockResolvedValue(
        envelope({ disk_image_publications: publications }, META),
      );

      const result = await diskImagePublicationsApi.list(PLATFORM_ID);

      expect(result.publications.map((p) => p.status)).toEqual(statuses);
    });
  });

  // ---------------------------------------------------------------------------
  // get
  // ---------------------------------------------------------------------------
  describe('get', () => {
    it('calls GET with the correct URL for a single publication', async () => {
      const pub = makePublication();
      mockGet.mockResolvedValue(
        envelope({ disk_image_publication: pub }),
      );

      await diskImagePublicationsApi.get(PLATFORM_ID, PUBLICATION_ID);

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith(
        `/system/node_platforms/${PLATFORM_ID}/disk_image_publications/${PUBLICATION_ID}`,
      );
    });

    it('returns the publication extracted from the single-record envelope', async () => {
      const pub = makePublication({ status: 'published', active: true });
      mockGet.mockResolvedValue(envelope({ disk_image_publication: pub }));

      const result = await diskImagePublicationsApi.get(PLATFORM_ID, PUBLICATION_ID);

      expect(result).toMatchObject({
        id: PUBLICATION_ID,
        platform_id: PLATFORM_ID,
        status: 'published',
        active: true,
      });
    });

    it('returns all optional fields present on a full publication record', async () => {
      const pub = makePublication({
        firmware_ref: 'firmware-ref-xyz',
        error_message: undefined,
        attestation_predicate: { buildType: 'https://slsa.dev/provenance/v1' },
      });
      mockGet.mockResolvedValue(envelope({ disk_image_publication: pub }));

      const result = await diskImagePublicationsApi.get(PLATFORM_ID, PUBLICATION_ID);

      expect(result.firmware_ref).toBe('firmware-ref-xyz');
      expect(result.attestation_predicate).toEqual({ buildType: 'https://slsa.dev/provenance/v1' });
    });

    it('returns a purged publication whose file_object_id may be absent', async () => {
      const pub = makePublication({
        status: 'purged',
        active: false,
        file_object_id: undefined,
        purged_at: '2026-06-03T00:00:00Z',
      });
      mockGet.mockResolvedValue(envelope({ disk_image_publication: pub }));

      const result = await diskImagePublicationsApi.get(PLATFORM_ID, PUBLICATION_ID);

      expect(result.status).toBe('purged');
      expect(result.file_object_id).toBeUndefined();
      expect(result.purged_at).toBe('2026-06-03T00:00:00Z');
    });

    it('returns a failed publication with error_message populated', async () => {
      const pub = makePublication({
        status: 'failed',
        active: false,
        error_message: 'cosign verify failed: signature not found',
      });
      mockGet.mockResolvedValue(envelope({ disk_image_publication: pub }));

      const result = await diskImagePublicationsApi.get(PLATFORM_ID, PUBLICATION_ID);

      expect(result.status).toBe('failed');
      expect(result.error_message).toBe('cosign verify failed: signature not found');
    });

    it('propagates API errors to the caller', async () => {
      const err = new Error('Not found');
      mockGet.mockRejectedValue(err);

      await expect(
        diskImagePublicationsApi.get(PLATFORM_ID, PUBLICATION_ID),
      ).rejects.toThrow('Not found');
    });

    it('returns a publication without attestation when cosign fields are absent', async () => {
      const pub = makePublication({
        attestation_present: false,
        cosign_bundle_present: false,
        attestation_predicate: null,
      });
      mockGet.mockResolvedValue(envelope({ disk_image_publication: pub }));

      const result = await diskImagePublicationsApi.get(PLATFORM_ID, PUBLICATION_ID);

      expect(result.attestation_present).toBe(false);
      expect(result.cosign_bundle_present).toBe(false);
      expect(result.attestation_predicate).toBeNull();
    });
  });

  // ---------------------------------------------------------------------------
  // rollback
  // ---------------------------------------------------------------------------
  describe('rollback', () => {
    it('calls POST with the correct URL', async () => {
      mockPost.mockResolvedValue(
        envelope({
          activated_publication_id: PUBLICATION_ID,
          prior_file_object_id: 'file-obj-old',
        }),
      );

      await diskImagePublicationsApi.rollback(PLATFORM_ID, PUBLICATION_ID);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        `/system/node_platforms/${PLATFORM_ID}/rollback_disk_image`,
        { publication_id: PUBLICATION_ID },
      );
    });

    it('sends publication_id in the request body', async () => {
      const TARGET_PUB = 'pub-target-42';
      mockPost.mockResolvedValue(
        envelope({ activated_publication_id: TARGET_PUB }),
      );

      await diskImagePublicationsApi.rollback(PLATFORM_ID, TARGET_PUB);

      expect(mockPost).toHaveBeenCalledWith(
        expect.any(String),
        { publication_id: TARGET_PUB },
      );
    });

    it('returns activated_publication_id from the response envelope', async () => {
      const ACTIVATED_ID = 'pub-rollback-target';
      mockPost.mockResolvedValue(
        envelope({
          activated_publication_id: ACTIVATED_ID,
          prior_file_object_id: 'file-obj-prior',
        }),
      );

      const result = await diskImagePublicationsApi.rollback(PLATFORM_ID, ACTIVATED_ID);

      expect(result.activated_publication_id).toBe(ACTIVATED_ID);
    });

    it('returns prior_file_object_id when the backend provides it', async () => {
      mockPost.mockResolvedValue(
        envelope({
          activated_publication_id: PUBLICATION_ID,
          prior_file_object_id: 'file-obj-abc',
        }),
      );

      const result = await diskImagePublicationsApi.rollback(PLATFORM_ID, PUBLICATION_ID);

      expect(result.prior_file_object_id).toBe('file-obj-abc');
    });

    it('returns undefined prior_file_object_id when the backend omits it', async () => {
      mockPost.mockResolvedValue(
        envelope({ activated_publication_id: PUBLICATION_ID }),
      );

      const result = await diskImagePublicationsApi.rollback(PLATFORM_ID, PUBLICATION_ID);

      expect(result.prior_file_object_id).toBeUndefined();
    });

    it('propagates API errors (e.g. purged publication refused)', async () => {
      const err = new Error('Unprocessable Entity: publication is purged');
      mockPost.mockRejectedValue(err);

      await expect(
        diskImagePublicationsApi.rollback(PLATFORM_ID, PUBLICATION_ID),
      ).rejects.toThrow('Unprocessable Entity: publication is purged');
    });

    it('does not call GET or DELETE for a rollback operation', async () => {
      mockPost.mockResolvedValue(
        envelope({ activated_publication_id: PUBLICATION_ID }),
      );

      await diskImagePublicationsApi.rollback(PLATFORM_ID, PUBLICATION_ID);

      expect(mockGet).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // URL construction — ensure platform ID is correctly interpolated
  // ---------------------------------------------------------------------------
  describe('URL construction', () => {
    it('list: uses the provided platformId in the URL path', async () => {
      const OTHER_PLATFORM = 'plat-xyz-999';
      mockGet.mockResolvedValue(
        envelope({ disk_image_publications: [] }),
      );

      await diskImagePublicationsApi.list(OTHER_PLATFORM);

      expect(mockGet).toHaveBeenCalledWith(
        `/system/node_platforms/${OTHER_PLATFORM}/disk_image_publications`,
        { params: undefined },
      );
    });

    it('get: uses both platformId and publicationId in the URL path', async () => {
      const OTHER_PLATFORM = 'plat-xyz-999';
      const OTHER_PUB = 'pub-other-99';
      const pub = makePublication({ id: OTHER_PUB, platform_id: OTHER_PLATFORM });
      mockGet.mockResolvedValue(envelope({ disk_image_publication: pub }));

      await diskImagePublicationsApi.get(OTHER_PLATFORM, OTHER_PUB);

      expect(mockGet).toHaveBeenCalledWith(
        `/system/node_platforms/${OTHER_PLATFORM}/disk_image_publications/${OTHER_PUB}`,
      );
    });

    it('rollback: uses the provided platformId in the URL path', async () => {
      const OTHER_PLATFORM = 'plat-xyz-999';
      const OTHER_PUB = 'pub-other-99';
      mockPost.mockResolvedValue(
        envelope({ activated_publication_id: OTHER_PUB }),
      );

      await diskImagePublicationsApi.rollback(OTHER_PLATFORM, OTHER_PUB);

      expect(mockPost).toHaveBeenCalledWith(
        `/system/node_platforms/${OTHER_PLATFORM}/rollback_disk_image`,
        { publication_id: OTHER_PUB },
      );
    });
  });
});
