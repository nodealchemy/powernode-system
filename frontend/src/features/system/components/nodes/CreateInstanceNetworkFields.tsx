import React from 'react';
import type { CreateInstanceFormData } from './createInstanceHelpers';

export interface CreateInstanceNetworkFieldsProps {
  formData: CreateInstanceFormData;
  submitting: boolean;
  onChange: (field: keyof CreateInstanceFormData, value: string) => void;
}

export const CreateInstanceNetworkFields: React.FC<CreateInstanceNetworkFieldsProps> = ({
  formData,
  submitting,
  onChange,
}) => (
  <div className="space-y-4">
    <h3 className="text-sm font-medium text-theme-primary">Network Configuration</h3>

    <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
      {/* Private IP */}
      <div>
        <label htmlFor="instance-private-ip" className="block text-sm font-medium text-theme-secondary mb-1">
          Private IP
        </label>
        <input
          id="instance-private-ip"
          type="text"
          value={formData.private_ip_address}
          onChange={(e) => onChange('private_ip_address', e.target.value)}
          placeholder="10.0.0.1"
          className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary placeholder-theme-secondary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary font-mono text-sm"
          disabled={submitting}
        />
      </div>

      {/* Public IP */}
      <div>
        <label htmlFor="instance-public-ip" className="block text-sm font-medium text-theme-secondary mb-1">
          Public IP
        </label>
        <input
          id="instance-public-ip"
          type="text"
          value={formData.public_ip_address}
          onChange={(e) => onChange('public_ip_address', e.target.value)}
          placeholder="203.0.113.1"
          className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary placeholder-theme-secondary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary font-mono text-sm"
          disabled={submitting}
        />
      </div>

      {/* VPN IP */}
      <div>
        <label htmlFor="instance-vpn-ip" className="block text-sm font-medium text-theme-secondary mb-1">
          VPN IP
        </label>
        <input
          id="instance-vpn-ip"
          type="text"
          value={formData.vpn_ip_address}
          onChange={(e) => onChange('vpn_ip_address', e.target.value)}
          placeholder="172.16.0.1"
          className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary placeholder-theme-secondary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary font-mono text-sm"
          disabled={submitting}
        />
      </div>
    </div>

    <p className="text-xs text-theme-secondary">
      {formData.variety === 'cloud'
        ? 'IP addresses are typically assigned automatically by the provider. Leave empty for automatic assignment.'
        : 'Specify IP addresses for this instance. Leave empty if not applicable.'}
    </p>
  </div>
);

export default CreateInstanceNetworkFields;
