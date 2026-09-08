import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs';
import path from 'node:path';

/**
 * Guards the modal-shell consolidation (IMP-a354b985dbf3).
 *
 * 34 components under `features/system/components` hand-rolled the modal
 * overlay/backdrop/panel shell in four mutually inconsistent class variants
 * while 44 siblings rendered `@/shared/components/ui/Modal`. Backdrop opacity,
 * z-index, focus handling and Escape behaviour therefore differed between
 * hubs. Every true modal now renders the core `Modal`.
 *
 * This is a RATCHET, not a snapshot, and it is modelled on the repo's
 * `core-purity-baseline.txt`: `KNOWN_HAND_ROLLED` grandfathers the shells that
 * are deliberately NOT core-`Modal` (the slide-out drawers, which are not a
 * Modal fit, and the two `platform/` panels that inline a confirm sheet). Any
 * OTHER file that hand-rolls an overlay fails the scan.
 *
 * Both arms matter:
 *   - a file outside the baseline may not hand-roll a shell (catches a
 *     regression, or a new component copy-pasting the old idiom);
 *   - every baseline entry must still exist AND still hand-roll (catches a
 *     baseline that has gone stale, so the exemption list can never quietly
 *     grow into a licence).
 *
 * `fixed inset-0` is the marker because all four historical variants opened
 * with it, and the core `Modal` renders its own overlay inside a portal — so a
 * consumer of the shared component never writes it.
 */

const componentsRoot = __dirname;

/**
 * Shells that legitimately do not use the core `Modal`.
 *
 * Each entry is a file path relative to `features/system/components`.
 * Removing an entry is the intended way to migrate one: the scan goes red
 * until the file actually renders the shared `Modal`.
 */
const KNOWN_HAND_ROLLED: readonly string[] = [
  // Slide-out drawers: anchored panels with their own transition, not centred
  // dialogs. `Modal`'s `drawer` variant is a different animation and a fixed
  // max-width, so these stay hand-rolled by decision.
  'platform/PeerDetailDrawer.tsx',
  'platform/StorageMigrationDetailDrawer.tsx',
  // Inline confirm sheets rendered by a panel rather than standalone dialogs.
  'platform/MigrationChainsPanel.tsx',
  'platform/MigrationsPanel.tsx',
  // Not a dialog at all: a full-viewport click-catcher that dismisses an
  // absolutely-positioned dropdown menu.
  'nodes/NodeInstanceControls.tsx',

  // --- Still to migrate. Shrink this list; never grow it. ---
  'operations/AgentPeersTab.tsx',
  'operations/BatchDetailModal.tsx',
  'operations/CiWebhooksTab.tsx',
  'operations/CiWorkersTab.tsx',
  'operations/GitopsTab.tsx',
  'operations/OperationDetailModal.tsx',
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

/** True when the file writes its own full-viewport overlay. */
function handRollsOverlay(source: string): boolean {
  return /fixed inset-0/.test(source);
}

const sources = findSources(componentsRoot);
const relative = (f: string) => path.relative(componentsRoot, f);

describe('modal shell contract', () => {
  it('is scanning a real tree', () => {
    // Guards the guard: a path bug that empties the list would make the
    // assertions below pass vacuously.
    expect(existsSync(componentsRoot)).toBe(true);
    expect(sources.length).toBeGreaterThan(100);
  });

  it('has no component outside the baseline hand-rolling a modal overlay', () => {
    const offenders = sources
      .filter((f) => handRollsOverlay(readFileSync(f, 'utf8')))
      .map(relative)
      .filter((f) => !KNOWN_HAND_ROLLED.includes(f))
      .sort();

    expect(offenders).toEqual([]);
  });

  it('has no stale baseline entry', () => {
    const stale = KNOWN_HAND_ROLLED.filter((entry) => {
      const full = path.join(componentsRoot, entry);
      if (!existsSync(full)) return true;
      return !handRollsOverlay(readFileSync(full, 'utf8'));
    }).sort();

    expect(stale).toEqual([]);
  });
});
