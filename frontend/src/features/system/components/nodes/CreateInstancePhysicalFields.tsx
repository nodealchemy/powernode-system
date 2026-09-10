import React from 'react';
import { Server, Loader2 } from 'lucide-react';
import { EntityLink } from '@/shared/components/entity';
import type { SystemNodePlatform } from '@system/features/system/types/system.types';
import type { CatalogField, CreateInstanceFormData } from './createInstanceHelpers';

export interface CreateInstancePhysicalFieldsProps {
  formData: CreateInstanceFormData;
  submitting: boolean;
  platforms: SystemNodePlatform[];
  loadingPlatforms: boolean;
  onChange: (field: keyof CreateInstanceFormData, value: string) => void;
  renderLoadError: (field: CatalogField) => React.ReactNode;
}

/** Physical Device Configuration (Path C claim flow). Plan: docs/plans/wondrous-yawning-anchor.md */
export const CreateInstancePhysicalFields: React.FC<CreateInstancePhysicalFieldsProps> = ({
  formData,
  submitting,
  platforms,
  loadingPlatforms,
  onChange,
  renderLoadError,
}) => (
  <div className="space-y-4 p-4 bg-theme-background rounded-lg border border-theme">
    <h3 className="text-sm font-medium text-theme-primary flex items-center gap-2">
      <Server className="w-4 h-4" />
      Physical Device Configuration
    </h3>
    <p className="text-xs text-theme-secondary">
      The instance will be created in a pending state. Flash the platform&apos;s
      disk image onto an SD card / USB stick and plug the device in — it will
      poll the platform and surface in the &ldquo;Unclaimed Devices&rdquo; panel for you to
      claim.
    </p>

    <div>
      <label htmlFor="instance-platform" className="block text-sm font-medium text-theme-secondary mb-1">
        Platform <span className="text-theme-danger-fg">*</span>
      </label>
      <div className="relative">
        <select
          id="instance-platform"
          value={formData.node_platform_id}
          onChange={(e) => onChange('node_platform_id', e.target.value)}
          className="w-full px-3 py-2 rounded-lg border bg-theme-surface text-theme-primary
            focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary border-theme"
          disabled={submitting || loadingPlatforms}
        >
          <option value="">Select a platform...</option>
          {platforms.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}{p.architecture_name ? ` (${p.architecture_name})` : ''}
            </option>
          ))}
        </select>
        {loadingPlatforms && (
          <Loader2 className="absolute right-8 top-1/2 -translate-y-1/2 w-4 h-4 animate-spin text-theme-secondary" />
        )}
      </div>
      {renderLoadError('platforms')}
      {formData.node_platform_id && (
        <div className="mt-1">
          <EntityLink
            type="node_platform"
            id={formData.node_platform_id}
            label="View platform details"
            className="text-xs"
          />
        </div>
      )}
      <p className="mt-1 text-xs text-theme-tertiary">
        Determines which generic disk image to flash. RPi 4 → ubuntu-24.04-rpi4;
        generic UEFI arm64 SBC → ubuntu-24.04-arm64-uefi.
      </p>
    </div>

    <div>
      <label htmlFor="instance-mac" className="block text-sm font-medium text-theme-secondary mb-1">
        MAC address (optional pre-binding)
      </label>
      <input
        id="instance-mac"
        type="text"
        value={formData.mac_address}
        onChange={(e) => onChange('mac_address', e.target.value)}
        placeholder="aa:bb:cc:dd:ee:ff"
        className="w-full px-3 py-2 rounded-lg border bg-theme-surface text-theme-primary font-mono
          focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary border-theme"
        disabled={submitting}
      />
      <p className="mt-1 text-xs text-theme-tertiary">
        Leave blank for the standard claim flow (operator confirms in Unclaimed Devices
        panel). If you know the device&apos;s MAC, set it here for deterministic auto-binding.
      </p>
    </div>

    <div>
      <label htmlFor="instance-description" className="block text-sm font-medium text-theme-secondary mb-1">
        Description / notes
      </label>
      <input
        id="instance-description"
        type="text"
        value={formData.description}
        onChange={(e) => onChange('description', e.target.value)}
        placeholder="e.g. Pi 4 in network closet rack 2"
        className="w-full px-3 py-2 rounded-lg border bg-theme-surface text-theme-primary
          focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary border-theme"
        disabled={submitting}
      />
    </div>
  </div>
);

export default CreateInstancePhysicalFields;
