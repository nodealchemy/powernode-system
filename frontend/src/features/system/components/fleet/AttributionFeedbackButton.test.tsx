import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { AttributionFeedbackButton } from './AttributionFeedbackButton';

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

// =============================================================================
// Helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const DEFAULT_PROPS = {
  instanceId: 'inst-abc',
  candidateModuleId: 'mod-xyz',
  candidateKind: 'software_fault',
};

const renderComponent = (props = DEFAULT_PROPS, onSubmitted?: jest.Mock) =>
  render(
    <AttributionFeedbackButton
      {...props}
      onSubmitted={onSubmitted}
    />
  );

// =============================================================================
// Tests
// =============================================================================

describe('AttributionFeedbackButton', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render state
  // ---------------------------------------------------------------------------

  it('renders Confirm and Reject buttons on initial load', () => {
    renderComponent();
    expect(screen.getByRole('button', { name: /confirm/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /reject/i })).toBeInTheDocument();
  });

  it('renders "Add note" button when note area is hidden', () => {
    renderComponent();
    expect(screen.getByRole('button', { name: /add note/i })).toBeInTheDocument();
  });

  it('does not render the textarea initially', () => {
    renderComponent();
    expect(screen.queryByPlaceholderText(/optional context/i)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Note toggle
  // ---------------------------------------------------------------------------

  it('shows the textarea and hides "Add note" after clicking Add note', () => {
    renderComponent();
    fireEvent.click(screen.getByRole('button', { name: /add note/i }));
    expect(screen.getByPlaceholderText(/optional context/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /add note/i })).not.toBeInTheDocument();
  });

  it('allows typing in the note textarea', () => {
    renderComponent();
    fireEvent.click(screen.getByRole('button', { name: /add note/i }));
    const textarea = screen.getByPlaceholderText(/optional context/i);
    fireEvent.change(textarea, { target: { value: 'sensor data mismatch' } });
    expect(textarea).toHaveValue('sensor data mismatch');
  });

  // ---------------------------------------------------------------------------
  // Confirm submission
  // ---------------------------------------------------------------------------

  it('POSTs to /system/fleet/attribution_feedback with confirmed=true on Confirm click', async () => {
    mockPost.mockResolvedValue(envelope({}));
    renderComponent();

    fireEvent.click(screen.getByRole('button', { name: /confirm/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/fleet/attribution_feedback', {
        instance_id: 'inst-abc',
        candidate_module_id: 'mod-xyz',
        candidate_kind: 'software_fault',
        confirmed: true,
        note: undefined,
      })
    );
  });

  it('shows success notification with boost message after confirming', async () => {
    mockPost.mockResolvedValue(envelope({}));
    renderComponent();

    fireEvent.click(screen.getByRole('button', { name: /confirm/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Confirmed — future calls will boost similar candidates',
      })
    );
  });

  // ---------------------------------------------------------------------------
  // Reject submission
  // ---------------------------------------------------------------------------

  it('POSTs with confirmed=false on Reject click', async () => {
    mockPost.mockResolvedValue(envelope({}));
    renderComponent();

    fireEvent.click(screen.getByRole('button', { name: /reject/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/fleet/attribution_feedback', {
        instance_id: 'inst-abc',
        candidate_module_id: 'mod-xyz',
        candidate_kind: 'software_fault',
        confirmed: false,
        note: undefined,
      })
    );
  });

  it('shows success notification with downweight message after rejecting', async () => {
    mockPost.mockResolvedValue(envelope({}));
    renderComponent();

    fireEvent.click(screen.getByRole('button', { name: /reject/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Rejected — future calls will downweight similar candidates',
      })
    );
  });

  // ---------------------------------------------------------------------------
  // Note included in payload when non-empty
  // ---------------------------------------------------------------------------

  it('includes trimmed note in payload when provided', async () => {
    mockPost.mockResolvedValue(envelope({}));
    renderComponent();

    fireEvent.click(screen.getByRole('button', { name: /add note/i }));
    fireEvent.change(screen.getByPlaceholderText(/optional context/i), {
      target: { value: '  memory spike  ' },
    });
    fireEvent.click(screen.getByRole('button', { name: /confirm/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/fleet/attribution_feedback', {
        instance_id: 'inst-abc',
        candidate_module_id: 'mod-xyz',
        candidate_kind: 'software_fault',
        confirmed: true,
        note: 'memory spike',
      })
    );
  });

  it('sends note: undefined when note textarea contains only whitespace', async () => {
    mockPost.mockResolvedValue(envelope({}));
    renderComponent();

    fireEvent.click(screen.getByRole('button', { name: /add note/i }));
    fireEvent.change(screen.getByPlaceholderText(/optional context/i), {
      target: { value: '   ' },
    });
    fireEvent.click(screen.getByRole('button', { name: /confirm/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/fleet/attribution_feedback', {
        instance_id: 'inst-abc',
        candidate_module_id: 'mod-xyz',
        candidate_kind: 'software_fault',
        confirmed: true,
        note: undefined,
      })
    );
  });

  // ---------------------------------------------------------------------------
  // Post-submit reset
  // ---------------------------------------------------------------------------

  it('clears note and hides textarea after successful submission', async () => {
    mockPost.mockResolvedValue(envelope({}));
    renderComponent();

    fireEvent.click(screen.getByRole('button', { name: /add note/i }));
    const textarea = screen.getByPlaceholderText(/optional context/i);
    fireEvent.change(textarea, { target: { value: 'test note' } });
    fireEvent.click(screen.getByRole('button', { name: /confirm/i }));

    await waitFor(() => expect(screen.queryByPlaceholderText(/optional context/i)).not.toBeInTheDocument());
    expect(screen.getByRole('button', { name: /add note/i })).toBeInTheDocument();
  });

  it('calls onSubmitted callback after successful submission', async () => {
    mockPost.mockResolvedValue(envelope({}));
    const onSubmitted = jest.fn();
    renderComponent(DEFAULT_PROPS, onSubmitted);

    fireEvent.click(screen.getByRole('button', { name: /confirm/i }));

    await waitFor(() => expect(onSubmitted).toHaveBeenCalledTimes(1));
  });

  it('does not call onSubmitted when submission fails', async () => {
    mockPost.mockRejectedValue(new Error('network error'));
    const onSubmitted = jest.fn();
    renderComponent(DEFAULT_PROPS, onSubmitted);

    fireEvent.click(screen.getByRole('button', { name: /confirm/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Feedback submission failed',
      })
    );
    expect(onSubmitted).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  it('shows error notification when POST fails', async () => {
    mockPost.mockRejectedValue(new Error('500'));
    renderComponent();

    fireEvent.click(screen.getByRole('button', { name: /reject/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Feedback submission failed',
      })
    );
  });

  // ---------------------------------------------------------------------------
  // Submitting (loading) state
  // ---------------------------------------------------------------------------

  it('disables both action buttons while a submission is in flight', async () => {
    let resolvePost!: (v: unknown) => void;
    mockPost.mockReturnValue(new Promise((res) => { resolvePost = res; }));
    renderComponent();

    fireEvent.click(screen.getByRole('button', { name: /confirm/i }));

    // While pending, both primary action buttons should be disabled
    await waitFor(() => {
      expect(screen.getByRole('button', { name: /confirm/i })).toBeDisabled();
      expect(screen.getByRole('button', { name: /reject/i })).toBeDisabled();
    });

    // Resolve so component doesn't linger in an unfinished state
    resolvePost(envelope({}));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /confirm/i })).not.toBeDisabled()
    );
  });

  // ---------------------------------------------------------------------------
  // Props forwarded correctly
  // ---------------------------------------------------------------------------

  it('uses the candidateKind prop in the POST payload', async () => {
    mockPost.mockResolvedValue(envelope({}));
    render(
      <AttributionFeedbackButton
        instanceId="inst-1"
        candidateModuleId="mod-1"
        candidateKind="hardware_fault"
      />
    );

    fireEvent.click(screen.getByRole('button', { name: /confirm/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/fleet/attribution_feedback', expect.objectContaining({
        candidate_kind: 'hardware_fault',
      }))
    );
  });
});
