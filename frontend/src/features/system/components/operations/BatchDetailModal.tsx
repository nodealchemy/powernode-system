import React, { useEffect, useState } from 'react';
import { Hammer, X, ShieldCheck, AlertCircle } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { EntityLink } from '@/shared/components/entity';
import { capitalize, formatDateTime, formatFileSize } from '@/shared/utils/formatters';
import { moduleBuildsApi } from '@system/features/system/services/api/moduleBuildsApi';
import type {
  SystemModuleBuildBatchFull,
  SystemModuleBuildBatchModule,
  SystemModuleBuildBatchStatus,
  SystemModuleBuildParity,
  SystemModuleBuildParityStatus,
} from '@system/features/system/types/system.types';

interface BatchDetailModalProps {
  batchId: string;
  onClose: () => void;
}

const STATUS_LABELS: Record<SystemModuleBuildBatchStatus, string> = {
  planning: 'Planning',
  dispatched: 'Dispatched',
  awaiting_signature: 'Awaiting signature',
  publishing: 'Publishing',
  complete: 'Complete',
  partial: 'Partial',
  failed: 'Failed',
};

function statusVariant(
  status: SystemModuleBuildBatchStatus
): 'outline' | 'warning' | 'success' | 'danger' {
  switch (status) {
    case 'planning':
      return 'outline';
    case 'dispatched':
    case 'awaiting_signature':
    case 'publishing':
      return 'warning';
    case 'complete':
      return 'success';
    case 'partial':
      return 'warning';
    case 'failed':
      return 'danger';
    default:
      return 'outline';
  }
}

// NativeModuleBuildOrchestrator::TERMINAL_MODULE_STATES + "queued"/
// "dispatched" — the only 4 values entry["state"] ever takes.
function moduleStateVariant(state: string): 'outline' | 'warning' | 'success' | 'danger' {
  switch (state) {
    case 'queued':
      return 'outline';
    case 'dispatched':
      return 'warning';
    case 'succeeded':
      return 'success';
    case 'failed':
      return 'danger';
    default:
      return 'outline';
  }
}

// ModuleBuildParityService::STATUSES.
function parityVariant(
  status: SystemModuleBuildParityStatus
): 'success' | 'warning' | 'danger' | 'secondary' {
  switch (status) {
    case 'ok':
      return 'success';
    case 'waived':
      return 'warning';
    case 'failed':
    case 'error':
      return 'danger';
    default:
      return 'secondary';
  }
}

function parityTooltip(parity: SystemModuleBuildParity): string | undefined {
  if (parity.status === 'failed' && parity.diff_summary) {
    const { added, removed, changed } = parity.diff_summary;
    return `${added.length} added, ${removed.length} removed, ${changed.length} changed`;
  }
  if (parity.status === 'error' && parity.error) {
    return parity.error;
  }
  return undefined;
}

// The 5 AASM timestamp columns — narrowed to just these keys (rather than
// `keyof SystemModuleBuildBatchFull`) so `batch[step.key]` types as
// `string | null | undefined` and needs no unsafe cast below.
type TimelineKey = 'dispatched_at' | 'awaiting_signature_at' | 'publishing_at' | 'completed_at' | 'failed_at';

const TIMELINE_STEPS: { key: TimelineKey; label: string }[] = [
  { key: 'dispatched_at', label: 'Dispatched' },
  { key: 'awaiting_signature_at', label: 'Awaiting signature' },
  { key: 'publishing_at', label: 'Publishing' },
  { key: 'completed_at', label: 'Completed' },
  { key: 'failed_at', label: 'Failed' },
];

/**
 * Self-fetching detail modal for a System::ModuleBuildBatch — the AASM
 * timestamp ladder + per-module build/parity/artifact breakdown
 * (ModuleBuildBatchSerializer#as_full). Registered in entityRegistry as
 * `module_build_batch` (object-agnostic `fetchById`) so notifications/
 * signals can also EntityLink straight to a batch; this component is the
 * one BatchList itself opens directly by id.
 */
export const BatchDetailModal: React.FC<BatchDetailModalProps> = ({ batchId, onClose }) => {
  const [batch, setBatch] = useState<SystemModuleBuildBatchFull | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadFailed, setLoadFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setLoadFailed(false);
    moduleBuildsApi.get(batchId)
      .then((result) => {
        if (!cancelled) setBatch(result);
      })
      .catch(() => {
        if (!cancelled) setLoadFailed(true);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => { cancelled = true; };
  }, [batchId]);

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto">
      <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={onClose} />

      <div className="flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-4xl bg-theme-surface rounded-lg shadow-xl">
          {/* Header */}
          <div className="flex items-center justify-between p-4 border-b border-theme">
            <div className="flex items-center gap-3 min-w-0">
              <Hammer className="w-6 h-6 text-theme-info-fg flex-shrink-0" />
              <div className="min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <h2 className="text-lg font-semibold text-theme-primary">
                    {loading ? 'Loading…' : 'Module build batch'}
                  </h2>
                  {batch && (
                    <>
                      <Badge variant={statusVariant(batch.status)} size="sm">
                        {STATUS_LABELS[batch.status] ?? batch.status}
                      </Badge>
                      {batch.shadow && <Badge variant="outline" size="sm">shadow</Badge>}
                    </>
                  )}
                </div>
                {batch && (
                  <p className="text-sm text-theme-secondary font-mono truncate">
                    {batch.base_sha.slice(0, 7)}→{batch.head_sha.slice(0, 7)}
                  </p>
                )}
              </div>
            </div>
            <Button variant="ghost" size="sm" onClick={onClose}>
              <X className="w-5 h-5" />
            </Button>
          </div>

          {/* Body */}
          <div className="p-6 max-h-[70vh] overflow-y-auto space-y-6">
            {loading ? (
              <div className="flex items-center justify-center py-12">
                <LoadingSpinner size="lg" />
              </div>
            ) : !batch || loadFailed ? (
              <div className="text-center py-12">
                <AlertCircle className="w-12 h-12 text-theme-error-fg mx-auto mb-4" />
                <p className="text-theme-error-fg">Failed to load batch details</p>
              </div>
            ) : (
              <>
                {/* Summary */}
                <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-4">
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Trigger</label>
                    <p className="text-theme-primary">{capitalize(batch.trigger)}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Modules</label>
                    <p className="text-theme-primary">{batch.succeeded_count}/{batch.planned_count} succeeded{batch.failed_count > 0 ? `, ${batch.failed_count} failed` : ''}</p>
                  </div>
                  <div>
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Created</label>
                    <p className="text-theme-primary text-sm">{formatDateTime(batch.created_at)}</p>
                  </div>
                  <div className="sm:col-span-2 md:col-span-3">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Base SHA</label>
                    <p className="text-theme-primary font-mono text-xs break-all">{batch.base_sha}</p>
                  </div>
                  <div className="sm:col-span-2 md:col-span-3">
                    <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Head SHA</label>
                    <p className="text-theme-primary font-mono text-xs break-all">{batch.head_sha}</p>
                  </div>
                  {batch.package_context && (
                    <>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Package repo kind</label>
                        <p className="text-theme-primary">{batch.package_context.package_repo_kind ?? '—'}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Architecture</label>
                        <p className="text-theme-primary">{batch.package_context.architecture ?? '—'}</p>
                      </div>
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Snapshot / tag</label>
                        <p className="text-theme-primary">{batch.package_context.snapshot ?? '—'} / {batch.package_context.tag ?? '—'}</p>
                      </div>
                    </>
                  )}
                </div>

                {/* AASM timestamp ladder */}
                <div className="pt-4 border-t border-theme">
                  <h3 className="text-sm font-medium text-theme-primary mb-3">Timeline</h3>
                  <div className="grid grid-cols-2 sm:grid-cols-5 gap-4">
                    {TIMELINE_STEPS.map((step) => {
                      const value = batch[step.key];
                      return (
                        <div key={step.key}>
                          <div className="text-xs text-theme-secondary mb-1">{step.label}</div>
                          <p className={`text-xs ${value ? 'text-theme-primary' : 'text-theme-tertiary'}`}>
                            {formatDateTime(value)}
                          </p>
                        </div>
                      );
                    })}
                  </div>
                </div>

                {/* Error message */}
                {batch.error_message && (
                  <div className="bg-theme-danger-bg border border-theme-danger-border/30 rounded-lg p-4">
                    <div className="flex items-center gap-2 mb-2">
                      <AlertCircle className="w-5 h-5 text-theme-error-fg" />
                      <h4 className="font-medium text-theme-error-fg">Error</h4>
                    </div>
                    <pre className="text-sm text-theme-error-fg whitespace-pre-wrap font-mono">
                      {batch.error_message}
                    </pre>
                  </div>
                )}

                {/* Per-module breakdown */}
                <div className="pt-4 border-t border-theme">
                  <h3 className="text-sm font-medium text-theme-primary mb-3">Modules</h3>
                  <div className="overflow-x-auto">
                    <table className="w-full text-sm">
                      <thead>
                        <tr className="bg-theme-background border-b border-theme">
                          <th className="text-left py-2 px-3 font-medium text-theme-primary">Module</th>
                          <th className="text-left py-2 px-3 font-medium text-theme-primary">State</th>
                          <th className="text-left py-2 px-3 font-medium text-theme-primary">Attempts</th>
                          <th className="text-left py-2 px-3 font-medium text-theme-primary">Parity</th>
                          <th className="text-left py-2 px-3 font-medium text-theme-primary">Signed</th>
                          <th className="text-left py-2 px-3 font-medium text-theme-primary">Size</th>
                          <th className="text-left py-2 px-3 font-medium text-theme-primary">Task</th>
                          <th className="text-left py-2 px-3 font-medium text-theme-primary">Instance</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-theme">
                        {batch.modules.map((row: SystemModuleBuildBatchModule) => (
                          <tr key={row.module} className="hover:bg-theme-surface-hover transition-colors duration-200">
                            <td className="py-2 px-3 font-mono text-xs text-theme-primary">{row.module}</td>
                            <td className="py-2 px-3">
                              <Badge variant={moduleStateVariant(row.state)} size="xs">{row.state}</Badge>
                            </td>
                            <td className="py-2 px-3 text-theme-primary">{row.attempts}</td>
                            <td className="py-2 px-3">
                              {row.parity ? (
                                <span title={parityTooltip(row.parity)}>
                                  <Badge variant={parityVariant(row.parity.status)} size="xs">
                                    {row.parity.status}
                                  </Badge>
                                </span>
                              ) : (
                                <span className="text-theme-tertiary">—</span>
                              )}
                            </td>
                            <td className="py-2 px-3">
                              {row.artifact?.signed ? (
                                <span title="cosign bundle present">
                                  <ShieldCheck size={14} className="text-theme-success-fg" />
                                </span>
                              ) : (
                                <span className="text-theme-tertiary">—</span>
                              )}
                            </td>
                            <td className="py-2 px-3 text-theme-primary">
                              {row.artifact?.size_bytes != null ? formatFileSize(row.artifact.size_bytes) : '—'}
                            </td>
                            <td className="py-2 px-3">
                              {row.task ? (
                                <EntityLink type="system_task" id={row.task.id} label={row.task.status} className="text-xs" />
                              ) : (
                                <span className="text-theme-tertiary">—</span>
                              )}
                            </td>
                            <td className="py-2 px-3">
                              {/* node_instance EntityLink needs a composite "nodeId:instanceId" id
                                  the lease's node_instance_id alone can't supply (same limitation
                                  documented in entityRegistry.ts's resolveOperableType) — render
                                  plain text instead of a broken link. */}
                              {row.lease?.node_instance_id ? (
                                <span className="font-mono text-xs text-theme-secondary" title={row.lease.node_instance_id}>
                                  {row.lease.node_instance_id.slice(0, 8)}
                                </span>
                              ) : (
                                <span className="text-theme-tertiary">—</span>
                              )}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              </>
            )}
          </div>

          {/* Footer */}
          <div className="flex items-center justify-end p-4 border-t border-theme">
            <Button variant="outline" onClick={onClose}>Close</Button>
          </div>
        </div>
      </div>
    </div>
  );
};

export default BatchDetailModal;
