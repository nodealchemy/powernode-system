import React, { useEffect, useState, useCallback } from 'react';
import { Network as NetworkIcon, Users } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { sdwanApi } from '../../services/api/sdwanApi';
import type {
  SdwanNetwork,
  SdwanPeer,
} from '../../types/sdwan.types';

interface NetworkDetailModalProps {
  network: SdwanNetwork | null;
  isOpen: boolean;
  onClose: () => void;
}

/**
 * NetworkDetailModal — richer detail surface for an SDWAN network,
 * shown as a modal so operators don't lose their place in the network
 * list. Replaces row-click → page navigate from the prior NetworkList
 * behavior.
 *
 * Fetches the latest network detail + peer list when opened. Skips
 * firewall + VIPs + port mappings + routing — those remain in the full
 * /app/system/sdwan/networks/:id detail page for advanced ops, since
 * surfacing all 7 sub-tabs in a modal would force a re-implementation
 * of the page in modal layout.
 *
 * The detail page route still exists and is bookmarkable; a "View in
 * full page" link at the bottom of the modal takes operators there
 * when they need the full management surface.
 */
export const NetworkDetailModal: React.FC<NetworkDetailModalProps> = ({
  network,
  isOpen,
  onClose,
}) => {
  const [detail, setDetail] = useState<SdwanNetwork | null>(null);
  const [peers, setPeers] = useState<SdwanPeer[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async (id: string) => {
    try {
      setLoading(true);
      setError(null);
      const [networkData, peersData] = await Promise.all([
        sdwanApi.getNetwork(id),
        sdwanApi.getPeers(id),
      ]);
      setDetail(networkData);
      setPeers(peersData.peers);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load network detail');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (isOpen && network) {
      load(network.id);
    } else if (!isOpen) {
      // Clear stale state when the modal closes so a future open
      // doesn't briefly flash the previous network's data.
      setDetail(null);
      setPeers([]);
      setError(null);
    }
  }, [isOpen, network, load]);

  if (!network) return null;

  const display = detail ?? network;

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={display.name} size="lg">
      <div className="space-y-6">
        {/* Header summary */}
        <div className="flex items-start justify-between">
          <div className="flex items-start gap-3">
            <NetworkIcon className="text-theme-accent mt-1" size={20} />
            <div>
              <p className="text-xs text-theme-secondary font-mono">{display.slug}</p>
              <p className="text-xs text-theme-secondary font-mono mt-0.5">{display.cidr_64}</p>
            </div>
          </div>
          <span className={statusBadgeClass(display.status)}>{display.status}</span>
        </div>

        {display.description && (
          <p className="text-sm text-theme-primary">{display.description}</p>
        )}

        {/* Metadata grid */}
        <dl className="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
          <DetailField
            label="Topology strategy"
            value={(display.settings as { topology_strategy?: string })?.topology_strategy ?? '—'}
          />
          <DetailField
            label="Peer breakdown"
            value={`${display.peer_count} total · ${display.hub_count ?? 0} hub${display.hub_count === 1 ? '' : 's'} · ${display.spoke_count ?? 0} spoke${display.spoke_count === 1 ? '' : 's'}`}
          />
          {display.created_at && (
            <DetailField label="Created" value={new Date(display.created_at).toLocaleString()} />
          )}
          {display.updated_at && (
            <DetailField label="Updated" value={new Date(display.updated_at).toLocaleString()} />
          )}
        </dl>

        {/* Peers */}
        <div>
          <div className="flex items-center gap-2 mb-2">
            <Users size={16} className="text-theme-accent" />
            <h4 className="text-sm font-medium text-theme-primary">
              Peers ({loading ? '…' : peers.length})
            </h4>
          </div>

          {error && (
            <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>
          )}

          {loading && peers.length === 0 ? (
            <div className="p-4 text-sm text-theme-secondary text-center">Loading peers…</div>
          ) : peers.length === 0 ? (
            <div className="p-4 text-sm text-theme-secondary text-center bg-theme-background-secondary rounded">
              No peers attached yet.
            </div>
          ) : (
            <div className="overflow-x-auto border border-theme-border rounded">
              <table className="w-full text-xs">
                <thead className="bg-theme-background-secondary text-theme-secondary">
                  <tr>
                    <th className="text-left p-2">Name</th>
                    <th className="text-left p-2">Role</th>
                    <th className="text-left p-2">Endpoint</th>
                    <th className="text-left p-2">Status</th>
                    <th className="text-left p-2">Last handshake</th>
                  </tr>
                </thead>
                <tbody>
                  {peers.map((p) => (
                    <tr key={p.id} className="border-t border-theme-border">
                      <td className="p-2 text-theme-primary">{p.name ?? p.id.slice(0, 8)}</td>
                      <td className="p-2 text-theme-secondary">
                        {p.publicly_reachable ? 'hub' : 'spoke'}
                      </td>
                      <td className="p-2 font-mono text-theme-secondary">
                        {peerEndpoint(p)}
                      </td>
                      <td className="p-2 text-theme-secondary">{p.status ?? '—'}</td>
                      <td className="p-2 text-theme-secondary">
                        {p.last_handshake_at
                          ? new Date(p.last_handshake_at).toLocaleString()
                          : '—'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {/* Link to full management page */}
        <div className="pt-2 border-t border-theme-border text-right text-xs">
          <a
            href={`/app/system/sdwan/networks/${display.id}`}
            className="text-theme-accent hover:underline"
          >
            Open full management page →
          </a>
        </div>
      </div>
    </Modal>
  );
};

interface DetailFieldProps {
  label: string;
  value: string;
}

const DetailField: React.FC<DetailFieldProps> = ({ label, value }) => (
  <div>
    <dt className="text-theme-secondary text-xs uppercase tracking-wide">{label}</dt>
    <dd className="text-theme-primary mt-1">{value}</dd>
  </div>
);

function statusBadgeClass(status: string): string {
  const base = 'px-2 py-0.5 rounded text-xs font-medium';
  switch (status) {
    case 'active':
      return `${base} bg-theme-success text-theme-success`;
    case 'registered':
      return `${base} bg-theme-info text-theme-info`;
    case 'suspended':
      return `${base} bg-theme-warning text-theme-warning`;
    case 'archived':
      return `${base} bg-theme-background-secondary text-theme-secondary`;
    default:
      return `${base} bg-theme-background-secondary text-theme-secondary`;
  }
}

function peerEndpoint(p: SdwanPeer): string {
  const host = p.endpoint_host_v6 ?? p.endpoint_host_v4 ?? p.endpoint_host;
  if (!host) return '—';
  const hostStr = host.includes(':') ? `[${host}]` : host;
  return p.endpoint_port ? `${hostStr}:${p.endpoint_port}` : hostStr;
}
