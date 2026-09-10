import React from 'react';
import { CheckCircle, XCircle, Globe, Lock } from 'lucide-react';
import type { SystemProvider } from '@system/features/system/types/system.types';
import { providerTypeLabels } from './providerDetailHelpers';

export interface ProviderInfoTabProps {
  provider: SystemProvider | null;
}

export const ProviderInfoTab: React.FC<ProviderInfoTabProps> = ({ provider }) => {
  if (!provider) return null;

  return (
    <div className="space-y-6">
      {/* Basic Info */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-6">
        <div className="space-y-4">
          <div>
            <label className="block text-sm text-theme-secondary mb-1">Name</label>
            <p className="text-theme-primary font-medium">{provider.name}</p>
          </div>
          <div>
            <label className="block text-sm text-theme-secondary mb-1">Description</label>
            <p className="text-theme-primary">{provider.description || '—'}</p>
          </div>
        </div>
        <div className="space-y-4">
          <div>
            <label className="block text-sm text-theme-secondary mb-1">Provider Type</label>
            <p className="text-theme-primary">
              {providerTypeLabels[provider.provider_type] || provider.provider_type}
            </p>
          </div>
          <div>
            <label className="block text-sm text-theme-secondary mb-1">Resources</label>
            <div className="flex items-center gap-4 text-theme-primary">
              <span>{provider.region_count || 0} regions</span>
              <span>{provider.connection_count || 0} connections</span>
            </div>
          </div>
        </div>
      </div>

      {/* Status Badges */}
      <div className="flex flex-wrap gap-4 pt-4 border-t border-theme">
        <div className="flex items-center gap-2">
          {provider.enabled ? (
            <CheckCircle className="w-5 h-5 text-theme-success-fg" />
          ) : (
            <XCircle className="w-5 h-5 text-theme-error-fg" />
          )}
          <span className="text-theme-primary">
            {provider.enabled ? 'Enabled' : 'Disabled'}
          </span>
        </div>
        <div className="flex items-center gap-2">
          {provider.public ? (
            <Globe className="w-5 h-5 text-theme-info-fg" />
          ) : (
            <Lock className="w-5 h-5 text-theme-secondary" />
          )}
          <span className="text-theme-primary">
            {provider.public ? 'Public' : 'Private'}
          </span>
        </div>
      </div>

      {/* Timestamps */}
      <div className="grid grid-cols-2 gap-4 pt-4 border-t border-theme text-sm">
        <div>
          <span className="text-theme-secondary">Created:</span>
          <span className="ml-2 text-theme-primary">
            {new Date(provider.created_at).toLocaleString()}
          </span>
        </div>
        <div>
          <span className="text-theme-secondary">Updated:</span>
          <span className="ml-2 text-theme-primary">
            {new Date(provider.updated_at).toLocaleString()}
          </span>
        </div>
      </div>
    </div>
  );
};

export default ProviderInfoTab;
