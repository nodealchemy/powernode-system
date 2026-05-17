import React, { useEffect, useMemo, useState } from 'react';
import { Server, AlertCircle, X, ExternalLink } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { serviceCatalogApi } from '../../services/api/serviceCatalogApi';
import type {
  RemoteCatalogOffering,
  ServiceSubscription,
} from '../../types/service_delivery.types';

/**
 * Subscribe-to-remote-offering modal. Collects the subscriber's
 * chosen local_hostname (the public domain under which Traefik will
 * serve this remote service) plus an optional ttl_days + DNS
 * credential. Invokes the remote subscribe endpoint which
 * orchestrates: peer's federation_api/subscriptions → local
 * SubscriptionLifecycleService.activate!
 *
 * Plan reference: Decentralized Federation §L + P4.6.8e.
 */

interface SubscribeServiceModalProps {
  isOpen: boolean;
  onClose: () => void;
  peerId: string;
  offering: RemoteCatalogOffering | null;
  onSubscribed?: (subscription: ServiceSubscription) => void;
}

// Hostnames must look reasonable. Permissive client-side regex —
// backend validation is authoritative.
const HOSTNAME_PATTERN = /^[a-z0-9]([a-z0-9.-]{0,253}[a-z0-9])?(:\d+)?$/i;
const SITE_LOCAL_PREFIXES = ['localhost:', '127.0.0.1:'];
const MIN_GRANT_TTL = 7;

export const SubscribeServiceModal: React.FC<SubscribeServiceModalProps> = ({
  isOpen,
  onClose,
  peerId,
  offering,
  onSubscribed,
}) => {
  const [localHostname, setLocalHostname] = useState('');
  const [ttlDays, setTtlDays] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!isOpen) return;
    setLocalHostname('');
    setTtlDays(offering ? String(offering.default_grant_ttl_days) : '30');
    setError(null);
  }, [isOpen, offering]);

  const validation = useMemo(() => {
    const errors: string[] = [];
    if (!localHostname.trim()) errors.push('Local hostname is required.');
    else if (!HOSTNAME_PATTERN.test(localHostname.trim())) {
      errors.push('Hostname looks malformed. Examples: git.alice.tld, localhost:5432.');
    }
    if (ttlDays.trim() !== '') {
      const t = parseInt(ttlDays, 10);
      if (!Number.isFinite(t) || t < MIN_GRANT_TTL) {
        errors.push(`TTL must be ≥ ${MIN_GRANT_TTL} days (or blank for offering default).`);
      }
    }
    return { ok: errors.length === 0, errors };
  }, [localHostname, ttlDays]);

  const isSiteLocal = useMemo(
    () => SITE_LOCAL_PREFIXES.some((p) => localHostname.startsWith(p)),
    [localHostname],
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validation.ok || !offering) {
      setError(validation.errors[0] ?? 'Form invalid');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const sub = await serviceCatalogApi.subscribeToPeer(peerId, {
        slug: offering.slug,
        local_hostname: localHostname.trim(),
        ttl_days: ttlDays.trim() === '' ? undefined : parseInt(ttlDays, 10),
      });
      onSubscribed?.(sub);
      onClose();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Subscribe failed');
    } finally {
      setSubmitting(false);
    }
  };

  if (!offering) return null;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <div className="flex items-center gap-2">
          <Server className="w-5 h-5 text-theme-info" />
          <span>Subscribe to {offering.name}</span>
        </div>
      }
      maxWidth="lg"
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="ghost" onClick={onClose} disabled={submitting}>
            Cancel
          </Button>
          <Button variant="primary" onClick={handleSubmit} disabled={submitting || !validation.ok}>
            {submitting ? 'Subscribing…' : 'Subscribe'}
          </Button>
        </div>
      }
    >
      <form onSubmit={handleSubmit} className="space-y-4">
        {error && (
          <div className="p-2 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm rounded">
            <AlertCircle className="w-4 h-4 flex-shrink-0" />
            <span className="flex-1">{error}</span>
            <button type="button" onClick={() => setError(null)} className="p-1">
              <X className="w-3 h-3" />
            </button>
          </div>
        )}

        <div className="bg-theme-background-secondary p-3 rounded text-sm space-y-1">
          <div className="flex items-baseline gap-2">
            <span className="text-theme-secondary text-xs uppercase tracking-wide">Service</span>
            <span className="font-mono">{offering.slug}</span>
          </div>
          <div className="flex items-baseline gap-2">
            <span className="text-theme-secondary text-xs uppercase tracking-wide">Protocol</span>
            <span className="font-mono">{offering.protocol}</span>
            <span className="text-theme-secondary">:{offering.backend_port}</span>
          </div>
          {offering.latency_metadata.p50_ms !== undefined && (
            <div className="flex items-baseline gap-2 text-xs text-theme-secondary">
              <span>Latency: p50 {offering.latency_metadata.p50_ms}ms</span>
              {offering.latency_metadata.p95_ms !== undefined && (
                <span>· p95 {offering.latency_metadata.p95_ms}ms</span>
              )}
            </div>
          )}
        </div>

        <div>
          <label className="block text-xs font-medium text-theme-secondary mb-1">Local Hostname</label>
          <input
            type="text"
            value={localHostname}
            onChange={(e) => setLocalHostname(e.target.value.trim())}
            disabled={submitting}
            required
            placeholder="git.alice.tld or localhost:5432"
            className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
          />
          <p className="text-xs text-theme-secondary mt-1">
            {isSiteLocal ? (
              <>
                <strong>Site-local TCP forward:</strong> service exposed on loopback only; no public cert needed.
              </>
            ) : (
              <>
                Public hostname Traefik will serve.{' '}
                {offering.protocol === 'https' || offering.protocol === 'tls' ? (
                  <>
                    An ACME cert will be issued via DNS-01.
                  </>
                ) : (
                  <>No TLS termination (protocol: {offering.protocol}).</>
                )}
              </>
            )}
          </p>
        </div>

        <div>
          <label className="block text-xs font-medium text-theme-secondary mb-1">
            Grant TTL (days)
          </label>
          <input
            type="number"
            min={MIN_GRANT_TTL}
            max={365}
            value={ttlDays}
            onChange={(e) => setTtlDays(e.target.value)}
            disabled={submitting}
            className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
          />
          <p className="text-xs text-theme-secondary mt-1">
            How long the operator's grant remains valid before requiring renewal. Default from offering:
            {' '}{offering.default_grant_ttl_days} days.
          </p>
        </div>

        {offering.subscription_terms_markdown && (
          <div>
            <label className="block text-xs font-medium text-theme-secondary mb-1">
              Subscription Terms <ExternalLink className="w-3 h-3 inline ml-0.5 align-text-bottom" />
            </label>
            <div className="text-xs text-theme-secondary bg-theme-background-secondary p-2 rounded max-h-32 overflow-y-auto whitespace-pre-wrap">
              {offering.subscription_terms_markdown}
            </div>
          </div>
        )}
      </form>
    </Modal>
  );
};
