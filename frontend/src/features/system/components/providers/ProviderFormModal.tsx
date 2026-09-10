import React, { useMemo, useState, useEffect } from 'react';
import { Cloud, KeyRound } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { apiClient } from '@/shared/services/apiClient';
import { logger } from '@/shared/utils/logger';
import {
  type CredentialTestStatus,
  type ProviderCredentialValues,
} from '@/features/onboarding/ProviderCredentialForm';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemProvider } from '@system/features/system/types/system.types';
import { toOnboardingType, type ProviderFormData } from './providerFormHelpers';
import { ProviderGeneralTab } from './ProviderGeneralTab';
import { ProviderCredentialsTab } from './ProviderCredentialsTab';

type TabKey = 'general' | 'credentials';

interface ProviderFormModalProps {
  isOpen: boolean;
  onClose: () => void;
  onProviderSaved?: (provider: SystemProvider) => void;
  /**
   * A credential was stored. Separate from onProviderSaved because storing a
   * credential is its own button on its own tab: the provider may not have
   * been touched at all, and a surface listing credentials would otherwise
   * miss the one write it exists to show.
   */
  onCredentialSaved?: () => void;
  editProvider?: SystemProvider | null;
}

/**
 * ProviderFormModal - Modal for creating or editing providers
 *
 * C12 (component-status-plane campaign): the General tab's giant per-
 * provider-type form body and the Credentials tab panel used to be inline
 * JSX in this file (1132 lines total). Split onto section components —
 * ProviderGeneralTab, ProviderCredentialsTab — with the provider-type
 * catalog and onboarding-type mapping moved to providerFormHelpers.ts. This
 * file is now the orchestrator: form state, validation, submit/save
 * handlers, and the manual two-tab strip.
 */
export const ProviderFormModal: React.FC<ProviderFormModalProps> = ({
  isOpen,
  onClose,
  onProviderSaved,
  onCredentialSaved,
  editProvider
}) => {
  const { addNotification } = useNotifications();

  const [formData, setFormData] = useState<ProviderFormData>({
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
    network_mode: '',
    bridge_name: '',
    proxmox_endpoint: '',
    proxmox_verify_ssl: 'true',
    proxmox_default_node: '',
    proxmox_default_storage: '',
    proxmox_default_bridge: '',
    aws_default_region: '',
    aws_default_vpc_id: '',
    aws_default_subnet_id: '',
    gcp_project_id: '',
    gcp_default_region: '',
    gcp_default_zone: '',
    azure_subscription_id: '',
    azure_default_location: '',
    openstack_auth_url: '',
    openstack_default_project: '',
    openstack_default_region: '',
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
      onCredentialSaved?.();
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

  const handleCredentialsChange = (values: ProviderCredentialValues, valid: boolean) => {
    setCredentialValues(values);
    setCredentialsValid(valid);
    if (credentialSaved) setCredentialSaved(false);
  };

  // Credentials tab needs the provider record (for its UUID) to associate
  // credentials. Available once editing OR once a new provider has been
  // successfully created in this session (createdProvider is populated by
  // handleSubmit on a successful POST). For the truly-empty case the tab is
  // disabled with a hint pointing to the Save button.
  const credentialsTabAvailable = !!effectiveProvider;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={isEditMode ? 'Edit Provider' : 'Add Provider'}
      icon={<Cloud className="w-6 h-6" />}
      maxWidth="2xl"
    >
          {/* Tab strip */}
          <div className="flex items-center gap-1 border-b border-theme" role="tablist">
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
            <ProviderCredentialsTab
              effectiveProvider={effectiveProvider}
              editProvider={editProvider}
              createdProvider={createdProvider}
              onboardingType={onboardingType}
              providerType={formData.provider_type}
              credentialsValid={credentialsValid}
              testStatus={testStatus}
              savingCredentials={savingCredentials}
              credentialSaved={credentialSaved}
              onCredentialsChange={handleCredentialsChange}
              onTestStatusChange={setTestStatus}
              onSaveCredentials={handleSaveCredentials}
              onClose={onClose}
            />
          ) : (
            <ProviderGeneralTab
              formData={formData}
              errors={errors}
              submitting={submitting}
              isEditMode={isEditMode}
              setField={setField}
              handleChange={handleChange}
              onSubmit={handleSubmit}
              onClose={onClose}
            />
          )}
    </Modal>
  );
};

export default ProviderFormModal;
