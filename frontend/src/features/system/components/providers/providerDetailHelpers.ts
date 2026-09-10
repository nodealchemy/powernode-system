import type { ProviderCatalogSummary } from '@system/features/system/services/api/providersApi';

export const providerTypeLabels: Record<string, string> = {
  aws: 'Amazon Web Services',
  openstack: 'OpenStack',
  gcp: 'Google Cloud Platform',
  azure: 'Microsoft Azure',
  digitalocean: 'DigitalOcean',
  custom: 'Custom Provider'
};

const CATALOG_RESOURCE_LABELS: Array<[keyof ProviderCatalogSummary, string]> = [
  ['regions', 'regions'],
  ['availability_zones', 'availability zones'],
  ['instance_types', 'instance types'],
  ['volume_types', 'volume types']
];

/**
 * One-line summary of a catalog sync. Reports the total per resource and, when
 * anything was created, how many of those are new — an operator running this to
 * pick up a newly released instance type wants that number, and "0 new" on a
 * repeat sync is the signal that nothing changed upstream.
 *
 * `total` is absent on the availability-zone phase (synced per region, so the
 * service reports only created/updated); derive it rather than printing NaN.
 */
export function summariseCatalog(catalog: ProviderCatalogSummary): string {
  return CATALOG_RESOURCE_LABELS.map(([key, label]) => {
    const counts = catalog?.[key];
    if (!counts) return `${label} 0`;
    const total = counts.total ?? counts.created + counts.updated;
    return counts.created > 0
      ? `${label} ${total} (${counts.created} new)`
      : `${label} ${total}`;
  }).join(', ');
}
