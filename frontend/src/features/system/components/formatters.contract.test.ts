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

/**
 * Any named helper, with enough of its body to classify.
 *
 * NOT restricted to `format*`: the sixth copy found during IMP-afe91410f14d is
 * called `fmt`, and a name convention is exactly the assumption the previous
 * pass already had to abandon once. The two classifiers below carry the weight
 * instead, and they are deliberately asymmetric — see FULL_TIMESTAMP.
 */
const HELPER =
  /\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(|\b(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=\n]*)?=\s*(?:async\s*)?\(/g;
const BODY_LINES = 12;

/**
 * Bodies that duplicate something core already exports.
 *
 * A byte ladder is unmistakable, so it is caught under ANY helper name. A
 * toLocaleString call is not: most of the ~164 inline ones live in small render
 * helpers assigned to a const, and the approving direction put those out of
 * scope. So the timestamp shape is only reported when the author named the
 * thing `format*`, which is what a formatter-by-intent looks like.
 */
const BYTE_LADDER = /1024/;
const FULL_TIMESTAMP = /toLocaleString\(/;

/**
 * A module-scope `const KB = 1024` hoisted above a helper takes the literal OUT
 * of the body window, and the ladder below it then classifies clean. Feeding
 * those constants in alongside the body closes that hole; it is also why the
 * sanctioned volumeSize helper needs its sanction at all.
 */
const UNIT_CONSTANT = /^\s*const\s+[A-Z][A-Z0-9_]*\s*=\s*[^;]*1024/m;

function duplicatesCore(name: string, body: string, moduleConstants: string): boolean {
  if (BYTE_LADDER.test(body)) return true;
  if (UNIT_CONSTANT.test(moduleConstants) && /\bBYTES?_|_GB\b|_KB\b|_MB\b/.test(body)) return true;
  return name.startsWith('format') && FULL_TIMESTAMP.test(body);
}

/**
 * Local copies that remain, each with the reason it was not converted here.
 * Removing an entry is how one is migrated; a stale entry FAILS, so this list
 * cannot quietly outlive the copies it describes.
 */
const KNOWN_LOCAL_COPIES: Record<string, string> = {
  'platform/StorageMigrationDetailDrawer.tsx:fmt':
    'A byte ladder capped at MB, so a 1 GiB copy renders as "1024.0 MB" where every other size screen now says "1.0 GB". Found only when IMP-afe91410f14d dropped the format* name convention from this scan — it is called fmt. Left listed rather than converted because platform/ was another lane\'s directory during that task; its own spec pins the cap at StorageMigrationDetailDrawer.test.tsx:327 and 366, so converting it means updating those two assertions.',
};

/**
 * The one extension-side formatter this guard sanctions, and the reason it is
 * not a copy: provider volumes report `size_gb`, so core's formatFileSize —
 * which takes BYTES — renders a 100 GB volume as '100 B' if handed the raw
 * value. This helper multiplies into bytes ONCE and delegates, keeping the
 * gigabyte as the domain unit and the ladder as core's (IMP-afe91410f14d).
 *
 * Sanctioned by PATH, and the arm below checks it actually delegates — an
 * entry here is permission to convert a unit, not permission to hand-roll a
 * second ladder under a blessed filename.
 */
const SANCTIONED_HELPERS: Record<string, string> = {
  '../utils/volumeSize.ts:formatVolumeSize':
    'Converts the API\'s gigabytes to bytes and delegates to core formatFileSize, because volume sizes are not reported in bytes.',
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

function helpersIn(source: string, relative: string): Helper[] {
  const lines = source.split('\n');
  const found: Helper[] = [];

  for (const match of source.matchAll(HELPER)) {
    const name = match[1] ?? match[2];
    const lineIndex = source.slice(0, match.index).split('\n').length - 1;
    const following = lines.slice(lineIndex, lineIndex + BODY_LINES).join('\n');
    found.push({
      key: `${relative}:${name}`,
      name,
      where: `${relative}:${lineIndex + 1}`,
      duplicates: duplicatesCore(name, following, source),
    });
  }
  return found;
}

describe('date, duration and size formatting is owned by @/shared/utils/formatters', () => {
  const sources = findSources(scanRoot);
  const componentRoot = path.join(scanRoot, 'features/system/components');
  // Sanctioned by helper KEY, not by file: every other helper in a sanctioned
  // file is still examined, and the core-owned-names arm below still applies to
  // it. A file-level exemption would have made that arm's "no exceptions"
  // claim false.
  const helpers = sources
    .flatMap((file) => helpersIn(readFileSync(file, 'utf8'), path.relative(componentRoot, file)))
    .filter((helper) => !(helper.key in SANCTIONED_HELPERS));

  it('scans the extension frontend, so an empty result means clean and not broken', () => {
    expect(sources.length).toBeGreaterThan(200);
    expect(sources.some((f) => f.endsWith('sdwan/PeerList.tsx'))).toBe(true);
    expect(sources.some((f) => f.endsWith('operations/OperationList.tsx'))).toBe(true);
    // The body arm cannot be proved against the tree any more — the tree is
    // clean, which is the point. Prove it against a FIXTURE run through the
    // real extraction, not just the predicate: the line-window arithmetic in
    // helpersIn is the half that would silently report nothing if it broke,
    // and every arm would stay green while the guard saw no copies at all.
    const fixture = [
      "const KB = 1024;",
      "",
      "function formatWhen(ts: string): string {",
      "  return new Date(ts).toLocaleString();",
      "}",
      "",
      "const fmt = (n: number) => `${(n / (1024 * 1024)).toFixed(1)} MB`;",
      "",
      "const hoisted = (n: number) => `${(n / BYTES_PER_MB).toFixed(1)} MB`;",
      "",
      "const shout = (label: string) => label.toUpperCase();",
    ].join("\n");
    const classified = helpersIn(fixture, 'fixture.tsx');

    expect(classified.find((h) => h.name === 'formatWhen')?.duplicates).toBe(true);
    expect(classified.find((h) => h.name === 'fmt')?.duplicates).toBe(true);
    expect(classified.find((h) => h.name === 'hoisted')?.duplicates).toBe(true);
    expect(classified.find((h) => h.name === 'shout')?.duplicates).toBe(false);
    // And the window must point at the right line, or the report is unreadable.
    expect(classified.find((h) => h.name === 'formatWhen')?.where).toBe('fixture.tsx:3');
  });

  it('redefines none of the names core owns', () => {
    const everyHelper = sources.flatMap((file) =>
      helpersIn(readFileSync(file, 'utf8'), path.relative(componentRoot, file))
    );
    const offenders = everyHelper
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

  it('keeps every sanctioned helper delegating to core rather than hand-rolling', () => {
    const notDelegating = Object.entries(SANCTIONED_HELPERS).filter(([key, reason]) => {
      const relative = key.split(':')[0];
      const body = readFileSync(path.join(scanRoot, 'features/system/components', relative), 'utf8');
      return (
        !body.includes("from '@/shared/utils/formatters'") ||
        !/formatFileSize\(|formatDateTime\(|formatTimestamp\(|formatDuration\(/.test(body) ||
        reason.trim().length < 40
      );
    });

    expect(notDelegating.map(([key]) => key)).toEqual([]);
  });

  it('gives every baselined copy a reason', () => {
    const unexplained = Object.entries(KNOWN_LOCAL_COPIES)
      .filter(([, reason]) => reason.trim().length < 40)
      .map(([key]) => key);

    expect(unexplained).toEqual([]);
  });
});
