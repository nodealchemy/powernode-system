import { providerCredentialsApi } from './providerCredentialsApi';
import type { SystemProviderCredential } from '../../types/system.types';

const mockGet = jest.fn();
const mockDelete = jest.fn();
const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
    post: (...args: unknown[]) => mockPost(...args),
  },
}));

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const CREDENTIAL: SystemProviderCredential = {
  id: 'cred-1',
  provider_id: 'p-1',
  provider_name: 'AWS Prod',
  provider_type: 'aws',
  name: 'aws-root-key',
  scope: 'account_owned',
  is_active: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

describe('providerCredentialsApi', () => {
  beforeEach(() => jest.clearAllMocks());

  it('reads the collection from the route the controller declares', async () => {
    // The literal is pinned, not derived: an assertion that computed the URL
    // from the client would agree with it by construction and test nothing.
    mockGet.mockResolvedValue(envelope({ provider_credentials: [CREDENTIAL] }));

    await expect(providerCredentialsApi.list()).resolves.toEqual([CREDENTIAL]);
    expect(mockGet).toHaveBeenCalledWith('/system/provider_credentials');
  });

  it('returns an empty list when the payload omits the key', async () => {
    mockGet.mockResolvedValue(envelope({}));

    await expect(providerCredentialsApi.list()).resolves.toEqual([]);
  });

  it('deletes by id under the same collection', async () => {
    mockDelete.mockResolvedValue(envelope({}));

    await providerCredentialsApi.destroy('cred-1');

    expect(mockDelete).toHaveBeenCalledWith('/system/provider_credentials/cred-1');
  });

  it('creates a credential, resolving the provider by id or type, and returns its id', async () => {
    mockPost.mockResolvedValue(envelope({ provider_credential: CREDENTIAL }));

    await expect(
      providerCredentialsApi.create({ providerId: 'aws', providerType: 'aws', credentials: { k: 'v' } })
    ).resolves.toBe('cred-1');
    expect(mockPost).toHaveBeenCalledWith('/system/provider_credentials', {
      provider_id: 'aws',
      provider_type: 'aws',
      credentials: { k: 'v' },
    });
  });

  it('tests credentials on the test route and unwraps the verdict', async () => {
    mockPost.mockResolvedValue(envelope({ valid: false, error: 'AccessDenied' }));

    await expect(
      providerCredentialsApi.test({
        providerId: 'hetzner',
        providerType: 'hetzner',
        category: 'cloud',
        credentials: { api_token: 't' },
      })
    ).resolves.toEqual({ valid: false, error: 'AccessDenied' });
    expect(mockPost).toHaveBeenCalledWith('/system/provider_credentials/test', {
      provider_id: 'hetzner',
      provider_type: 'hetzner',
      provider_category: 'cloud',
      credentials: { api_token: 't' },
    });
  });
});
