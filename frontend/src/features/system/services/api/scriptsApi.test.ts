import { scriptsApi } from './scriptsApi';
import type { ScriptCreate } from './scriptsApi';
import type { SystemNodeScript } from '../../types/system.types';

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

/**
 * Build a double-envelope AxiosResponse-like object matching the backend shape:
 *   { data: { success: true, data: <payload> } }
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const SCRIPT_A: SystemNodeScript = {
  id: 'script-a',
  name: 'build-base',
  description: 'Base build script',
  variety: 'build',
  data: '#!/bin/bash\necho hello',
  enabled: true,
  public: false,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const SCRIPT_B: SystemNodeScript = {
  id: 'script-b',
  name: 'init-nginx',
  description: 'Init script for nginx',
  variety: 'init',
  data: '#!/bin/bash\nnginx -g "daemon off;"',
  enabled: false,
  public: true,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-02T00:00:00Z',
};

const CREATE_PAYLOAD: ScriptCreate = {
  name: 'sync-assets',
  description: 'Sync static assets',
  variety: 'sync',
  data: '#!/bin/bash\nrsync -av /src /dst',
  enabled: true,
  public: false,
};

// =============================================================================
// Tests
// =============================================================================

describe('scriptsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // getScripts
  // ---------------------------------------------------------------------------

  describe('getScripts', () => {
    it('calls GET /system/node_scripts and returns the node_scripts array', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ node_scripts: [SCRIPT_A, SCRIPT_B] })
      );

      const result = await scriptsApi.getScripts();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/node_scripts');
      expect(result).toEqual([SCRIPT_A, SCRIPT_B]);
    });

    it('returns an empty array when node_scripts is missing from the payload', async () => {
      mockGet.mockResolvedValueOnce(envelope({}));

      const result = await scriptsApi.getScripts();

      expect(result).toEqual([]);
    });

    it('returns an empty array when node_scripts is null', async () => {
      mockGet.mockResolvedValueOnce(envelope({ node_scripts: null }));

      const result = await scriptsApi.getScripts();

      expect(result).toEqual([]);
    });

    it('returns an empty array when the list is empty', async () => {
      mockGet.mockResolvedValueOnce(envelope({ node_scripts: [] }));

      const result = await scriptsApi.getScripts();

      expect(result).toEqual([]);
    });

    it('propagates a network error thrown by apiClient', async () => {
      const networkError = new Error('Network Error');
      mockGet.mockRejectedValueOnce(networkError);

      await expect(scriptsApi.getScripts()).rejects.toThrow('Network Error');
      expect(mockGet).toHaveBeenCalledWith('/system/node_scripts');
    });
  });

  // ---------------------------------------------------------------------------
  // getScript
  // ---------------------------------------------------------------------------

  describe('getScript', () => {
    it('calls GET /system/node_scripts/:id and returns the node_script', async () => {
      mockGet.mockResolvedValueOnce(envelope({ node_script: SCRIPT_A }));

      const result = await scriptsApi.getScript('script-a');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/node_scripts/script-a');
      expect(result).toEqual(SCRIPT_A);
    });

    it('interpolates the id correctly into the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ node_script: SCRIPT_B }));

      await scriptsApi.getScript('script-b');

      expect(mockGet).toHaveBeenCalledWith('/system/node_scripts/script-b');
    });

    it('returns the full node_script object including optional fields', async () => {
      mockGet.mockResolvedValueOnce(envelope({ node_script: SCRIPT_A }));

      const result = await scriptsApi.getScript('script-a');

      expect(result.id).toBe('script-a');
      expect(result.name).toBe('build-base');
      expect(result.variety).toBe('build');
      expect(result.enabled).toBe(true);
      expect(result.data).toBe('#!/bin/bash\necho hello');
    });

    it('propagates a 404 error thrown by apiClient', async () => {
      const notFoundError = new Error('Request failed with status code 404');
      mockGet.mockRejectedValueOnce(notFoundError);

      await expect(scriptsApi.getScript('nonexistent')).rejects.toThrow(
        'Request failed with status code 404'
      );
    });
  });

  // ---------------------------------------------------------------------------
  // createScript
  // ---------------------------------------------------------------------------

  describe('createScript', () => {
    it('calls POST /system/node_scripts with node_script wrapper and returns created script', async () => {
      mockPost.mockResolvedValueOnce(envelope({ node_script: SCRIPT_A }));

      const result = await scriptsApi.createScript(CREATE_PAYLOAD);

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith('/system/node_scripts', {
        node_script: CREATE_PAYLOAD,
      });
      expect(result).toEqual(SCRIPT_A);
    });

    it('wraps the payload in a node_script key', async () => {
      mockPost.mockResolvedValueOnce(envelope({ node_script: SCRIPT_B }));

      await scriptsApi.createScript(CREATE_PAYLOAD);

      const [, body] = mockPost.mock.calls[0] as [string, unknown];
      expect(body).toEqual({ node_script: CREATE_PAYLOAD });
    });

    it('handles a minimal required-only payload (name + variety)', async () => {
      const minimalPayload: ScriptCreate = { name: 'minimal', variety: 'custom' };
      const createdScript: SystemNodeScript = {
        id: 'script-min',
        name: 'minimal',
        variety: 'custom',
        enabled: false,
        public: false,
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockPost.mockResolvedValueOnce(envelope({ node_script: createdScript }));

      const result = await scriptsApi.createScript(minimalPayload);

      expect(mockPost).toHaveBeenCalledWith('/system/node_scripts', {
        node_script: minimalPayload,
      });
      expect(result).toEqual(createdScript);
    });

    it('accepts all four variety values', async () => {
      const varieties: ScriptCreate['variety'][] = ['build', 'init', 'sync', 'custom'];

      for (const variety of varieties) {
        const payload: ScriptCreate = { name: `${variety}-script`, variety };
        const created: SystemNodeScript = {
          id: `${variety}-id`,
          name: `${variety}-script`,
          variety,
          enabled: false,
          public: false,
          created_at: '2026-01-01T00:00:00Z',
          updated_at: '2026-01-01T00:00:00Z',
        };
        mockPost.mockResolvedValueOnce(envelope({ node_script: created }));

        const result = await scriptsApi.createScript(payload);

        expect(result.variety).toBe(variety);
      }
    });

    it('propagates an API error thrown by apiClient', async () => {
      const apiError = new Error('Unprocessable Entity');
      mockPost.mockRejectedValueOnce(apiError);

      await expect(scriptsApi.createScript(CREATE_PAYLOAD)).rejects.toThrow(
        'Unprocessable Entity'
      );
    });
  });

  // ---------------------------------------------------------------------------
  // updateScript
  // ---------------------------------------------------------------------------

  describe('updateScript', () => {
    it('calls PUT /system/node_scripts/:id with node_script wrapper and returns updated script', async () => {
      const updates: Partial<ScriptCreate> = { name: 'build-base-v2', enabled: false };
      const updated: SystemNodeScript = { ...SCRIPT_A, name: 'build-base-v2', enabled: false };
      mockPut.mockResolvedValueOnce(envelope({ node_script: updated }));

      const result = await scriptsApi.updateScript('script-a', updates);

      expect(mockPut).toHaveBeenCalledTimes(1);
      expect(mockPut).toHaveBeenCalledWith('/system/node_scripts/script-a', {
        node_script: updates,
      });
      expect(result).toEqual(updated);
    });

    it('interpolates the id correctly into the URL for PUT', async () => {
      const updates: Partial<ScriptCreate> = { enabled: true };
      const updated: SystemNodeScript = { ...SCRIPT_B, enabled: true };
      mockPut.mockResolvedValueOnce(envelope({ node_script: updated }));

      await scriptsApi.updateScript('script-b', updates);

      expect(mockPut).toHaveBeenCalledWith('/system/node_scripts/script-b', {
        node_script: updates,
      });
    });

    it('wraps the partial payload in a node_script key', async () => {
      const updates: Partial<ScriptCreate> = { description: 'updated description' };
      mockPut.mockResolvedValueOnce(envelope({ node_script: SCRIPT_A }));

      await scriptsApi.updateScript('script-a', updates);

      const [, body] = mockPut.mock.calls[0] as [string, unknown];
      expect(body).toEqual({ node_script: updates });
    });

    it('accepts an empty partial update (no fields changed)', async () => {
      const updates: Partial<ScriptCreate> = {};
      mockPut.mockResolvedValueOnce(envelope({ node_script: SCRIPT_A }));

      const result = await scriptsApi.updateScript('script-a', updates);

      expect(mockPut).toHaveBeenCalledWith('/system/node_scripts/script-a', {
        node_script: {},
      });
      expect(result).toEqual(SCRIPT_A);
    });

    it('allows updating the variety field', async () => {
      const updates: Partial<ScriptCreate> = { variety: 'custom' };
      const updated: SystemNodeScript = { ...SCRIPT_A, variety: 'custom' };
      mockPut.mockResolvedValueOnce(envelope({ node_script: updated }));

      const result = await scriptsApi.updateScript('script-a', updates);

      expect(result.variety).toBe('custom');
    });

    it('allows updating only the data field', async () => {
      const updates: Partial<ScriptCreate> = { data: '#!/bin/bash\nnewscript' };
      const updated: SystemNodeScript = { ...SCRIPT_A, data: '#!/bin/bash\nnewscript' };
      mockPut.mockResolvedValueOnce(envelope({ node_script: updated }));

      const result = await scriptsApi.updateScript('script-a', updates);

      expect(result.data).toBe('#!/bin/bash\nnewscript');
    });

    it('propagates a 404 error thrown by apiClient', async () => {
      mockPut.mockRejectedValueOnce(new Error('Request failed with status code 404'));

      await expect(
        scriptsApi.updateScript('nonexistent', { name: 'x' })
      ).rejects.toThrow('Request failed with status code 404');
    });
  });

  // ---------------------------------------------------------------------------
  // deleteScript
  // ---------------------------------------------------------------------------

  describe('deleteScript', () => {
    it('calls DELETE /system/node_scripts/:id', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await scriptsApi.deleteScript('script-a');

      expect(mockDelete).toHaveBeenCalledTimes(1);
      expect(mockDelete).toHaveBeenCalledWith('/system/node_scripts/script-a');
    });

    it('interpolates the id correctly into the DELETE URL', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await scriptsApi.deleteScript('script-b');

      expect(mockDelete).toHaveBeenCalledWith('/system/node_scripts/script-b');
    });

    it('resolves to undefined (void) on success', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      const result = await scriptsApi.deleteScript('script-a');

      expect(result).toBeUndefined();
    });

    it('does not call get, post, or put when deleting', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });

      await scriptsApi.deleteScript('script-a');

      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
    });

    it('propagates an error thrown by apiClient', async () => {
      const deleteError = new Error('Request failed with status code 403');
      mockDelete.mockRejectedValueOnce(deleteError);

      await expect(scriptsApi.deleteScript('script-a')).rejects.toThrow(
        'Request failed with status code 403'
      );
    });
  });

  // ---------------------------------------------------------------------------
  // URL isolation — each method only calls its own HTTP verb
  // ---------------------------------------------------------------------------

  describe('HTTP verb isolation', () => {
    it('getScripts only calls GET', async () => {
      mockGet.mockResolvedValueOnce(envelope({ node_scripts: [] }));
      await scriptsApi.getScripts();
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });

    it('getScript only calls GET', async () => {
      mockGet.mockResolvedValueOnce(envelope({ node_script: SCRIPT_A }));
      await scriptsApi.getScript('script-a');
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });

    it('createScript only calls POST', async () => {
      mockPost.mockResolvedValueOnce(envelope({ node_script: SCRIPT_A }));
      await scriptsApi.createScript(CREATE_PAYLOAD);
      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });

    it('updateScript only calls PUT', async () => {
      mockPut.mockResolvedValueOnce(envelope({ node_script: SCRIPT_A }));
      await scriptsApi.updateScript('script-a', { name: 'x' });
      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });

    it('deleteScript only calls DELETE', async () => {
      mockDelete.mockResolvedValueOnce({ data: { success: true } });
      await scriptsApi.deleteScript('script-a');
      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
    });
  });
});
