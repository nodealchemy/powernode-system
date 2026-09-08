import React, { useCallback, useEffect, useState } from 'react';
import { KeyRound, Trash2 } from 'lucide-react';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { logger } from '@/shared/utils/logger';
import { apiErrorMessage } from '@system/features/system/services/api/helpers';
import { providerCredentialsApi } from '@system/features/system/services/api/providerCredentialsApi';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import type { SystemProviderCredential } from '@system/features/system/types/system.types';

interface ProviderCredentialsPanelProps {
  /** Bumped by the parent after a write that may have stored a credential. */
  refreshKey?: number;
}

/**
 * Configured cloud credentials, listed on the screen that creates them.
 *
 * Before this panel the store was one-way: ProviderFormModal and the core
 * onboarding wizard could POST a credential, and nothing in either frontend
 * tree issued the GET or the DELETE. An operator who typed a secret wrong, or
 * who needed to revoke one after a key rotation, had no way back — the
 * controller's own header said #index existed so a "configured" state could be
 * rendered without leaking secrets, and no caller had ever been written.
 *
 * Inactive credentials are LISTED, not filtered out. Removing one flips
 * is_active rather than erasing it, so the audit of which credential
 * provisioned which instance survives — but #destroy is not the only writer of
 * that column: System::ProviderCredential#record_failure! deactivates a
 * credential after six consecutive failures. Filtering to active rows would
 * make exactly that credential invisible on the one screen meant to explain
 * why provisioning stopped working, which is the same one-way shape this panel
 * exists to close. They are shown dimmed and marked instead.
 *
 * `last_error` is serialised by the controller and deliberately NOT rendered:
 * it carries a raw provider-SDK auth error, which is the one field on this
 * record that could echo something an operator typed.
 */
export const ProviderCredentialsPanel: React.FC<ProviderCredentialsPanelProps> = ({
  refreshKey = 0,
}) => {
  const { hasPermission } = usePermissions();
  const canRead = hasPermission('system.providers.read');
  const canDelete = hasPermission('system.providers.delete');
  const { addNotification } = useNotifications();
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [credentials, setCredentials] = useState<SystemProviderCredential[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);

  const fetchCredentials = useCallback(async () => {
    if (!canRead) {
      setLoading(false);
      return;
    }
    // `loading` is the initial-load flag: the container replaces the whole list
    // with a spinner for it. A refetch keeps the rows on screen instead.
    setCredentials((current) => {
      if (current.length > 0) setRefreshing(true);
      else setLoading(true);
      return current;
    });
    setError(null);
    try {
      setCredentials(await providerCredentialsApi.list());
    } catch (err) {
      logger.error('ProviderCredentialsPanel: failed to load credentials', err);
      setError(apiErrorMessage(err, 'Failed to load stored credentials'));
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [canRead]);

  useEffect(() => {
    void fetchCredentials();
  }, [fetchCredentials, refreshKey]);

  const handleDelete = (credential: SystemProviderCredential) => {
    const label = credentialLabel(credential);
    confirm({
      title: 'Remove stored credential',
      message: `Remove ${label}? Anything still provisioning against it will start failing to authenticate. The credential itself is not recoverable from here — it would have to be entered again.`,
      confirmLabel: 'Remove credential',
      variant: 'danger',
      onConfirm: async () => {
        setDeletingId(credential.id);
        try {
          await providerCredentialsApi.destroy(credential.id);
          addNotification({ type: 'success', message: `Removed ${label}` });
          await fetchCredentials();
        } catch (err) {
          logger.error('ProviderCredentialsPanel: failed to remove credential', err, {
            credentialId: credential.id,
          });
          addNotification({
            type: 'error',
            message: apiErrorMessage(err, 'Failed to remove credential'),
          });
        } finally {
          setDeletingId(null);
        }
      },
    });
  };

  // A reader without system.providers.read would get a 403 from #index, so the
  // panel is not rendered at all rather than showing a failed request.
  if (!canRead) return null;

  return (
    <div className="mt-8">
      <header className="mb-3">
        <h3 className="text-sm font-medium text-theme-primary flex items-center gap-2">
          <KeyRound className="w-4 h-4" />
          Configured credentials
        </h3>
        <p className="text-xs text-theme-secondary mt-1">
          Stored cloud credentials for this account. The server never returns the
          secret itself, so a credential is identified here by its name and provider.
        </p>
      </header>

      {error && <ErrorAlert message={error} onClose={() => setError(null)} />}

      <ResponsiveListContainer
        loading={loading}
        refreshing={refreshing}
        totalCount={credentials.length}
        filteredCount={credentials.length}
        onRefresh={() => void fetchCredentials()}
        emptyState={{
          icon: KeyRound,
          title: 'No stored credentials',
          description:
            'Credentials saved from a provider form appear here, where they can be removed.',
        }}
      >
        <ResponsiveListContainer.Body>
          <table className="w-full text-sm">
            <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
              <tr>
                <th className="text-left px-4 py-2 font-medium">Credential</th>
                <th className="text-left px-4 py-2 font-medium">Provider</th>
                <th className="text-left px-4 py-2 font-medium">State</th>
                <th className="text-right px-4 py-2 font-medium">Actions</th>
              </tr>
            </thead>
            <tbody>
              {credentials.map((credential) => (
                <tr
                  key={credential.id}
                  className={`border-t border-theme ${credential.is_active ? '' : 'opacity-60'}`}
                >
                  <td className="px-4 py-3 text-theme-primary">
                    {credential.name || 'Unnamed credential'}
                  </td>
                  <td className="px-4 py-3 text-theme-secondary">
                    {credential.provider_name || credential.provider_type || '—'}
                  </td>
                  <td className="px-4 py-3 text-theme-secondary">
                    {credential.is_active ? 'Active' : 'Deactivated'}
                  </td>
                  <td className="px-4 py-3 text-right">
                    {/* Nothing to remove on a row that is already deactivated —
                        #destroy would flip a column that is already false. */}
                    {canDelete && credential.is_active && (
                      <button
                        type="button"
                        onClick={() => handleDelete(credential)}
                        disabled={deletingId === credential.id}
                        aria-label={`Remove ${credentialLabel(credential)}`}
                        className="p-1 text-theme-secondary hover:text-theme-danger-fg disabled:opacity-50"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </ResponsiveListContainer.Body>
      </ResponsiveListContainer>

      {ConfirmationDialog}
    </div>
  );
};

/** What the operator sees this credential called, in a notice or a label. */
function credentialLabel(credential: SystemProviderCredential): string {
  const name = credential.name || 'Unnamed credential';
  const provider = credential.provider_name || credential.provider_type;
  return provider ? `${name} (${provider})` : name;
}

export default ProviderCredentialsPanel;
