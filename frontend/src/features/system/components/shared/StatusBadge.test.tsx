import React from 'react';
import { render, screen } from '@testing-library/react';
import { StatusBadge, statusVariant, STATUS_VARIANTS } from './StatusBadge';

// StatusBadge (IMP-328c63a1da8a) — one status→variant table for the whole
// extension, replacing twelve independent maps in two incompatible idioms
// (core Badge variants vs raw `bg-theme-*-bg text-theme-*-fg` pill classes at
// three different paddings).
//
// The table is asserted ENTRY BY ENTRY rather than by rendering a few
// examples. A handful of spot checks passes just as happily when a status is
// dropped from the table and starts falling through to the default, which is
// exactly the silent regression this consolidation is meant to end.

describe('statusVariant', () => {
  // Every status the twelve replaced maps knew about, with the variant this
  // table settles on. Where the old maps DISAGREED the resolution is called
  // out — those rows are deliberate colour changes, not transcription.
  const CASES: Array<[string, string, string?]> = [
    // --- terminal success ---
    ['available', 'success'],
    ['active', 'success'],
    ['complete', 'success'],
    ['success', 'success'],
    ['published', 'success'],
    ['completed', 'success'],
    ['valid', 'success'],
    ['ok', 'success'],
    ['idle', 'success'],

    // --- in flight / informational ---
    ['in-use', 'info'],
    ['scheduled', 'info'],
    ['registered', 'info'],
    ['bootstrapping', 'info'],
    ['paused', 'info'],
    [
      'held',
      'info',
      'The component status plane\'s operator-intent verdict — cordoned, paused, drained (design §4.1). Beside `paused`, which is the same concept under an older name. NOT amber: `suspended` four blocks down is amber and means "needs attention", the opposite polarity, and rev 1 of the design called this verdict `suspended` before catching that collision.',
    ],
    [
      'proposed',
      'info',
      'PeerStatusPill rendered this grey (background-tertiary) and sdwan/FederationPeerList rendered it info; it is an opening move, not a null state, so info wins.',
    ],
    [
      'accepted',
      'info',
      'PeerStatusPill said info, sdwan/FederationPeerList said success. It is an intermediate step before active, so info wins — reserving success for states that are actually serving.',
    ],
    [
      'enrolled',
      'info',
      'Both deleted maps (federation/ChildrenPanel and PeerStatusPill) rendered this info, and PeerStatusPill had an explicit test pairing it with accepted. An enrolled peer is not yet serving, so it must not read as active.',
    ],
    ['validating', 'info'],
    ['transferring', 'info'],
    ['applying', 'info'],
    ['in_flight', 'info'],
    ['approved', 'info'],
    ['preparing', 'info'],
    [
      'issuing',
      'info',
      'ingress/IngressRoutesPanel rendered this amber; the two acme panels rendered it blue. It is work in progress on a healthy certificate, so info.',
    ],
    ['renewing', 'info'],
    ['running', 'primary'],
    [
      'progressing',
      'primary',
      'An in-flight remediation or provisioning (design §4.1). Beside `running` for the same reason: work actually happening, not a queue position, and the saturated fill is what separates the two from the pale informational states.',
    ],

    // --- needs attention, not yet broken ---
    [
      'pending',
      'warning',
      'The widest disagreement of the lot. Warning in four maps; grey in sdwan_hub/OvnDeploymentsTab (deployment status), federation/ServiceSubscriptionsPanel and acme/AcmeCertificatesPanel; info in sdwan/PeerList and in OvnDeploymentsTab\'s SECOND map, for port state. operations/GitopsTab reached it through a `default: secondary` catch-all over an untyped status, so it moves out of grey too. Warning wins on both weight of use and meaning.',
    ],
    ['creating', 'warning'],
    ['deleting', 'warning'],
    ['dispatched', 'warning'],
    ['awaiting_signature', 'warning'],
    ['awaiting_upload', 'warning'],
    ['publishing', 'warning'],
    ['verifying', 'warning'],
    ['queued', 'warning'],
    ['partial', 'warning'],
    ['suspended', 'warning'],
    ['failing_over', 'warning'],
    ['draining', 'warning'],
    ['conflict', 'warning'],
    ['syncing', 'warning'],
    ['cutover', 'warning'],
    ['deprecated', 'warning'],
    ['expired', 'warning'],
    [
      'degraded',
      'warning',
      'PeerStatusPill said warning, sdwan_hub/OvnDeploymentsTab said danger. Degraded is serving-but-impaired, which is not the same as down, so warning wins.',
    ],

    // --- broken ---
    ['error', 'danger'],
    ['failed', 'danger'],
    ['revoked', 'danger'],
    ['disconnected', 'danger'],
    ['retired', 'danger'],
    ['down', 'danger'],
    ['invalid', 'danger'],

    // --- inert ---
    ['deleted', 'secondary'],
    ['aborted', 'secondary'],
    [
      'cancelled',
      'secondary',
      'federation/ServiceSubscriptionsPanel rendered this red; every other map rendered it grey. A cancellation is a decision, not a failure, so grey wins.',
    ],
    ['archived', 'secondary'],
    ['unassigned', 'secondary'],
    ['unknown', 'secondary'],
    ['removed', 'secondary'],
    ['draft', 'secondary'],
    ['untested', 'secondary'],
    ['disabled', 'secondary'],
    [
      'planned',
      'secondary',
      'Grey in the three migration panels; kept grey rather than promoted, since a planned migration has not started.',
    ],

    // --- drafted, not yet acting ---
    ['planning', 'outline'],

    // --- absent measurement ---
    [
      'not_measured',
      'outline',
      'The sweep could not obtain a reading (design §4.1). Deliberately NOT grey beside `unknown`: `unknown` is inert, while `not_measured` is a gap an operator should close, ranking above `progressing` on the verdict ladder. Filed grey it would sit among `deleted`, `archived` and `disabled` and never be looked at. Shares `outline` with core\'s VerdictBadge so the verdict reads the same on the status page and on a fleet tab.',
    ],
  ];

  it.each(CASES)('maps %s to the %s variant', (status, variant) => {
    expect(statusVariant(status)).toBe(variant);
  });

  it('covers every status in the table and nothing else', () => {
    // Equality, not containment: a status silently dropped from the table
    // starts falling through to the default and still renders, so only an
    // exact comparison notices it going missing.
    expect(Object.keys(STATUS_VARIANTS).sort()).toEqual(CASES.map(([s]) => s).sort());
  });

  it('falls back to secondary for a status it has never seen', () => {
    expect(statusVariant('a_status_no_backend_emits')).toBe('secondary');
  });

  it('is case-insensitive, because backends disagree on casing', () => {
    expect(statusVariant('ACTIVE')).toBe('success');
    expect(statusVariant('Failed')).toBe('danger');
  });

  // The component status plane's six verdicts, asserted as a SET rather than
  // relying on their six rows above. The rows say what each maps to; this says
  // that all six are known at all, which is the property C1 owes the status
  // page — a verdict missing from the table falls through to `secondary` and
  // renders grey, and a grey `down` is worse than no badge.
  describe('component status verdicts (design §4.1)', () => {
    const VERDICTS = ['ok', 'held', 'progressing', 'not_measured', 'degraded', 'down'];

    it.each(VERDICTS)('knows %s rather than falling through to the default', (verdict) => {
      // Both arms: the table HAS the key, and the lookup does not return the
      // fallback. Checking only the key would pass for an entry whose value was
      // literally 'secondary'; checking only the variant would pass for a
      // verdict that happened to be spelled like an unrelated status.
      expect(Object.keys(STATUS_VARIANTS)).toContain(verdict);
      expect(statusVariant(verdict)).not.toBe('secondary');
    });

    it('does not render not_measured as the inert grey that unknown gets', () => {
      // These two are the pair most easily collapsed — both mean "no value" in
      // casual reading. They are different answers: `unknown` is a value nobody
      // needs, `not_measured` is a reading nobody took.
      expect(statusVariant('unknown')).toBe('secondary');
      expect(statusVariant('not_measured')).toBe('outline');
    });
  });
});

describe('StatusBadge', () => {
  it('renders the status as its own label by default', () => {
    render(<StatusBadge status="active" />);
    expect(screen.getByText('active')).toBeInTheDocument();
  });

  it('renders an explicit label instead when one is given', () => {
    render(<StatusBadge status="awaiting_signature" label="Awaiting signature" />);
    expect(screen.getByText('Awaiting signature')).toBeInTheDocument();
    expect(screen.queryByText('awaiting_signature')).not.toBeInTheDocument();
  });

  it('carries the variant class for its status', () => {
    const { container } = render(<StatusBadge status="failed" />);
    expect(container.querySelector('.badge-theme-danger')).toBeInTheDocument();
  });

  it('defaults to the sm size and accepts an override', () => {
    const { container: def } = render(<StatusBadge status="active" />);
    expect(def.querySelector('.badge-theme-sm')).toBeInTheDocument();

    const { container: xs } = render(<StatusBadge status="active" size="xs" />);
    expect(xs.querySelector('.badge-theme-xs')).toBeInTheDocument();
  });

  it('renders nothing for an absent status rather than an empty badge', () => {
    // A row whose status has not loaded should show no pill at all — an empty
    // coloured pill reads as a real state the backend reported.
    const { container } = render(<StatusBadge status={undefined} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('passes dot and pulse through for the in-flight states that used them', () => {
    const { container } = render(<StatusBadge status="pending" dot pulse />);
    expect(container.querySelector('.badge-dot')).toBeInTheDocument();
  });
});
