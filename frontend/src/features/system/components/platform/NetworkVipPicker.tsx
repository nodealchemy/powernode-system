import React, { useEffect, useState } from 'react';
import { Network as NetworkIcon, AlertTriangle } from 'lucide-react';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type { SdwanNetwork } from '@system/features/system/types/sdwan.types';
import { NetworkVipsTab } from '../sdwan/vips/NetworkVipsTab';

/**
 * NetworkVipPicker — a per-network selector that renders the existing
 * NetworkVipsTab for the chosen SDWAN network. VIPs are the federation
 * hub's service-discovery substrate (first-class addresses peers claim on
 * loopback, advertised via iBGP), but they're scoped per-network — there is
 * no system-wide VIP endpoint. So we mirror CatalogBrowserTab's peer-selector
 * pattern: pick a network, then drill into its VIP surface.
 *
 * Composition only — VIP CRUD + failover live entirely in the reused
 * NetworkVipsTab (which gates its own mutations on `sdwan.vips.manage`). When
 * `readOnly` is set the picker hides the tab's create action handle so the
 * Monitor tab shows liveness without mutation affordances.
 *
 * Plan reference: Phase 3 (Federation & Multi-Site) — service discovery (VIPs).
 */

interface NetworkVipPickerProps {
  /** When true, suppress the create action handle (Monitor view). */
  readOnly?: boolean;
}

export const NetworkVipPicker: React.FC<NetworkVipPickerProps> = ({ readOnly = false }) => {
  const [networks, setNetworks] = useState<SdwanNetwork[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    sdwanApi
      .getNetworks({ per_page: 200 })
      .then((resp) => {
        if (cancelled) return;
        setNetworks(resp.networks);
        if (resp.networks.length > 0) setSelectedId(resp.networks[0].id);
      })
      .catch((err: unknown) => {
        if (!cancelled) setError(err instanceof Error ? err.message : 'Failed to load networks');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (loading) {
    return <div className="p-4 text-theme-secondary text-sm">Loading networks…</div>;
  }

  if (error) {
    return (
      <div className="p-3 bg-theme-danger-bg text-theme-danger-fg flex items-center gap-2 text-sm rounded">
        <AlertTriangle className="w-4 h-4" />
        <span>{error}</span>
      </div>
    );
  }

  if (networks.length === 0) {
    return (
      <div className="p-12 text-center text-theme-secondary text-sm">
        No SDWAN networks yet. Create one in the SDWAN hub to start advertising virtual IPs.
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="bg-theme-surface border border-theme rounded-lg p-3 flex items-center gap-3">
        <NetworkIcon className="w-4 h-4 text-theme-secondary" />
        <label htmlFor="vip-network-select" className="text-sm text-theme-secondary">
          Network:
        </label>
        <select
          id="vip-network-select"
          value={selectedId ?? ''}
          onChange={(e) => setSelectedId(e.target.value)}
          className="flex-1 px-2 py-1 border border-theme rounded bg-theme-background-secondary text-theme-primary text-sm"
        >
          {networks.map((n) => (
            <option key={n.id} value={n.id}>
              {n.name} ({n.cidr_64})
            </option>
          ))}
        </select>
      </div>

      {selectedId && (
        // readOnly: pass a no-op onActionsReady so NetworkVipsTab doesn't
        // surface a create handle to a parent that isn't wired for it. The
        // tab's own row-level mutations still respect sdwan.vips.manage.
        <NetworkVipsTab key={selectedId} networkId={selectedId} onActionsReady={readOnly ? () => {} : undefined} />
      )}
    </div>
  );
};

export default NetworkVipPicker;
