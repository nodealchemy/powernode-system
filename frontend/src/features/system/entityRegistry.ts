// System entity registry — wires the CORE entity-reference infra
// (`@/shared/services/entityRegistry`) to the system extension's objects.
//
// The core registry is owner-keyed (mirrors `featureRegistry`): the system
// extension registers its own types under the "system" owner; core stays
// ignorant of them. `<EntityLink>` / `<EntityReferenceHost>` (mounted once in
// DashboardLayout) then resolve a `type` and render one of three modes:
//
//   1. id modal     — `component` + `idProp`                  → bespoke modal self-fetches by id
//   2. object modal  — `component` + `objectProp` + `fetchById` → host fetches, passes the object
//   3. generic       — `fetchById` only                        → field-driven EntityDetailModal
//
// Every registered type traces to a verified bespoke modal export and/or a
// verified `*Api` read method. Entries whose getById does not exist are
// intentionally omitted — `EntityLink` degrades to plain text for unknown
// types, so omission is safe (see the OMISSIONS note at the bottom).
import type { ComponentType } from 'react';
import { entityRegistry, type EntityDefinition } from '@/shared/services/entityRegistry';

// Bespoke (id-prop) detail modals — confirmed named exports, each taking a
// single id prop and self-fetching.
import { NodeDetailModal } from '@system/features/system/components/nodes/NodeDetailModal';
import { TemplateDetailModal } from '@system/features/system/components/templates/TemplateDetailModal';
import { ModuleDetailModal } from '@system/features/system/components/modules/ModuleDetailModal';
import { NetworkDetailModal as ProviderNetworkDetailModal } from '@system/features/system/components/networks/NetworkDetailModal';
import { VolumeDetailModal } from '@system/features/system/components/volumes/VolumeDetailModal';
import { OperationDetailModal } from '@system/features/system/components/operations/OperationDetailModal';
// Object-prop modal — takes a fully-loaded SdwanNetwork (not an id).
import { NetworkDetailModal as SdwanNetworkDetailModal } from '@system/features/system/components/sdwan/NetworkDetailModal';

// Read APIs (generic + object modes). Each method below is verified to exist.
import { nodesApi } from '@system/features/system/services/api/nodesApi';
import { platformsApi } from '@system/features/system/services/api/platformsApi';
import { architecturesApi } from '@system/features/system/services/api/architecturesApi';
import { modulesApi } from '@system/features/system/services/api/modulesApi';
import { providersApi } from '@system/features/system/services/api/providersApi';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import { acmeCertificatesApi } from '@system/features/system/services/api/acmeCertificatesApi';
import { acmeDnsCredentialsApi } from '@system/features/system/services/api/acmeDnsCredentialsApi';
import { ciWorkersApi } from '@system/features/system/services/api/ciWorkersApi';
import { cveApi } from '@system/features/system/services/api/cveApi';
import { gitopsApi } from '@system/features/system/services/api/gitopsApi';
import { storageMigrationsApi } from '@system/features/system/services/api/storageMigrationsApi';
import { platformPeersApi } from '@system/features/system/services/api/platformPeersApi';

// The registry stores every component in a single typed slot
// (`ComponentType<Record<string, unknown>>`). Each modal was authored as a
// distinct `FC<P>` and `FC<P>` doesn't satisfy `FC<Record<string, unknown>>`
// under React's strict prop variance — so widen here, once, instead of `any`.
// The host injects only the props each modal declares (`idProp`/`objectProp`
// + `isOpen`/`onClose`), so the widening is sound at the call boundary.
type EntityModal = EntityDefinition['component'];
const asModal = (component: ComponentType<never>): EntityModal =>
  component as unknown as ComponentType<Record<string, unknown>>;

// Split a composite EntityLink id (e.g. "nodeId:instanceId") into its parts.
// Returns `undefined` when the id is malformed so callers can fail the fetch
// loudly rather than issue a request with empty path segments.
function splitCompositeId(id: string, parts: number): string[] | undefined {
  const segments = id.split(':');
  if (segments.length !== parts || segments.some((s) => s.length === 0)) {
    return undefined;
  }
  return segments;
}

/**
 * Register every system object type with the core entity registry.
 * Idempotent at the call site (re-registration overwrites by type), but the
 * extension calls it exactly once from `register()`.
 */
export function registerSystemEntities(): void {
  entityRegistry.registerEntities('system', [
    // ---- Mode 1: bespoke id-prop modals (self-fetch) ----
    {
      type: 'node',
      label: 'Node',
      permission: 'system.nodes.read',
      icon: 'Server',
      component: asModal(NodeDetailModal),
      idProp: 'nodeId',
    },
    {
      type: 'node_template',
      label: 'Template',
      permission: 'system.templates.read',
      icon: 'LayoutTemplate',
      component: asModal(TemplateDetailModal),
      idProp: 'templateId',
    },
    {
      type: 'node_module',
      label: 'Module',
      permission: 'system.modules.read',
      icon: 'Package',
      component: asModal(ModuleDetailModal),
      idProp: 'moduleId',
    },
    {
      type: 'provider_network',
      label: 'Provider Network',
      permission: 'system.networks.read',
      icon: 'Network',
      component: asModal(ProviderNetworkDetailModal),
      idProp: 'networkId',
    },
    {
      type: 'provider_volume',
      label: 'Volume',
      permission: 'system.volumes.read',
      icon: 'HardDrive',
      component: asModal(VolumeDetailModal),
      idProp: 'volumeId',
    },
    {
      type: 'system_task',
      label: 'Operation',
      permission: 'system.infra_tasks.read',
      icon: 'Activity',
      component: asModal(OperationDetailModal),
      idProp: 'operationId',
    },

    // ---- Mode 2: object-prop modal (host fetches, passes the object) ----
    {
      type: 'sdwan_network',
      label: 'SDWAN Network',
      permission: 'sdwan.networks.read',
      icon: 'ShieldCheck',
      component: asModal(SdwanNetworkDetailModal),
      objectProp: 'network',
      fetchById: (id: string) => sdwanApi.getNetwork(id),
    },

    // ---- Mode 3: generic field-driven modal (fetchById only) ----
    {
      type: 'node_platform',
      label: 'Platform',
      permission: 'system.platforms.read',
      icon: 'Cpu',
      labelField: 'name',
      fetchById: (id: string) => platformsApi.getPlatform(id),
    },
    {
      type: 'node_architecture',
      label: 'Architecture',
      permission: 'system.architectures.read',
      icon: 'Cpu',
      labelField: 'name',
      fetchById: (id: string) => architecturesApi.getArchitecture(id),
    },
    {
      type: 'node_module_category',
      label: 'Module Category',
      permission: 'system.modules.read',
      icon: 'FolderTree',
      labelField: 'name',
      fetchById: (id: string) => modulesApi.getModuleCategory(id),
    },
    {
      type: 'provider',
      label: 'Provider',
      permission: 'system.providers.read',
      icon: 'Cloud',
      labelField: 'name',
      fetchById: (id: string) => providersApi.getProvider(id),
    },
    {
      // Composite id "nodeId:instanceId" — the instance route is nested under
      // its node, so both segments are required to fetch.
      type: 'node_instance',
      label: 'Instance',
      permission: 'system.node_instances.read',
      icon: 'Box',
      labelField: 'name',
      fetchById: (id: string) => {
        const parts = splitCompositeId(id, 2);
        if (!parts) {
          return Promise.reject(
            new Error(`node_instance id must be "nodeId:instanceId" (got "${id}")`),
          );
        }
        const [nodeId, instanceId] = parts;
        return nodesApi.getNodeInstance(nodeId, instanceId);
      },
    },
    {
      // ACME certs are gated by authentication only (no resource-level read
      // permission on index/show), so no `permission` is set — backend enforces auth.
      type: 'acme_certificate',
      label: 'Certificate',
      icon: 'BadgeCheck',
      labelField: 'common_name',
      fetchById: (id: string) => acmeCertificatesApi.get(id),
    },
    {
      // ACME DNS credentials are gated by authentication only (no resource-level
      // read permission on index/show), so no `permission` is set here.
      type: 'acme_dns_credential',
      label: 'DNS Credential',
      icon: 'KeyRound',
      labelField: 'name',
      fetchById: (id: string) => acmeDnsCredentialsApi.get(id),
    },
    {
      type: 'ci_worker',
      label: 'CI Worker',
      permission: 'system.ci_workers.read',
      icon: 'Wrench',
      labelField: 'name',
      fetchById: (id: string) => ciWorkersApi.get(id),
    },
    {
      // CveExposure has no `name`; `package_name` is the operator-facing label.
      type: 'cve',
      label: 'CVE Exposure',
      permission: 'system.cve.read',
      icon: 'ShieldAlert',
      labelField: 'package_name',
      fetchById: (id: string) => cveApi.get(id),
    },
    {
      // `gitopsApi.get` returns `{ gitops_repository, recent_runs }`. The
      // generic modal reads top-level scalars, so unwrap to the repository row
      // (with its `name`) — otherwise the field dump would be empty.
      type: 'gitops_repository',
      label: 'GitOps Repository',
      permission: 'system.gitops.read',
      icon: 'GitBranch',
      labelField: 'name',
      fetchById: (id: string) => gitopsApi.get(id).then((r) => r.gitops_repository),
    },
    {
      // No `name` on a migration; `role` is the most descriptive scalar label.
      // Reads are gated by authentication only, so no `permission` is set.
      type: 'storage_migration',
      label: 'Storage Migration',
      icon: 'DatabaseBackup',
      labelField: 'role',
      fetchById: (id: string) => storageMigrationsApi.get(id),
    },
    {
      // No `name` on a peer; the remote URL identifies it.
      type: 'platform_peer',
      label: 'Platform Peer',
      permission: 'system.peers.read',
      icon: 'Share2',
      labelField: 'remote_instance_url',
      fetchById: (id: string) => platformPeersApi.getPeer(id),
    },

    // ---- Mode 3: SDWAN sub-resources (domain-scoped read permissions) ----
    {
      type: 'sdwan_host_bridge',
      label: 'Host Bridge',
      permission: 'sdwan.host_bridges.read',
      icon: 'Cable',
      labelField: 'bridge_name',
      fetchById: (id: string) => sdwanApi.getHostBridge(id),
    },
    {
      // `getOvnDeployment` returns `{ deployment, compiled_plan }`; unwrap to
      // the deployment row so the generic modal has scalar fields to render.
      type: 'sdwan_ovn_deployment',
      label: 'OVN Deployment',
      permission: 'sdwan.ovn.read',
      icon: 'Boxes',
      labelField: 'status',
      fetchById: (id: string) => sdwanApi.getOvnDeployment(id).then((r) => r.deployment),
    },
    {
      type: 'sdwan_ipfix_collector',
      label: 'IPFIX Collector',
      permission: 'sdwan.ipfix.read',
      icon: 'Radar',
      labelField: 'name',
      fetchById: (id: string) => sdwanApi.getIpfixCollector(id),
    },
    {
      // Composite id "networkId:vipId" — the VIP route is nested under its
      // network, so both segments are required.
      type: 'sdwan_virtual_ip',
      label: 'Virtual IP',
      permission: 'sdwan.vips.read',
      icon: 'Globe',
      labelField: 'name',
      fetchById: (id: string) => {
        const parts = splitCompositeId(id, 2);
        if (!parts) {
          return Promise.reject(
            new Error(`sdwan_virtual_ip id must be "networkId:vipId" (got "${id}")`),
          );
        }
        const [networkId, vipId] = parts;
        return sdwanApi.getVirtualIp(networkId, vipId);
      },
    },
    {
      // Verified: route policies are addressed by a single id at
      // `/sdwan/route_policies/:id` — NOT a network-nested composite.
      type: 'sdwan_route_policy',
      label: 'Route Policy',
      permission: 'sdwan.route_policies.read',
      icon: 'Route',
      labelField: 'name',
      fetchById: (id: string) => sdwanApi.getRoutePolicy(id),
    },
  ]);
}

/**
 * Map a backend Task `operable_type` to a registered entity `type`.
 *
 * Tasks reference their subject via a polymorphic `operable_type`, which may
 * arrive either as the Rails class name ("System::Node") or as an
 * already-normalized short form ("node"). This normalizes both shapes to the
 * registry key so a task row can render its subject as an `<EntityLink>`.
 *
 * Returns `undefined` for types with no registered entity (the caller then
 * renders plain text).
 */
export function resolveOperableType(operableType: string): string | undefined {
  if (!operableType) return undefined;

  // Normalize "System::Node" / "Sdwan::Network" → "node" / "network": take the
  // last namespace segment, strip the leading domain prefix the registry omits,
  // then snake_case it. Already-short forms pass through this unchanged.
  const lastSegment = operableType.split('::').pop() ?? operableType;
  const snake = lastSegment
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
    .toLowerCase();

  // Canonical operable_type → registry type. Covers both the class-derived
  // snake form and any backend short form / alias that differs from the
  // registry key.
  const MAP: Record<string, string> = {
    // Node lifecycle
    node: 'node',
    // node_instance is intentionally omitted: its registry fetcher needs a
    // composite id ("nodeId:instanceId") that a task's single operable_id cannot
    // supply, so an instance operable renders as plain text instead of a link.
    node_module: 'node_module',
    module: 'node_module',
    node_template: 'node_template',
    template: 'node_template',
    node_platform: 'node_platform',
    platform: 'node_platform',
    node_architecture: 'node_architecture',
    architecture: 'node_architecture',
    // Providers
    provider: 'provider',
    provider_network: 'provider_network',
    network: 'provider_network',
    provider_volume: 'provider_volume',
    volume: 'provider_volume',
    // Tasks
    task: 'system_task',
    system_task: 'system_task',
    // SDWAN — `Sdwan::Network` collapses to `network`, which the provider
    // network already claims; SDWAN networks are keyed explicitly instead.
    sdwan_network: 'sdwan_network',
    sdwan_host_bridge: 'sdwan_host_bridge',
    host_bridge: 'sdwan_host_bridge',
    sdwan_ovn_deployment: 'sdwan_ovn_deployment',
    ovn_deployment: 'sdwan_ovn_deployment',
    sdwan_ipfix_collector: 'sdwan_ipfix_collector',
    ipfix_collector: 'sdwan_ipfix_collector',
    // sdwan_virtual_ip omitted here too — its fetcher also needs a composite
    // "networkId:vipId" id that a single operable_id cannot supply.
    sdwan_route_policy: 'sdwan_route_policy',
    route_policy: 'sdwan_route_policy',
  };

  return MAP[snake];
}
