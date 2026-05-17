import React, { useCallback, useEffect, useState } from 'react';
import { Globe2, Network as NetworkIcon, AlertTriangle, X, Server, Plus } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { serviceCatalogApi } from '../../services/api/serviceCatalogApi';
import { SubscribeServiceModal } from './SubscribeServiceModal';
import type {
  RemoteCatalogOffering,
  ServiceProtocol,
  ServiceSubscription,
} from '../../types/service_delivery.types';

/**
 * Per-peer catalog browser: lists a federated peer's published
 * service offerings + lets the subscriber initiate a subscription
 * via the SubscribeServiceModal.
 *
 * Plan reference: Decentralized Federation §L.7 + P4.6.8e.
 */

interface PeerCatalogBrowserProps {
  peerId: string;
  peerLabel?: string;
  // Bumps re-fetch (e.g. after a successful subscribe in the parent).
  refreshKey?: number;
  // Called after a subscribe completes successfully — the parent
  // typically refreshes any "my subscriptions" panel.
  onSubscribed?: (sub: ServiceSubscription) => void;
}

export const PeerCatalogBrowser: React.FC<PeerCatalogBrowserProps> = ({
  peerId,
  peerLabel,
  refreshKey = 0,
  onSubscribed,
}) => {
  const [offerings, setOfferings] = useState<RemoteCatalogOffering[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [generatedAt, setGeneratedAt] = useState<string | null>(null);
  const [subscribingTo, setSubscribingTo] = useState<RemoteCatalogOffering | null>(null);

  const fetchCatalog = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await serviceCatalogApi.fetchPeerCatalog(peerId);
      setOfferings(result.offerings);
      setGeneratedAt(result.generated_at);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to fetch peer catalog');
      setOfferings([]);
    } finally {
      setLoading(false);
    }
  }, [peerId]);

  useEffect(() => {
    void fetchCatalog();
  }, [fetchCatalog, refreshKey]);

  const handleSubscribed = (sub: ServiceSubscription) => {
    onSubscribed?.(sub);
    setSubscribingTo(null);
    // No need to re-fetch the catalog — subscribe doesn't change the
    // remote catalog state.
  };

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Server className="w-5 h-5 text-theme-info" />
          <h2 className="font-semibold text-theme-primary">
            {peerLabel ?? 'Peer'} Service Catalog
          </h2>
          <span className="text-xs text-theme-secondary font-mono">
            {peerId.slice(0, 8)}…
          </span>
        </div>
        <div className="flex items-center gap-2 text-xs text-theme-secondary">
          {generatedAt && (
            <span>
              Generated {new Date(generatedAt).toLocaleString()}
            </span>
          )}
          <button
            type="button"
            onClick={() => void fetchCatalog()}
            className="px-2 py-1 rounded hover:bg-theme-surface-hover"
            disabled={loading}
          >
            {loading ? 'refreshing…' : 'Refresh'}
          </button>
        </div>
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

      {!loading && offerings.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm">
          This peer has not published any active offerings yet.
        </div>
      )}

      {offerings.length > 0 && (
        <ul className="divide-y divide-theme">
          {offerings.map((offering) => (
            <OfferingCard
              key={offering.slug}
              offering={offering}
              onSubscribe={() => setSubscribingTo(offering)}
            />
          ))}
        </ul>
      )}

      <SubscribeServiceModal
        isOpen={subscribingTo !== null}
        onClose={() => setSubscribingTo(null)}
        peerId={peerId}
        offering={subscribingTo}
        onSubscribed={handleSubscribed}
      />
    </div>
  );
};

interface OfferingCardProps {
  offering: RemoteCatalogOffering;
  onSubscribe: () => void;
}

const OfferingCard: React.FC<OfferingCardProps> = ({ offering, onSubscribe }) => {
  const protoIcon = protocolIcon(offering.protocol);
  const subscribable = offering.accepting_new_subscriptions;

  return (
    <li className="px-4 py-3 flex items-start gap-3">
      <div className="flex-shrink-0 mt-0.5">{protoIcon}</div>
      <div className="flex-1 min-w-0">
        <div className="flex items-baseline gap-2">
          <span className="font-medium text-theme-primary">{offering.name}</span>
          <span className="text-xs text-theme-secondary font-mono">{offering.slug}</span>
          {offering.status === 'deprecated' && (
            <span className="text-xs px-1.5 py-0.5 rounded bg-theme-warning text-theme-warning">
              deprecated
            </span>
          )}
        </div>
        {offering.description_markdown && (
          <p className="text-xs text-theme-secondary mt-1 line-clamp-2 whitespace-pre-wrap">
            {offering.description_markdown}
          </p>
        )}
        <div className="flex items-center gap-3 text-xs text-theme-secondary mt-1 font-mono">
          <span>
            {offering.protocol}:{offering.backend_port}
          </span>
          <span>·</span>
          <span>TTL {offering.default_grant_ttl_days}d</span>
          <span>·</span>
          <span>scopes: {offering.default_grant_scopes.join(', ')}</span>
          {offering.capacity_metadata.max_subscribers !== undefined && (
            <>
              <span>·</span>
              <span>cap {offering.capacity_metadata.max_subscribers}</span>
            </>
          )}
        </div>
      </div>
      <div className="flex-shrink-0">
        <Button
          variant={subscribable ? 'primary' : 'ghost'}
          onClick={onSubscribe}
          disabled={!subscribable}
        >
          <Plus className="w-4 h-4" />
          {subscribable ? 'Subscribe' : 'Closed'}
        </Button>
      </div>
    </li>
  );
};

function protocolIcon(protocol: ServiceProtocol): React.ReactNode {
  switch (protocol) {
    case 'https':
    case 'http':
      return <Globe2 className="w-4 h-4 text-theme-secondary" />;
    case 'tcp':
    case 'tls':
      return <NetworkIcon className="w-4 h-4 text-theme-secondary" />;
  }
}
