import React, { useEffect, useMemo, useState } from 'react';
import { ShieldCheck, AlertCircle, X, RefreshCw } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { acmeCertificatesApi } from '../../services/api/acmeCertificatesApi';
import { acmeDnsCredentialsApi } from '../../services/api/acmeDnsCredentialsApi';
import type {
  AcmeDnsCredentialSummary,
  AcmeIssuer,
} from '../../types/acme.types';

/**
 * Two-step certificate request modal:
 *   1. Configure (common name, SANs, DNS cred, issuer, email)
 *   2. Issue (synchronous; server holds connection during ACME flow)
 *
 * Defaults to letsencrypt-staging to encourage dry-runs before hitting
 * LE prod's tighter rate limits.
 *
 * Plan reference: Decentralized Federation §J + P2.5.9.
 */

interface RequestCertificateModalProps {
  isOpen: boolean;
  onClose: () => void;
  onRequested?: () => void | Promise<void>;
  availableIssuers: string[];
}

const ISSUER_HELP: Record<string, string> = {
  'letsencrypt-staging':
    "Let's Encrypt staging. Cert is real-but-untrusted. Use for testing — generous rate limits.",
  'letsencrypt-prod':
    "Let's Encrypt production. Browser-trusted. Rate-limited: 5 duplicate certs/week, 300 new orders/3h.",
};

export const RequestCertificateModal: React.FC<RequestCertificateModalProps> = ({
  isOpen,
  onClose,
  onRequested,
  availableIssuers,
}) => {
  const [commonName, setCommonName] = useState('');
  const [sans, setSans] = useState('');
  const [issuer, setIssuer] = useState<AcmeIssuer | string>('letsencrypt-staging');
  const [acmeEmail, setAcmeEmail] = useState('');
  const [dnsCreds, setDnsCreds] = useState<AcmeDnsCredentialSummary[]>([]);
  const [dnsCredId, setDnsCredId] = useState('');
  const [phase, setPhase] = useState<'form' | 'issuing' | 'done'>('form');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isOpen) return;
    setCommonName('');
    setSans('');
    setIssuer('letsencrypt-staging');
    setAcmeEmail('');
    setDnsCredId('');
    setPhase('form');
    setError(null);
    // Load valid DNS credentials.
    (async () => {
      try {
        const result = await acmeDnsCredentialsApi.list();
        const valid = result.credentials.filter((c) => c.status === 'valid');
        setDnsCreds(valid);
        if (valid.length === 1) setDnsCredId(valid[0].id);
      } catch (err: unknown) {
        setError(err instanceof Error ? err.message : 'Failed to load DNS credentials');
      }
    })();
  }, [isOpen]);

  const valid = useMemo(() => {
    return (
      commonName.trim().length > 0 &&
      acmeEmail.trim().length > 0 &&
      dnsCredId.length > 0 &&
      issuer.length > 0
    );
  }, [commonName, acmeEmail, dnsCredId, issuer]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!valid) {
      setError('Fill all required fields + pick a valid DNS credential.');
      return;
    }
    setPhase('issuing');
    setError(null);
    const sansArr = sans
      .split(',')
      .map((s) => s.trim())
      .filter((s) => s.length > 0);

    try {
      // Create the pending row first. This is fast.
      const created = await acmeCertificatesApi.create({
        common_name: commonName.trim(),
        dns_credential_id: dnsCredId,
        issuer,
        acme_email: acmeEmail.trim(),
        sans: sansArr,
      });
      // Fire request_issue immediately. Server holds the connection
      // open while ACME runs; expect 60-180s.
      await acmeCertificatesApi.requestIssue(created.id);
      setPhase('done');
      await onRequested?.();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Issuance failed');
      setPhase('form');
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <div className="flex items-center gap-2">
          <ShieldCheck className="w-5 h-5 text-theme-info" />
          <span>Request certificate</span>
        </div>
      }
      maxWidth="2xl"
      footer={
        phase === 'form' ? (
          <div className="flex items-center justify-end gap-2">
            <Button variant="ghost" onClick={onClose}>
              Cancel
            </Button>
            <Button variant="primary" onClick={handleSubmit} disabled={!valid}>
              Issue certificate
            </Button>
          </div>
        ) : (
          <div className="flex items-center justify-end">
            <Button variant="primary" onClick={onClose} disabled={phase === 'issuing'}>
              Done
            </Button>
          </div>
        )
      }
    >
      {phase === 'issuing' && (
        <div className="space-y-3 py-8 text-center">
          <RefreshCw className="w-8 h-8 mx-auto text-theme-info animate-spin" />
          <div className="text-theme-primary font-medium">Issuing certificate…</div>
          <div className="text-sm text-theme-secondary">
            ACME ceremony is running — typically 60-180 seconds. The connection stays
            open. Don't close this dialog.
          </div>
        </div>
      )}

      {phase === 'done' && (
        <div className="space-y-3 py-8 text-center">
          <ShieldCheck className="w-8 h-8 mx-auto text-theme-success" />
          <div className="text-theme-primary font-medium">Certificate issued.</div>
          <div className="text-sm text-theme-secondary">
            The cert + private key + chain are stored in Vault. Inspect from the list
            view.
          </div>
        </div>
      )}

      {phase === 'form' && (
        <form onSubmit={handleSubmit} className="space-y-4">
          {error && (
            <div className="p-2 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm rounded">
              <AlertCircle className="w-4 h-4" />
              <span className="flex-1">{error}</span>
              <button type="button" onClick={() => setError(null)} className="p-1">
                <X className="w-3 h-3" />
              </button>
            </div>
          )}

          <div>
            <label className="block text-xs font-medium text-theme-secondary mb-1">
              Common name (primary domain)
            </label>
            <input
              type="text"
              value={commonName}
              onChange={(e) => setCommonName(e.target.value.trim())}
              required
              placeholder="dev.powernode.net"
              className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary font-mono text-sm"
            />
          </div>

          <div>
            <label className="block text-xs font-medium text-theme-secondary mb-1">
              SANs (optional, comma-separated)
            </label>
            <input
              type="text"
              value={sans}
              onChange={(e) => setSans(e.target.value)}
              placeholder="alt.example.com, www.example.com"
              className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary font-mono text-sm"
            />
          </div>

          <div>
            <label className="block text-xs font-medium text-theme-secondary mb-1">
              DNS provider credential
            </label>
            {dnsCreds.length === 0 ? (
              <div className="text-sm text-theme-warning bg-theme-warning rounded p-2">
                No valid DNS credentials. Add one and run "Test connectivity" first.
              </div>
            ) : (
              <select
                value={dnsCredId}
                onChange={(e) => setDnsCredId(e.target.value)}
                required
                className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary text-sm"
              >
                <option value="">-- pick one --</option>
                {dnsCreds.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name} ({c.provider})
                  </option>
                ))}
              </select>
            )}
          </div>

          <div>
            <label className="block text-xs font-medium text-theme-secondary mb-1">
              Issuer
            </label>
            <select
              value={issuer}
              onChange={(e) => setIssuer(e.target.value)}
              required
              className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary text-sm"
            >
              {availableIssuers.map((iss) => (
                <option key={iss} value={iss}>
                  {iss}
                </option>
              ))}
            </select>
            {ISSUER_HELP[issuer] && (
              <p className="text-xs text-theme-secondary mt-1">{ISSUER_HELP[issuer]}</p>
            )}
          </div>

          <div>
            <label className="block text-xs font-medium text-theme-secondary mb-1">
              ACME account email
            </label>
            <input
              type="email"
              value={acmeEmail}
              onChange={(e) => setAcmeEmail(e.target.value.trim())}
              required
              placeholder="ops@your-domain.tld"
              className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary text-sm"
            />
            <p className="text-xs text-theme-secondary mt-1">
              Let's Encrypt sends renewal reminders here. Persisted with the cert.
            </p>
          </div>
        </form>
      )}
    </Modal>
  );
};
