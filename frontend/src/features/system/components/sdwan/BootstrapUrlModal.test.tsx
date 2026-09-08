import React from 'react';
import { readFileSync, readdirSync, statSync } from 'fs';
import { join, relative } from 'path';

/** Every .test.tsx under a directory, for the cross-spec path scan below. */
function walkSpecs(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) walkSpecs(full, out);
    else if (entry.endsWith('.test.tsx')) out.push(full);
  }
  return out;
}
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BootstrapUrlModal } from './BootstrapUrlModal';
import type { SdwanIssueUserDeviceResponse } from '../../types/sdwan.types';

// =============================================================================
// Fixtures
// =============================================================================

/** The bootstrap path prefix the server emits. Pinned against it below. */
const BOOTSTRAP_PATH_PREFIX = '/api/v1/system/sdwan/bootstrap/';

const DEVICE_RESULT: SdwanIssueUserDeviceResponse = {
  user_device: {
    id: 'dev-1',
    access_grant_id: 'grant-1',
    label: 'laptop-alice',
    public_key: 'ABC123publickey==',
    assigned_address: '10.0.0.42/32',
    downloadable: true,
    last_downloaded_at: null,
    last_seen_at: null,
    revoked_at: null,
    created_at: '2026-06-01T12:00:00Z',
  },
  bootstrap: {
    token: 'opaque-token-blob',
    url: '/api/v1/system/sdwan/bootstrap/opaque-token-blob',
    expires_at: '2026-06-01T13:00:00Z',
  },
};

// =============================================================================
// Clipboard mock
// =============================================================================

const mockWriteText = jest.fn();
Object.defineProperty(navigator, 'clipboard', {
  value: { writeText: mockWriteText },
  writable: true,
});

// =============================================================================
// Helpers
// =============================================================================

interface RenderOpts {
  isOpen?: boolean;
  result?: SdwanIssueUserDeviceResponse | null;
  onClose?: jest.Mock;
}

function renderModal({ isOpen = true, result = DEVICE_RESULT, onClose = jest.fn() }: RenderOpts = {}) {
  return render(
    <BootstrapUrlModal isOpen={isOpen} result={result} onClose={onClose} />,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('BootstrapUrlModal', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockWriteText.mockResolvedValue(undefined);
  });

  // ── Null-result guard ────────────────────────────────────────────────────────

  it('renders nothing when result is null', () => {
    const { container } = renderModal({ result: null });
    expect(container).toBeEmptyDOMElement();
  });

  // ── Closed state ─────────────────────────────────────────────────────────────

  it('renders nothing when isOpen is false even with a result', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText(/Bootstrap URL/i)).not.toBeInTheDocument();
  });

  // ── Open / visible state ─────────────────────────────────────────────────────

  it('renders the modal title including the device label', () => {
    renderModal();
    expect(
      screen.getByText(/Bootstrap URL — laptop-alice/i),
    ).toBeInTheDocument();
  });

  it('displays the single-use warning with expiry date', () => {
    renderModal();
    const formattedExpiry = new Date('2026-06-01T13:00:00Z').toLocaleString();
    expect(
      screen.getByText(new RegExp(`Single-use, expires ${formattedExpiry}`, 'i')),
    ).toBeInTheDocument();
  });

  it('shows the full bootstrap URL composed from window.location.origin + path', () => {
    renderModal();
    const expectedUrl = `${window.location.origin}/api/v1/system/sdwan/bootstrap/opaque-token-blob`;
    const input = screen.getByRole<HTMLInputElement>('textbox');
    expect(input.value).toBe(expectedUrl);
  });

  it('renders the input as read-only', () => {
    renderModal();
    const input = screen.getByRole<HTMLInputElement>('textbox');
    expect(input).toHaveAttribute('readonly');
  });

  it('displays the device assigned address', () => {
    renderModal();
    expect(screen.getByText('10.0.0.42/32')).toBeInTheDocument();
  });

  it('displays the device public key', () => {
    renderModal();
    expect(screen.getByText('ABC123publickey==')).toBeInTheDocument();
  });

  it('renders a Copy button initially', () => {
    renderModal();
    expect(screen.getByRole('button', { name: /copy/i })).toBeInTheDocument();
  });

  it('renders a Done button', () => {
    renderModal();
    expect(screen.getByRole('button', { name: /done/i })).toBeInTheDocument();
  });

  // ── Copy interaction ─────────────────────────────────────────────────────────

  it('calls clipboard.writeText with the full URL when Copy is clicked', async () => {
    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /copy/i }));
    await waitFor(() => {
      expect(mockWriteText).toHaveBeenCalledWith(
        `${window.location.origin}/api/v1/system/sdwan/bootstrap/opaque-token-blob`,
      );
    });
  });

  it('changes the button label to "Copied" immediately after successful copy', async () => {
    renderModal();
    fireEvent.click(screen.getByRole('button', { name: /copy/i }));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /copied/i })).toBeInTheDocument(),
    );
  });

  it('resets the button label back to "Copy" after 2 seconds', async () => {
    jest.useFakeTimers();
    renderModal();

    fireEvent.click(screen.getByRole('button', { name: /copy/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /copied/i })).toBeInTheDocument(),
    );

    act(() => {
      jest.advanceTimersByTime(2000);
    });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^copy$/i })).toBeInTheDocument(),
    );

    jest.useRealTimers();
  });

  it('does not throw when clipboard API is unavailable (silently falls back)', async () => {
    mockWriteText.mockRejectedValue(new Error('Clipboard unavailable'));
    renderModal();

    expect(() => {
      fireEvent.click(screen.getByRole('button', { name: /copy/i }));
    }).not.toThrow();

    // Button should not transition to "Copied" if clipboard failed
    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /copied/i })).not.toBeInTheDocument(),
    );
  });

  // ── Input selection on focus ─────────────────────────────────────────────────

  it('selects all text in the input when it is focused', () => {
    renderModal();
    const input = screen.getByRole<HTMLInputElement>('textbox');
    const selectSpy = jest.spyOn(input, 'select');
    fireEvent.focus(input);
    expect(selectSpy).toHaveBeenCalled();
  });

  // ── Done / close ─────────────────────────────────────────────────────────────

  it('calls onClose when the Done button is clicked', () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    fireEvent.click(screen.getByRole('button', { name: /done/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when the modal X (close) button is clicked', () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    fireEvent.click(screen.getByLabelText('Close modal'));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ── Expiry rendering ─────────────────────────────────────────────────────────

  it('formats expires_at using toLocaleString', () => {
    const expiresAt = '2026-12-31T23:59:59Z';
    const result: SdwanIssueUserDeviceResponse = {
      ...DEVICE_RESULT,
      bootstrap: {
        ...DEVICE_RESULT.bootstrap,
        expires_at: expiresAt,
      },
    };
    renderModal({ result });
    const expected = new Date(expiresAt).toLocaleString();
    expect(screen.getByText(new RegExp(expected, 'i'))).toBeInTheDocument();
  });

  // ── Different device label ────────────────────────────────────────────────────

  it('includes the device label in the modal title', () => {
    const result: SdwanIssueUserDeviceResponse = {
      ...DEVICE_RESULT,
      user_device: { ...DEVICE_RESULT.user_device, label: 'workstation-bob' },
    };
    renderModal({ result });
    expect(
      screen.getByText(/Bootstrap URL — workstation-bob/i),
    ).toBeInTheDocument();
  });

  // ── URL construction edge case ────────────────────────────────────────────────

  it('handles a bootstrap URL with a custom path segment', () => {
    const result: SdwanIssueUserDeviceResponse = {
      ...DEVICE_RESULT,
      bootstrap: {
        ...DEVICE_RESULT.bootstrap,
        url: '/api/v1/system/sdwan/bootstrap/different-token-xyz',
      },
    };
    renderModal({ result });
    const expected = `${window.location.origin}/api/v1/system/sdwan/bootstrap/different-token-xyz`;
    const input = screen.getByRole<HTMLInputElement>('textbox');
    expect(input.value).toBe(expected);
  });

  // ── Explanatory prose ─────────────────────────────────────────────────────────

  it('renders the one-time-use explanation text', () => {
    renderModal();
    expect(
      screen.getByText(/WireGuard config exactly once/i),
    ).toBeInTheDocument();
  });

  it('renders the 410 Gone warning about lost URLs', () => {
    renderModal();
    expect(screen.getByText(/410 Gone/i)).toBeInTheDocument();
  });

  // ── Label rendering ───────────────────────────────────────────────────────────

  it('renders the "Bootstrap URL" field label', () => {
    renderModal();
    expect(screen.getByText('Bootstrap URL')).toBeInTheDocument();
  });

  it('renders the "Device address:" label with the assigned address', () => {
    renderModal();
    expect(screen.getByText(/Device address:/i)).toBeInTheDocument();
  });

  it('renders the "Public key:" label with the public key', () => {
    renderModal();
    expect(screen.getByText(/Public key:/i)).toBeInTheDocument();
  });

  // ── Server path parity ────────────────────────────────────────────────────────
  //
  // This modal shows the operator the exact URL a user will fetch their
  // WireGuard config from. The URL is single-use and token-authenticated, so an
  // operator who copies a wrong path hands the user a link that 404s with no
  // signal about which half is wrong.
  //
  // The component only renders the URL it is handed, so a wrong fixture breaks
  // nothing and every example still passes — which is exactly why the fixtures
  // sat on a path the server has never emitted. The assertions below tie them
  // to the server's own emitter so they cannot drift again.
  //
  // Note what is pinned and what is derived. BOOTSTRAP_PATH_PREFIX stays a
  // LITERAL: it is the wire value under test, and computing the fixtures from
  // the server file instead would make this spec agree with the server by
  // construction and test nothing. The server read is the ORACLE, not the
  // source of the value.

  /** The prefix the server actually emits, read from its emitter. */
  const serverBootstrapPrefix = (): string => {
    const controller = readFileSync(
      join(
        __dirname, '..', '..', '..', '..', '..', '..',
        'server', 'app', 'controllers', 'api', 'v1', 'system', 'sdwan',
        'user_devices_controller.rb',
      ),
      'utf8',
    );
    // matchAll + an exact count, not `.match`, which takes the FIRST hit and
    // cannot tell code from prose. That file opens with a header comment about
    // this very URL, so a quoted example pasted there later would silently
    // re-anchor this oracle onto a comment while the real emitter drifted.
    const hits = [...controller.matchAll(/"(\/api\/v\d+\/[^"]*bootstrap\/)#\{token\}"/g)];
    if (hits.length !== 1) {
      throw new Error(
        `Expected exactly one bootstrap URL literal in user_devices_controller.rb, found ${hits.length}. ` +
        'If the emitter moved or changed shape, update this guard rather than deleting it.',
      );
    }
    return hits[0][1];
  };

  it('pins the bootstrap path prefix the server actually emits', () => {
    expect(BOOTSTRAP_PATH_PREFIX).toBe(serverBootstrapPrefix());
  });

  it('builds its fixture URLs from that prefix', () => {
    expect(DEVICE_RESULT.bootstrap.url).toBe(`${BOOTSTRAP_PATH_PREFIX}opaque-token-blob`);
  });

  it('has no bootstrap path in any sdwan spec that uses a different prefix', () => {
    // Scoped to the whole sdwan component tree, not just this file. The same
    // defect was also sitting in AccessTab.test.tsx, which feeds this very
    // modal a fixture of its own — a guard that only read __filename would
    // never have seen it, and would not see the next one either.
    //
    // The fixtures this scans must stay LITERAL. Writing them as
    // `${BOOTSTRAP_PATH_PREFIX}token` would satisfy the assertion above while
    // leaving this one nothing to find, and the empty-match guard below would
    // then fail on what looks like a harmless cleanup.
    const specs = walkSpecs(__dirname);
    expect(specs.length).toBeGreaterThan(0);

    const offenders: string[] = [];
    let seen = 0;
    for (const file of specs) {
      const found =
        readFileSync(file, 'utf8').match(
          /\/api\/v\d+\/[A-Za-z0-9_\/-]*bootstrap\/[A-Za-z0-9_-]+/g,
        ) ?? [];
      seen += found.length;
      for (const path of found) {
        if (!path.startsWith(BOOTSTRAP_PATH_PREFIX)) {
          offenders.push(`${relative(__dirname, file)}: ${path}`);
        }
      }
    }
    // Without this, deleting every fixture would read as a clean pass.
    expect(seen).toBeGreaterThan(0);
    expect(offenders).toEqual([]);
  });
});
