// Behavioral tests for diskImageWebhooksApi — pure request-shaping /
// response-extraction tests covering every exported function including edge cases.
//
// API double-envelope: apiClient.{get,post,delete} resolve to an AxiosResponse
// whose body is { success: true, data: <payload> }. A mocked resolve is
// therefore { data: { success: true, data: <payload> } } — the outer `data`
// key is the AxiosResponse body, and the inner `data` key is the API envelope.
//
// NOTE: The plaintext secret (secret_plaintext) and the absolute webhook URL
// are returned EXACTLY ONCE on create and rotateSecret — tests verify that
// these one-time values pass through the API layer untouched.

import { diskImageWebhooksApi } from './diskImageWebhooksApi';
import type {
  SystemDiskImageWebhook,
  SystemDiskImageWebhookCreatedResponse,
} from '@system/features/system/types/system.types';

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
// Fixtures
// =============================================================================

const WEBHOOK_A: SystemDiskImageWebhook = {
  id: 'wh-aaa',
  account_id: 'account-1',
  label: 'my-ci-repo',
  status: 'active',
  secret_preview: 'abcd1234',
  last_received_at: '2026-06-01T10:00:00Z',
  received_count: 42,
  last_rotated_at: '2026-05-01T08:00:00Z',
  created_by_id: 'user-1',
  webhook_url_path: '/api/v1/system/webhooks/disk_image/built/wh-aaa',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-06-01T10:00:00Z',
};

const WEBHOOK_B: SystemDiskImageWebhook = {
  id: 'wh-bbb',
  account_id: 'account-1',
  label: 'backup-ci-repo',
  status: 'disabled',
  secret_preview: 'efgh5678',
  received_count: 0,
  webhook_url_path: '/api/v1/system/webhooks/disk_image/built/wh-bbb',
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

const CREATED_RESPONSE: SystemDiskImageWebhookCreatedResponse = {
  disk_image_webhook: WEBHOOK_A,
  secret_plaintext: 'supersecretplaintextvalue123456',
  webhook_url: 'https://powernode.example.com/api/v1/system/webhooks/disk_image/built/wh-aaa',
  note: 'Store this secret securely — it will not be shown again.',
};

const ROTATED_RESPONSE: SystemDiskImageWebhookCreatedResponse = {
  disk_image_webhook: {
    ...WEBHOOK_A,
    secret_preview: 'xxxxxxxx',
    last_rotated_at: '2026-06-05T12:00:00Z',
    updated_at: '2026-06-05T12:00:00Z',
  },
  secret_plaintext: 'rotated_plaintext_secret_value789',
  // rotate_secret renders webhook_url through the same builder as create
  // (IMP-b5b9544fc993). Two guards, and they cover different things:
  // disk_image_webhooks_rotate_secret_spec.rb pins the field's PRESENCE on both
  // gate branches, and diskImageWebhookPath.contract.test.ts pins the literal
  // PREFIX against the model. It is the SAME url as the create response above,
  // because rotating changes the secret, not the path.
  webhook_url: 'https://powernode.example.com/api/v1/system/webhooks/disk_image/built/wh-aaa',
  note: 'Old secret revoked. Update the CI secret store before the next webhook fires.',
};

/**
 * Build the double-envelope AxiosResponse mock value.
 * Outer `data` = AxiosResponse body; inner `data` = API envelope payload.
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Tests
// =============================================================================

describe('diskImageWebhooksApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list()
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('GET /system/disk_image_webhooks and returns the disk_image_webhooks array', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ disk_image_webhooks: [WEBHOOK_A, WEBHOOK_B] }),
      );

      const result = await diskImageWebhooksApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/disk_image_webhooks');
      expect(result).toHaveLength(2);
      expect(result[0]).toEqual(WEBHOOK_A);
      expect(result[1]).toEqual(WEBHOOK_B);
    });

    it('returns an empty array when disk_image_webhooks key is absent from the payload', async () => {
      mockGet.mockResolvedValueOnce(envelope({}));

      const result = await diskImageWebhooksApi.list();

      expect(result).toEqual([]);
    });

    it('returns an empty array when disk_image_webhooks is explicitly null/undefined', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ disk_image_webhooks: null }),
      );

      const result = await diskImageWebhooksApi.list();

      expect(result).toEqual([]);
    });

    it('returns a single-element array when only one webhook is present', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ disk_image_webhooks: [WEBHOOK_A] }),
      );

      const result = await diskImageWebhooksApi.list();

      expect(result).toHaveLength(1);
      expect(result[0]).toEqual(WEBHOOK_A);
    });

    it('propagates API errors to the caller', async () => {
      const apiError = new Error('Network error');
      mockGet.mockRejectedValueOnce(apiError);

      await expect(diskImageWebhooksApi.list()).rejects.toThrow('Network error');
    });
  });

  // ---------------------------------------------------------------------------
  // get(id)
  // ---------------------------------------------------------------------------

  describe('get(id)', () => {
    it('GET /system/disk_image_webhooks/:id and returns the disk_image_webhook', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ disk_image_webhook: WEBHOOK_A }),
      );

      const result = await diskImageWebhooksApi.get('wh-aaa');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/disk_image_webhooks/wh-aaa');
      expect(result).toEqual(WEBHOOK_A);
    });

    it('interpolates the id correctly into the URL', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ disk_image_webhook: WEBHOOK_B }),
      );

      await diskImageWebhooksApi.get('wh-bbb');

      expect(mockGet).toHaveBeenCalledWith('/system/disk_image_webhooks/wh-bbb');
    });

    it('returns the full webhook record including secret_preview', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ disk_image_webhook: WEBHOOK_A }),
      );

      const result = await diskImageWebhooksApi.get('wh-aaa');

      // Full plaintext secret is NOT available via get() — only secret_preview
      expect(result.secret_preview).toBe('abcd1234');
      expect(result.label).toBe('my-ci-repo');
      expect(result.status).toBe('active');
    });

    it('propagates API errors to the caller', async () => {
      mockGet.mockRejectedValueOnce(new Error('Not found'));

      await expect(diskImageWebhooksApi.get('nonexistent')).rejects.toThrow('Not found');
    });
  });

  // ---------------------------------------------------------------------------
  // create(label)
  // ---------------------------------------------------------------------------

  describe('create(label)', () => {
    it('POST /system/disk_image_webhooks with label and returns the created response', async () => {
      mockPost.mockResolvedValueOnce(envelope(CREATED_RESPONSE));

      const result = await diskImageWebhooksApi.create('my-ci-repo');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith('/system/disk_image_webhooks', {
        label: 'my-ci-repo',
      });
      expect(result).toEqual(CREATED_RESPONSE);
    });

    it('returns the secret_plaintext in the response (shown EXACTLY ONCE)', async () => {
      mockPost.mockResolvedValueOnce(envelope(CREATED_RESPONSE));

      const result = await diskImageWebhooksApi.create('my-ci-repo');

      expect(result.secret_plaintext).toBe('supersecretplaintextvalue123456');
      expect(result.disk_image_webhook).toEqual(WEBHOOK_A);
      expect(result.webhook_url).toBe('https://powernode.example.com/api/v1/system/webhooks/disk_image/built/wh-aaa');
      expect(result.note).toBeTruthy();
    });

    it('sends only the label in the POST body (no extra fields)', async () => {
      mockPost.mockResolvedValueOnce(envelope(CREATED_RESPONSE));

      await diskImageWebhooksApi.create('backup-ci-repo');

      expect(mockPost).toHaveBeenCalledWith('/system/disk_image_webhooks', {
        label: 'backup-ci-repo',
      });
      // Verify no extraneous keys are sent
      const [, body] = mockPost.mock.calls[0] as [string, Record<string, unknown>];
      expect(Object.keys(body)).toEqual(['label']);
    });

    it('propagates API errors to the caller', async () => {
      mockPost.mockRejectedValueOnce(new Error('Validation failed'));

      await expect(diskImageWebhooksApi.create('bad-label')).rejects.toThrow('Validation failed');
    });
  });

  // ---------------------------------------------------------------------------
  // destroy(id)
  // ---------------------------------------------------------------------------

  describe('rotateSecret(id) gating', () => {
    it('passes the pending-approval envelope through instead of a secret', async () => {
      // CHARACTERIZATION, not a regression test — say so honestly. At runtime
      // this already passed the envelope through, because extractData returns
      // the body when there is no nested data key. What was broken was the
      // declared TYPE: rotateSecret claimed a created-response unconditionally,
      // so the component could hand the envelope to the one-time secret modal
      // with no compile error and crash on the absent webhook. The fix that
      // bites is the union return type plus the caller's branch; this example
      // pins the passthrough so a future `pick` cannot quietly swallow it.
      const pending = {
        pending: true,
        deferred_operation_id: 'def-op-7',
        action_category: 'system.disk_image_webhook_rotate_secret',
        approval_request_id: 'appr-7',
        message: 'Rotation parked awaiting approval.',
      };
      mockPost.mockResolvedValueOnce({ data: { success: true, data: pending } });

      const result = await diskImageWebhooksApi.rotateSecret('wh-aaa');

      expect(result).toEqual(pending);
      expect((result as { secret_plaintext?: string }).secret_plaintext).toBeUndefined();
    });
  });

  describe('destroy(id)', () => {
    it('DELETE /system/disk_image_webhooks/:id', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await diskImageWebhooksApi.destroy('wh-aaa');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith('/system/disk_image_webhooks/wh-aaa');
    });

    it('interpolates the id correctly into the DELETE URL', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await diskImageWebhooksApi.destroy('wh-bbb');

      expect(mockDelete).toHaveBeenCalledWith('/system/disk_image_webhooks/wh-bbb');
    });

    it('resolves to a deleted marker on the applied branch', async () => {
      // Was `undefined`. destroy is GATED, so it now reports WHICH branch the
      // server took; a caller cannot distinguish "revoked" from "parked
      // awaiting approval" if the body is discarded (IMP-50d629fafd45).
      // The shape the controller actually renders on the applied branch:
      // render_success(message: "Webhook revoked"). extractGated discards that
      // payload and substitutes the marker, which is what `Deleted` is for.
      mockDelete.mockResolvedValueOnce({
        data: { success: true, data: { message: 'Webhook revoked' } },
      });

      const result = await diskImageWebhooksApi.destroy('wh-aaa');

      expect(result).toEqual({ deleted: true });
    });

    it('passes the pending-approval envelope through instead of claiming success', async () => {
      const pending = {
        pending: true,
        deferred_operation_id: 'def-op-9',
        action_category: 'system.disk_image_webhook_revoke',
        approval_request_id: 'appr-9',
        message: 'Revoke parked awaiting approval.',
      };
      mockDelete.mockResolvedValueOnce({ data: { success: true, data: pending } });

      const result = await diskImageWebhooksApi.destroy('wh-aaa');

      expect(result).toEqual(pending);
    });

    it('propagates API errors to the caller', async () => {
      mockDelete.mockRejectedValueOnce(new Error('Forbidden'));

      await expect(diskImageWebhooksApi.destroy('wh-aaa')).rejects.toThrow('Forbidden');
    });
  });

  // ---------------------------------------------------------------------------
  // rotateSecret(id)
  // ---------------------------------------------------------------------------

  describe('rotateSecret(id)', () => {
    it('POST /system/disk_image_webhooks/:id/rotate_secret with empty body', async () => {
      mockPost.mockResolvedValueOnce(envelope(ROTATED_RESPONSE));

      const result = await diskImageWebhooksApi.rotateSecret('wh-aaa');

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith(
        '/system/disk_image_webhooks/wh-aaa/rotate_secret',
        {},
      );
      expect(result).toEqual(ROTATED_RESPONSE);
    });

    it('returns the new secret_plaintext in the rotate response (old secret immediately revoked)', async () => {
      mockPost.mockResolvedValueOnce(envelope(ROTATED_RESPONSE));

      const result = await diskImageWebhooksApi.rotateSecret('wh-aaa');

      expect(result.secret_plaintext).toBe('rotated_plaintext_secret_value789');
      expect(result.disk_image_webhook.id).toBe('wh-aaa');
      expect(result.webhook_url).toBe('https://powernode.example.com/api/v1/system/webhooks/disk_image/built/wh-aaa');
      expect(result.note).toBeTruthy();
    });

    it('interpolates the id correctly into the rotate URL', async () => {
      mockPost.mockResolvedValueOnce(envelope(ROTATED_RESPONSE));

      await diskImageWebhooksApi.rotateSecret('wh-bbb');

      expect(mockPost).toHaveBeenCalledWith(
        '/system/disk_image_webhooks/wh-bbb/rotate_secret',
        {},
      );
    });

    it('sends an empty body on rotate (no extra fields)', async () => {
      mockPost.mockResolvedValueOnce(envelope(ROTATED_RESPONSE));

      await diskImageWebhooksApi.rotateSecret('wh-aaa');

      const [, body] = mockPost.mock.calls[0] as [string, Record<string, unknown>];
      expect(body).toEqual({});
    });

    it('propagates API errors to the caller', async () => {
      mockPost.mockRejectedValueOnce(new Error('Webhook not found'));

      await expect(diskImageWebhooksApi.rotateSecret('nonexistent')).rejects.toThrow(
        'Webhook not found',
      );
    });
  });

  // ── Fixture / server agreement ────────────────────────────────────────────
  //
  // The serializer derives webhook_url_path from the webhook's OWN id
  // (`.../built/#{@webhook.id}`), so a fixture whose path names a different id
  // than its `id` field is describing a response the server cannot produce.
  // Both fixtures here did exactly that — wh-aaa carried `.../abcdef` — on top
  // of using a path shape that matches no route.
  //
  // The prefix itself is pinned against the serializer in
  // diskImageWebhookPath.contract.test.ts; this pins the tail.
  describe('fixture integrity', () => {
    it.each([
      ['WEBHOOK_A', WEBHOOK_A],
      ['WEBHOOK_B', WEBHOOK_B],
    ])('%s derives its webhook_url_path from its own id', (_name, webhook) => {
      expect(webhook.webhook_url_path).toMatch(new RegExp(`/${webhook.id}$`));
    });

    it.each([
      ['CREATED_RESPONSE', CREATED_RESPONSE],
      ['ROTATED_RESPONSE', ROTATED_RESPONSE],
    ])('%s builds its absolute URL from its own webhook_url_path', (_name, res) => {
      // Both, not just the created one. Rotating changes the secret, not the
      // path, so the rotated response must carry the same URL — and until
      // IMP-b5b9544fc993 it carried a fabricated one, which is exactly the
      // value an untied fixture will drift back to.
      expect(res.webhook_url).toMatch(
        new RegExp(`${res.disk_image_webhook.webhook_url_path}$`),
      );
    });
  });
});
