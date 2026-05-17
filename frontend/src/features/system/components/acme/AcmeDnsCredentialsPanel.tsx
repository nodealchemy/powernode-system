import React, { useCallback, useEffect, useState } from 'react';
import {
  KeyRound,
  AlertTriangle,
  Plus,
  Trash2,
  X,
  Check,
  Clock,
  ShieldAlert,
  ShieldCheck,
  Globe,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { acmeDnsCredentialsApi } from '../../services/api/acmeDnsCredentialsApi';
import type {
  AcmeDnsCredentialSummary,
  AcmeDnsCredentialStatus,
  SupportedProvider,
} from '../../types/acme.types';
import { AcmeDnsCredentialModal } from './AcmeDnsCredentialModal';
import { DnsRecordsModal } from './DnsRecordsModal';

/**
 * Operator-facing list of ACME DNS credentials. Inline actions: test
 * connectivity (probes the provider's verify endpoint), delete.
 * Plaintext tokens are never shown — only status + last_validated_at.
 *
 * Plan reference: Decentralized Federation §J + P2.5.8.
 */

interface AcmeDnsCredentialsPanelProps {
  refreshKey?: number;
}

export const AcmeDnsCredentialsPanel: React.FC<AcmeDnsCredentialsPanelProps> = ({
  refreshKey = 0,
}) => {
  const [credentials, setCredentials] = useState<AcmeDnsCredentialSummary[]>([]);
  const [providers, setProviders] = useState<SupportedProvider[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [modalOpen, setModalOpen] = useState(false);
  const [testingId, setTestingId] = useState<string | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [lastTestReason, setLastTestReason] = useState<Record<string, string>>({});
  // CF-DNS.3 — DNS records modal targeted at a specific credential
  const [dnsRecordsTarget, setDnsRecordsTarget] = useState<AcmeDnsCredentialSummary | null>(null);

  const fetchCreds = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await acmeDnsCredentialsApi.list();
      setCredentials(result.credentials);
      setProviders(result.supported_providers);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load credentials');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void fetchCreds();
  }, [fetchCreds, refreshKey]);

  const handleTest = async (cred: AcmeDnsCredentialSummary) => {
    setTestingId(cred.id);
    setLastTestReason((prev) => ({ ...prev, [cred.id]: '' }));
    try {
      const result = await acmeDnsCredentialsApi.testConnectivity(cred.id);
      setLastTestReason((prev) => ({ ...prev, [cred.id]: result.reason }));
      await fetchCreds();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'Test failed';
      setLastTestReason((prev) => ({ ...prev, [cred.id]: message }));
    } finally {
      setTestingId(null);
    }
  };

  const handleDelete = async (cred: AcmeDnsCredentialSummary) => {
    const ok = window.confirm(
      `Delete credential "${cred.name}"?\n\n` +
        'The Vault-stored token will be destroyed. This is reversible only by ' +
        're-creating the credential with a fresh token. Active certificates referencing ' +
        'this credential will block the delete.',
    );
    if (!ok) return;
    setDeletingId(cred.id);
    try {
      await acmeDnsCredentialsApi.destroy(cred.id);
      await fetchCreds();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Delete failed');
    } finally {
      setDeletingId(null);
    }
  };

  return (
    <>
      <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
        <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <KeyRound className="w-5 h-5 text-theme-info" />
            <h2 className="font-semibold text-theme-primary">DNS Provider Credentials</h2>
            <span className="text-xs text-theme-secondary">
              {loading
                ? 'loading…'
                : `${credentials.length} ${credentials.length === 1 ? 'credential' : 'credentials'}`}
            </span>
          </div>
          <Button variant="primary" onClick={() => setModalOpen(true)}>
            <Plus className="w-4 h-4" />
            Add credential
          </Button>
        </header>

        {error && (
          <div className="p-3 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm">
            <AlertTriangle className="w-4 h-4 flex-shrink-0" />
            <span className="flex-1">{error}</span>
            <button type="button" onClick={() => setError(null)} className="p-1">
              <X className="w-3 h-3" />
            </button>
          </div>
        )}

        {!loading && credentials.length === 0 && !error && (
          <div className="p-12 text-center text-theme-secondary text-sm">
            No DNS credentials configured yet. Add one to enable automatic Let's Encrypt
            issuance via the DNS-01 challenge.
          </div>
        )}

        {credentials.length > 0 && (
          <table className="w-full text-sm">
            <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
              <tr>
                <th className="text-left px-4 py-2 font-medium">Name</th>
                <th className="text-left px-4 py-2 font-medium">Provider</th>
                <th className="text-left px-4 py-2 font-medium">Status</th>
                <th className="text-left px-4 py-2 font-medium">Last validated</th>
                <th className="text-right px-4 py-2 font-medium">Actions</th>
              </tr>
            </thead>
            <tbody>
              {credentials.map((cred) => (
                <CredentialRow
                  key={cred.id}
                  cred={cred}
                  lastReason={lastTestReason[cred.id] ?? null}
                  testing={testingId === cred.id}
                  deleting={deletingId === cred.id}
                  onTest={() => handleTest(cred)}
                  onDelete={() => handleDelete(cred)}
                  onManageDns={
                    cred.provider === 'cloudflare' ? () => setDnsRecordsTarget(cred) : undefined
                  }
                />
              ))}
            </tbody>
          </table>
        )}
      </div>

      <AcmeDnsCredentialModal
        isOpen={modalOpen}
        onClose={() => setModalOpen(false)}
        onCreated={() => {
          setModalOpen(false);
          void fetchCreds();
        }}
        supportedProviders={providers}
      />

      <DnsRecordsModal
        isOpen={!!dnsRecordsTarget}
        credentialId={dnsRecordsTarget?.id ?? null}
        credentialName={dnsRecordsTarget?.name ?? ''}
        onClose={() => setDnsRecordsTarget(null)}
      />
    </>
  );
};

interface CredentialRowProps {
  cred: AcmeDnsCredentialSummary;
  lastReason: string | null;
  testing: boolean;
  deleting: boolean;
  onTest: () => void;
  onDelete: () => void;
  onManageDns?: () => void;
}

const CredentialRow: React.FC<CredentialRowProps> = ({
  cred,
  lastReason,
  testing,
  deleting,
  onTest,
  onDelete,
  onManageDns,
}) => (
  <tr className="border-t border-theme">
    <td className="px-4 py-3 text-theme-primary font-mono text-xs">{cred.name}</td>
    <td className="px-4 py-3 text-theme-secondary">
      <span className="px-1.5 py-0.5 bg-theme-background-secondary rounded text-xs font-mono">
        {cred.provider}
      </span>
    </td>
    <td className="px-4 py-3">
      <StatusPill status={cred.status} />
      {lastReason && (
        <div className="text-xs text-theme-secondary mt-1 max-w-xs italic">{lastReason}</div>
      )}
    </td>
    <td className="px-4 py-3 text-xs text-theme-secondary">
      {cred.last_validated_at ? (
        <span className="inline-flex items-center gap-1">
          <Clock className="w-3 h-3" />
          {new Date(cred.last_validated_at).toLocaleString()}
          {cred.needs_revalidation && (
            <span className="text-theme-warning ml-1" title="Older than 24h">stale</span>
          )}
        </span>
      ) : (
        <span className="text-theme-tertiary">never</span>
      )}
    </td>
    <td className="px-4 py-3 text-right">
      <button
        type="button"
        onClick={onTest}
        disabled={testing}
        title="Verify the credential against the provider's API"
        className="px-2 py-1 rounded text-xs text-theme-info hover:bg-theme-surface-hover disabled:opacity-40 inline-flex items-center gap-1 mr-1 transition-colors"
      >
        {testing ? <Clock className="w-3 h-3" /> : <Check className="w-3 h-3" />}
        {testing ? 'Testing…' : 'Test'}
      </button>
      {onManageDns && (
        <button
          type="button"
          onClick={onManageDns}
          title="Manage DNS records on zones this credential can reach"
          className="px-2 py-1 rounded text-xs text-theme-info hover:bg-theme-surface-hover inline-flex items-center gap-1 mr-1 transition-colors"
        >
          <Globe className="w-3 h-3" />
          DNS Records
        </button>
      )}
      <button
        type="button"
        onClick={onDelete}
        disabled={deleting}
        title="Delete credential + Vault secret"
        className="px-2 py-1 rounded text-xs text-theme-danger hover:bg-theme-surface-hover disabled:opacity-40 inline-flex items-center gap-1 transition-colors"
      >
        <Trash2 className="w-3 h-3" />
        {deleting ? 'Deleting…' : 'Delete'}
      </button>
    </td>
  </tr>
);

const StatusPill: React.FC<{ status: AcmeDnsCredentialStatus }> = ({ status }) => {
  const config: Record<AcmeDnsCredentialStatus, { className: string; icon: React.ReactNode; label: string }> = {
    untested: {
      className: 'bg-theme-background-tertiary text-theme-secondary',
      icon: <Clock className="w-3 h-3" />,
      label: 'untested',
    },
    valid: {
      className: 'bg-theme-success text-theme-success',
      icon: <ShieldCheck className="w-3 h-3" />,
      label: 'valid',
    },
    invalid: {
      className: 'bg-theme-danger text-theme-danger',
      icon: <ShieldAlert className="w-3 h-3" />,
      label: 'invalid',
    },
    expired: {
      className: 'bg-theme-warning text-theme-warning',
      icon: <AlertTriangle className="w-3 h-3" />,
      label: 'expired',
    },
  };
  const c = config[status];
  return (
    <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium ${c.className}`}>
      {c.icon}
      {c.label}
    </span>
  );
};
