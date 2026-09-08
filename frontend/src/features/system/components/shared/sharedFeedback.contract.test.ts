import { readFileSync, readdirSync, statSync } from 'fs';
import { join, relative } from 'path';

// Shared error/loading feedback ratchet (IMP-fb105f6edaa3).
//
// Core ships ui/ErrorAlert and ui/LoadingSpinner. Before this, the extension
// hand-rolled both: a `bg-theme-danger-bg text-theme-danger-fg` div for errors
// (which therefore had no icon and no dismiss affordance unless each site
// added its own) and a `p-8 text-center text-theme-secondary` div reading
// "Loading X…" for loading (which therefore looked different from the spinner
// every neighbouring surface used).
//
// The oracle is an EXACT SET in both directions, for the same reason as the
// ResponsiveListContainer ratchet: a ceiling goes green when someone fixes one
// site and adds another, and never notices a stale entry.
//
// IMPORTANT about what this does NOT match. `bg-theme-danger-bg` on its own is
// a legitimate colour token — status badges, severity maps, a `hover:` on a
// destructive button. Only the ADJACENT PAIR inside a plain string className,
// which is the hand-rolled banner's signature, is a finding. Template-literal
// maps that compose `${base} bg-theme-danger-bg text-theme-danger-fg` are
// styling a badge, not raising an alert, and are deliberately out of scope.
// A className carrying a `hover:` is likewise excluded: a banner has no hover
// state, so that token marks a destructive BUTTON wearing the danger colours.

const SRC_ROOT = join(__dirname, '..', '..', '..', '..');

/** Hand-rolled error banners that remain, with the reason each is not ErrorAlert. */
const ERROR_BANNER_EXEMPT: readonly string[] = [
  // ErrorAlert renders a `message: string`. This one carries rich JSX — an
  // interpolated <code> field name — so routing it through ErrorAlert would
  // flatten markup the operator needs, not just restyle a box.
  'features/system/components/sdwan/vips/VirtualIpFailoverModal.tsx',
  // A permission-denial notice, not a failed operation. "You don't have
  // permission to view SDWAN routing" is this page's normal rendering for a
  // reader without the grant; ErrorAlert's alert-triangle chrome would present
  // a correct, expected state as something gone wrong. (The same file's real
  // error banner, further down, WAS converted.)
  'pages/app/system/SdwanRoutingPage.tsx',
  // A labelled detail FIELD inside a drawer ("Error" heading over the
  // migration's own error_message in mono), not a page-level alert. ErrorAlert
  // would drop both the label and the monospacing that makes a stack trace
  // readable.
  'features/system/components/platform/MigrationsPanel.tsx',
  // Nothing owed here any more. The three files that carried a "another lane
  // owns this" note during the parallel drain — FulfillmentTab,
  // AcmeDnsCredentialModal and CreateModuleFromPackageModal — are all on
  // ErrorAlert now, so every entry above is a deliberate design decision with
  // a stated reason. A new entry means new debt, not a backlog.
];

/**
 * Sites still matching the loading pattern, with the reason each is not
 * LoadingSpinner. Every one is a FALSE POSITIVE of the class-based match
 * rather than debt: these are not loading blocks at all.
 */
const LOADING_EXEMPT: readonly string[] = [
  // EMPTY-state boxes that happen to wear the loading block's three classes.
  // Each is a `{!loading && items.length === 0}` branch reading "No grants
  // matching the current filter." or the like — the classes coincide, the
  // meaning does not, and a spinner belongs in none of them. These are
  // PERMANENT exemptions, not entries awaiting conversion.
  //
  // DnsRecordsModal is the clearest case: its REAL loading block was converted
  // to LoadingSpinner in this same change, and it stays listed here only
  // because its empty state still matches. That is the limit of a scan keyed
  // on class names — it cannot tell an empty state from a loading one.
  'features/system/components/platform/GrantsManagementModal.tsx',
  'features/system/components/platform/CapabilitiesManagementModal.tsx',
  'features/system/components/acme/DnsRecordsModal.tsx',
];

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules') continue;
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      walk(full, out);
    } else if (entry.endsWith('.tsx') && !entry.includes('.test.')) {
      out.push(full);
    }
  }
  return out;
}

function rel(file: string): string {
  return relative(SRC_ROOT, file).split(/[\\/]/).join('/');
}

/**
 * The adjacent colour pair inside a DOUBLE-QUOTED className. A template
 * literal is how the badge/severity maps compose their classes, and those are
 * not alerts.
 */
const HAND_ROLLED_BANNER =
  /className="(?![^"]*hover:)[^"]*\bbg-theme-danger-bg text-theme-danger-fg\b[^"]*"/;

/** The centred "Loading …" block LoadingSpinner replaces. */
const HAND_ROLLED_LOADING = /className="[^"]*\bp-8 text-center text-theme-secondary\b[^"]*"/;

function filesMatching(pattern: RegExp): string[] {
  return walk(SRC_ROOT)
    .filter((file) => pattern.test(readFileSync(file, 'utf8')))
    .map(rel)
    .sort();
}

describe('shared error and loading feedback', () => {
  it('has exactly the known set of hand-rolled error banners left', () => {
    expect(filesMatching(HAND_ROLLED_BANNER)).toEqual([...ERROR_BANNER_EXEMPT].sort());
  });

  it('has exactly the known set of hand-rolled loading blocks left', () => {
    expect(filesMatching(HAND_ROLLED_LOADING)).toEqual([...LOADING_EXEMPT].sort());
  });

  it('still resolves the shared components it is steering people towards', () => {
    // If either component is deleted or its import id moves, every consumer
    // breaks — but the two assertions above would go quietly green, since they
    // only look for the patterns they want GONE. Pin both halves: the files
    // exist, AND the host-api allowlist still resolves their ids. The
    // allowlist check is not redundant — an id absent from it type-checks and
    // passes jest, then fails only at module-build time.
    const ui = join(SRC_ROOT, '..', '..', '..', '..', 'frontend', 'src', 'shared', 'components', 'ui');
    expect(statSync(join(ui, 'ErrorAlert.tsx')).isFile()).toBe(true);
    expect(statSync(join(ui, 'LoadingSpinner.tsx')).isFile()).toBe(true);

    const host = readFileSync(
      join(SRC_ROOT, '..', '..', '..', '..', 'frontend', 'src', 'shared', 'host-api', 'modules.ts'),
      'utf8',
    );
    expect(host).toContain("'@/shared/components/ui/ErrorAlert'");
    expect(host).toContain("'@/shared/components/ui/LoadingSpinner'");
  });
});
