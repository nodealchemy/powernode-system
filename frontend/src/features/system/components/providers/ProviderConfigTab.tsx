import React from 'react';
import type { SystemProvider } from '@system/features/system/types/system.types';

export interface ProviderConfigTabProps {
  provider: SystemProvider | null;
}

export const ProviderConfigTab: React.FC<ProviderConfigTabProps> = ({ provider }) => {
  if (!provider) return null;

  const hasConfig = provider.config && Object.keys(provider.config).length > 0;
  const hasCapabilities = provider.capabilities && Object.keys(provider.capabilities).length > 0;

  return (
    <div className="space-y-6">
      {/* Config */}
      <div>
        <h4 className="font-medium text-theme-primary mb-2">Configuration</h4>
        {hasConfig ? (
          <pre className="bg-theme-background rounded-lg p-4 text-sm text-theme-primary overflow-x-auto border border-theme font-mono">
            {JSON.stringify(provider.config, null, 2)}
          </pre>
        ) : (
          <p className="text-theme-secondary text-sm">No configuration defined</p>
        )}
      </div>

      {/* Capabilities */}
      <div>
        <h4 className="font-medium text-theme-primary mb-2">Capabilities</h4>
        {hasCapabilities ? (
          <pre className="bg-theme-background rounded-lg p-4 text-sm text-theme-primary overflow-x-auto border border-theme font-mono">
            {JSON.stringify(provider.capabilities, null, 2)}
          </pre>
        ) : (
          <p className="text-theme-secondary text-sm">No capabilities defined</p>
        )}
      </div>
    </div>
  );
};

export default ProviderConfigTab;
