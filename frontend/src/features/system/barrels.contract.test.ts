import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs';
import path from 'node:path';

/**
 * Guards against empty barrel files under `features/` (IMP-389b3ba6a05e).
 *
 * `features/system/index.ts` was a doc comment over a bare `export {};`. Its
 * own comment recorded that everything it once re-exported had moved to the
 * platform admin surface, and that direct `@system/features/system/<area>/...`
 * imports are the convention for what remains — so the barrel had outlived its
 * purpose and had no importers.
 *
 * Unlike the sibling guard in `hooks/hooks.contract.test.ts`, this one needs no
 * import resolution: a barrel that exports NOTHING is dead by construction,
 * because importing it can never yield a binding. That makes the rule cheap and
 * total — it does not matter whether anyone imports it.
 *
 * Scoped to `index.ts` on purpose. A bare `export {}` is a legitimate idiom
 * elsewhere (forcing a file into module scope for global augmentation); it is
 * never meaningful in a barrel.
 */

const featuresRoot = path.resolve(__dirname, '..');

function findBarrels(dir: string, out: string[] = []): string[] {
  if (!existsSync(dir)) return out;
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules') continue;
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) findBarrels(full, out);
    else if (entry === 'index.ts' || entry === 'index.tsx') out.push(full);
  }
  return out;
}

/** Strip comments, then ask whether anything is actually exported. */
function exportsNothing(source: string): boolean {
  const code = source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^\s*\/\/.*$/gm, '')
    .trim();
  // The only statement left is one or more bare `export {}` / `export {};`.
  return code.length > 0 && /^(?:export\s*\{\s*\}\s*;?\s*)+$/.test(code);
}

const barrels = findBarrels(featuresRoot);

describe('features barrel contract', () => {
  it('is scanning a real tree', () => {
    // Guards the guard: a path bug that empties the list would make the
    // assertion below pass vacuously.
    expect(existsSync(featuresRoot)).toBe(true);
    expect(barrels.length).toBeGreaterThan(0);
  });

  it('has no barrel that exports nothing', () => {
    const empty = barrels
      .filter((f) => exportsNothing(readFileSync(f, 'utf8')))
      .map((f) => path.relative(featuresRoot, f));

    expect(empty).toEqual([]);
  });
});
