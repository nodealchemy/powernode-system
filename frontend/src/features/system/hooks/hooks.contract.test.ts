import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs';
import path from 'node:path';

/**
 * Guards `features/system/hooks/` against dead modules (IMP-a824c7cace83).
 *
 * `useSystemStats.ts` sat here as 196 unreachable lines exporting three
 * symbols. It looked alive: `hooks/index.ts` re-exported all three, so a grep
 * for the symbol names always returned a hit. But nothing imported the barrel
 * either — every real consumer imports the concrete module
 * (`@system/features/system/hooks/useResourceList`, `.../useSystemWebSocket`,
 * `.../useSystemAutonomyConfig`). The barrel laundered a dead module into
 * looking referenced, and the hook duplicated the two fetches SystemOverview
 * already makes inline, so wiring it up would have created a second polling
 * path against the same endpoints.
 *
 * This test is that grep, mechanized. Import specifiers are RESOLVED to real
 * paths rather than substring-matched, because core carries its own unrelated
 * `../hooks` barrels that a loose pattern matches (that false positive is what
 * made the first draft of this test pass vacuously). The barrel itself is
 * excluded from the importer search, so it can never launder a dead module.
 */

const hooksDir = __dirname;
// .../extensions/system/frontend/src/features/system/hooks -> repo root
const repoRoot = path.resolve(hooksDir, '../../../../../../..');

const EXT_SYSTEM_SRC = path.join(repoRoot, 'extensions/system/frontend/src');
const CORE_SRC = path.join(repoRoot, 'frontend/src');

// Every sibling extension's frontend is a potential importer. The roots are
// DERIVED from the filesystem rather than named, because the core-purity gate
// forbids an extension's source from naming another extension (public or
// private), and a hardcoded list would also rot as extensions come and go.
function siblingExtensionSrcRoots(): string[] {
  const roots: string[] = [];
  for (const parent of [path.join(repoRoot, 'extensions'), path.join(repoRoot, 'extensions', 'private')]) {
    if (!existsSync(parent)) continue;
    for (const entry of readdirSync(parent)) {
      if (entry === 'private') continue;
      const src = path.join(parent, entry, 'frontend', 'src');
      if (src !== EXT_SYSTEM_SRC && existsSync(src) && statSync(src).isDirectory()) roots.push(src);
    }
  }
  return roots;
}

const SOURCE_ROOTS = [EXT_SYSTEM_SRC, CORE_SRC, ...siblingExtensionSrcRoots()];

const isSourceFile = (f: string) => /\.tsx?$/.test(f);
const isSpecFile = (f: string) => /\.(test|spec)\.tsx?$/.test(f);

function walk(dir: string, out: string[] = []): string[] {
  if (!existsSync(dir)) return out;
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules') continue;
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (isSourceFile(full)) out.push(full);
  }
  return out;
}

/**
 * Resolve an import specifier to an absolute, extension-less path.
 *
 * `@ext/system/` is handled alongside `@system/`: vite.config.ts registers
 * BOTH for every extension slug, so a consumer written either way is real.
 * Other extensions' aliases resolve into their own src and can never name a
 * file in this directory, so dropping them is safe.
 */
function resolveSpecifier(fromFile: string, spec: string): string | null {
  let abs: string;
  if (spec.startsWith('@system/')) abs = path.join(EXT_SYSTEM_SRC, spec.slice('@system/'.length));
  else if (spec.startsWith('@ext/system/'))
    abs = path.join(EXT_SYSTEM_SRC, spec.slice('@ext/system/'.length));
  else if (spec.startsWith('@/')) abs = path.join(CORE_SRC, spec.slice(2));
  else if (spec.startsWith('.')) abs = path.resolve(path.dirname(fromFile), spec);
  else return null; // bare package specifier
  return abs.replace(/\/index$/, '');
}

const SPECIFIER_RE = /(?:from|import|require)\s*\(?\s*['"]([^'"]+)['"]/g;

/**
 * Comments are stripped first. Without that, a `from '…'` inside a JSDoc
 * `@example` keeps a module alive — and the very hook this test was written
 * for shipped exactly such a block.
 */
const stripComments = (source: string): string =>
  source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

function importedPaths(file: string, source: string): string[] {
  const out: string[] = [];
  for (const m of stripComments(source).matchAll(SPECIFIER_RE)) {
    const resolved = resolveSpecifier(file, m[1]);
    if (resolved) out.push(resolved);
  }
  return out;
}

/** Every hook module here, excluding specs and the barrel. */
const hookModules = readdirSync(hooksDir)
  .filter(isSourceFile)
  .filter((f) => !isSpecFile(f))
  .filter((f) => f !== 'index.ts')
  .map((f) => f.replace(/\.tsx?$/, ''));

/**
 * Files that may count as an importer. Excluding this whole directory means a
 * barrel re-export cannot stand in for a real consumer, and a hook importing a
 * sibling hook cannot keep a dead pair alive. Specs are excluded too: a module
 * only its own tests reach is still dead.
 */
const candidateImporters = SOURCE_ROOTS.flatMap((r) => walk(r)).filter(
  (f) => path.dirname(f) !== hooksDir && !isSpecFile(f),
);

const importsByFile = new Map<string, string[]>(
  candidateImporters.map((f) => [f, importedPaths(f, readFileSync(f, 'utf8'))]),
);

const importersOf = (target: string): string[] =>
  candidateImporters.filter((f) => importsByFile.get(f)!.includes(target));

describe('features/system/hooks contract', () => {
  it('has no unimported barrel that could launder a dead module', () => {
    // A barrel is only legitimate while something imports it. If nothing does,
    // every export it carries is invisible to the per-module check below.
    if (importersOf(hooksDir).length === 0) {
      expect(existsSync(path.join(hooksDir, 'index.ts'))).toBe(false);
    }
  });

  it('finds the hook modules it is meant to be checking', () => {
    // Guards the guard: a resolver or path bug that empties either list would
    // make the assertions below pass vacuously.
    expect(hookModules.length).toBeGreaterThan(0);
    expect(candidateImporters.length).toBeGreaterThan(0);

    // Canary: a wholesale resolver break leaves the two lists populated and
    // only the barrel assertion above would still pass. useResourceList is
    // imported by a dozen components, so zero importers means the resolver is
    // broken, not that the hook died.
    expect(importersOf(path.join(hooksDir, 'useResourceList'))).not.toHaveLength(0);
  });

  it.each(hookModules)(
    '%s is imported by its concrete path from non-test code outside this directory',
    (mod) => {
      expect(importersOf(path.join(hooksDir, mod))).not.toHaveLength(0);
    },
  );
});
