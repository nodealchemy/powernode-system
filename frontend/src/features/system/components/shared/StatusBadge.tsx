import React from 'react';
import { Badge } from '@/shared/components/ui/Badge';

// StatusBadge — the single status→style mapping for the System extension.
//
// It replaces twelve independent maps written in two incompatible idioms:
// seven mapped a status to a core Badge variant, and five mapped it to raw
// `bg-theme-*-bg text-theme-*-fg` pill classes at three different paddings
// (px-2 py-0.5, px-3 py-1, px-1.5 py-0.5). The visible cost was that the same
// status word was coloured and sized differently between adjacent tabs, and
// the maintenance cost was that any change to the scheme had to be made twelve
// times.
//
// WHAT THIS CHANGES VISUALLY, beyond the per-status colours resolved below.
// The replaced raw pills were TINTED chips — `bg-theme-*-bg` behind
// `text-theme-*-fg` — with square-ish corners and no border. Core's Badge
// renders a solid saturated fill with white text, fully-rounded corners, and a
// border on the secondary variant. That restyle applies at every call site,
// not only where a colour word changed, and it is the direct consequence of
// wrapping the core Badge rather than reimplementing a chip.
//
// Core's shared statusHelpers.ts is deliberately NOT the home for this: it
// covers invoice, customer and subscription states only, and core must never
// take a dependency on an extension's vocabulary. So this lives extension-side
// and wraps the core Badge rather than reimplementing it.
//
// Adding a status: add it to STATUS_VARIANTS and to the table in the spec.
// The spec asserts the two are EQUAL, so neither can drift from the other.

export type BadgeVariant = NonNullable<React.ComponentProps<typeof Badge>['variant']>;
export type StatusBadgeSize = NonNullable<React.ComponentProps<typeof Badge>['size']>;

/**
 * Every status the replaced maps knew about.
 *
 * Where those maps DISAGREED about the same word, the resolution is recorded
 * on the entry. Those are deliberate changes to what an operator sees, not
 * transcription, and each is repeated in the spec so the reasoning is visible
 * from either side.
 */
export const STATUS_VARIANTS = {
  // Terminal success — the thing is doing its job.
  available: 'success',
  active: 'success',
  complete: 'success',
  success: 'success',
  published: 'success',
  completed: 'success',
  valid: 'success',
  ok: 'success',
  idle: 'success',

  // In flight, or purely informational.
  'in-use': 'info',
  scheduled: 'info',
  registered: 'info',
  bootstrapping: 'info',
  paused: 'info',
  // OPERATOR INTENT — cordoned, paused, drained, on hold. The component status
  // plane's `held` verdict (design §4.1), which rev 1 of that design called
  // `suspended` before noticing that `suspended` already lives four rows down
  // in this very table meaning "needs attention", with the opposite polarity.
  // It sits beside `paused` because that is the same concept under an older
  // name. It is emphatically NOT amber: a planned drain that renders as a
  // problem teaches an operator to ignore amber.
  held: 'info',
  // PeerStatusPill rendered `proposed` grey and sdwan/FederationPeerList
  // rendered it info. It is an opening move rather than a null state, so info.
  proposed: 'info',
  // PeerStatusPill said info, sdwan/FederationPeerList said success. It is an
  // intermediate step before active, so info — success stays reserved for
  // states that are actually serving.
  accepted: 'info',
  // Same reasoning as `accepted`, and both deleted maps agreed on info: an
  // enrolled peer has completed enrolment but is not yet serving. Rendering it
  // green made it indistinguishable from `active`.
  enrolled: 'info',
  validating: 'info',
  transferring: 'info',
  applying: 'info',
  in_flight: 'info',
  approved: 'info',
  preparing: 'info',
  // ingress/IngressRoutesPanel rendered issuing and renewing amber; the two acme
  // panels rendered them blue. They are work in progress on a healthy cert, so
  // info — warning is reserved for something the operator may need to act on.
  issuing: 'info',
  renewing: 'info',
  running: 'primary',
  // An in-flight remediation or provisioning (design §4.1). Beside `running`
  // and for the same reason: it is work actually happening, not a queue
  // position, and the saturated fill is what separates the two from the pale
  // informational states above.
  progressing: 'primary',

  // Needs attention, not yet broken.
  // Four maps said warning; sdwan/PeerList said info and
  // sdwan_hub/OvnDeploymentsTab said secondary. Warning wins on both weight of
  // use and meaning.
  pending: 'warning',
  creating: 'warning',
  deleting: 'warning',
  dispatched: 'warning',
  awaiting_signature: 'warning',
  awaiting_upload: 'warning',
  publishing: 'warning',
  verifying: 'warning',
  queued: 'warning',
  partial: 'warning',
  suspended: 'warning',
  failing_over: 'warning',
  draining: 'warning',
  conflict: 'warning',
  syncing: 'warning',
  cutover: 'warning',
  deprecated: 'warning',
  expired: 'warning',
  // PeerStatusPill said warning, sdwan_hub/OvnDeploymentsTab said danger.
  // Degraded is serving-but-impaired, which is not the same as down.
  degraded: 'warning',

  // Broken.
  error: 'danger',
  failed: 'danger',
  revoked: 'danger',
  disconnected: 'danger',
  retired: 'danger',
  down: 'danger',
  invalid: 'danger',

  // Inert — no longer acting, and not a failure.
  deleted: 'secondary',
  aborted: 'secondary',
  cancelled: 'secondary',
  archived: 'secondary',
  unassigned: 'secondary',
  planned: 'secondary',
  draft: 'secondary',
  unknown: 'secondary',
  removed: 'secondary',
  untested: 'secondary',
  disabled: 'secondary',

  // Drafted, not yet acting.
  planning: 'outline',

  // AN ABSENT MEASUREMENT (design §4.1) — the sweep could not obtain a
  // reading. It is NOT `unknown` two blocks up, and the difference is the
  // whole point: `unknown` is an inert grey for a value nobody needs, while
  // `not_measured` is a gap an operator should close, ranking above
  // `progressing` on the verdict ladder for exactly that reason. Filed grey it
  // would sit among `deleted`, `archived` and `disabled` and never be looked
  // at. It shares `outline` with core's VerdictBadge, so the same verdict
  // reads the same on the status page and on a fleet tab; the two tables are
  // separate on purpose (this one must not import core's status vocabulary,
  // and core must not learn this one's), which is what makes the agreement
  // worth stating here rather than assuming.
  not_measured: 'outline',
} as const satisfies Record<string, BadgeVariant>;

/** Every status this table knows. */
export type KnownStatus = keyof typeof STATUS_VARIANTS;

/**
 * Compile-time coverage assertion for a domain's status union.
 *
 * Each replaced map was a `Record<SomeUnion, string>`, so adding a member to
 * the union without extending the map was a compile error. Taking `status:
 * string` here would have dropped that coupling entirely and let a new backend
 * status ship rendered grey, with no failing test to show for it. The spec
 * declares one of these per union that is still growing, which restores the
 * error at the same place — the union's own definition — without duplicating
 * the colours.
 */
export type CoveredBy<T extends string> = Exclude<T, KnownStatus> extends never
  ? true
  : ['status(es) missing from STATUS_VARIANTS:', Exclude<T, KnownStatus>];

/**
 * Variant for a status string.
 *
 * Case-insensitive: these values arrive from several backends and from
 * agent-reported state, which do not agree on casing. Unknown statuses fall
 * back to `secondary` rather than throwing — a status this table has not seen
 * yet is a gap in the table, and blanking a row over it would hide the very
 * value that reveals the gap.
 */
export function statusVariant(status: string | null | undefined): BadgeVariant {
  if (!status) return 'secondary';
  // The table is `as const` so that KnownStatus is the literal union rather
  // than `string`; that is what makes CoveredBy able to name a missing status.
  // The lookup itself takes an arbitrary string, hence the widening here.
  const table: Record<string, BadgeVariant> = STATUS_VARIANTS;
  return table[status.toLowerCase()] ?? 'secondary';
}

export interface StatusBadgeProps {
  /** Raw status from the API. Rendered as the label unless `label` is given. */
  status: string | null | undefined;
  /** Human-facing text, when the raw value is not what an operator should read. */
  label?: React.ReactNode;
  size?: StatusBadgeSize;
  /** Leading dot, for the in-flight states that used one before. */
  dot?: boolean;
  /** Pulses the dot. Only meaningful with `dot`. */
  pulse?: boolean;
  icon?: React.ReactNode;
  className?: string;
}

export const StatusBadge: React.FC<StatusBadgeProps> = ({
  status,
  label,
  size = 'sm',
  dot = false,
  pulse = false,
  icon,
  className,
}) => {
  // An absent status renders nothing at all. An empty coloured pill reads as a
  // state the backend actually reported, which is worse than no pill.
  if (!status && !label) return null;

  return (
    <Badge
      variant={statusVariant(status)}
      size={size}
      dot={dot}
      pulse={pulse}
      icon={icon}
      className={className}
    >
      {label ?? status}
    </Badge>
  );
};

export default StatusBadge;
