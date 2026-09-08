import React from 'react';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { HoneypotCanaryTile } from './HoneypotCanaryTile';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();
const mockLoggerWarn = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: (...args: unknown[]) => mockPost(...args),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

// Mirrors the real logger's full surface (logger.ts) — a partial mock turns a
// later logger.apiError(...) anywhere in this module graph into a confusing
// "not a function" instead of an obvious mock gap.
jest.mock('@/shared/utils/logger', () => {
  const stub = {
    debug: jest.fn(),
    info: jest.fn(),
    warn: (...args: unknown[]) => mockLoggerWarn(...args),
    error: jest.fn(),
    apiStart: jest.fn(),
    apiComplete: jest.fn(),
    apiError: jest.fn(),
    child: jest.fn(() => stub),
  };
  return { ...jest.requireActual('@/shared/utils/logger'), logger: stub };
});

// =============================================================================
// Helpers
// =============================================================================

// Double-envelope: AxiosResponse.data = { success: true, data: <payload> }
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function signalsResponse(events: FleetEventStub[]) {
  return envelope({ events, count: events.length, channel: 'system_fleet' });
}

interface FleetEventStub {
  id: string;
  account_id: string;
  kind: string;
  severity: 'low' | 'medium' | 'high' | 'critical';
  payload: Record<string, unknown>;
  correlation_id: string | null;
  source: string | null;
  emitted_at: string;
}

function makeEvent(id: string, emittedAt: Date): FleetEventStub {
  return {
    id,
    account_id: 'acct-1',
    kind: 'system.honeypot_triggered',
    severity: 'high',
    payload: {},
    correlation_id: null,
    source: null,
    emitted_at: emittedAt.toISOString(),
  };
}

// Build timestamps relative to now
const now = Date.now();
const TWENTY_THREE_HOURS_AGO = new Date(now - 23 * 60 * 60 * 1000);
const TWENTY_FIVE_HOURS_AGO = new Date(now - 25 * 60 * 60 * 1000);
const SIX_DAYS_AGO = new Date(now - 6 * 24 * 60 * 60 * 1000);
const EIGHT_DAYS_AGO = new Date(now - 8 * 24 * 60 * 60 * 1000);

const EVENT_WITHIN_24H = makeEvent('evt-1', TWENTY_THREE_HOURS_AGO);
const EVENT_WITHIN_7D_NOT_24H = makeEvent('evt-2', TWENTY_FIVE_HOURS_AGO);
const EVENT_WITHIN_7D_ALSO = makeEvent('evt-3', SIX_DAYS_AGO);
const EVENT_OLDER_THAN_7D = makeEvent('evt-4', EIGHT_DAYS_AGO);

// =============================================================================
// Tests
// =============================================================================

describe('HoneypotCanaryTile', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockLoggerWarn.mockReset();
  });

  // Only the two outage-stamp tests install fake timers; everything else runs
  // on the real clock, so put it back rather than leaking a frozen one.
  afterEach(() => {
    jest.useRealTimers();
  });

  // ---------------------------------------------------------------------------
  // Render / Loading state
  // ---------------------------------------------------------------------------

  it('renders the tile label "Honeypot Canaries" immediately', () => {
    mockPost.mockReturnValue(new Promise(() => {})); // never resolves
    render(<HoneypotCanaryTile />);
    expect(screen.getByText('Honeypot Canaries')).toBeInTheDocument();
  });

  it('shows Loading… text while the API call is in flight', () => {
    mockPost.mockReturnValue(new Promise(() => {}));
    render(<HoneypotCanaryTile />);
    expect(screen.getByText(/Loading…/)).toBeInTheDocument();
  });

  it('hides the loading text once the API resolves', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // API call shape
  // ---------------------------------------------------------------------------

  it('POSTs to /system/fleet/signals with kind and limit params', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));
    expect(mockPost).toHaveBeenCalledWith('/system/fleet/signals', {
      kind: 'system.honeypot_triggered',
      limit: 100,
    });
  });

  // ---------------------------------------------------------------------------
  // Empty / clean state (no events)
  // ---------------------------------------------------------------------------

  it('shows 0 for both windows when there are no events', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());

    // Both 24h and 7d counts should be 0
    const allZeroes = screen.getAllByText('0');
    expect(allZeroes.length).toBeGreaterThanOrEqual(2);
  });

  it('does not show the ALERT badge when there are no recent events', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
  });

  it('does not show "Last access:" when there are no recent events', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.queryByText(/Last access:/)).not.toBeInTheDocument();
  });

  it('uses the plain Shield icon (no ShieldAlert) when last24h is empty', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    // ShieldAlert is not rendered — no element with the text-theme-error-fg icon class in icon area
    // We verify by absence of the ALERT badge (indicator of ShieldAlert path)
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Events within 24h — alert state
  // ---------------------------------------------------------------------------

  it('shows ALERT badge when there is at least one event within 24h', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());
  });

  it('counts the correct number of events within last 24h', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_24H, EVENT_WITHIN_7D_NOT_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    // last24h count is 1 (only EVENT_WITHIN_24H qualifies)
    expect(screen.getByText('1')).toBeInTheDocument();
  });

  it('shows "Last access:" timestamp when last24h > 0', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Last access:/)).toBeInTheDocument());
  });

  it('Last access timestamp reflects the first event (accessEvents[0])', async () => {
    // When the API returns events, accessEvents[0] is what drives the Last access line.
    // EVENT_WITHIN_24H has emitted_at = TWENTY_THREE_HOURS_AGO.
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Last access:/)).toBeInTheDocument());
    // Timestamp rendered via toLocaleString() — just ensure something follows "Last access:"
    const lastAccessEl = screen.getByText(/Last access:/);
    expect(lastAccessEl.textContent).toMatch(/Last access:\s*.+/);
  });

  // ---------------------------------------------------------------------------
  // Events within 7d but not 24h — warning state (no ALERT badge)
  // ---------------------------------------------------------------------------

  it('does not show ALERT badge when events are only within 7d (not 24h)', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_7D_NOT_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
  });

  it('shows 0 for last 24h and correct count for last 7d when events are older than 24h', async () => {
    mockPost.mockResolvedValue(
      signalsResponse([EVENT_WITHIN_7D_NOT_24H, EVENT_WITHIN_7D_ALSO]),
    );
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    // last24h = 0
    expect(screen.getByText('0')).toBeInTheDocument();
    // last7d = 2
    expect(screen.getByText('2')).toBeInTheDocument();
  });

  it('does not show "Last access:" when events are only within 7d', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_WITHIN_7D_NOT_24H]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.queryByText(/Last access:/)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Events older than 7d — clean state (counted in accessEvents but filtered out)
  // ---------------------------------------------------------------------------

  it('excludes events older than 7d from both window counts', async () => {
    mockPost.mockResolvedValue(signalsResponse([EVENT_OLDER_THAN_7D]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    // Both counts should be 0
    const zeroes = screen.getAllByText('0');
    expect(zeroes.length).toBeGreaterThanOrEqual(2);
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Mixed events across windows
  // ---------------------------------------------------------------------------

  it('correctly counts events across multiple windows simultaneously', async () => {
    const events = [
      EVENT_WITHIN_24H,         // in both last24h and last7d
      EVENT_WITHIN_7D_NOT_24H,  // in last7d only
      EVENT_WITHIN_7D_ALSO,     // in last7d only
      EVENT_OLDER_THAN_7D,      // excluded from both
    ];
    mockPost.mockResolvedValue(signalsResponse(events));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());
    // last24h = 1
    expect(screen.getByText('1')).toBeInTheDocument();
    // last7d = 3 (events within 7d window includes the one within 24h too)
    expect(screen.getByText('3')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Window labels
  // ---------------------------------------------------------------------------

  it('renders "last 24h" and "last 7d" labels', async () => {
    mockPost.mockResolvedValue(signalsResponse([]));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());
    expect(screen.getByText('last 24h')).toBeInTheDocument();
    expect(screen.getByText('last 7d')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error / network failure (IMP-a133d32b7e4e)
  //
  // This tile is a security canary, so "we could not ask" must never render as
  // "nobody touched the honeypots". The old behaviour swallowed the failure and
  // showed 0/0 in the neutral tone — pixel-identical to a quiet fleet. These
  // tests replace the three that pinned that behaviour.
  // ---------------------------------------------------------------------------

  it('renders an unavailable state instead of a zero-count all-clear on API error', async () => {
    mockPost.mockRejectedValue(new Error('network failure'));
    render(<HoneypotCanaryTile />);

    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());

    // The counts and their window labels must be gone: a 0 an operator can read
    // as "no intrusions" is the whole defect.
    expect(screen.queryByText('last 24h')).not.toBeInTheDocument();
    expect(screen.queryByText('last 7d')).not.toBeInTheDocument();
    expect(screen.queryByText('0')).not.toBeInTheDocument();
  });

  it('carries a warning tone, not the neutral tone, on API error', async () => {
    mockPost.mockRejectedValue(new Error('network failure'));
    const { container } = render(<HoneypotCanaryTile />);

    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());

    const tile = container.firstElementChild as HTMLElement;
    expect(tile.className).toContain('border-theme-warning-border');
    // `border-theme` alone is the quiet-fleet tone.
    expect(tile.className).not.toMatch(/border-theme(?![\w-])/);
  });

  it('does not show the ALERT badge on API error', async () => {
    mockPost.mockRejectedValue(new Error('network failure'));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
  });

  it('does not show "Last access:" on API error', async () => {
    mockPost.mockRejectedValue(new Error('network failure'));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());
    expect(screen.queryByText(/Last access:/)).not.toBeInTheDocument();
  });

  it('logs the failure through the shared logger', async () => {
    mockPost.mockRejectedValue(new Error('network failure'));
    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());
    expect(mockLoggerWarn).toHaveBeenCalled();
  });

  it('retries the fetch and recovers when the operator clicks Retry', async () => {
    mockPost
      .mockRejectedValueOnce(new Error('network failure'))
      .mockResolvedValueOnce(signalsResponse([EVENT_WITHIN_24H]));

    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /retry/i }));

    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());
    expect(screen.queryByText(/Signal feed unavailable/i)).not.toBeInTheDocument();
    expect(mockPost).toHaveBeenCalledTimes(2);
  });

  it('keeps the explanation and the Retry control visible while a retry is in flight', async () => {
    let releaseSecond: () => void = () => {};
    mockPost
      .mockRejectedValueOnce(new Error('network failure'))
      .mockReturnValueOnce(new Promise((resolve) => {
        releaseSecond = () => resolve(signalsResponse([]));
      }));

    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(2));

    // Mid-retry the operator must still be told the feed is down, and must
    // still have the control — not a bare "Loading…".
    expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument();
    expect(screen.getByText(/Honeypot status is unknown, not clear/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /retry/i })).toBeDisabled();

    releaseSecond();
    await waitFor(() => expect(screen.queryByText(/Signal feed unavailable/i)).not.toBeInTheDocument());
  });

  it('treats a 200 with a malformed payload as unavailable, not as zero hits', async () => {
    // extractData falls back to the raw body, so a well-formed HTTP response
    // can still carry no `events`. Unguarded this reached render as
    // undefined.filter(...) and threw the tile off the dashboard entirely.
    mockPost.mockResolvedValue(envelope({ count: 0, channel: 'system_fleet' }));

    render(<HoneypotCanaryTile />);

    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());
    expect(screen.queryByText('0')).not.toBeInTheDocument();
    expect(screen.queryByText('last 24h')).not.toBeInTheDocument();
    expect(mockLoggerWarn).toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // A feed outage must never LOWER an already-observed severity
  // (IMP-b80f2bc38419, follow-up to IMP-a133d32b7e4e)
  //
  // Dropping the counts on failure is right — a stale number reads as fresh.
  // Dropping the last known SEVERITY is a separate decision and the wrong one:
  // it repaints a live intrusion amber and badge-less, so an operator scanning
  // for red tiles stops seeing it. Losing the feed made the fleet look better
  // than it was, which is the defect the original task existed to remove.
  // ---------------------------------------------------------------------------

  it('keeps the ALERT badge when the feed drops from an alerting state', async () => {
    mockPost
      .mockResolvedValueOnce(signalsResponse([EVENT_WITHIN_24H]))
      .mockRejectedValueOnce(new Error('network failure'));

    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /refresh honeypot canaries/i }));

    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());
    expect(screen.getByText('ALERT')).toBeInTheDocument();
  });

  it('keeps the error tone, not the warning tone, when the feed drops from an alerting state', async () => {
    mockPost
      .mockResolvedValueOnce(signalsResponse([EVENT_WITHIN_24H]))
      .mockRejectedValueOnce(new Error('network failure'));

    const { container } = render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /refresh honeypot canaries/i }));
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());

    const tile = container.firstElementChild as HTMLElement;
    expect(tile.className).toContain('border-theme-error-border');
    expect(tile.className).not.toContain('border-theme-warning-border');
  });

  it('keeps the last known "Last access:" timestamp when the feed drops', async () => {
    mockPost
      .mockResolvedValueOnce(signalsResponse([EVENT_WITHIN_24H]))
      .mockRejectedValueOnce(new Error('network failure'));

    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Last access:/)).toBeInTheDocument());
    const before = screen.getByText(/Last access:/).textContent;

    fireEvent.click(screen.getByRole('button', { name: /refresh honeypot canaries/i }));
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());

    expect(screen.getByText(/Last access:/).textContent).toBe(before);
  });

  it('still hides the counts when the feed drops from an alerting state', async () => {
    mockPost
      .mockResolvedValueOnce(signalsResponse([EVENT_WITHIN_24H]))
      .mockRejectedValueOnce(new Error('network failure'));

    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /refresh honeypot canaries/i }));
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());

    // A preserved severity is not a licence to show a stale number.
    expect(screen.queryByText('last 24h')).not.toBeInTheDocument();
    expect(screen.queryByText('last 7d')).not.toBeInTheDocument();
  });

  it('marks how long the feed has been unavailable', async () => {
    mockPost
      .mockResolvedValueOnce(signalsResponse([EVENT_WITHIN_24H]))
      .mockRejectedValueOnce(new Error('network failure'));

    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /refresh honeypot canaries/i }));

    await waitFor(() =>
      expect(screen.getByText(/feed unavailable since/i)).toBeInTheDocument(),
    );
  });

  it('does not invent an alert when the feed drops from a clear state', async () => {
    mockPost
      .mockResolvedValueOnce(signalsResponse([]))
      .mockRejectedValueOnce(new Error('network failure'));

    const { container } = render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('last 24h')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /refresh honeypot canaries/i }));
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());

    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
    expect(screen.queryByText(/Last access:/)).not.toBeInTheDocument();
    const tile = container.firstElementChild as HTMLElement;
    expect(tile.className).toContain('border-theme-warning-border');
  });

  it('drops the preserved alert once the feed recovers to a clear reading', async () => {
    mockPost
      .mockResolvedValueOnce(signalsResponse([EVENT_WITHIN_24H]))
      .mockRejectedValueOnce(new Error('network failure'))
      .mockResolvedValueOnce(signalsResponse([]));

    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());

    // First click is the header control (healthy state); the second is the
    // unavailable branch's own Retry — only one exists at a time.
    fireEvent.click(screen.getByRole('button', { name: /refresh honeypot canaries/i }));
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    await waitFor(() => expect(screen.getByText('last 24h')).toBeInTheDocument());

    // A preserved severity must not outlive the outage that justified it.
    expect(screen.queryByText('ALERT')).not.toBeInTheDocument();
    expect(screen.queryByText(/feed unavailable since/i)).not.toBeInTheDocument();
  });

  it('reports the start of the outage, not the last retry, across repeated failures', async () => {
    // Real time moves too little between two clicks for toLocaleString, whose
    // finest field is seconds, to distinguish "outage start" from "last retry".
    // Without a controllable clock this test passes against a plain
    // setUnavailableSince(new Date()) and pins nothing. The step is 5 minutes:
    // visible in the rendered string, and far too small to drag
    // EVENT_WITHIN_24H (23h old) out of either window.
    jest.useFakeTimers({ now });
    mockPost
      .mockResolvedValueOnce(signalsResponse([EVENT_WITHIN_24H]))
      .mockRejectedValue(new Error('still down'));

    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /refresh honeypot canaries/i }));
    await waitFor(() => expect(screen.getByText(/feed unavailable since/i)).toBeInTheDocument());
    const firstMarker = screen.getByText(/feed unavailable since/i).textContent;

    jest.setSystemTime(now + 5 * 60 * 1000);

    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    // Wait on the CATCH having run, not on the call having been made: the
    // unavailable branch never renders "Loading…", so waiting for its absence
    // resolves on the previous render and the assertion below would read the
    // stamp from the first failure whatever the second one did.
    await waitFor(() => expect(mockLoggerWarn).toHaveBeenCalledTimes(2));

    expect(screen.getByText(/feed unavailable since/i).textContent).toBe(firstMarker);
  });

  it('re-stamps the marker for a NEW outage after the feed recovered in between', async () => {
    // The stamp is only "the start of THIS outage" if it is cleared on
    // recovery. Without that clear the tile reports the first outage's time
    // during a later one, overstating how long the canary has been blind —
    // beside a preserved ALERT, which is exactly when that number is read.
    jest.useFakeTimers({ now });
    mockPost
      .mockResolvedValueOnce(signalsResponse([EVENT_WITHIN_24H]))
      .mockRejectedValueOnce(new Error('down'))
      .mockResolvedValueOnce(signalsResponse([EVENT_WITHIN_24H]))
      .mockRejectedValueOnce(new Error('down again'));

    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText('ALERT')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /refresh honeypot canaries/i }));
    await waitFor(() => expect(screen.getByText(/feed unavailable since/i)).toBeInTheDocument());
    const firstOutage = screen.getByText(/feed unavailable since/i).textContent;

    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    await waitFor(() => expect(screen.getByText('last 24h')).toBeInTheDocument());

    jest.setSystemTime(now + 5 * 60 * 1000);

    fireEvent.click(screen.getByRole('button', { name: /refresh honeypot canaries/i }));
    await waitFor(() => expect(screen.getByText(/feed unavailable since/i)).toBeInTheDocument());

    expect(screen.getByText(/feed unavailable since/i).textContent).not.toBe(firstOutage);
  });

  it('returns to the unavailable state when a retry also fails', async () => {
    mockPost.mockRejectedValue(new Error('still down'));

    render(<HoneypotCanaryTile />);
    await waitFor(() => expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /retry/i }));

    // The retry re-enters the loading state, so wait for it to settle before
    // asserting — otherwise this passes on the pre-click render.
    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(screen.queryByText(/Loading…/)).not.toBeInTheDocument());

    expect(screen.getByText(/Signal feed unavailable/i)).toBeInTheDocument();
    expect(screen.queryByText('0')).not.toBeInTheDocument();
  });
});
