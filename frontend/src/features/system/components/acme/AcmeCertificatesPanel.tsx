import React, { useCallback, useEffect, useState } from 'react';
import {
  ShieldCheck,
  Plus,
  AlertTriangle,
  Trash2,
  RefreshCw,
  Clock,
  ShieldAlert,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { EntityLink } from '@/shared/components/entity';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { acmeCertificatesApi } from '../../services/api/acmeCertificatesApi';
import type {
  AcmeCertificateSummary,
  AcmeCertificateStatus,
} from '../../types/acme.types';
import { RequestCertificateModal } from './RequestCertificateModal';

/**
 * Operator-facing list of ACME-issued certificates. Inline actions:
 * request issuance (for pending/failed), revoke (for active), delete
 * (for terminal). Plaintext PEMs are never shown — only metadata +
 * vault-presence indicator.
 *
 * Plan reference: Decentralized Federation §J + P2.5.9.
 */

interface AcmeCertificatesPanelProps {
  refreshKey?: number;
}

export const AcmeCertificatesPanel: React.FC<AcmeCertificatesPanelProps> = ({
  refreshKey = 0,
}) => {
  const { addNotification } = useNotifications();
  const [certs, setCerts] = useState<AcmeCertificateSummary[]>([]);
  const [issuers, setIssuers] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [modalOpen, setModalOpen] = useState(false);
  const [actingId, setActingId] = useState<string | null>(null);
  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  const toggleExpanded = useCallback((id: string) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  }, []);

  const fetchCerts = useCallback(async () => {
    setLoading(true);
    try {
      const result = await acmeCertificatesApi.list();
      setCerts(result.certificates);
      setIssuers(result.issuers);
    } catch (err: unknown) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to load certificates',
      });
    } finally {
      setLoading(false);
    }
  }, [addNotification]);

  useEffect(() => {
    void fetchCerts();
  }, [fetchCerts, refreshKey]);

  const handleRequestIssue = async (cert: AcmeCertificateSummary) => {
    if (
      !window.confirm(
        `Request ACME issuance for "${cert.common_name}" (${cert.issuer})?\n\n` +
          'This calls Let\'s Encrypt + your DNS provider. Typical duration: 60-180s. ' +
          'The connection stays open; the response is the source of truth.',
      )
    ) {
      return;
    }
    setActingId(cert.id);
    try {
      await acmeCertificatesApi.requestIssue(cert.id);
      await fetchCerts();
    } catch (err: unknown) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Issuance failed',
      });
      await fetchCerts();
    } finally {
      setActingId(null);
    }
  };

  const handleRenew = async (cert: AcmeCertificateSummary) => {
    if (
      !window.confirm(
        `Renew certificate for "${cert.common_name}"?\n\n` +
          'This calls Let\'s Encrypt + your DNS provider to obtain a fresh cert ' +
          'using the same account key. Typical duration: 30-120 seconds. ' +
          'Traefik hot-reloads the cert without dropping connections.',
      )
    ) {
      return;
    }
    setActingId(cert.id);
    try {
      await acmeCertificatesApi.renew(cert.id);
      await fetchCerts();
    } catch (err: unknown) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Renewal failed',
      });
      await fetchCerts();
    } finally {
      setActingId(null);
    }
  };

  const handleRevoke = async (cert: AcmeCertificateSummary) => {
    const reason = window.prompt(
      `Revoke certificate for "${cert.common_name}"?\n\n` +
        'This is irreversible. Optional reason:',
      '',
    );
    if (reason === null) return;
    setActingId(cert.id);
    try {
      await acmeCertificatesApi.revoke(cert.id, reason || undefined);
      await fetchCerts();
    } catch (err: unknown) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Revoke failed',
      });
    } finally {
      setActingId(null);
    }
  };

  const handleDelete = async (cert: AcmeCertificateSummary) => {
    if (!window.confirm(`Delete certificate row for "${cert.common_name}"?`)) return;
    setActingId(cert.id);
    try {
      await acmeCertificatesApi.destroy(cert.id);
      await fetchCerts();
    } catch (err: unknown) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Delete failed',
      });
    } finally {
      setActingId(null);
    }
  };

  return (
    <>
      <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
        <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <ShieldCheck className="w-5 h-5 text-theme-info-fg" />
            <h2 className="font-semibold text-theme-primary">Certificates</h2>
            <span className="text-xs text-theme-secondary">
              {loading
                ? 'loading…'
                : `${certs.length} ${certs.length === 1 ? 'certificate' : 'certificates'}`}
            </span>
          </div>
          <Button variant="primary" onClick={() => setModalOpen(true)}>
            <Plus className="w-4 h-4" />
            Request certificate
          </Button>
        </header>

        {!loading && certs.length === 0 && (
          <div className="p-12 text-center text-theme-secondary text-sm">
            No certificates yet. Click "Request certificate" to issue one against Let's
            Encrypt using one of your configured DNS provider credentials.
          </div>
        )}

        {certs.length > 0 && (
          <table className="w-full text-sm">
            <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
              <tr>
                <th className="w-8 px-2 py-2"></th>
                <th className="text-left px-4 py-2 font-medium">Domain</th>
                <th className="text-left px-4 py-2 font-medium">Status</th>
                <th className="text-left px-4 py-2 font-medium">Issuer</th>
                <th className="text-left px-4 py-2 font-medium">Expires</th>
                <th className="text-right px-4 py-2 font-medium">Actions</th>
              </tr>
            </thead>
            <tbody>
              {certs.map((cert) => (
                <CertRow
                  key={cert.id}
                  cert={cert}
                  acting={actingId === cert.id}
                  expanded={expandedIds.has(cert.id)}
                  onToggleExpanded={() => toggleExpanded(cert.id)}
                  onRequestIssue={() => handleRequestIssue(cert)}
                  onRenew={() => handleRenew(cert)}
                  onRevoke={() => handleRevoke(cert)}
                  onDelete={() => handleDelete(cert)}
                />
              ))}
            </tbody>
          </table>
        )}
      </div>

      <RequestCertificateModal
        isOpen={modalOpen}
        onClose={() => setModalOpen(false)}
        availableIssuers={issuers}
        onRequested={async () => {
          setModalOpen(false);
          await fetchCerts();
        }}
      />
    </>
  );
};

interface CertRowProps {
  cert: AcmeCertificateSummary;
  acting: boolean;
  expanded: boolean;
  onToggleExpanded: () => void;
  onRequestIssue: () => void;
  onRenew: () => void;
  onRevoke: () => void;
  onDelete: () => void;
}

const CertRow: React.FC<CertRowProps> = ({
  cert,
  acting,
  expanded,
  onToggleExpanded,
  onRequestIssue,
  onRenew,
  onRevoke,
  onDelete,
}) => {
  const canIssue = cert.status === 'pending' || cert.status === 'failed';
  const canRenew = cert.status === 'valid';
  const canRevoke = !cert.terminal && (cert.status === 'valid' || cert.status === 'renewing');
  const canDelete = cert.terminal || cert.status === 'pending' || cert.status === 'failed';

  return (
    <React.Fragment>
    <tr className="border-t border-theme">
      <td className="px-2 py-3 align-middle">
        <button
          type="button"
          onClick={onToggleExpanded}
          className="p-1 text-theme-secondary hover:text-theme-primary rounded transition-colors"
          title={expanded ? 'Collapse details' : 'Expand details'}
        >
          {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
        </button>
      </td>
      <td className="px-4 py-3">
        <div className="text-theme-primary font-mono text-xs">{cert.common_name}</div>
        {cert.sans.length > 0 && (
          <div className="text-xs text-theme-secondary mt-1">
            +{cert.sans.length} SAN{cert.sans.length === 1 ? '' : 's'}: {cert.sans.join(', ')}
          </div>
        )}
      </td>
      <td className="px-4 py-3">
        <StatusPill status={cert.status} />
        {cert.last_renewal_error && (
          <div className="text-xs text-theme-danger-fg mt-1 max-w-xs italic">
            {cert.last_renewal_error}
          </div>
        )}
      </td>
      <td className="px-4 py-3 text-xs text-theme-secondary font-mono">{cert.issuer}</td>
      <td className="px-4 py-3 text-xs text-theme-secondary">
        {cert.expires_at ? (
          <>
            <div>{new Date(cert.expires_at).toLocaleDateString()}</div>
            {cert.days_until_expiry !== null && (
              <div
                className={
                  cert.days_until_expiry < 30
                    ? 'text-theme-warning-fg'
                    : 'text-theme-tertiary'
                }
              >
                {cert.days_until_expiry > 0
                  ? `in ${cert.days_until_expiry}d`
                  : `expired ${Math.abs(cert.days_until_expiry)}d ago`}
              </div>
            )}
          </>
        ) : (
          <span className="text-theme-tertiary">—</span>
        )}
      </td>
      <td className="px-4 py-3 text-right">
        {canIssue && (
          <button
            type="button"
            onClick={onRequestIssue}
            disabled={acting}
            title="Request ACME issuance"
            className="px-2 py-1 rounded text-xs text-theme-info-fg hover:bg-theme-surface-hover disabled:opacity-40 inline-flex items-center gap-1 mr-1 transition-colors"
          >
            {acting ? <Clock className="w-3 h-3" /> : <RefreshCw className="w-3 h-3" />}
            {acting ? 'Issuing…' : cert.status === 'failed' ? 'Retry' : 'Issue'}
          </button>
        )}
        {canRenew && (
          <button
            type="button"
            onClick={onRenew}
            disabled={acting}
            title="Renew now (force ACME renewal — same account key, fresh cert)"
            className="px-2 py-1 rounded text-xs text-theme-info-fg hover:bg-theme-surface-hover disabled:opacity-40 inline-flex items-center gap-1 mr-1 transition-colors"
          >
            {acting ? <Clock className="w-3 h-3 animate-spin" /> : <RefreshCw className="w-3 h-3" />}
            {acting ? 'Renewing…' : 'Renew'}
          </button>
        )}
        {canRevoke && (
          <button
            type="button"
            onClick={onRevoke}
            disabled={acting}
            title="Revoke certificate"
            className="px-2 py-1 rounded text-xs text-theme-warning-fg hover:bg-theme-surface-hover disabled:opacity-40 inline-flex items-center gap-1 mr-1 transition-colors"
          >
            <ShieldAlert className="w-3 h-3" />
            Revoke
          </button>
        )}
        {canDelete && (
          <button
            type="button"
            onClick={onDelete}
            disabled={acting}
            title="Delete row"
            className="px-2 py-1 rounded text-xs text-theme-danger-fg hover:bg-theme-surface-hover disabled:opacity-40 inline-flex items-center gap-1 transition-colors"
          >
            <Trash2 className="w-3 h-3" />
            Delete
          </button>
        )}
      </td>
    </tr>
    {expanded && (
      <tr className="bg-theme-background border-b border-theme">
        <td></td>
        <td colSpan={5} className="px-4 py-3">
          <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
            <div>
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Issuer
              </label>
              <p className="text-theme-primary font-mono text-xs">{cert.issuer}</p>
            </div>
            <div>
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Challenge Type
              </label>
              <p className="text-theme-primary font-mono text-xs">{cert.challenge_type}</p>
            </div>
            <div>
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Status
              </label>
              <p className="text-theme-primary">{cert.status}</p>
            </div>
            <div className="col-span-full">
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Subject Alternative Names
              </label>
              {cert.sans.length > 0 ? (
                <p className="text-theme-primary font-mono text-xs break-all">
                  {cert.sans.join(', ')}
                </p>
              ) : (
                <p className="text-theme-tertiary text-xs">None</p>
              )}
            </div>
            <div>
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Vault Material (chain/key)
              </label>
              <p className="text-theme-primary text-xs">
                {cert.vault_paths_present ? 'Present in Vault' : 'Not yet stored'}
              </p>
            </div>
            <div>
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                DNS Credential
              </label>
              {cert.dns_credential_id ? (
                <EntityLink
                  type="acme_dns_credential"
                  id={cert.dns_credential_id}
                  label={cert.dns_credential_id}
                  className="font-mono text-xs"
                />
              ) : (
                <p className="text-theme-tertiary text-xs">—</p>
              )}
            </div>
            <div>
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Issued
              </label>
              <p className="text-theme-primary text-xs">
                {cert.issued_at ? new Date(cert.issued_at).toLocaleString() : 'Not issued'}
              </p>
            </div>
            <div>
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Expires
              </label>
              <p className="text-theme-primary text-xs">
                {cert.expires_at ? new Date(cert.expires_at).toLocaleString() : '—'}
                {cert.days_until_expiry !== null && (
                  <span
                    className={
                      cert.days_until_expiry < 30 ? 'text-theme-warning-fg ml-1' : 'text-theme-tertiary ml-1'
                    }
                  >
                    {cert.days_until_expiry > 0
                      ? `(in ${cert.days_until_expiry}d)`
                      : `(expired ${Math.abs(cert.days_until_expiry)}d ago)`}
                  </span>
                )}
              </p>
            </div>
            {cert.last_renewal_error && (
              <div className="col-span-full">
                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                  Last Renewal Error
                </label>
                <p className="text-theme-danger-fg text-xs italic">{cert.last_renewal_error}</p>
              </div>
            )}
            <div>
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Created
              </label>
              <p className="text-theme-primary text-xs">
                {new Date(cert.created_at).toLocaleString()}
              </p>
            </div>
            <div>
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Updated
              </label>
              <p className="text-theme-primary text-xs">
                {new Date(cert.updated_at).toLocaleString()}
              </p>
            </div>
            <div className="col-span-full">
              <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                Certificate ID
              </label>
              <p className="text-theme-primary font-mono text-xs truncate" title={cert.id}>
                {cert.id}
              </p>
            </div>
          </div>
        </td>
      </tr>
    )}
    </React.Fragment>
  );
};

const StatusPill: React.FC<{ status: AcmeCertificateStatus }> = ({ status }) => {
  const config: Record<
    AcmeCertificateStatus,
    { className: string; icon: React.ReactNode; label: string }
  > = {
    pending: {
      className: 'bg-theme-background-tertiary text-theme-secondary',
      icon: <Clock className="w-3 h-3" />,
      label: 'pending',
    },
    issuing: {
      className: 'bg-theme-info-bg text-theme-info-fg',
      icon: <RefreshCw className="w-3 h-3 animate-spin" />,
      label: 'issuing',
    },
    valid: {
      className: 'bg-theme-success-bg text-theme-success-fg',
      icon: <CheckCircle2 className="w-3 h-3" />,
      label: 'valid',
    },
    renewing: {
      className: 'bg-theme-info-bg text-theme-info-fg',
      icon: <RefreshCw className="w-3 h-3 animate-spin" />,
      label: 'renewing',
    },
    expired: {
      className: 'bg-theme-warning-bg text-theme-warning-fg',
      icon: <AlertTriangle className="w-3 h-3" />,
      label: 'expired',
    },
    revoked: {
      className: 'bg-theme-danger-bg text-theme-danger-fg',
      icon: <ShieldAlert className="w-3 h-3" />,
      label: 'revoked',
    },
    failed: {
      className: 'bg-theme-danger-bg text-theme-danger-fg',
      icon: <AlertTriangle className="w-3 h-3" />,
      label: 'failed',
    },
  };
  const c = config[status];
  return (
    <span
      className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium ${c.className}`}
    >
      {c.icon}
      {c.label}
    </span>
  );
};
