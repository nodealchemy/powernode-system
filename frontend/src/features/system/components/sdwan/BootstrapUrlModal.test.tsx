import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BootstrapUrlModal } from './BootstrapUrlModal';
import type { SdwanIssueUserDeviceResponse } from '../../types/sdwan.types';

// =============================================================================
// Fixtures
// =============================================================================

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
    url: '/api/v1/sdwan/bootstrap/opaque-token-blob',
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
    const expectedUrl = `${window.location.origin}/api/v1/sdwan/bootstrap/opaque-token-blob`;
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
        `${window.location.origin}/api/v1/sdwan/bootstrap/opaque-token-blob`,
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
        url: '/api/v1/sdwan/bootstrap/different-token-xyz',
      },
    };
    renderModal({ result });
    const expected = `${window.location.origin}/api/v1/sdwan/bootstrap/different-token-xyz`;
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
});
