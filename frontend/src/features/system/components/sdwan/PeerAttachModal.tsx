import React, { useState, useEffect } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';
import { systemApi } from '../../services/systemApi';
import type { SystemNodeInstance } from '../../types/system.types';

interface PeerAttachModalProps {
  isOpen: boolean;
  networkId: string;
  onClose: () => void;
  onAttached: () => void;
}

/**
 * PeerAttachModal — selects a NodeInstance and attaches it to the SDWAN
 * network. Hub mode requires a public endpoint (host + port). Spoke mode
 * connects outbound only and inherits hub addressing automatically.
 */
export const PeerAttachModal: React.FC<PeerAttachModalProps> = ({ isOpen, networkId, onClose, onAttached }) => {
  const { addNotification } = useNotifications();
  const [instances, setInstances] = useState<SystemNodeInstance[]>([]);
  const [loadingInstances, setLoadingInstances] = useState(false);
  const [nodeInstanceId, setNodeInstanceId] = useState('');
  const [publiclyReachable, setPubliclyReachable] = useState(false);
  // Slice 7a: dual-stack endpoint inputs. v6 is preferred; v4 is fallback.
  const [endpointHostV6, setEndpointHostV6] = useState('');
  const [endpointHostV4, setEndpointHostV4] = useState('');
  const [endpointPort, setEndpointPort] = useState<number>(51820);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setLoadingInstances(true);
    // Pull a flat list of all node instances under the account. The
    // existing /system/nodes endpoint nests instances under each node;
    // for slice 3 we walk via systemApi.getNodes() + getNodeInstances().
    systemApi
      .getNodes({ per_page: 50 })
      .then(async ({ nodes }) => {
        const instLists = await Promise.all(
          nodes.map((n) => systemApi.getNodeInstances(n.id).then((r) => r.node_instances))
        );
        setInstances(instLists.flat());
      })
      .catch(() => addNotification({ type: 'error', message: 'Failed to load node instances' }))
      .finally(() => setLoadingInstances(false));
  }, [isOpen, addNotification]);

  const reset = () => {
    setNodeInstanceId('');
    setPubliclyReachable(false);
    setEndpointHostV6('');
    setEndpointHostV4('');
    setEndpointPort(51820);
    setSubmitting(false);
  };

  const handleClose = () => {
    if (submitting) return;
    reset();
    onClose();
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!nodeInstanceId) {
      addNotification({ type: 'error', message: 'Pick a node instance to attach' });
      return;
    }
    if (publiclyReachable && !endpointHostV6.trim() && !endpointHostV4.trim()) {
      addNotification({ type: 'error', message: 'Hub peers need at least one endpoint (v6 or v4)' });
      return;
    }
    if (publiclyReachable && !endpointPort) {
      addNotification({ type: 'error', message: 'Hub peers require an endpoint port' });
      return;
    }
    setSubmitting(true);
    try {
      await sdwanApi.attachPeer(networkId, {
        node_instance_id: nodeInstanceId,
        publicly_reachable: publiclyReachable,
        endpoint_host_v6: publiclyReachable && endpointHostV6.trim() ? endpointHostV6.trim() : undefined,
        endpoint_host_v4: publiclyReachable && endpointHostV4.trim() ? endpointHostV4.trim() : undefined,
        endpoint_port: publiclyReachable ? endpointPort : undefined,
      });
      addNotification({ type: 'success', message: 'Peer attached' });
      onAttached();
      reset();
      onClose();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to attach peer';
      addNotification({ type: 'error', message: msg });
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Attach peer to network">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Node instance</label>
          <select
            value={nodeInstanceId}
            onChange={(e) => setNodeInstanceId(e.target.value)}
            className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
            disabled={submitting || loadingInstances}
          >
            <option value="">{loadingInstances ? 'Loading…' : 'Select a node instance'}</option>
            {instances.map((i) => (
              <option key={i.id} value={i.id}>
                {i.name} ({i.status})
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              checked={publiclyReachable}
              onChange={(e) => setPubliclyReachable(e.target.checked)}
              disabled={submitting}
            />
            <span className="text-sm text-theme-primary">
              Publicly reachable (hub) — other peers will connect to this one.
            </span>
          </label>
          <p className="text-xs text-theme-secondary mt-1 ml-6">
            Networks with no hub are isolated until one is attached.
          </p>
        </div>

        {publiclyReachable && (
          <div className="space-y-3">
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                IPv6 endpoint host <span className="text-xs text-theme-secondary">(preferred)</span>
              </label>
              <input
                type="text"
                value={endpointHostV6}
                onChange={(e) => setEndpointHostV6(e.target.value)}
                className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary font-mono text-sm"
                placeholder="2001:db8::1 or hub.v6.example.com"
                disabled={submitting}
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                IPv4 endpoint host <span className="text-xs text-theme-secondary">(fallback)</span>
              </label>
              <input
                type="text"
                value={endpointHostV4}
                onChange={(e) => setEndpointHostV4(e.target.value)}
                className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary font-mono text-sm"
                placeholder="203.0.113.10 or hub.example.com"
                disabled={submitting}
              />
              <p className="text-xs text-theme-secondary mt-1">
                Provide at least one. Both = v6 preferred with v4 fallback.
              </p>
            </div>
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">Port</label>
              <input
                type="number"
                value={endpointPort}
                onChange={(e) => setEndpointPort(Number(e.target.value))}
                className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
                min={1}
                max={65535}
                disabled={submitting}
              />
            </div>
          </div>
        )}

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={handleClose} disabled={submitting}>
            Cancel
          </Button>
          <Button variant="primary" type="submit" disabled={submitting || !nodeInstanceId}>
            {submitting ? 'Attaching…' : 'Attach'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
