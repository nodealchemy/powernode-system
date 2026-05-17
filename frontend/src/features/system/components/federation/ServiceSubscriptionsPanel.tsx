import React, { useCallback, useEffect, useState } from 'react';
import { Globe2, Network as NetworkIcon, AlertTriangle, X, Server, Clock } from 'lucide-react';
import { serviceCatalogApi } from '../../services/api/serviceCatalogApi';
import type {
  ServiceSubscription,
  SubscriptionStatus,
  ServiceProtocol,
} from '../../types/service_delivery.types';

/**
 * Subscriber-side panel: list this platform's active subscriptions
 * to remote peers' services. Read + cancel; CREATE happens via the
 * per-peer catalog browser (P4.6.8e).
 *
 * Plan reference: Decentralized Federation §L.7 + P4.6.8.
 */

interface ServiceSubscriptionsPanelProps {
  initialStatusFilter?: SubscriptionStatus | null;
  // Scope to subscriptions with a specific peer (for the per-peer
  // detail view). Omit to show all subscriptions.
  peerIdFilter?: string;
  refreshKey?: number;
  onSelect?: (sub: ServiceSubscription) => void;
}

export const ServiceSubscriptionsPanel: React.FC<ServiceSubscriptionsPanelProps> = ({
  initialStatusFilter = null,
  peerIdFilter,
  refreshKey = 0,
  onSelect,
}) => {
  const [subs, setSubs] = useState<ServiceSubscription[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<SubscriptionStatus | null>(initialStatusFilter);
  const [cancellingId, setCancellingId] = useState<string | null>(null);

  const fetchSubs = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await serviceCatalogApi.listSubscriptions({
        status: statusFilter ?? undefined,
        peer_id: peerIdFilter,
      });
      setSubs(result.subscriptions);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load subscriptions');
    } finally {
      setLoading(false);
    }
  }, [statusFilter, peerIdFilter]);

  useEffect(() => {
    void fetchSubs();
  }, [fetchSubs, refreshKey]);

  const handleCancel = async (sub: ServiceSubscription) => {
    const reason = window.prompt(
      `Cancel subscription to "${sub.service_offering_slug}" on ${sub.local_hostname}?\n\n` +
        'This revokes the federation grant and removes the Traefik route. ' +
        'Provide an optional reason:',
      '',
    );
    if (reason === null) return; // user cancelled the prompt itself

    setCancellingId(sub.id);
    try {
      await serviceCatalogApi.cancelSubscription(sub.id, reason || undefined);
      await fetchSubs();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to cancel subscription');
    } finally {
      setCancellingId(null);
    }
  };

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Server className="w-5 h-5 text-theme-info" />
          <h2 className="font-semibold text-theme-primary">Service Subscriptions</h2>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${subs.length} ${subs.length === 1 ? 'subscription' : 'subscriptions'}`}
          </span>
        </div>
        <StatusFilterBar value={statusFilter} onChange={setStatusFilter} />
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

      {!loading && subs.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm">
          No active subscriptions. Browse a federated peer's catalog to subscribe to their services.
        </div>
      )}

      {subs.length > 0 && (
        <table className="w-full text-sm">
          <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
            <tr>
              <th className="text-left px-4 py-2 font-medium">Service / Host</th>
              <th className="text-left px-4 py-2 font-medium">Peer</th>
              <th className="text-left px-4 py-2 font-medium">Protocol</th>
              <th className="text-left px-4 py-2 font-medium">Status</th>
              <th className="text-left px-4 py-2 font-medium">Active Since</th>
              <th className="text-right px-4 py-2 font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {subs.map((sub) => (
              <SubscriptionRow
                key={sub.id}
                subscription={sub}
                onSelect={onSelect}
                onCancel={() => handleCancel(sub)}
                isCancelling={cancellingId === sub.id}
              />
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
};

interface SubscriptionRowProps {
  subscription: ServiceSubscription;
  onSelect?: (sub: ServiceSubscription) => void;
  onCancel: () => void;
  isCancelling: boolean;
}

const SubscriptionRow: React.FC<SubscriptionRowProps> = ({
  subscription,
  onSelect,
  onCancel,
  isCancelling,
}) => {
  const isTerminal = subscription.status === 'cancelled';
  const protoIcon = protocolIcon(subscription.protocol);

  return (
    <tr
      className={`border-t border-theme ${onSelect ? 'cursor-pointer hover:bg-theme-surface-hover' : ''}`}
      onClick={() => onSelect?.(subscription)}
    >
      <td className="px-4 py-3">
        <div className="font-medium text-theme-primary">{subscription.service_offering_slug}</div>
        <div className="text-xs text-theme-secondary font-mono">
          {subscription.site_local ? '(site-local)' : ''} {subscription.local_hostname}
        </div>
      </td>
      <td className="px-4 py-3 text-theme-secondary text-xs font-mono">
        {subscription.federation_peer_id.slice(0, 8)}…
      </td>
      <td className="px-4 py-3 text-theme-secondary">
        <div className="inline-flex items-center gap-1.5">
          {protoIcon}
          <span className="font-mono text-xs">{subscription.protocol}</span>
        </div>
      </td>
      <td className="px-4 py-3">
        <StatusPill status={subscription.status} />
      </td>
      <td className="px-4 py-3 text-theme-secondary text-xs">
        {subscription.activated_at ? (
          <span className="inline-flex items-center gap-1">
            <Clock className="w-3 h-3" />
            {new Date(subscription.activated_at).toLocaleDateString()}
          </span>
        ) : (
          <span className="text-theme-tertiary">—</span>
        )}
      </td>
      <td className="px-4 py-3 text-right" onClick={(e) => e.stopPropagation()}>
        {!isTerminal && (
          <button
            type="button"
            onClick={onCancel}
            disabled={isCancelling}
            title="Cancel subscription"
            className="px-2 py-1 rounded text-xs text-theme-danger hover:bg-theme-danger disabled:opacity-40"
          >
            {isCancelling ? 'Cancelling…' : 'Cancel'}
          </button>
        )}
      </td>
    </tr>
  );
};

// ─── Small bits ────────────────────────────────────────────────────────

const STATUS_FILTERS: Array<{ value: SubscriptionStatus | null; label: string }> = [
  { value: null, label: 'All' },
  { value: 'active', label: 'Active' },
  { value: 'pending', label: 'Pending' },
  { value: 'suspended', label: 'Suspended' },
  { value: 'cancelled', label: 'Cancelled' },
];

const StatusFilterBar: React.FC<{
  value: SubscriptionStatus | null;
  onChange: (v: SubscriptionStatus | null) => void;
}> = ({ value, onChange }) => (
  <div className="inline-flex items-center gap-1 text-xs">
    {STATUS_FILTERS.map((f) => (
      <button
        type="button"
        key={f.label}
        onClick={() => onChange(f.value)}
        className={`px-2 py-1 rounded ${
          value === f.value
            ? 'bg-theme-info-solid text-white'
            : 'text-theme-secondary hover:bg-theme-surface-hover'
        }`}
      >
        {f.label}
      </button>
    ))}
  </div>
);

const StatusPill: React.FC<{ status: SubscriptionStatus }> = ({ status }) => {
  const styleByStatus: Record<SubscriptionStatus, string> = {
    pending: 'bg-theme-background-tertiary text-theme-secondary',
    active: 'bg-theme-success text-theme-success',
    suspended: 'bg-theme-warning text-theme-warning',
    cancelled: 'bg-theme-danger text-theme-danger',
  };
  return (
    <span
      className={`inline-block px-2 py-0.5 rounded text-xs font-medium ${styleByStatus[status]}`}
    >
      {status}
    </span>
  );
};

function protocolIcon(protocol: ServiceProtocol): React.ReactNode {
  switch (protocol) {
    case 'https':
    case 'http':
      return <Globe2 className="w-3.5 h-3.5" />;
    case 'tcp':
    case 'tls':
      return <NetworkIcon className="w-3.5 h-3.5" />;
  }
}
