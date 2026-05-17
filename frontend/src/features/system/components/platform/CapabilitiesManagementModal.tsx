import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Globe2,
  AlertCircle,
  X,
  Plus,
  Trash2,
  ArrowRight,
  ArrowLeft,
  ArrowLeftRight,
  Move,
} from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { peerCapabilitiesApi } from '../../services/api/peerCapabilitiesApi';
import type {
  CapabilityConflictResolution,
  CapabilityDirection,
  CapabilityPolicy,
  CreateCapabilityRequest,
  FederationCapability,
} from '../../types/capability.types';

/**
 * Per-peer FederationCapability management modal. Mirrors the layout of
 * GrantsManagementModal: list + collapsible "Add Capability" form.
 *
 * Capabilities are non-symmetric: each peer declares their own. The form
 * captures resource_kind / direction / policy / filter (JSON) /
 * conflict_resolution.
 *
 * Plan reference: Decentralized Federation §D + §I + P4 + P7.6.
 */

interface CapabilitiesManagementModalProps {
  isOpen: boolean;
  peerId: string | null;
  peerLabel: string;
  onClose: () => void;
  onChanged?: () => void;
}

const DIRECTIONS: Array<{ value: CapabilityDirection; label: string; icon: React.ReactNode }> = [
  { value: 'push_local_to_remote', label: 'Push (us → them)', icon: <ArrowRight className="w-3 h-3" /> },
  { value: 'pull_remote_to_local', label: 'Pull (them → us)', icon: <ArrowLeft className="w-3 h-3" /> },
  { value: 'bidirectional', label: 'Bidirectional', icon: <ArrowLeftRight className="w-3 h-3" /> },
  { value: 'migration_only', label: 'Migration only', icon: <Move className="w-3 h-3" /> },
];

const POLICIES: Array<{ value: CapabilityPolicy; label: string; help: string }> = [
  { value: 'manual', label: 'Manual', help: 'Operator triggers each sync explicitly.' },
  { value: 'auto_on_change', label: 'Auto on change', help: 'Sync triggered by source-row update.' },
  { value: 'auto_periodic', label: 'Auto periodic', help: 'Sync on cron tick (15-min default).' },
  { value: 'on_match_filter', label: 'On match filter', help: 'Sync when row matches filter.' },
];

const CONFLICT_RESOLUTIONS: Array<{ value: CapabilityConflictResolution; label: string }> = [
  { value: 'local_wins', label: 'Local wins' },
  { value: 'remote_wins', label: 'Remote wins' },
  { value: 'prompt', label: 'Prompt operator' },
];

export const CapabilitiesManagementModal: React.FC<CapabilitiesManagementModalProps> = ({
  isOpen,
  peerId,
  peerLabel,
  onClose,
  onChanged,
}) => {
  const [capabilities, setCapabilities] = useState<FederationCapability[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showAddForm, setShowAddForm] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);

  const fetch = useCallback(async () => {
    if (!peerId) return;
    setLoading(true);
    setError(null);
    try {
      const result = await peerCapabilitiesApi.list(peerId);
      setCapabilities(result.capabilities);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load capabilities');
    } finally {
      setLoading(false);
    }
  }, [peerId]);

  useEffect(() => {
    if (isOpen) {
      void fetch();
      setShowAddForm(false);
    } else {
      setCapabilities([]);
      setError(null);
    }
  }, [isOpen, fetch]);

  const handleDelete = async (cap: FederationCapability) => {
    if (!peerId) return;
    const ok = window.confirm(
      `Delete capability "${cap.resource_kind}" (${cap.direction})?\n\n` +
        'Capabilities are mutable declarations — this is a hard delete, not a soft one.',
    );
    if (!ok) return;
    setDeletingId(cap.id);
    try {
      await peerCapabilitiesApi.destroy(peerId, cap.id);
      await fetch();
      onChanged?.();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Delete failed');
    } finally {
      setDeletingId(null);
    }
  };

  const handleAdded = () => {
    setShowAddForm(false);
    void fetch();
    onChanged?.();
  };

  if (!peerId) return null;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <div className="flex items-center gap-2">
          <Globe2 className="w-5 h-5 text-theme-info" />
          <span>Capabilities — </span>
          <code className="font-mono text-sm text-theme-secondary">{peerLabel}</code>
        </div>
      }
      maxWidth="3xl"
      footer={
        <div className="flex items-center justify-between">
          <Button variant="ghost" onClick={onClose}>
            Close
          </Button>
          {!showAddForm && (
            <Button variant="primary" onClick={() => setShowAddForm(true)}>
              <Plus className="w-4 h-4" />
              Add Capability
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

        {showAddForm && (
          <AddCapabilityForm
            peerId={peerId}
            onAdded={handleAdded}
            onCancel={() => setShowAddForm(false)}
          />
        )}

        <div className="flex items-center justify-end">
          <span className="text-xs text-theme-secondary">
            {loading
              ? 'loading…'
              : `${capabilities.length} capabilit${capabilities.length === 1 ? 'y' : 'ies'}`}
          </span>
        </div>

        {!loading && capabilities.length === 0 ? (
          <div className="p-8 text-center text-theme-secondary text-sm border border-theme rounded">
            No capabilities declared yet. Capabilities are how this platform tells
            the peer "I'll push you skills" or "send me your trading_strategies" —
            without one, no resource flows automatically.
          </div>
        ) : (
          <div className="space-y-2 max-h-96 overflow-y-auto">
            {capabilities.map((c) => (
              <CapabilityRow
                key={c.id}
                capability={c}
                isDeleting={deletingId === c.id}
                onDelete={() => handleDelete(c)}
              />
            ))}
          </div>
        )}
      </div>
    </Modal>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Capability row

interface CapabilityRowProps {
  capability: FederationCapability;
  isDeleting: boolean;
  onDelete: () => void;
}

const CapabilityRow: React.FC<CapabilityRowProps> = ({ capability, isDeleting, onDelete }) => {
  const dirInfo = DIRECTIONS.find((d) => d.value === capability.direction);

  return (
    <div className="p-3 border border-theme bg-theme-background-secondary rounded text-xs">
      <div className="flex items-center justify-between gap-2 mb-1">
        <div className="flex items-center gap-2 min-w-0 flex-1">
          <span className="font-mono text-theme-primary truncate">{capability.resource_kind}</span>
          {dirInfo && (
            <span className="inline-flex items-center gap-1 px-1.5 py-0.5 bg-theme-surface rounded text-theme-secondary">
              {dirInfo.icon}
              <span className="text-[10px]">{capability.direction}</span>
            </span>
          )}
          <PolicyBadge policy={capability.policy} />
        </div>
        <button
          type="button"
          onClick={onDelete}
          disabled={isDeleting}
          title="Delete capability"
          className="px-2 py-1 rounded text-xs text-theme-danger hover:bg-theme-surface-hover transition-colors disabled:opacity-40 inline-flex items-center gap-1"
        >
          <Trash2 className="w-3 h-3" />
          {isDeleting ? 'Deleting…' : 'Delete'}
        </button>
      </div>

      <div className="flex items-center gap-3 text-theme-secondary">
        <span>conflict · <span className="font-mono text-theme-primary">{capability.conflict_resolution}</span></span>
        {capability.last_synced_at && (
          <span>last sync · {new Date(capability.last_synced_at).toLocaleString()}</span>
        )}
      </div>

      {Object.keys(capability.filter).length > 0 && (
        <details className="mt-1">
          <summary className="cursor-pointer text-theme-secondary hover:text-theme-primary">
            filter · {Object.keys(capability.filter).length} predicate{Object.keys(capability.filter).length === 1 ? '' : 's'}
          </summary>
          <pre className="mt-1 text-[10px] bg-theme-surface p-2 rounded overflow-x-auto font-mono text-theme-primary">
            {JSON.stringify(capability.filter, null, 2)}
          </pre>
        </details>
      )}
    </div>
  );
};

const PolicyBadge: React.FC<{ policy: CapabilityPolicy }> = ({ policy }) => {
  const cls: Record<CapabilityPolicy, string> = {
    manual: 'bg-theme-background-tertiary text-theme-secondary',
    auto_on_change: 'bg-theme-info text-theme-info',
    auto_periodic: 'bg-theme-info text-theme-info',
    on_match_filter: 'bg-theme-warning text-theme-warning',
  };
  return (
    <span className={`inline-block px-1.5 py-0.5 rounded text-[10px] font-mono ${cls[policy]}`}>
      {policy}
    </span>
  );
};

// ──────────────────────────────────────────────────────────────────────
// Add-capability inline form

interface AddCapabilityFormProps {
  peerId: string;
  onAdded: () => void;
  onCancel: () => void;
}

const AddCapabilityForm: React.FC<AddCapabilityFormProps> = ({ peerId, onAdded, onCancel }) => {
  const [resourceKind, setResourceKind] = useState('');
  const [direction, setDirection] = useState<CapabilityDirection>('push_local_to_remote');
  const [policy, setPolicy] = useState<CapabilityPolicy>('manual');
  const [conflict, setConflict] = useState<CapabilityConflictResolution>('local_wins');
  const [filterJson, setFilterJson] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const validation = useMemo(() => {
    const errors: string[] = [];
    if (!resourceKind.trim()) errors.push('resource_kind is required.');
    if (filterJson.trim()) {
      try {
        const parsed = JSON.parse(filterJson);
        if (typeof parsed !== 'object' || Array.isArray(parsed) || parsed === null) {
          errors.push('filter must be a JSON object.');
        }
      } catch {
        errors.push('filter must be valid JSON.');
      }
    }
    return { ok: errors.length === 0, errors };
  }, [resourceKind, filterJson]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validation.ok) {
      setError(validation.errors[0] ?? 'Form invalid');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const req: CreateCapabilityRequest = {
        resource_kind: resourceKind.trim(),
        direction,
        policy,
        conflict_resolution: conflict,
        filter: filterJson.trim() ? JSON.parse(filterJson) : {},
      };
      await peerCapabilitiesApi.create(peerId, req);
      onAdded();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Create failed');
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
          Add Capability
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

      <Field label="Resource Kind *">
        <input
          type="text"
          value={resourceKind}
          onChange={(e) => setResourceKind(e.target.value)}
          disabled={submitting}
          required
          placeholder="e.g. skill, trading_strategy, knowledge_base_entry"
          className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
        />
      </Field>

      <div className="grid grid-cols-2 gap-3">
        <Field label="Direction *">
          <select
            value={direction}
            onChange={(e) => setDirection(e.target.value as CapabilityDirection)}
            disabled={submitting}
            className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary text-xs disabled:opacity-50"
          >
            {DIRECTIONS.map((d) => (
              <option key={d.value} value={d.value}>{d.label}</option>
            ))}
          </select>
        </Field>
        <Field label="Policy *">
          <select
            value={policy}
            onChange={(e) => setPolicy(e.target.value as CapabilityPolicy)}
            disabled={submitting}
            className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary text-xs disabled:opacity-50"
          >
            {POLICIES.map((p) => (
              <option key={p.value} value={p.value}>{p.label}</option>
            ))}
          </select>
          <p className="text-[10px] text-theme-secondary mt-0.5">
            {POLICIES.find((p) => p.value === policy)?.help}
          </p>
        </Field>
      </div>

      <Field label="Conflict Resolution">
        <select
          value={conflict}
          onChange={(e) => setConflict(e.target.value as CapabilityConflictResolution)}
          disabled={submitting}
          className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary text-xs disabled:opacity-50"
        >
          {CONFLICT_RESOLUTIONS.map((c) => (
            <option key={c.value} value={c.value}>{c.label}</option>
          ))}
        </select>
        <p className="text-[10px] text-theme-secondary mt-0.5">
          Used only for secondary unique-constraint collisions (per LD #14, two
          peers cannot hold the same UUID, so there's no "newer" question).
        </p>
      </Field>

      <Field label="Filter (optional JSON object)">
        <textarea
          value={filterJson}
          onChange={(e) => setFilterJson(e.target.value)}
          disabled={submitting}
          rows={3}
          placeholder='e.g. {"tags": ["public"]}'
          className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
        />
        <p className="text-[10px] text-theme-secondary mt-0.5">
          Filter predicates restrict which rows of the resource_kind flow under this capability.
        </p>
      </Field>

      <div className="flex items-center justify-end gap-2">
        <Button variant="ghost" onClick={onCancel} disabled={submitting}>
          Cancel
        </Button>
        <Button
          variant="primary"
          onClick={handleSubmit}
          disabled={submitting || !validation.ok}
        >
          {submitting ? 'Adding…' : 'Add Capability'}
        </Button>
      </div>
    </form>
  );
};

const Field: React.FC<{ label: string; children: React.ReactNode }> = ({ label, children }) => (
  <div>
    <label className="block text-xs font-medium text-theme-secondary mb-1">{label}</label>
    {children}
  </div>
);
