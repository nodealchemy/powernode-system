import { readFileSync, readdirSync, statSync } from 'fs';
import { join, relative } from 'path';

// Disk-image webhook path contract (IMP-92f3bfda6aed).
//
// `webhook_url_path` is the path an operator copies into a CI provider to
// point it at this platform. A wrong one silently never fires: nothing 404s in
// the UI, the provider just posts into the void.
//
// It was spelled three different ways, and only the server's was right:
//   - the serializer emits  /api/v1/system/webhooks/disk_image/built/<id>
//   - CiWebhooksTab.test.tsx pinned /api/v1/system/disk_image_webhooks/<id>/receive
//   - diskImageWebhooksApi.test.ts used /hooks/disk_image/<id>
// The last two match no route at all. Nothing caught it: CiWebhooksTab only
// renders the string it is handed, so every example passed on a value the
// server has never produced, and the route-parity lint skips *.test.tsx by
// design because a call in a spec is not a UI caller.
//
// The path now has ONE home, System::DiskImageWebhook#webhook_url_path, and the
// serializer, the controller and the deferred-path executor delegate to it.
// The second assertion below is what keeps that true.
//
// A further producer exists in CORE, not this extension: the disk-image
// operator MCP tool builds the same URL. EXT_ROOT-rooted reads cannot see it,
// and it is covered by core's own specs, so it is named here, not guarded.
//
// This lives in its own contract spec rather than inline in one of the two
// specs, as IMP-e27e26fbf2d9 did, because the two consumers sit in unrelated
// directories: a guard inline in either one would be structurally blind to the
// other, which is the exact mistake that let this survive.
//
// WHAT IS PINNED AND WHAT IS DERIVED. WEBHOOK_PATH_PREFIX stays a LITERAL: it
// is the wire value under test. Computing it from the server file would make
// this spec agree with the server by construction and test nothing. The server
// read is the ORACLE, not the source of the value.

const API_DIR = __dirname;
const SRC_ROOT = join(API_DIR, '..', '..', '..', '..');
const EXT_ROOT = join(API_DIR, '..', '..', '..', '..', '..', '..');

/** The path prefix the server emits. Pinned against both emitters below. */
const WEBHOOK_PATH_PREFIX = '/api/v1/system/webhooks/disk_image/built/';

/**
 * Read the single quoted occurrence of a pattern from a server file.
 *
 * matchAll with an exact count, never String.match: match takes the FIRST hit
 * and cannot tell code from prose, so a quoted example pasted into a comment
 * would silently re-anchor the oracle while the real emitter drifted.
 */
function soleMatch(file: string, pattern: RegExp, what: string): string {
  const source = readFileSync(file, 'utf8');
  const hits = [...source.matchAll(pattern)];
  if (hits.length !== 1) {
    throw new Error(
      `Expected exactly one ${what} in ${relative(EXT_ROOT, file)}, found ${hits.length}. ` +
      'If the emitter moved or changed shape, update this guard rather than deleting it.',
    );
  }
  return hits[0][1];
}

/** Every file with one of the given extensions under a directory. */
function walk(dir: string, out: string[] = [], ext?: string): string[] {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules') continue;
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) walk(full, out, ext);
    else if (ext ? entry.endsWith(ext) : entry.endsWith('.ts') || entry.endsWith('.tsx')) {
      out.push(full);
    }
  }
  return out;
}

describe('disk-image webhook path contract', () => {
  it('pins the path prefix the model emits', () => {
    const emitted = soleMatch(
      join(EXT_ROOT, 'server', 'app', 'models', 'system', 'disk_image_webhook.rb'),
      /"(\/api\/v\d+\/[^"]*disk_image\/built\/)#\{id\}"/g,
      'webhook_url_path literal',
    );
    expect(WEBHOOK_PATH_PREFIX).toBe(emitted);
  });

  it('keeps the model as the ONLY server-side home for that path', () => {
    // The serializer, the controller and the deferred-path executor all emit
    // this URL. They used to build it independently, and the executor's copy
    // was missing entirely — an operator whose rotation was approved
    // asynchronously got a secret with no URL beside it. They now delegate to
    // the model, and this is what stops a fourth emitter re-introducing a
    // private copy that can drift from the other three.
    //
    // Comment lines are skipped: the receiving controller documents the route
    // it implements in a header comment, which is not a second emitter.
    const serverApp = join(EXT_ROOT, 'server', 'app');
    const owner = join(serverApp, 'models', 'system', 'disk_image_webhook.rb');
    const offenders: string[] = [];

    for (const file of walk(serverApp, [], '.rb')) {
      if (file === owner) continue;
      readFileSync(file, 'utf8')
        .split('\n')
        .forEach((line, i) => {
          if (/^\s*#/.test(line)) return;
          if (line.includes('/webhooks/disk_image/built/')) {
            offenders.push(`${relative(EXT_ROOT, file)}:${i + 1}`);
          }
        });
    }

    expect(offenders).toEqual([]);
  });

  it('has no disk-image webhook DELIVERY path in the frontend with a different prefix', () => {
    // Tree-wide, not directory-scoped: the two offending fixtures lived in
    // features/system/components/operations and features/system/services/api,
    // and a guard scoped to either would be blind to the other.
    //
    // Delivery paths only. `/system/disk_image_webhooks` and its members are
    // the CRUD endpoints for managing these webhooks — real routes, correctly
    // spelled, and none of this rule's business.
    //
    // The discriminator is SEGMENT-aware on purpose. A substring test for
    // `hooks/` also matches `disk_image_webhooks/`, which swept every CRUD
    // path into the finding list. A delivery endpoint is one with a `hooks` or
    // `webhooks` path SEGMENT, or a trailing `receive`.
    // Excluding this file is load-bearing, not tidiness: its own
    // WEBHOOK_PATH_PREFIX literal is delivery-shaped and prefix-compliant, so
    // leaving it in would keep `seen` above zero even if every fixture were
    // deleted, turning the anti-vacuity check below into a silent pass.
    const files = walk(SRC_ROOT).filter((f) => f !== __filename);
    expect(files.length).toBeGreaterThan(0);

    const STRING_LITERAL = /['"`]([^'"`\n]*)['"`]/g;
    // Scanning by KEY as well as by shape. The shape test alone cannot see a
    // fixture set to a CRUD MEMBER path — `/api/v1/system/disk_image_webhooks/
    // <id>` is one segment, not a `webhooks` segment, and it ends in the id
    // rather than `receive` — which is the most plausible next drift precisely
    // because that path does resolve. The key test catches it; the shape test
    // catches a bare literal that never passes through one of these keys.
    const KEYED_VALUE = /\bwebhook_url(?:_path)?\s*:\s*['"`]([^'"`\n]*)['"`]/g;

    const stripOrigin = (value: string): string =>
      /^https?:\/\//.test(value) ? value.replace(/^https?:\/\/[^/]+/, '') : value;

    const offenders = new Set<string>();
    let seen = 0;

    for (const file of files) {
      const source = readFileSync(file, 'utf8');
      const label = relative(SRC_ROOT, file);

      for (const [, literal] of source.matchAll(STRING_LITERAL)) {
        if (!literal.includes('disk_image')) continue;
        const segments = stripOrigin(literal).split('/');
        const isDelivery =
          segments.some((seg) => seg === 'hooks' || seg === 'webhooks') ||
          segments[segments.length - 1] === 'receive';
        if (!isDelivery) continue;
        seen += 1;
        if (!stripOrigin(literal).startsWith(WEBHOOK_PATH_PREFIX)) {
          offenders.add(`${label}: ${literal}`);
        }
      }

      for (const [, value] of source.matchAll(KEYED_VALUE)) {
        seen += 1;
        if (!stripOrigin(value).startsWith(WEBHOOK_PATH_PREFIX)) {
          offenders.add(`${label}: ${value}`);
        }
      }
    }

    // Without this, deleting every fixture would read as a clean pass.
    expect(seen).toBeGreaterThan(0);
    expect([...offenders]).toEqual([]);
  });
});
