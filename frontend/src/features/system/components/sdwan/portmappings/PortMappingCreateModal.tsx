import React, { useState, useEffect } from 'react';
import { ArrowRightLeft } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../../services/api/sdwanApi';
import { isPendingApproval } from '../../../services/api/helpers';
import { pendingApprovalNotice } from '../../../utils/pendingApproval';
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
  const { addNotification } = useNotifications();
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
  const [peersError, setPeersError] = useState<string | null>(null);
  const [vipsError, setVipsError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Peers and VIPs are the only sources of hub/target options. Swallowing a
  // failed load into an empty list renders as "No hubs available" — indistinguishable
  // from a network that genuinely has none — and the submit then blames the operator
  // for not selecting an option that was never offered.
  useEffect(() => {
    let cancelled = false;
    setPeersError(null);
    setVipsError(null);

    sdwanApi.getPeers(networkId).then((r) => {
      if (cancelled) return;
      setPeers(r.peers);
    }).catch((err) => {
      if (cancelled) return;
      const message = `Could not load the peers for this network: ${err instanceof Error ? err.message : 'request failed'}. Hub and target selection is unavailable, so saving is blocked until this succeeds.`;
      setPeers([]);
      setPeersError(message);
      addNotification({ type: 'error', message });
    });

    sdwanApi.listVirtualIps(networkId).then((r) => {
      if (cancelled) return;
      setVips(r.virtual_ips);
    }).catch((err) => {
      if (cancelled) return;
      const message = `Could not load the virtual IPs for this network: ${err instanceof Error ? err.message : 'request failed'}. VIP targets are unavailable, so saving is blocked until this succeeds.`;
      setVips([]);
      setVipsError(message);
      addNotification({ type: 'error', message });
    });

    return () => {
      cancelled = true;
    };
  }, [networkId, addNotification]);

  const hubPeers = peers.filter((p) => p.publicly_reachable);

  // A failed peer load is always disqualifying — every mapping needs a hub peer.
  // A failed VIP load only is when the payload actually carries a VIP: a
  // peer-targeted mapping never reads the VIP list and does not even render its
  // select, so blocking that operator would help nobody.
  //
  // The disabled button is not the whole guard: fireEvent.submit and a submit
  // fired in the same tick as mount both bypass it, so the refusal also lives in
  // the handler.
  const optionsUnavailable = !!peersError || (targetType === 'virtual_ip' && !!vipsError);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (optionsUnavailable) return;
    setSubmitting(true);
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
      if (isPendingApproval(saved)) {
        addNotification(
          pendingApprovalNotice(`${isEdit ? 'updating' : 'creating'} port mapping '${name}'`, saved)
        );
        onClose();
        return;
      }
      onSaved(saved);
    } catch (err) {
      addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Save failed' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen
      onClose={onClose}
      title={isEdit ? `Edit port mapping — ${mapping!.name}` : 'New port mapping'}
      icon={<ArrowRightLeft className="w-6 h-6" />}
      size="lg"
    >
      <form onSubmit={handleSubmit} className="space-y-4">
        {peersError && <ErrorAlert message={peersError} />}
        {vipsError && <ErrorAlert message={vipsError} />}
        <FormField
          label="Name"
          value={name}
          onChange={setName}
          nativeRequired
          maxLength={64}
          placeholder="e.g. db-public"
        />

        <FormField
          label="Description"
          value={description ?? ''}
          onChange={setDescription}
        />

        <div>
          <FormField
            label="Hub peer"
            type="select"
            value={hubPeerId}
            onChange={setHubPeerId}
            nativeRequired
            options={[
              { value: '', label: 'Select a hub (publicly reachable)…' },
              ...hubPeers.map((p) => ({
                value: p.id,
                label: `${p.id.slice(0, 8)} (${p.assigned_address})`,
              })),
            ]}
          />
          {!peersError && hubPeers.length === 0 && (
            <div className="text-xs text-theme-warning-fg mt-1">
              No hubs available. Mark a peer as <code className="font-mono">publicly_reachable: true</code> first.
            </div>
          )}
        </div>

        <div className="grid grid-cols-3 gap-3">
          <FormField
            label="Protocol"
            type="select"
            value={protocol}
            onChange={(v) => setProtocol(v as SdwanPortMappingProtocol)}
            options={[
              { value: 'tcp', label: 'TCP' },
              { value: 'udp', label: 'UDP' },
            ]}
          />
          <FormField
            label="Listen port"
            type="number"
            value={listenPort ? String(listenPort) : ''}
            onChange={(v) => setListenPort(parseInt(v, 10) || 0)}
            nativeRequired
            min={1}
            max={65535}
            placeholder="5432"
          />
          <FormField
            label={<>Target port <span className="text-theme-secondary text-xs">(optional)</span></>}
            type="number"
            value={String(targetPort)}
            onChange={(v) => setTargetPort(v === '' ? '' : parseInt(v, 10))}
            min={1}
            max={65535}
            placeholder="defaults to listen port"
          />
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
          <FormField
            label="Target peer"
            type="select"
            value={targetPeerId ?? ''}
            onChange={setTargetPeerId}
            nativeRequired
            options={[
              { value: '', label: 'Select a target peer…' },
              ...peers.map((p) => ({
                value: p.id,
                label: `${p.id.slice(0, 8)} (${p.assigned_address}) ${
                  p.publicly_reachable ? '· hub' : '· spoke'
                }`,
              })),
            ]}
          />
        ) : (
          <div>
            <FormField
              label="Target virtual IP"
              type="select"
              value={targetVipId ?? ''}
              onChange={setTargetVipId}
              nativeRequired
              options={[
                { value: '', label: 'Select a VIP…' },
                ...vips.map((v) => ({
                  value: v.id,
                  label: `${v.name} (${v.cidr}) ${v.anycast ? '· anycast' : '· active/passive'}`,
                })),
              ]}
            />
            {!vipsError && vips.length === 0 && (
              <div className="text-xs text-theme-warning-fg mt-1">
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

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={onClose} type="button">
            Cancel
          </Button>
          <Button variant="primary" type="submit" disabled={submitting || optionsUnavailable}>
            {submitting ? 'Saving…' : isEdit ? 'Save changes' : 'Create mapping'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
