import type { CoveredBy } from './StatusBadge';
import type { MigrationStatus } from '../../types/migration.types';
import type { MigrationChainStatus } from '../../types/migrationChain.types';
import type { StorageMigrationStatus } from '../../types/storageMigration.types';
import type { PeerStatus } from '../../types/peer.types';
import type { ChildPeerStatus } from '../../types/spawn.types';
import type { IngressRouteStatus } from '../../services/api/ingressApi';
import type { AcmeCertificateStatus, AcmeDnsCredentialStatus } from '../../types/acme.types';
import type { Verdict } from '@/shared/types/platformStatus';

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

// The component status plane's six verdicts (design §4.1), which this
// extension renders wherever a fleet surface shows a component's status.
//
// THE TYPE COMES FROM CORE, THE COLOURS DO NOT. Extensions may depend on core;
// core may never depend on an extension. So importing core's `Verdict` union is
// allowed and is strictly better than restating the six strings here: a copy
// would go stale the moment core adds a seventh verdict, and this assertion —
// whose entire job is to notice that — would keep passing. What stays
// extension-side is the MAPPING: StatusBadge's vocabulary is this extension's,
// its table imports eight extension unions above, and core must not take a
// dependency on any of it. Hence the type import and nothing else; core's
// VerdictBadge component is deliberately not imported here.
//
// A verdict added to core's ladder without an entry in STATUS_VARIANTS fails
// HERE, at extension tsc, naming the verdict.
const _coversPlatformVerdict: CoveredBy<Verdict> = true;

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
  _coversPlatformVerdict,
] as const;
