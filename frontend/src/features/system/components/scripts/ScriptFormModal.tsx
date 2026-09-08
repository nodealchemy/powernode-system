import React, { useState, useEffect } from 'react';
import { FileCode } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { FormField } from '@/shared/components/ui/FormField';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeScript } from '@system/features/system/types/system.types';

interface ScriptFormModalProps {
  isOpen: boolean;
  onClose: () => void;
  onScriptSaved?: (script: SystemNodeScript) => void;
  editScript?: SystemNodeScript | null;
}

/**
 * ScriptFormModal - Modal for creating or editing node scripts
 */
export const ScriptFormModal: React.FC<ScriptFormModalProps> = ({
  isOpen,
  onClose,
  onScriptSaved,
  editScript
}) => {
  const { addNotification } = useNotifications();

  const [formData, setFormData] = useState({
    name: '',
    description: '',
    variety: 'custom' as 'build' | 'init' | 'sync' | 'custom',
    data: '',
    enabled: true,
    public: false
  });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);

  const isEditMode = !!editScript;

  useEffect(() => {
    if (isOpen) {
      if (editScript) {
        setFormData({
          name: editScript.name,
          description: editScript.description || '',
          variety: editScript.variety,
          data: editScript.data || '',
          enabled: editScript.enabled,
          public: editScript.public
        });
      } else {
        setFormData({
          name: '',
          description: '',
          variety: 'custom',
          data: '#!/bin/bash\n\n# Script content here\n',
          enabled: true,
          public: false
        });
      }
      setErrors({});
    }
  }, [isOpen, editScript]);

  // FormField reports a value, the checkboxes still report an event; both land
  // here so the clear-the-error behaviour cannot drift between them.
  const setField = (name: string, value: string | boolean) => {
    setFormData(prev => ({ ...prev, [name]: value }));
    if (errors[name]) {
      setErrors(prev => {
        const next = { ...prev };
        delete next[name];
        return next;
      });
    }
  };

  const handleChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>
  ) => {
    const { name, value, type } = e.target;
    setField(name, type === 'checkbox' ? (e.target as HTMLInputElement).checked : value);
  };

  const validateForm = (): boolean => {
    const newErrors: Record<string, string> = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Name must be at least 2 characters';
    }

    if (!formData.variety) {
      newErrors.variety = 'Type is required';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!validateForm()) return;

    setSubmitting(true);

    try {
      let result: SystemNodeScript;

      if (isEditMode && editScript) {
        result = await systemApi.updateScript(editScript.id, formData);
        addNotification({
          type: 'success',
          message: `Script "${result.name}" updated successfully`
        });
      } else {
        result = await systemApi.createScript(formData);
        addNotification({
          type: 'success',
          message: `Script "${result.name}" created successfully`
        });
      }

      onScriptSaved?.(result);
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update script: ${errorMessage}`
          : `Failed to create script: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditMode ? 'Edit Script' : 'Create Script'}
      icon={<FileCode className="w-6 h-6" />}
      maxWidth="2xl"
    >
          <form onSubmit={handleSubmit}>
            <div className="space-y-4">
              {/* Name and Type Row */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <FormField
                  label="Name"
                  id="name"
                  required
                  value={formData.name}
                  onChange={(v) => setField('name', v)}
                  placeholder="e.g., Install Dependencies"
                  error={errors.name}
                />

                <FormField
                  label="Type"
                  id="variety"
                  type="select"
                  required
                  value={formData.variety}
                  onChange={(v) => setField('variety', v)}
                  error={errors.variety}
                  options={[
                    { value: 'build', label: 'Build Script' },
                    { value: 'init', label: 'Init Script' },
                    { value: 'sync', label: 'Sync Script' },
                    { value: 'custom', label: 'Custom Script' },
                  ]}
                />
              </div>

              {/* Description */}
              <FormField
                label="Description"
                id="description"
                type="textarea"
                rows={2}
                value={formData.description}
                onChange={(v) => setField('description', v)}
                placeholder="Script description"
              />

              {/* Script Content */}
              <FormField
                label="Script Content"
                id="data"
                type="textarea"
                rows={15}
                className="font-mono text-sm"
                value={formData.data}
                onChange={(v) => setField('data', v)}
                placeholder="#!/bin/bash&#10;&#10;# Your script here..."
              />

              {/* Checkboxes */}
              <div className="flex flex-col sm:flex-row sm:items-center gap-4">
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="enabled"
                    checked={formData.enabled}
                    onChange={handleChange}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
                  />
                  <span className="text-sm text-theme-primary">Enabled</span>
                </label>

                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="public"
                    checked={formData.public}
                    onChange={handleChange}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
                  />
                  <span className="text-sm text-theme-primary">Public</span>
                </label>
              </div>
            </div>

            <div className="flex justify-end gap-3 mt-4 pt-4 border-t border-theme">
              <Button type="button" variant="outline" onClick={onClose}>
                Cancel
              </Button>
              <Button type="submit" variant="primary" disabled={submitting}>
                {submitting ? (
                  <>
                    <LoadingSpinner size="sm" className="mr-2" />
                    {isEditMode ? 'Updating...' : 'Creating...'}
                  </>
                ) : (
                  isEditMode ? 'Update Script' : 'Create Script'
                )}
              </Button>
            </div>
          </form>
    </Modal>
  );
};

export default ScriptFormModal;
