import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Cpu, Cloud, Server, Zap, Loader2, RefreshCw } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { EntityLink } from '@/shared/components/entity';
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

interface FormData {
  name: string;
  variety: 'cloud' | 'physical' | 'dynamic';
  description: string;
  private_ip_address: string;
  public_ip_address: string;
  vpn_ip_address: string;
  // Cloud-specific fields
  provider_connection_id: string;
  provider_region_id: string;
  provider_instance_type_id: string;
  provider_availability_zone_id: string;
  provider_network_id: string;
  provider_network_subnet_id: string;
  // Physical-specific fields (Path C claim flow)
  // Plan: docs/plans/wondrous-yawning-anchor.md
  node_platform_id: string;
  mac_address: string;            // optional pre-binding for known devices
}

/**
 * The catalogs this form loads. Each one is a cascading select, and each used
 * to end in `.catch(() => setX([]))` — so a dead provider connection, a 403 or
 * a network blip rendered exactly like an empty catalog and the operator was
 * left with "no regions" and no diagnosis (IMP-a78aa727d1d8).
 */
type CatalogField =
  | 'platforms'
  | 'connections'
  | 'regions'
  | 'instanceTypes'
  | 'zones'
  | 'networks'
  | 'subnets';

/** What the inline hint calls each one. */
const CATALOG_LABELS: Record<CatalogField, string> = {
  platforms: 'platforms',
  connections: 'provider connections',
  regions: 'regions',
  instanceTypes: 'instance sizes',
  zones: 'availability zones',
  networks: 'networks',
  subnets: 'subnets'
};

interface FormErrors {
  name?: string;
  variety?: string;
  provider_connection_id?: string;
  provider_region_id?: string;
  provider_instance_type_id?: string;
}

/**
 * CreateInstanceModal - Modal for creating new node instances
 *
 * Provides a form to create instances with name, variety,
 * cloud provider configuration (cascading selects), and IP address settings.
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
  const [formData, setFormData] = useState<FormData>({
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
  const [errors, setErrors] = useState<FormErrors>({});

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
    const newErrors: FormErrors = {};

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
  const handleChange = useCallback((field: keyof FormData, value: string) => {
    setFormData(prev => ({ ...prev, [field]: value }));
    // Clear error when field is edited
    if (errors[field as keyof FormErrors]) {
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
        <div>
          <label htmlFor="instance-name" className="block text-sm font-medium text-theme-primary mb-1">
            Name <span className="text-theme-danger-fg">*</span>
          </label>
          <input
            id="instance-name"
            type="text"
            value={formData.name}
            onChange={(e) => handleChange('name', e.target.value)}
            placeholder="my-instance-01"
            className={`
              w-full px-3 py-2 rounded-lg border bg-theme-surface text-theme-primary
              placeholder-theme-secondary focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary
              ${errors.name ? 'border-theme-danger-border' : 'border-theme'}
            `}
            disabled={submitting}
          />
          {errors.name && (
            <p className="mt-1 text-sm text-theme-danger-fg">{errors.name}</p>
          )}
        </div>

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
                  onChange={(e) => handleChange('provider_connection_id', e.target.value)}
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
                  onChange={(e) => handleChange('provider_region_id', e.target.value)}
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
                  onChange={(e) => handleChange('provider_instance_type_id', e.target.value)}
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
                  onChange={(e) => handleChange('provider_availability_zone_id', e.target.value)}
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
                  onChange={(e) => handleChange('provider_network_id', e.target.value)}
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
                    onChange={(e) => handleChange('provider_network_subnet_id', e.target.value)}
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
        )}

        {/* Physical Device Configuration (Path C claim flow) */}
        {/* Plan: docs/plans/wondrous-yawning-anchor.md */}
        {formData.variety === 'physical' && (
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
                  onChange={(e) => handleChange('node_platform_id', e.target.value)}
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
                onChange={(e) => handleChange('mac_address', e.target.value)}
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
                onChange={(e) => handleChange('description', e.target.value)}
                placeholder="e.g. Pi 4 in network closet rack 2"
                className="w-full px-3 py-2 rounded-lg border bg-theme-surface text-theme-primary
                  focus:outline-none focus:ring-2 focus:ring-theme-interactive-primary border-theme"
                disabled={submitting}
              />
            </div>
          </div>
        )}

        {/* IP Addresses */}
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
                onChange={(e) => handleChange('private_ip_address', e.target.value)}
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
                onChange={(e) => handleChange('public_ip_address', e.target.value)}
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
                onChange={(e) => handleChange('vpn_ip_address', e.target.value)}
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
      </form>
    </Modal>
  );
};

export default CreateInstanceModal;
