import type { CoveredBy } from './StatusBadge';
import type { MigrationStatus } from '../../types/migration.types';
import type { MigrationChainStatus } from '../../types/migrationChain.types';
import type { StorageMigrationStatus } from '../../types/storageMigration.types';
import type { PeerStatus } from '../../types/peer.types';
import type { ChildPeerStatus } from '../../types/spawn.types';
import type { IngressRouteStatus } from '../../services/api/ingressApi';
import type { AcmeCertificateStatus, AcmeDnsCredentialStatus } from '../../types/acme.types';

// Compile-time coverage for the status unions StatusBadge is expected to know.
//
// Each of the twelve replaced maps was a `Record<SomeUnion, string>`, so adding
// a member to a union without extending the map was a compile error at the
// union's own definition. StatusBadge takes `status: string`, which would have
// dropped that coupling entirely and let a new backend status ship rendered
// grey with no failing test to show for it. These assertions restore it.
//
// THIS FILE IS DELIBERATELY NOT A .test.ts. `tsconfig.check.json` excludes
// `**/*.test.ts(x)`, so a type-only assertion written in a spec is never
// checked by anything: jest strips types without checking them and tsc never
// sees the file. Written there, this guard would have been inert — and it was,
// until a review caught that the first version of it also imported three of
// these unions from a module path that does not exist, which nothing noticed
// for exactly the same reason. A plain `.ts` under `src` is compiled whether or
// not anything imports it, which is what makes these fail.
//
// A failure here reads as: Type '["status(es) missing from STATUS_VARIANTS:",
// "the_new_status"]' is not assignable to type 'true'. Add the status to
// STATUS_VARIANTS and to the CASES table in StatusBadge.test.tsx.

const _coversMigration: CoveredBy<MigrationStatus> = true;
const _coversChain: CoveredBy<MigrationChainStatus> = true;
const _coversStorage: CoveredBy<StorageMigrationStatus> = true;
const _coversPeer: CoveredBy<PeerStatus> = true;
const _coversChildPeer: CoveredBy<ChildPeerStatus> = true;
const _coversIngressRoute: CoveredBy<IngressRouteStatus> = true;
const _coversAcmeCertificate: CoveredBy<AcmeCertificateStatus> = true;
const _coversAcmeDnsCredential: CoveredBy<AcmeDnsCredentialStatus> = true;

// Referenced so the declarations are not flagged as unused; the assertion is
// the type annotation, not the value.
export const STATUS_UNION_COVERAGE = [
  _coversMigration,
  _coversChain,
  _coversStorage,
  _coversPeer,
  _coversChildPeer,
  _coversIngressRoute,
  _coversAcmeCertificate,
  _coversAcmeDnsCredential,
] as const;
