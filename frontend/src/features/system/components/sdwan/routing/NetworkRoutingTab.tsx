import React, { useState, useEffect, useCallback } from 'react';
import { Route, Wifi, AlertTriangle } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Modal } from '@/shared/components/ui/Modal';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanNetwork, SdwanPeer } from '../../../types/sdwan.types';
import { BgpSessionsTable } from './BgpSessionsTable';

interface NetworkRoutingTabProps {
  network: SdwanNetwork;
  onNetworkUpdated?: (network: SdwanNetwork) => void;
  // Slice 9d2 — page-owned action handle (matches "Actions ALL in
  // PageContainer" rule). Parent page wires the "Change routing mode"
  // button into PageContainer.actions when this tab is active.
  onActionsReady?: (handle: { openModeToggle: () => void } | null) => void;
}

export const NetworkRoutingTab: React.FC<NetworkRoutingTabProps> = ({ network, onNetworkUpdated, onActionsReady }) => {
  // Permission gating happens at the parent page (PageContainer.actions);
  // this tab is purely presentational + modal owner.
  const { addNotification } = useNotifications();

  const [peers, setPeers] = useState<SdwanPeer[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showModeToggle, setShowModeToggle] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const peerResult = await sdwanApi.getPeers(network.id);
      setPeers(peerResult.peers);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load routing data');
    } finally {
      setLoading(false);
    }
  }, [network.id]);

  useEffect(() => {
    load();
  }, [load, refreshKey]);

  useEffect(() => {
    onActionsReady?.({ openModeToggle: () => setShowModeToggle(true) });
    return () => onActionsReady?.(null);
  }, [onActionsReady]);

  const handleModeToggle = async (newMode: 'static' | 'ibgp') => {
    try {
      // routing_protocol isn't in SdwanNetworkCreate — cast to unknown then
      // the looser shape so this compiles without changing the existing
      // Partial<SdwanNetworkCreate & {status}> contract throughout the API.
      const updated = await sdwanApi.updateNetwork(
        network.id,
        { routing_protocol: newMode } as unknown as Parameters<typeof sdwanApi.updateNetwork>[1]
      );
      onNetworkUpdated?.(updated);
      setShowModeToggle(false);
      addNotification?.({
        type: 'success',
        message: `Network routing mode changed to ${newMode}.`,
      });
      setRefreshKey((k) => k + 1);
    } catch (err) {
      addNotification?.({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to change routing mode',
      });
    }
  };

  const hubPeers = peers.filter((p) => p.publicly_reachable);
  const totalLanSubnets = peers.reduce((sum, p) => sum + (p.lan_subnets?.length ?? 0), 0);

  if (loading) return <div className="p-4 text-theme-secondary">Loading routing data…</div>;
  if (error) return <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>;

  return (
    <div className="space-y-5">
      {/* Mode banner — read-only summary; "Change mode" button lives in
          the page's PageContainer.actions per "Actions ALL in
          PageContainer" rule. */}
      <div className="flex items-center gap-3 p-3 bg-theme-surface rounded border border-theme">
        <Route size={20} className="text-theme-secondary" />
        <div className="flex-1">
          <div className="text-sm font-medium text-theme-primary">
            Routing protocol: <span className="font-mono">{network.routing_protocol ?? 'static'}</span>
          </div>
          <div className="text-xs text-theme-secondary mt-0.5">
            {(network.routing_protocol ?? 'static') === 'static'
              ? 'Static — declared LAN subnets and VIP CIDRs are folded into peer AllowedIPs at compile time. No FRR daemon.'
              : 'iBGP — FRR daemon distributes routes dynamically across the overlay. Hubs become route reflectors.'}
          </div>
        </div>
      </div>

      {/* Per-peer LAN subnet summary */}
      <div className="bg-theme-surface rounded border border-theme">
        <div className="p-3 border-b border-theme flex items-center justify-between">
          <div>
            <h4 className="text-sm font-semibold text-theme-primary">External prefixes (LAN subnets)</h4>
            <p className="text-xs text-theme-secondary mt-0.5">
              Operator-declared external prefixes per peer. Edit per-peer via the Peers tab.
            </p>
          </div>
          <div className="text-xs text-theme-secondary">
            {totalLanSubnets} prefix{totalLanSubnets === 1 ? '' : 'es'}
          </div>
        </div>
        {peers.length === 0 ? (
          <div className="p-4 text-center text-sm text-theme-secondary">No peers in this network yet.</div>
        ) : (
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-theme-secondary border-b border-theme">
                <th className="px-3 py-2">Peer</th>
                <th className="px-3 py-2">Role</th>
                <th className="px-3 py-2">Overlay /128</th>
                <th className="px-3 py-2">Declared subnets</th>
              </tr>
            </thead>
            <tbody>
              {peers.map((p) => (
                <tr key={p.id} className="border-b border-theme last:border-0">
                  <td className="px-3 py-2 font-medium">{p.node_instance_id?.slice(0, 8) ?? p.id.slice(0, 8)}</td>
                  <td className="px-3 py-2 text-xs">
                    <span className="inline-flex items-center gap-1">
                      <Wifi size={12} className={p.publicly_reachable ? 'text-theme-success' : 'text-theme-secondary'} />
                      {p.publicly_reachable ? 'Hub' : 'Spoke'}
                    </span>
                  </td>
                  <td className="px-3 py-2 font-mono text-xs text-theme-secondary">{p.assigned_address}</td>
                  <td className="px-3 py-2">
                    {p.lan_subnets && p.lan_subnets.length > 0 ? (
                      <div className="flex flex-wrap gap-1">
                        {p.lan_subnets.map((cidr) => (
                          <span
                            key={cidr}
                            className="font-mono text-xs px-1.5 py-0.5 rounded bg-theme-background-secondary"
                          >
                            {cidr}
                          </span>
                        ))}
                      </div>
                    ) : (
                      <span className="text-xs text-theme-secondary">—</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* iBGP-only blocks */}
      {network.routing_protocol === 'ibgp' && (
        <>
          <div className="bg-theme-surface rounded border border-theme">
            <div className="p-3 border-b border-theme">
              <h4 className="text-sm font-semibold text-theme-primary">Route reflectors</h4>
              <p className="text-xs text-theme-secondary mt-0.5">
                Hubs (publicly reachable peers) become route reflectors by default. Configured redundancy:{' '}
                <span className="font-mono">{network.route_reflector_redundancy ?? 1}</span>.
              </p>
            </div>
            <div className="p-3">
              {hubPeers.length === 0 ? (
                <div className="flex items-start gap-2 p-2 bg-theme-warning/30 rounded text-sm">
                  <AlertTriangle size={16} className="text-theme-warning shrink-0 mt-0.5" />
                  <div className="text-theme-secondary">
                    No publicly reachable hubs. iBGP needs at least one route reflector — flag a peer as{' '}
                    <code className="font-mono text-xs">publicly_reachable: true</code> to elect it as RR.
                  </div>
                </div>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {hubPeers.map((p) => (
                    <div
                      key={p.id}
                      className="px-3 py-1.5 rounded bg-theme-background-secondary text-xs flex items-center gap-2"
                    >
                      <Wifi size={12} className="text-theme-success" />
                      {p.node_instance_id?.slice(0, 8) ?? p.id.slice(0, 8)} (RR)
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>

          <div className="bg-theme-surface rounded border border-theme p-3">
            <h4 className="text-sm font-semibold text-theme-primary mb-2">Live BGP sessions in this network</h4>
            <BgpSessionsTable networkId={network.id} refreshKey={refreshKey} />
          </div>

          <div className="bg-theme-surface rounded border border-theme p-3 text-xs text-theme-secondary">
            <div className="font-medium text-theme-primary mb-1">Advertisement audit trail</div>
            Slice 9f will surface the live <code className="font-mono">subnet_advertisements</code> table here —
            declared LAN subnets, VIP announcements, and iBGP-learned routes with their AS path and timestamps. For
            now, query via the MCP tool <code className="font-mono">system_sdwan_list_subnet_advertisements</code>.
          </div>
        </>
      )}

      {showModeToggle && (
        <Modal isOpen onClose={() => setShowModeToggle(false)} title="Change routing protocol" size="md">
          <div className="space-y-3">
            <p className="text-sm text-theme-primary">
              Switching modes recompiles every peer's WireGuard + FRR config on the next agent reconcile.
            </p>
            <div className="space-y-2">
              <Button
                variant={network.routing_protocol === 'static' ? 'primary' : 'secondary'}
                onClick={() => handleModeToggle('static')}
                disabled={network.routing_protocol === 'static'}
                className="w-full justify-start text-left"
              >
                <div>
                  <div className="font-medium">Static</div>
                  <div className="text-xs opacity-80">
                    LAN subnets + VIP CIDRs folded into AllowedIPs. No daemon. Simple, deterministic.
                  </div>
                </div>
              </Button>
              <Button
                variant={network.routing_protocol === 'ibgp' ? 'primary' : 'secondary'}
                onClick={() => handleModeToggle('ibgp')}
                disabled={network.routing_protocol === 'ibgp'}
                className="w-full justify-start text-left"
              >
                <div>
                  <div className="font-medium">iBGP (Free Range Routing)</div>
                  <div className="text-xs opacity-80">
                    Dynamic distribution via FRR. Hubs become route reflectors. Requires AS allocation
                    + frr package on each peer.
                  </div>
                </div>
              </Button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
};
