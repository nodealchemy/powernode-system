// Behavioral tests for the platformDeploymentsApi client.
//
// Verifies the exact URLs, HTTP methods, and payload shapes used by each
// exported function as well as the double-envelope unwrapping that
// `extractData` performs on the raw AxiosResponse.

import { platformDeploymentsApi } from './platformDeploymentsApi';
import type { DeploymentSummary, DeploymentUpdateRequest } from '../../types/deployment.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockPatch = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const DEPLOYMENT_A: DeploymentSummary = {
  id: 'dep-a',
  name: 'api-primary',
  service_role: 'api',
  target_replicas: 3,
  actual_replicas: 3,
  actual_by_status: { running: 3 },
  cordoned_count: 0,
  public_dns_hostname: 'api.example.com',
  satellite_extension_slug: null,
  node_template: { id: 'tpl-1', name: 'ubuntu-base', slug: 'ubuntu-base' },
  virtual_ip: { id: 'vip-1', cidr: '10.0.0.1/32', preferred_endpoint: '10.0.0.1' },
  metadata: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const DEPLOYMENT_B: DeploymentSummary = {
  id: 'dep-b',
  name: 'worker-fleet',
  service_role: 'worker',
  target_replicas: 5,
  actual_replicas: 4,
  actual_by_status: { running: 4 },
  cordoned_count: 0,
  public_dns_hostname: null,
  satellite_extension_slug: null,
  node_template: null,
  virtual_ip: null,
  metadata: { region: 'us-east-1' },
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-02T00:00:00Z',
};

// Mirrors the canonical double-envelope: AxiosResponse.data = { success, data: <payload> }
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Tests
// =============================================================================

describe('platformDeploymentsApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockPatch.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // list()
  // ---------------------------------------------------------------------------

  describe('list()', () => {
    it('calls GET /system/platform/deployments with no arguments', async () => {
      mockGet.mockResolvedValue(
        envelope({ deployments: [DEPLOYMENT_A, DEPLOYMENT_B], count: 2 }),
      );

      await platformDeploymentsApi.list();

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/platform/deployments');
    });

    it('returns the unwrapped DeploymentListResponse on success', async () => {
      mockGet.mockResolvedValue(
        envelope({ deployments: [DEPLOYMENT_A, DEPLOYMENT_B], count: 2 }),
      );

      const result = await platformDeploymentsApi.list();

      expect(result.deployments).toHaveLength(2);
      expect(result.count).toBe(2);
      expect(result.deployments[0]).toMatchObject({ id: 'dep-a', name: 'api-primary' });
      expect(result.deployments[1]).toMatchObject({ id: 'dep-b', name: 'worker-fleet' });
    });

    it('returns an empty deployments array when the backend returns count 0', async () => {
      mockGet.mockResolvedValue(
        envelope({ deployments: [], count: 0 }),
      );

      const result = await platformDeploymentsApi.list();

      expect(result.deployments).toHaveLength(0);
      expect(result.count).toBe(0);
    });

    it('propagates a rejected promise when apiClient.get rejects', async () => {
      const networkError = new Error('Network Error');
      mockGet.mockRejectedValue(networkError);

      await expect(platformDeploymentsApi.list()).rejects.toThrow('Network Error');
    });
  });

  // ---------------------------------------------------------------------------
  // get(id)
  // ---------------------------------------------------------------------------

  describe('get(id)', () => {
    it('calls GET /system/platform/deployments/:id with the correct id', async () => {
      mockGet.mockResolvedValue(
        envelope({ deployment: DEPLOYMENT_A }),
      );

      await platformDeploymentsApi.get('dep-a');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/system/platform/deployments/dep-a');
    });

    it('returns the unwrapped DeploymentSummary (extracts .deployment from data)', async () => {
      mockGet.mockResolvedValue(
        envelope({ deployment: DEPLOYMENT_A }),
      );

      const result = await platformDeploymentsApi.get('dep-a');

      expect(result).toMatchObject({
        id: 'dep-a',
        name: 'api-primary',
        service_role: 'api',
        target_replicas: 3,
        actual_replicas: 3,
        public_dns_hostname: 'api.example.com',
      });
    });

    it('correctly resolves deployments with null optional fields', async () => {
      mockGet.mockResolvedValue(
        envelope({ deployment: DEPLOYMENT_B }),
      );

      const result = await platformDeploymentsApi.get('dep-b');

      expect(result.public_dns_hostname).toBeNull();
      expect(result.satellite_extension_slug).toBeNull();
      expect(result.node_template).toBeNull();
      expect(result.virtual_ip).toBeNull();
    });

    it('uses the id verbatim in the URL path', async () => {
      mockGet.mockResolvedValue(
        envelope({ deployment: DEPLOYMENT_B }),
      );

      await platformDeploymentsApi.get('dep-b');

      expect(mockGet).toHaveBeenCalledWith('/system/platform/deployments/dep-b');
    });

    it('propagates a rejected promise when apiClient.get rejects', async () => {
      mockGet.mockRejectedValue(new Error('Not Found'));

      await expect(platformDeploymentsApi.get('nonexistent')).rejects.toThrow('Not Found');
    });
  });

  // ---------------------------------------------------------------------------
  // update(id, patch)
  // ---------------------------------------------------------------------------

  describe('update(id, patch)', () => {
    it('calls PATCH /system/platform/deployments/:id with the patch body', async () => {
      const patch: DeploymentUpdateRequest = { target_replicas: 5 };
      mockPatch.mockResolvedValue(
        envelope({ deployment: { ...DEPLOYMENT_A, target_replicas: 5 } }),
      );

      await platformDeploymentsApi.update('dep-a', patch);

      expect(mockPatch).toHaveBeenCalledTimes(1);
      expect(mockPatch).toHaveBeenCalledWith('/system/platform/deployments/dep-a', {
        target_replicas: 5,
      });
    });

    // IMP-f4fe1ed1ec1e: update() returns the WHOLE envelope, not the flattened
    // row. A target_replicas patch now drives System::Platform::ReplicaReconciler
    // server-side and the outcome rides back alongside the row under
    // `reconciled`; a caller that unwrapped to the row dropped it and reported
    // every save as a scale.
    it('returns the whole update envelope, with the row under `deployment`', async () => {
      const patch: DeploymentUpdateRequest = { target_replicas: 5 };
      const updated = { ...DEPLOYMENT_A, target_replicas: 5 };
      mockPatch.mockResolvedValue(
        envelope({ deployment: updated }),
      );

      const result = await platformDeploymentsApi.update('dep-a', patch);

      expect(result.deployment.target_replicas).toBe(5);
      expect(result.deployment.id).toBe('dep-a');
    });

    it('surfaces the reconcile outcome the PATCH returns alongside the row', async () => {
      const updated = { ...DEPLOYMENT_A, target_replicas: 5 };
      mockPatch.mockResolvedValue(
        envelope({
          deployment: updated,
          reconciled: {
            ok: false,
            refused_reason: 'insufficient_permission',
            message: 'Reconcile requires system.instances.create',
            actual_before: 2,
            actual_after: 2,
            target_replicas: 5,
            provisioned_instance_ids: [],
            terminated_instance_ids: [],
            pending_removal_instance_ids: [],
            failures: [],
          },
        }),
      );

      const result = await platformDeploymentsApi.update('dep-a', { target_replicas: 5 });

      expect(result.reconciled?.ok).toBe(false);
      expect(result.reconciled?.refused_reason).toBe('insufficient_permission');
      expect(result.reconciled?.actual_after).toBe(2);
    });

    it('sends a patch with public_dns_hostname when provided', async () => {
      const patch: DeploymentUpdateRequest = { public_dns_hostname: 'new.example.com' };
      const updated = { ...DEPLOYMENT_A, public_dns_hostname: 'new.example.com' };
      mockPatch.mockResolvedValue(
        envelope({ deployment: updated }),
      );

      const result = await platformDeploymentsApi.update('dep-a', patch);

      expect(mockPatch).toHaveBeenCalledWith('/system/platform/deployments/dep-a', {
        public_dns_hostname: 'new.example.com',
      });
      expect(result.deployment.public_dns_hostname).toBe('new.example.com');
    });

    it('sends a patch with null public_dns_hostname (to clear it)', async () => {
      const patch: DeploymentUpdateRequest = { public_dns_hostname: null };
      const updated = { ...DEPLOYMENT_A, public_dns_hostname: null };
      mockPatch.mockResolvedValue(
        envelope({ deployment: updated }),
      );

      const result = await platformDeploymentsApi.update('dep-a', patch);

      expect(mockPatch).toHaveBeenCalledWith('/system/platform/deployments/dep-a', {
        public_dns_hostname: null,
      });
      expect(result.deployment.public_dns_hostname).toBeNull();
    });

    it('sends a combined patch with both fields', async () => {
      const patch: DeploymentUpdateRequest = {
        target_replicas: 2,
        public_dns_hostname: 'minimal.example.com',
      };
      const updated = { ...DEPLOYMENT_A, target_replicas: 2, public_dns_hostname: 'minimal.example.com' };
      mockPatch.mockResolvedValue(
        envelope({ deployment: updated }),
      );

      await platformDeploymentsApi.update('dep-a', patch);

      expect(mockPatch).toHaveBeenCalledWith('/system/platform/deployments/dep-a', {
        target_replicas: 2,
        public_dns_hostname: 'minimal.example.com',
      });
    });

    it('sends an empty patch object without error', async () => {
      const patch: DeploymentUpdateRequest = {};
      mockPatch.mockResolvedValue(
        envelope({ deployment: DEPLOYMENT_A }),
      );

      const result = await platformDeploymentsApi.update('dep-a', patch);

      expect(mockPatch).toHaveBeenCalledWith('/system/platform/deployments/dep-a', {});
      expect(result.deployment.id).toBe('dep-a');
    });

    it('propagates a rejected promise when apiClient.patch rejects', async () => {
      mockPatch.mockRejectedValue(new Error('Validation failed'));

      await expect(
        platformDeploymentsApi.update('dep-a', { target_replicas: -1 }),
      ).rejects.toThrow('Validation failed');
    });

    it('uses the correct id in the URL when updating a different deployment', async () => {
      const patch: DeploymentUpdateRequest = { target_replicas: 10 };
      const updated = { ...DEPLOYMENT_B, target_replicas: 10 };
      mockPatch.mockResolvedValue(
        envelope({ deployment: updated }),
      );

      await platformDeploymentsApi.update('dep-b', patch);

      expect(mockPatch).toHaveBeenCalledWith('/system/platform/deployments/dep-b', {
        target_replicas: 10,
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Envelope contract — no other HTTP verbs are called
  // ---------------------------------------------------------------------------

  describe('HTTP method contract', () => {
    it('never calls POST, PUT, or DELETE', async () => {
      mockGet.mockResolvedValue(envelope({ deployments: [], count: 0 }));
      await platformDeploymentsApi.list();

      mockGet.mockResolvedValue(envelope({ deployment: DEPLOYMENT_A }));
      await platformDeploymentsApi.get('dep-a');

      mockPatch.mockResolvedValue(envelope({ deployment: DEPLOYMENT_A }));
      await platformDeploymentsApi.update('dep-a', {});

      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });
  });
});
