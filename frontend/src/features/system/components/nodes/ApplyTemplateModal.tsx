import React, { useState, useEffect } from 'react';
import { Layers, AlertTriangle } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { ConfirmationModal } from '@/shared/components/ui/ConfirmationModal';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { TemplateApplyResult } from '@system/features/system/services/api/nodesApi';
import type { SystemNode } from '@system/features/system/types/system.types';

interface ApplyTemplateModalProps {
  node: SystemNode | null;
  isOpen: boolean;
  onClose: () => void;
  onApplied?: () => void;
}

/**
 * Re-apply a node's template.
 *
 * The dry run is MANDATORY, not a convenience: apply_template creates
 * NodeModule assignments and, with `purge_stale`, deletes the ones the
 * template no longer carries. Nothing about the button reveals how many rows
 * that is, and on a node whose template drifted the purge count is exactly the
 * number the operator needs before agreeing.
 *
 * The preview is therefore pinned to the flags it was computed with. Toggling
 * `purge_stale` after previewing invalidates the preview rather than leaving a
 * stale created/skipped/purged summary next to an Apply button that would now
 * do something different — the counts on screen must always describe the
 * request the button will send.
 */
export const ApplyTemplateModal: React.FC<ApplyTemplateModalProps> = ({
  node,
  isOpen,
  onClose,
  onApplied
}) => {
  const { addNotification } = useNotifications();

  const [purgeStale, setPurgeStale] = useState(false);
  const [preview, setPreview] = useState<TemplateApplyResult | null>(null);
  // The purge_stale the preview on screen was computed with. Compared against
  // the live checkbox so a toggle cannot silently re-label an old plan.
  const [previewPurgeStale, setPreviewPurgeStale] = useState(false);
  const [busy, setBusy] = useState<'preview' | 'apply' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmOpen, setConfirmOpen] = useState(false);

  useEffect(() => {
    if (isOpen) {
      setPurgeStale(false);
      setPreview(null);
      setPreviewPurgeStale(false);
      setBusy(null);
      setError(null);
      setConfirmOpen(false);
    }
  }, [isOpen, node?.id]);

  if (!isOpen || !node) return null;

  const previewIsCurrent = preview !== null && previewPurgeStale === purgeStale;

  // TemplateApplyService#preview appends this to every dry run's warnings. It
  // describes the MODE, not the composition, and rendering it with a warning
  // badge next to real conflicts is exactly the dilution the per-entry
  // severity work exists to prevent — the panel already says "Dry-run result".
  const DRY_RUN_SENTINEL = 'dry_run: no changes persisted';
  const previewWarnings = (preview?.warnings ?? []).filter((w) => w !== DRY_RUN_SENTINEL);

  const runPreview = async () => {
    setBusy('preview');
    setError(null);
    try {
      const result = await systemApi.applyTemplate(node.id, { dry_run: true, purge_stale: purgeStale });
      setPreview(result);
      setPreviewPurgeStale(purgeStale);
    } catch (err) {
      setPreview(null);
      setError(err instanceof Error ? err.message : 'Failed to preview the template apply');
    } finally {
      setBusy(null);
    }
  };

  const runApply = async () => {
    setBusy('apply');
    setError(null);
    try {
      const result = await systemApi.applyTemplate(node.id, { dry_run: false, purge_stale: purgeStale });
      addNotification({
        type: 'success',
        message:
          `Template applied: ${result.created_count} created, ${result.skipped_count} skipped` +
          (result.purged_count > 0 ? `, ${result.purged_count} purged` : '')
      });
      onApplied?.();
      onClose();
    } catch (err) {
      // The server refused, so the plan on screen no longer describes anything
      // it agreed to. Drop it rather than leave counts next to a live Apply
      // button that would re-send a request the server has already rejected.
      setPreview(null);
      setError(err instanceof Error ? err.message : 'Failed to apply the template');
    } finally {
      setBusy(null);
    }
  };

  // Purging removes assignments that exist on the node today, so it is the one
  // path that asks twice. `ConfirmationModal` is rendered directly rather than
  // through `useConfirmation` because this component needs to KNOW when the
  // dialog is open: the shared Modal listens for Escape on `document`, so one
  // press would otherwise close the confirmation and this modal together. The
  // hook exposes no dismissal signal, only a confirm callback.
  const handleApplyClick = () => {
    if (!purgeStale) {
      void runApply();
      return;
    }
    setConfirmOpen(true);
  };

  return (
    <>
      <Modal
        isOpen={isOpen}
        onClose={onClose}
        title="Apply Template"
        subtitle={node.node_template_name ? `${node.name} — ${node.node_template_name}` : node.name}
        icon={<Layers className="w-6 h-6" />}
        size="lg"
        closeOnEscape={!confirmOpen}
        footer={
          <div className="flex items-center gap-3">
            <Button variant="secondary" onClick={runPreview} disabled={busy !== null}>
              {busy === 'preview' && <LoadingSpinner size="sm" className="mr-2" />}
              {preview ? 'Re-run preview' : 'Preview changes'}
            </Button>
            <Button
              variant="primary"
              onClick={handleApplyClick}
              disabled={busy !== null || !previewIsCurrent}
              title={previewIsCurrent ? undefined : 'Run the dry-run preview first'}
            >
              {busy === 'apply' && <LoadingSpinner size="sm" className="mr-2" />}
              Apply Template
            </Button>
            <Button variant="ghost" onClick={onClose}>
              Cancel
            </Button>
          </div>
        }
      >
        <div className="space-y-4">
          {error && <ErrorAlert message={error} onClose={() => setError(null)} />}

          <p className="text-sm text-theme-secondary">
            Re-applies the node&apos;s template, creating any module assignment the node is missing.
            Preview the plan before applying — nothing is written by a preview.
          </p>

          <label className="flex items-start gap-3 cursor-pointer">
            <input
              type="checkbox"
              checked={purgeStale}
              onChange={(e) => setPurgeStale(e.target.checked)}
              disabled={busy !== null}
              className="mt-1"
            />
            <span>
              <span className="block text-sm font-medium text-theme-primary">
                Also remove assignments the template no longer carries
              </span>
              <span className="block text-xs text-theme-secondary">
                Destructive. Deletes existing module assignments on this node.
              </span>
            </span>
          </label>

          {preview && !previewIsCurrent && (
            <div className="bg-theme-warning-bg border border-theme-warning-border rounded-lg p-3 flex items-start gap-2">
              <AlertTriangle className="w-4 h-4 text-theme-warning-fg mt-0.5" />
              <p className="text-sm text-theme-warning-fg">
                The purge option changed since this preview ran. Re-run the preview to see what
                Apply would do now.
              </p>
            </div>
          )}

          {preview && (
            <div className="bg-theme-background border border-theme rounded-lg p-4 space-y-3">
              <h4 className="font-medium text-theme-primary">Dry-run result</h4>
              <div className="grid grid-cols-3 gap-4">
                <div>
                  <div className="text-xs text-theme-secondary">Created</div>
                  <div className="text-lg font-mono text-theme-primary">{preview.created_count}</div>
                </div>
                <div>
                  <div className="text-xs text-theme-secondary">Skipped</div>
                  <div className="text-lg font-mono text-theme-primary">{preview.skipped_count}</div>
                </div>
                <div>
                  <div className="text-xs text-theme-secondary">Purged</div>
                  <div className="text-lg font-mono text-theme-primary">{preview.purged_count}</div>
                </div>
              </div>

              {previewWarnings.length > 0 && (
                <div>
                  <div className="text-xs font-medium text-theme-warning-fg mb-1">Warnings</div>
                  <ul className="space-y-1">
                    {previewWarnings.map((w, idx) => (
                      <li key={idx} className="flex items-start gap-2 text-sm">
                        <Badge variant="warning" size="xs">warning</Badge>
                        <span className="text-theme-primary">{w}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              )}

              {preview.errors.length > 0 && (
                <div>
                  <div className="text-xs font-medium text-theme-error-fg mb-1">Errors</div>
                  <ul className="space-y-1">
                    {preview.errors.map((e, idx) => (
                      <li key={idx} className="flex items-start gap-2 text-sm">
                        <Badge variant="danger" size="xs">error</Badge>
                        <span className="text-theme-primary">{e}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              )}
            </div>
          )}
        </div>
      </Modal>

      <ConfirmationModal
        isOpen={confirmOpen}
        onClose={() => setConfirmOpen(false)}
        onConfirm={() => {
          setConfirmOpen(false);
          void runApply();
        }}
        title="Purge stale module assignments"
        // The dry run already counted them, so the confirmation states the
        // number rather than asking the operator to carry it over from the
        // panel behind this dialog.
        message={`Applying with purge will remove ${preview?.purged_count ?? 0} module assignment(s) from "${node.name}" that the template no longer carries. This cannot be undone.`}
        confirmLabel="Apply and purge"
        cancelLabel="Keep assignments"
        variant="danger"
      />
    </>
  );
};

export default ApplyTemplateModal;
