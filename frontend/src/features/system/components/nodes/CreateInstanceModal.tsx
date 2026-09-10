import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Cpu, Cloud, Server, Zap, RefreshCw } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { FormField } from '@/shared/components/ui/FormField';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { logger } from '@/shared/utils/logger';
import { systemApi } from '@system/features/system/services/systemApi';
import type {
  SystemNode,
  SystemNodeInstance,
  SystemNodePlatform,
  SystemProviderConnection,
  SystemProviderRegion,
  SystemProviderInstanceType,
  SystemProviderAvailabilityZone,
  SystemProviderNetwork,
  SystemProviderNetworkSubnet
} from '@system/features/system/types/system.types';
import {
  CATALOG_LABELS,
  type CatalogField,
  type CreateInstanceFormData,
  type CreateInstanceFormErrors,
} from './createInstanceHelpers';
import { CreateInstanceCloudFields } from './CreateInstanceCloudFields';
import { CreateInstancePhysicalFields } from './CreateInstancePhysicalFields';
import { CreateInstanceNetworkFields } from './CreateInstanceNetworkFields';

interface CreateInstanceModalProps {
  /** The node to create an instance for */
  node: SystemNode | null;
  /** Whether the modal is open */
  isOpen: boolean;
  /** Callback when modal is closed */
  onClose: () => void;
  /** Callback when instance is created successfully */
  onInstanceCreated?: (instance: SystemNodeInstance) => void;
}

/**
 * CreateInstanceModal - Modal for creating new node instances
 *
 * Provides a form to create instances with name, variety,
 * cloud provider configuration (cascading selects), and IP address settings.
 *
 * C12 (component-status-plane campaign): the cloud cascading-select block,
 * the physical claim-flow block, and the IP address block used to be inline
 * JSX in this file (922 lines total). Split onto section components —
 * CreateInstanceCloudFields, CreateInstancePhysicalFields,
 * CreateInstanceNetworkFields — with the shared form-data/catalog types
 * moved to createInstanceHelpers.ts. This file is now the orchestrator: all
 * cascading-catalog load/retry logic, validation, and submit handling.
 */
export const CreateInstanceModal: React.FC<CreateInstanceModalProps> = ({
  node,
  isOpen,
  onClose,
  onInstanceCreated
}) => {
  const { addNotification } = useNotifications();

  // State
  const [submitting, setSubmitting] = useState(false);
  const [formData, setFormData] = useState<CreateInstanceFormData>({
    name: '',
    variety: 'cloud',
    description: '',
    private_ip_address: '',
    public_ip_address: '',
    vpn_ip_address: '',
    provider_connection_id: '',
    provider_region_id: '',
    provider_instance_type_id: '',
    provider_availability_zone_id: '',
    provider_network_id: '',
    provider_network_subnet_id: '',
    node_platform_id: '',
    mac_address: '',
  });

  // Available platforms for the physical branch (architecture cascades from
  // platform.node_architecture_id; we filter to enabled rows for the
  // operator's account in the platform dropdown).
  const [platforms, setPlatforms] = useState<SystemNodePlatform[]>([]);
  const [loadingPlatforms, setLoadingPlatforms] = useState(false);
  const [errors, setErrors] = useState<CreateInstanceFormErrors>({});

  // Cascading dropdown data
  const [connections, setConnections] = useState<SystemProviderConnection[]>([]);
  const [regions, setRegions] = useState<SystemProviderRegion[]>([]);
  const [instanceTypes, setInstanceTypes] = useState<SystemProviderInstanceType[]>([]);
  const [availabilityZones, setAvailabilityZones] = useState<SystemProviderAvailabilityZone[]>([]);
  const [networks, setNetworks] = useState<SystemProviderNetwork[]>([]);
  const [subnets, setSubnets] = useState<SystemProviderNetworkSubnet[]>([]);

  // Loading states for cascading selects
  const [loadingConnections, setLoadingConnections] = useState(false);
  const [loadingRegions, setLoadingRegions] = useState(false);
  const [loadingInstanceTypes, setLoadingInstanceTypes] = useState(false);
  const [loadingZones, setLoadingZones] = useState(false);
  const [loadingNetworks, setLoadingNetworks] = useState(false);
  const [loadingSubnets, setLoadingSubnets] = useState(false);

  // Which catalogs failed to load.
  const [loadErrors, setLoadErrors] = useState<Partial<Record<CatalogField, true>>>({});
  // The last fetch each catalog ran, so Retry can re-run exactly that one.
  //
  // Deliberately NOT a nonce in the effects' dependency arrays: three of these
  // effects also blank the dependent form fields as a side effect, so retrying
  // "instance sizes" through the effect would wipe the availability zone,
  // network and subnet the operator had already chosen and re-fire all three
  // loads instead of the one they asked for. The thunk is re-registered every
  // time the effect runs, so it can never close over a stale connection.
  const lastLoad = useRef<Partial<Record<CatalogField, () => void>>>({});
  // Per-catalog fetch token. A retry makes concurrent requests for one field
  // routine, and without this a slow rejection from the attempt BEFORE the
  // retry lands afterwards, empties the list the retry just filled and puts the
  // error hint back with nothing in flight.
  const catalogSeq = useRef<Partial<Record<CatalogField, number>>>({});
  // One notification per episode, not one per catalog: selecting a region
  // fires three loads at once, and a provider outage fails all three.
  const notifiedLoadFailure = useRef(false);

  const clearLoadError = useCallback((...fields: CatalogField[]) => {
    setLoadErrors(prev => {
      const next = { ...prev };
      let changed = false;
      for (const field of fields) {
        if (next[field]) {
          delete next[field];
          changed = true;
        }
      }
      return changed ? next : prev;
    });
  }, []);

  /**
   * Runs one catalog fetch with the three things the bare `.catch(() => setX([]))`
   * left out: an inline per-field hint, a logger line, and one notification.
   *
   * The logger gets the message STRING, never the error object: logger.warn
   * JSON.stringifies its context, and an AxiosError's own enumerable properties
   * carry the request config — including the Authorization header.
   */
  const loadCatalog = useCallback(
    <T,>(
      field: CatalogField,
      fetcher: () => Promise<T>,
      onSuccess: (value: T) => void,
      onFailure: () => void,
      setBusy: (busy: boolean) => void
    ) => {
      const run = () => {
        const token = (catalogSeq.current[field] = (catalogSeq.current[field] ?? 0) + 1);
        const isCurrent = () => catalogSeq.current[field] === token;

        setBusy(true);
        clearLoadError(field);

        fetcher()
          .then(value => { if (isCurrent()) onSuccess(value); })
          .catch((error: unknown) => {
            if (!isCurrent()) return;
            onFailure();
            setLoadErrors(prev => ({ ...prev, [field]: true }));
            logger.warn(`CreateInstanceModal: failed to load ${CATALOG_LABELS[field]}`, {
              message: error instanceof Error ? error.message : String(error)
            });
            if (!notifiedLoadFailure.current) {
              notifiedLoadFailure.current = true;
              addNotification({
                type: 'error',
                message: 'Some provisioning options could not be loaded. Retry them below.'
              });
            }
          })
          .finally(() => { if (isCurrent()) setBusy(false); });
      };

      lastLoad.current[field] = run;
      run();
    },
    [addNotification, clearLoadError]
  );

  const retryCatalog = useCallback((field: CatalogField) => {
    // A retry is a deliberate operator action, so a second failure is worth
    // acknowledging rather than swallowing under the first episode's toast.
    notifiedLoadFailure.current = false;
    lastLoad.current[field]?.();
  }, []);

  // Reset form when modal opens
  useEffect(() => {
    if (isOpen && node) {
      setFormData({
        name: `${node.name}-instance-${Date.now().toString(36).slice(-4)}`,
        variety: 'cloud',
        description: '',
        private_ip_address: '',
        public_ip_address: '',
        vpn_ip_address: '',
        provider_connection_id: '',
        provider_region_id: '',
        provider_instance_type_id: '',
        provider_availability_zone_id: '',
        provider_network_id: '',
        provider_network_subnet_id: '',
        node_platform_id: '',
        mac_address: '',
      });
      setErrors({});
      setRegions([]);
      setInstanceTypes([]);
      setAvailabilityZones([]);
      setNetworks([]);
      setSubnets([]);
      setLoadErrors({});
    }
  }, [isOpen, node]);

  // Separate from the form reset above, which is gated on `node`: the
  // connections load only checks `isOpen`, so it can fail — and notify — on a
  // modal opened without one.
  useEffect(() => {
    if (isOpen) {
      notifiedLoadFailure.current = false;
      setLoadErrors({});
    }
  }, [isOpen]);

  // Load platforms when the operator switches to the physical branch.
  useEffect(() => {
    if (isOpen && formData.variety === 'physical' && platforms.length === 0) {
      loadCatalog('platforms', () => systemApi.getPlatforms(), setPlatforms,
        () => setPlatforms([]), setLoadingPlatforms);
    }
  }, [isOpen, formData.variety, platforms.length, loadCatalog]);

  // Load provider connections on modal open
  useEffect(() => {
    if (isOpen && formData.variety === 'cloud') {
      loadCatalog('connections', () => systemApi.getProviderConnections(), setConnections,
        () => setConnections([]), setLoadingConnections);
    }
  }, [isOpen, formData.variety, loadCatalog]);

  // Load regions when connection changes
  useEffect(() => {
    if (formData.provider_connection_id) {
      const connection = connections.find(c => c.id === formData.provider_connection_id);
      const providerId = connection?.provider_id;
      if (providerId) {
        loadCatalog('regions', () => systemApi.getProviderRegions(providerId),
          setRegions, () => setRegions([]), setLoadingRegions);
      }
    } else {
      setRegions([]);
      // No connection means no pending regions load, so a hint left over from
      // the previous one would render a Retry that can never fire.
      clearLoadError('regions');
    }
    // Clear dependent fields
    setFormData(prev => ({
      ...prev,
      provider_region_id: '',
      provider_instance_type_id: '',
      provider_availability_zone_id: '',
      provider_network_id: '',
      provider_network_subnet_id: ''
    }));
    setInstanceTypes([]);
    setAvailabilityZones([]);
    setNetworks([]);
    setSubnets([]);
  }, [formData.provider_connection_id, connections, loadCatalog, clearLoadError]);

  // Load instance types, zones, and networks when region changes
  useEffect(() => {
    if (formData.provider_region_id) {
      const connection = connections.find(c => c.id === formData.provider_connection_id);
      const providerId = connection?.provider_id;
      if (providerId) {
        // Load instance types for provider
        loadCatalog('instanceTypes',
          () => systemApi.getProviderInstanceTypes(providerId),
          setInstanceTypes, () => setInstanceTypes([]), setLoadingInstanceTypes);

        // Load availability zones for region
        loadCatalog('zones',
          () => systemApi.getProviderAvailabilityZones(providerId, formData.provider_region_id),
          setAvailabilityZones, () => setAvailabilityZones([]), setLoadingZones);

        // Load networks for region
        loadCatalog('networks',
          () => systemApi.getNetworks({ provider_region_id: formData.provider_region_id }),
          (result) => setNetworks(result.networks), () => setNetworks([]), setLoadingNetworks);
      }
    } else {
      setInstanceTypes([]);
      setAvailabilityZones([]);
      setNetworks([]);
      clearLoadError('instanceTypes', 'zones', 'networks');
    }
    // Clear dependent fields
    setFormData(prev => ({
      ...prev,
      provider_instance_type_id: '',
      provider_availability_zone_id: '',
      provider_network_id: '',
      provider_network_subnet_id: ''
    }));
    setSubnets([]);
  }, [formData.provider_region_id, formData.provider_connection_id, connections,
      loadCatalog, clearLoadError]);

  // Load subnets when network or zone changes
  useEffect(() => {
    if (formData.provider_network_id) {
      loadCatalog('subnets',
        () => systemApi.getNetworkSubnets(formData.provider_network_id, formData.provider_availability_zone_id || undefined),
        setSubnets, () => setSubnets([]), setLoadingSubnets);
    } else {
      setSubnets([]);
      clearLoadError('subnets');
    }
    setFormData(prev => ({ ...prev, provider_network_subnet_id: '' }));
  }, [formData.provider_network_id, formData.provider_availability_zone_id,
      loadCatalog, clearLoadError]);

  /**
   * The inline per-field hint. Rendered only on a real failure, so an EMPTY
   * catalog still reads as empty rather than broken — telling those two apart
   * is the whole point of the change.
   */
  const renderLoadError = (field: CatalogField) => {
    if (!loadErrors[field]) return null;
    return (
      <p className="mt-1 text-sm text-theme-danger-fg flex items-center gap-2">
        <span>Could not load {CATALOG_LABELS[field]}.</span>
        <button
          type="button"
          onClick={() => retryCatalog(field)}
          aria-label={`Retry loading ${CATALOG_LABELS[field]}`}
          className="inline-flex items-center gap-1 underline hover:no-underline"
        >
          <RefreshCw className="w-3 h-3" />
          Retry
        </button>
      </p>
    );
  };

  // Form validation
  const validate = useCallback((): boolean => {
    const newErrors: CreateInstanceFormErrors = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Name is required';
    } else if (formData.name.length < 3) {
      newErrors.name = 'Name must be at least 3 characters';
    } else if (formData.name.length > 100) {
      newErrors.name = 'Name must be less than 100 characters';
    } else if (!/^[a-zA-Z0-9][a-zA-Z0-9\-_.]*$/.test(formData.name)) {
      newErrors.name = 'Name must start with alphanumeric and contain only letters, numbers, hyphens, underscores, and dots';
    }

    if (!formData.variety) {
      newErrors.variety = 'Instance type is required';
    }

    // Cloud-specific validation
    if (formData.variety === 'cloud') {
      if (!formData.provider_connection_id) {
        newErrors.provider_connection_id = 'Provider connection is required for cloud instances';
      }
      if (!formData.provider_region_id) {
        newErrors.provider_region_id = 'Region is required for cloud instances';
      }
      if (!formData.provider_instance_type_id) {
        newErrors.provider_instance_type_id = 'Instance type is required for cloud instances';
      }
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  }, [formData]);

  // Handle field change
  const handleChange = useCallback((field: keyof CreateInstanceFormData, value: string) => {
    setFormData(prev => ({ ...prev, [field]: value }));
    // Clear error when field is edited
    if (errors[field as keyof CreateInstanceFormErrors]) {
      setErrors(prev => ({ ...prev, [field]: undefined }));
    }
  }, [errors]);

  // Handle form submission
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!validate() || !node) {
      return;
    }

    setSubmitting(true);

    try {
      const instanceData: Parameters<typeof systemApi.createNodeInstance>[1] = {
        name: formData.name.trim(),
        variety: formData.variety,
        private_ip_address: formData.private_ip_address.trim() || undefined,
        public_ip_address: formData.public_ip_address.trim() || undefined,
        vpn_ip_address: formData.vpn_ip_address.trim() || undefined,
        status: 'pending',
        config: {}
      };

      // Add cloud-specific config
      if (formData.variety === 'cloud') {
        instanceData.config = {
          provider_connection_id: formData.provider_connection_id,
          provider_region_id: formData.provider_region_id,
          provider_instance_type_id: formData.provider_instance_type_id,
          provider_availability_zone_id: formData.provider_availability_zone_id || undefined,
          provider_network_id: formData.provider_network_id || undefined,
          provider_network_subnet_id: formData.provider_network_subnet_id || undefined
        };
      }

      const instance = await systemApi.createNodeInstance(node.id, instanceData);

      addNotification({
        type: 'success',
        message: `Instance "${instance.name}" created successfully`
      });

      onInstanceCreated?.(instance);
      onClose();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Failed to create instance';
      addNotification({
        type: 'error',
        message: errorMessage
      });
    } finally {
      setSubmitting(false);
    }
  };

  const varietyIcon = {
    cloud: <Cloud className="w-4 h-4" />,
    physical: <Server className="w-4 h-4" />,
    dynamic: <Zap className="w-4 h-4" />
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Create Instance"
      subtitle={node ? `For node: ${node.name}` : undefined}
      icon={<Cpu className="w-6 h-6" />}
      size="xl"
      footer={
        <div className="flex items-center justify-end gap-3">
          <Button variant="ghost" onClick={onClose} disabled={submitting}>
            Cancel
          </Button>
          <Button
            variant="primary"
            onClick={handleSubmit}
            disabled={submitting}
          >
            {submitting ? 'Creating...' : 'Create Instance'}
          </Button>
        </div>
      }
    >
      <form onSubmit={handleSubmit} className="space-y-6">
        {/* Name Field */}
        <FormField
          label="Name"
          id="instance-name"
          required
          value={formData.name}
          onChange={(v) => handleChange('name', v)}
          placeholder="my-instance-01"
          error={errors.name}
          disabled={submitting}
        />

        {/* Instance Type */}
        <div>
          <label htmlFor="instance-variety" className="block text-sm font-medium text-theme-primary mb-1">
            Instance Type <span className="text-theme-danger-fg">*</span>
          </label>
          <div className="grid grid-cols-3 gap-3">
            {(['cloud', 'physical', 'dynamic'] as const).map((type) => (
              <button
                key={type}
                type="button"
                onClick={() => handleChange('variety', type)}
                className={`
                  flex items-center justify-center gap-2 px-4 py-3 rounded-lg border transition-colors
                  ${formData.variety === type
                    ? 'bg-theme-info-fg text-white border-theme-info-border'
                    : 'bg-theme-surface text-theme-secondary border-theme hover:border-theme-info-border/50'
                  }
                `}
                disabled={submitting}
              >
                {varietyIcon[type]}
                <span className="capitalize">{type}</span>
              </button>
            ))}
          </div>
          {errors.variety && (
            <p className="mt-1 text-sm text-theme-danger-fg">{errors.variety}</p>
          )}
          <p className="mt-2 text-xs text-theme-secondary">
            {formData.variety === 'cloud' && 'Virtual machine hosted in a cloud provider'}
            {formData.variety === 'physical' && 'Physical hardware server'}
            {formData.variety === 'dynamic' && 'Dynamically provisioned instance'}
          </p>
        </div>

        {/* Cloud Provider Configuration - Cascading Selects */}
        {formData.variety === 'cloud' && (
          <CreateInstanceCloudFields
            formData={formData}
            errors={errors}
            submitting={submitting}
            connections={connections}
            regions={regions}
            instanceTypes={instanceTypes}
            availabilityZones={availabilityZones}
            networks={networks}
            subnets={subnets}
            loadingConnections={loadingConnections}
            loadingRegions={loadingRegions}
            loadingInstanceTypes={loadingInstanceTypes}
            loadingZones={loadingZones}
            loadingNetworks={loadingNetworks}
            loadingSubnets={loadingSubnets}
            onChange={handleChange}
            renderLoadError={renderLoadError}
          />
        )}

        {/* Physical Device Configuration (Path C claim flow) */}
        {formData.variety === 'physical' && (
          <CreateInstancePhysicalFields
            formData={formData}
            submitting={submitting}
            platforms={platforms}
            loadingPlatforms={loadingPlatforms}
            onChange={handleChange}
            renderLoadError={renderLoadError}
          />
        )}

        {/* IP Addresses */}
        <CreateInstanceNetworkFields
          formData={formData}
          submitting={submitting}
          onChange={handleChange}
        />
      </form>
    </Modal>
  );
};

export default CreateInstanceModal;
