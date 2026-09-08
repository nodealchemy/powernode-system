import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs';
import path from 'node:path';

/**
 * Guards the form-primitive adoption (IMP-ed4678c123b5).
 *
 * The extension hand-wrote the label class 180 times across 36 files and let
 * the input class drift into three variants, so error styling, help text and
 * sizing differed modal to modal while `@/shared/components/ui/FormField`
 * already modelled exactly that field.
 *
 * Scope follows the operator direction: FormField is adopted only where a
 * label IMMEDIATELY precedes a text/number/select/textarea control. Radio
 * groups, checkboxes and file inputs are not modelled by FormField and stay
 * hand-written — so a blanket "this class must not appear" rule would be wrong
 * and would push those toward a component that cannot express them.
 *
 * The scan therefore pairs each hand-written label with the control that
 * follows it and reports only the MIGRATABLE pairings. `KNOWN_HAND_WRITTEN`
 * grandfathers the files still to convert; removing an entry is how one is
 * migrated, and the second arm fails if an entry has gone stale, so the list
 * can only shrink.
 */

const componentsRoot = __dirname;

/** The label class every hand-written field repeats. */
const LABEL_CLASS = 'block text-sm font-medium text-theme-primary mb-1';

/**
 * How far past a label to look for its control. Labels here are followed by a
 * closing tag and at most a required-marker span before the control opens.
 */
const LOOKAHEAD_LINES = 6;

/** Control kinds FormField models. A bare `<input>` defaults to text. */
const MIGRATABLE_CONTROL = /<(select|textarea)\b|<input\b(?![^>]*type=)|<input\b[^>]*type="(text|number|email|password|tel|url|date)"/;

/** Control kinds FormField cannot express, which stay hand-written. */
const EXEMPT_CONTROL = /<input\b[^>]*type="(radio|checkbox|file|color|range)"/;

function findSources(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules') continue;
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) {
      findSources(full, out);
    } else if (entry.endsWith('.tsx') && !entry.includes('.test.')) {
      out.push(full);
    }
  }
  return out;
}

/**
 * Count labels that sit immediately in front of a control FormField models.
 * A multi-line control tag is joined before matching, so `type=` on its own
 * line is still seen.
 */
function migratableFieldCount(source: string): number {
  const lines = source.split('\n');
  let count = 0;

  lines.forEach((line, i) => {
    if (!line.includes(LABEL_CLASS)) return;
    const window = lines.slice(i + 1, i + 1 + LOOKAHEAD_LINES).join(' ');
    if (EXEMPT_CONTROL.test(window)) return;
    if (MIGRATABLE_CONTROL.test(window)) count += 1;
  });

  return count;
}

/**
 * Files that still hand-write at least one migratable field. Shrink this list;
 * never grow it.
 */
const KNOWN_HAND_WRITTEN: readonly string[] = [
  'providers/AvailabilityZoneFormModal.tsx',
  'providers/ConnectionFormModal.tsx',
  'providers/InstanceTypeFormModal.tsx',
  'providers/ProviderFormModal.tsx',
  'providers/RegionFormModal.tsx',
  'sdwan/AccessGrantCreateModal.tsx',
  'sdwan/AccessTab.tsx',
  'sdwan/FederationPeerList.tsx',
  'sdwan/FederationPeerProposeModal.tsx',
  'sdwan/FirewallRuleFormModal.tsx',
  'sdwan/NetworkFormModal.tsx',
  'sdwan/PeerAttachModal.tsx',
  'sdwan/PeerEditModal.tsx',
  'sdwan/UserDeviceIssueModal.tsx',
  'sdwan/portmappings/PortMappingCreateModal.tsx',
  'sdwan/routing/RoutePolicyEditModal.tsx',
  'sdwan/vips/VirtualIpCreateModal.tsx',
  'sdwan/vips/VirtualIpEditModal.tsx',
  'sdwan_hub/CreateHostBridgeModal.tsx',
];

const sources = findSources(componentsRoot).map((f) => ({
  rel: path.relative(componentsRoot, f),
  source: readFileSync(f, 'utf8'),
}));

describe('form field contract', () => {
  it('is scanning a real tree', () => {
    expect(existsSync(componentsRoot)).toBe(true);
    expect(sources.length).toBeGreaterThan(100);
  });

  it('recognises the label/control pairing it is built to find', () => {
    // Guards the guard: if the pairing heuristic stopped matching anything,
    // the assertion below would pass by seeing nothing at all.
    const sample = [
      '<label className="block text-sm font-medium text-theme-primary mb-1">',
      '  Name',
      '</label>',
      '<input',
      '  type="text"',
      '/>',
    ].join('\n');
    expect(migratableFieldCount(sample)).toBe(1);

    const radio = sample.replace('type="text"', 'type="radio"');
    expect(migratableFieldCount(radio)).toBe(0);
  });

  it('has no component outside the baseline hand-writing a FormField-shaped field', () => {
    const offenders = sources
      .filter((f) => migratableFieldCount(f.source) > 0)
      .map((f) => f.rel)
      .filter((f) => !KNOWN_HAND_WRITTEN.includes(f))
      .sort();

    expect(offenders).toEqual([]);
  });

  it('has no stale baseline entry', () => {
    const stale = KNOWN_HAND_WRITTEN.filter((rel) => {
      const file = sources.find((f) => f.rel === rel);
      if (!file) return true;
      return migratableFieldCount(file.source) === 0;
    }).sort();

    expect(stale).toEqual([]);
  });
});
