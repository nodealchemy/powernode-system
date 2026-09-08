import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';

/**
 * Guards the formatter consolidation (IMP-c11d5ad755b8).
 *
 * Eight components re-implemented formatting that `@/shared/utils/formatters`
 * already exports, and the copies had drifted apart rather than merely
 * duplicating: three formatBytes bodies disagreed (one returned 'not measured'
 * for null with one decimal, two had no null handling and two decimals at GB),
 * and two formatDuration bodies differed only in rendering a sub-minute run as
 * '45s' or '45 seconds'. An operator comparing two hub screens saw the same
 * quantity written two ways.
 *
 * A guard that pinned the OUTPUT would not have caught that — each copy was
 * self-consistent. So this pins DEFINITIONS, in two arms that fail differently:
 *
 *   NAMES (no exceptions): the identifiers core owns may not be redefined here.
 *   BODIES (baselined): a helper that formats a full timestamp or walks a byte
 *   ladder under any name must be listed in KNOWN_LOCAL_COPIES with a reason.
 *
 * The second arm exists because the first one is weak on its own: the drift
 * this task fixed would have slipped straight past a name check under the name
 * `formatTs`, and three such copies were sitting in the tree while the eight
 * named files were being migrated. The list can only shrink — an entry whose
 * copy is gone fails too — so 'not converted yet' stays a decision somebody
 * wrote down rather than a silence.
 *
 * Deliberately NOT in scope, per the approving direction: the ~164 inline
 * `new Date(...).toLocale*` calls scattered through render bodies. This looks
 * only at NAMED HELPERS, so an inline call in JSX is not reported here.
 */

/** The whole extension frontend — a copy on a page counts as much as one in a component. */
const scanRoot = path.join(__dirname, '..', '..', '..');

/** Identifiers core owns. Redefining one locally is how the drift started. */
const CORE_OWNED = [
  'formatDate',
  'formatDateTime',
  'formatTimestamp',
  'formatDuration',
  'formatBytes',
  'formatFileSize',
];

/** Any named `format*` helper, with enough of its body to classify. */
const HELPER = /\b(?:const|let|var|function)\s+(format[A-Za-z0-9_]*)\s*[=(]/g;
const BODY_LINES = 12;

/** Bodies that duplicate something core already exports. */
const FULL_TIMESTAMP = /toLocaleString\(/;
const BYTE_LADDER = /1024/;

/**
 * Local copies that remain, each with the reason it was not converted here.
 * Removing an entry is how one is migrated; a stale entry FAILS, so this list
 * cannot quietly outlive the copies it describes.
 */
const KNOWN_LOCAL_COPIES: Record<string, string> = {
  'sdwan_hub/HostBridgesTab.tsx:formatTs':
    "Byte-identical to core's formatTimestamp. Left for a follow-up because sdwan_hub was being edited by another lane during this consolidation.",
  'sdwan_hub/IpfixCollectorsTab.tsx:formatTs':
    "Byte-identical to core's formatTimestamp. Left for a follow-up for the same reason as HostBridgesTab.",
  'packages/CreateModuleFromPackageModal.tsx:formatSize':
    "A fourth byte ladder, disagreeing again (0 decimals at KB, stops at MB). packages/ was being edited by another lane; it should adopt formatFileSize.",
  'volumes/VolumeList.tsx:formatSize':
    'Takes GIGABYTES and renders GB/TB, so core formatFileSize (which takes bytes) is the wrong function — converting it needs a decision about the unit, not just an import.',
  'volumes/VolumeDetailModal.tsx:formatSize':
    'The same GB-input helper as VolumeList, duplicated. Both should collapse onto one, once the unit question above is answered.',
};

function findSources(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules') continue;
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) {
      findSources(full, out);
    } else if (/\.tsx?$/.test(entry) && !entry.includes('.test.')) {
      out.push(full);
    }
  }
  return out;
}

interface Helper {
  key: string;
  name: string;
  where: string;
  duplicates: boolean;
}

function helpersIn(file: string, relative: string): Helper[] {
  const body = readFileSync(file, 'utf8');
  const lines = body.split('\n');
  const found: Helper[] = [];

  for (const match of body.matchAll(HELPER)) {
    const lineIndex = body.slice(0, match.index).split('\n').length - 1;
    const following = lines.slice(lineIndex, lineIndex + BODY_LINES).join('\n');
    found.push({
      key: `${relative}:${match[1]}`,
      name: match[1],
      where: `${relative}:${lineIndex + 1}`,
      duplicates: FULL_TIMESTAMP.test(following) || BYTE_LADDER.test(following),
    });
  }
  return found;
}

describe('date, duration and size formatting is owned by @/shared/utils/formatters', () => {
  const sources = findSources(scanRoot);
  const helpers = sources.flatMap((file) =>
    helpersIn(file, path.relative(path.join(scanRoot, 'features/system/components'), file))
  );

  it('scans the extension frontend, so an empty result means clean and not broken', () => {
    expect(sources.length).toBeGreaterThan(200);
    expect(sources.some((f) => f.endsWith('sdwan/PeerList.tsx'))).toBe(true);
    expect(sources.some((f) => f.endsWith('operations/OperationList.tsx'))).toBe(true);
    // The body arm is only meaningful if it can see a body it should classify.
    expect(helpers.some((h) => h.duplicates)).toBe(true);
  });

  it('redefines none of the names core owns', () => {
    const offenders = helpers
      .filter((h) => CORE_OWNED.includes(h.name))
      .map((h) => `${h.where} defines ${h.name}`);

    expect(offenders).toEqual([]);
  });

  it('has no unlisted local copy of a timestamp or byte formatter', () => {
    const unlisted = helpers
      .filter((h) => h.duplicates && !(h.key in KNOWN_LOCAL_COPIES))
      .map((h) => `${h.where} defines ${h.name}`);

    expect(unlisted.sort()).toEqual([]);
  });

  it('lists no copy that is already gone', () => {
    const live = new Set(helpers.map((h) => h.key));
    const stale = Object.keys(KNOWN_LOCAL_COPIES).filter((key) => !live.has(key));

    expect(stale.sort()).toEqual([]);
  });

  it('imports from core where the finding named a copy', () => {
    // The consolidation is only real if the call sites reach core. Checked by
    // SYMBOL, not just by module path: a file that imports formatFileSize and
    // then hand-rolls a date is not what any of these lines claim.
    const adopters: Record<string, string> = {
      'networks/NetworkDetailModal.tsx': 'formatDateTime',
      'templates/TemplateDetailModal.tsx': 'formatDateTime',
      'volumes/VolumeDetailModal.tsx': 'formatDateTime',
      'volumes/VolumeList.tsx': 'formatTimestamp',
      'operations/OperationList.tsx': 'formatTimestamp',
      'operations/OperationDetailModal.tsx': 'formatTimestamp',
      'sdwan/PeerList.tsx': 'formatFileSize',
      'platforms/DiskImageHistoryTab.tsx': 'formatFileSize',
      'sdwan_hub/FlowSamplesTab.tsx': 'formatFileSize',
    };

    const missing = Object.entries(adopters).filter(([relative, symbol]) => {
      const body = readFileSync(path.join(__dirname, relative), 'utf8');
      const importLine = body.match(/import \{([^}]*)\} from '@\/shared\/utils\/formatters';/);
      return !importLine || !importLine[1].includes(symbol);
    });

    expect(missing.map(([file]) => file)).toEqual([]);
  });

  it('gives every baselined copy a reason', () => {
    const unexplained = Object.entries(KNOWN_LOCAL_COPIES)
      .filter(([, reason]) => reason.trim().length < 40)
      .map(([key]) => key);

    expect(unexplained).toEqual([]);
  });
});
