import React, { useState, useEffect } from 'react';
import { X, Network, AlertCircle } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderNetworkSubnet } from '@system/features/system/types/system.types';

interface SubnetFormModalProps {
  /** Network this subnet belongs to */
  networkId: string;
  /** Subnet to edit (null for create mode) */
  subnet: SystemProviderNetworkSubnet | null;
  isOpen: boolean;
  onClose: () => void;
  onSaved?: () => void;
  /** Set when the owning provider has a cloud connection. */
  manualOverride?: boolean;
}

interface FormData {
  name: string;
  cidr_block: string;
  description: string;
  status: string;
  is_public: boolean;
  enabled: boolean;
}

interface FormErrors {
  name?: string;
  cidr_block?: string;
}

const EMPTY: FormData = {
  name: '',
  cidr_block: '',
  description: '',
  status: 'available',
  is_public: false,
  enabled: true
};

const STATUS_OPTIONS = ['available', 'pending', 'deleting', 'deleted', 'error'];

// IPv4 CIDR only — the backend column and every provider adapter in the tree
// speak IPv4 here. Deliberately a shape check, not a range check: the server is
// the authority on whether the block fits its network.
const CIDR_PATTERN = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/;

/**
 * SubnetFormModal - create/edit a subnet under a provider network. Matches
 * `provider_networks/:network_id/provider_network_subnets`.
 */
export const SubnetFormModal: React.FC<SubnetFormModalProps> = ({
  networkId,
  subnet,
  isOpen,
  onClose,
  onSaved,
  manualOverride = false
}) => {
  const { addNotification } = useNotifications();
  const isEditMode = !!subnet;

  const [submitting, setSubmitting] = useState(false);
  const [formData, setFormData] = useState<FormData>(EMPTY);
  const [errors, setErrors] = useState<FormErrors>({});

  useEffect(() => {
    if (!isOpen) return;
    if (subnet) {
      setFormData({
        name: subnet.name,
        cidr_block: subnet.cidr_block || '',
        description: subnet.description || '',
        status: subnet.status || 'available',
        is_public: subnet.is_public,
        enabled: subnet.enabled
      });
    } else {
      setFormData(EMPTY);
    }
    setErrors({});
  }, [isOpen, subnet]);

  const validate = (): boolean => {
    const newErrors: FormErrors = {};
    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    }
    const cidr = formData.cidr_block.trim();
    if (!cidr) {
      newErrors.cidr_block = 'CIDR block is required';
    } else if (!CIDR_PATTERN.test(cidr)) {
      newErrors.cidr_block = 'CIDR block must look like 10.0.1.0/24';
    }
    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleChange = (field: keyof FormData, value: string | boolean) => {
    setFormData(prev => ({ ...prev, [field]: value }));
    if (errors[field as keyof FormErrors]) {
      setErrors(prev => ({ ...prev, [field]: undefined }));
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validate()) return;

    setSubmitting(true);
    try {
      const payload = {
        name: formData.name.trim(),
        cidr_block: formData.cidr_block.trim(),
        // On update a dropped key leaves the column untouched, so a blanked
        // description must be sent as an explicit null to clear it.
        description: formData.description.trim() || (isEditMode ? null : undefined),
        status: formData.status,
        is_public: formData.is_public,
        enabled: formData.enabled
      };

      if (isEditMode && subnet) {
        await systemApi.updateNetworkSubnet(networkId, subnet.id, payload);
        addNotification({
          type: 'success',
          message: `Subnet "${payload.name}" updated successfully`
        });
      } else {
        await systemApi.createNetworkSubnet(networkId, payload);
        addNotification({
          type: 'success',
          message: `Subnet "${payload.name}" created successfully`
        });
      }

      onSaved?.();
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update subnet: ${errorMessage}`
          : `Failed to create subnet: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-[60] overflow-y-auto">
      <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={onClose} />

      <div className="flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-lg bg-theme-surface rounded-lg shadow-xl">
          <div className="flex items-center justify-between p-4 border-b border-theme">
            <div className="flex items-center gap-3">
              <Network className="w-6 h-6 text-theme-info-fg" />
              <h2 className="text-lg font-semibold text-theme-primary">
                {isEditMode ? 'Edit Subnet' : 'Add Subnet'}
              </h2>
              {manualOverride && (
                <Badge variant="warning" size="xs">Manual override</Badge>
              )}
            </div>
            <Button variant="ghost" size="sm" onClick={onClose}>
              <X className="w-5 h-5" />
            </Button>
          </div>

          <form onSubmit={handleSubmit}>
            <div className="p-4 space-y-4 max-h-[60vh] overflow-y-auto">
              {manualOverride && (
                <p className="text-xs text-theme-warning-fg bg-theme-background rounded-lg p-3 border border-theme">
                  This network&apos;s provider has a cloud connection, so its subnets are
                  normally populated by Sync catalog. A hand-written entry is a manual
                  override and a later sync may reconcile it.
                </p>
              )}

              <div>
                <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor="subnet-name">
                  Name <span className="text-theme-error-fg">*</span>
                </label>
                <input
                  id="subnet-name"
                  type="text"
                  value={formData.name}
                  onChange={(e) => handleChange('name', e.target.value)}
                  placeholder="Enter subnet name"
                  className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
                    errors.name ? 'border-theme-error-border' : 'border-theme'
                  }`}
                  disabled={submitting}
                />
                {errors.name && (
                  <p className="mt-1 text-sm text-theme-error-fg flex items-center gap-1">
                    <AlertCircle className="w-4 h-4" />
                    {errors.name}
                  </p>
                )}
              </div>

              <div>
                <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor="subnet-cidr">
                  CIDR Block <span className="text-theme-error-fg">*</span>
                </label>
                <input
                  id="subnet-cidr"
                  type="text"
                  value={formData.cidr_block}
                  onChange={(e) => handleChange('cidr_block', e.target.value)}
                  placeholder="e.g., 10.0.1.0/24"
                  className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary font-mono placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
                    errors.cidr_block ? 'border-theme-error-border' : 'border-theme'
                  }`}
                  disabled={submitting}
                />
                {errors.cidr_block && (
                  <p className="mt-1 text-sm text-theme-error-fg flex items-center gap-1">
                    <AlertCircle className="w-4 h-4" />
                    {errors.cidr_block}
                  </p>
                )}
              </div>

              <div>
                <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor="subnet-status">
                  Status
                </label>
                <select
                  id="subnet-status"
                  value={formData.status}
                  onChange={(e) => handleChange('status', e.target.value)}
                  className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus"
                  disabled={submitting}
                >
                  {STATUS_OPTIONS.map(option => (
                    <option key={option} value={option}>{option}</option>
                  ))}
                </select>
              </div>

              <div>
                <label className="block text-sm font-medium text-theme-primary mb-1" htmlFor="subnet-description">
                  Description
                </label>
                <textarea
                  id="subnet-description"
                  value={formData.description}
                  onChange={(e) => handleChange('description', e.target.value)}
                  placeholder="Optional description"
                  rows={2}
                  className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus resize-none"
                  disabled={submitting}
                />
              </div>

              <label className="flex items-center gap-2 text-sm text-theme-primary">
                <input
                  type="checkbox"
                  checked={formData.is_public}
                  onChange={(e) => handleChange('is_public', e.target.checked)}
                  disabled={submitting}
                />
                Public subnet
              </label>

              <label className="flex items-center gap-2 text-sm text-theme-primary">
                <input
                  type="checkbox"
                  checked={formData.enabled}
                  onChange={(e) => handleChange('enabled', e.target.checked)}
                  disabled={submitting}
                />
                Enabled
              </label>
            </div>

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
                  isEditMode ? 'Update Subnet' : 'Add Subnet'
                )}
              </Button>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
};

export default SubnetFormModal;
