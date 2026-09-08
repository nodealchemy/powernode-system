import React, { useState, useEffect } from 'react';
import { Copy } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import { CompositionReportPanel } from './CompositionReportPanel';
import type { TemplateCompositionReportEntry } from '@system/features/system/services/api/templatesApi';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';

interface CloneTemplateModalProps {
  /** Source template. Null closes the modal. */
  template: SystemNodeTemplate | null;
  isOpen: boolean;
  onClose: () => void;
  onCloned?: (template: SystemNodeTemplate) => void;
}

/**
 * Server-side deep clone of a template.
 *
 * Distinct from the list's "Duplicate", which only prefills the create form:
 * this copies the source's module assignments wholesale, so the operator gets
 * a template that already composes, and inherits whatever composition
 * conflicts the source carried.
 *
 * The clone therefore does NOT close on success when the backend returns a
 * `composition_report`. That report is advisory at the API boundary — the
 * service reports rather than refusing — so a modal that closed on the
 * success notification would put the only copy of it in a toast.
 */
export const CloneTemplateModal: React.FC<CloneTemplateModalProps> = ({
  template,
  isOpen,
  onClose,
  onCloned
}) => {
  const { addNotification } = useNotifications();
  const [name, setName] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<TemplateCompositionReportEntry[] | null>(null);

  // Reset per opening: the modal is rendered permanently by its parent and
  // returns null when closed, so without this the previous clone's report and
  // typed name would be waiting for the next template.
  useEffect(() => {
    if (isOpen) {
      setName('');
      setError(null);
      setReport(null);
      setSubmitting(false);
    }
  }, [isOpen, template?.id]);

  if (!isOpen || !template) return null;

  const handleClone = async () => {
    setSubmitting(true);
    setError(null);
    try {
      const result = await systemApi.cloneTemplate(template.id, name.trim() || undefined);
      addNotification({ type: 'success', message: `Template cloned as "${result.template.name}"` });
      onCloned?.(result.template);

      if (result.composition_report?.length) {
        setReport(result.composition_report);
      } else {
        onClose();
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to clone template');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Clone Template"
      subtitle={`Deep copy of ${template.name}, including its module assignments`}
      icon={<Copy className="w-6 h-6" />}
      size="lg"
      footer={
        <div className="flex items-center gap-3">
          {!report && (
            <Button variant="primary" onClick={handleClone} disabled={submitting}>
              {submitting && <LoadingSpinner size="sm" className="mr-2" />}
              Clone Template
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
            intro="The clone was created and carries the source template's composition conflicts."
          />
        ) : (
          <>
            <p className="text-sm text-theme-secondary">
              Copies every module assignment from <span className="font-medium text-theme-primary">{template.name}</span>{' '}
              with its priority, enabled flag and per-module configuration intact.
            </p>
            <FormField
              label="New template name"
              value={name}
              onChange={setName}
              placeholder={`${template.name}-copy`}
              disabled={submitting}
              helpText="Leave blank to use the default name."
            />
          </>
        )}
      </div>
    </Modal>
  );
};

export default CloneTemplateModal;
