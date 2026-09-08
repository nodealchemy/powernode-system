import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type { SystemProviderCredential } from '../../types/system.types';

/**
 * Stored cloud credentials (BYOC).
 *
 * Creation is not here: it is issued inline by ProviderFormModal and by the
 * core onboarding wizard, both of which POST this path directly. This client
 * covers the two verbs that had no caller at all — the operator could store a
 * credential and then never see it or remove it.
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
};
