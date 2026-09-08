import { readFileSync, readdirSync, statSync } from 'fs';
import { join, relative } from 'path';

// Adoption ratchet for ResponsiveListContainer (IMP-91dab7a7dfb0).
//
// The container was extracted to absorb the list chrome — initial-load
// spinner, empty state, filter row with refresh button, count summary, and
// the desktop-table / mobile-cards split — that list components were each
// re-implementing. Adoption stalled at 13 of 40 while 27 others kept their
// own copies, so the empty/error copy drifted between hubs and every fix to
// the chrome had to be made 28 times.
//
// The oracle is an EXACT SET, not a ceiling. A ceiling ("no more than N")
// goes green when someone migrates one file and adds another, and it never
// notices a stale entry left behind after a migration. Equality fails in
// BOTH directions: a new hand-rolled table is an unexpected entry, and a
// migrated file still listed here is a stale one.
//
// To migrate a file: convert it, then delete its line below. Do not add a
// line to make a new component pass.

const SRC_ROOT = join(__dirname, '..', '..', '..', '..');

/**
 * Tables that render inside a modal, inside a composite tab, or as a
 * presentational sub-table that takes its rows as a prop. None of these is a
 * list surface: the container would wrap them in its own surface card and swap
 * the layout, which is a redesign rather than the behaviour-preserving
 * migration this ratchet tracks.
 *
 * This list is SEPARATE from the one below on purpose. When the two were one
 * array distinguished only by a comment, moving a line from "still owes the
 * work" to "never has to" was invisible to the equality assertion — debt could
 * be relabelled as an exemption without the diff showing it. Two named lists
 * make that move a change in both.
 */
const EXEMPT: readonly string[] = [
  // Table inside a modal.
  'features/system/components/acme/DnsRecordsModal.tsx',
  'features/system/components/operations/BatchDetailModal.tsx',
  // Table is one part of a composite tab, not the tab's list. NOTE: both of
  // these still hand-roll a loading string and an empty branch of their own.
  // Exempt from the CONTAINER, not from that duplication.
  'features/system/components/sdwan/AccessTab.tsx',
  'features/system/components/sdwan/routing/NetworkRoutingTab.tsx',
  // Presentational sub-table: receives rows as a prop, owns no loading, empty
  // or filter chrome for the container to absorb.
  'features/system/components/platform/PeerTable.tsx',
];

/**
 * Still owes the conversion. Delete the line as each is converted.
 *
 * Empty, and that is the point: adoption is complete, so every remaining
 * non-container table is a deliberate EXEMPT with a stated reason. A new
 * entry here means new debt, not a backlog.
 */
const UNMIGRATED: readonly string[] = [];

const EXPECTED_WITHOUT_CONTAINER: readonly string[] = [...EXEMPT, ...UNMIGRATED];

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

function tablesWithoutContainer(): string[] {
  return walk(SRC_ROOT)
    .filter((file) => {
      const source = readFileSync(file, 'utf8');
      if (!source.includes('<table')) return false;
      // Match an IMPORT, not a mention. Keying on containment lets a single
      // comment naming the container remove a file from this scan for good.
      return !/^\s*import[^\n]*ResponsiveListContainer/m.test(source);
    })
    .map((file) => relative(SRC_ROOT, file).split(/[\\/]/).join('/'))
    .sort();
}

describe('ResponsiveListContainer adoption', () => {
  it('has exactly the known set of components rendering a table outside the container', () => {
    expect(tablesWithoutContainer()).toEqual([...EXPECTED_WITHOUT_CONTAINER].sort());
  });

  it('still finds the container itself, so a rename cannot silence the scan', () => {
    // The check keys on the identifier. If the component is renamed and this
    // file is not updated, every consumer stops matching and the list above
    // would appear to grow — but a reader could equally conclude the scan
    // broke. Pin the identifier's existence so the failure is unambiguous.
    const container = readFileSync(join(__dirname, 'ResponsiveListContainer.tsx'), 'utf8');
    expect(container).toContain('export { ResponsiveListContainer }');
  });
});
