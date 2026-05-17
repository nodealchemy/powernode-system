import React, { useEffect, useMemo, useState } from 'react';
import { Server, AlertCircle, X, Copy, Check, KeyRound } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { childrenApi } from '../../services/api/childrenApi';
import type { SpawnMode, SpawnResponse } from '../../types/spawn.types';

/**
 * Spawn-platform modal. Two phases:
 *
 *   Phase 1: form (spawn_mode + parent_url + template_id + region + TTL)
 *   Phase 2: show the acceptance token (ONCE — UI captures the only
 *            opportunity to display the plaintext)
 *
 * Plan reference: Decentralized Federation §H + P6.
 */

interface SpawnPlatformModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSpawned?: (response: SpawnResponse) => void;
}

const SPAWN_MODE_OPTIONS: Array<{ value: SpawnMode; label: string; help: string }> = [
  {
    value: 'managed_child',
    label: 'Managed Child',
    help: 'Parent retains operator-scope FederationGrant on child. Intervention policies cascade.',
  },
  {
    value: 'autonomous_peer',
    label: 'Autonomous Peer',
    help: 'Child is a peer post-handshake. No auto-grants; equal relationship.',
  },
  {
    value: 'cluster_member',
    label: 'Cluster Member',
    help: 'Child shares PG primary via streaming replication; Redis pointed at parent VIP.',
  },
];

const URL_PATTERN = /^https:\/\/[a-z0-9.-]+(:[0-9]+)?\/?$/i;

export const SpawnPlatformModal: React.FC<SpawnPlatformModalProps> = ({
  isOpen,
  onClose,
  onSpawned,
}) => {
  const [phase, setPhase] = useState<'form' | 'token'>('form');
  const [spawnMode, setSpawnMode] = useState<SpawnMode>('managed_child');
  const [parentUrl, setParentUrl] = useState('');
  const [templateId, setTemplateId] = useState('powernode-hub');
  const [region, setRegion] = useState('');
  const [ttlDays, setTtlDays] = useState('7');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [response, setResponse] = useState<SpawnResponse | null>(null);
  const [tokenCopied, setTokenCopied] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setPhase('form');
    setSpawnMode('managed_child');
    setParentUrl('');
    setTemplateId('powernode-hub');
    setRegion('');
    setTtlDays('7');
    setError(null);
    setResponse(null);
    setTokenCopied(false);
  }, [isOpen]);

  const validation = useMemo(() => {
    const errors: string[] = [];
    if (!parentUrl.trim()) errors.push('Parent URL is required.');
    else if (!URL_PATTERN.test(parentUrl.trim())) {
      errors.push('Parent URL must be https://... (the child needs to POST to it).');
    }
    if (!templateId.trim()) errors.push('Template ID is required.');
    const ttl = parseInt(ttlDays, 10);
    if (!Number.isFinite(ttl) || ttl < 1 || ttl > 30) {
      errors.push('Token TTL must be 1-30 days.');
    }
    return { ok: errors.length === 0, errors };
  }, [parentUrl, templateId, ttlDays]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validation.ok) {
      setError(validation.errors[0] ?? 'Form invalid');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const result = await childrenApi.spawn({
        spawn_mode: spawnMode,
        parent_url: parentUrl.trim(),
        spawn_target: {
          template_id: templateId.trim(),
          ...(region.trim() ? { region: region.trim() } : {}),
        },
        token_ttl_seconds: parseInt(ttlDays, 10) * 86_400,
      });
      setResponse(result);
      setPhase('token');
      onSpawned?.(result);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Spawn failed');
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
          <Server className="w-5 h-5 text-theme-info" />
          <span>{phase === 'form' ? 'Spawn Platform' : 'Spawn Token'}</span>
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
              {submitting ? 'Spawning…' : 'Spawn'}
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
            <label className="block text-xs font-medium text-theme-secondary mb-1">Spawn Mode</label>
            <div className="space-y-2">
              {SPAWN_MODE_OPTIONS.map((opt) => (
                <label
                  key={opt.value}
                  className={`block p-2 rounded border cursor-pointer ${
                    spawnMode === opt.value
                      ? 'border-theme-info bg-theme-info'
                      : 'border-theme bg-theme-background-secondary hover:bg-theme-surface-hover'
                  }`}
                >
                  <input
                    type="radio"
                    name="spawn_mode"
                    value={opt.value}
                    checked={spawnMode === opt.value}
                    onChange={() => setSpawnMode(opt.value)}
                    className="mr-2"
                  />
                  <span className="font-medium text-theme-primary">{opt.label}</span>
                  <span className="text-xs text-theme-secondary ml-2">— {opt.help}</span>
                </label>
              ))}
            </div>
          </div>

          <div>
            <label className="block text-xs font-medium text-theme-secondary mb-1">
              Parent URL
            </label>
            <input
              type="text"
              value={parentUrl}
              onChange={(e) => setParentUrl(e.target.value.trim())}
              disabled={submitting}
              required
              placeholder="https://hub.alice.tld"
              className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
            />
            <p className="text-xs text-theme-secondary mt-1">
              Reachable URL for the child's first-run handler to POST back to.
            </p>
          </div>

          <div className="grid grid-cols-3 gap-3">
            <div className="col-span-2">
              <label className="block text-xs font-medium text-theme-secondary mb-1">Template ID</label>
              <input
                type="text"
                value={templateId}
                onChange={(e) => setTemplateId(e.target.value)}
                disabled={submitting}
                required
                placeholder="powernode-hub"
                className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
              />
            </div>
            <div>
              <label className="block text-xs font-medium text-theme-secondary mb-1">Region</label>
              <input
                type="text"
                value={region}
                onChange={(e) => setRegion(e.target.value)}
                disabled={submitting}
                placeholder="us-west"
                className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
              />
            </div>
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
              How long the child has to accept before the token expires.
            </p>
          </div>
        </form>
      ) : (
        // Phase 2: token-shown-once
        response && (
          <div className="space-y-4">
            <div className="p-3 bg-theme-warning text-theme-warning text-sm rounded flex items-start gap-2">
              <KeyRound className="w-4 h-4 flex-shrink-0 mt-0.5" />
              <span>
                <strong>Capture this token now.</strong> The plaintext is shown only once.
                If lost, you must spawn again to get a new token.
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
                  className="px-3 py-1.5 border border-theme rounded bg-theme-info-solid text-white text-xs inline-flex items-center gap-1 hover:opacity-90"
                >
                  {tokenCopied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
                  {tokenCopied ? 'Copied' : 'Copy'}
                </button>
              </div>
            </div>

            <div>
              <label className="block text-xs font-medium text-theme-secondary mb-1">
                Spawn Payload (virtio-fw-cfg seed)
              </label>
              <pre className="text-xs bg-theme-background-secondary p-2 rounded overflow-x-auto font-mono text-theme-primary max-h-48">
                {JSON.stringify(response.spawn_payload, null, 2)}
              </pre>
              <p className="text-xs text-theme-secondary mt-1">
                The child's first-run handler reads this payload from
                virtio-fw-cfg and POSTs the acceptance_token to{' '}
                <code className="font-mono">{response.spawn_payload.parent_url as string}</code>
                /api/v1/system/federation_api/accept.
              </p>
            </div>

            <div className="text-xs text-theme-secondary">
              Child peer id: <code className="font-mono">{response.child.id}</code>
              {' · '}Status: <code className="font-mono">{response.child.status}</code>
            </div>
          </div>
        )
      )}
    </Modal>
  );
};
