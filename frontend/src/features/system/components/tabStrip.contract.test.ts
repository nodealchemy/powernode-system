import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs';
import path from 'node:path';

/**
 * Guards the tab-strip consolidation (IMP-8b972c69a79f).
 *
 * Four detail modals carried a byte-identical inline `<nav className="flex
 * -mb-px">` strip — same class string, same active/inactive branches, same
 * icon child — while `NodeDetailModal` and `TemplateDetailModal` already
 * rendered the shared `TabContainer` for the same job. They all render
 * `TabContainer` now.
 *
 * Two arms, because a class-string scan alone is satisfiable the wrong way:
 *
 *   - No component may carry the removed strip's class run. This catches a
 *     verbatim copy-paste of the old idiom.
 *   - Every component that owns tab STATE must render `TabContainer`. This is
 *     the load-bearing arm. It keys on `setActiveTab`, which survives both
 *     ways the first arm can be defeated: deleting the strip while keeping
 *     the state, and re-hand-rolling it with one class token renamed. The old
 *     strip set no `role="tab"`, so keying on ARIA would have missed exactly
 *     the shape this task removed.
 *
 * Scope is this directory tree. Nothing renders a tab strip outside it today;
 * a detail modal added elsewhere would not be covered.
 */

const componentsRoot = __dirname;

/** The class run that every hand-rolled copy of the strip shared. */
const INLINE_STRIP_MARKER = 'px-6 py-3 text-sm font-medium border-b-2 transition-colors';

/**
 * How a file signals it OWNS a tab strip: it holds the selected-tab state.
 * Deliberately not `role="tab"` — the strip this task removed had no role
 * attribute at all, so an ARIA-keyed check would not have seen it.
 */
const OWNS_TABS = /setActiveTab/;

/**
 * The one shared tab container. The deprecated copy under `components/ui` was
 * deleted in favour of it (IMP-efa22f08cb32); the host API exposes this id to
 * extension bundles.
 */
const TAB_CONTAINER_IMPORT = "@/shared/components/layout/TabContainer";

/**
 * Components that own tab state without being the detail-modal strip this task
 * consolidated. Each is a different control with different ergonomics, not a
 * copy of the strip; migrating them is a separate decision.
 */
const NOT_THE_DETAIL_STRIP: readonly string[] = [
  // A two-tab form switcher inside a form modal: narrower padding, a disabled
  // state and a title tooltip explaining why the second tab is unavailable.
  'providers/ProviderFormModal.tsx',
];

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

const sources = findSources(componentsRoot).map((f) => ({
  rel: path.relative(componentsRoot, f),
  source: readFileSync(f, 'utf8'),
}));

describe('tab strip contract', () => {
  it('is scanning a real tree', () => {
    // Guards the guard: a path bug that empties the list would make every
    // assertion below pass vacuously.
    expect(existsSync(componentsRoot)).toBe(true);
    expect(sources.length).toBeGreaterThan(100);
  });

  it('has several components owning tab state', () => {
    // Guards the second arm the same way: if nothing matches OWNS_TABS, the
    // assertion below has nothing to check and passes vacuously.
    const withTabs = sources.filter((f) => OWNS_TABS.test(f.source));
    expect(withTabs.length).toBeGreaterThan(4);
  });

  it('has no component hand-rolling the tab strip', () => {
    const offenders = sources
      .filter((f) => f.source.includes(INLINE_STRIP_MARKER))
      .map((f) => f.rel)
      .sort();

    expect(offenders).toEqual([]);
  });

  it('has every tab-owning component rendering the shared TabContainer', () => {
    const missing = sources
      .filter((f) => OWNS_TABS.test(f.source))
      .filter((f) => !f.source.includes(TAB_CONTAINER_IMPORT))
      .map((f) => f.rel)
      .filter((f) => !NOT_THE_DETAIL_STRIP.includes(f))
      .sort();

    expect(missing).toEqual([]);
  });

  it('has no stale exemption', () => {
    // An exemption that no longer owns tab state, or that has since adopted
    // TabContainer, must be removed rather than left as standing permission.
    const stale = NOT_THE_DETAIL_STRIP.filter((rel) => {
      const file = sources.find((f) => f.rel === rel);
      if (!file) return true;
      return !OWNS_TABS.test(file.source) || file.source.includes(TAB_CONTAINER_IMPORT);
    }).sort();

    expect(stale).toEqual([]);
  });
});
