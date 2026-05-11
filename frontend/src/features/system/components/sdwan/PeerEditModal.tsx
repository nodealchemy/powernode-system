import React, { useEffect, useState } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { apiClient } from '@/shared/services/apiClient';
import type { SdwanPeer } from '../../types/sdwan.types';

interface PeerEditModalProps {
  isOpen: boolean;
  networkId: string;
  peer: SdwanPeer | null;
  onClose: () => void;
  onSaved: () => void;
}

/**
 * PeerEditModal — toggles a peer's hub/spoke role + endpoint. Promoting
 * a spoke to hub requires at least one endpoint (v6 or v4) plus a port;
 * demoting a hub to spoke clears them. Address + listen_port immutable
 * post-creation.
 *
 * Slice 7a: split endpoint inputs into v6 + v4 fields. Operators can
 * provide either (or both — both = v6 preferred with v4 fallback).
 */
export const PeerEditModal: React.FC<PeerEditModalProps> = ({ isOpen, networkId, peer, onClose, onSaved }) => {
  const { addNotification } = useNotifications();
  const [publiclyReachable, setPubliclyReachable] = useState(false);
  const [endpointHostV6, setEndpointHostV6] = useState('');
  const [endpointHostV4, setEndpointHostV4] = useState('');
  const [endpointPort, setEndpointPort] = useState<number>(51820);
  // Slice 9a — declarative external prefixes (CIDRs) routed through this peer.
  const [lanSubnets, setLanSubnets] = useState<string>('');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!peer) return;
    setPubliclyReachable(peer.publicly_reachable);
    // Slice 7a: prefer split fields. Fall back to legacy endpoint_host
    // for rows created before the dual-stack migration — heuristically
    // classify by colon presence (v6 literals contain ':', v4 + hostnames
    // do not).
    if (peer.endpoint_host_v6 || peer.endpoint_host_v4) {
      setEndpointHostV6(peer.endpoint_host_v6 ?? '');
      setEndpointHostV4(peer.endpoint_host_v4 ?? '');
    } else if (peer.endpoint_host) {
      if (peer.endpoint_host.includes(':')) {
        setEndpointHostV6(peer.endpoint_host);
        setEndpointHostV4('');
      } else {
        setEndpointHostV6('');
        setEndpointHostV4(peer.endpoint_host);
      }
    } else {
      setEndpointHostV6('');
      setEndpointHostV4('');
    }
    setEndpointPort(peer.endpoint_port ?? 51820);
    // Slice 9a — render lan_subnets as newline-separated for easy paste/edit.
    setLanSubnets(Array.isArray(peer.lan_subnets) ? peer.lan_subnets.join('\n') : '');
  }, [peer]);

  if (!peer) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
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
      // Slice 9a — parse newline/comma-separated CIDRs into array.
      const parsedSubnets = lanSubnets
        .split(/[\n,]/)
        .map((s) => s.trim())
        .filter((s) => s.length > 0);

      await apiClient.put(`/system/sdwan/networks/${networkId}/peers/${peer.id}`, {
        peer: {
          publicly_reachable: publiclyReachable,
          lan_subnets: parsedSubnets,
          endpoint_host_v6: publiclyReachable && endpointHostV6.trim() ? endpointHostV6.trim() : null,
          endpoint_host_v4: publiclyReachable && endpointHostV4.trim() ? endpointHostV4.trim() : null,
          // Clear the legacy column when switching to dual-stack — the new
          // split fields are the canonical source going forward.
          endpoint_host: null,
          endpoint_port: publiclyReachable ? endpointPort : null,
        },
      });
      addNotification({ type: 'success', message: 'Peer updated' });
      onSaved();
      onClose();
    } catch (err) {
      addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Update failed' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={() => !submitting && onClose()} title="Edit peer">
      <form onSubmit={handleSubmit} className="space-y-3">
        <div className="text-xs text-theme-secondary font-mono">
          Address: {peer.assigned_address}
        </div>
        {peer.effective_endpoint && (
          <div className="text-xs text-theme-secondary">
            Currently using: <span className="font-mono">{peer.effective_endpoint}</span>
            {peer.effective_endpoint_family && (
              <span className="ml-1 text-theme-info">({peer.effective_endpoint_family})</span>
            )}
            {peer.fallback_endpoint && (
              <span className="ml-2">· fallback: <span className="font-mono">{peer.fallback_endpoint}</span></span>
            )}
          </div>
        )}
        <div>
          <label className="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox" checked={publiclyReachable}
              onChange={(e) => setPubliclyReachable(e.target.checked)}
              disabled={submitting}
            />
            <span className="text-sm text-theme-primary">Publicly reachable (hub mode)</span>
          </label>
        </div>
        {publiclyReachable && (
          <div className="space-y-3">
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                IPv6 endpoint host <span className="text-xs text-theme-secondary">(preferred)</span>
              </label>
              <input
                type="text" value={endpointHostV6} onChange={(e) => setEndpointHostV6(e.target.value)}
                className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary font-mono text-sm"
                placeholder="2001:db8::1 or hub.v6.example.com"
                disabled={submitting}
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                IPv4 endpoint host <span className="text-xs text-theme-secondary">(fallback)</span>
              </label>
              <input
                type="text" value={endpointHostV4} onChange={(e) => setEndpointHostV4(e.target.value)}
                className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary font-mono text-sm"
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
                type="number" value={endpointPort} onChange={(e) => setEndpointPort(Number(e.target.value))}
                className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
                min={1} max={65535} disabled={submitting}
              />
            </div>
          </div>
        )}
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={onClose} disabled={submitting}>Cancel</Button>
          <Button variant="primary" type="submit" disabled={submitting}>
            {submitting ? 'Saving…' : 'Save'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
