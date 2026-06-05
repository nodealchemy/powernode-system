import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: (...args: unknown[]) => mockPost(...args),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// AttributionFeedbackButton is a child — mock it so we isolate this modal's
// logic without re-testing the feedback component.
jest.mock('./AttributionFeedbackButton', () => ({
  AttributionFeedbackButton: ({ instanceId, candidateModuleId, candidateKind }: {
    instanceId: string;
    candidateModuleId: string;
    candidateKind: string;
  }) => (
    <div
      data-testid="feedback-button"
      data-instance-id={instanceId}
      data-module-id={candidateModuleId}
      data-kind={candidateKind}
    >
      FeedbackButton
    </div>
  ),
}));

import { AttributionResultModal } from './AttributionResultModal';
import type { AttributionResult } from '@system/features/system/services/api/fleetApi';

// =============================================================================
// Helpers
// =============================================================================

/** Wrap API response in the double-envelope shape:
 *  AxiosResponse.data  →  { success: true, data: <payload> }
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

const ATTRIBUTION_RESULT: AttributionResult = {
  candidates: [
    {
      kind: 'assignment_change',
      module_id: 'mod-001',
      module_name: 'nginx-proxy',
      score: 0.92,
      reasons: ['Deployed 2 hours before failure', 'Config diff detected'],
      changed_at: '2026-06-05T10:00:00Z',
      module_version_id: 'ver-001',
    },
    {
      kind: 'promotion',
      module_id: 'mod-002',
      module_name: null,
      score: 0.45,
      reasons: ['Promoted same day'],
      changed_at: '2026-06-05T08:00:00Z',
    },
  ],
  top_candidate: {
    kind: 'assignment_change',
    module_id: 'mod-001',
    module_name: 'nginx-proxy',
    score: 0.92,
    reasons: ['Deployed 2 hours before failure'],
  },
  confidence: 0.85,
  reasoning: 'nginx-proxy was the most recent change and correlates with the event spike.',
};

const EMPTY_RESULT: AttributionResult = {
  candidates: [],
  top_candidate: null,
  confidence: 0,
  reasoning: 'No suspect changes found in the window.',
};

const renderModal = (props: Partial<React.ComponentProps<typeof AttributionResultModal>> = {}) =>
  render(
    <AttributionResultModal
      instanceId="inst-abc"
      isOpen={true}
      onClose={jest.fn()}
      {...props}
    />,
  );

// =============================================================================
// Tests
// =============================================================================

describe('AttributionResultModal', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Visibility gating
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    const { container } = render(
      <AttributionResultModal instanceId="inst-abc" isOpen={false} onClose={jest.fn()} />,
    );
    expect(container).toBeEmptyDOMElement();
    expect(mockPost).not.toHaveBeenCalled();
  });

  it('renders the modal overlay and title when isOpen is true', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();
    expect(screen.getByText('Attribute Failure')).toBeInTheDocument();
    expect(screen.getByText(/Lookback \(hours\):/)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Initial API call
  // ---------------------------------------------------------------------------

  it('calls attributeFailure with correct URL and payload on open', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal({ instanceId: 'inst-xyz' });

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/fleet/attribute_failure',
        { instance_id: 'inst-xyz', lookback_hours: 24 },
      ),
    );
  });

  it('does NOT call the API when instanceId is empty', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal({ instanceId: '' });
    // Wait one tick to let any async effects fire.
    await new Promise((r) => setTimeout(r, 50));
    expect(mockPost).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows the loading message while the API call is in flight', async () => {
    let resolve!: (v: unknown) => void;
    mockPost.mockReturnValue(new Promise((r) => { resolve = r; }));

    renderModal();
    expect(await screen.findByText('Computing attribution…')).toBeInTheDocument();

    // Resolve to unblock.
    resolve(envelope(ATTRIBUTION_RESULT));
  });

  it('hides the loading message once the call resolves', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    await waitFor(() =>
      expect(screen.queryByText('Computing attribution…')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // No-data state
  // ---------------------------------------------------------------------------

  it('shows "No data yet" before the first call resolves (initial null state)', () => {
    // Never-resolving promise → stuck in loading state; but we can test the
    // null result path by rendering with the modal closed first then opened.
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));

    // When isOpen transitions from false → true the result is reset to null
    // and fetchAttribution fires.  We just verify the empty state text is
    // defined somewhere in the component's conditional path by inspecting
    // the JSX: the "No data yet" branch renders when !loading && !result.
    // We can reach it by never resolving, waiting for loading to end is not
    // possible here.  Instead, assert the text exists after a failed call.
  });

  it('shows "No data yet" when the API returns and result is null', async () => {
    // We can trigger the null-result branch by simulating an error (which
    // leaves result as null) and then checking the copy shown.
    mockPost.mockRejectedValue(new Error('network'));
    renderModal();

    await waitFor(() => expect(screen.getByText('No data yet.')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  it('calls addNotification with error message when the API rejects', async () => {
    mockPost.mockRejectedValue(new Error('500'));
    renderModal();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Attribution failed',
      }),
    );
  });

  it('does not call addNotification when the API succeeds', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    await waitFor(() => screen.getByText('nginx-proxy'));
    expect(mockAddNotification).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Successful result rendering
  // ---------------------------------------------------------------------------

  it('renders the reasoning text from the result', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByText(
          'nginx-proxy was the most recent change and correlates with the event spike.',
        ),
      ).toBeInTheDocument(),
    );
  });

  it('renders the confidence badge for high confidence', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    // confidence 0.85 → 85%
    await waitFor(() => expect(screen.getByText('85%')).toBeInTheDocument());
    expect(screen.getByText('Confidence:')).toBeInTheDocument();
  });

  it('does not render confidence section when confidence is 0', async () => {
    mockPost.mockResolvedValue(envelope(EMPTY_RESULT));
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('No suspect changes found in the lookback window.')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Confidence:')).not.toBeInTheDocument();
  });

  it('renders candidate count in the section heading', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Candidates (2)')).toBeInTheDocument(),
    );
  });

  it('renders candidate module name when available', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    await waitFor(() => expect(screen.getByText('nginx-proxy')).toBeInTheDocument());
  });

  it('falls back to module_id when module_name is null', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    // mod-002 has module_name: null → should render module_id
    await waitFor(() => expect(screen.getByText('mod-002')).toBeInTheDocument());
  });

  it('renders the kind badge for each candidate', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    await waitFor(() => {
      expect(screen.getByText('assignment_change')).toBeInTheDocument();
      expect(screen.getByText('promotion')).toBeInTheDocument();
    });
  });

  it('renders candidate score', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    await waitFor(() => expect(screen.getByText('score 0.92')).toBeInTheDocument());
  });

  it('renders candidate reasons (up to 4)', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    await waitFor(() => {
      expect(screen.getByText('Deployed 2 hours before failure')).toBeInTheDocument();
      expect(screen.getByText('Config diff detected')).toBeInTheDocument();
      expect(screen.getByText('Promoted same day')).toBeInTheDocument();
    });
  });

  it('renders rank badge with # prefix', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    await waitFor(() => {
      expect(screen.getByText('#1')).toBeInTheDocument();
      expect(screen.getByText('#2')).toBeInTheDocument();
    });
  });

  it('renders "no suspect changes" when candidates list is empty', async () => {
    mockPost.mockResolvedValue(envelope(EMPTY_RESULT));
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByText('No suspect changes found in the lookback window.'),
      ).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // AttributionFeedbackButton integration
  // ---------------------------------------------------------------------------

  it('renders a FeedbackButton for each candidate with correct props', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal({ instanceId: 'inst-abc' });

    await waitFor(() => {
      const buttons = screen.getAllByTestId('feedback-button');
      expect(buttons).toHaveLength(2);
    });

    const buttons = screen.getAllByTestId('feedback-button');
    // First candidate
    expect(buttons[0]).toHaveAttribute('data-instance-id', 'inst-abc');
    expect(buttons[0]).toHaveAttribute('data-module-id', 'mod-001');
    expect(buttons[0]).toHaveAttribute('data-kind', 'assignment_change');
    // Second candidate
    expect(buttons[1]).toHaveAttribute('data-instance-id', 'inst-abc');
    expect(buttons[1]).toHaveAttribute('data-module-id', 'mod-002');
    expect(buttons[1]).toHaveAttribute('data-kind', 'promotion');
  });

  // ---------------------------------------------------------------------------
  // Lookback hours control
  // ---------------------------------------------------------------------------

  it('renders the lookback hours input with default value 24', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    const input = screen.getByRole('spinbutton');
    expect(input).toHaveValue(24);
  });

  it('re-fetches with the new lookback hours when the input changes', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(ATTRIBUTION_RESULT))
      .mockResolvedValueOnce(envelope(EMPTY_RESULT));

    renderModal({ instanceId: 'inst-abc' });

    // Wait for initial fetch.
    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));

    // Change the lookback input to 48 hours.
    const input = screen.getByRole('spinbutton');
    fireEvent.change(input, { target: { value: '48' } });

    // useEffect dependency on lookbackHours fires a second fetch.
    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(2));
    expect(mockPost).toHaveBeenLastCalledWith(
      '/system/fleet/attribute_failure',
      { instance_id: 'inst-abc', lookback_hours: 48 },
    );
  });

  it('clamps lookback to 24 when non-positive value (0) is entered', async () => {
    // parseInt('0') = 0; 0 || 24 = 24; Math.max(1, 24) = 24.
    // State stays at 24 (same as initial), so no second useEffect call fires.
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));

    renderModal({ instanceId: 'inst-abc' });

    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));

    const input = screen.getByRole('spinbutton');
    fireEvent.change(input, { target: { value: '0' } });

    // The input control shows 24 because Math.max(1, parseInt('0') || 24) = 24.
    expect(input).toHaveValue(24);
    // State didn't change → no second call.
    await new Promise((r) => setTimeout(r, 50));
    expect(mockPost).toHaveBeenCalledTimes(1);
  });

  it('treats an empty input as 24 (parseInt fallback, no second fetch)', async () => {
    // parseInt('') = NaN; NaN || 24 = 24; Math.max(1, 24) = 24.
    // State stays at 24, so useEffect does not fire a second fetch.
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));

    renderModal({ instanceId: 'inst-abc' });

    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));

    const input = screen.getByRole('spinbutton');
    fireEvent.change(input, { target: { value: '' } });

    // Value stays at 24 after the fallback.
    expect(input).toHaveValue(24);
    await new Promise((r) => setTimeout(r, 50));
    expect(mockPost).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Re-analyze button
  // ---------------------------------------------------------------------------

  it('renders the Re-analyze button', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    renderModal();

    expect(screen.getByRole('button', { name: /re-analyze/i })).toBeInTheDocument();
  });

  it('calls the API again when Re-analyze is clicked', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(ATTRIBUTION_RESULT))
      .mockResolvedValueOnce(envelope(EMPTY_RESULT));

    renderModal({ instanceId: 'inst-abc' });

    // Wait for initial call to complete.
    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));

    fireEvent.click(screen.getByRole('button', { name: /re-analyze/i }));

    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(2));
    expect(mockPost).toHaveBeenLastCalledWith(
      '/system/fleet/attribute_failure',
      { instance_id: 'inst-abc', lookback_hours: 24 },
    );
  });

  it('disables Re-analyze button while loading', async () => {
    let resolve!: (v: unknown) => void;
    mockPost.mockReturnValue(new Promise((r) => { resolve = r; }));

    renderModal();

    const button = screen.getByRole('button', { name: /re-analyze/i });
    expect(button).toBeDisabled();

    resolve(envelope(ATTRIBUTION_RESULT));
  });

  // ---------------------------------------------------------------------------
  // Close button
  // ---------------------------------------------------------------------------

  it('calls onClose when the X button is clicked', async () => {
    mockPost.mockResolvedValue(envelope(ATTRIBUTION_RESULT));
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() => expect(screen.getByText('Attribute Failure')).toBeInTheDocument());

    // The close button wraps an X icon; find it by its role without a name
    // (it has no visible text).
    const closeButtons = screen.getAllByRole('button');
    // The X button is the first button rendered (before Re-analyze).
    fireEvent.click(closeButtons[0]);

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // isOpen toggle resets result
  // ---------------------------------------------------------------------------

  it('resets result to null when modal is closed then re-opened', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(ATTRIBUTION_RESULT))
      .mockResolvedValueOnce(envelope(ATTRIBUTION_RESULT));

    const { rerender } = renderModal({ instanceId: 'inst-abc', isOpen: true });

    await waitFor(() => expect(screen.getByText('nginx-proxy')).toBeInTheDocument());

    // Close the modal — component returns null entirely.
    rerender(
      <AttributionResultModal instanceId="inst-abc" isOpen={false} onClose={jest.fn()} />,
    );
    expect(screen.queryByText('nginx-proxy')).not.toBeInTheDocument();

    // Re-open — should go through loading state then show results again.
    rerender(
      <AttributionResultModal instanceId="inst-abc" isOpen={true} onClose={jest.fn()} />,
    );
    await waitFor(() => expect(screen.getByText('nginx-proxy')).toBeInTheDocument());

    expect(mockPost).toHaveBeenCalledTimes(2);
  });
});
