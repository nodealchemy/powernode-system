import React, { useState, useEffect } from 'react';
import { KeyRound, ShieldCheck, ShieldOff } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import { apiErrorMessage } from '@system/features/system/services/api/nodesApi';
import type {
  ClaudeCodeCredential,
  ClaudeCodeCredentialPayload,
  ClaudeCodeOauthPayload
} from '@system/features/system/services/api/nodesApi';

interface ClaudeCodeCredentialPanelProps {
  nodeId: string;
  instanceId: string;
}

type CredentialKind = 'api_key' | 'oauth';

/**
 * Operator panel for a NodeInstance's Claude Code CLI credential — the secret
 * the claude-tmux NodeModule fetches at boot.
 *
 * WRITE-ONLY, and that is the whole design constraint (CryptoMaterialSafety):
 *
 *   - The stored secret is never fetched. The API has no read path for it and
 *     this panel asks for none; all it ever shows is the index card the
 *     controller serializes — kind, presence, timestamps.
 *   - What the operator types is held only long enough to POST it. Every exit
 *     from `submit` clears the field, success or failure, so the value is not
 *     sitting in component state (or in a React DevTools tree, or in a
 *     component's props on the next render) after the request.
 *   - Nothing here logs, echoes, or renders the typed value. Errors surface the
 *     server's own sentence, read out of the error envelope rather than off
 *     the axios Error (whose message is only the status line); the controller
 *     writes those to name FIELDS rather than values.
 *
 * The API-key field is a password input so it is masked while typing and kept
 * out of browser autofill. The OAuth blob cannot be masked — it is a JSON
 * object the operator pastes — so it gets the same clear-on-submit treatment
 * and is never re-rendered from anything but the operator's own keystrokes.
 */
export const ClaudeCodeCredentialPanel: React.FC<ClaudeCodeCredentialPanelProps> = ({
  nodeId,
  instanceId
}) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const { confirm, close: closeConfirmation, ConfirmationDialog } = useConfirmation();

  const canRead = hasPermission('system.node_instance_credentials.read');
  const canManage = hasPermission('system.node_instance_credentials.manage');

  const [credential, setCredential] = useState<ClaudeCodeCredential | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [formOpen, setFormOpen] = useState(false);
  const [kind, setKind] = useState<CredentialKind>('api_key');
  // The plaintext, for as long as it takes to send it. Cleared by `submit` on
  // every exit — see the component docblock.
  const [apiKey, setApiKey] = useState('');
  const [oauthText, setOauthText] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);

  useEffect(() => {
    if (!canRead) {
      setLoading(false);
      return;
    }
    // Guarded rather than fire-and-forget: this panel takes its subject from a
    // prop, so a slow response for the previous instance must not land on the
    // one now on screen and label it with another instance's credential.
    let cancelled = false;
    setLoading(true);
    setLoadError(null);
    setCredential(null);

    void (async () => {
      try {
        const found = await systemApi.getClaudeCodeCredential(nodeId, instanceId);
        if (!cancelled) setCredential(found);
      } catch (err) {
        if (cancelled) return;
        setCredential(null);
        setLoadError(apiErrorMessage(err, 'Failed to load credential status'));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
  }, [canRead, nodeId, instanceId]);

  // The panel lives inside a permanently-mounted modal, so a pending
  // confirmation and a half-typed secret must not survive a move to another
  // instance.
  useEffect(() => {
    setFormOpen(false);
    setApiKey('');
    setOauthText('');
    setFormError(null);
    closeConfirmation();
  }, [instanceId, closeConfirmation]);

  if (!canRead) return null;

  const openForm = (nextKind: CredentialKind) => {
    setKind(nextKind);
    setApiKey('');
    setOauthText('');
    setFormError(null);
    setFormOpen(true);
  };

  const buildPayload = (): ClaudeCodeCredentialPayload | null => {
    if (kind === 'api_key') {
      if (!apiKey.trim()) {
        setFormError('An API key is required.');
        return null;
      }
      return { api_key: apiKey.trim() };
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(oauthText);
    } catch {
      // Deliberately not interpolating the parser message: it can quote the
      // offending text, which here is the credential blob.
      setFormError('That is not valid JSON. Paste the claudeAiOauth object from ~/.claude/.credentials.json.');
      return null;
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      setFormError('The OAuth payload must be a JSON object.');
      return null;
    }
    return { oauth: parsed as ClaudeCodeOauthPayload };
  };

  const submit = async () => {
    const payload = buildPayload();
    if (!payload) return;

    const rotating = credential !== null;
    setSubmitting(true);
    setFormError(null);
    try {
      const saved = rotating
        ? await systemApi.rotateClaudeCodeCredential(nodeId, instanceId, payload)
        : await systemApi.setClaudeCodeCredential(nodeId, instanceId, payload);
      setCredential(saved);
      setFormOpen(false);
      addNotification({
        type: 'success',
        message: rotating ? 'Claude Code credential rotated' : 'Claude Code credential stored'
      });
    } catch (err) {
      // The server's message names fields, never values.
      setFormError(apiErrorMessage(err, 'Failed to store the credential'));
    } finally {
      // Unconditional: the typed secret is dropped whether the request
      // succeeded, was refused, or threw. Nothing is worth a retry that keeps
      // key material alive in component state.
      setApiKey('');
      setOauthText('');
      setSubmitting(false);
    }
  };

  const handleRemove = () => {
    confirm({
      title: 'Remove Claude Code credential',
      message:
        'The stored secret is deleted from Vault and this instance can no longer fetch it at boot. ' +
        'It cannot be recovered — you would have to supply it again.',
      confirmLabel: 'Remove credential',
      cancelLabel: 'Keep credential',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deleteClaudeCodeCredential(nodeId, instanceId);
          setCredential(null);
          addNotification({ type: 'success', message: 'Claude Code credential removed' });
        } catch (err) {
          addNotification({
            type: 'error',
            message: `Failed to remove credential: ${apiErrorMessage(err, 'An error occurred')}`
          });
        }
      }
    });
  };

  return (
    <div className="bg-theme-surface rounded p-3 border border-theme">
      <div className="flex items-center justify-between gap-2 mb-2">
        <div className="flex items-center gap-2">
          <KeyRound className="w-4 h-4 text-theme-secondary" />
          <span className="text-xs font-semibold text-theme-secondary uppercase tracking-wide">
            Claude Code credential
          </span>
        </div>

        {!loading && !loadError && (
          credential ? (
            <div className="flex items-center gap-2">
              <ShieldCheck className="w-4 h-4 text-theme-success-fg" />
              <Badge variant="success" size="xs">Configured</Badge>
              <Badge variant="secondary" size="xs">{credential.credential_kind}</Badge>
            </div>
          ) : (
            <div className="flex items-center gap-2">
              <ShieldOff className="w-4 h-4 text-theme-tertiary" />
              <Badge variant="secondary" size="xs">Not configured</Badge>
            </div>
          )
        )}
      </div>

      {loading ? (
        <div className="flex items-center gap-2 text-sm text-theme-secondary">
          <LoadingSpinner size="sm" />
          <span>Checking credential status…</span>
        </div>
      ) : loadError ? (
        <p className="text-sm text-theme-error-fg">{loadError}</p>
      ) : (
        <>
          <p className="text-xs text-theme-secondary mb-2">
            {credential ? (
              <>Last changed {new Date(credential.updated_at).toLocaleString()}. The stored secret is
              write-only — it can be replaced or removed, never read back.</>
            ) : (
              <>No secret stored. The claude-tmux module on this instance has nothing to fetch at boot.</>
            )}
          </p>

          {canManage && !formOpen && (
            <div className="flex flex-wrap items-center gap-2">
              <Button variant="outline" size="sm" onClick={() => openForm(credential?.credential_kind ?? 'api_key')}>
                {credential ? 'Rotate' : 'Set credential'}
              </Button>
              {credential && (
                <Button
                  variant="outline"
                  size="sm"
                  onClick={handleRemove}
                  className="text-theme-error-fg border-theme-error-border hover:bg-theme-error-bg"
                >
                  Remove
                </Button>
              )}
            </div>
          )}

          {canManage && formOpen && (
            <div className="space-y-3 mt-2">
              {formError && <p className="text-sm text-theme-error-fg">{formError}</p>}

              <div>
                <label className="block text-xs text-theme-secondary mb-1" htmlFor={`cred-kind-${instanceId}`}>
                  Credential kind
                </label>
                <select
                  id={`cred-kind-${instanceId}`}
                  value={kind}
                  onChange={(e) => {
                    // Switching kind drops whatever was typed for the other
                    // one rather than carrying it along unsent.
                    setKind(e.target.value as CredentialKind);
                    setApiKey('');
                    setOauthText('');
                    setFormError(null);
                  }}
                  // Rotation cannot change the kind — the server refuses it so
                  // the old kind's Vault entry is never orphaned.
                  disabled={submitting || credential !== null}
                  className="w-full px-2 py-1 text-sm rounded border border-theme bg-theme-background text-theme-primary"
                >
                  <option value="api_key">Anthropic API key</option>
                  <option value="oauth">Claude subscription (OAuth)</option>
                </select>
                {credential && (
                  <p className="text-xs text-theme-tertiary mt-1">
                    A rotation keeps the existing kind. To switch, remove the credential and set a new one.
                  </p>
                )}
              </div>

              {kind === 'api_key' ? (
                <div>
                  <label className="block text-xs text-theme-secondary mb-1" htmlFor={`cred-api-key-${instanceId}`}>
                    API key
                  </label>
                  <input
                    id={`cred-api-key-${instanceId}`}
                    type="password"
                    value={apiKey}
                    onChange={(e) => setApiKey(e.target.value)}
                    disabled={submitting}
                    // Chrome ignores "off" on a password field; "new-password"
                    // is the value it honours, and keeping this out of the
                    // password manager is the point.
                    autoComplete="new-password"
                    spellCheck={false}
                    placeholder="Paste the Anthropic API key"
                    className="w-full px-2 py-1 text-sm font-mono rounded border border-theme bg-theme-background text-theme-primary"
                  />
                </div>
              ) : (
                <div>
                  <label className="block text-xs text-theme-secondary mb-1" htmlFor={`cred-oauth-${instanceId}`}>
                    claudeAiOauth JSON
                  </label>
                  <textarea
                    id={`cred-oauth-${instanceId}`}
                    value={oauthText}
                    onChange={(e) => setOauthText(e.target.value)}
                    disabled={submitting}
                    autoComplete="off"
                    spellCheck={false}
                    rows={5}
                    placeholder='{"accessToken": "…", "refreshToken": "…", "expiresAt": 1780000000000}'
                    className="w-full px-2 py-1 text-sm font-mono rounded border border-theme bg-theme-background text-theme-primary"
                  />
                  <p className="text-xs text-theme-tertiary mt-1">
                    The claudeAiOauth object from ~/.claude/.credentials.json. expiresAt is epoch
                    milliseconds.
                  </p>
                </div>
              )}

              <div className="flex items-center gap-2">
                <Button variant="primary" size="sm" onClick={submit} disabled={submitting}>
                  {submitting && <LoadingSpinner size="sm" className="mr-2" />}
                  {credential ? 'Rotate credential' : 'Store credential'}
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={submitting}
                  onClick={() => {
                    setFormOpen(false);
                    setApiKey('');
                    setOauthText('');
                    setFormError(null);
                  }}
                >
                  Cancel
                </Button>
              </div>
            </div>
          )}
        </>
      )}

      {ConfirmationDialog}
    </div>
  );
};

export default ClaudeCodeCredentialPanel;
