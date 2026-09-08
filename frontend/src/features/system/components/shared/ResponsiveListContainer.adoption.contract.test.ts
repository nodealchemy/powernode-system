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
 * Files that render a <table> without going through the container.
 *
 * Two kinds live here and they are NOT the same debt:
 *   - UNMIGRATED: still owes the conversion.
 *   - EXEMPT: renders a table inside a modal or inside a tab that owns other
 *     content, so it is not a list surface. The container would wrap it in
 *     its own surface card and swap the layout — that is a redesign, not the
 *     behaviour-preserving migration this ratchet tracks.
 */
const EXPECTED_WITHOUT_CONTAINER: readonly string[] = [
  // --- EXEMPT: table inside a modal ---
  'features/system/components/acme/DnsRecordsModal.tsx',
  'features/system/components/operations/BatchDetailModal.tsx',
  // --- EXEMPT: table is one part of a composite tab, not the tab's list ---
  'features/system/components/sdwan/AccessTab.tsx',
  'features/system/components/sdwan/routing/NetworkRoutingTab.tsx',
  // --- EXEMPT: presentational sub-table, receives rows as a prop and owns
  //     no loading/empty/filter chrome of its own ---
  'features/system/components/platform/PeerTable.tsx',

  // --- UNMIGRATED (delete the line as each is converted) ---
  'features/system/components/acme/AcmeCertificatesPanel.tsx',
  'features/system/components/acme/AcmeDnsCredentialsPanel.tsx',
  'features/system/components/federation/ChildrenPanel.tsx',
  'features/system/components/federation/ServiceOfferingsPanel.tsx',
  'features/system/components/federation/ServiceSubscriptionsPanel.tsx',
  'features/system/components/ingress/IngressRoutesPanel.tsx',
  'features/system/components/platform/MigrationChainsPanel.tsx',
  'features/system/components/platform/MigrationsPanel.tsx',
  'features/system/components/platform/ScalingPanel.tsx',
  'features/system/components/platform/StorageMigrationsPanel.tsx',
  'features/system/components/sdwan_hub/FlowSamplesTab.tsx',
  'features/system/components/sdwan_hub/HostBridgesTab.tsx',
  'features/system/components/sdwan_hub/IpfixCollectorsTab.tsx',
  'features/system/components/sdwan_hub/OvnDeploymentsTab.tsx',
  'pages/app/system/MyVpnDevicesPage.tsx',
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

function tablesWithoutContainer(): string[] {
  return walk(SRC_ROOT)
    .filter((file) => {
      const source = readFileSync(file, 'utf8');
      if (!source.includes('<table')) return false;
      return !source.includes('ResponsiveListContainer');
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
