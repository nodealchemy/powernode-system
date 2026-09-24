import { apiClient } from '@/shared/services/apiClient';
import type {
  ProviderCredentialTestRequest,
  ProviderCredentialTestResult,
} from '@/shared/services/featureRegistry';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type { SystemProviderCredential } from '../../types/system.types';

/**
 * Stored cloud credentials (BYOC). The only client of this route: the
 * extension's own screens call it directly, and core's setup wizard reaches it
 * through the cloud handlers register.ts registers.
 *
 * #index returns metadata and provider context only; the encrypted values are
 * never serialised, which is what makes listing them safe.
 */
const BASE = '/system/provider_credentials';

export const providerCredentialsApi = {
  list: async (): Promise<SystemProviderCredential[]> => {
    const response = await apiClient.get<
      ApiEnvelope<{ provider_credentials: SystemProviderCredential[] }>
    >(BASE);
    return extractData(response).provider_credentials ?? [];
  },

  /**
   * Deactivates rather than erases: the server flips is_active so the audit of
   * which credential provisioned which instance survives. The row keeps
   * existing and #index keeps returning it, so a caller has to decide what to
   * show — and #destroy is not the only writer of that column, since a
   * credential also deactivates itself after six consecutive failures.
   */
  destroy: async (id: string): Promise<void> => {
    await apiClient.delete<ApiEnvelope<unknown>>(`${BASE}/${id}`);
  },

  /**
   * Stores a credential. `providerId` is a provider's UUID, or its type slug
   * when no provider row exists yet: the server then creates the provider.
   * Resolves to the new credential's id.
   */
  create: async ({
    providerId,
    providerType,
    credentials,
  }: {
    providerId: string;
    providerType: string;
    credentials: Record<string, string>;
  }): Promise<string | null> => {
    const response = await apiClient.post<
      ApiEnvelope<{ provider_credential?: SystemProviderCredential }>
    >(BASE, { provider_id: providerId, provider_type: providerType, credentials });
    return extractData(response).provider_credential?.id ?? null;
  },

  /** Tests credentials without storing them; always a verdict, never a throw on rejection. */
  test: async ({
    providerId,
    providerType,
    category,
    credentials,
  }: ProviderCredentialTestRequest): Promise<ProviderCredentialTestResult> => {
    const response = await apiClient.post<ApiEnvelope<ProviderCredentialTestResult>>(`${BASE}/test`, {
      provider_id: providerId,
      provider_type: providerType,
      provider_category: category,
      credentials,
    });
    return extractData(response);
  },
};
