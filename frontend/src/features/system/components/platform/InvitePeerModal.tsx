import React, { useEffect, useMemo, useState } from 'react';
import { Network, AlertCircle, X, Copy, Check, KeyRound, Plus, Trash2 } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { platformPeersApi } from '../../services/api/platformPeersApi';
import type {
  EndpointScope,
  InvitePeerResponse,
  SpawnMode,
  SpawnRole,
} from '../../types/peer.types';

/**
 * Invite-peer modal. Two phases:
 *
 *   Phase 1: form (remote URL + spawn_role + spawn_mode + endpoint list + TTL)
 *   Phase 2: show the acceptance token (ONCE — UI captures the only
 *            opportunity to display the plaintext)
 *
 * Distinct from SpawnPlatformModal: spawn modal *provisions* a new
 * child platform; this modal records intent to peer with an existing
 * remote platform that the operator already runs (or will run).
 *
 * Plan reference: Decentralized Federation §I + P7.1.
 */

interface InvitePeerModalProps {
  isOpen: boolean;
  onClose: () => void;
  onInvited?: (response: InvitePeerResponse) => void;
}

interface EndpointRow {
  url: string;
  scope: EndpointScope;
  priority: number;
}

const ROLE_OPTIONS: Array<{ value: SpawnRole; label: string; help: string }> = [
  {
    value: 'symmetric',
    label: 'Symmetric Peer',
    help: 'Equal peer — no parent/child relationship. Most common for cross-org federation.',
  },
  {
    value: 'child',
    label: 'I am the child',
    help: 'Remote platform spawned us. Use this only when reconstructing a child-side row manually.',
  },
];

const MODE_OPTIONS: Array<{ value: SpawnMode; label: string }> = [
  { value: 'out_of_band', label: 'Out-of-band (manual exchange)' },
  { value: 'autonomous_peer', label: 'Autonomous Peer' },
  { value: 'managed_child', label: 'Managed Child' },
  { value: 'cluster_member', label: 'Cluster Member' },
];

const URL_PATTERN = /^https:\/\/[a-z0-9.-]+(:[0-9]+)?\/?$/i;

export const InvitePeerModal: React.FC<InvitePeerModalProps> = ({
  isOpen,
  onClose,
  onInvited,
}) => {
  const [phase, setPhase] = useState<'form' | 'token'>('form');
  const [remoteUrl, setRemoteUrl] = useState('');
  const [spawnRole, setSpawnRole] = useState<SpawnRole>('symmetric');
  const [spawnMode, setSpawnMode] = useState<SpawnMode>('out_of_band');
  const [endpoints, setEndpoints] = useState<EndpointRow[]>([]);
  const [ttlDays, setTtlDays] = useState('7');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [response, setResponse] = useState<InvitePeerResponse | null>(null);
  const [tokenCopied, setTokenCopied] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setPhase('form');
    setRemoteUrl('');
    setSpawnRole('symmetric');
    setSpawnMode('out_of_band');
    setEndpoints([]);
    setTtlDays('7');
    setError(null);
    setResponse(null);
    setTokenCopied(false);
  }, [isOpen]);

  // Seed the WAN endpoint from the remote URL when none has been added
  // explicitly. The user can still add LAN / SDWAN scopes via "Add
  // Endpoint".
  const effectiveEndpoints = useMemo<EndpointRow[]>(() => {
    if (endpoints.length > 0) return endpoints;
    if (!remoteUrl.trim() || !URL_PATTERN.test(remoteUrl.trim())) return [];
    return [{ url: remoteUrl.trim(), scope: 'wan', priority: 100 }];
  }, [endpoints, remoteUrl]);

  const validation = useMemo(() => {
    const errors: string[] = [];
    if (!remoteUrl.trim()) errors.push('Remote URL is required.');
    else if (!URL_PATTERN.test(remoteUrl.trim())) {
      errors.push('Remote URL must be https://... (no trailing path).');
    }
    const ttl = parseInt(ttlDays, 10);
    if (!Number.isFinite(ttl) || ttl < 1 || ttl > 30) {
      errors.push('Token TTL must be 1-30 days.');
    }
    endpoints.forEach((e, idx) => {
      if (!URL_PATTERN.test(e.url.trim())) {
        errors.push(`Endpoint #${idx + 1} URL is invalid.`);
      }
    });
    return { ok: errors.length === 0, errors };
  }, [remoteUrl, ttlDays, endpoints]);

  const handleAddEndpoint = () => {
    setEndpoints((prev) => [
      ...prev,
      { url: '', scope: 'lan', priority: 1 + prev.length * 10 },
    ]);
  };

  const handleUpdateEndpoint = (idx: number, patch: Partial<EndpointRow>) => {
    setEndpoints((prev) => prev.map((e, i) => (i === idx ? { ...e, ...patch } : e)));
  };

  const handleRemoveEndpoint = (idx: number) => {
    setEndpoints((prev) => prev.filter((_, i) => i !== idx));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validation.ok) {
      setError(validation.errors[0] ?? 'Form invalid');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const result = await platformPeersApi.invite({
        remote_instance_url: remoteUrl.trim(),
        spawn_role: spawnRole,
        spawn_mode: spawnMode,
        endpoints: effectiveEndpoints,
        token_ttl_seconds: parseInt(ttlDays, 10) * 86_400,
      });
      setResponse(result);
      setPhase('token');
      onInvited?.(result);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Invite failed');
    } finally {
      setSubmitting(false);
    }
  };

  const handleCopyToken = async () => {
    if (!response) return;
    try {
      await navigator.clipboard.writeText(response.acceptance_token);
      setTokenCopied(true);
      setTimeout(() => setTokenCopied(false), 2000);
    } catch {
      // Clipboard API unavailable — operator can select + copy manually
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <div className="flex items-center gap-2">
          <Network className="w-5 h-5 text-theme-info" />
          <span>{phase === 'form' ? 'Invite Peer' : 'Acceptance Token'}</span>
        </div>
      }
      maxWidth="2xl"
      footer={
        phase === 'form' ? (
          <div className="flex items-center justify-end gap-2">
            <Button variant="ghost" onClick={onClose} disabled={submitting}>
              Cancel
            </Button>
            <Button variant="primary" onClick={handleSubmit} disabled={submitting || !validation.ok}>
              {submitting ? 'Inviting…' : 'Invite'}
            </Button>
          </div>
        ) : (
          <div className="flex items-center justify-end">
            <Button variant="primary" onClick={onClose}>
              Done
            </Button>
          </div>
        )
      }
    >
      {phase === 'form' ? (
        <form onSubmit={handleSubmit} className="space-y-4">
          {error && (
            <div className="p-2 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm rounded">
              <AlertCircle className="w-4 h-4" />
              <span className="flex-1">{error}</span>
              <button type="button" onClick={() => setError(null)} className="p-1">
                <X className="w-3 h-3" />
              </button>
            </div>
          )}

          <div>
            <label className="block text-xs font-medium text-theme-secondary mb-1">
              Remote Instance URL
            </label>
            <input
              type="text"
              value={remoteUrl}
              onChange={(e) => setRemoteUrl(e.target.value.trim())}
              disabled={submitting}
              required
              placeholder="https://hub.bob.tld"
              className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
            />
            <p className="text-xs text-theme-secondary mt-1">
              The remote platform's public hub URL. They'll need to POST your token to
              <code className="font-mono mx-1">/api/v1/system/federation_api/accept</code>
              to complete the handshake.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs font-medium text-theme-secondary mb-1">Role</label>
              <select
                value={spawnRole}
                onChange={(e) => setSpawnRole(e.target.value as SpawnRole)}
                disabled={submitting}
                className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 text-sm"
              >
                {ROLE_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
              <p className="text-xs text-theme-secondary mt-1">
                {ROLE_OPTIONS.find((o) => o.value === spawnRole)?.help}
              </p>
            </div>
            <div>
              <label className="block text-xs font-medium text-theme-secondary mb-1">Mode</label>
              <select
                value={spawnMode}
                onChange={(e) => setSpawnMode(e.target.value as SpawnMode)}
                disabled={submitting}
                className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 text-sm"
              >
                {MODE_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
              <p className="text-xs text-theme-secondary mt-1">
                Out-of-band is the default for symmetric peerings.
              </p>
            </div>
          </div>

          <div>
            <div className="flex items-center justify-between mb-1">
              <label className="block text-xs font-medium text-theme-secondary">
                Endpoints (optional — defaults to remote URL as WAN)
              </label>
              <button
                type="button"
                onClick={handleAddEndpoint}
                className="text-xs text-theme-info hover:underline inline-flex items-center gap-1"
              >
                <Plus className="w-3 h-3" /> Add Endpoint
              </button>
            </div>
            {endpoints.length === 0 ? (
              <div className="text-xs text-theme-tertiary p-2 bg-theme-background-secondary rounded">
                One WAN endpoint will be auto-derived from the remote URL above.
              </div>
            ) : (
              <div className="space-y-2">
                {endpoints.map((ep, idx) => (
                  <div key={idx} className="flex items-center gap-2">
                    <input
                      type="text"
                      value={ep.url}
                      onChange={(e) => handleUpdateEndpoint(idx, { url: e.target.value.trim() })}
                      disabled={submitting}
                      placeholder="https://lan-hub.bob.tld"
                      className="flex-1 px-2 py-1 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-xs"
                    />
                    <select
                      value={ep.scope}
                      onChange={(e) => handleUpdateEndpoint(idx, { scope: e.target.value as EndpointScope })}
                      disabled={submitting}
                      className="px-2 py-1 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 text-xs"
                    >
                      <option value="lan">lan</option>
                      <option value="sdwan">sdwan</option>
                      <option value="wan">wan</option>
                    </select>
                    <input
                      type="number"
                      value={ep.priority}
                      onChange={(e) => handleUpdateEndpoint(idx, { priority: parseInt(e.target.value, 10) || 0 })}
                      disabled={submitting}
                      className="w-20 px-2 py-1 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-xs"
                      title="priority (lower = preferred)"
                    />
                    <button
                      type="button"
                      onClick={() => handleRemoveEndpoint(idx)}
                      title="Remove endpoint"
                      className="p-1 text-theme-danger hover:bg-theme-surface-hover rounded transition-colors"
                    >
                      <Trash2 className="w-3 h-3" />
                    </button>
                  </div>
                ))}
              </div>
            )}
            <p className="text-xs text-theme-secondary mt-1">
              Lower priority wins. Federation client probes LAN → SDWAN → WAN with 200ms fast-fail.
            </p>
          </div>

          <div>
            <label className="block text-xs font-medium text-theme-secondary mb-1">
              Acceptance Token TTL (days, 1-30)
            </label>
            <input
              type="number"
              min={1}
              max={30}
              value={ttlDays}
              onChange={(e) => setTtlDays(e.target.value)}
              disabled={submitting}
              className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
            />
            <p className="text-xs text-theme-secondary mt-1">
              How long the remote operator has to accept before the token expires.
            </p>
          </div>
        </form>
      ) : (
        response && (
          <div className="space-y-4">
            <div className="p-3 bg-theme-warning text-theme-warning text-sm rounded flex items-start gap-2">
              <KeyRound className="w-4 h-4 flex-shrink-0 mt-0.5" />
              <span>
                <strong>Capture this token now.</strong> The plaintext is shown only once.
                If lost, you must revoke this peer and invite again.
              </span>
            </div>

            <div>
              <label className="block text-xs font-medium text-theme-secondary mb-1">
                Acceptance Token
              </label>
              <div className="flex items-stretch gap-2">
                <input
                  type="text"
                  readOnly
                  value={response.acceptance_token}
                  className="flex-1 px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary font-mono text-xs select-all"
                />
                <button
                  type="button"
                  onClick={handleCopyToken}
                  className="px-3 py-1.5 border border-theme rounded bg-theme-info-solid text-white text-xs inline-flex items-center gap-1 hover:opacity-90 transition-opacity"
                >
                  {tokenCopied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
                  {tokenCopied ? 'Copied' : 'Copy'}
                </button>
              </div>
              <p className="text-xs text-theme-secondary mt-1">
                Hand this to the remote operator. They invoke
                <code className="font-mono mx-1">POST {response.peer.remote_instance_url}/api/v1/system/federation_api/accept</code>
                with body
                <code className="font-mono mx-1">{`{ acceptance_token: "..." }`}</code>
                to complete the handshake.
              </p>
            </div>

            <div className="text-xs text-theme-secondary">
              Peer id: <code className="font-mono">{response.peer.id}</code>
              {' · '}Status: <code className="font-mono">{response.peer.status}</code>
              {' · '}Expires: <code className="font-mono">{response.peer.acceptance_expires_at
                ? new Date(response.peer.acceptance_expires_at).toLocaleString()
                : '—'}</code>
            </div>
          </div>
        )
      )}
    </Modal>
  );
};
