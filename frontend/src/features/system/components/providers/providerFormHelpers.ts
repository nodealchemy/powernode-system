import {
  PROVIDER_FIELD_SCHEMAS,
  type ProviderFieldScope,
  type ProviderTypeSlug,
} from '@/features/onboarding/ProviderCredentialForm';

// Module-scoped so the reference stays stable across renders and ProviderCredentialForm's
// memoization keys don't churn. The Credentials tab hides every config-scope field
// (endpoint URLs, regions, verify_ssl, subscription IDs) because those live on the
// General tab and are written to Provider.config directly.
export const CREDENTIAL_TAB_EXCLUDE_SCOPES: ProviderFieldScope[] = ['config'];

/**
 * Map a SystemProvider.provider_type slug to the BYOC credential schema
 * shipped with the FirstRunWizard. Returns `null` for provider types that
 * don't yet have a credential schema (e.g. `openstack`, `custom`) so the
 * Credentials tab can render a graceful explainer instead.
 */
export const toOnboardingType = (providerType: string | undefined): ProviderTypeSlug | null => {
  if (!providerType) return null;
  const slug = providerType.toLowerCase();
  // PROVIDER_FIELD_SCHEMAS is keyed by category first (ai/cloud/git). The
  // ProviderFormModal lives in the system extension and only handles cloud
  // providers, so we look up under the cloud bucket.
  if (slug in PROVIDER_FIELD_SCHEMAS.cloud) return slug;
  return null;
};

export const providerTypes = [
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

export interface ProviderFormData {
  name: string;
  description: string;
  provider_type: string;
  enabled: boolean;
  public: boolean;
  config: string;
  capabilities: string;
  // local_qemu:
  network_mode: '' | 'user' | 'network' | 'bridge' | 'routed';
  bridge_name: string;
  // proxmox: connection + lifecycle defaults.
  proxmox_endpoint: string;
  proxmox_verify_ssl: 'true' | 'false';
  proxmox_default_node: string;
  proxmox_default_storage: string;
  proxmox_default_bridge: string;
  // aws:
  aws_default_region: string;
  aws_default_vpc_id: string;
  aws_default_subnet_id: string;
  // gcp:
  gcp_project_id: string;
  gcp_default_region: string;
  gcp_default_zone: string;
  // azure:
  azure_subscription_id: string;
  azure_default_location: string;
  // openstack:
  openstack_auth_url: string;
  openstack_default_project: string;
  openstack_default_region: string;
  // digitalocean / vultr:
  digitalocean_default_region: string;
  vultr_default_region: string;
}
