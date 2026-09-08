import React, { useState, useEffect, useRef } from 'react';
import { Upload } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { logger } from '@/shared/utils/logger';
import { systemApi } from '@system/features/system/services/systemApi';
import { CompositionReportPanel } from './CompositionReportPanel';
import type { TemplateCompositionReportEntry } from '@system/features/system/services/api/templatesApi';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';

interface ImportTemplateModalProps {
  isOpen: boolean;
  onClose: () => void;
  onImported?: (template: SystemNodeTemplate) => void;
}

/**
 * Import a template bundle produced by the list's Export action.
 *
 * The bundle is parsed in the browser before it is sent: the endpoint accepts
 * a JSON string and answers a bad one with a 400 whose message is the parser's,
 * which is a poor way to learn that a paste was truncated. Parsing here also
 * means the request body is always the object shape.
 *
 * Like a clone, an import materializes a whole template's joins outside the
 * per-assignment composition guard, so the returned report is shown rather
 * than closed over.
 */
export const ImportTemplateModal: React.FC<ImportTemplateModalProps> = ({
  isOpen,
  onClose,
  onImported
}) => {
  const { addNotification } = useNotifications();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [bundleText, setBundleText] = useState('');
  const [name, setName] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<TemplateCompositionReportEntry[] | null>(null);
  const [importedCount, setImportedCount] = useState<number | null>(null);

  useEffect(() => {
    if (isOpen) {
      setBundleText('');
      setName('');
      setError(null);
      setReport(null);
      setImportedCount(null);
      setSubmitting(false);
    }
  }, [isOpen]);

  if (!isOpen) return null;

  const handleFile = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = () => {
      setBundleText(typeof reader.result === 'string' ? reader.result : '');
      setError(null);
    };
    reader.onerror = () => {
      logger.warn('Template bundle file could not be read', { name: file.name });
      setError('Could not read that file.');
    };
    reader.readAsText(file);
  };

  const handleImport = async () => {
    let bundle: Record<string, unknown>;
    try {
      const parsed: unknown = JSON.parse(bundleText);
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        setError('The bundle must be a JSON object.');
        return;
      }
      bundle = parsed as Record<string, unknown>;
    } catch (err) {
      setError(`That is not valid JSON: ${err instanceof Error ? err.message : 'parse failed'}`);
      return;
    }

    setSubmitting(true);
    setError(null);
    try {
      const result = await systemApi.importTemplate(bundle, name.trim() || undefined);
      addNotification({
        type: 'success',
        message: `Imported "${result.template.name}" with ${result.template_modules_count} module assignment(s)`
      });
      onImported?.(result.template);

      if (result.composition_report?.length) {
        setImportedCount(result.template_modules_count);
        setReport(result.composition_report);
      } else {
        onClose();
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to import template');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Import Template"
      subtitle="Restore a template bundle exported from this or another deployment"
      icon={<Upload className="w-6 h-6" />}
      size="lg"
      footer={
        <div className="flex items-center gap-3">
          {!report && (
            <Button
              variant="primary"
              onClick={handleImport}
              disabled={submitting || bundleText.trim().length === 0}
            >
              {submitting && <LoadingSpinner size="sm" className="mr-2" />}
              Import Template
            </Button>
          )}
          <Button variant="ghost" onClick={onClose}>
            {report ? 'Done' : 'Cancel'}
          </Button>
        </div>
      }
    >
      <div className="space-y-4">
        {error && <ErrorAlert message={error} onClose={() => setError(null)} />}

        {report ? (
          <CompositionReportPanel
            entries={report}
            intro={`The template was imported with ${importedCount ?? 0} module assignment(s) and composes with conflicts.`}
          />
        ) : (
          <>
            <div>
              <label className="block text-sm text-theme-secondary mb-1" htmlFor="template-bundle-file">
                Bundle file
              </label>
              <input
                id="template-bundle-file"
                ref={fileInputRef}
                type="file"
                accept="application/json,.json"
                onChange={handleFile}
                disabled={submitting}
                className="block w-full text-sm text-theme-primary file:mr-3 file:py-2 file:px-4 file:rounded-lg file:border file:border-theme file:bg-theme-surface file:text-theme-primary hover:file:bg-theme-background"
              />
            </div>

            <FormField
              label="Bundle JSON"
              type="textarea"
              rows={10}
              value={bundleText}
              onChange={(value) => {
                setBundleText(value);
                setError(null);
              }}
              disabled={submitting}
              placeholder='{"node_template": { … }, "template_modules": [ … ]}'
              helpText="Choose a file above or paste the exported bundle here."
            />

            <FormField
              label="Import as name"
              value={name}
              onChange={setName}
              disabled={submitting}
              placeholder="Name carried in the bundle"
              helpText="Leave blank to keep the name the bundle carries."
            />
          </>
        )}
      </div>
    </Modal>
  );
};

export default ImportTemplateModal;
