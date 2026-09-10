import React from 'react';
import { FormField } from '@/shared/components/ui/FormField';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { providerTypes, type ProviderFormData } from './providerFormHelpers';

export interface ProviderGeneralTabProps {
  formData: ProviderFormData;
  errors: Record<string, string>;
  submitting: boolean;
  isEditMode: boolean;
  setField: (name: string, value: string | boolean) => void;
  handleChange: (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>
  ) => void;
  onSubmit: (e: React.FormEvent) => void;
  onClose: () => void;
}

export const ProviderGeneralTab: React.FC<ProviderGeneralTabProps> = ({
  formData,
  errors,
  submitting,
  isEditMode,
  setField,
  handleChange,
  onSubmit,
  onClose,
}) => (
  <form onSubmit={onSubmit}>
    <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
      {/* Name and Type */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <FormField
          label="Name"
          id="name"
          required
          value={formData.name}
          onChange={(v) => setField('name', v)}
          placeholder="e.g., Production AWS"
          error={errors.name}
        />

        <FormField
          label="Provider Type"
          id="provider_type"
          type="select"
          required
          value={formData.provider_type}
          onChange={(v) => setField('provider_type', v)}
          error={errors.provider_type}
          options={providerTypes.map(type => ({ value: type.value, label: type.label }))}
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
        placeholder="Provider description"
      />

      {/* local_qemu networking — convenience fields that merge into Configuration JSON below */}
      {formData.provider_type === 'local_qemu' && (
        <div className="rounded-md border border-theme bg-theme-background-secondary p-3 space-y-3">
          <div>
            <FormField
              label="Network Mode"
              id="network_mode"
              type="select"
              value={formData.network_mode}
              onChange={(v) => setField('network_mode', v)}
              data-testid="provider-form-network-mode"
              options={[
                { value: '', label: '(default — derived from URI)' },
                { value: 'user', label: 'user — QEMU SLIRP, NAT-to-host' },
                { value: 'network', label: 'network — libvirt-managed virbr0 with NAT' },
                { value: 'bridge', label: 'bridge — joins LAN as a peer (real DHCP lease)' },
                { value: 'routed', label: 'routed — host-routed via pwnvbr0 (no NAT, SDWAN underlay)' },
              ]}
            />
            <p className="mt-1 text-xs text-theme-tertiary">
              Bridge mode requires a host bridge plus <code>/etc/qemu/bridge.conf</code> allowing it
              and <code>cap_net_admin</code> on <code>qemu-bridge-helper</code>.
            </p>
          </div>
          {(formData.network_mode === 'bridge' || formData.network_mode === 'routed') && (
            <div>
              <FormField
                label="Bridge Name"
                id="bridge_name"
                value={formData.bridge_name}
                onChange={(v) => setField('bridge_name', v)}
                placeholder={formData.network_mode === 'routed' ? 'pwnvbr0' : 'br0'}
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
            <FormField
              label="PVE API Endpoint"
              id="proxmox_endpoint"
              required
              value={formData.proxmox_endpoint}
              onChange={(v) => setField('proxmox_endpoint', v)}
              placeholder="https://pve.example.com:8006"
              error={errors.proxmox_endpoint}
              helpText="Base URL of the Proxmox VE REST API. Include scheme and port (8006 by default)."
              data-testid="provider-form-proxmox-endpoint"
            />
          </div>

          <div>
            <FormField
              label="TLS certificate verification"
              id="proxmox_verify_ssl"
              type="select"
              value={formData.proxmox_verify_ssl}
              onChange={(v) => setField('proxmox_verify_ssl', v)}
              data-testid="provider-form-proxmox-verify-ssl"
              options={[
                { value: 'true', label: 'Verify certificate (default — publicly-trusted cert)' },
                { value: 'false', label: 'Skip verification (self-signed PVE cert)' },
              ]}
            />
            <p className="mt-1 text-xs text-theme-tertiary">
              Most homelab PVE installs ship a self-signed cert — set to "Skip verification" for those.
            </p>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <FormField
                label="Default node"
                id="proxmox_default_node"
                value={formData.proxmox_default_node}
                onChange={(v) => setField('proxmox_default_node', v)}
                placeholder="(auto)"
              />
              <p className="mt-1 text-xs text-theme-tertiary">
                PVE node to provision VMs/LXCs on by default.
              </p>
            </div>
            <div>
              <FormField
                label="Default storage"
                id="proxmox_default_storage"
                value={formData.proxmox_default_storage}
                onChange={(v) => setField('proxmox_default_storage', v)}
                placeholder="(auto)"
              />
              <p className="mt-1 text-xs text-theme-tertiary">
                Storage pool for new disks (e.g. <code>local-lvm</code>).
              </p>
            </div>
            <div>
              <FormField
                label="Default bridge"
                id="proxmox_default_bridge"
                value={formData.proxmox_default_bridge}
                onChange={(v) => setField('proxmox_default_bridge', v)}
                placeholder="vmbr0"
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
              <FormField
                label="Default region"
                id="aws_default_region"
                value={formData.aws_default_region}
                onChange={(v) => setField('aws_default_region', v)}
                placeholder="us-east-1"
              />
              <p className="mt-1 text-xs text-theme-tertiary">
                AWS region code (e.g. <code>us-east-1</code>, <code>us-west-2</code>).
              </p>
            </div>
            <div>
              <FormField
                label="Default VPC"
                id="aws_default_vpc_id"
                value={formData.aws_default_vpc_id}
                onChange={(v) => setField('aws_default_vpc_id', v)}
                placeholder="(auto)"
              />
              <p className="mt-1 text-xs text-theme-tertiary">
                VPC ID (<code>vpc-...</code>) — defaults to account default-VPC.
              </p>
            </div>
            <div>
              <FormField
                label="Default subnet"
                id="aws_default_subnet_id"
                value={formData.aws_default_subnet_id}
                onChange={(v) => setField('aws_default_subnet_id', v)}
                placeholder="(auto)"
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
            <FormField
              label="Project ID"
              id="gcp_project_id"
              required
              value={formData.gcp_project_id}
              onChange={(v) => setField('gcp_project_id', v)}
              placeholder="my-gcp-project-12345"
              error={errors.gcp_project_id}
              helpText="GCP project ID where instances will be created."
            />
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <FormField
                label="Default region"
                id="gcp_default_region"
                value={formData.gcp_default_region}
                onChange={(v) => setField('gcp_default_region', v)}
                placeholder="us-central1"
              />
              <p className="mt-1 text-xs text-theme-tertiary">
                GCP region (e.g. <code>us-central1</code>).
              </p>
            </div>
            <div>
              <FormField
                label="Default zone"
                id="gcp_default_zone"
                value={formData.gcp_default_zone}
                onChange={(v) => setField('gcp_default_zone', v)}
                placeholder="(auto)"
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
              <FormField
                label="Subscription ID"
                id="azure_subscription_id"
                value={formData.azure_subscription_id}
                onChange={(v) => setField('azure_subscription_id', v)}
                placeholder="00000000-0000-0000-0000-000000000000"
              />
              <p className="mt-1 text-xs text-theme-tertiary">
                Azure subscription UUID for resource creation.
              </p>
            </div>
            <div>
              <FormField
                label="Default location"
                id="azure_default_location"
                value={formData.azure_default_location}
                onChange={(v) => setField('azure_default_location', v)}
                placeholder="eastus"
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
            <FormField
              label="Keystone auth URL"
              id="openstack_auth_url"
              required
              value={formData.openstack_auth_url}
              onChange={(v) => setField('openstack_auth_url', v)}
              placeholder="https://keystone.example.com:5000/v3"
              error={errors.openstack_auth_url}
            />
            {/* Not helpText: that prop is a string, and this hint marks
                up the path it is telling the operator not to omit. */}
            {!errors.openstack_auth_url && (
              <p className="mt-1 text-xs text-theme-tertiary">
                Keystone v3 endpoint URL — include the <code>/v3</code> suffix.
              </p>
            )}
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <FormField
                label="Default project"
                id="openstack_default_project"
                value={formData.openstack_default_project}
                onChange={(v) => setField('openstack_default_project', v)}
                placeholder="admin"
              />
              <p className="mt-1 text-xs text-theme-tertiary">
                Project (tenant) name to scope deployments to.
              </p>
            </div>
            <div>
              <FormField
                label="Default region"
                id="openstack_default_region"
                value={formData.openstack_default_region}
                onChange={(v) => setField('openstack_default_region', v)}
                placeholder="RegionOne"
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
            <FormField
              label="Default region"
              id="digitalocean_default_region"
              value={formData.digitalocean_default_region}
              onChange={(v) => setField('digitalocean_default_region', v)}
              placeholder="nyc3"
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
            <FormField
              label="Default region"
              id="vultr_default_region"
              value={formData.vultr_default_region}
              onChange={(v) => setField('vultr_default_region', v)}
              placeholder="ewr"
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
          <FormField
            label={<>Configuration <span className="text-xs font-normal text-theme-tertiary">(stored as JSON in <code>System::Provider#config</code>)</span></>}
            id="config"
            type="textarea"
            rows={4}
            value={formData.config}
            onChange={(v) => setField('config', v)}
            placeholder='{}'
            className="font-mono text-sm"
            error={errors.config}
          />

          {/* Capabilities */}
          <FormField
            label={<>Capabilities <span className="text-xs font-normal text-theme-tertiary">(usually <code>{'{"supports": [...]}'}</code>; informational metadata)</span></>}
            id="capabilities"
            type="textarea"
            rows={4}
            value={formData.capabilities}
            onChange={(v) => setField('capabilities', v)}
            placeholder='{}'
            className="font-mono text-sm"
            error={errors.capabilities}
          />
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
);

export default ProviderGeneralTab;
