import React, { useState } from 'react';
import { KeyRound, Download, Ban } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import { apiErrorMessage } from '@system/features/system/services/api/nodesApi';

interface OperatorKeyPanelProps {
  nodeId: string;
  instanceId: string;
}

interface MintedKey {
  tokenId: string;
  expiresAt: string;
  key: string;
  document: string | null;
}

export const PROVISION_FILENAME = 'powernode-provision.cfg';

/**
 * "Generate enrolment key" for one node instance (D4 key + D5 document).
 *
 * ONE-SHOT, and that is the design constraint (CryptoMaterialSafety):
 *
 *   - The key and provisioning document exist only in this component's state,
 *     from the mint response until the operator dismisses or revokes. They are
 *     never written to storage, logged, or re-fetched (no server URL serves
 *     them again).
 *   - The download is a Blob built here from that response; the object URL is
 *     revoked immediately after the click.
 *
 * The caller mounts this only for users holding system.instances.control
 * (permission-based; never roles).
 */
export const OperatorKeyPanel: React.FC<OperatorKeyPanelProps> = ({ nodeId, instanceId }) => {
  const { addNotification } = useNotifications();
  const [minted, setMinted] = useState<MintedKey | null>(null);
  const [busy, setBusy] = useState(false);

  const mint = async () => {
    setBusy(true);
    try {
      const res = await systemApi.mintOperatorKey(nodeId, instanceId, { includeProvisioningDocument: true });
      setMinted({
        tokenId: res.bootstrap_token.id,
        expiresAt: res.bootstrap_token.expires_at,
        key: res.token,
        document: res.provisioning_document ?? null,
      });
    } catch (error) {
      addNotification({ type: 'error', message: apiErrorMessage(error, 'Failed to generate enrolment key') });
    } finally {
      setBusy(false);
    }
  };

  const download = () => {
    if (!minted?.document) return;
    const url = URL.createObjectURL(new Blob([minted.document], { type: 'application/json' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = PROVISION_FILENAME;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  };

  const revoke = async () => {
    if (!minted) return;
    setBusy(true);
    try {
      await systemApi.revokeOperatorKey(nodeId, instanceId, minted.tokenId);
      setMinted(null);
      addNotification({ type: 'success', message: 'Enrolment key revoked.' });
    } catch (error) {
      addNotification({ type: 'error', message: apiErrorMessage(error, 'Failed to revoke enrolment key') });
    } finally {
      setBusy(false);
    }
  };

  if (!minted) {
    return (
      <div>
        <Button variant="secondary" size="sm" onClick={mint} disabled={busy}>
          <KeyRound className="w-4 h-4 mr-1" />
          Generate enrolment key
        </Button>
      </div>
    );
  }

  return (
    <div className="bg-theme-surface rounded p-3 border border-theme space-y-2 text-sm">
      <p className="text-theme-warning-fg text-xs font-medium">
        Shown once. Copy it or download the file now; it cannot be displayed again.
      </p>
      <code className="block font-mono text-xs text-theme-primary break-all select-all">{minted.key}</code>
      <p className="text-xs text-theme-secondary">
        Expires {new Date(minted.expiresAt).toLocaleString()}
      </p>
      <div className="flex flex-wrap gap-2">
        {minted.document && (
          <Button variant="primary" size="sm" onClick={download}>
            <Download className="w-4 h-4 mr-1" />
            Download {PROVISION_FILENAME}
          </Button>
        )}
        <Button variant="danger" size="sm" onClick={revoke} disabled={busy}>
          <Ban className="w-4 h-4 mr-1" />
          Revoke
        </Button>
        <Button variant="ghost" size="sm" onClick={() => setMinted(null)}>
          Done
        </Button>
      </div>
    </div>
  );
};

export default OperatorKeyPanel;
