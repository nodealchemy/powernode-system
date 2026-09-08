import React, { useState, useEffect } from 'react';
import { Network } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { FormField } from '@/shared/components/ui/FormField';
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

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <span className="flex items-center gap-3">
          {isEditMode ? 'Edit Subnet' : 'Add Subnet'}
          {manualOverride && (
            <Badge variant="warning" size="xs">Manual override</Badge>
          )}
        </span>
      }
      icon={<Network className="w-6 h-6" />}
      maxWidth="lg"
    >
          <form onSubmit={handleSubmit}>
            <div className="space-y-4">
              {manualOverride && (
                <p className="text-xs text-theme-warning-fg bg-theme-background rounded-lg p-3 border border-theme">
                  This network&apos;s provider has a cloud connection, so its subnets are
                  normally populated by Sync catalog. A hand-written entry is a manual
                  override and a later sync may reconcile it.
                </p>
              )}

              <FormField
                label="Name"
                id="subnet-name"
                required
                disabled={submitting}
                value={formData.name}
                onChange={(v) => handleChange('name', v)}
                placeholder="Enter subnet name"
                error={errors.name}
              />

              <FormField
                label="CIDR Block"
                id="subnet-cidr"
                required
                className="font-mono"
                disabled={submitting}
                value={formData.cidr_block}
                onChange={(v) => handleChange('cidr_block', v)}
                placeholder="e.g., 10.0.1.0/24"
                error={errors.cidr_block}
              />

              <FormField
                label="Status"
                id="subnet-status"
                type="select"
                disabled={submitting}
                value={formData.status}
                onChange={(v) => handleChange('status', v)}
                options={STATUS_OPTIONS.map((option) => ({ value: option, label: option }))}
              />

              <FormField
                label="Description"
                id="subnet-description"
                type="textarea"
                rows={2}
                disabled={submitting}
                value={formData.description}
                onChange={(v) => handleChange('description', v)}
                placeholder="Optional description"
              />

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
    </Modal>
  );
};

export default SubnetFormModal;
