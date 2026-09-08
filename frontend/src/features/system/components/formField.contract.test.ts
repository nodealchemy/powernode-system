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

/**
 * The whole extension frontend, not just the component tree: the create- and
 * edit-pool forms live on a page, and scanning only `components/` reported an
 * empty baseline while twelve hand-written fields sat one directory over.
 */
const scanRoot = path.join(__dirname, '..', '..', '..');

/** The label class every hand-written field repeats. */
const LABEL_CLASS = 'block text-sm font-medium text-theme-primary mb-1';

/**
 * How far past a label to look. The scan walks to `</label>` rather than
 * stopping at a fixed offset — a caption that ran long used to fall out of the
 * window and take its field with it — and this is only the bound that stops a
 * stray label class from scanning to end of file.
 */
const SCAN_LINES = 40;

/** Control kinds FormField models. A bare `<input>` defaults to text. */
const MIGRATABLE_CONTROL = /<(select|textarea)\b|<input\b(?![^>]*type=)|<input\b[^>]*type="(text|number|email|password|tel|url|date)"/;

/** Control kinds FormField cannot express, which stay hand-written. */
const EXEMPT_CONTROL = /<input\b[^>]*type="(radio|checkbox|file|color|range)"/;

/**
 * The first tag after the label closes, opening OR closing — the optional
 * slash is what makes closing tags visible. A caption over a static value
 * display is followed by `</div>`; a pattern that could not match it would run
 * on and pair that caption with the next field's control.
 */
const FIRST_TAG = /<\/?([A-Za-z][A-Za-z0-9]*)/;

/**
 * A hint paragraph or a JSX comment sitting between a caption and its control.
 * Neither makes the pairing a composite, so both are stepped over: this is the
 * shape that hid modules/ModuleFormModal.tsx's manifest field from an earlier
 * version of this scan.
 */
const BETWEEN_LABEL_AND_CONTROL = /^\s*(?:\{\/\*[\s\S]*?\*\/\}|<p\b[^>]*>[\s\S]*?<\/p>)/;

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
 * Count labels that sit IMMEDIATELY in front of a control FormField models.
 *
 * "Immediately" is the operator direction's own word and is load-bearing, so
 * it is what the scan checks: the first element opened after `</label>` has to
 * be the control itself. A label followed by a wrapper element names a
 * composite — a radio pair, or a kind-selector whose select and value input
 * share one caption — and FormField, which renders one label and one control,
 * cannot express it. Counting those would report work that must not be done.
 *
 * A multi-line control tag is joined before matching, so `type=` on its own
 * line is still seen.
 */
function migratableFieldCount(source: string): number {
  const lines = source.split('\n');
  let count = 0;

  lines.forEach((line, i) => {
    if (!line.includes(LABEL_CLASS)) return;

    // From the label line itself: the caption may run over several lines, and
    // may contain markup of its own, so the close tag is the anchor.
    const window = lines.slice(i, i + SCAN_LINES).join('\n');
    const closed = window.indexOf('</label>');
    if (closed === -1) return;

    let after = window.slice(closed + '</label>'.length);
    for (;;) {
      const skippable = BETWEEN_LABEL_AND_CONTROL.exec(after);
      if (!skippable) break;
      after = after.slice(skippable[0].length);
    }

    // The name check is what rejects a closing tag; the regex only has to SEE
    // one. A pattern that could not match `</div>` would run past it and pair
    // this caption with the next field's control.
    const tag = FIRST_TAG.exec(after);
    if (!tag) return;
    if (!['input', 'select', 'textarea'].includes(tag[1])) return;

    const control = after.slice(tag.index);
    if (EXEMPT_CONTROL.test(control)) return;
    if (MIGRATABLE_CONTROL.test(control)) count += 1;
  });

  return count;
}

/**
 * Files that still hand-write a field this scan calls migratable, each with the
 * reason it stayed. An entry may only ever be removed: a new hand-written field
 * fails the first arm by name rather than quietly joining this list, and the
 * second arm fails if an entry outlives the code it describes.
 *
 * KNOWN HOLE, singular, so nobody reads the list as more than it is: the scan
 * keys on one exact class string, so a field written with a different label
 * class — `mb-2`, or the same classes in another order — is invisible to it.
 * Closing that would mean giving up the exact key for something with a real
 * false-positive rate, which is a worse trade. Everything else it used to miss
 * is now caught: a hint paragraph or a comment between the caption and the
 * control is stepped over, and a long caption no longer falls out of a fixed
 * window.
 *
 * Not a hole: a caption followed by a container rather than a control. That is
 * the composite exemption the operator direction asks for, and it is doing real
 * work — it is what keeps FirewallRuleFormModal's selector, which pairs one
 * caption with a kind select plus a value input, out of this list.
 */
const KNOWN_HAND_WRITTEN: readonly string[] = [
  // The five spec textareas need two things FormField cannot express: the
  // inherited file_spec renders readOnly, which has no prop, and all five are
  // resize-y, which the textarea branch overrides with a hardcoded resize-none
  // that a caller's className cannot reliably beat.
  'features/system/components/modules/ModuleFormModal.tsx',
];

const sources = findSources(scanRoot).map((f) => ({
  rel: path.relative(scanRoot, f),
  source: readFileSync(f, 'utf8'),
}));

describe('form field contract', () => {
  it('is scanning a real tree', () => {
    expect(existsSync(scanRoot)).toBe(true);
    expect(sources.length).toBeGreaterThan(100);
    // Pin the widened root: the page tree is where the gap was.
    expect(sources.some((f) => f.rel.startsWith('pages/'))).toBe(true);
    expect(sources.some((f) => f.rel.startsWith('features/'))).toBe(true);
  });

  it('recognises the label/control pairing it is built to find', () => {
    // Guards the guard: with an empty baseline, a heuristic that matched
    // nothing would make both arms below pass by seeing nothing at all.
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

    // A caption over a group is not a field: the control does not follow the
    // label, a container does.
    const composite = [
      '<label className="block text-sm font-medium text-theme-primary mb-1">Source</label>',
      '<div className="grid grid-cols-3 gap-2">',
      '  <select value={kind}>',
      '    <option value="all">any</option>',
      '  </select>',
      '</div>',
    ].join('\n');
    expect(migratableFieldCount(composite)).toBe(0);

    // A hint between the caption and the control still leaves one field. This
    // is the shape that hid the manifest textarea from an earlier scan.
    const hinted = [
      '<label className="block text-sm font-medium text-theme-primary mb-1">',
      '  Paste manifest.yaml',
      '</label>',
      '<p className="text-xs text-theme-secondary mb-2">',
      '  What the server does with this.',
      '</p>',
      '<textarea id="manifest_yaml" />',
    ].join('\n');
    expect(migratableFieldCount(hinted)).toBe(1);

    // A caption over a read-only value is not a field either. Its paragraph is
    // skipped like a hint, so the closing tag behind it is what has to stop the
    // scan — otherwise the caption pairs with the NEXT field's control.
    const readOnlyDisplay = [
      '  <div>',
      '    <label className="block text-sm font-medium text-theme-primary mb-1">CIDR</label>',
      '    <p className="font-mono">{vip.cidr}</p>',
      '  </div>',
      '  <input type="text" value={name} />',
    ].join('\n');
    expect(migratableFieldCount(readOnlyDisplay)).toBe(0);

    // A caption longer than any fixed lookahead still finds its control.
    const longCaption = [
      '<label className="block text-sm font-medium text-theme-primary mb-1">',
      ...Array(12).fill('  annotation line'),
      '</label>',
      '<input type="text" />',
    ].join('\n');
    expect(migratableFieldCount(longCaption)).toBe(1);
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
