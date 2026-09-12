import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  ShieldCheck,
  X,
  Plus,
  Trash2,
  Clock,
  Filter,
} from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useReasonConfirm } from '../../hooks/useReasonConfirm';
import { peerGrantsApi } from '../../services/api/peerGrantsApi';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import type {
  FederationGrant,
  GrantLifecycle,
  GrantScope,
  IssueGrantRequest,
} from '../../types/grant.types';

/**
 * Per-peer FederationGrant management modal. Two-section layout:
 *
 *   - Top: filterable list of grants (active / expired / revoked / archived)
 *   - Bottom: collapsible "Issue New Grant" form
 *
 * Pessimistic-scope allowlists (node_instance_ids / sdwan_network_ids /
 * source_cidrs) are required on every axis — concrete entries, or `*` for
 * any; the server refuses a blank axis — and exposed via comma-separated
 * text inputs. Full
 * relation-pickers are queued for the unified /app/system/network view
 * (per plan §K.5).
 *
 * Plan reference: Decentralized Federation §E + §I + P4 + P7.5.
 */

interface GrantsManagementModalProps {
  isOpen: boolean;
  peerId: string | null;
  peerLabel: string;
  onClose: () => void;
  onChanged?: () => void;
}

const ALL_SCOPES: GrantScope[] = ['read', 'write', 'admin', 'migrate'];

const LIFECYCLE_FILTERS: Array<{ value: GrantLifecycle | null; label: string }> = [
  { value: null, label: 'All' },
  { value: 'active', label: 'Active' },
  { value: 'expired', label: 'Expired' },
  { value: 'revoked', label: 'Revoked' },
  { value: 'archived', label: 'Archived' },
];

export const GrantsManagementModal: React.FC<GrantsManagementModalProps> = ({
  isOpen,
  peerId,
  peerLabel,
  onClose,
  onChanged,
}) => {
  const { addNotification } = useNotifications();
  const { confirmWithReason, ConfirmationDialog } = useReasonConfirm();
  const [grants, setGrants] = useState<FederationGrant[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<GrantLifecycle | null>(null);
  const [showIssueForm, setShowIssueForm] = useState(false);
  const [revokingId, setRevokingId] = useState<string | null>(null);

  const fetchGrants = useCallback(async () => {
    if (!peerId) return;
    setLoading(true);
    setError(null);
    try {
      const result = await peerGrantsApi.list(peerId, filter ?? undefined);
      setGrants(result.grants);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load grants');
    } finally {
      setLoading(false);
    }
  }, [peerId, filter]);

  useEffect(() => {
    if (isOpen) {
      void fetchGrants();
      setShowIssueForm(false);
    } else {
      setGrants([]);
      setError(null);
    }
  }, [isOpen, fetchGrants]);

  const handleRevoke = (grant: FederationGrant) => {
    if (!peerId) return;
    confirmWithReason({
      title: 'Revoke grant',
      message: `Revoke grant for "${grant.remote_subject}" on ${grant.resource_kind}? This soft-deletes the grant. It is retained for 90d then auto-archived.`,
      confirmLabel: 'Revoke this grant',
      reasonPlaceholder: 'Why is this grant being revoked?',
      onConfirm: async (reason) => {
        setRevokingId(grant.id);
        try {
          await peerGrantsApi.revoke(peerId, grant.id, reason);
          addNotification({ type: 'success', message: `Grant for '${grant.remote_subject}' revoked.` });
          await fetchGrants();
          onChanged?.();
        } catch (err: unknown) {
          addNotification({
            type: 'error',
            message: err instanceof Error ? err.message : 'Revoke failed',
          });
        } finally {
          setRevokingId(null);
        }
      },
    });
  };

  const handleIssued = () => {
    setShowIssueForm(false);
    void fetchGrants();
    onChanged?.();
  };

  if (!peerId) return null;

  return (
    <>
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      // The shared Modal registers its Escape handler on `document`, so while a
      // revoke confirmation is stacked on this one a single Escape press would
      // fire BOTH onClose handlers — dismissing the confirmation and dumping the
      // operator out of the grants panel. Hand Escape to the confirmation while
      // it is open.
      closeOnEscape={!ConfirmationDialog}
      icon={<ShieldCheck className="w-6 h-6" />}
      title={
        <div className="flex items-center gap-2">
          <ShieldCheck className="w-5 h-5 text-theme-info-fg" />
          <span>Grants — </span>
          <code className="font-mono text-sm text-theme-secondary">{peerLabel}</code>
        </div>
      }
      maxWidth="3xl"
      footer={
        <div className="flex items-center justify-between">
          <Button variant="ghost" onClick={onClose}>
            Close
          </Button>
          {!showIssueForm && (
            <Button variant="primary" onClick={() => setShowIssueForm(true)}>
              <Plus className="w-4 h-4" />
              Issue Grant
            </Button>
          )}
        </div>
      }
    >
      <div className="space-y-4">
        {error && (
          <ErrorAlert message={error} onClose={() => setError(null)} />
        )}

        {showIssueForm && (
          <IssueGrantForm
            peerId={peerId}
            onIssued={handleIssued}
            onCancel={() => setShowIssueForm(false)}
          />
        )}

        <div className="flex items-center justify-between">
          <div className="inline-flex items-center gap-2 text-xs">
            <Filter className="w-3 h-3 text-theme-secondary" />
            {LIFECYCLE_FILTERS.map((f) => (
              <button
                type="button"
                key={f.label}
                onClick={() => setFilter(f.value)}
                className={`px-2 py-1 rounded transition-colors ${
                  filter === f.value
                    ? 'bg-theme-info-solid text-white'
                    : 'text-theme-secondary hover:bg-theme-surface-hover'
                }`}
              >
                {f.label}
              </button>
            ))}
          </div>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${grants.length} grant${grants.length === 1 ? '' : 's'}`}
          </span>
        </div>

        {!loading && grants.length === 0 ? (
          <div className="p-8 text-center text-theme-secondary text-sm border border-theme rounded">
            No grants matching the current filter.
          </div>
        ) : (
          <div className="space-y-2 max-h-96 overflow-y-auto">
            {grants.map((g) => (
              <GrantRow
                key={g.id}
                grant={g}
                isRevoking={revokingId === g.id}
                onRevoke={() => handleRevoke(g)}
              />
            ))}
          </div>
        )}
      </div>
    </Modal>
    {/* Rendered outside the grants Modal so the confirmation stacks above it. */}
    {ConfirmationDialog}
    </>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Grant row

interface GrantRowProps {
  grant: FederationGrant;
  isRevoking: boolean;
  onRevoke: () => void;
}

const GrantRow: React.FC<GrantRowProps> = ({ grant, isRevoking, onRevoke }) => {
  const canRevoke = grant.lifecycle === 'active';

  return (
    <div className="p-3 border border-theme bg-theme-background-secondary rounded text-xs space-y-1">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2 min-w-0 flex-1">
          <LifecyclePill lifecycle={grant.lifecycle} />
          <span className="font-mono text-theme-primary truncate" title={grant.remote_subject}>
            {grant.remote_subject}
          </span>
          <span className="text-theme-tertiary">→</span>
          <span className="font-mono text-theme-primary">{grant.resource_kind}</span>
          {grant.resource_id && (
            <span className="font-mono text-theme-tertiary text-[10px]">
              ({grant.resource_id.slice(0, 8)}…)
            </span>
          )}
        </div>
        {canRevoke && (
          <button
            type="button"
            onClick={onRevoke}
            disabled={isRevoking}
            title="Revoke grant"
            className="px-2 py-1 rounded text-xs text-theme-danger-fg hover:bg-theme-surface-hover transition-colors disabled:opacity-40 inline-flex items-center gap-1"
          >
            <Trash2 className="w-3 h-3" />
            {isRevoking ? 'Revoking…' : 'Revoke'}
          </button>
        )}
      </div>

      <div className="flex items-center gap-3 text-theme-secondary">
        <span>scopes · <span className="font-mono text-theme-primary">{grant.permission_scopes.join(' ')}</span></span>
        <span className="inline-flex items-center gap-1">
          <Clock className="w-3 h-3" />
          {grant.lifecycle === 'active'
            ? `expires ${new Date(grant.expires_at).toLocaleDateString()}`
            : grant.revoked_at
              ? `revoked ${new Date(grant.revoked_at).toLocaleDateString()}`
              : `expired ${new Date(grant.expires_at).toLocaleDateString()}`}
        </span>
      </div>

      {!grant.unrestricted && (
        <div className="text-theme-secondary">
          scope ·{' '}
          <span className="mr-2">{axisSummary(grant.node_instance_ids, 'instance')}</span>
          <span className="mr-2">{axisSummary(grant.sdwan_network_ids, 'network')}</span>
          <span className="font-mono text-theme-primary">
            {isAnyAxis(grant.source_cidrs) || grant.source_cidrs.length === 0
              ? axisSummary(grant.source_cidrs, 'source')
              : grant.source_cidrs.join(', ')}
          </span>
        </div>
      )}

      {grant.revocation_reason && (
        <div className="text-theme-tertiary italic">revoke reason: {grant.revocation_reason}</div>
      )}
    </div>
  );
};

// `['*']` is the explicit ANY sentinel; a blank axis denies (the server
// refuses to issue one, so blank only shows on a row written around it).
const isAnyAxis = (list: string[]): boolean => list.length === 1 && list[0] === '*';

const axisSummary = (list: string[], noun: string): string => {
  if (isAnyAxis(list)) return `any ${noun}`;
  if (list.length === 0) return `no ${noun} (deny)`;
  return `${list.length} ${noun}${list.length === 1 ? '' : 's'}`;
};

const LifecyclePill: React.FC<{ lifecycle: GrantLifecycle }> = ({ lifecycle }) => {
  const cls: Record<GrantLifecycle, string> = {
    active: 'bg-theme-success-bg text-theme-success-fg',
    expired: 'bg-theme-warning-bg text-theme-warning-fg',
    revoked: 'bg-theme-danger-bg text-theme-danger-fg',
    archived: 'bg-theme-background-tertiary text-theme-secondary',
  };
  return (
    <span className={`inline-block px-1.5 py-0.5 rounded text-[10px] font-medium uppercase ${cls[lifecycle]}`}>
      {lifecycle}
    </span>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Issue-grant inline form

interface IssueGrantFormProps {
  peerId: string;
  onIssued: () => void;
  onCancel: () => void;
}

const IssueGrantForm: React.FC<IssueGrantFormProps> = ({ peerId, onIssued, onCancel }) => {
  const [resourceKind, setResourceKind] = useState('');
  const [resourceId, setResourceId] = useState('');
  const [remoteSubject, setRemoteSubject] = useState('');
  const [scopes, setScopes] = useState<GrantScope[]>(['read']);
  const [ttlDays, setTtlDays] = useState('30');
  const [nodeInstanceIds, setNodeInstanceIds] = useState('');
  const [sdwanNetworkIds, setSdwanNetworkIds] = useState('');
  const [sourceCidrs, setSourceCidrs] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const parseCsv = (s: string): string[] =>
    s.split(',').map((part) => part.trim()).filter(Boolean);

  const validation = useMemo(() => {
    const errors: string[] = [];
    if (!resourceKind.trim()) errors.push('resource_kind is required.');
    if (!remoteSubject.trim()) errors.push('remote_subject is required.');
    if (scopes.length === 0) errors.push('Select at least one scope.');
    const ttl = parseInt(ttlDays, 10);
    if (!Number.isFinite(ttl) || ttl < 7 || ttl > 365) {
      errors.push('TTL must be 7–365 days.');
    }
    const axes = [nodeInstanceIds, sdwanNetworkIds, sourceCidrs].map(parseCsv);
    if (axes.some((a) => a.length === 0)) {
      errors.push('Every pessimistic-scope allowlist is required — list values, or * for any.');
    } else if (axes.some((a) => a.includes('*') && a.length > 1)) {
      errors.push('* (any) must stand alone in an allowlist, not be mixed with values.');
    }
    return { ok: errors.length === 0, errors };
  }, [resourceKind, remoteSubject, scopes, ttlDays, nodeInstanceIds, sdwanNetworkIds, sourceCidrs]);

  const handleToggleScope = (scope: GrantScope) => {
    setScopes((prev) =>
      prev.includes(scope) ? prev.filter((s) => s !== scope) : [...prev, scope],
    );
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
      const req: IssueGrantRequest = {
        resource_kind: resourceKind.trim(),
        resource_id: resourceId.trim() || undefined,
        remote_subject: remoteSubject.trim(),
        permission_scopes: scopes,
        ttl_days: parseInt(ttlDays, 10),
        node_instance_ids: parseCsv(nodeInstanceIds),
        sdwan_network_ids: parseCsv(sdwanNetworkIds),
        source_cidrs: parseCsv(sourceCidrs),
      };
      await peerGrantsApi.issue(peerId, req);
      onIssued();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Issue failed');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <form
      onSubmit={handleSubmit}
      className="p-3 bg-theme-background-secondary border border-theme rounded space-y-3"
    >
      <div className="flex items-center justify-between">
        <h4 className="text-sm font-semibold text-theme-primary inline-flex items-center gap-2">
          <Plus className="w-4 h-4 text-theme-info-fg" />
          Issue New Grant
        </h4>
        <button
          type="button"
          onClick={onCancel}
          className="p-1 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors"
        >
          <X className="w-4 h-4" />
        </button>
      </div>

      {error && (
        <ErrorAlert message={error} onClose={() => setError(null)} />
      )}

      <div className="grid grid-cols-2 gap-3">
        <Field label="Resource Kind *">
          <input
            type="text"
            value={resourceKind}
            onChange={(e) => setResourceKind(e.target.value)}
            disabled={submitting}
            required
            placeholder="e.g. skill"
            className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
          />
        </Field>
        <Field label="Resource ID (optional)">
          <input
            type="text"
            value={resourceId}
            onChange={(e) => setResourceId(e.target.value)}
            disabled={submitting}
            placeholder="UUID or blank for all-of-kind"
            className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
          />
        </Field>
      </div>

      <Field label="Remote Subject *">
        <input
          type="text"
          value={remoteSubject}
          onChange={(e) => setRemoteSubject(e.target.value)}
          disabled={submitting}
          required
          placeholder="e.g. alice@remote-platform.example.org"
          className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
        />
      </Field>

      <div className="grid grid-cols-3 gap-3">
        <Field label="Scopes" className="col-span-2">
          <div className="flex flex-wrap gap-1">
            {ALL_SCOPES.map((scope) => (
              <button
                key={scope}
                type="button"
                onClick={() => handleToggleScope(scope)}
                disabled={submitting}
                className={`px-2 py-1 rounded text-xs font-mono transition-colors ${
                  scopes.includes(scope)
                    ? 'bg-theme-info-solid text-white'
                    : 'bg-theme-surface text-theme-secondary hover:bg-theme-surface-hover'
                }`}
              >
                {scope}
              </button>
            ))}
          </div>
        </Field>
        <Field label="TTL (days)">
          <input
            type="number"
            min={7}
            max={365}
            value={ttlDays}
            onChange={(e) => setTtlDays(e.target.value)}
            disabled={submitting}
            className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
          />
        </Field>
      </div>

      <details open className="text-xs">
        <summary className="cursor-pointer text-theme-secondary hover:text-theme-primary">
          Pessimistic scope (required) — instance / network / CIDR allowlists; * means any
        </summary>
        <div className="mt-2 space-y-2">
          <Field label="Node Instance IDs (comma-separated)">
            <input
              type="text"
              value={nodeInstanceIds}
              onChange={(e) => setNodeInstanceIds(e.target.value)}
              disabled={submitting}
              placeholder="instance IDs, or * for any instance"
              className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
            />
          </Field>
          <Field label="SDWAN Network IDs (comma-separated)">
            <input
              type="text"
              value={sdwanNetworkIds}
              onChange={(e) => setSdwanNetworkIds(e.target.value)}
              disabled={submitting}
              placeholder="network IDs, or * for any network"
              className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
            />
          </Field>
          <Field label="Source CIDR allowlist (comma-separated)">
            <input
              type="text"
              value={sourceCidrs}
              onChange={(e) => setSourceCidrs(e.target.value)}
              disabled={submitting}
              placeholder="e.g. 10.0.0.0/8, 192.168.1.0/24, or * for any source"
              className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
            />
          </Field>
        </div>
      </details>

      <div className="flex items-center justify-end gap-2">
        <Button variant="ghost" onClick={onCancel} disabled={submitting}>
          Cancel
        </Button>
        <Button
          variant="primary"
          onClick={handleSubmit}
          disabled={submitting || !validation.ok}
        >
          {submitting ? 'Issuing…' : 'Issue Grant'}
        </Button>
      </div>
    </form>
  );
};

const Field: React.FC<{ label: string; className?: string; children: React.ReactNode }> = ({
  label,
  className,
  children,
}) => (
  <div className={className}>
    <label className="block text-xs font-medium text-theme-secondary mb-1">{label}</label>
    {children}
  </div>
);
