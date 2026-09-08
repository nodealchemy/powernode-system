import React, { useState, useEffect } from 'react';
import { Route } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../../services/api/sdwanApi';
import { isPendingApproval } from '../../../services/api/helpers';
import { pendingApprovalNotice } from '../../../utils/pendingApproval';
import type {
  SdwanRoutePolicy,
  SdwanRoutePolicyScope,
  SdwanRoutePolicyDirection,
  SdwanRoutePolicyStatement,
} from '../../../types/sdwan.types';

interface RoutePolicyEditModalProps {
  policy?: SdwanRoutePolicy | null; // null = create
  onClose: () => void;
  onSaved: (policy: SdwanRoutePolicy) => void;
}

// Default statements payload — operators can replace wholesale.
const DEFAULT_STATEMENTS: SdwanRoutePolicyStatement[] = [
  {
    match: { prefix_in: ['10.0.0.0/8'] },
    action: { type: 'accept', set_local_pref: 200 },
  },
];

export const RoutePolicyEditModal: React.FC<RoutePolicyEditModalProps> = ({
  policy,
  onClose,
  onSaved,
}) => {
  const { addNotification } = useNotifications();
  const isEdit = !!policy;
  const [name, setName] = useState(policy?.name ?? '');
  const [description, setDescription] = useState(policy?.description ?? '');
  const [scope, setScope] = useState<SdwanRoutePolicyScope>(policy?.scope ?? 'account');
  const [scopeResourceId, setScopeResourceId] = useState(policy?.scope_resource_id ?? '');
  const [direction, setDirection] = useState<SdwanRoutePolicyDirection>(policy?.direction ?? 'import');
  const [enabled, setEnabled] = useState(policy?.enabled ?? true);
  // The list endpoint omits statements, so on edit the real ones arrive from the
  // backfill below. Seeding the editor with DEFAULT_STATEMENTS here would let an
  // early Save write the placeholder over the live policy, so the editor starts
  // empty on edit and the placeholder is only ever offered when creating.
  const needsStatementsBackfill = !!policy?.id && !policy.statements;
  const [statementsJson, setStatementsJson] = useState(
    needsStatementsBackfill ? '' : JSON.stringify(policy?.statements ?? DEFAULT_STATEMENTS, null, 2)
  );
  const [statementsLoading, setStatementsLoading] = useState(needsStatementsBackfill);
  const [statementsError, setStatementsError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // If editing, fetch full statements (the list endpoint omits them). Until this
  // resolves the form has no idea what the policy currently says, so Save stays
  // blocked — and stays blocked for good if the fetch fails.
  useEffect(() => {
    if (!policy?.id || policy.statements) {
      // No backfill is owed for this policy — release any gate a previous one set,
      // so a caller that reuses this instance is not left with a dead form.
      setStatementsLoading(false);
      setStatementsError(null);
      return;
    }
    let cancelled = false;
    setStatementsLoading(true);
    setStatementsError(null);
    sdwanApi.getRoutePolicy(policy.id).then((p) => {
      if (cancelled) return;
      if (p.statements) {
        setStatementsJson(JSON.stringify(p.statements, null, 2));
      } else {
        setStatementsError(
          'Could not load the current statements for this policy — the server returned none. Close and reopen to retry; saving is blocked so the live policy is not overwritten.'
        );
      }
      setStatementsLoading(false);
    }).catch((err) => {
      if (cancelled) return;
      setStatementsError(
        `Could not load the current statements for this policy: ${err instanceof Error ? err.message : 'request failed'}. Close and reopen to retry; saving is blocked so the live policy is not overwritten.`
      );
      setStatementsLoading(false);
    });
    return () => {
      cancelled = true;
    };
  }, [policy?.id, policy?.statements]);

  // Enter in a text field submits the form, so the disabled button is not the
  // only entry point — the guard has to live in the handler too.
  const statementsUnavailable = statementsLoading || !!statementsError;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (statementsUnavailable) return;
    setSubmitting(true);
    try {
      let parsedStatements: SdwanRoutePolicyStatement[];
      try {
        parsedStatements = JSON.parse(statementsJson);
        if (!Array.isArray(parsedStatements)) {
          throw new Error('statements must be a JSON array');
        }
      } catch (parseErr) {
        throw new Error(`Invalid JSON in statements: ${parseErr instanceof Error ? parseErr.message : 'parse error'}`);
      }

      const payload = {
        name,
        description: description || undefined,
        scope,
        scope_resource_id: scope === 'account' ? null : scopeResourceId || null,
        direction,
        enabled,
        statements: parsedStatements,
      };

      const saved = isEdit
        ? await sdwanApi.updateRoutePolicy(policy!.id, payload)
        : await sdwanApi.createRoutePolicy(payload);
      if (isPendingApproval(saved)) {
        addNotification(pendingApprovalNotice(`${isEdit ? 'updating' : 'creating'} route policy '${name}'`, saved));
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
    <Modal isOpen onClose={onClose} title={isEdit ? `Edit policy — ${policy!.name}` : 'New route policy'} icon={<Route className="w-6 h-6" />} size="lg">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Name</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              maxLength={64}
              placeholder="e.g. prefer-internal-routes"
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Direction</label>
            <select
              value={direction}
              onChange={(e) => setDirection(e.target.value as SdwanRoutePolicyDirection)}
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
            >
              <option value="import">Import (inbound from neighbors)</option>
              <option value="export">Export (outbound to neighbors)</option>
            </select>
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">Description</label>
          <input
            type="text"
            value={description ?? ''}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
          />
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Scope</label>
            <select
              value={scope}
              onChange={(e) => setScope(e.target.value as SdwanRoutePolicyScope)}
              className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary"
            >
              <option value="account">Account (every iBGP neighbor)</option>
              <option value="network">Network (one network's neighbors)</option>
              <option value="peer">Peer (one peer's neighbors)</option>
            </select>
          </div>
          {scope !== 'account' && (
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">
                {scope === 'network' ? 'Network ID' : 'Peer ID'}
              </label>
              <input
                type="text"
                value={scopeResourceId ?? ''}
                onChange={(e) => setScopeResourceId(e.target.value)}
                required
                placeholder="UUID"
                className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary font-mono"
              />
            </div>
          )}
        </div>

        <div>
          <label className="block text-sm font-medium text-theme-primary mb-1">
            Statements (ordered JSON array)
          </label>
          <textarea
            value={statementsJson}
            onChange={(e) => setStatementsJson(e.target.value)}
            required
            rows={14}
            disabled={statementsUnavailable}
            placeholder={statementsLoading ? 'Loading current statements…' : undefined}
            className="w-full px-3 py-2 rounded bg-theme-surface border border-theme text-theme-primary font-mono text-xs disabled:opacity-60"
            spellCheck={false}
          />
          {statementsLoading && (
            <div className="mt-1 text-xs text-theme-secondary">
              Loading the policy&apos;s current statements…
            </div>
          )}
          {statementsError && (
            <div className="mt-2">
              <ErrorAlert message={statementsError} />
            </div>
          )}
          <div className="mt-1 text-xs text-theme-secondary">
            Each statement is <code className="font-mono">{'{ match: {...}, action: {...} }'}</code>. Match keys:{' '}
            <code className="font-mono">prefix_in</code>, <code className="font-mono">as_path_regex</code>,{' '}
            <code className="font-mono">community_in</code>. Action keys: <code className="font-mono">type</code>{' '}
            (accept|reject), <code className="font-mono">set_local_pref</code>, <code className="font-mono">set_med</code>,{' '}
            <code className="font-mono">prepend_as_path</code>, <code className="font-mono">add_community</code>.
          </div>
        </div>

        <div className="flex items-center gap-2">
          <input
            type="checkbox"
            id="enabled"
            checked={enabled}
            onChange={(e) => setEnabled(e.target.checked)}
          />
          <label htmlFor="enabled" className="text-sm text-theme-primary">
            Enabled (compiles into FRR; disable to draft a policy without applying it)
          </label>
        </div>

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={onClose} type="button">
            Cancel
          </Button>
          <Button variant="primary" type="submit" disabled={submitting || statementsUnavailable}>
            {submitting ? 'Saving…' : isEdit ? 'Save changes' : 'Create policy'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
