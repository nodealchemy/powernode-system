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
 * How far past a label to look for its control. Labels here are followed by a
 * closing tag and at most a required-marker span before the control opens.
 */
const LOOKAHEAD_LINES = 6;

/** Control kinds FormField models. A bare `<input>` defaults to text. */
const MIGRATABLE_CONTROL = /<(select|textarea)\b|<input\b(?![^>]*type=)|<input\b[^>]*type="(text|number|email|password|tel|url|date)"/;

/** Control kinds FormField cannot express, which stay hand-written. */
const EXEMPT_CONTROL = /<input\b[^>]*type="(radio|checkbox|file|color|range)"/;

/** The first element opened after the label closes. */
const FIRST_ELEMENT = /<([A-Za-z][A-Za-z0-9]*)/;

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
    const window = lines.slice(i, i + 1 + LOOKAHEAD_LINES).join(' ');
    if (!window.includes('</label>')) return;

    const after = window.split('</label>')[1];
    const opened = FIRST_ELEMENT.exec(after);
    if (!opened) return;
    if (!['input', 'select', 'textarea'].includes(opened[1])) return;

    const control = after.slice(opened.index);
    if (EXEMPT_CONTROL.test(control)) return;
    if (MIGRATABLE_CONTROL.test(control)) count += 1;
  });

  return count;
}

/**
 * Files that still hand-write at least one migratable field.
 *
 * Now empty: every one of them was converted. It stays here for the first arm,
 * which is what keeps it empty — a new hand-written field fails that arm by
 * name rather than quietly joining a list. The second arm is dormant while the
 * list is empty and exists so that a future entry cannot outlive its file.
 *
 * KNOWN HOLES, so nobody reads this as more than it is. The scan keys on one
 * exact class string and on the control following the label directly, so it
 * does not see: a different label class (`mb-2`, or the same classes reordered),
 * a control wrapped in a positioning div, a hint paragraph sitting between the
 * label and its control, or a caption running past LOOKAHEAD_LINES. Real
 * examples of the last two survive in modules/ModuleFormModal.tsx, where the
 * spec textareas are separately unmigratable anyway — one is readOnly, which
 * FormField has no prop for. This arm catches the shape that was repeated 180
 * times; it is not a proof of absence.
 */
const KNOWN_HAND_WRITTEN: readonly string[] = [];

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
