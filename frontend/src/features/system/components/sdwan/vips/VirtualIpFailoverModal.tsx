import React, { useState } from 'react';
import { AlertTriangle } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanVirtualIp } from '../../../types/sdwan.types';

interface VirtualIpFailoverModalProps {
  networkId: string;
  vip: SdwanVirtualIp;
  onClose: () => void;
  onFailedOver: (vip: SdwanVirtualIp) => void;
}

export const VirtualIpFailoverModal: React.FC<VirtualIpFailoverModalProps> = ({
  networkId,
  vip,
  onClose,
  onFailedOver,
}) => {
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const nextHolder = vip.failover_holder_peer_ids[0];

  const handleConfirm = async () => {
    setSubmitting(true);
    setError(null);
    try {
      const updated = await sdwanApi.failoverVirtualIp(networkId, vip.id);
      onFailedOver(updated);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failover failed');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen onClose={onClose} title={`Failover VIP — ${vip.name}`} size="md">
      <div className="space-y-4">
        <div className="flex items-start gap-2 p-3 bg-theme-warning/30 rounded text-sm">
          <AlertTriangle size={20} className="text-theme-warning shrink-0 mt-0.5" />
          <div>
            <div className="font-medium text-theme-primary">Manual failover</div>
            <div className="text-theme-secondary mt-1">
              Promotes the head of <code className="font-mono text-xs">failover_holder_peer_ids</code> to primary
              holder. The current primary moves to the back of the failover queue. The change takes effect on the
              next agent reconcile cycle (typically &lt;30s).
            </div>
          </div>
        </div>

        <div className="space-y-1 text-sm">
          <div>
            <span className="text-theme-secondary">VIP:</span>{' '}
            <span className="font-mono text-theme-primary">{vip.cidr}</span>
          </div>
          <div>
            <span className="text-theme-secondary">Current holder:</span>{' '}
            <span className="font-mono text-xs text-theme-primary">
              {vip.primary_holder_peer_id?.slice(0, 12) ?? '—'}
            </span>
          </div>
          <div>
            <span className="text-theme-secondary">Next holder (after failover):</span>{' '}
            <span className="font-mono text-xs text-theme-primary">
              {nextHolder?.slice(0, 12) ?? '—'}
            </span>
          </div>
        </div>

        {!nextHolder && (
          <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">
            No failover candidates configured. Edit the VIP and add at least one peer to{' '}
            <code className="font-mono text-xs">failover_holder_peer_ids</code> first.
          </div>
        )}

        {error && <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>}

        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose} type="button">
            Cancel
          </Button>
          <Button variant="warning" type="button" onClick={handleConfirm} disabled={submitting || !nextHolder}>
            {submitting ? 'Failing over…' : 'Confirm failover'}
          </Button>
        </div>
      </div>
    </Modal>
  );
};
