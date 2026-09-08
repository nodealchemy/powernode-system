import { readFileSync } from 'node:fs';
import path from 'node:path';

/**
 * Guards the SAFETY ARGUMENT recorded above FOREIGN_DOMAIN_KEY, not the filter
 * (IMP-28dfcae4f968).
 *
 * SystemSettingsPanel drops the server's `other` bucket from the operator-facing
 * modal. That is only safe because no category this extension owns can land
 * there, and the doc block is where a reader auditing the filter is sent to
 * check. It cited the wrong invariant: it said the pivot spec pins that every
 * SEEDED category files under a named domain, while since IMP-fa63f411633b the
 * spec's oracle is keyed to `Ai::InterventionPolicy.registered_categories` —
 * the set PATCH #update admits — which is strictly wider than the seeded subset
 * and therefore a stronger guarantee.
 *
 * The distinction is the whole point. Two composer categories were registered
 * and deliberately unseeded, so a seeded-set invariant said nothing about them
 * and they were stranded in `other` the moment an operator saved a policy row
 * through the endpoint, a path no seed file exercises. Understating the
 * guarantee is the same framing that let that defect survive two iterations,
 * which is why the wording is worth pinning rather than leaving to review.
 *
 * A comment cannot be exercised, so this is a source-level assertion. It has
 * both arms deliberately: the stale claim must be absent AND the real one
 * present, because either alone passes for the wrong reason — deleting the
 * whole block would satisfy a negative-only test.
 */

const panelSource = readFileSync(
  path.resolve(__dirname, 'SystemSettingsPanel.tsx'),
  'utf8',
);

/** The doc block this test governs: everything above `const FOREIGN_DOMAIN_KEY`. */
function foreignDomainDocBlock(): string {
  const marker = "const FOREIGN_DOMAIN_KEY";
  const end = panelSource.indexOf(marker);
  expect(end).toBeGreaterThan(-1);
  const blockStart = panelSource.lastIndexOf('/**', end);
  expect(blockStart).toBeGreaterThan(-1);
  return panelSource.slice(blockStart, end);
}

describe('FOREIGN_DOMAIN_KEY safety argument', () => {
  it('does not claim the pivot spec pins the SEEDED set', () => {
    expect(foreignDomainDocBlock()).not.toMatch(/every\s+seeded\s+category/i);
  });

  it('names the registered set as the invariant the filter rests on', () => {
    const block = foreignDomainDocBlock();
    expect(block).toMatch(/registered/i);
    // The registry is what PATCH admits; that is why it is the right set.
    expect(block).toMatch(/registered_categories/);
  });

  it('scopes the guarantee to the namespaces this extension owns', () => {
    // Core statics land in `other` BY DESIGN, so an unqualified "nothing
    // reaches other" would be false and would make the filter look unsafe.
    expect(foreignDomainDocBlock()).toMatch(/system\.|sdwan\./);
  });

  it('still points at the spec that carries the invariant', () => {
    expect(foreignDomainDocBlock()).toContain(
      'autonomy_domain_pivot_spec.rb',
    );
  });
});
