import React, { useState, useEffect } from 'react';
import { Server, CheckCircle, XCircle, RefreshCw } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderConnection } from '@system/features/system/types/system.types';

interface ConnectionFormModalProps {
  /** Provider ID for this connection */
  providerId: string;
  /** Connection to edit (null for create mode) */
  connection: SystemProviderConnection | null;
  /** Whether the modal is open */
  isOpen: boolean;
  /** Callback when modal is closed */
  onClose: () => void;
  /** Callback when connection is saved */
  onConnectionSaved?: () => void;
}

interface FormData {
  name: string;
  description: string;
  endpoint_url: string;
  access_key: string;
  secret_key: string;
  tenant: string;
}

interface FormErrors {
  name?: string;
  access_key?: string;
  secret_key?: string;
}

type TestStatus = 'idle' | 'testing' | 'success' | 'error';

/**
 * ConnectionFormModal - Modal for creating/editing provider connections with test functionality
 */
export const ConnectionFormModal: React.FC<ConnectionFormModalProps> = ({
  providerId,
  connection,
  isOpen,
  onClose,
  onConnectionSaved
}) => {
  const { addNotification } = useNotifications();
  const isEditMode = !!connection;

  // State
  const [submitting, setSubmitting] = useState(false);
  const [testStatus, setTestStatus] = useState<TestStatus>('idle');
  const [testMessage, setTestMessage] = useState('');
  const [formData, setFormData] = useState<FormData>({
    name: '',
    description: '',
    endpoint_url: '',
    access_key: '',
    secret_key: '',
    tenant: ''
  });
  const [errors, setErrors] = useState<FormErrors>({});

  // Initialize form
  useEffect(() => {
    if (isOpen) {
      if (connection) {
        setFormData({
          name: connection.name,
          description: connection.description || '',
          endpoint_url: connection.endpoint_url || '',
          access_key: '', // Don't pre-fill credentials for security
          secret_key: '',
          tenant: ''
        });
      } else {
        setFormData({
          name: '',
          description: '',
          endpoint_url: '',
          access_key: '',
          secret_key: '',
          tenant: ''
        });
      }
      setErrors({});
      setTestStatus('idle');
      setTestMessage('');
    }
  }, [isOpen, connection]);

  // Validate form
  const validate = (): boolean => {
    const newErrors: FormErrors = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Name must be at least 2 characters';
    }

    // For create mode, credentials are required
    // For edit mode, they're optional (keep existing if not provided)
    if (!isEditMode) {
      if (!formData.access_key.trim()) {
        newErrors.access_key = 'Access key is required';
      }
      if (!formData.secret_key.trim()) {
        newErrors.secret_key = 'Secret key is required';
      }
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  // Handle field change
  const handleChange = (field: keyof FormData, value: string) => {
    setFormData(prev => ({ ...prev, [field]: value }));
    if (errors[field as keyof FormErrors]) {
      setErrors(prev => ({ ...prev, [field]: undefined }));
    }
    // Reset test status when form changes
    if (testStatus !== 'idle') {
      setTestStatus('idle');
      setTestMessage('');
    }
  };

  // Test connection
  const handleTest = async () => {
    if (!formData.access_key || !formData.secret_key) {
      addNotification({
        type: 'warning',
        message: 'Please enter credentials to test the connection'
      });
      return;
    }

    setTestStatus('testing');
    setTestMessage('');

    try {
      // For existing connections, use the API test endpoint
      // For new connections, we'd need a test-before-save endpoint
      if (isEditMode && connection) {
        const result = await systemApi.testProviderConnection(connection.id);
        if (result.success) {
          setTestStatus('success');
          setTestMessage(result.message || 'Connection successful');
        } else {
          setTestStatus('error');
          setTestMessage(result.message || 'Connection failed');
        }
      } else {
        // For new connections, we simulate a test (actual implementation would need backend support)
        addNotification({
          type: 'info',
          message: 'Save the connection first, then test it from the connections list'
        });
        setTestStatus('idle');
      }
    } catch (error) {
      setTestStatus('error');
      setTestMessage(error instanceof Error ? error.message : 'Connection test failed');
    }
  };

  // Handle submit
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!validate()) {
      return;
    }

    setSubmitting(true);

    try {
      const payload: Record<string, unknown> = {
        name: formData.name.trim(),
        description: formData.description.trim() || undefined,
        endpoint_url: formData.endpoint_url.trim() || undefined,
        provider_id: providerId,
        config: {}
      };

      // Only include credentials if provided
      if (formData.access_key.trim()) {
        payload.access_key = formData.access_key.trim();
      }
      if (formData.secret_key.trim()) {
        payload.secret_key = formData.secret_key.trim();
      }
      if (formData.tenant.trim()) {
        payload.tenant = formData.tenant.trim();
      }

      if (isEditMode && connection) {
        await systemApi.updateProviderConnection(connection.id, payload);
        addNotification({
          type: 'success',
          message: `Connection "${payload.name}" updated successfully`
        });
      } else {
        await systemApi.createProviderConnection(payload as unknown as Parameters<typeof systemApi.createProviderConnection>[0]);
        addNotification({
          type: 'success',
          message: `Connection "${payload.name}" created successfully`
        });
      }

      onConnectionSaved?.();
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update connection: ${errorMessage}`
          : `Failed to create connection: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditMode ? 'Edit Connection' : 'Add Connection'}
      icon={<Server className="w-6 h-6" />}
      maxWidth="lg"
    >

          {/* Form */}
          <form onSubmit={handleSubmit}>
            <div className="space-y-4">
              {/* Name */}
              <FormField
                label="Name"
                required
                value={formData.name}
                onChange={(v) => handleChange('name', v)}
                placeholder="Enter connection name"
                error={errors.name}
                disabled={submitting}
              />

              {/* Description */}
              <FormField
                label="Description"
                type="textarea"
                rows={2}
                value={formData.description}
                onChange={(v) => handleChange('description', v)}
                placeholder="Optional description"
                disabled={submitting}
              />

              {/* Endpoint URL */}
              <FormField
                label="Endpoint URL"
                type="url"
                value={formData.endpoint_url}
                onChange={(v) => handleChange('endpoint_url', v)}
                placeholder="https://api.provider.com"
                className="font-mono"
                disabled={submitting}
              />

              {/* Credentials Section */}
              <div className="pt-4 border-t border-theme">
                <h4 className="text-sm font-medium text-theme-primary mb-3">Credentials</h4>

                {/* Access Key */}
                <div className="mb-4">
                  <FormField
                    label="Access Key"
                    required={!isEditMode}
                    value={formData.access_key}
                    onChange={(v) => handleChange('access_key', v)}
                    placeholder={isEditMode ? "Leave empty to keep existing" : "Enter access key"}
                    className="font-mono"
                    error={errors.access_key}
                    disabled={submitting}
                  />
                </div>

                {/* Secret Key */}
                <div className="mb-4">
                  {/* No reveal toggle: this field held a masked secret before this
                      refactor and still does. Adding one would be a change to how
                      a credential is handled, not a change of styling. */}
                  <FormField
                    label="Secret Key"
                    type="password"
                    showPasswordToggle={false}
                    required={!isEditMode}
                    value={formData.secret_key}
                    onChange={(v) => handleChange('secret_key', v)}
                    placeholder={isEditMode ? "Leave empty to keep existing" : "Enter secret key"}
                    className="font-mono"
                    error={errors.secret_key}
                    disabled={submitting}
                  />
                </div>

                {/* Tenant (optional) */}
                <FormField
                  label="Tenant / Project ID"
                  value={formData.tenant}
                  onChange={(v) => handleChange('tenant', v)}
                  placeholder="Optional tenant or project ID"
                  className="font-mono"
                  disabled={submitting}
                />
              </div>

              {/* Test Connection */}
              {isEditMode && (
                <div className="pt-4 border-t border-theme">
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-2">
                      <span className="text-sm font-medium text-theme-primary">Test Connection</span>
                      {testStatus === 'success' && (
                        <Badge variant="success" size="sm">
                          <CheckCircle className="w-3 h-3 mr-1" />
                          Success
                        </Badge>
                      )}
                      {testStatus === 'error' && (
                        <Badge variant="danger" size="sm">
                          <XCircle className="w-3 h-3 mr-1" />
                          Failed
                        </Badge>
                      )}
                    </div>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={handleTest}
                      disabled={testStatus === 'testing' || submitting}
                    >
                      {testStatus === 'testing' ? (
                        <>
                          <RefreshCw className="w-4 h-4 mr-2 animate-spin" />
                          Testing...
                        </>
                      ) : (
                        <>
                          <RefreshCw className="w-4 h-4 mr-2" />
                          Test
                        </>
                      )}
                    </Button>
                  </div>
                  {testMessage && (
                    <p className={`mt-2 text-sm ${testStatus === 'success' ? 'text-theme-success-fg' : 'text-theme-error-fg'}`}>
                      {testMessage}
                    </p>
                  )}
                </div>
              )}
            </div>

            {/* Footer */}
            <div className="flex justify-end gap-3 p-4 border-t border-theme">
              <Button type="button" variant="outline" onClick={onClose} disabled={submitting}>
                Cancel
              </Button>
              <Button type="submit" variant="primary" disabled={submitting}>
                {submitting ? (
                  <>
                    <LoadingSpinner size="sm" className="mr-2" />
                    {isEditMode ? 'Updating...' : 'Creating...'}
                  </>
                ) : (
                  isEditMode ? 'Update Connection' : 'Add Connection'
                )}
              </Button>
            </div>
          </form>
    </Modal>
  );
};

export default ConnectionFormModal;
