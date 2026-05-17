import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  ShieldCheck,
  AlertCircle,
  X,
  Plus,
  Trash2,
  Clock,
  Filter,
} from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { peerGrantsApi } from '../../services/api/peerGrantsApi';
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
 * source_cidrs) are exposed via comma-separated text inputs — full
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

  const handleRevoke = async (grant: FederationGrant) => {
    if (!peerId) return;
    const reason = window.prompt(
      `Revoke grant for "${grant.remote_subject}" on ${grant.resource_kind}?\n\n` +
        'This soft-deletes the grant. It is retained for 90d then auto-archived. Optional reason:',
      '',
    );
    if (reason === null) return;
    setRevokingId(grant.id);
    try {
      await peerGrantsApi.revoke(peerId, grant.id, reason || undefined);
      await fetchGrants();
      onChanged?.();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Revoke failed');
    } finally {
      setRevokingId(null);
    }
  };

  const handleIssued = () => {
    setShowIssueForm(false);
    void fetchGrants();
    onChanged?.();
  };

  if (!peerId) return null;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <div className="flex items-center gap-2">
          <ShieldCheck className="w-5 h-5 text-theme-info" />
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
          <div className="p-2 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm rounded">
            <AlertCircle className="w-4 h-4" />
            <span className="flex-1">{error}</span>
            <button type="button" onClick={() => setError(null)} className="p-1">
              <X className="w-3 h-3" />
            </button>
          </div>
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
            className="px-2 py-1 rounded text-xs text-theme-danger hover:bg-theme-surface-hover transition-colors disabled:opacity-40 inline-flex items-center gap-1"
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
          {grant.node_instance_ids.length > 0 && (
            <span className="mr-2">
              {grant.node_instance_ids.length} instance{grant.node_instance_ids.length === 1 ? '' : 's'}
            </span>
          )}
          {grant.sdwan_network_ids.length > 0 && (
            <span className="mr-2">
              {grant.sdwan_network_ids.length} network{grant.sdwan_network_ids.length === 1 ? '' : 's'}
            </span>
          )}
          {grant.source_cidrs.length > 0 && (
            <span className="font-mono text-theme-primary">{grant.source_cidrs.join(', ')}</span>
          )}
        </div>
      )}

      {grant.revocation_reason && (
        <div className="text-theme-tertiary italic">revoke reason: {grant.revocation_reason}</div>
      )}
    </div>
  );
};

const LifecyclePill: React.FC<{ lifecycle: GrantLifecycle }> = ({ lifecycle }) => {
  const cls: Record<GrantLifecycle, string> = {
    active: 'bg-theme-success text-theme-success',
    expired: 'bg-theme-warning text-theme-warning',
    revoked: 'bg-theme-danger text-theme-danger',
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

  const validation = useMemo(() => {
    const errors: string[] = [];
    if (!resourceKind.trim()) errors.push('resource_kind is required.');
    if (!remoteSubject.trim()) errors.push('remote_subject is required.');
    if (scopes.length === 0) errors.push('Select at least one scope.');
    const ttl = parseInt(ttlDays, 10);
    if (!Number.isFinite(ttl) || ttl < 7 || ttl > 365) {
      errors.push('TTL must be 7–365 days.');
    }
    return { ok: errors.length === 0, errors };
  }, [resourceKind, remoteSubject, scopes, ttlDays]);

  const handleToggleScope = (scope: GrantScope) => {
    setScopes((prev) =>
      prev.includes(scope) ? prev.filter((s) => s !== scope) : [...prev, scope],
    );
  };

  const parseCsv = (s: string): string[] =>
    s.split(',').map((part) => part.trim()).filter(Boolean);

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
          <Plus className="w-4 h-4 text-theme-info" />
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
        <div className="p-2 bg-theme-danger text-theme-danger flex items-center gap-2 text-xs rounded">
          <AlertCircle className="w-3 h-3" />
          <span className="flex-1">{error}</span>
          <button type="button" onClick={() => setError(null)} className="p-1">
            <X className="w-3 h-3" />
          </button>
        </div>
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

      <details className="text-xs">
        <summary className="cursor-pointer text-theme-secondary hover:text-theme-primary">
          Pessimistic scope (optional) — instance / network / CIDR allowlists
        </summary>
        <div className="mt-2 space-y-2">
          <Field label="Node Instance IDs (comma-separated)">
            <input
              type="text"
              value={nodeInstanceIds}
              onChange={(e) => setNodeInstanceIds(e.target.value)}
              disabled={submitting}
              placeholder="empty = any instance"
              className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
            />
          </Field>
          <Field label="SDWAN Network IDs (comma-separated)">
            <input
              type="text"
              value={sdwanNetworkIds}
              onChange={(e) => setSdwanNetworkIds(e.target.value)}
              disabled={submitting}
              placeholder="empty = any network"
              className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
            />
          </Field>
          <Field label="Source CIDR allowlist (comma-separated)">
            <input
              type="text"
              value={sourceCidrs}
              onChange={(e) => setSourceCidrs(e.target.value)}
              disabled={submitting}
              placeholder="e.g. 10.0.0.0/8, 192.168.1.0/24"
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
