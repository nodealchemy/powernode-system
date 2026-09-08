import React, { useState, useEffect } from 'react';
import { FileText } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { FormField } from '@/shared/components/ui/FormField';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeTemplate, SystemNodePlatform } from '@system/features/system/types/system.types';

interface CreateTemplateModalProps {
  /** Whether the modal is open */
  isOpen: boolean;
  /** Callback when modal is closed */
  onClose: () => void;
  /** Callback when template is created */
  onTemplateCreated?: (template: SystemNodeTemplate) => void;
  /** Optional default platform ID */
  defaultPlatformId?: string;
  /** Optional template to edit (for edit mode) */
  editTemplate?: SystemNodeTemplate | null;
  /** Optional template to duplicate */
  duplicateFrom?: SystemNodeTemplate | null;
}

/**
 * CreateTemplateModal - Modal for creating or editing node templates
 *
 * Uses platform patterns:
 * - Form validation with error states
 * - Global notifications for success/error
 * - Theme-aware styling
 */
export const CreateTemplateModal: React.FC<CreateTemplateModalProps> = ({
  isOpen,
  onClose,
  onTemplateCreated,
  defaultPlatformId,
  editTemplate,
  duplicateFrom
}) => {
  const { addNotification } = useNotifications();

  // Form state
  const [formData, setFormData] = useState({
    name: '',
    description: '',
    node_platform_id: defaultPlatformId || '',
    admin_user: 'root',
    enabled: true,
    public: false,
    config: {} as Record<string, unknown>
  });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);

  // Platform options
  const [platforms, setPlatforms] = useState<SystemNodePlatform[]>([]);
  const [loadingPlatforms, setLoadingPlatforms] = useState(true);

  // Determine mode
  const isEditMode = !!editTemplate;
  const isDuplicateMode = !!duplicateFrom;

  // Fetch platforms on mount
  useEffect(() => {
    const fetchPlatforms = async () => {
      try {
        const data = await systemApi.getPlatforms();
        setPlatforms(data);
      } catch (error) {
        addNotification({
          type: 'error',
          message: 'Failed to load platforms'
        });
      } finally {
        setLoadingPlatforms(false);
      }
    };

    if (isOpen) {
      fetchPlatforms();
    }
  }, [isOpen, addNotification]);

  // Initialize form when editing or duplicating
  useEffect(() => {
    if (isOpen) {
      if (editTemplate) {
        setFormData({
          name: editTemplate.name,
          description: editTemplate.description || '',
          node_platform_id: editTemplate.node_platform_id || '',
          admin_user: editTemplate.admin_user || 'root',
          enabled: editTemplate.enabled,
          public: editTemplate.public,
          config: editTemplate.config || {}
        });
      } else if (duplicateFrom) {
        setFormData({
          name: `${duplicateFrom.name} (Copy)`,
          description: duplicateFrom.description || '',
          node_platform_id: duplicateFrom.node_platform_id || '',
          admin_user: duplicateFrom.admin_user || 'root',
          enabled: duplicateFrom.enabled,
          public: false, // Default to private for duplicates
          config: duplicateFrom.config || {}
        });
      } else {
        // Reset form for new template
        setFormData({
          name: '',
          description: '',
          node_platform_id: defaultPlatformId || '',
          admin_user: 'root',
          enabled: true,
          public: false,
          config: {}
        });
      }
      setErrors({});
    }
  }, [isOpen, editTemplate, duplicateFrom, defaultPlatformId]);

  // Handle input change
  const handleChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>
  ) => {
    const { name, value, type } = e.target;
    setField(name, type === 'checkbox' ? (e.target as HTMLInputElement).checked : value);
  };

  // FormField reports a value, the checkboxes still report an event; both land
  // here so the clear-the-error behaviour cannot drift between them.
  const setField = (name: string, value: string | boolean) => {
    setFormData(prev => ({ ...prev, [name]: value }));

    // Clear error when field is modified
    if (errors[name]) {
      setErrors(prev => {
        const next = { ...prev };
        delete next[name];
        return next;
      });
    }
  };

  // Validate form
  const validateForm = (): boolean => {
    const newErrors: Record<string, string> = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Name must be at least 2 characters';
    } else if (formData.name.length > 100) {
      newErrors.name = 'Name must be less than 100 characters';
    }

    if (formData.description && formData.description.length > 500) {
      newErrors.description = 'Description must be less than 500 characters';
    }

    if (formData.admin_user && formData.admin_user.length > 50) {
      newErrors.admin_user = 'Admin user must be less than 50 characters';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  // Handle form submission
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!validateForm()) {
      return;
    }

    setSubmitting(true);

    try {
      let result: SystemNodeTemplate;

      if (isEditMode && editTemplate) {
        result = await systemApi.updateTemplate(editTemplate.id, formData);
        addNotification({
          type: 'success',
          message: `Template "${result.name}" updated successfully`
        });
      } else {
        result = await systemApi.createTemplate(formData);
        addNotification({
          type: 'success',
          message: `Template "${result.name}" created successfully`
        });
      }

      onTemplateCreated?.(result);
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update template: ${errorMessage}`
          : `Failed to create template: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditMode ? 'Edit Template' : isDuplicateMode ? 'Duplicate Template' : 'Create Template'}
      icon={<FileText className="w-6 h-6" />}
      maxWidth="lg"
    >
          {/* Form */}
          <form onSubmit={handleSubmit}>
            <div className="space-y-4">
              {/* Name */}
              <FormField
                label="Name"
                id="name"
                required
                value={formData.name}
                onChange={(v) => setField('name', v)}
                placeholder="Enter template name"
                error={errors.name}
              />

              {/* Description */}
              <FormField
                label="Description"
                id="description"
                type="textarea"
                rows={3}
                value={formData.description}
                onChange={(v) => setField('description', v)}
                placeholder="Enter template description"
                error={errors.description}
              />

              {/* Platform */}
              {loadingPlatforms ? (
                <div>
                  <label className="block text-sm font-medium text-theme-primary mb-1">
                    Platform
                  </label>
                  <div className="flex items-center justify-center py-2">
                    <LoadingSpinner size="sm" />
                  </div>
                </div>
              ) : (
                <FormField
                  label="Platform"
                  id="node_platform_id"
                  type="select"
                  value={formData.node_platform_id}
                  onChange={(v) => setField('node_platform_id', v)}
                  options={[
                    { value: '', label: 'Select a platform (optional)' },
                    ...platforms.map((platform) => ({
                      value: platform.id,
                      label: platform.name,
                    })),
                  ]}
                />
              )}

              {/* Admin User */}
              <FormField
                label="Admin User"
                id="admin_user"
                value={formData.admin_user}
                onChange={(v) => setField('admin_user', v)}
                placeholder="e.g., root"
                error={errors.admin_user}
              />

              {/* Checkboxes */}
              <div className="flex flex-col sm:flex-row sm:items-center gap-4">
                {/* Enabled */}
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

                {/* Public */}
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="public"
                    checked={formData.public}
                    onChange={handleChange}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
                  />
                  <span className="text-sm text-theme-primary">Public (visible to all accounts)</span>
                </label>
              </div>
            </div>

            {/* Footer */}
            <div className="flex justify-end gap-3 p-4 border-t border-theme">
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
                  isEditMode ? 'Update Template' : 'Create Template'
                )}
              </Button>
            </div>
          </form>
    </Modal>
  );
};

export default CreateTemplateModal;
