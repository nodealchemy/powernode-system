import React, { useState, useEffect } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanVirtualIp, SdwanPeer } from '../../../types/sdwan.types';

interface VirtualIpCreateModalProps {
  networkId: string;
  onClose: () => void;
  onCreated: (vip: SdwanVirtualIp) => void;
}

export const VirtualIpCreateModal: React.FC<VirtualIpCreateModalProps> = ({
  networkId,
  onClose,
  onCreated,
}) => {
  const [name, setName] = useState('');
  const [cidr, setCidr] = useState('');
  const [description, setDescription] = useState('');
  const [anycast, setAnycast] = useState(false);
  const [primaryHolderId, setPrimaryHolderId] = useState<string>('');
  const [anycastHolderIds, setAnycastHolderIds] = useState<string[]>([]);
  const [failoverIds, setFailoverIds] = useState<string[]>([]);
  const [advertisedMed, setAdvertisedMed] = useState<number>(0);
  const [advertisedLocalPref, setAdvertisedLocalPref] = useState<number>(100);
  const [peers, setPeers] = useState<SdwanPeer[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    sdwanApi.getPeers(networkId).then((r) => setPeers(r.peers)).catch(() => setPeers([]));
  }, [networkId]);

  const peerOption = (p: SdwanPeer) => ({
    value: p.id,
    label: `${p.node_instance_id?.slice(0, 8) ?? p.id.slice(0, 8)} (${p.publicly_reachable ? 'hub' : 'spoke'})`,
  });

  const toggleAnycastHolder = (id: string) => {
    setAnycastHolderIds((curr) => (curr.includes(id) ? curr.filter((x) => x !== id) : [...curr, id]));
  };

  const toggleFailover = (id: string) => {
    setFailoverIds((curr) => (curr.includes(id) ? curr.filter((x) => x !== id) : [...curr, id]));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      const holders = anycast ? anycastHolderIds : primaryHolderId ? [primaryHolderId] : [];
      if (anycast && holders.length < 2) {
        throw new Error('Anycast VIPs require at least 2 holder peers.');
      }
      if (!cidr.match(/^[0-9a-fA-F.:]+\/\d{1,3}$/)) {
        throw new Error('CIDR must be a valid v4 or v6 prefix (e.g. 192.0.2.42/32).');
      }
      const created = await sdwanApi.createVirtualIp(networkId, {
        name,
        cidr,
        description: description || undefined,
        anycast,
        holder_peer_ids: holders,
        failover_holder_peer_ids: anycast ? [] : failoverIds,
        advertised_med: advertisedMed,
        advertised_local_pref: advertisedLocalPref,
      });
      onCreated(created);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create virtual IP');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen onClose={onClose} title="Create Virtual IP" size="lg">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Name</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              maxLength={64}
              placeholder="e.g. webapp-vip"
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">CIDR</label>
            <input
              type="text"
              value={cidr}
              onChange={(e) => setCidr(e.target.value)}
              required
              placeholder="192.0.2.42/32 or fdXX::/128"
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary font-mono"
            />
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Description</label>
          <input
            type="text"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
          />
        </div>

        <div className="flex items-center gap-2 p-3 bg-theme-background-secondary rounded">
          <input
            type="checkbox"
            id="anycast"
            checked={anycast}
            onChange={(e) => setAnycast(e.target.checked)}
          />
          <label htmlFor="anycast" className="text-sm text-theme-primary">
            Anycast mode (active/active across multiple holders, requires iBGP)
          </label>
        </div>

        {anycast ? (
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-2">
              Anycast holders (select 2 or more)
            </label>
            <div className="space-y-1 max-h-48 overflow-y-auto border border-theme rounded p-2">
              {peers.map((p) => (
                <label key={p.id} className="flex items-center gap-2 px-2 py-1 hover:bg-theme-background-secondary/50 rounded cursor-pointer">
                  <input
                    type="checkbox"
                    checked={anycastHolderIds.includes(p.id)}
                    onChange={() => toggleAnycastHolder(p.id)}
                  />
                  <span className="text-sm">{peerOption(p).label}</span>
                </label>
              ))}
            </div>
          </div>
        ) : (
          <>
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">Primary holder</label>
              <select
                value={primaryHolderId}
                onChange={(e) => setPrimaryHolderId(e.target.value)}
                required
                className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
              >
                <option value="">Select a peer…</option>
                {peers.map((p) => (
                  <option key={p.id} value={p.id}>
                    {peerOption(p).label}
                  </option>
                ))}
              </select>
            </div>

            <div>
              <label className="block text-sm font-medium text-theme-primary mb-2">
                Failover candidates (ordered)
              </label>
              <div className="space-y-1 max-h-32 overflow-y-auto border border-theme rounded p-2">
                {peers.filter((p) => p.id !== primaryHolderId).map((p) => (
                  <label key={p.id} className="flex items-center gap-2 px-2 py-1 hover:bg-theme-background-secondary/50 rounded cursor-pointer">
                    <input
                      type="checkbox"
                      checked={failoverIds.includes(p.id)}
                      onChange={() => toggleFailover(p.id)}
                    />
                    <span className="text-sm">{peerOption(p).label}</span>
                  </label>
                ))}
              </div>
            </div>
          </>
        )}

        <details className="text-sm">
          <summary className="cursor-pointer text-theme-secondary">Advanced (BGP metrics)</summary>
          <div className="mt-2 grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs text-theme-secondary mb-1">MED (Multi-Exit Discriminator)</label>
              <input
                type="number"
                value={advertisedMed}
                onChange={(e) => setAdvertisedMed(parseInt(e.target.value, 10) || 0)}
                min={0}
                className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
              />
            </div>
            <div>
              <label className="block text-xs text-theme-secondary mb-1">Local Preference</label>
              <input
                type="number"
                value={advertisedLocalPref}
                onChange={(e) => setAdvertisedLocalPref(parseInt(e.target.value, 10) || 100)}
                min={0}
                className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
              />
            </div>
          </div>
        </details>

        {error && <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>}

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={onClose} type="button">
            Cancel
          </Button>
          <Button variant="primary" type="submit" disabled={submitting}>
            {submitting ? 'Creating…' : 'Create Virtual IP'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
