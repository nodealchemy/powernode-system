import React, { useMemo, useState, useEffect } from 'react';
import { X, Cloud, AlertCircle, KeyRound, CheckCircle2 } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { apiClient } from '@/shared/services/apiClient';
import { logger } from '@/shared/utils/logger';
import {
  PROVIDER_FIELD_SCHEMAS,
  ProviderCredentialForm,
  type CredentialTestStatus,
  type ProviderTypeSlug,
  type ProviderCredentialValues,
} from '@/features/onboarding/ProviderCredentialForm';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProvider } from '@system/features/system/types/system.types';

type TabKey = 'general' | 'credentials';

/**
 * Map a SystemProvider.provider_type slug to the BYOC credential schema
 * shipped with the FirstRunWizard. Returns `null` for provider types that
 * don't yet have a credential schema (e.g. `openstack`, `custom`) so the
 * Credentials tab can render a graceful explainer instead.
 */
const toOnboardingType = (providerType: string | undefined): ProviderTypeSlug | null => {
  if (!providerType) return null;
  const slug = providerType.toLowerCase();
  // PROVIDER_FIELD_SCHEMAS is keyed by category first (ai/cloud/git). The
  // ProviderFormModal lives in the system extension and only handles cloud
  // providers, so we look up under the cloud bucket.
  if (slug in PROVIDER_FIELD_SCHEMAS.cloud) return slug;
  return null;
};

interface ProviderFormModalProps {
  isOpen: boolean;
  onClose: () => void;
  onProviderSaved?: (provider: SystemProvider) => void;
  editProvider?: SystemProvider | null;
}

const providerTypes = [
  { value: 'aws', label: 'Amazon Web Services' },
  { value: 'openstack', label: 'OpenStack' },
  { value: 'gcp', label: 'Google Cloud Platform' },
  { value: 'azure', label: 'Microsoft Azure' },
  { value: 'digitalocean', label: 'DigitalOcean' },
  { value: 'local_qemu', label: 'Local QEMU/KVM (libvirt)' },
  { value: 'custom', label: 'Custom Provider' }
];

/**
 * ProviderFormModal - Modal for creating or editing providers
 */
export const ProviderFormModal: React.FC<ProviderFormModalProps> = ({
  isOpen,
  onClose,
  onProviderSaved,
  editProvider
}) => {
  const { addNotification } = useNotifications();

  const [formData, setFormData] = useState({
    name: '',
    description: '',
    provider_type: 'aws',
    enabled: true,
    public: false,
    config: '{}',
    capabilities: '{}',
    // local_qemu-only convenience fields. When the form is submitted these
    // get merged into the parsed `config` JSON so the backend stores them
    // under System::Provider#config["network_mode"] / ["bridge_name"]. The
    // raw Configuration JSON textarea below remains the source of truth
    // for everything else.
    network_mode: '' as '' | 'user' | 'network' | 'bridge' | 'routed',
    bridge_name: '',
  });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);
  const [activeTab, setActiveTab] = useState<TabKey>('general');

  // Credentials tab state — kept in this scope so switching tabs preserves entry.
  const [credentialValues, setCredentialValues] = useState<ProviderCredentialValues>({});
  const [credentialsValid, setCredentialsValid] = useState(false);
  const [testStatus, setTestStatus] = useState<CredentialTestStatus>('idle');
  const [savingCredentials, setSavingCredentials] = useState(false);
  const [credentialSaved, setCredentialSaved] = useState(false);

  const isEditMode = !!editProvider;

  const onboardingType = useMemo(
    () => toOnboardingType(formData.provider_type),
    [formData.provider_type]
  );

  // Reset credentials tab whenever a different provider is being edited so the
  // previous record's keys can't leak into the next save.
  useEffect(() => {
    setCredentialValues({});
    setCredentialsValid(false);
    setTestStatus('idle');
    setCredentialSaved(false);
    setActiveTab('general');
  }, [editProvider?.id]);

  useEffect(() => {
    if (isOpen) {
      if (editProvider) {
        const cfg = (editProvider.config || {}) as Record<string, unknown>;
        const nm = typeof cfg.network_mode === 'string' ? cfg.network_mode : '';
        setFormData({
          name: editProvider.name,
          description: editProvider.description || '',
          provider_type: editProvider.provider_type,
          enabled: editProvider.enabled,
          public: editProvider.public,
          config: JSON.stringify(editProvider.config || {}, null, 2),
          capabilities: JSON.stringify(editProvider.capabilities || {}, null, 2),
          network_mode: (['user', 'network', 'bridge', 'routed'].includes(nm) ? nm : '') as '' | 'user' | 'network' | 'bridge' | 'routed',
          bridge_name: typeof cfg.bridge_name === 'string' ? cfg.bridge_name : '',
        });
      } else {
        setFormData({
          name: '',
          description: '',
          provider_type: 'aws',
          enabled: true,
          public: false,
          config: '{}',
          capabilities: '{}',
          network_mode: '',
          bridge_name: '',
        });
      }
      setErrors({});
    }
  }, [isOpen, editProvider]);

  const handleChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>
  ) => {
    const { name, value, type } = e.target;
    const newValue = type === 'checkbox' ? (e.target as HTMLInputElement).checked : value;
    setFormData(prev => ({ ...prev, [name]: newValue }));
    if (errors[name]) {
      setErrors(prev => {
        const next = { ...prev };
        delete next[name];
        return next;
      });
    }
  };

  const validateJson = (value: string, fieldName: string): boolean => {
    try {
      JSON.parse(value);
      return true;
    } catch {
      setErrors(prev => ({ ...prev, [fieldName]: 'Invalid JSON format' }));
      return false;
    }
  };

  const validateForm = (): boolean => {
    const newErrors: Record<string, string> = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Name must be at least 2 characters';
    }

    if (!formData.provider_type) {
      newErrors.provider_type = 'Provider type is required';
    }

    // Validate JSON fields
    let jsonValid = true;
    if (!validateJson(formData.config, 'config')) jsonValid = false;
    if (!validateJson(formData.capabilities, 'capabilities')) jsonValid = false;

    if (!jsonValid) {
      return false;
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!validateForm()) return;

    setSubmitting(true);

    try {
      // Merge the local_qemu convenience fields back into config. Only sets
      // them when explicitly chosen (non-empty) so AWS/Azure/GCP submissions
      // don't gain spurious keys.
      const parsedConfig = JSON.parse(formData.config) as Record<string, unknown>;
      if (formData.provider_type === 'local_qemu') {
        if (formData.network_mode) {
          parsedConfig.network_mode = formData.network_mode;
        } else {
          delete parsedConfig.network_mode;
        }
        if ((formData.network_mode === 'bridge' || formData.network_mode === 'routed') && formData.bridge_name.trim()) {
          parsedConfig.bridge_name = formData.bridge_name.trim();
        } else {
          delete parsedConfig.bridge_name;
        }
      }

      const submitData = {
        name: formData.name,
        description: formData.description || undefined,
        provider_type: formData.provider_type,
        enabled: formData.enabled,
        public: formData.public,
        config: parsedConfig,
        capabilities: JSON.parse(formData.capabilities)
      };

      let result: SystemProvider;

      if (isEditMode && editProvider) {
        result = await systemApi.updateProvider(editProvider.id, submitData);
        addNotification({
          type: 'success',
          message: `Provider "${result.name}" updated successfully`
        });
      } else {
        result = await systemApi.createProvider(submitData);
        addNotification({
          type: 'success',
          message: `Provider "${result.name}" created successfully`
        });
      }

      onProviderSaved?.(result);
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: isEditMode
          ? `Failed to update provider: ${errorMessage}`
          : `Failed to create provider: ${errorMessage}`
      });
    } finally {
      setSubmitting(false);
    }
  };

  const handleSaveCredentials = async () => {
    if (!editProvider) return;
    if (!credentialsValid) return;
    setSavingCredentials(true);
    try {
      await apiClient.post('/system/provider_credentials', {
        provider_id: editProvider.id,
        provider_type: editProvider.provider_type,
        credentials: credentialValues,
      });
      setCredentialSaved(true);
      addNotification({
        type: 'success',
        message: `Credentials saved for ${editProvider.name}`,
      });
    } catch (error) {
      logger.error('ProviderFormModal: failed to save credentials', error, {
        providerId: editProvider.id,
      });
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: `Failed to save credentials: ${errorMessage}`,
      });
    } finally {
      setSavingCredentials(false);
    }
  };

  if (!isOpen) return null;

  // Credentials tab is only meaningful once the provider record exists (we need
  // its UUID to associate the credential record). For new providers we still
  // show the tab disabled with a hint, so operators discover it after save.
  const credentialsTabAvailable = isEditMode;

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto">
      <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={onClose} />

      <div className="flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-2xl bg-theme-surface rounded-lg shadow-xl">
          <div className="flex items-center justify-between p-4 border-b border-theme">
            <div className="flex items-center gap-3">
              <Cloud className="w-6 h-6 text-theme-accent" />
              <h2 className="text-lg font-semibold text-theme-primary">
                {isEditMode ? 'Edit Provider' : 'Add Provider'}
              </h2>
            </div>
            <Button variant="ghost" size="sm" onClick={onClose}>
              <X className="w-5 h-5" />
            </Button>
          </div>

          {/* Tab strip */}
          <div className="flex items-center gap-1 border-b border-theme px-4" role="tablist">
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === 'general'}
              onClick={() => setActiveTab('general')}
              data-testid="provider-form-tab-general"
              className={`flex items-center gap-1.5 border-b-2 px-3 py-2 text-sm font-medium transition-colors ${
                activeTab === 'general'
                  ? 'border-theme-interactive-primary text-theme-interactive-primary'
                  : 'border-transparent text-theme-secondary hover:text-theme-primary'
              }`}
            >
              <Cloud className="h-4 w-4" />
              General
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === 'credentials'}
              onClick={() => credentialsTabAvailable && setActiveTab('credentials')}
              disabled={!credentialsTabAvailable}
              data-testid="provider-form-tab-credentials"
              title={
                credentialsTabAvailable
                  ? 'Manage cloud credentials for this provider'
                  : 'Save the provider first to add credentials'
              }
              className={`flex items-center gap-1.5 border-b-2 px-3 py-2 text-sm font-medium transition-colors ${
                activeTab === 'credentials'
                  ? 'border-theme-interactive-primary text-theme-interactive-primary'
                  : 'border-transparent text-theme-secondary hover:text-theme-primary'
              } ${credentialsTabAvailable ? '' : 'cursor-not-allowed opacity-50'}`}
            >
              <KeyRound className="h-4 w-4" />
              Credentials
            </button>
          </div>

          {activeTab === 'credentials' && credentialsTabAvailable && editProvider ? (
            <div
              className="p-4 space-y-4 max-h-[70vh] overflow-y-auto"
              data-testid="provider-form-credentials-panel"
            >
              {onboardingType ? (
                <>
                  <ProviderCredentialForm
                    category="cloud"
                    providerType={onboardingType}
                    providerId={editProvider.id}
                    onChange={(values, valid) => {
                      setCredentialValues(values);
                      setCredentialsValid(valid);
                      if (credentialSaved) setCredentialSaved(false);
                    }}
                    onTestStatusChange={setTestStatus}
                  />
                  <div className="flex flex-wrap items-center gap-3 border-t border-theme pt-3">
                    <Button
                      type="button"
                      variant="primary"
                      size="sm"
                      onClick={handleSaveCredentials}
                      disabled={
                        !credentialsValid ||
                        savingCredentials ||
                        (onboardingType !== 'localqemu' && testStatus !== 'valid')
                      }
                      data-testid="provider-form-save-credentials-btn"
                    >
                      {savingCredentials ? (
                        <>
                          <LoadingSpinner size="sm" className="mr-2" />
                          Saving…
                        </>
                      ) : credentialSaved ? (
                        'Saved'
                      ) : (
                        'Save credentials'
                      )}
                    </Button>
                    {credentialSaved && (
                      <span className="flex items-center gap-1 text-xs text-theme-success">
                        <CheckCircle2 className="h-4 w-4" />
                        Credentials encrypted and stored.
                      </span>
                    )}
                  </div>
                </>
              ) : (
                <div className="rounded-lg border border-theme bg-theme-warning/10 p-4 text-sm text-theme-secondary">
                  <p className="font-medium text-theme-primary">
                    No credential schema for {formData.provider_type}.
                  </p>
                  <p className="mt-1 text-xs">
                    The BYOC credential entry form supports AWS, Hetzner, DigitalOcean, Vultr,
                    GCP, Azure, and LocalQemu. For other provider types, use the legacy
                    Configuration JSON on the General tab.
                  </p>
                </div>
              )}
              <div className="flex justify-end pt-2 border-t border-theme">
                <Button type="button" variant="outline" onClick={onClose}>
                  Close
                </Button>
              </div>
            </div>
          ) : (
          <form onSubmit={handleSubmit}>
            <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
              {/* Name and Type */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div>
                  <label htmlFor="name" className="block text-sm font-medium text-theme-primary mb-1">
                    Name <span className="text-theme-error">*</span>
                  </label>
                  <input
                    type="text"
                    id="name"
                    name="name"
                    value={formData.name}
                    onChange={handleChange}
                    placeholder="e.g., Production AWS"
                    className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
                      errors.name ? 'border-theme-error' : 'border-theme'
                    }`}
                  />
                  {errors.name && (
                    <p className="mt-1 text-sm text-theme-error flex items-center gap-1">
                      <AlertCircle className="w-4 h-4" />
                      {errors.name}
                    </p>
                  )}
                </div>

                <div>
                  <label htmlFor="provider_type" className="block text-sm font-medium text-theme-primary mb-1">
                    Provider Type <span className="text-theme-error">*</span>
                  </label>
                  <select
                    id="provider_type"
                    name="provider_type"
                    value={formData.provider_type}
                    onChange={handleChange}
                    className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus ${
                      errors.provider_type ? 'border-theme-error' : 'border-theme'
                    }`}
                  >
                    {providerTypes.map(type => (
                      <option key={type.value} value={type.value}>
                        {type.label}
                      </option>
                    ))}
                  </select>
                </div>
              </div>

              {/* Description */}
              <div>
                <label htmlFor="description" className="block text-sm font-medium text-theme-primary mb-1">
                  Description
                </label>
                <textarea
                  id="description"
                  name="description"
                  value={formData.description}
                  onChange={handleChange}
                  placeholder="Provider description"
                  rows={2}
                  className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus resize-none"
                />
              </div>

              {/* local_qemu networking — convenience fields that merge into Configuration JSON below */}
              {formData.provider_type === 'local_qemu' && (
                <div className="rounded-md border border-theme bg-theme-background-secondary p-3 space-y-3">
                  <div>
                    <label htmlFor="network_mode" className="block text-sm font-medium text-theme-primary mb-1">
                      Network Mode
                    </label>
                    <select
                      id="network_mode"
                      name="network_mode"
                      value={formData.network_mode}
                      onChange={handleChange}
                      className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus"
                      data-testid="provider-form-network-mode"
                    >
                      <option value="">(default — derived from URI)</option>
                      <option value="user">user — QEMU SLIRP, NAT-to-host</option>
                      <option value="network">network — libvirt-managed virbr0 with NAT</option>
                      <option value="bridge">bridge — joins LAN as a peer (real DHCP lease)</option>
                      <option value="routed">routed — host-routed via pwnvbr0 (no NAT, SDWAN underlay)</option>
                    </select>
                    <p className="mt-1 text-xs text-theme-tertiary">
                      Bridge mode requires a host bridge plus <code>/etc/qemu/bridge.conf</code> allowing it
                      and <code>cap_net_admin</code> on <code>qemu-bridge-helper</code>.
                    </p>
                  </div>
                  {(formData.network_mode === 'bridge' || formData.network_mode === 'routed') && (
                    <div>
                      <label htmlFor="bridge_name" className="block text-sm font-medium text-theme-primary mb-1">
                        Bridge Name
                      </label>
                      <input
                        id="bridge_name"
                        type="text"
                        name="bridge_name"
                        value={formData.bridge_name}
                        onChange={handleChange}
                        placeholder={formData.network_mode === 'routed' ? 'pwnvbr0' : 'br0'}
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus"
                        data-testid="provider-form-bridge-name"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        {formData.network_mode === 'routed' ? (
                          <>Host-internal routed bridge (e.g. <code>pwnvbr0</code>). Default: <code>pwnvbr0</code>. Host needs IP forwarding enabled and the bridge in <code>/etc/qemu/bridge.conf</code>.</>
                        ) : (
                          <>Name of the host's Linux bridge interface (e.g. <code>br0</code>). Defaults to <code>br0</code>.</>
                        )}
                      </p>
                    </div>
                  )}
                </div>
              )}

              {/* Configuration */}
              <div>
                <label htmlFor="config" className="block text-sm font-medium text-theme-primary mb-1">
                  Configuration (JSON)
                </label>
                <textarea
                  id="config"
                  name="config"
                  value={formData.config}
                  onChange={handleChange}
                  rows={4}
                  className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus resize-none font-mono text-sm ${
                    errors.config ? 'border-theme-error' : 'border-theme'
                  }`}
                />
                {errors.config && (
                  <p className="mt-1 text-sm text-theme-error flex items-center gap-1">
                    <AlertCircle className="w-4 h-4" />
                    {errors.config}
                  </p>
                )}
              </div>

              {/* Capabilities */}
              <div>
                <label htmlFor="capabilities" className="block text-sm font-medium text-theme-primary mb-1">
                  Capabilities (JSON)
                </label>
                <textarea
                  id="capabilities"
                  name="capabilities"
                  value={formData.capabilities}
                  onChange={handleChange}
                  rows={4}
                  className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus resize-none font-mono text-sm ${
                    errors.capabilities ? 'border-theme-error' : 'border-theme'
                  }`}
                />
                {errors.capabilities && (
                  <p className="mt-1 text-sm text-theme-error flex items-center gap-1">
                    <AlertCircle className="w-4 h-4" />
                    {errors.capabilities}
                  </p>
                )}
              </div>

              {/* Checkboxes */}
              <div className="flex flex-col sm:flex-row sm:items-center gap-4">
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="enabled"
                    checked={formData.enabled}
                    onChange={handleChange}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-accent focus:ring-theme-focus"
                  />
                  <span className="text-sm text-theme-primary">Enabled</span>
                </label>

                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="public"
                    checked={formData.public}
                    onChange={handleChange}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-accent focus:ring-theme-focus"
                  />
                  <span className="text-sm text-theme-primary">Public</span>
                </label>
              </div>
            </div>

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
                  isEditMode ? 'Update Provider' : 'Add Provider'
                )}
              </Button>
            </div>
          </form>
          )}
        </div>
      </div>
    </div>
  );
};

export default ProviderFormModal;
