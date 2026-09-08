import React, { useState, useEffect, useRef } from 'react';
import { Route, Play } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { sdwanApi } from '../../../services/api/sdwanApi';
import { isPendingApproval } from '../../../services/api/helpers';
import { pendingApprovalNotice } from '../../../utils/pendingApproval';
import type {
  SdwanRoutePolicy,
  SdwanRoutePolicyScope,
  SdwanRoutePolicyDirection,
  SdwanRoutePolicyStatement,
  SdwanRoutePolicyCompiled,
  SdwanNetwork,
  SdwanPeer,
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
  const { hasPermission } = usePermissions();
  const isEdit = !!policy;
  // The preview walks three READ endpoints the modal's own manage permission
  // does not imply — permissions are flat, so a manage-only operator would get
  // a preview that 403s at every step. Offer it only when all three hold.
  const canPreviewCompile =
    hasPermission('system.sdwan.route_policies.read') &&
    hasPermission('system.sdwan.networks.read') &&
    hasPermission('system.sdwan.peers.read');
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

  // ──── Compile preview (IMP-d1900addb504) ─────────────────────────
  // GET route_policies/:id/compile?peer_id is per-PEER and needs a saved
  // policy, so the preview only exists on edit. Peers are network-scoped,
  // hence the network → peer cascade rather than one flat picker.
  const [previewOpen, setPreviewOpen] = useState(false);
  const [previewNetworkId, setPreviewNetworkId] = useState('');
  const [previewPeerId, setPreviewPeerId] = useState('');
  const [previewNetworks, setPreviewNetworks] = useState<SdwanNetwork[]>([]);
  const [previewPeers, setPreviewPeers] = useState<SdwanPeer[]>([]);
  const [compiled, setCompiled] = useState<SdwanRoutePolicyCompiled | null>(null);
  const [compiling, setCompiling] = useState(false);
  const [compileError, setCompileError] = useState<string | null>(null);
  // Monotonic request id: a compile that resolves after the operator moved on
  // must not paint its output under the peer now selected.
  const compileSeq = useRef(0);

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

  // Network list for the preview cascade. Loaded only once the operator opens
  // the preview: compiling is an optional step, and the common path through
  // this modal is edit-and-save, which must not pay for a request it ignores.
  useEffect(() => {
    if (!policy?.id || !previewOpen || !canPreviewCompile) return;
    let cancelled = false;
    sdwanApi
      .getNetworks()
      .then((r) => {
        if (cancelled) return;
        setPreviewNetworks(r.networks);
      })
      .catch((err) => {
        if (cancelled) return;
        setCompileError(
          `Could not load networks for the compile preview: ${err instanceof Error ? err.message : 'request failed'}`
        );
      });
    return () => {
      cancelled = true;
    };
  }, [policy?.id, previewOpen, canPreviewCompile]);

  // Peers for the chosen network. Changing the network invalidates both the
  // selected peer and any output already on screen — leaving the previous
  // peer's compiled config under a new network's name would misattribute it.
  useEffect(() => {
    compileSeq.current += 1;
    setPreviewPeerId('');
    setPreviewPeers([]);
    setCompiled(null);
    if (!previewNetworkId) return;
    let cancelled = false;
    sdwanApi
      .getPeers(previewNetworkId)
      .then((r) => {
        if (cancelled) return;
        setPreviewPeers(r.peers);
      })
      .catch((err) => {
        if (cancelled) return;
        setCompileError(
          `Could not load peers for that network: ${err instanceof Error ? err.message : 'request failed'}`
        );
      });
    return () => {
      cancelled = true;
    };
  }, [previewNetworkId]);

  // Changing the peer invalidates any output already on screen for the same
  // reason changing the network does — otherwise peer A's FRR config sits
  // under peer B's name with nothing saying which one produced it.
  const selectPreviewPeer = (peerId: string) => {
    compileSeq.current += 1;
    setPreviewPeerId(peerId);
    setCompiled(null);
    setCompileError(null);
  };

  const handlePreviewCompile = async () => {
    if (!policy?.id || !previewPeerId) return;
    const seq = ++compileSeq.current;
    setCompiling(true);
    setCompileError(null);
    try {
      const result = await sdwanApi.compileRoutePolicy(policy.id, previewPeerId);
      if (seq !== compileSeq.current) return;
      setCompiled(result.compiled);
    } catch (err) {
      if (seq !== compileSeq.current) return;
      setCompiled(null);
      setCompileError(err instanceof Error ? err.message : 'Compile failed');
    } finally {
      if (seq === compileSeq.current) setCompiling(false);
    }
  };

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
            <FormField
              label="Name"
              value={name}
              onChange={setName}
              nativeRequired
              maxLength={64}
              placeholder="e.g. prefer-internal-routes"
            />
          </div>
          <div>
            <FormField
              label="Direction"
              type="select"
              value={direction}
              onChange={(v) => setDirection(v as SdwanRoutePolicyDirection)}
              options={[
                { value: 'import', label: 'Import (inbound from neighbors)' },
                { value: 'export', label: 'Export (outbound to neighbors)' },
              ]}
            />
          </div>
        </div>

        <div>
          <FormField
            label="Description"
            value={description ?? ''}
            onChange={setDescription}
          />
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div>
            <FormField
              label="Scope"
              type="select"
              value={scope}
              onChange={(v) => setScope(v as SdwanRoutePolicyScope)}
              options={[
                { value: 'account', label: 'Account (every iBGP neighbor)' },
                { value: 'network', label: "Network (one network's neighbors)" },
                { value: 'peer', label: "Peer (one peer's neighbors)" },
              ]}
            />
          </div>
          {scope !== 'account' && (
            <FormField
              label={scope === 'network' ? 'Network ID' : 'Peer ID'}
              value={scopeResourceId ?? ''}
              onChange={setScopeResourceId}
              nativeRequired
              placeholder="UUID"
              className="font-mono"
            />
          )}
        </div>

        <div>
          <FormField
            label="Statements (ordered JSON array)"
            type="textarea"
            value={statementsJson}
            onChange={setStatementsJson}
            nativeRequired
            rows={14}
            disabled={statementsUnavailable}
            placeholder={statementsLoading ? 'Loading current statements…' : undefined}
            className="font-mono text-xs disabled:opacity-60"
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

        {isEdit && canPreviewCompile && (
          <section className="border border-theme rounded p-3 space-y-3">
            <div className="flex items-start justify-between gap-3">
              <div>
                <h3 className="text-sm font-medium text-theme-primary">Preview compiled output</h3>
                <p className="text-xs text-theme-secondary mt-0.5">
                  Compilation is per-peer and reflects <strong>every</strong> policy that applies to
                  that peer, not just this one. It reads the SAVED policy, so unsaved edits above
                  are not included.
                </p>
              </div>
              <Button
                variant="secondary"
                type="button"
                onClick={() => setPreviewOpen((open) => !open)}
              >
                {previewOpen ? 'Hide preview' : 'Show preview'}
              </Button>
            </div>

            {previewOpen && (
              <>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <FormField
                  label="Compile for network"
                  id="compile-network"
                  type="select"
                  value={previewNetworkId}
                  onChange={setPreviewNetworkId}
                  options={[
                    { value: '', label: 'Select a network…' },
                    ...previewNetworks.map((n) => ({ value: n.id, label: n.name })),
                  ]}
                />
              </div>
              {previewNetworkId && (
                <div>
                  <FormField
                    label="Compile for peer"
                    id="compile-peer"
                    type="select"
                    value={previewPeerId}
                    onChange={selectPreviewPeer}
                    options={[
                      { value: '', label: 'Select a peer…' },
                      ...previewPeers.map((p) => ({
                        value: p.id,
                        label: `${p.node_instance_id?.slice(0, 8) ?? p.id.slice(0, 8)} (${
                          p.publicly_reachable ? 'hub' : 'spoke'
                        })`,
                      })),
                    ]}
                  />
                </div>
              )}
            </div>

            <Button
              variant="secondary"
              type="button"
              onClick={handlePreviewCompile}
              disabled={compiling || !previewPeerId}
            >
              <Play size={14} />
              <span className="ml-1">{compiling ? 'Compiling…' : 'Preview compiled'}</span>
            </Button>

            {compileError && <ErrorAlert message={compileError} />}

            {compiled && (
              <div className="space-y-2">
                {(
                  [
                    ['Prefix lists', compiled.prefix_lists],
                    ['IPv6 prefix lists', compiled.ipv6_prefix_lists],
                    ['AS-path lists', compiled.as_path_lists],
                    ['Community lists', compiled.community_lists],
                    ['Route maps', compiled.route_maps],
                  ] as Array<[string, string[]]>
                ).map(([label, lines]) => (
                  <div key={label}>
                    <div className="text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">
                      {label}
                    </div>
                    {lines.length === 0 ? (
                      <p className="text-xs text-theme-tertiary">none</p>
                    ) : (
                      <pre className="text-xs font-mono text-theme-primary bg-theme-background-secondary rounded p-2 overflow-x-auto">
                        {lines.map((line) => (
                          <div key={line}>{line}</div>
                        ))}
                      </pre>
                    )}
                  </div>
                ))}
              </div>
            )}
              </>
            )}
          </section>
        )}

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
