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
  type ProviderFieldScope,
  type ProviderTypeSlug,
  type ProviderCredentialValues,
} from '@/features/onboarding/ProviderCredentialForm';

// Module-scoped so the reference stays stable across renders and ProviderCredentialForm's
// memoization keys don't churn. The Credentials tab hides every config-scope field
// (endpoint URLs, regions, verify_ssl, subscription IDs) because those live on the
// General tab and are written to Provider.config directly.
const CREDENTIAL_TAB_EXCLUDE_SCOPES: ProviderFieldScope[] = ['config'];
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
  { value: 'vultr', label: 'Vultr' },
  { value: 'proxmox', label: 'Proxmox VE' },
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
    // Per-provider-type convenience fields. When the form is submitted these
    // get merged into the parsed `config` JSON so the backend stores them
    // under System::Provider#config[…]. The raw Configuration JSON textarea
    // (inside Advanced) remains the source of truth for anything not covered.
    //
    // local_qemu:
    network_mode: '' as '' | 'user' | 'network' | 'bridge' | 'routed',
    bridge_name: '',
    // proxmox: connection + lifecycle defaults. endpoint + verify_ssl drive
    // adapter authentication; default_* are used by create_instance when the
    // caller doesn't specify them.
    proxmox_endpoint: '',
    proxmox_verify_ssl: 'true' as 'true' | 'false',
    proxmox_default_node: '',
    proxmox_default_storage: '',
    proxmox_default_bridge: '',
    // aws: typical regional defaults. Region is also in the AWS credentials
    // schema; the General-tab value writes to Provider.config["default_region"]
    // and acts as the fallback when a connection doesn't override it.
    aws_default_region: '',
    aws_default_vpc_id: '',
    aws_default_subnet_id: '',
    // gcp: project_id is required for any GCP API call.
    gcp_project_id: '',
    gcp_default_region: '',
    gcp_default_zone: '',
    // azure: subscription_id often differs per-tenant; common to set once.
    azure_subscription_id: '',
    azure_default_location: '',
    // openstack: Keystone v3 endpoint + project + region are the minimum.
    openstack_auth_url: '',
    openstack_default_project: '',
    openstack_default_region: '',
    // digitalocean / vultr: just a default region slug.
    digitalocean_default_region: '',
    vultr_default_region: '',
  });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);
  const [activeTab, setActiveTab] = useState<TabKey>('general');

  // Local "just-created" tracker. When the operator saves a NEW provider, we
  // stash the returned record here, switch them to the Credentials tab, and
  // keep the modal open so they can enter credentials in a single flow rather
  // than re-opening the modal in edit mode. The Credentials tab uses the
  // effective provider (editProvider ?? createdProvider) for lookups.
  const [createdProvider, setCreatedProvider] = useState<SystemProvider | null>(null);

  // Credentials tab state — kept in this scope so switching tabs preserves entry.
  const [credentialValues, setCredentialValues] = useState<ProviderCredentialValues>({});
  const [credentialsValid, setCredentialsValid] = useState(false);
  const [testStatus, setTestStatus] = useState<CredentialTestStatus>('idle');
  const [savingCredentials, setSavingCredentials] = useState(false);
  const [credentialSaved, setCredentialSaved] = useState(false);

  // `isEditMode` historically meant "the prop was set" — we now also flip to
  // true once a newly-created provider lands in local state, so the Credentials
  // tab unlocks without requiring the parent to re-render with the prop.
  const effectiveProvider = editProvider ?? createdProvider;
  const isEditMode = !!effectiveProvider;

  const onboardingType = useMemo(
    () => toOnboardingType(formData.provider_type),
    [formData.provider_type]
  );

  // Reset credentials tab whenever a different provider is being edited so the
  // previous record's keys can't leak into the next save. Also clears the
  // local createdProvider when the modal is opened for a different editProvider
  // (otherwise stale "just-created" state would survive across opens).
  useEffect(() => {
    setCredentialValues({});
    setCredentialsValid(false);
    setTestStatus('idle');
    setCredentialSaved(false);
    setActiveTab('general');
    setCreatedProvider(null);
  }, [editProvider?.id, isOpen]);

  useEffect(() => {
    if (isOpen) {
      if (editProvider) {
        const cfg = (editProvider.config || {}) as Record<string, unknown>;
        const nm = typeof cfg.network_mode === 'string' ? cfg.network_mode : '';
        const verifyRaw = cfg.verify_ssl;
        const verifySsl: 'true' | 'false' = verifyRaw === false || verifyRaw === 'false' ? 'false' : 'true';
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
          proxmox_endpoint: typeof cfg.endpoint === 'string' ? cfg.endpoint : (typeof cfg.endpoint_url === 'string' ? cfg.endpoint_url : ''),
          proxmox_verify_ssl: verifySsl,
          proxmox_default_node: typeof cfg.default_node === 'string' ? cfg.default_node : '',
          proxmox_default_storage: typeof cfg.default_storage === 'string' ? cfg.default_storage : '',
          proxmox_default_bridge: typeof cfg.default_bridge === 'string' ? cfg.default_bridge : '',
          aws_default_region: typeof cfg.default_region === 'string' ? cfg.default_region : '',
          aws_default_vpc_id: typeof cfg.default_vpc_id === 'string' ? cfg.default_vpc_id : '',
          aws_default_subnet_id: typeof cfg.default_subnet_id === 'string' ? cfg.default_subnet_id : '',
          gcp_project_id: typeof cfg.project_id === 'string' ? cfg.project_id : '',
          gcp_default_region: typeof cfg.default_region === 'string' ? cfg.default_region : '',
          gcp_default_zone: typeof cfg.default_zone === 'string' ? cfg.default_zone : '',
          azure_subscription_id: typeof cfg.subscription_id === 'string' ? cfg.subscription_id : '',
          azure_default_location: typeof cfg.default_location === 'string' ? cfg.default_location : '',
          openstack_auth_url: typeof cfg.auth_url === 'string' ? cfg.auth_url : '',
          openstack_default_project: typeof cfg.default_project === 'string' ? cfg.default_project : '',
          openstack_default_region: typeof cfg.default_region === 'string' ? cfg.default_region : '',
          digitalocean_default_region: typeof cfg.default_region === 'string' ? cfg.default_region : '',
          vultr_default_region: typeof cfg.default_region === 'string' ? cfg.default_region : '',
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
          proxmox_endpoint: '',
          proxmox_verify_ssl: 'true',
          proxmox_default_node: '',
          proxmox_default_storage: '',
          proxmox_default_bridge: '',
          aws_default_region: 'us-east-1',
          aws_default_vpc_id: '',
          aws_default_subnet_id: '',
          gcp_project_id: '',
          gcp_default_region: 'us-central1',
          gcp_default_zone: '',
          azure_subscription_id: '',
          azure_default_location: 'eastus',
          openstack_auth_url: '',
          openstack_default_project: '',
          openstack_default_region: '',
          digitalocean_default_region: 'nyc3',
          vultr_default_region: 'ewr',
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

    // Proxmox requires an endpoint URL — the adapter can't authenticate
    // without it, and putting it on the General tab means we surface the
    // validation before the operator even reaches the Credentials tab.
    if (formData.provider_type === 'proxmox' && !formData.proxmox_endpoint.trim()) {
      newErrors.proxmox_endpoint = 'PVE API endpoint URL is required for Proxmox providers';
    } else if (formData.provider_type === 'proxmox' && !/^https?:\/\//.test(formData.proxmox_endpoint.trim())) {
      newErrors.proxmox_endpoint = 'Endpoint must start with http:// or https://';
    }

    // GCP cannot create resources without a project; require it up front so
    // the failure surfaces in the form rather than from the backend adapter.
    if (formData.provider_type === 'gcp' && !formData.gcp_project_id.trim()) {
      newErrors.gcp_project_id = 'GCP project ID is required';
    }

    // OpenStack needs the Keystone auth URL to even attempt authentication —
    // the username/password on the Credentials tab is useless without it.
    if (formData.provider_type === 'openstack' && !formData.openstack_auth_url.trim()) {
      newErrors.openstack_auth_url = 'Keystone auth URL is required for OpenStack providers';
    } else if (formData.provider_type === 'openstack' && !/^https?:\/\//.test(formData.openstack_auth_url.trim())) {
      newErrors.openstack_auth_url = 'Auth URL must start with http:// or https://';
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
      } else {
        // Per-provider config merge. Each branch writes its structured form
        // fields back into the Provider.config JSONB under stable keys.
        // setOrDel keeps the JSON tidy (no empty-string keys littering it).
        const setOrDel = (key: string, value: string) => {
          if (value && value.trim()) {
            parsedConfig[key] = value.trim();
          } else {
            delete parsedConfig[key];
          }
        };

        if (formData.provider_type === 'proxmox') {
          setOrDel('endpoint', formData.proxmox_endpoint);
          // verify_ssl is always a definite "true" or "false" — write it.
          parsedConfig.verify_ssl = formData.proxmox_verify_ssl;
          setOrDel('default_node', formData.proxmox_default_node);
          setOrDel('default_storage', formData.proxmox_default_storage);
          setOrDel('default_bridge', formData.proxmox_default_bridge);
        } else if (formData.provider_type === 'aws') {
          setOrDel('default_region', formData.aws_default_region);
          setOrDel('default_vpc_id', formData.aws_default_vpc_id);
          setOrDel('default_subnet_id', formData.aws_default_subnet_id);
        } else if (formData.provider_type === 'gcp') {
          setOrDel('project_id', formData.gcp_project_id);
          setOrDel('default_region', formData.gcp_default_region);
          setOrDel('default_zone', formData.gcp_default_zone);
        } else if (formData.provider_type === 'azure') {
          setOrDel('subscription_id', formData.azure_subscription_id);
          setOrDel('default_location', formData.azure_default_location);
        } else if (formData.provider_type === 'openstack') {
          setOrDel('auth_url', formData.openstack_auth_url);
          setOrDel('default_project', formData.openstack_default_project);
          setOrDel('default_region', formData.openstack_default_region);
        } else if (formData.provider_type === 'digitalocean') {
          setOrDel('default_region', formData.digitalocean_default_region);
        } else if (formData.provider_type === 'vultr') {
          setOrDel('default_region', formData.vultr_default_region);
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

      if (editProvider) {
        result = await systemApi.updateProvider(editProvider.id, submitData);
        addNotification({
          type: 'success',
          message: `Provider "${result.name}" updated successfully`
        });
        onProviderSaved?.(result);
        onClose();
      } else {
        result = await systemApi.createProvider(submitData);
        addNotification({
          type: 'success',
          message: `Provider "${result.name}" created — add credentials next`
        });
        // Notify the parent (so its provider list refreshes) but keep the modal
        // open. Stash the result locally + switch to Credentials so the operator
        // can finish the flow in one go instead of re-opening the modal.
        setCreatedProvider(result);
        onProviderSaved?.(result);
        setActiveTab('credentials');
      }
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
    if (!effectiveProvider) return;
    if (!credentialsValid) return;
    setSavingCredentials(true);
    try {
      await apiClient.post('/system/provider_credentials', {
        provider_id: effectiveProvider.id,
        provider_type: effectiveProvider.provider_type,
        credentials: credentialValues,
      });
      setCredentialSaved(true);
      addNotification({
        type: 'success',
        message: `Credentials saved for ${effectiveProvider.name}`,
      });
    } catch (error) {
      logger.error('ProviderFormModal: failed to save credentials', error, {
        providerId: effectiveProvider.id,
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

  // Credentials tab needs the provider record (for its UUID) to associate
  // credentials. Available once editing OR once a new provider has been
  // successfully created in this session (createdProvider is populated by
  // handleSubmit on a successful POST). For the truly-empty case the tab is
  // disabled with a hint pointing to the Save button.
  const credentialsTabAvailable = !!effectiveProvider;

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto">
      <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={onClose} />

      <div className="flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-2xl bg-theme-surface rounded-lg shadow-xl">
          <div className="flex items-center justify-between p-4 border-b border-theme">
            <div className="flex items-center gap-3">
              <Cloud className="w-6 h-6 text-theme-info" />
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

          {activeTab === 'credentials' && credentialsTabAvailable && effectiveProvider ? (
            <div
              className="p-4 space-y-4 max-h-[70vh] overflow-y-auto"
              data-testid="provider-form-credentials-panel"
            >
              {!editProvider && createdProvider && (
                <div className="rounded-lg border border-theme-success/40 bg-theme-success/10 p-3 text-sm text-theme-secondary">
                  <p className="font-medium text-theme-primary">
                    Provider "{createdProvider.name}" created.
                  </p>
                  <p className="mt-1 text-xs">
                    Fill in credentials below and click <span className="font-medium text-theme-secondary">Test</span>{' '}
                    then <span className="font-medium text-theme-secondary">Save credentials</span> to finish,
                    or click <span className="font-medium text-theme-secondary">Close</span> to add them later.
                  </p>
                </div>
              )}
              {onboardingType ? (
                <>
                  <ProviderCredentialForm
                    category="cloud"
                    providerType={onboardingType}
                    providerId={effectiveProvider.id}
                    excludeScopes={CREDENTIAL_TAB_EXCLUDE_SCOPES}
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

              {/* Proxmox VE connection settings — structured form fields that
                  merge into Configuration JSON. ProxmoxProvider#pve_credential
                  reads these from connection.provider.config when not present
                  on the per-connection record. */}
              {formData.provider_type === 'proxmox' && (
                <div className="rounded-md border border-theme bg-theme-background-secondary p-3 space-y-3">
                  <p className="text-xs font-medium uppercase tracking-wide text-theme-tertiary">
                    Proxmox VE connection
                  </p>

                  <div>
                    <label htmlFor="proxmox_endpoint" className="block text-sm font-medium text-theme-primary mb-1">
                      PVE API Endpoint <span className="text-theme-error">*</span>
                    </label>
                    <input
                      id="proxmox_endpoint"
                      type="text"
                      name="proxmox_endpoint"
                      value={formData.proxmox_endpoint}
                      onChange={handleChange}
                      placeholder="https://pve.example.com:8006"
                      className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
                        errors.proxmox_endpoint ? 'border-theme-error' : 'border-theme'
                      }`}
                      data-testid="provider-form-proxmox-endpoint"
                    />
                    {errors.proxmox_endpoint ? (
                      <p className="mt-1 text-sm text-theme-error flex items-center gap-1">
                        <AlertCircle className="w-4 h-4" />
                        {errors.proxmox_endpoint}
                      </p>
                    ) : (
                      <p className="mt-1 text-xs text-theme-tertiary">
                        Base URL of the Proxmox VE REST API. Include scheme and port (8006 by default).
                      </p>
                    )}
                  </div>

                  <div>
                    <label htmlFor="proxmox_verify_ssl" className="block text-sm font-medium text-theme-primary mb-1">
                      TLS certificate verification
                    </label>
                    <select
                      id="proxmox_verify_ssl"
                      name="proxmox_verify_ssl"
                      value={formData.proxmox_verify_ssl}
                      onChange={handleChange}
                      className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus"
                      data-testid="provider-form-proxmox-verify-ssl"
                    >
                      <option value="true">Verify certificate (default — publicly-trusted cert)</option>
                      <option value="false">Skip verification (self-signed PVE cert)</option>
                    </select>
                    <p className="mt-1 text-xs text-theme-tertiary">
                      Most homelab PVE installs ship a self-signed cert — set to "Skip verification" for those.
                    </p>
                  </div>

                  <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                    <div>
                      <label htmlFor="proxmox_default_node" className="block text-sm font-medium text-theme-primary mb-1">
                        Default node
                      </label>
                      <input
                        id="proxmox_default_node"
                        type="text"
                        name="proxmox_default_node"
                        value={formData.proxmox_default_node}
                        onChange={handleChange}
                        placeholder="(auto)"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        PVE node to provision VMs/LXCs on by default.
                      </p>
                    </div>
                    <div>
                      <label htmlFor="proxmox_default_storage" className="block text-sm font-medium text-theme-primary mb-1">
                        Default storage
                      </label>
                      <input
                        id="proxmox_default_storage"
                        type="text"
                        name="proxmox_default_storage"
                        value={formData.proxmox_default_storage}
                        onChange={handleChange}
                        placeholder="(auto)"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        Storage pool for new disks (e.g. <code>local-lvm</code>).
                      </p>
                    </div>
                    <div>
                      <label htmlFor="proxmox_default_bridge" className="block text-sm font-medium text-theme-primary mb-1">
                        Default bridge
                      </label>
                      <input
                        id="proxmox_default_bridge"
                        type="text"
                        name="proxmox_default_bridge"
                        value={formData.proxmox_default_bridge}
                        onChange={handleChange}
                        placeholder="vmbr0"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        Network bridge (Linux or OVS).
                      </p>
                    </div>
                  </div>

                  <p className="text-xs text-theme-tertiary">
                    API token credentials (USER@REALM!TOKENNAME + UUID secret) go on the
                    <span className="font-medium text-theme-secondary"> Credentials </span>
                    tab after saving.
                  </p>
                </div>
              )}

              {/* AWS regional defaults. Access key + secret go on the Credentials
                  tab; these are just the per-provider deployment defaults. */}
              {formData.provider_type === 'aws' && (
                <div className="rounded-md border border-theme bg-theme-background-secondary p-3 space-y-3">
                  <p className="text-xs font-medium uppercase tracking-wide text-theme-tertiary">
                    AWS deployment defaults
                  </p>

                  <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                    <div>
                      <label htmlFor="aws_default_region" className="block text-sm font-medium text-theme-primary mb-1">
                        Default region
                      </label>
                      <input
                        id="aws_default_region"
                        type="text"
                        name="aws_default_region"
                        value={formData.aws_default_region}
                        onChange={handleChange}
                        placeholder="us-east-1"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        AWS region code (e.g. <code>us-east-1</code>, <code>us-west-2</code>).
                      </p>
                    </div>
                    <div>
                      <label htmlFor="aws_default_vpc_id" className="block text-sm font-medium text-theme-primary mb-1">
                        Default VPC
                      </label>
                      <input
                        id="aws_default_vpc_id"
                        type="text"
                        name="aws_default_vpc_id"
                        value={formData.aws_default_vpc_id}
                        onChange={handleChange}
                        placeholder="(auto)"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        VPC ID (<code>vpc-...</code>) — defaults to account default-VPC.
                      </p>
                    </div>
                    <div>
                      <label htmlFor="aws_default_subnet_id" className="block text-sm font-medium text-theme-primary mb-1">
                        Default subnet
                      </label>
                      <input
                        id="aws_default_subnet_id"
                        type="text"
                        name="aws_default_subnet_id"
                        value={formData.aws_default_subnet_id}
                        onChange={handleChange}
                        placeholder="(auto)"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        Subnet ID (<code>subnet-...</code>) for new instances.
                      </p>
                    </div>
                  </div>

                  <p className="text-xs text-theme-tertiary">
                    AWS access key + secret go on the
                    <span className="font-medium text-theme-secondary"> Credentials </span>
                    tab after saving.
                  </p>
                </div>
              )}

              {/* GCP project + regional defaults. Service account JSON goes on
                  the Credentials tab. */}
              {formData.provider_type === 'gcp' && (
                <div className="rounded-md border border-theme bg-theme-background-secondary p-3 space-y-3">
                  <p className="text-xs font-medium uppercase tracking-wide text-theme-tertiary">
                    GCP project + deployment defaults
                  </p>

                  <div>
                    <label htmlFor="gcp_project_id" className="block text-sm font-medium text-theme-primary mb-1">
                      Project ID <span className="text-theme-error">*</span>
                    </label>
                    <input
                      id="gcp_project_id"
                      type="text"
                      name="gcp_project_id"
                      value={formData.gcp_project_id}
                      onChange={handleChange}
                      placeholder="my-gcp-project-12345"
                      className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
                        errors.gcp_project_id ? 'border-theme-error' : 'border-theme'
                      }`}
                    />
                    {errors.gcp_project_id ? (
                      <p className="mt-1 text-sm text-theme-error flex items-center gap-1">
                        <AlertCircle className="w-4 h-4" />
                        {errors.gcp_project_id}
                      </p>
                    ) : (
                      <p className="mt-1 text-xs text-theme-tertiary">
                        GCP project ID where instances will be created.
                      </p>
                    )}
                  </div>

                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    <div>
                      <label htmlFor="gcp_default_region" className="block text-sm font-medium text-theme-primary mb-1">
                        Default region
                      </label>
                      <input
                        id="gcp_default_region"
                        type="text"
                        name="gcp_default_region"
                        value={formData.gcp_default_region}
                        onChange={handleChange}
                        placeholder="us-central1"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        GCP region (e.g. <code>us-central1</code>).
                      </p>
                    </div>
                    <div>
                      <label htmlFor="gcp_default_zone" className="block text-sm font-medium text-theme-primary mb-1">
                        Default zone
                      </label>
                      <input
                        id="gcp_default_zone"
                        type="text"
                        name="gcp_default_zone"
                        value={formData.gcp_default_zone}
                        onChange={handleChange}
                        placeholder="(auto)"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        Zone within the region (e.g. <code>us-central1-a</code>).
                      </p>
                    </div>
                  </div>

                  <p className="text-xs text-theme-tertiary">
                    Service account JSON goes on the
                    <span className="font-medium text-theme-secondary"> Credentials </span>
                    tab after saving.
                  </p>
                </div>
              )}

              {/* Azure subscription + location. Service principal credentials on
                  the Credentials tab. */}
              {formData.provider_type === 'azure' && (
                <div className="rounded-md border border-theme bg-theme-background-secondary p-3 space-y-3">
                  <p className="text-xs font-medium uppercase tracking-wide text-theme-tertiary">
                    Azure subscription + deployment defaults
                  </p>

                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    <div>
                      <label htmlFor="azure_subscription_id" className="block text-sm font-medium text-theme-primary mb-1">
                        Subscription ID
                      </label>
                      <input
                        id="azure_subscription_id"
                        type="text"
                        name="azure_subscription_id"
                        value={formData.azure_subscription_id}
                        onChange={handleChange}
                        placeholder="00000000-0000-0000-0000-000000000000"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        Azure subscription UUID for resource creation.
                      </p>
                    </div>
                    <div>
                      <label htmlFor="azure_default_location" className="block text-sm font-medium text-theme-primary mb-1">
                        Default location
                      </label>
                      <input
                        id="azure_default_location"
                        type="text"
                        name="azure_default_location"
                        value={formData.azure_default_location}
                        onChange={handleChange}
                        placeholder="eastus"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        Azure region (e.g. <code>eastus</code>, <code>westus2</code>).
                      </p>
                    </div>
                  </div>

                  <p className="text-xs text-theme-tertiary">
                    Tenant ID + client ID + client secret go on the
                    <span className="font-medium text-theme-secondary"> Credentials </span>
                    tab after saving.
                  </p>
                </div>
              )}

              {/* OpenStack Keystone endpoint + project/region. Username + password
                  + domain on the Credentials tab. */}
              {formData.provider_type === 'openstack' && (
                <div className="rounded-md border border-theme bg-theme-background-secondary p-3 space-y-3">
                  <p className="text-xs font-medium uppercase tracking-wide text-theme-tertiary">
                    OpenStack Keystone + deployment defaults
                  </p>

                  <div>
                    <label htmlFor="openstack_auth_url" className="block text-sm font-medium text-theme-primary mb-1">
                      Keystone auth URL <span className="text-theme-error">*</span>
                    </label>
                    <input
                      id="openstack_auth_url"
                      type="text"
                      name="openstack_auth_url"
                      value={formData.openstack_auth_url}
                      onChange={handleChange}
                      placeholder="https://keystone.example.com:5000/v3"
                      className={`w-full px-3 py-2 rounded-lg border bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus ${
                        errors.openstack_auth_url ? 'border-theme-error' : 'border-theme'
                      }`}
                    />
                    {errors.openstack_auth_url ? (
                      <p className="mt-1 text-sm text-theme-error flex items-center gap-1">
                        <AlertCircle className="w-4 h-4" />
                        {errors.openstack_auth_url}
                      </p>
                    ) : (
                      <p className="mt-1 text-xs text-theme-tertiary">
                        Keystone v3 endpoint URL — include the <code>/v3</code> suffix.
                      </p>
                    )}
                  </div>

                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                    <div>
                      <label htmlFor="openstack_default_project" className="block text-sm font-medium text-theme-primary mb-1">
                        Default project
                      </label>
                      <input
                        id="openstack_default_project"
                        type="text"
                        name="openstack_default_project"
                        value={formData.openstack_default_project}
                        onChange={handleChange}
                        placeholder="admin"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        Project (tenant) name to scope deployments to.
                      </p>
                    </div>
                    <div>
                      <label htmlFor="openstack_default_region" className="block text-sm font-medium text-theme-primary mb-1">
                        Default region
                      </label>
                      <input
                        id="openstack_default_region"
                        type="text"
                        name="openstack_default_region"
                        value={formData.openstack_default_region}
                        onChange={handleChange}
                        placeholder="RegionOne"
                        className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                      />
                      <p className="mt-1 text-xs text-theme-tertiary">
                        Keystone region (often <code>RegionOne</code>).
                      </p>
                    </div>
                  </div>

                  <p className="text-xs text-theme-tertiary">
                    Username + password + user-domain go on the
                    <span className="font-medium text-theme-secondary"> Credentials </span>
                    tab after saving.
                  </p>
                </div>
              )}

              {/* DigitalOcean: only regional default. API token on Credentials. */}
              {formData.provider_type === 'digitalocean' && (
                <div className="rounded-md border border-theme bg-theme-background-secondary p-3 space-y-3">
                  <p className="text-xs font-medium uppercase tracking-wide text-theme-tertiary">
                    DigitalOcean deployment defaults
                  </p>

                  <div>
                    <label htmlFor="digitalocean_default_region" className="block text-sm font-medium text-theme-primary mb-1">
                      Default region
                    </label>
                    <input
                      id="digitalocean_default_region"
                      type="text"
                      name="digitalocean_default_region"
                      value={formData.digitalocean_default_region}
                      onChange={handleChange}
                      placeholder="nyc3"
                      className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                    />
                    <p className="mt-1 text-xs text-theme-tertiary">
                      DigitalOcean region slug (e.g. <code>nyc3</code>, <code>sfo3</code>, <code>ams3</code>).
                    </p>
                  </div>

                  <p className="text-xs text-theme-tertiary">
                    Personal access token goes on the
                    <span className="font-medium text-theme-secondary"> Credentials </span>
                    tab after saving.
                  </p>
                </div>
              )}

              {/* Vultr: only regional default. API key on Credentials. */}
              {formData.provider_type === 'vultr' && (
                <div className="rounded-md border border-theme bg-theme-background-secondary p-3 space-y-3">
                  <p className="text-xs font-medium uppercase tracking-wide text-theme-tertiary">
                    Vultr deployment defaults
                  </p>

                  <div>
                    <label htmlFor="vultr_default_region" className="block text-sm font-medium text-theme-primary mb-1">
                      Default region
                    </label>
                    <input
                      id="vultr_default_region"
                      type="text"
                      name="vultr_default_region"
                      value={formData.vultr_default_region}
                      onChange={handleChange}
                      placeholder="ewr"
                      className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
                    />
                    <p className="mt-1 text-xs text-theme-tertiary">
                      Vultr region code (e.g. <code>sea</code> Seattle, <code>ewr</code> New Jersey, <code>lax</code>).
                    </p>
                  </div>

                  <p className="text-xs text-theme-tertiary">
                    Vultr API key goes on the
                    <span className="font-medium text-theme-secondary"> Credentials </span>
                    tab after saving.
                  </p>
                </div>
              )}

              {/* Advanced configuration — collapsed by default. Most operators don't
                  need to set anything here; provider-type-specific fields (above)
                  and the Credentials tab cover the common case. The JSON shapes
                  are stored in System::Provider#config / #capabilities respectively. */}
              <details className="rounded-lg border border-theme bg-theme-background-secondary">
                <summary className="cursor-pointer select-none px-3 py-2 text-sm font-medium text-theme-primary hover:bg-theme-surface-hover">
                  Advanced configuration (raw JSON)
                </summary>
                <div className="space-y-4 px-3 pb-3 pt-1">
                  <p className="text-xs text-theme-tertiary">
                    Most providers don't need anything here. Credentials live on the{' '}
                    <span className="font-medium text-theme-secondary">Credentials</span> tab; the
                    fields below are escape hatches for provider-specific metadata. Leave both as{' '}
                    <code className="rounded bg-theme-surface px-1 py-0.5">{'{}'}</code> if unsure.
                  </p>

                  {/* Configuration */}
                  <div>
                    <label htmlFor="config" className="block text-sm font-medium text-theme-primary mb-1">
                      Configuration <span className="text-xs font-normal text-theme-tertiary">(stored as JSON in <code>System::Provider#config</code>)</span>
                    </label>
                    <textarea
                      id="config"
                      name="config"
                      value={formData.config}
                      onChange={handleChange}
                      rows={4}
                      placeholder='{}'
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
                      Capabilities <span className="text-xs font-normal text-theme-tertiary">(usually <code>{'{"supports": [...]}'}</code>; informational metadata)</span>
                    </label>
                    <textarea
                      id="capabilities"
                      name="capabilities"
                      value={formData.capabilities}
                      onChange={handleChange}
                      rows={4}
                      placeholder='{}'
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
                </div>
              </details>

              {/* Checkboxes */}
              <div className="flex flex-col sm:flex-row sm:items-center gap-4">
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="enabled"
                    checked={formData.enabled}
                    onChange={handleChange}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info focus:ring-theme-focus"
                  />
                  <span className="text-sm text-theme-primary">Enabled</span>
                </label>

                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    name="public"
                    checked={formData.public}
                    onChange={handleChange}
                    className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info focus:ring-theme-focus"
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
