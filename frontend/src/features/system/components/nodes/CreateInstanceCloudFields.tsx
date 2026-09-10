import React from 'react';
import { Cloud, Loader2 } from 'lucide-react';
import type {
  SystemProviderConnection,
  SystemProviderRegion,
  SystemProviderInstanceType,
  SystemProviderAvailabilityZone,
  SystemProviderNetwork,
  SystemProviderNetworkSubnet
} from '@system/features/system/types/system.types';
import type { CatalogField, CreateInstanceFormData, CreateInstanceFormErrors } from './createInstanceHelpers';

export interface CreateInstanceCloudFieldsProps {
  formData: CreateInstanceFormData;
  errors: CreateInstanceFormErrors;
  submitting: boolean;
  connections: SystemProviderConnection[];
  regions: SystemProviderRegion[];
  instanceTypes: SystemProviderInstanceType[];
  availabilityZones: SystemProviderAvailabilityZone[];
  networks: SystemProviderNetwork[];
  subnets: SystemProviderNetworkSubnet[];
  loadingConnections: boolean;
  loadingRegions: boolean;
  loadingInstanceTypes: boolean;
  loadingZones: boolean;
  loadingNetworks: boolean;
  loadingSubnets: boolean;
  onChange: (field: keyof CreateInstanceFormData, value: string) => void;
  renderLoadError: (field: CatalogField) => React.ReactNode;
}

export const CreateInstanceCloudFields: React.FC<CreateInstanceCloudFieldsProps> = ({
  formData,
  errors,
  submitting,
  connections,
  regions,
  instanceTypes,
  availabilityZones,
  networks,
  subnets,
  loadingConnections,
  loadingRegions,
  loadingInstanceTypes,
  loadingZones,
  loadingNetworks,
  loadingSubnets,
  onChange,
  renderLoadError,
}) => (
  <div className="space-y-4 p-4 bg-theme-background rounded-lg border border-theme">
    <h3 className="text-sm font-medium text-theme-primary flex items-center gap-2">
      <Cloud className="w-4 h-4" />
      Cloud Provider Configuration
    </h3>

    {/* Provider Connection */}
    <div>
      <label htmlFor="provider-connection" className="block text-sm font-medium text-theme-secondary mb-1">
        Provider Connection <span className="text-theme-danger-fg">*</span>
      </label>
      <div className="relative">
        <select
          id="provider-connection"
          value={formData.provider_connection_id}
          onChange={(e) => onChange('provider_connection_id', e.target.value)}
          className={`
            w-full px-3 py-2 rounded-lg border bg-theme-surface text-theme-primary
            focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary
            ${errors.provider_connection_id ? 'border-theme-danger-border' : 'border-theme'}
          `}
          disabled={submitting || loadingConnections}
        >
          <option value="">Select a provider connection...</option>
          {connections.map(conn => (
            <option key={conn.id} value={conn.id}>
              {conn.name} ({conn.provider_name})
            </option>
          ))}
        </select>
        {loadingConnections && (
          <Loader2 className="absolute right-8 top-1/2 -translate-y-1/2 w-4 h-4 animate-spin text-theme-secondary" />
        )}
      </div>
      {renderLoadError('connections')}
      {errors.provider_connection_id && (
        <p className="mt-1 text-sm text-theme-danger-fg">{errors.provider_connection_id}</p>
      )}
    </div>

    {/* Region */}
    <div>
      <label htmlFor="provider-region" className="block text-sm font-medium text-theme-secondary mb-1">
        Region <span className="text-theme-danger-fg">*</span>
      </label>
      <div className="relative">
        <select
          id="provider-region"
          value={formData.provider_region_id}
          onChange={(e) => onChange('provider_region_id', e.target.value)}
          className={`
            w-full px-3 py-2 rounded-lg border bg-theme-surface text-theme-primary
            focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary
            ${errors.provider_region_id ? 'border-theme-danger-border' : 'border-theme'}
          `}
          disabled={submitting || !formData.provider_connection_id || loadingRegions}
        >
          <option value="">Select a region...</option>
          {regions.map(region => (
            <option key={region.id} value={region.id}>
              {region.name} ({region.region_code})
            </option>
          ))}
        </select>
        {loadingRegions && (
          <Loader2 className="absolute right-8 top-1/2 -translate-y-1/2 w-4 h-4 animate-spin text-theme-secondary" />
        )}
      </div>
      {renderLoadError('regions')}
      {errors.provider_region_id && (
        <p className="mt-1 text-sm text-theme-danger-fg">{errors.provider_region_id}</p>
      )}
    </div>

    {/* Instance Type */}
    <div>
      <label htmlFor="provider-instance-type" className="block text-sm font-medium text-theme-secondary mb-1">
        Instance Size <span className="text-theme-danger-fg">*</span>
      </label>
      <div className="relative">
        <select
          id="provider-instance-type"
          value={formData.provider_instance_type_id}
          onChange={(e) => onChange('provider_instance_type_id', e.target.value)}
          className={`
            w-full px-3 py-2 rounded-lg border bg-theme-surface text-theme-primary
            focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary
            ${errors.provider_instance_type_id ? 'border-theme-danger-border' : 'border-theme'}
          `}
          disabled={submitting || !formData.provider_region_id || loadingInstanceTypes}
        >
          <option value="">Select an instance size...</option>
          {instanceTypes.map(type => (
            <option key={type.id} value={type.id}>
              {type.display_name || type.name}
            </option>
          ))}
        </select>
        {loadingInstanceTypes && (
          <Loader2 className="absolute right-8 top-1/2 -translate-y-1/2 w-4 h-4 animate-spin text-theme-secondary" />
        )}
      </div>
      {renderLoadError('instanceTypes')}
      {errors.provider_instance_type_id && (
        <p className="mt-1 text-sm text-theme-danger-fg">{errors.provider_instance_type_id}</p>
      )}
    </div>

    {/* Availability Zone */}
    <div>
      <label htmlFor="availability-zone" className="block text-sm font-medium text-theme-secondary mb-1">
        Availability Zone
      </label>
      <div className="relative">
        <select
          id="availability-zone"
          value={formData.provider_availability_zone_id}
          onChange={(e) => onChange('provider_availability_zone_id', e.target.value)}
          className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary"
          disabled={submitting || !formData.provider_region_id || loadingZones}
        >
          <option value="">Auto-select (any zone)</option>
          {availabilityZones.filter(z => z.operational).map(zone => (
            <option key={zone.id} value={zone.id}>
              {zone.name} ({zone.zone_code}) - {zone.status}
            </option>
          ))}
        </select>
        {loadingZones && (
          <Loader2 className="absolute right-8 top-1/2 -translate-y-1/2 w-4 h-4 animate-spin text-theme-secondary" />
        )}
      </div>
      {renderLoadError('zones')}
    </div>

    {/* Network */}
    <div>
      <label htmlFor="provider-network" className="block text-sm font-medium text-theme-secondary mb-1">
        Network
      </label>
      <div className="relative">
        <select
          id="provider-network"
          value={formData.provider_network_id}
          onChange={(e) => onChange('provider_network_id', e.target.value)}
          className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary"
          disabled={submitting || !formData.provider_region_id || loadingNetworks}
        >
          <option value="">Default network</option>
          {networks.map(network => (
            <option key={network.id} value={network.id}>
              {network.name} ({network.cidr_block})
            </option>
          ))}
        </select>
        {loadingNetworks && (
          <Loader2 className="absolute right-8 top-1/2 -translate-y-1/2 w-4 h-4 animate-spin text-theme-secondary" />
        )}
      </div>
      {renderLoadError('networks')}
    </div>

    {/* Subnet */}
    {formData.provider_network_id && (
      <div>
        <label htmlFor="provider-subnet" className="block text-sm font-medium text-theme-secondary mb-1">
          Subnet
        </label>
        <div className="relative">
          <select
            id="provider-subnet"
            value={formData.provider_network_subnet_id}
            onChange={(e) => onChange('provider_network_subnet_id', e.target.value)}
            className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary"
            disabled={submitting || loadingSubnets}
          >
            <option value="">Auto-select subnet</option>
            {subnets.map(subnet => (
              <option key={subnet.id} value={subnet.id}>
                {subnet.name} ({subnet.cidr_block}) {subnet.is_public ? '(Public)' : '(Private)'}
              </option>
            ))}
          </select>
          {loadingSubnets && (
            <Loader2 className="absolute right-8 top-1/2 -translate-y-1/2 w-4 h-4 animate-spin text-theme-secondary" />
          )}
        </div>
        {renderLoadError('subnets')}
      </div>
    )}
  </div>
);

export default CreateInstanceCloudFields;
