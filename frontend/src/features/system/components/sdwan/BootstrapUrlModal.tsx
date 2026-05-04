import React, { useState } from 'react';
import { Copy, Check } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import type { SdwanIssueUserDeviceResponse } from '../../types/sdwan.types';

interface BootstrapUrlModalProps {
  isOpen: boolean;
  result: SdwanIssueUserDeviceResponse | null;
  onClose: () => void;
}

/**
 * BootstrapUrlModal — shown ONCE after issuing a user device. The
 * bootstrap URL is single-use server-side; the modal includes a "copy"
 * button + an explicit one-time-only warning so operators understand
 * they can't reload to retrieve it.
 *
 * The full URL is computed by joining `window.location.origin` with the
 * server-supplied path. The token is the entire opaque blob — the
 * server validates it via Rails MessageVerifier on consumption.
 */
export const BootstrapUrlModal: React.FC<BootstrapUrlModalProps> = ({ isOpen, result, onClose }) => {
  const [copied, setCopied] = useState(false);

  if (!result) return null;

  const fullUrl = `${window.location.origin}${result.bootstrap.url}`;

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(fullUrl);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // clipboard API unavailable in this context — fall back to selection prompt
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={`Bootstrap URL — ${result.user_device.label}`}>
      <div className="space-y-4">
        <div className="p-3 bg-theme-warning-bg border border-theme-warning rounded text-sm">
          <strong className="text-theme-warning">Single-use, expires {new Date(result.bootstrap.expires_at).toLocaleString()}.</strong>
          <p className="text-theme-secondary mt-1">
            Send this URL to the user via any channel (Slack, email, signed message). The server returns
            the WireGuard config exactly once. After it's been fetched, this URL becomes 410 Gone — issue
            a new device if it gets lost in transit.
          </p>
        </div>

        <div>
          <label className="block text-xs text-theme-secondary mb-1">Bootstrap URL</label>
          <div className="flex gap-2">
            <input
              type="text" value={fullUrl} readOnly
              onFocus={(e) => e.currentTarget.select()}
              className="flex-1 p-2 bg-theme-input border border-theme-border rounded text-theme-primary font-mono text-xs"
            />
            <Button variant="secondary" onClick={handleCopy} type="button">
              {copied ? <Check size={16} /> : <Copy size={16} />}
              <span className="ml-1">{copied ? 'Copied' : 'Copy'}</span>
            </Button>
          </div>
        </div>

        <div className="text-xs text-theme-secondary">
          <div>Device address: <span className="font-mono">{result.user_device.assigned_address}</span></div>
          <div>Public key: <span className="font-mono">{result.user_device.public_key}</span></div>
        </div>

        <div className="flex justify-end pt-2">
          <Button variant="primary" onClick={onClose}>Done</Button>
        </div>
      </div>
    </Modal>
  );
};
