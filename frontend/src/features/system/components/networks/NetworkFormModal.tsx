import React, { useState, useEffect } from 'react';
import { Network } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { FormField } from '@/shared/components/ui/FormField';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProviderNetwork, SystemProviderRegion } from '@system/features/system/types/system.types';

interface NetworkFormModalProps {
  /** Network to edit (null for create mode) */
  network: SystemProviderNetwork | null;
  /** Whether the modal is open */
  isOpen: boolean;
  /** Callback when modal is closed */
  onClose: () => void;
  /** Callback when network is saved */
  onNetworkSaved?: (network: SystemProviderNetwork) => void;
}

interface FormData {
  name: string;
  description: string;
  provider_region_id: string;
  cidr_block: string;
  is_default: boolean;
  dns_support: boolean;
  dns_hostnames: boolean;
}

interface FormErrors {
  name?: string;
  cidr_block?: string;
  provider_region_id?: string;
}

// CIDR validation regex
const CIDR_REGEX = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/;

/**
 * NetworkFormModal - Modal for creating/editing networks
 */
export const NetworkFormModal: React.FC<NetworkFormModalProps> = ({
  network,
  isOpen,
  onClose,
  onNetworkSaved
}) => {
  const { addNotification } = useNotifications();
  const isEditMode = !!network;

  // State
  const [submitting, setSubmitting] = useState(false);
  const [regions, setRegions] = useState<SystemProviderRegion[]>([]);
  const [loadingRegions, setLoadingRegions] = useState(true);
  const [formData, setFormData] = useState<FormData>({
    name: '',
    description: '',
    provider_region_id: '',
    cidr_block: '10.0.0.0/16',
    is_default: false,
    dns_support: true,
    dns_hostnames: false
  });
  const [errors, setErrors] = useState<FormErrors>({});

  // Fetch regions
  useEffect(() => {
    const fetchRegions = async () => {
      try {
        const providers = await systemApi.getProviders();
        const allRegions: SystemProviderRegion[] = [];

        for (const provider of providers) {
          const providerRegions = await systemApi.getProviderRegions(provider.id);
          allRegions.push(...providerRegions.map(r => ({
            ...r,
            provider_name: provider.name
          })));
        }

        setRegions(allRegions);
      } catch (error) {
        addNotification({
          type: 'error',
          message: 'Failed to load regions'
        });
      } finally {
        setLoadingRegions(false);
      }
    };

    if (isOpen) {
      fetchRegions();
    }
  }, [isOpen, addNotification]);

  // Initialize form
  useEffect(() => {
    if (isOpen) {
      if (network) {
        setFormData({
          name: network.name,
          description: network.description || '',
          provider_region_id: network.provider_region_id || '',
          cidr_block: network.cidr_block || '',
          is_default: network.is_default ?? false,
          dns_support: network.dns_support ?? true,
          dns_hostnames: network.dns_hostnames ?? false
        });
      } else {
        setFormData({
          name: '',
          description: '',
          provider_region_id: '',
          cidr_block: '10.0.0.0/16',
          is_default: false,
          dns_support: true,
          dns_hostnames: false
        });
      }
      setErrors({});
    }
  }, [isOpen, network]);

  // Validate form
  const validate = (): boolean => {
    const newErrors: FormErrors = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Name must be at least 2 characters';
    }

    if (!formData.provider_region_id) {
      newErrors.provider_region_id = 'Region is required';
    }

    if (!formData.cidr_block) {
      newErrors.cidr_block = 'CIDR block is required';
    } else if (!CIDR_REGEX.test(formData.cidr_block)) {
      newErrors.cidr_block = 'Invalid CIDR format (e.g., 10.0.0.0/16)';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  // Handle field change
  const handleChange = (field: keyof FormData, value: string | boolean) => {
    setFormData(prev => ({ ...prev, [field]: value }));
    if (errors[field as keyof FormErrors]) {
      setErrors(prev => ({ ...prev, [field]: undefined }));
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
      let savedNetwork: SystemProviderNetwork;

      const payload = {
        name: formData.name.trim(),
        description: formData.description.trim() || undefined,
        provider_region_id: formData.provider_region_id,
        cidr_block: formData.cidr_block,
        is_default: formData.is_default,
        dns_support: formData.dns_support,
        dns_hostnames: formData.dns_hostnames
      };

      if (isEditMode && network) {
        savedNetwork = await systemApi.updateNetwork(network.id, payload);
        addNotification({
          type: 'success',
          message: `Network "${savedNetwork.name}" updated successfully`
        });
      } else {
        savedNetwork = await systemApi.createNetwork(payload);
        addNotification({
          type: 'success',
          message: `Network "${savedNetwork.name}" created successfully`
        });
      }

      onNetworkSaved?.(savedNetwork);
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update network: ${errorMessage}`
          : `Failed to create network: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditMode ? 'Edit Network' : 'Create Network'}
      icon={<Network className="w-6 h-6" />}
      maxWidth="lg"
    >
          {/* Form */}
          <form onSubmit={handleSubmit}>
            <div className="space-y-4">
              {/* Name */}
              <FormField
                label="Name"
                required
                disabled={submitting}
                value={formData.name}
                onChange={(v) => handleChange('name', v)}
                placeholder="Enter network name"
                error={errors.name}
              />

              {/* Description */}
              <FormField
                label="Description"
                type="textarea"
                rows={2}
                disabled={submitting}
                value={formData.description}
                onChange={(v) => handleChange('description', v)}
                placeholder="Optional description"
              />

              {/* Region */}
              {loadingRegions ? (
                <div>
                  <label className="block text-sm font-medium text-theme-primary mb-1">
                    Region <span className="text-theme-error-fg">*</span>
                  </label>
                  <div className="flex items-center justify-center py-2">
                    <LoadingSpinner size="sm" />
                  </div>
                </div>
              ) : (
                <FormField
                  label="Region"
                  type="select"
                  required
                  disabled={submitting || isEditMode}
                  value={formData.provider_region_id}
                  onChange={(v) => handleChange('provider_region_id', v)}
                  error={errors.provider_region_id}
                  options={[
                    { value: '', label: 'Select a region' },
                    ...regions.map((region) => {
                      const providerName = (region as SystemProviderRegion & { provider_name?: string })
                        .provider_name;
                      return {
                        value: region.id,
                        label: `${providerName ? `${providerName} - ` : ''}${region.name} (${region.region_code})`,
                      };
                    }),
                  ]}
                />
              )}

              {/* CIDR Block */}
              <FormField
                label="CIDR Block"
                required
                className="font-mono"
                disabled={submitting || isEditMode}
                value={formData.cidr_block}
                onChange={(v) => handleChange('cidr_block', v)}
                placeholder="e.g., 10.0.0.0/16"
                error={errors.cidr_block}
                helpText="IPv4 network range in CIDR notation"
              />

              {/* Options */}
              <div className="space-y-3 pt-2">
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={formData.dns_support}
                    onChange={(e) => handleChange('dns_support', e.target.checked)}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
                    disabled={submitting}
                  />
                  <span className="text-sm text-theme-primary">Enable DNS resolution</span>
                </label>

                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={formData.dns_hostnames}
                    onChange={(e) => handleChange('dns_hostnames', e.target.checked)}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
                    disabled={submitting}
                  />
                  <span className="text-sm text-theme-primary">Enable DNS hostnames</span>
                </label>

                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={formData.is_default}
                    onChange={(e) => handleChange('is_default', e.target.checked)}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
                    disabled={submitting}
                  />
                  <span className="text-sm text-theme-primary">Set as default network</span>
                </label>
              </div>
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
                  isEditMode ? 'Update Network' : 'Create Network'
                )}
              </Button>
            </div>
          </form>
    </Modal>
  );
};

export default NetworkFormModal;
