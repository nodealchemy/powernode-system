import React, { useState, useEffect } from 'react';
import { Globe } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../../services/api/sdwanApi';
import { isPendingApproval } from '../../../services/api/helpers';
import { pendingApprovalNotice } from '../../../utils/pendingApproval';
import type { SdwanVirtualIp, SdwanPeer, SdwanVirtualIpUpdate } from '../../../types/sdwan.types';

interface VirtualIpEditModalProps {
  networkId: string;
  vip: SdwanVirtualIp;
  onClose: () => void;
  onSaved: (vip: SdwanVirtualIp) => void;
}

/**
 * Edits a live VIP through sdwanApi.updateVirtualIp (IMP-d1900addb504).
 *
 * The CIDR and the anycast/active-passive mode are deliberately read-only
 * here. The server permits both, but changing either re-plumbs which address
 * holders claim on their loopback and how it is advertised — that is a
 * delete-and-recreate, not an edit, and doing it silently under a "Save
 * changes" button would move a live address out from under its holders.
 */
export const VirtualIpEditModal: React.FC<VirtualIpEditModalProps> = ({
  networkId,
  vip,
  onClose,
  onSaved,
}) => {
  const { addNotification } = useNotifications();
  const [name, setName] = useState(vip.name);
  const [description, setDescription] = useState(vip.description ?? '');
  const [primaryHolderId, setPrimaryHolderId] = useState<string>(
    vip.primary_holder_peer_id ?? vip.holder_peer_ids[0] ?? ''
  );
  const [anycastHolderIds, setAnycastHolderIds] = useState<string[]>(vip.holder_peer_ids);
  const [failoverIds, setFailoverIds] = useState<string[]>(vip.failover_holder_peer_ids);
  // Holder and failover keys are sent ONLY when the operator actually moved
  // them. Sending the reconstructed value on every save would rewrite state
  // this form cannot fully represent: an anycast VIP's failover candidates
  // (never shown here), and a legacy active/passive row carrying more than one
  // holder, which `[primaryHolderId]` would truncate. The model gates its
  // single-holder rule on change, so an untouched save must not look like one.
  const [holdersTouched, setHoldersTouched] = useState(false);
  const [failoverTouched, setFailoverTouched] = useState(false);
  const [advertisedMed, setAdvertisedMed] = useState<number>(vip.advertised_med);
  const [advertisedLocalPref, setAdvertisedLocalPref] = useState<number>(vip.advertised_local_pref);
  const [peers, setPeers] = useState<SdwanPeer[]>([]);
  const [peersError, setPeersError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Same reasoning as the create modal: the peer list is the ONLY source of
  // holder options, so a failed load must block the save rather than present
  // an empty picker that silently drops the VIP's current holders.
  useEffect(() => {
    let cancelled = false;
    setPeersError(null);
    sdwanApi
      .getPeers(networkId)
      .then((r) => {
        if (cancelled) return;
        setPeers(r.peers);
      })
      .catch((err) => {
        if (cancelled) return;
        const message = `Could not load the peers for this network: ${
          err instanceof Error ? err.message : 'request failed'
        }. Holder selection is unavailable, so saving is blocked until this succeeds.`;
        setPeers([]);
        setPeersError(message);
        addNotification({ type: 'error', message });
      });
    return () => {
      cancelled = true;
    };
  }, [networkId, addNotification]);

  const optionsUnavailable = !!peersError;

  const peerLabel = (p: SdwanPeer) =>
    `${p.node_instance_id?.slice(0, 8) ?? p.id.slice(0, 8)} (${p.publicly_reachable ? 'hub' : 'spoke'})`;

  const toggleAnycastHolder = (id: string) => {
    setHoldersTouched(true);
    setAnycastHolderIds((curr) => (curr.includes(id) ? curr.filter((x) => x !== id) : [...curr, id]));
  };

  const toggleFailover = (id: string) => {
    setFailoverTouched(true);
    setFailoverIds((curr) => (curr.includes(id) ? curr.filter((x) => x !== id) : [...curr, id]));
  };

  const selectPrimaryHolder = (id: string) => {
    setHoldersTouched(true);
    setPrimaryHolderId(id);
  };

  // A number field must be able to hold 0 — `parseInt(v) || fallback` turns a
  // deliberate 0 into the fallback and silently raises the advertised metric.
  const parseMetric = (raw: string, fallback: number): number => {
    const n = parseInt(raw, 10);
    return Number.isNaN(n) ? fallback : n;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    // The disabled button is not the whole guard — Enter in a text field and a
    // programmatic submit both bypass it.
    if (optionsUnavailable) return;
    setSubmitting(true);
    try {
      // Sent unconditionally — `|| undefined` would drop the key and make
      // clearing the description a silent no-op reported as success.
      const payload: SdwanVirtualIpUpdate = {
        name,
        description: description.trim(),
        advertised_med: advertisedMed,
        advertised_local_pref: advertisedLocalPref,
      };

      if (holdersTouched) {
        const holders = vip.anycast ? anycastHolderIds : primaryHolderId ? [primaryHolderId] : [];
        if (vip.anycast && holders.length < 2) {
          throw new Error('Anycast VIPs require at least 2 holder peers.');
        }
        if (!vip.anycast && holders.length === 0) {
          throw new Error('An active/passive VIP needs a primary holder.');
        }
        payload.holder_peer_ids = holders;
      }

      // Anycast VIPs never expose failover candidates in this form, so they are
      // never written from here.
      if (!vip.anycast && (failoverTouched || holdersTouched)) {
        // A promoted peer must not stay its own failover candidate — the list
        // filters it out of the checkboxes but the state keeps it, and
        // failover! would then promote the holder onto itself.
        payload.failover_holder_peer_ids = failoverIds.filter((id) => id !== primaryHolderId);
      }

      const saved = await sdwanApi.updateVirtualIp(networkId, vip.id, payload);
      if (isPendingApproval(saved)) {
        addNotification(pendingApprovalNotice(`updating VIP '${vip.name}'`, saved));
        onClose();
        return;
      }
      onSaved(saved);
    } catch (err) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to update virtual IP',
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen
      onClose={onClose}
      title={`Edit Virtual IP — ${vip.name}`}
      icon={<Globe className="w-6 h-6" />}
      size="lg"
    >
      <form onSubmit={handleSubmit} className="space-y-4">
        {peersError && <ErrorAlert message={peersError} />}

        <div className="grid grid-cols-2 gap-3">
          <div>
            <label htmlFor="vip-edit-name" className="block text-sm font-medium text-theme-primary mb-1">
              Name
            </label>
            <input
              id="vip-edit-name"
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              maxLength={64}
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">CIDR</label>
            <p className="px-3 py-2 rounded bg-theme-background-secondary border border-theme text-theme-secondary font-mono text-sm">
              {vip.cidr}
            </p>
          </div>
        </div>

        <div>
          <label htmlFor="vip-edit-description" className="block text-sm font-medium text-theme-primary mb-1">
            Description
          </label>
          <input
            id="vip-edit-description"
            type="text"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
          />
        </div>

        <p className="text-xs text-theme-secondary">
          Address and mode ({vip.anycast ? 'anycast' : 'active/passive'}) are fixed for the life of
          the VIP — changing either moves a live address, so delete and recreate instead.
        </p>

        {vip.anycast ? (
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-2">
              Anycast holders (select 2 or more)
            </label>
            <div className="space-y-1 max-h-48 overflow-y-auto border border-theme rounded p-2">
              {peers.map((p) => (
                <label
                  key={p.id}
                  className="flex items-center gap-2 px-2 py-1 hover:bg-theme-background-secondary/50 rounded cursor-pointer"
                >
                  <input
                    type="checkbox"
                    checked={anycastHolderIds.includes(p.id)}
                    onChange={() => toggleAnycastHolder(p.id)}
                  />
                  <span className="text-sm">{peerLabel(p)}</span>
                </label>
              ))}
            </div>
          </div>
        ) : (
          <>
            <div>
              <label htmlFor="vip-edit-primary" className="block text-sm font-medium text-theme-primary mb-1">
                Primary holder
              </label>
              <select
                id="vip-edit-primary"
                value={primaryHolderId}
                onChange={(e) => selectPrimaryHolder(e.target.value)}
                className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
              >
                <option value="">Select a peer…</option>
                {peers.map((p) => (
                  <option key={p.id} value={p.id}>
                    {peerLabel(p)}
                  </option>
                ))}
              </select>
            </div>

            <div>
              <label className="block text-sm font-medium text-theme-primary mb-2">
                Failover candidates (ordered)
              </label>
              <div className="space-y-1 max-h-32 overflow-y-auto border border-theme rounded p-2">
                {peers
                  .filter((p) => p.id !== primaryHolderId)
                  .map((p) => (
                    <label
                      key={p.id}
                      className="flex items-center gap-2 px-2 py-1 hover:bg-theme-background-secondary/50 rounded cursor-pointer"
                    >
                      <input
                        type="checkbox"
                        checked={failoverIds.includes(p.id)}
                        onChange={() => toggleFailover(p.id)}
                      />
                      <span className="text-sm">{peerLabel(p)}</span>
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
              <label htmlFor="vip-edit-med" className="block text-xs text-theme-secondary mb-1">
                MED (Multi-Exit Discriminator)
              </label>
              <input
                id="vip-edit-med"
                type="number"
                value={advertisedMed}
                onChange={(e) => setAdvertisedMed(parseMetric(e.target.value, 0))}
                min={0}
                className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
              />
            </div>
            <div>
              <label htmlFor="vip-edit-local-pref" className="block text-xs text-theme-secondary mb-1">
                Local Preference
              </label>
              <input
                id="vip-edit-local-pref"
                type="number"
                value={advertisedLocalPref}
                onChange={(e) => setAdvertisedLocalPref(parseMetric(e.target.value, 100))}
                min={0}
                className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
              />
            </div>
          </div>
        </details>

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={onClose} type="button">
            Cancel
          </Button>
          <Button variant="primary" type="submit" disabled={submitting || optionsUnavailable}>
            {submitting ? 'Saving…' : 'Save changes'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
