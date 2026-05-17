import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Globe,
  AlertCircle,
  X,
  Plus,
  Trash2,
  RefreshCw,
  Check,
  Edit2,
} from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { dnsRecordsApi } from '../../services/api/dnsRecordsApi';
import type {
  CloudflareZone,
  CreateRecordRequest,
  DnsRecord,
  DnsRecordType,
} from '../../types/dns.types';

/**
 * DNS record management modal. Opened from AcmeDnsCredentialsPanel —
 * uses the credential's Vault-stored api_token to surface every zone
 * the token has access to, then lets the operator CRUD records inline.
 *
 * Layout:
 *   [Zone selector] [Refresh]
 *   [Records table — type / name / content / TTL / proxied / actions]
 *   [+ Add Record] (collapses to inline form)
 *
 * Plan reference: CF-DNS.3.
 */

interface DnsRecordsModalProps {
  isOpen: boolean;
  credentialId: string | null;
  credentialName: string;
  onClose: () => void;
}

const RECORD_TYPES: DnsRecordType[] = ['A', 'AAAA', 'CNAME', 'TXT', 'MX', 'SRV', 'NS', 'CAA', 'PTR'];

export const DnsRecordsModal: React.FC<DnsRecordsModalProps> = ({
  isOpen,
  credentialId,
  credentialName,
  onClose,
}) => {
  const [zones, setZones] = useState<CloudflareZone[]>([]);
  const [selectedZoneId, setSelectedZoneId] = useState<string | null>(null);
  const [records, setRecords] = useState<DnsRecord[]>([]);
  const [loadingZones, setLoadingZones] = useState(false);
  const [loadingRecords, setLoadingRecords] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showAddForm, setShowAddForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);

  const fetchZones = useCallback(async () => {
    if (!credentialId) return;
    setLoadingZones(true);
    setError(null);
    try {
      const zs = await dnsRecordsApi.listZones(credentialId);
      setZones(zs);
      if (zs.length > 0 && !selectedZoneId) {
        setSelectedZoneId(zs[0].id);
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load zones');
    } finally {
      setLoadingZones(false);
    }
  }, [credentialId, selectedZoneId]);

  const fetchRecords = useCallback(async () => {
    if (!credentialId || !selectedZoneId) return;
    setLoadingRecords(true);
    setError(null);
    try {
      const rs = await dnsRecordsApi.listRecords(credentialId, selectedZoneId);
      setRecords(rs);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Failed to load records');
    } finally {
      setLoadingRecords(false);
    }
  }, [credentialId, selectedZoneId]);

  useEffect(() => {
    if (isOpen) {
      void fetchZones();
      setShowAddForm(false);
      setEditingId(null);
    } else {
      setZones([]);
      setSelectedZoneId(null);
      setRecords([]);
      setError(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen, credentialId]);

  useEffect(() => {
    if (selectedZoneId) void fetchRecords();
  }, [selectedZoneId, fetchRecords]);

  const handleDelete = async (record: DnsRecord) => {
    if (!credentialId || !selectedZoneId) return;
    const ok = window.confirm(
      `Delete ${record.type} record "${record.name}" → "${record.content}"?\n\nThis is permanent.`,
    );
    if (!ok) return;
    setDeletingId(record.id);
    setError(null);
    try {
      await dnsRecordsApi.deleteRecord(credentialId, record.id, selectedZoneId);
      await fetchRecords();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Delete failed');
    } finally {
      setDeletingId(null);
    }
  };

  const handleAdded = () => {
    setShowAddForm(false);
    void fetchRecords();
  };

  const handleUpdated = () => {
    setEditingId(null);
    void fetchRecords();
  };

  if (!credentialId) return null;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <div className="flex items-center gap-2">
          <Globe className="w-5 h-5 text-theme-info" />
          <span>DNS Records — </span>
          <code className="font-mono text-sm text-theme-secondary">{credentialName}</code>
        </div>
      }
      maxWidth="4xl"
      footer={
        <div className="flex items-center justify-between">
          <Button variant="ghost" onClick={onClose}>Close</Button>
          {!showAddForm && selectedZoneId && (
            <Button variant="primary" onClick={() => setShowAddForm(true)}>
              <Plus className="w-4 h-4" />
              Add Record
            </Button>
          )}
        </div>
      }
    >
      <div className="space-y-4">
        {error && (
          <div className="p-2 bg-theme-danger text-theme-danger text-sm rounded flex items-start gap-2">
            <AlertCircle className="w-4 h-4 mt-0.5 flex-shrink-0" />
            <span className="flex-1">{error}</span>
            <button type="button" onClick={() => setError(null)} className="p-1">
              <X className="w-3 h-3" />
            </button>
          </div>
        )}

        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2 flex-1">
            <label className="text-xs font-medium text-theme-secondary">Zone</label>
            <select
              value={selectedZoneId ?? ''}
              onChange={(e) => setSelectedZoneId(e.target.value)}
              disabled={loadingZones}
              className="flex-1 px-2 py-1 border border-theme rounded bg-theme-background-secondary text-theme-primary text-sm disabled:opacity-50 font-mono"
            >
              {loadingZones ? (
                <option>Loading zones…</option>
              ) : zones.length === 0 ? (
                <option>No zones available</option>
              ) : (
                zones.map((z) => (
                  <option key={z.id} value={z.id}>
                    {z.name} ({z.status})
                  </option>
                ))
              )}
            </select>
          </div>
          <button
            type="button"
            onClick={() => {
              void fetchZones();
              if (selectedZoneId) void fetchRecords();
            }}
            disabled={loadingZones || loadingRecords}
            className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
            title="Refresh"
          >
            <RefreshCw className={`w-4 h-4 ${(loadingZones || loadingRecords) ? 'animate-spin' : ''}`} />
          </button>
        </div>

        {showAddForm && selectedZoneId && (
          <AddRecordForm
            credentialId={credentialId}
            zoneId={selectedZoneId}
            onAdded={handleAdded}
            onCancel={() => setShowAddForm(false)}
          />
        )}

        {loadingRecords ? (
          <div className="p-8 text-center text-theme-secondary text-sm">Loading records…</div>
        ) : records.length === 0 ? (
          <div className="p-8 text-center text-theme-secondary text-sm border border-theme rounded">
            No DNS records on this zone yet.
          </div>
        ) : (
          <div className="max-h-96 overflow-y-auto">
            <table className="w-full text-sm">
              <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase sticky top-0">
                <tr>
                  <th className="text-left px-3 py-2 font-medium">Type</th>
                  <th className="text-left px-3 py-2 font-medium">Name</th>
                  <th className="text-left px-3 py-2 font-medium">Content</th>
                  <th className="text-left px-3 py-2 font-medium">TTL</th>
                  <th className="text-left px-3 py-2 font-medium">Proxy</th>
                  <th className="text-right px-3 py-2 font-medium">Actions</th>
                </tr>
              </thead>
              <tbody>
                {records.map((r) =>
                  editingId === r.id ? (
                    <EditRecordRow
                      key={r.id}
                      record={r}
                      credentialId={credentialId}
                      zoneId={selectedZoneId!}
                      onCancel={() => setEditingId(null)}
                      onUpdated={handleUpdated}
                    />
                  ) : (
                    <RecordRow
                      key={r.id}
                      record={r}
                      onEdit={() => setEditingId(r.id)}
                      onDelete={() => handleDelete(r)}
                      isDeleting={deletingId === r.id}
                    />
                  ),
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </Modal>
  );
};

// ── Read-only row ─────────────────────────────────────────────────────

const RecordRow: React.FC<{
  record: DnsRecord;
  onEdit: () => void;
  onDelete: () => void;
  isDeleting: boolean;
}> = ({ record, onEdit, onDelete, isDeleting }) => (
  <tr className="border-t border-theme hover:bg-theme-surface-hover transition-colors">
    <td className="px-3 py-2">
      <span className="inline-block px-1.5 py-0.5 bg-theme-background-secondary rounded text-xs font-mono">
        {record.type}
      </span>
    </td>
    <td className="px-3 py-2 font-mono text-xs text-theme-primary break-all">{record.name}</td>
    <td className="px-3 py-2 font-mono text-xs text-theme-secondary break-all max-w-md">
      {record.content}
    </td>
    <td className="px-3 py-2 text-xs text-theme-secondary">
      {record.ttl === 1 ? 'auto' : record.ttl}
    </td>
    <td className="px-3 py-2 text-xs text-theme-secondary">
      {record.proxied ? <span className="text-theme-info">proxied</span> : '—'}
    </td>
    <td className="px-3 py-2 text-right">
      <button
        type="button"
        onClick={onEdit}
        className="p-1 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors mr-1"
        title="Edit record"
      >
        <Edit2 className="w-3 h-3" />
      </button>
      <button
        type="button"
        onClick={onDelete}
        disabled={isDeleting}
        className="p-1 rounded text-theme-danger hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
        title="Delete record"
      >
        <Trash2 className="w-3 h-3" />
      </button>
    </td>
  </tr>
);

// ── Edit row ──────────────────────────────────────────────────────────

const EditRecordRow: React.FC<{
  record: DnsRecord;
  credentialId: string;
  zoneId: string;
  onCancel: () => void;
  onUpdated: () => void;
}> = ({ record, credentialId, zoneId, onCancel, onUpdated }) => {
  const [name, setName] = useState(record.name);
  const [content, setContent] = useState(record.content);
  const [ttl, setTtl] = useState(String(record.ttl));
  const [proxied, setProxied] = useState(!!record.proxied);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSave = async () => {
    setSubmitting(true);
    setError(null);
    try {
      await dnsRecordsApi.updateRecord(credentialId, record.id, {
        zone_id: zoneId,
        name,
        content,
        ttl: parseInt(ttl, 10) || 1,
        proxied,
      });
      onUpdated();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Update failed');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <tr className="border-t border-theme bg-theme-background-secondary">
      <td className="px-3 py-2 font-mono text-xs">{record.type}</td>
      <td className="px-3 py-2">
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          disabled={submitting}
          className="w-full px-1.5 py-0.5 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs"
        />
      </td>
      <td className="px-3 py-2">
        <input
          type="text"
          value={content}
          onChange={(e) => setContent(e.target.value)}
          disabled={submitting}
          className="w-full px-1.5 py-0.5 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs"
        />
      </td>
      <td className="px-3 py-2">
        <input
          type="number"
          value={ttl}
          onChange={(e) => setTtl(e.target.value)}
          disabled={submitting}
          className="w-16 px-1.5 py-0.5 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs"
        />
      </td>
      <td className="px-3 py-2">
        <input
          type="checkbox"
          checked={proxied}
          onChange={(e) => setProxied(e.target.checked)}
          disabled={submitting || !['A', 'AAAA', 'CNAME'].includes(record.type)}
        />
      </td>
      <td className="px-3 py-2 text-right">
        <button
          type="button"
          onClick={handleSave}
          disabled={submitting}
          className="p-1 rounded text-theme-success hover:bg-theme-surface-hover transition-colors mr-1"
          title="Save"
        >
          <Check className="w-3 h-3" />
        </button>
        <button
          type="button"
          onClick={onCancel}
          disabled={submitting}
          className="p-1 rounded text-theme-secondary hover:bg-theme-surface-hover transition-colors"
          title="Cancel"
        >
          <X className="w-3 h-3" />
        </button>
        {error && <div className="text-xs text-theme-danger mt-1">{error}</div>}
      </td>
    </tr>
  );
};

// ── Add form ──────────────────────────────────────────────────────────

const AddRecordForm: React.FC<{
  credentialId: string;
  zoneId: string;
  onAdded: () => void;
  onCancel: () => void;
}> = ({ credentialId, zoneId, onAdded, onCancel }) => {
  const [type, setType] = useState<DnsRecordType>('A');
  const [name, setName] = useState('');
  const [content, setContent] = useState('');
  const [ttl, setTtl] = useState('1');
  const [proxied, setProxied] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const supportsProxy = useMemo(() => ['A', 'AAAA', 'CNAME'].includes(type), [type]);

  const validation = useMemo(() => {
    const errs: string[] = [];
    if (!name.trim()) errs.push('name is required');
    if (!content.trim()) errs.push('content is required');
    return { ok: errs.length === 0, errs };
  }, [name, content]);

  const handleSubmit = async () => {
    if (!validation.ok) {
      setError(validation.errs[0] ?? 'Form invalid');
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const req: CreateRecordRequest = {
        zone_id: zoneId,
        type,
        name: name.trim(),
        content: content.trim(),
        ttl: parseInt(ttl, 10) || 1,
        proxied: supportsProxy ? proxied : false,
      };
      await dnsRecordsApi.createRecord(credentialId, req);
      onAdded();
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Create failed');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="p-3 bg-theme-background-secondary border border-theme rounded space-y-3">
      <div className="flex items-center justify-between">
        <h4 className="text-sm font-semibold text-theme-primary inline-flex items-center gap-2">
          <Plus className="w-4 h-4 text-theme-info" />
          Add DNS Record
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
        </div>
      )}

      <div className="grid grid-cols-12 gap-2">
        <div className="col-span-2">
          <label className="block text-xs font-medium text-theme-secondary mb-1">Type</label>
          <select
            value={type}
            onChange={(e) => setType(e.target.value as DnsRecordType)}
            disabled={submitting}
            className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary text-xs disabled:opacity-50"
          >
            {RECORD_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
        <div className="col-span-4">
          <label className="block text-xs font-medium text-theme-secondary mb-1">Name *</label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            disabled={submitting}
            placeholder="e.g. hub.example.org"
            className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
          />
        </div>
        <div className="col-span-4">
          <label className="block text-xs font-medium text-theme-secondary mb-1">Content *</label>
          <input
            type="text"
            value={content}
            onChange={(e) => setContent(e.target.value)}
            disabled={submitting}
            placeholder={contentPlaceholder(type)}
            className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
          />
        </div>
        <div className="col-span-1">
          <label className="block text-xs font-medium text-theme-secondary mb-1">TTL</label>
          <input
            type="number"
            min={1}
            max={86400}
            value={ttl}
            onChange={(e) => setTtl(e.target.value)}
            disabled={submitting}
            className="w-full px-2 py-1 border border-theme rounded bg-theme-surface text-theme-primary font-mono text-xs disabled:opacity-50"
            title="1 = auto"
          />
        </div>
        <div className="col-span-1 flex items-end justify-center pb-1">
          <input
            type="checkbox"
            checked={proxied}
            onChange={(e) => setProxied(e.target.checked)}
            disabled={submitting || !supportsProxy}
            title={supportsProxy ? 'Proxy through Cloudflare' : 'Proxy not supported for this type'}
          />
        </div>
      </div>

      <div className="flex items-center justify-end gap-2">
        <Button variant="ghost" onClick={onCancel} disabled={submitting}>Cancel</Button>
        <Button variant="primary" onClick={handleSubmit} disabled={submitting || !validation.ok}>
          {submitting ? 'Adding…' : 'Add Record'}
        </Button>
      </div>
    </div>
  );
};

function contentPlaceholder(type: DnsRecordType): string {
  switch (type) {
    case 'A': return '192.0.2.1';
    case 'AAAA': return '2001:db8::1';
    case 'CNAME': return 'target.example.org';
    case 'TXT': return 'v=spf1 …';
    case 'MX': return 'mail.example.org';
    case 'NS': return 'ns1.example.org';
    case 'CAA': return '0 issue "letsencrypt.org"';
    case 'PTR': return 'host.example.org';
    case 'SRV': return '_proto._service target';
    default: return '';
  }
}
