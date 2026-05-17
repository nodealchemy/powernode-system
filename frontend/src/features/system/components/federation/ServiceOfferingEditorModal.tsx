import React, { useEffect, useMemo, useState } from 'react';
import { Server, AlertCircle, X } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { serviceCatalogApi } from '../../services/api/serviceCatalogApi';
import type {
  ServiceOffering,
  ServiceOfferingCreate,
  ServiceOfferingUpdate,
  ServiceProtocol,
  GrantScope,
} from '../../types/service_delivery.types';

/**
 * Create or edit a ServiceOffering. Single component handles both
 * modes — the `editOffering` prop discriminates: nil = create,
 * present = edit (with slug field locked because the backend
 * permit-list omits it).
 *
 * Plan reference: Decentralized Federation §L.7 + P4.6.8.
 */

interface ServiceOfferingEditorModalProps {
  isOpen: boolean;
  onClose: () => void;
  editOffering?: ServiceOffering | null;
  onSaved?: (offering: ServiceOffering) => void;
}

const PROTOCOL_OPTIONS: Array<{ value: ServiceProtocol; label: string }> = [
  { value: 'https', label: 'HTTPS (Traefik HTTPRouter + TLS)' },
  { value: 'http', label: 'HTTP (plain — TLS handled upstream)' },
  { value: 'tls', label: 'TLS (Traefik TCPRouter + TLS termination)' },
  { value: 'tcp', label: 'TCP (Traefik TCPRouter, raw — for site-local forwards)' },
];

const SCOPE_OPTIONS: GrantScope[] = ['read', 'write', 'admin', 'migrate'];

// Slug format mirrors the backend regex /\A[a-z0-9][a-z0-9-]*\z/
const SLUG_PATTERN = /^[a-z0-9][a-z0-9-]*$/;

// Mirror System::Federation::ServiceOffering::MIN_GRANT_TTL_DAYS (7).
const MIN_GRANT_TTL = 7;

interface FormState {
  slug: string;
  name: string;
  protocol: ServiceProtocol;
  backend_host: string;
  backend_port: string; // string for the input; coerced to number on submit
  default_grant_ttl_days: string;
  default_grant_scopes: GrantScope[];
  description_markdown: string;
  subscription_terms_markdown: string;
  max_subscribers: string;
}

const EMPTY_FORM: FormState = {
  slug: '',
  name: '',
  protocol: 'https',
  backend_host: '',
  backend_port: '443',
  default_grant_ttl_days: '30',
  default_grant_scopes: ['read'],
  description_markdown: '',
  subscription_terms_markdown: '',
  max_subscribers: '',
};

function formFromOffering(offering: ServiceOffering): FormState {
  const maxSubs = offering.capacity_metadata.max_subscribers;
  return {
    slug: offering.slug,
    name: offering.name,
    protocol: offering.protocol,
    backend_host: offering.backend_host ?? '',
    backend_port: String(offering.backend_port),
    default_grant_ttl_days: String(offering.default_grant_ttl_days),
    default_grant_scopes: offering.default_grant_scopes,
    description_markdown: offering.description_markdown ?? '',
    subscription_terms_markdown: offering.subscription_terms_markdown ?? '',
    max_subscribers: maxSubs !== undefined && maxSubs !== null ? String(maxSubs) : '',
  };
}

export const ServiceOfferingEditorModal: React.FC<ServiceOfferingEditorModalProps> = ({
  isOpen,
  onClose,
  editOffering,
  onSaved,
}) => {
  const isEdit = !!editOffering;
  const [form, setForm] = useState<FormState>(EMPTY_FORM);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Reset form state when the modal opens with a different target.
  useEffect(() => {
    if (!isOpen) return;
    setForm(editOffering ? formFromOffering(editOffering) : EMPTY_FORM);
    setError(null);
  }, [isOpen, editOffering]);

  const validation = useMemo(() => validate(form, isEdit), [form, isEdit]);
  const canSubmit = !submitting && validation.ok;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validation.ok) {
      setError(validation.errors[0] ?? 'Form invalid');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const saved = isEdit
        ? await serviceCatalogApi.updateOffering(editOffering!.id, buildUpdatePayload(form))
        : await serviceCatalogApi.createOffering(buildCreatePayload(form));
      onSaved?.(saved);
      onClose();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Save failed');
    } finally {
      setSubmitting(false);
    }
  };

  const updateField = <K extends keyof FormState>(key: K, value: FormState[K]) => {
    setForm((prev) => ({ ...prev, [key]: value }));
  };

  const toggleScope = (scope: GrantScope) => {
    setForm((prev) => {
      const has = prev.default_grant_scopes.includes(scope);
      return {
        ...prev,
        default_grant_scopes: has
          ? prev.default_grant_scopes.filter((s) => s !== scope)
          : [...prev.default_grant_scopes, scope],
      };
    });
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <div className="flex items-center gap-2">
          <Server className="w-5 h-5 text-theme-info" />
          <span>{isEdit ? 'Edit Service Offering' : 'New Service Offering'}</span>
        </div>
      }
      maxWidth="2xl"
      footer={
        <div className="flex items-center justify-end gap-2">
          <Button variant="ghost" onClick={onClose} disabled={submitting}>
            Cancel
          </Button>
          <Button variant="primary" onClick={handleSubmit} disabled={!canSubmit}>
            {submitting ? 'Saving…' : isEdit ? 'Save Changes' : 'Create Offering'}
          </Button>
        </div>
      }
    >
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

        <FieldRow
          label="Slug"
          help={isEdit ? 'Slug is immutable; subscribers reference offerings by slug.' :
                        'Lowercase alphanumeric + hyphens. Subscribers reference offerings by slug.'}
        >
          <input
            type="text"
            value={form.slug}
            onChange={(e) => updateField('slug', e.target.value.toLowerCase().trim())}
            disabled={isEdit || submitting}
            required
            placeholder="gitea, managed-postgres, …"
            className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
          />
        </FieldRow>

        <FieldRow label="Name" help="Operator-visible display label for the dashboard + remote catalog.">
          <input
            type="text"
            value={form.name}
            onChange={(e) => updateField('name', e.target.value)}
            disabled={submitting}
            required
            placeholder="Hosted Git, Managed Postgres, …"
            className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50"
          />
        </FieldRow>

        <FieldRow label="Protocol">
          <select
            value={form.protocol}
            onChange={(e) => updateField('protocol', e.target.value as ServiceProtocol)}
            disabled={submitting}
            className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50"
          >
            {PROTOCOL_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </select>
        </FieldRow>

        <div className="grid grid-cols-3 gap-3">
          <div className="col-span-2">
            <FieldRow label="Backend Host" help="Reachable address from this platform (DNS or IPv4/v6).">
              <input
                type="text"
                value={form.backend_host}
                onChange={(e) => updateField('backend_host', e.target.value.trim())}
                disabled={submitting}
                placeholder="backend.internal or fd00::1"
                className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
              />
            </FieldRow>
          </div>
          <FieldRow label="Port">
            <input
              type="number"
              min={1}
              max={65535}
              value={form.backend_port}
              onChange={(e) => updateField('backend_port', e.target.value)}
              disabled={submitting}
              required
              className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
            />
          </FieldRow>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <FieldRow label="Grant TTL (days)" help={`Floor ${MIN_GRANT_TTL} days.`}>
            <input
              type="number"
              min={MIN_GRANT_TTL}
              max={365}
              value={form.default_grant_ttl_days}
              onChange={(e) => updateField('default_grant_ttl_days', e.target.value)}
              disabled={submitting}
              required
              className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
            />
          </FieldRow>
          <FieldRow label="Max Subscribers" help="Leave blank for uncapped.">
            <input
              type="number"
              min={0}
              value={form.max_subscribers}
              onChange={(e) => updateField('max_subscribers', e.target.value)}
              disabled={submitting}
              placeholder="(uncapped)"
              className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 font-mono text-sm"
            />
          </FieldRow>
        </div>

        <FieldRow label="Grant Scopes" help="Permissions subscribers inherit. Read is the safe default.">
          <div className="flex items-center gap-1 flex-wrap">
            {SCOPE_OPTIONS.map((scope) => {
              const active = form.default_grant_scopes.includes(scope);
              return (
                <button
                  type="button"
                  key={scope}
                  onClick={() => toggleScope(scope)}
                  disabled={submitting}
                  className={`px-2 py-1 rounded text-xs font-mono ${
                    active
                      ? 'bg-theme-info-solid text-white'
                      : 'bg-theme-background-secondary text-theme-secondary hover:bg-theme-surface-hover'
                  } disabled:opacity-50`}
                >
                  {scope}
                </button>
              );
            })}
          </div>
        </FieldRow>

        <FieldRow label="Description (markdown)" help="Surfaced in the subscriber's catalog browse.">
          <textarea
            value={form.description_markdown}
            onChange={(e) => updateField('description_markdown', e.target.value)}
            disabled={submitting}
            rows={3}
            className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 text-sm"
          />
        </FieldRow>

        <FieldRow label="Subscription Terms (markdown)" help="Pricing, SLA, data residency disclosures.">
          <textarea
            value={form.subscription_terms_markdown}
            onChange={(e) => updateField('subscription_terms_markdown', e.target.value)}
            disabled={submitting}
            rows={3}
            className="w-full px-2 py-1.5 border border-theme rounded bg-theme-background-secondary text-theme-primary disabled:opacity-50 text-sm"
          />
        </FieldRow>
      </form>
    </Modal>
  );
};

// ─── Helpers ─────────────────────────────────────────────────────────

interface FieldRowProps {
  label: string;
  help?: string;
  children: React.ReactNode;
}

const FieldRow: React.FC<FieldRowProps> = ({ label, help, children }) => (
  <div>
    <label className="block text-xs font-medium text-theme-secondary mb-1">{label}</label>
    {children}
    {help && <p className="text-xs text-theme-secondary mt-1">{help}</p>}
  </div>
);

interface ValidationResult {
  ok: boolean;
  errors: string[];
}

function validate(form: FormState, isEdit: boolean): ValidationResult {
  const errors: string[] = [];

  if (!form.name.trim()) errors.push('Name is required.');
  if (!isEdit) {
    if (!form.slug.trim()) errors.push('Slug is required.');
    else if (!SLUG_PATTERN.test(form.slug)) errors.push('Slug must match [a-z0-9][a-z0-9-]*');
  }

  const port = parseInt(form.backend_port, 10);
  if (!Number.isFinite(port) || port < 1 || port > 65535) {
    errors.push('Port must be between 1 and 65535.');
  }
  if (!form.backend_host.trim()) {
    errors.push('Backend host is required (VIP-by-id support coming later).');
  }

  const ttl = parseInt(form.default_grant_ttl_days, 10);
  if (!Number.isFinite(ttl) || ttl < MIN_GRANT_TTL) {
    errors.push(`Grant TTL must be ≥ ${MIN_GRANT_TTL} days.`);
  }

  if (form.default_grant_scopes.length === 0) {
    errors.push('At least one grant scope is required.');
  }

  if (form.max_subscribers.trim() !== '') {
    const cap = parseInt(form.max_subscribers, 10);
    if (!Number.isFinite(cap) || cap < 0) {
      errors.push('Max subscribers must be a non-negative integer or blank.');
    }
  }

  return { ok: errors.length === 0, errors };
}

function buildCreatePayload(form: FormState): ServiceOfferingCreate {
  const payload: ServiceOfferingCreate = {
    slug: form.slug.trim(),
    name: form.name.trim(),
    protocol: form.protocol,
    backend_host: form.backend_host.trim(),
    backend_port: parseInt(form.backend_port, 10),
    default_grant_ttl_days: parseInt(form.default_grant_ttl_days, 10),
    default_grant_scopes: form.default_grant_scopes,
  };
  if (form.description_markdown.trim()) {
    payload.description_markdown = form.description_markdown;
  }
  if (form.subscription_terms_markdown.trim()) {
    payload.subscription_terms_markdown = form.subscription_terms_markdown;
  }
  if (form.max_subscribers.trim() !== '') {
    payload.capacity_metadata = { max_subscribers: parseInt(form.max_subscribers, 10) };
  }
  return payload;
}

function buildUpdatePayload(form: FormState): ServiceOfferingUpdate {
  // Update payload mirrors create, minus slug (which is immutable
  // server-side). Form-side disables the slug input in edit mode so
  // it's never reached, but we double-down by omitting it here too.
  const payload: ServiceOfferingUpdate = {
    name: form.name.trim(),
    protocol: form.protocol,
    backend_host: form.backend_host.trim(),
    backend_port: parseInt(form.backend_port, 10),
    default_grant_ttl_days: parseInt(form.default_grant_ttl_days, 10),
    default_grant_scopes: form.default_grant_scopes,
  };
  if (form.description_markdown.trim()) {
    payload.description_markdown = form.description_markdown;
  }
  if (form.subscription_terms_markdown.trim()) {
    payload.subscription_terms_markdown = form.subscription_terms_markdown;
  }
  if (form.max_subscribers.trim() !== '') {
    payload.capacity_metadata = { max_subscribers: parseInt(form.max_subscribers, 10) };
  } else {
    // Operator cleared the cap → explicitly send empty capacity_metadata
    // to overwrite any prior cap.
    payload.capacity_metadata = {};
  }
  return payload;
}
