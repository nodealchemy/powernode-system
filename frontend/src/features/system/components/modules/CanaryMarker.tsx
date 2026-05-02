import React, { useState } from 'react';
import { ShieldAlert, Shield } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeModule } from '@system/features/system/types/system.types';

interface Props {
  module: SystemNodeModule & { config?: Record<string, unknown> };
  onUpdated?: (module: SystemNodeModule) => void;
}

const LURE_KINDS = [
  'credential_store',
  'admin_shell',
  'production_keys',
  'ssh_keys',
  'database_root',
  'cloud_credentials',
  'custom'
];

// Operator UI for marking/unmarking a module as a honeypot canary
// (Track F-6). Confirms the security implication before flipping the bit.
export const CanaryMarker: React.FC<Props> = ({ module, onUpdated }) => {
  const { showNotification } = useNotifications();
  const honeypot = (module.config as { honeypot?: { canary?: boolean; lure_kind?: string; marked_at?: string } } | undefined)?.honeypot;
  const isCanary = honeypot?.canary === true;
  const [confirming, setConfirming] = useState(false);
  const [lureKind, setLureKind] = useState('credential_store');
  const [submitting, setSubmitting] = useState(false);

  const mark = async (): Promise<void> => {
    setSubmitting(true);
    try {
      const updated = await systemApi.markModuleAsCanary(module.id, lureKind);
      showNotification({
        type: 'success',
        message: `Module marked as honeypot canary (lure: ${lureKind})`
      });
      setConfirming(false);
      onUpdated?.(updated);
    } catch {
      showNotification({ type: 'error', message: 'Failed to mark as canary' });
    } finally {
      setSubmitting(false);
    }
  };

  const unmark = async (): Promise<void> => {
    setSubmitting(true);
    try {
      const updated = await systemApi.unmarkModuleAsCanary(module.id);
      showNotification({ type: 'success', message: 'Canary marker removed' });
      onUpdated?.(updated);
    } catch {
      showNotification({ type: 'error', message: 'Failed to remove canary marker' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="bg-theme-surface border border-theme-border rounded-lg p-4">
      <div className="flex items-center justify-between mb-2">
        <h3 className="text-sm font-semibold flex items-center gap-2">
          {isCanary ? <ShieldAlert size={14} className="text-theme-warning" /> : <Shield size={14} />}
          Honeypot Canary
        </h3>
        {isCanary && <Badge variant="warning">CANARY</Badge>}
      </div>
      <p className="text-xs text-theme-muted mb-3">
        Marking this module as a canary means any access (by external scanner or
        rogue AI agent) emits a critical-severity FleetEvent and routes through
        autonomy quarantine. The module remains operationally indistinguishable
        from a real one — only the security infrastructure knows the difference.
      </p>

      {isCanary ? (
        <div className="space-y-2">
          <div className="text-xs">
            <span className="text-theme-muted">Lure kind:</span>{' '}
            <code>{honeypot?.lure_kind}</code>
          </div>
          <div className="text-xs">
            <span className="text-theme-muted">Marked at:</span>{' '}
            {honeypot?.marked_at && new Date(honeypot.marked_at).toLocaleString()}
          </div>
          <Button size="sm" variant="secondary" onClick={unmark} disabled={submitting}>
            Remove Canary Marker
          </Button>
        </div>
      ) : confirming ? (
        <div className="space-y-3">
          <div>
            <label className="block text-xs text-theme-muted mb-1">Lure kind</label>
            <select
              value={lureKind}
              onChange={(e) => setLureKind(e.target.value)}
              className="w-full px-2 py-1.5 text-sm rounded border border-theme-border bg-theme-background"
            >
              {LURE_KINDS.map((kind) => (
                <option key={kind} value={kind}>{kind}</option>
              ))}
            </select>
          </div>
          <div className="flex gap-2">
            <Button size="sm" variant="primary" onClick={mark} disabled={submitting}>
              Confirm — Mark as Canary
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setConfirming(false)} disabled={submitting}>
              Cancel
            </Button>
          </div>
        </div>
      ) : (
        <Button size="sm" variant="secondary" onClick={() => setConfirming(true)}>
          Mark as Canary…
        </Button>
      )}
    </div>
  );
};

export default CanaryMarker;
