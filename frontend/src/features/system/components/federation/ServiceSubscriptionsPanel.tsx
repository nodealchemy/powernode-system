import React, { useCallback, useEffect, useState } from 'react';
import {
  Globe2,
  Network as NetworkIcon,
  Server,
  Clock,
  ChevronRight,
  ChevronDown,
} from 'lucide-react';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { EntityLink } from '@/shared/components/entity';
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
  const { addNotification } = useNotifications();
  const [subs, setSubs] = useState<ServiceSubscription[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState<SubscriptionStatus | null>(initialStatusFilter);
  const [cancellingId, setCancellingId] = useState<string | null>(null);
  // Click-to-expand state — Set<id> so multiple rows can be open at once.
  const [expandedIds, setExpandedIds] = useState<Set<string>>(new Set());
  // Full-detail cache, keyed by subscription id. The list endpoint returns a
  // summary shape; the show endpoint (getSubscription) adds backend_vip,
  // federation_grant_id, acme_certificate_id, and the *_at timestamps. We fetch
  // lazily on first expand and reuse the cached row thereafter.
  const [detailById, setDetailById] = useState<Record<string, ServiceSubscription>>({});
  const [detailLoadingId, setDetailLoadingId] = useState<string | null>(null);

  const fetchDetail = useCallback(
    async (sub: ServiceSubscription) => {
      if (detailById[sub.id]) return; // already loaded
      setDetailLoadingId(sub.id);
      try {
        const full = await serviceCatalogApi.getSubscription(sub.id);
        setDetailById((prev) => ({ ...prev, [sub.id]: full }));
      } catch (err: unknown) {
        addNotification({
          type: 'error',
          message: err instanceof Error ? err.message : 'Failed to load subscription detail',
        });
      } finally {
        setDetailLoadingId(null);
      }
    },
    [detailById, addNotification],
  );

  const toggleExpanded = useCallback(
    (sub: ServiceSubscription) => {
      setExpandedIds((prev) => {
        const next = new Set(prev);
        if (next.has(sub.id)) {
          next.delete(sub.id);
        } else {
          next.add(sub.id);
          void fetchDetail(sub);
        }
        return next;
      });
    },
    [fetchDetail],
  );

  const fetchSubs = useCallback(async () => {
    setLoading(true);
    try {
      const result = await serviceCatalogApi.listSubscriptions({
        status: statusFilter ?? undefined,
        peer_id: peerIdFilter,
      });
      setSubs(result.subscriptions);
    } catch (err: unknown) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to load subscriptions',
      });
    } finally {
      setLoading(false);
    }
  }, [statusFilter, peerIdFilter, addNotification]);

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
      addNotification({
        type: 'success',
        message: `Cancelled subscription to "${sub.service_offering_slug}"`,
      });
      await fetchSubs();
    } catch (err: unknown) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to cancel subscription',
      });
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

      {!loading && subs.length === 0 && (
        <div className="p-12 text-center text-theme-secondary text-sm">
          No active subscriptions. Browse a federated peer's catalog to subscribe to their services.
        </div>
      )}

      {subs.length > 0 && (
        <table className="w-full text-sm">
          <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
            <tr>
              <th className="w-8 px-2 py-2"></th>
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
                detail={detailById[sub.id]}
                onSelect={onSelect}
                onCancel={() => handleCancel(sub)}
                isCancelling={cancellingId === sub.id}
                expanded={expandedIds.has(sub.id)}
                onToggleExpand={() => toggleExpanded(sub)}
                detailLoading={detailLoadingId === sub.id}
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
  // Full-detail row from the show endpoint; undefined until lazily fetched on expand.
  detail?: ServiceSubscription;
  onSelect?: (sub: ServiceSubscription) => void;
  onCancel: () => void;
  isCancelling: boolean;
  expanded: boolean;
  onToggleExpand: () => void;
  detailLoading: boolean;
}

const SubscriptionRow: React.FC<SubscriptionRowProps> = ({
  subscription,
  detail,
  onSelect,
  onCancel,
  isCancelling,
  expanded,
  onToggleExpand,
  detailLoading,
}) => {
  const isTerminal = subscription.status === 'cancelled';
  const protoIcon = protocolIcon(subscription.protocol);
  // Prefer the fully-hydrated row (extra fields) once it has loaded.
  const view = detail ?? subscription;

  return (
    <>
    <tr
      className={`border-t border-theme ${onSelect ? 'cursor-pointer hover:bg-theme-surface-hover' : ''}`}
      onClick={() => onSelect?.(subscription)}
    >
      <td className="px-2 py-3 align-middle" onClick={(e) => e.stopPropagation()}>
        <button
          type="button"
          onClick={onToggleExpand}
          className="p-1 text-theme-secondary hover:text-theme-primary"
          title={expanded ? 'Collapse details' : 'Expand details'}
        >
          {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
        </button>
      </td>
      <td className="px-4 py-3">
        <div className="font-medium text-theme-primary">{subscription.service_offering_slug}</div>
        <div className="text-xs text-theme-secondary font-mono">
          {subscription.site_local ? '(site-local)' : ''} {subscription.local_hostname}
        </div>
      </td>
      <td className="px-4 py-3 text-theme-secondary text-xs font-mono" onClick={(e) => e.stopPropagation()}>
        <EntityLink
          type="platform_peer"
          id={subscription.federation_peer_id}
          label={`${subscription.federation_peer_id.slice(0, 8)}…`}
          className="font-mono text-xs"
        />
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
    {expanded && (
      <tr className="bg-theme-background border-b border-theme">
        <td></td>
        <td colSpan={6} className="px-4 py-3">
          {detailLoading && !detail ? (
            <p className="text-sm text-theme-secondary">Loading detail…</p>
          ) : (
            <div className="grid grid-cols-2 md:grid-cols-3 gap-3 text-sm">
              <div>
                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Local Hostname</label>
                <p className="text-theme-primary font-mono text-xs break-all">{view.local_hostname}</p>
              </div>
              <div>
                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Backend Port</label>
                <p className="text-theme-primary">{view.backend_port}</p>
              </div>
              <div>
                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Site Local</label>
                <p className="text-theme-primary">{view.site_local ? 'Yes' : 'No'}</p>
              </div>
              <div>
                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Peer</label>
                <EntityLink
                  type="platform_peer"
                  id={view.federation_peer_id}
                  label={view.federation_peer_id}
                  className="font-mono text-xs break-all"
                />
              </div>
              {view.backend_vip && (
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Backend VIP</label>
                  <p className="text-theme-primary font-mono text-xs break-all">{view.backend_vip}</p>
                </div>
              )}
              {view.federation_grant_id && (
                <div>
                  {/* federation_grant is not a registered EntityLink type → render as text. */}
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Federation Grant</label>
                  <p className="text-theme-primary font-mono text-xs break-all">{view.federation_grant_id}</p>
                </div>
              )}
              {view.acme_certificate_id && (
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">ACME Certificate</label>
                  <EntityLink
                    type="acme_certificate"
                    id={view.acme_certificate_id}
                    label={view.acme_certificate_id}
                    className="font-mono text-xs break-all"
                  />
                </div>
              )}
              <div>
                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Subscribed</label>
                <p className="text-theme-primary text-xs">{new Date(view.subscribed_at).toLocaleString()}</p>
              </div>
              {view.activated_at && (
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Activated</label>
                  <p className="text-theme-primary text-xs">{new Date(view.activated_at).toLocaleString()}</p>
                </div>
              )}
              {view.suspended_at && (
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Suspended</label>
                  <p className="text-theme-primary text-xs">{new Date(view.suspended_at).toLocaleString()}</p>
                </div>
              )}
              {view.cancelled_at && (
                <div>
                  <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Cancelled</label>
                  <p className="text-theme-primary text-xs">{new Date(view.cancelled_at).toLocaleString()}</p>
                </div>
              )}
              <div>
                <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Subscription ID</label>
                <p className="text-theme-primary font-mono text-xs break-all">{view.id}</p>
              </div>
            </div>
          )}
        </td>
      </tr>
    )}
    </>
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
