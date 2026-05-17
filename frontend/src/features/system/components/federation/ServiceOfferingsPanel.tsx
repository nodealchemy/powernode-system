import React, { useCallback, useEffect, useState } from 'react';
import { Globe2, Network as NetworkIcon, Server, Trash2, PauseCircle, PlayCircle, AlertTriangle } from 'lucide-react';
import { serviceCatalogApi } from '../../services/api/serviceCatalogApi';
import type {
  ServiceOffering,
  OfferingStatus,
  ServiceProtocol,
} from '../../types/service_delivery.types';

/**
 * Operator-side panel: list + manage this platform's federated
 * service offerings. Subscribers browse this catalog via the
 * federation_api/service_catalog endpoint after peering.
 *
 * Plan reference: Decentralized Federation §L.7 + P4.6.8.
 */

interface ServiceOfferingsPanelProps {
  // Optional: filter on initial load (e.g. "active" tab only).
  initialStatusFilter?: OfferingStatus | null;
  // Triggers a re-fetch when bumped (e.g. after a successful create
  // from a parent-managed modal).
  refreshKey?: number;
  // Optional callback for "New Offering" click; the parent typically
  // opens a creation modal.
  onCreateClick?: () => void;
  // Optional callback when a row is clicked (for nav to detail view).
  onSelect?: (offering: ServiceOffering) => void;
}

export const ServiceOfferingsPanel: React.FC<ServiceOfferingsPanelProps> = ({
  initialStatusFilter = null,
  refreshKey = 0,
  onCreateClick,
  onSelect,
}) => {
  const [offerings, setOfferings] = useState<ServiceOffering[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<OfferingStatus | null>(initialStatusFilter);
  const [actingOnId, setActingOnId] = useState<string | null>(null);

  const fetchOfferings = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await serviceCatalogApi.listOfferings(
        statusFilter ? { status: statusFilter } : undefined,
      );
      setOfferings(result.offerings);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load offerings');
    } finally {
      setLoading(false);
    }
  }, [statusFilter]);

  useEffect(() => {
    void fetchOfferings();
  }, [fetchOfferings, refreshKey]);

  const handleTransition = async (
    offering: ServiceOffering,
    action: 'activate' | 'deprecate' | 'retire',
  ) => {
    setActingOnId(offering.id);
    try {
      switch (action) {
        case 'activate':
          await serviceCatalogApi.activateOffering(offering.id);
          break;
        case 'deprecate':
          await serviceCatalogApi.deprecateOffering(offering.id);
          break;
        case 'retire':
          await serviceCatalogApi.retireOffering(offering.id);
          break;
      }
      await fetchOfferings();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : `Failed to ${action} offering`);
    } finally {
      setActingOnId(null);
    }
  };

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Server className="w-5 h-5 text-theme-info" />
          <h2 className="font-semibold text-theme-primary">Service Offerings</h2>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${offerings.length} ${offerings.length === 1 ? 'offering' : 'offerings'}`}
          </span>
        </div>
        <div className="flex items-center gap-2">
          <StatusFilterBar value={statusFilter} onChange={setStatusFilter} />
          {onCreateClick && (
            <button
              type="button"
              onClick={onCreateClick}
              className="px-3 py-1.5 text-sm bg-theme-info-solid text-white rounded hover:opacity-90"
            >
              New Offering
            </button>
          )}
        </div>
      </header>

      {error && (
        <div className="p-3 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm">
          <AlertTriangle className="w-4 h-4" />
          <span>{error}</span>
        </div>
      )}

      {!loading && offerings.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm">
          No offerings yet. Publishing one makes it visible to federated peers in the
          catalog endpoint.
        </div>
      )}

      {offerings.length > 0 && (
        <table className="w-full text-sm">
          <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
            <tr>
              <th className="text-left px-4 py-2 font-medium">Name / Slug</th>
              <th className="text-left px-4 py-2 font-medium">Protocol</th>
              <th className="text-left px-4 py-2 font-medium">Backend</th>
              <th className="text-left px-4 py-2 font-medium">Status</th>
              <th className="text-left px-4 py-2 font-medium">Subscribers</th>
              <th className="text-right px-4 py-2 font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {offerings.map((offering) => (
              <OfferingRow
                key={offering.id}
                offering={offering}
                onSelect={onSelect}
                onTransition={(action) => handleTransition(offering, action)}
                isActing={actingOnId === offering.id}
              />
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
};

interface OfferingRowProps {
  offering: ServiceOffering;
  onSelect?: (offering: ServiceOffering) => void;
  onTransition: (action: 'activate' | 'deprecate' | 'retire') => void;
  isActing: boolean;
}

const OfferingRow: React.FC<OfferingRowProps> = ({ offering, onSelect, onTransition, isActing }) => {
  const isRetired = offering.status === 'retired';
  const protoIcon = protocolIcon(offering.protocol);

  return (
    <tr
      className={`border-t border-theme ${onSelect ? 'cursor-pointer hover:bg-theme-surface-hover' : ''}`}
      onClick={() => onSelect?.(offering)}
    >
      <td className="px-4 py-3">
        <div className="font-medium text-theme-primary">{offering.name}</div>
        <div className="text-xs text-theme-secondary font-mono">{offering.slug}</div>
      </td>
      <td className="px-4 py-3 text-theme-secondary">
        <div className="inline-flex items-center gap-1.5">
          {protoIcon}
          <span className="font-mono text-xs">{offering.protocol}</span>
        </div>
      </td>
      <td className="px-4 py-3 text-theme-secondary text-xs font-mono">
        {backendLabel(offering)}
      </td>
      <td className="px-4 py-3">
        <StatusPill status={offering.status} />
      </td>
      <td className="px-4 py-3 text-theme-secondary">
        {offering.active_subscription_count}
        {offering.capacity_metadata.max_subscribers !== undefined && (
          <span className="text-xs"> / {offering.capacity_metadata.max_subscribers}</span>
        )}
      </td>
      <td className="px-4 py-3 text-right" onClick={(e) => e.stopPropagation()}>
        <div className="inline-flex items-center gap-1">
          {offering.status === 'draft' && (
            <ActionButton
              icon={<PlayCircle className="w-4 h-4" />}
              label="Activate"
              onClick={() => onTransition('activate')}
              disabled={isActing}
            />
          )}
          {offering.status === 'active' && (
            <ActionButton
              icon={<PauseCircle className="w-4 h-4" />}
              label="Deprecate"
              onClick={() => onTransition('deprecate')}
              disabled={isActing}
            />
          )}
          {offering.status === 'deprecated' && (
            <ActionButton
              icon={<PlayCircle className="w-4 h-4" />}
              label="Reactivate"
              onClick={() => onTransition('activate')}
              disabled={isActing}
            />
          )}
          {!isRetired && (
            <ActionButton
              icon={<Trash2 className="w-4 h-4" />}
              label="Retire"
              onClick={() => onTransition('retire')}
              disabled={isActing}
              danger
            />
          )}
        </div>
      </td>
    </tr>
  );
};

// ─── Small composable bits ─────────────────────────────────────────────

const STATUS_FILTERS: Array<{ value: OfferingStatus | null; label: string }> = [
  { value: null, label: 'All' },
  { value: 'draft', label: 'Draft' },
  { value: 'active', label: 'Active' },
  { value: 'deprecated', label: 'Deprecated' },
  { value: 'retired', label: 'Retired' },
];

const StatusFilterBar: React.FC<{
  value: OfferingStatus | null;
  onChange: (v: OfferingStatus | null) => void;
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

const StatusPill: React.FC<{ status: OfferingStatus }> = ({ status }) => {
  const styleByStatus: Record<OfferingStatus, string> = {
    draft: 'bg-theme-background-tertiary text-theme-secondary',
    active: 'bg-theme-success text-theme-success',
    deprecated: 'bg-theme-warning text-theme-warning',
    retired: 'bg-theme-danger text-theme-danger',
  };
  return (
    <span
      className={`inline-block px-2 py-0.5 rounded text-xs font-medium ${styleByStatus[status]}`}
    >
      {status}
    </span>
  );
};

interface ActionButtonProps {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  danger?: boolean;
}

const ActionButton: React.FC<ActionButtonProps> = ({ icon, label, onClick, disabled, danger }) => (
  <button
    type="button"
    onClick={onClick}
    disabled={disabled}
    title={label}
    className={`px-2 py-1 rounded text-xs inline-flex items-center gap-1 ${
      danger
        ? 'text-theme-danger hover:bg-theme-danger'
        : 'text-theme-secondary hover:bg-theme-surface-hover'
    } disabled:opacity-40 disabled:cursor-not-allowed`}
  >
    {icon}
    <span>{label}</span>
  </button>
);

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

function backendLabel(offering: ServiceOffering): string {
  if (offering.backend_vip_id) {
    return `vip:${offering.backend_vip_id.slice(0, 8)}…:${offering.backend_port}`;
  }
  if (offering.backend_host) {
    return `${offering.backend_host}:${offering.backend_port}`;
  }
  return `<unset>:${offering.backend_port}`;
}
