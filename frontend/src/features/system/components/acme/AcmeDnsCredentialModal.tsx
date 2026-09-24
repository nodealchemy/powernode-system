import React, { useEffect, useMemo, useRef, useState } from 'react';
import { KeyRound, AlertCircle, ExternalLink, ShieldCheck } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { acmeDnsCredentialsApi } from '../../services/api/acmeDnsCredentialsApi';
import type {
  AcmeDnsCredentialDetail,
  AcmeDnsProvider,
  SupportedProvider,
} from '../../types/acme.types';

/**
 * Create-form for a new ACME DNS credential. The token plaintext is
 * collected here, posted to the server, and never returned — the
 * response includes only the metadata row, never the secret.
 *
 * Plan reference: Decentralized Federation §J + P2.5.8.
 */

interface AcmeDnsCredentialModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCreated?: (credential: AcmeDnsCredentialDetail) => void;
  supportedProviders: SupportedProvider[];
}

interface ProviderHelp {
  helpText: React.ReactNode;
  fieldLabels?: Record<string, string>;
  fieldPlaceholders?: Record<string, string>;
}

const PROVIDER_HELP: Record<AcmeDnsProvider, ProviderHelp> = {
  cloudflare: {
    fieldLabels: { api_token: 'Cloudflare API Token' },
    fieldPlaceholders: { api_token: 'paste token here (starts after Create Token)' },
    helpText: (
      <div className="text-xs text-theme-secondary space-y-2">
        <p className="text-theme-primary font-medium">How to create a Cloudflare API Token:</p>
        <ol className="list-decimal pl-5 space-y-1">
          <li>
            Open{' '}
            <a
              href="https://dash.cloudflare.com/profile/api-tokens"
              target="_blank"
              rel="noopener noreferrer"
              className="text-theme-info-fg inline-flex items-center gap-1 hover:underline"
            >
              Cloudflare → My Profile → API Tokens
              <ExternalLink className="w-3 h-3" />
            </a>
          </li>
          <li>Click <strong>Create Token → Custom Token</strong>.</li>
          <li>
            Add <strong>two permissions</strong>:
            <ul className="list-disc pl-5 mt-1 space-y-0.5">
              <li><code className="font-mono">Zone — Zone — Read</code></li>
              <li><code className="font-mono">Zone — DNS — Edit</code></li>
            </ul>
          </li>
          <li>
            Under <strong>Zone Resources</strong>: <code className="font-mono">Include → All zones from an account</code>.
          </li>
          <li>
            (Optional) Restrict to your platform's public IP under{' '}
            <strong>IP Address Filtering</strong>.
          </li>
          <li>Click <strong>Continue → Create Token</strong> and copy the token below — Cloudflare shows it once.</li>
        </ol>
        <p className="italic">
          The platform stores the token in Vault and uses it only to solve ACME DNS-01 challenges. Never use the legacy Global API Key.
        </p>
      </div>
    ),
  },
  digitalocean: {
    fieldLabels: { auth_token: 'DigitalOcean Personal Access Token' },
    helpText: (
      <p className="text-xs text-theme-secondary">
        Create a read+write token at{' '}
        <a
          href="https://cloud.digitalocean.com/account/api/tokens"
          target="_blank"
          rel="noopener noreferrer"
          className="text-theme-info-fg hover:underline"
        >
          DigitalOcean → API → Tokens
        </a>
        .
      </p>
    ),
  },
  hetzner: {
    fieldLabels: { api_token: 'Hetzner DNS Console API Token' },
    helpText: (
      <p className="text-xs text-theme-secondary">
        Create at{' '}
        <a
          href="https://dns.hetzner.com/settings/api-token"
          target="_blank"
          rel="noopener noreferrer"
          className="text-theme-info-fg hover:underline"
        >
          dns.hetzner.com → Settings → API Tokens
        </a>
        .
      </p>
    ),
  },
  route53: {
    helpText: (
      <p className="text-xs text-theme-secondary">
        Create an IAM user with policy granting <code>route53:GetChange</code>,{' '}
        <code>route53:ListHostedZones</code>, and <code>route53:ChangeResourceRecordSets</code> for the zones you'll issue certs against.
      </p>
    ),
  },
  gcloud: {
    helpText: (
      <p className="text-xs text-theme-secondary">
        Create a service account with the <strong>DNS Administrator</strong> role and download its JSON key. Paste the full JSON below.
      </p>
    ),
  },
  porkbun: {
    helpText: (
      <p className="text-xs text-theme-secondary">
        Generate an API key + secret API key pair at Porkbun → Account → API Access.
      </p>
    ),
  },
  ovh: {
    helpText: (
      <p className="text-xs text-theme-secondary">
        Create application credentials at the OVH API console — endpoint values are <code>ovh-eu</code> / <code>ovh-us</code> / <code>ovh-ca</code>.
      </p>
    ),
  },
};

export const AcmeDnsCredentialModal: React.FC<AcmeDnsCredentialModalProps> = ({
  isOpen,
  onClose,
  onCreated,
  supportedProviders,
}) => {
  const { addNotification } = useNotifications();
  // Readiness is a backend fact (Acme::DnsProviderRegistry#production_ready?),
  // carried on each supported-providers entry. The UI never decides which
  // providers work — a deployment that wires a new one on the agent gets it
  // selectable with no frontend release.
  const isProductionReady = (slug: AcmeDnsProvider): boolean =>
    supportedProviders.some((p) => p.slug === slug && p.production_ready);

  // Open on a provider the operator can actually use. When the backend reports
  // none ready the form is replaced by an empty state, so the fallback here is
  // only ever a placeholder for a select that is never rendered.
  const firstReady = supportedProviders.find((p) => p.production_ready)?.slug;
  const noReadyProviders = firstReady === undefined;
  const defaultProvider: AcmeDnsProvider =
    firstReady ?? supportedProviders[0]?.slug ?? 'cloudflare';

  const [name, setName] = useState('');
  const [provider, setProvider] = useState<AcmeDnsProvider>(defaultProvider);
  const [credentials, setCredentials] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Read through a ref so a refetch that changes the advertised providers
  // cannot re-run this effect and wipe a half-typed token: the reset belongs
  // to OPENING the modal, not to the prop.
  const defaultProviderRef = useRef(defaultProvider);
  defaultProviderRef.current = defaultProvider;

  useEffect(() => {
    if (!isOpen) return;
    setName('');
    setProvider(defaultProviderRef.current);
    setCredentials({});
    setSubmitting(false);
    setError(null);
  }, [isOpen]);

  const providerMeta = useMemo(
    () => supportedProviders.find((p) => p.slug === provider),
    [supportedProviders, provider],
  );

  const providerHelp = PROVIDER_HELP[provider];
  const requiredFields = providerMeta?.required_fields ?? [];

  const valid = useMemo(() => {
    if (!name.trim()) return false;
    // A provider the backend has not marked ready must never be submittable:
    // the row would be accepted and then fail at first issuance. The select
    // already disables it; this closes the same hole on the submit path.
    if (!isProductionReady(provider)) return false;
    return requiredFields.every((f) => (credentials[f] ?? '').trim().length > 0);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [name, requiredFields, credentials, provider, supportedProviders]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!valid) {
      setError('Fill the name and all required credential fields.');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const created = await acmeDnsCredentialsApi.create({
        name: name.trim(),
        provider,
        credentials,
      });
      onCreated?.(created);
      onClose();
    } catch (err: unknown) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Create failed',
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <div className="flex items-center gap-2">
          <KeyRound className="w-5 h-5 text-theme-info-fg" />
          <span>Add ACME DNS Credential</span>
        </div>
      }
      icon={<ShieldCheck className="w-6 h-6" />}
      maxWidth="2xl"
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="ghost" onClick={onClose} disabled={submitting}>
            Cancel
          </Button>
          <Button
            variant="primary"
            onClick={handleSubmit}
            disabled={submitting || !valid}
          >
            {submitting ? 'Saving…' : 'Save credential'}
          </Button>
        </div>
      }
    >
      {noReadyProviders ? (
        <div className="p-3 bg-theme-warning-bg text-theme-warning-fg rounded flex items-start gap-2">
          <AlertCircle className="w-4 h-4 mt-0.5 flex-shrink-0" />
          <div className="text-sm">
            <p className="font-medium">No DNS provider is usable on this deployment yet.</p>
            <p className="mt-1 text-xs">
              The backend advertises {supportedProviders.length} provider
              {supportedProviders.length === 1 ? '' : 's'}, but none is wired
              through the on-node ACME issuer, so a credential saved here would
              fail at first issuance. Enable one on the agent and reopen this
              form.
            </p>
          </div>
        </div>
      ) : (
      <form onSubmit={handleSubmit} className="space-y-4">
        {error && (
          <ErrorAlert message={error} onClose={() => setError(null)} />
        )}

        <div>
          <label className="block text-xs font-medium text-theme-secondary mb-1">
            Credential name
          </label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            disabled={submitting}
            required
            placeholder="production-cloudflare"
            className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
          />
          <p className="text-xs text-theme-secondary mt-1">
            Operator-visible label. Unique within your account.
          </p>
        </div>

        <div>
          <label className="block text-xs font-medium text-theme-secondary mb-1">
            DNS provider
          </label>
          <select
            value={provider}
            onChange={(e) => {
              const slug = e.target.value as AcmeDnsProvider;
              if (!isProductionReady(slug)) return;
              setProvider(slug);
              setCredentials({});
            }}
            disabled={submitting}
            className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 text-sm"
          >
            {supportedProviders.filter((p) => p.production_ready).map((p) => (
              <option key={p.slug} value={p.slug}>
                {p.slug} — {p.description}
              </option>
            ))}
          </select>
          <p className="text-xs text-theme-secondary mt-1">
            Only providers wired through the on-node agent are listed; the
            rest are advertised by the backend but not yet usable for
            issuance.
          </p>
        </div>

        {providerHelp && (
          <div className="p-3 bg-theme-info-bg rounded text-theme-info-fg">
            <div className="flex items-start gap-2">
              <ShieldCheck className="w-4 h-4 mt-0.5 flex-shrink-0" />
              <div className="flex-1">{providerHelp.helpText}</div>
            </div>
          </div>
        )}

        <div className="space-y-3">
          {requiredFields.map((field) => {
            const label = providerHelp?.fieldLabels?.[field] ?? field.replace(/_/g, ' ');
            const placeholder = providerHelp?.fieldPlaceholders?.[field] ?? '';
            const isSecret = field !== 'region' && field !== 'endpoint' && field !== 'project_id';
            return (
              <div key={field}>
                <label className="block text-xs font-medium text-theme-secondary mb-1 capitalize">
                  {label}
                </label>
                {field === 'service_account_json' ? (
                  <textarea
                    value={credentials[field] ?? ''}
                    onChange={(e) =>
                      setCredentials((prev) => ({ ...prev, [field]: e.target.value }))
                    }
                    disabled={submitting}
                    required
                    placeholder={placeholder || 'paste full service-account JSON here'}
                    rows={6}
                    className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-xs"
                  />
                ) : (
                  <input
                    type={isSecret ? 'password' : 'text'}
                    autoComplete="off"
                    value={credentials[field] ?? ''}
                    onChange={(e) =>
                      setCredentials((prev) => ({ ...prev, [field]: e.target.value }))
                    }
                    disabled={submitting}
                    required
                    placeholder={placeholder}
                    className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
                  />
                )}
              </div>
            );
          })}
        </div>

        <p className="text-xs text-theme-secondary italic">
          The token plaintext is stored in Vault and never echoed back. After saving, click "Test connectivity" on the row to verify the credential.
        </p>
      </form>
      )}
    </Modal>
  );
};
