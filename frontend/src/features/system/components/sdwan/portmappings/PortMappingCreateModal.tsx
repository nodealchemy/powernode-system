import React, { useState, useEffect } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type {
  SdwanPortMapping,
  SdwanPeer,
  SdwanVirtualIp,
  SdwanPortMappingProtocol,
} from '../../../types/sdwan.types';

interface PortMappingCreateModalProps {
  networkId: string;
  mapping?: SdwanPortMapping | null; // null/undefined = create
  onClose: () => void;
  onSaved: (mapping: SdwanPortMapping) => void;
}

type TargetType = 'peer' | 'virtual_ip';

export const PortMappingCreateModal: React.FC<PortMappingCreateModalProps> = ({
  networkId,
  mapping,
  onClose,
  onSaved,
}) => {
  const isEdit = !!mapping;
  const [name, setName] = useState(mapping?.name ?? '');
  const [description, setDescription] = useState(mapping?.description ?? '');
  const [hubPeerId, setHubPeerId] = useState(mapping?.hub_peer_id ?? '');
  const [protocol, setProtocol] = useState<SdwanPortMappingProtocol>(mapping?.protocol ?? 'tcp');
  const [listenPort, setListenPort] = useState<number>(mapping?.listen_port ?? 0);
  const [targetPort, setTargetPort] = useState<number | ''>(mapping?.target_port ?? '');
  const [targetType, setTargetType] = useState<TargetType>(
    mapping?.target_virtual_ip_id ? 'virtual_ip' : 'peer'
  );
  const [targetPeerId, setTargetPeerId] = useState(mapping?.target_peer_id ?? '');
  const [targetVipId, setTargetVipId] = useState(mapping?.target_virtual_ip_id ?? '');
  const [enabled, setEnabled] = useState(mapping?.enabled ?? true);
  const [peers, setPeers] = useState<SdwanPeer[]>([]);
  const [vips, setVips] = useState<SdwanVirtualIp[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    sdwanApi.getPeers(networkId).then((r) => setPeers(r.peers)).catch(() => setPeers([]));
    sdwanApi.listVirtualIps(networkId).then((r) => setVips(r.virtual_ips)).catch(() => setVips([]));
  }, [networkId]);

  const hubPeers = peers.filter((p) => p.publicly_reachable);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      if (!hubPeerId) throw new Error('Select a hub peer (publicly reachable).');
      if (!listenPort || listenPort < 1 || listenPort > 65535) {
        throw new Error('Listen port must be 1-65535.');
      }
      if (targetType === 'peer' && !targetPeerId) {
        throw new Error('Select a target peer.');
      }
      if (targetType === 'virtual_ip' && !targetVipId) {
        throw new Error('Select a target VIP.');
      }

      const payload = {
        name,
        description: description || undefined,
        sdwan_peer_id: hubPeerId,
        protocol,
        listen_port: listenPort,
        target_port: targetPort === '' ? null : targetPort,
        target_peer_id: targetType === 'peer' ? targetPeerId : null,
        target_virtual_ip_id: targetType === 'virtual_ip' ? targetVipId : null,
        enabled,
      };

      const saved = isEdit
        ? await sdwanApi.updatePortMapping(networkId, mapping!.id, payload)
        : await sdwanApi.createPortMapping(networkId, payload);
      onSaved(saved);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Save failed');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen
      onClose={onClose}
      title={isEdit ? `Edit port mapping — ${mapping!.name}` : 'New port mapping'}
      size="lg"
    >
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Name</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
            maxLength={64}
            placeholder="e.g. db-public"
            className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Description</label>
          <input
            type="text"
            value={description ?? ''}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Hub peer</label>
          <select
            value={hubPeerId}
            onChange={(e) => setHubPeerId(e.target.value)}
            required
            className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
          >
            <option value="">Select a hub (publicly reachable)…</option>
            {hubPeers.map((p) => (
              <option key={p.id} value={p.id}>
                {p.id.slice(0, 8)} ({p.assigned_address})
              </option>
            ))}
          </select>
          {hubPeers.length === 0 && (
            <div className="text-xs text-theme-warning mt-1">
              No hubs available. Mark a peer as <code className="font-mono">publicly_reachable: true</code> first.
            </div>
          )}
        </div>

        <div className="grid grid-cols-3 gap-3">
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Protocol</label>
            <select
              value={protocol}
              onChange={(e) => setProtocol(e.target.value as SdwanPortMappingProtocol)}
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
            >
              <option value="tcp">TCP</option>
              <option value="udp">UDP</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Listen port</label>
            <input
              type="number"
              value={listenPort || ''}
              onChange={(e) => setListenPort(parseInt(e.target.value, 10) || 0)}
              required
              min={1}
              max={65535}
              placeholder="5432"
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">
              Target port <span className="text-theme-secondary text-xs">(optional)</span>
            </label>
            <input
              type="number"
              value={targetPort}
              onChange={(e) => setTargetPort(e.target.value === '' ? '' : parseInt(e.target.value, 10))}
              min={1}
              max={65535}
              placeholder="defaults to listen port"
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
            />
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Target type</label>
          <div className="flex gap-3">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                checked={targetType === 'peer'}
                onChange={() => setTargetType('peer')}
              />
              <span className="text-sm">Specific peer</span>
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                checked={targetType === 'virtual_ip'}
                onChange={() => setTargetType('virtual_ip')}
              />
              <span className="text-sm">Virtual IP (follows holder)</span>
            </label>
          </div>
        </div>

        {targetType === 'peer' ? (
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Target peer</label>
            <select
              value={targetPeerId ?? ''}
              onChange={(e) => setTargetPeerId(e.target.value)}
              required
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
            >
              <option value="">Select a target peer…</option>
              {peers.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.id.slice(0, 8)} ({p.assigned_address}) {p.publicly_reachable ? '· hub' : '· spoke'}
                </option>
              ))}
            </select>
          </div>
        ) : (
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Target virtual IP</label>
            <select
              value={targetVipId ?? ''}
              onChange={(e) => setTargetVipId(e.target.value)}
              required
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
            >
              <option value="">Select a VIP…</option>
              {vips.map((v) => (
                <option key={v.id} value={v.id}>
                  {v.name} ({v.cidr}) {v.anycast ? '· anycast' : '· active/passive'}
                </option>
              ))}
            </select>
            {vips.length === 0 && (
              <div className="text-xs text-theme-warning mt-1">
                No VIPs in this network. Create one in the Virtual IPs tab first.
              </div>
            )}
          </div>
        )}

        <div className="flex items-center gap-2">
          <input
            type="checkbox"
            id="pm-enabled"
            checked={enabled}
            onChange={(e) => setEnabled(e.target.checked)}
          />
          <label htmlFor="pm-enabled" className="text-sm text-theme-primary">
            Enabled (active in nft DNAT chain)
          </label>
        </div>

        {error && <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>}

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={onClose} type="button">
            Cancel
          </Button>
          <Button variant="primary" type="submit" disabled={submitting}>
            {submitting ? 'Saving…' : isEdit ? 'Save changes' : 'Create mapping'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
