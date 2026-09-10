export interface CreateInstanceFormData {
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
export type CatalogField =
  | 'platforms'
  | 'connections'
  | 'regions'
  | 'instanceTypes'
  | 'zones'
  | 'networks'
  | 'subnets';

/** What the inline hint calls each one. */
export const CATALOG_LABELS: Record<CatalogField, string> = {
  platforms: 'platforms',
  connections: 'provider connections',
  regions: 'regions',
  instanceTypes: 'instance sizes',
  zones: 'availability zones',
  networks: 'networks',
  subnets: 'subnets'
};

export interface CreateInstanceFormErrors {
  name?: string;
  variety?: string;
  provider_connection_id?: string;
  provider_region_id?: string;
  provider_instance_type_id?: string;
}
