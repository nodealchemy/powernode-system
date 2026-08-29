import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type { SdwanMyDevice } from '../../types/sdwan.types';

// Self-service SDWAN device retrieval — the RECIPIENT's half of the
// agent-issued-device design (increments 2 + 3a server-side).
//
// Distinct from `sdwanApi`'s user-device calls, which are the OPERATOR's:
// those are nested under `networks/:id/access_grants/:id/user_devices` and
// gated on `system.sdwan.user_devices.manage`. These two are top-level,
// authorized by OWNERSHIP alone (the caller's own Sdwan::AccessGrant rows),
// and carry no permission string — a VPN recipient is an ordinary user and
// an undefined permission name degrades to admin-only on this platform,
// which would lock out exactly the person the endpoints exist to serve.
//
// WHY THE DOWNLOAD IS BUILT CLIENT-SIDE AND NOT A LINK
// ---------------------------------------------------
// `GET /system/sdwan/my_devices/:id/config` is JWT-authenticated like every
// other SPA call. Navigating the browser to that URL — `window.location`,
// `window.open`, or an `<a href>` pointing at it — sends a plain top-level
// navigation with NO Authorization header, so the endpoint answers 401 and
// the user sees an error page instead of their config. The config therefore
// has to come back through `apiClient` (whose request interceptor attaches
// the bearer token) and be handed to the user as an object-URL built from
// the response body. Same shape as `nodesApi.downloadInstanceBootConfig`,
// except for when the object URL is revoked — see the note at that line.

// One macrotask is enough to let the browser's save start before the blob is
// released; a fixed small delay (rather than 0) also covers engines that defer
// the read by a frame.
const OBJECT_URL_REVOKE_DELAY_MS = 250;

/** Filename-safe slug for a user-chosen device label. */
function configFilename(label: string, deviceId: string): string {
  const slug = label
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .slice(0, 40)
    // Trim AFTER slicing as well as implicitly before: a long label cut at 40
    // characters can land mid-separator and leave a trailing hyphen.
    .replace(/^-+|-+$/g, '');
  // WireGuard's wg-quick derives the interface name from the filename and
  // rejects anything that isn't a valid interface name, so fall back to the
  // device id rather than emitting a bare ".conf".
  return `${slug || `device-${deviceId.slice(0, 8)}`}.conf`;
}

/**
 * Read a Blob as text without assuming `Blob.prototype.text` exists.
 *
 * Browsers have had `.text()` for years, but jsdom (the test environment)
 * ships a Blob with neither `.text()` nor `.arrayBuffer()`, so a `.text()`-only
 * implementation silently loses the server's refusal message under test — the
 * exact wording this function exists to surface. FileReader is present in both.
 */
async function blobToText(blob: Blob): Promise<string> {
  if (typeof blob.text === 'function') {
    return blob.text();
  }
  if (typeof FileReader === 'undefined') return '';
  return new Promise<string>((resolve) => {
    const reader = new FileReader();
    reader.onload = () => resolve(typeof reader.result === 'string' ? reader.result : '');
    reader.onerror = () => resolve('');
    try {
      reader.readAsText(blob);
    } catch {
      resolve('');
    }
  });
}

/**
 * Best-effort human message from a failed config fetch.
 *
 * The endpoint's refusals are text/plain `# <reason>\n` bodies (401/404/410/503
 * — see MyDevicesController#render_text_error), but because the request asks
 * for `responseType: 'blob'` axios hands the body back as a Blob, not a
 * string. Read it if we can; never let this throw over the original error.
 */
async function failureMessage(err: unknown): Promise<string> {
  const response = (err as { response?: { status?: number; data?: unknown } })?.response;
  if (!response) {
    return err instanceof Error && err.message ? err.message : 'Download failed';
  }

  let text = '';
  const data = response.data;
  if (typeof data === 'string') {
    text = data;
  } else if (data instanceof Blob) {
    try {
      text = await blobToText(data);
    } catch {
      text = '';
    }
  }

  const cleaned = text.replace(/^#\s*/, '').trim();
  return cleaned || `Download failed (HTTP ${response.status ?? 'error'})`;
}

export const myDevicesApi = {
  /**
   * The caller's own SDWAN devices. Ownership-scoped server-side; there is
   * no filter to pass and no "all devices" mode to ask for.
   */
  listMyDevices: async (): Promise<SdwanMyDevice[]> => {
    const response = await apiClient.get<ApiEnvelope<{ devices: SdwanMyDevice[] }>>(
      '/system/sdwan/my_devices'
    );
    return extractData(response).devices ?? [];
  },

  /**
   * Fetch one device's WireGuard config with the session JWT and hand it to
   * the user as a downloaded file. Resolves once the save has been triggered.
   *
   * Rejects with a plain Error carrying the server's own refusal text on
   * 401/404/410/503 so the caller can surface it verbatim.
   *
   * NOTE ON SIDE EFFECTS: every successful fetch stamps `last_downloaded_at`
   * server-side, and if the device still has a live operator-issued bootstrap
   * URL that fetch consumes it (the link then answers 410). That is single-use
   * working as designed, but it is why the UI should not invite idle
   * re-fetching.
   */
  downloadMyDeviceConfig: async (deviceId: string, label: string): Promise<void> => {
    let payload: unknown;
    try {
      const response = await apiClient.get<Blob>(
        `/system/sdwan/my_devices/${deviceId}/config`,
        { responseType: 'blob' }
      );
      payload = response.data;
    } catch (err) {
      throw new Error(await failureMessage(err));
    }

    // Test doubles and some proxies hand back a string even when a blob was
    // asked for. Wrap only in that case — `String(aBlob)` would stringify to
    // the literal "[object Blob]" and write that into the user's config file.
    const blob =
      payload instanceof Blob
        ? payload
        : new Blob([String(payload ?? '')], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    try {
      const link = document.createElement('a');
      link.href = url;
      link.download = configFilename(label, deviceId);
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
    } finally {
      // DEFERRED, not synchronous. `nodesApi.downloadInstanceBootConfig`
      // revokes inline right after `.click()`; that is safe in Chromium,
      // where the click starts the save in the same task, but Safari and
      // some Firefox versions have not yet read the blob when the current
      // task ends and the save silently produces an empty file. Diverging
      // from that precedent deliberately: once increment 4 stops minting
      // bootstrap URLs this is the ONLY way a recipient gets their config,
      // so a browser-specific silent failure here strands them. Revoking is
      // still worth doing rather than leaking — the object URL holds the
      // device's private key in memory for as long as it lives.
      setTimeout(() => {
        try {
          URL.revokeObjectURL(url);
        } catch {
          // The document (or, under test, the URL stub) can be torn down
          // before the timer fires. Nothing to clean up in that case, and an
          // uncaught throw from a stray timer is noise, not a signal.
        }
      }, OBJECT_URL_REVOKE_DELAY_MS);
    }
  },
};
