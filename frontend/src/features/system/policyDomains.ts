import {
  Server,
  Network,
  Container,
  HardDrive,
  Layers,
  ShieldAlert,
  GitBranch,
  Package,
  Boxes,
  Waypoints,
  Database,
  FolderKanban,
  Globe,
  Rocket,
} from 'lucide-react';
import type { PolicyDomainPresentation } from '@/shared/services/featureRegistry';

/**
 * How core's intervention-policy panel presents the policy domains this
 * extension owns — label, icon and blurb per domain key, in section order.
 * Registered in register.ts.
 *
 * PRESENTATION ONLY. Which category belongs to which domain is the server's
 * answer: System::Governance::PolicyDomainTable::PREFIXES, registered with core
 * at boot, is what GET /api/v1/ai/intervention_policies/grouped files rows by.
 * A literal list of categories here drifted once to omit 28 of 119
 * (IMP-0874acd5b50c), so none is kept. A key missing here is cosmetic — core
 * renders it under a humanised label — but every key the table declares has an
 * entry, so none does.
 *
 * ORDER is operator priority (the panel opens on the first entry). It is
 * deliberately NOT the server table's order, which is first-match-wins order
 * for prefix shadowing: that is why the server leads with instance_pool and
 * ends with node_lifecycle, and reading it as a running order would open the
 * panel on Instance Pools.
 */
export const SYSTEM_POLICY_DOMAINS: PolicyDomainPresentation[] = [
  {
    key: 'node_lifecycle',
    label: 'Node Lifecycle',
    icon: Server,
    description: 'Cert rotation, module assignment, instance reboot/reprovision/terminate, fleet-wide upgrades, operator tasks.',
  },
  {
    key: 'sdwan',
    label: 'SDWAN',
    icon: Network,
    description: 'Networks, peers, firewall rules, VIPs, route policies, port mappings, access grants, federation.',
  },
  {
    key: 'topology',
    label: 'Topology Design',
    icon: Waypoints,
    description: 'System Topology Designer compositions: cross-account federation, multi-tenant isolation, service discovery.',
  },
  {
    key: 'container_runtime',
    label: 'Container Runtimes',
    icon: Container,
    description: 'Docker daemon + K3s cluster lifecycle. Node join/drain, runtime upgrades.',
  },
  {
    key: 'disk_image',
    label: 'Disk Image CI',
    icon: HardDrive,
    description: 'Publication promotion, rollback, retention, webhook lifecycle.',
  },
  {
    key: 'instance_pool',
    label: 'Instance Pools',
    icon: Layers,
    description: 'Warm-pool create / update / delete / replenish / drain / acquire.',
  },
  {
    key: 'cve',
    label: 'CVE & Compliance',
    icon: ShieldAlert,
    description: 'SBOM ingest, exposure scan, remediation orchestration, critical-upgrade rollout.',
  },
  {
    key: 'gitops',
    label: 'GitOps',
    icon: GitBranch,
    description: 'Declarative fleet state: repository registration, sync, drift proposals and their application.',
  },
  {
    key: 'packages',
    label: 'Packages',
    icon: Package,
    description: 'Package repository sync and package-backed module create / refresh.',
  },
  {
    key: 'architecture',
    label: 'Architectures',
    icon: Boxes,
    description: 'Reference architecture catalog: propose, create, update, delete.',
  },
  {
    key: 'storage',
    label: 'Storage',
    icon: Database,
    description: 'Volume assignment reconciliation, storage ownership, snapshot deletion and restore.',
  },
  {
    key: 'ingress',
    label: 'Ingress',
    icon: Globe,
    description: 'Service exposure, certificate issuance and service backend sets.',
  },
  {
    key: 'platform',
    label: 'Platform Deployment',
    icon: Rocket,
    description: 'Platform-deployment scaling: the replica reconciler.',
  },
  {
    key: 'project',
    label: 'Project Adaptation',
    icon: FolderKanban,
    description: 'Provisioned-workload evolution: scale, cost control, relocation, schema and security changes.',
  },
];
