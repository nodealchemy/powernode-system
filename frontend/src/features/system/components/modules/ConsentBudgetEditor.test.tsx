import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { ConsentBudgetEditor } from './ConsentBudgetEditor';
import type { SystemNodeModule } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockPut = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: jest.fn(),
    put: (...args: unknown[]) => mockPut(...args),
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

function moduleEnvelope(partial: Partial<SystemNodeModule> & { id: string; name: string }) {
  return envelope({ node_module: { ...BASE_MODULE, ...partial } });
}

// =============================================================================
// Fixtures
// =============================================================================

const BASE_MODULE: SystemNodeModule = {
  id: 'mod-1',
  name: 'my-module',
  variety: 'config',
  enabled: true,
  public: false,
  priority: 10,
  mask: [],
  file_spec: [],
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

function buildModule(
  overrides: Partial<
    SystemNodeModule & {
      consent_budget_per_day?: number | null;
      consent_budget_used_count?: number;
      consent_budget_window_start_at?: string | null;
    }
  > = {}
) {
  return { ...BASE_MODULE, ...overrides };
}

const renderEditor = (
  props: Partial<{
    module: ReturnType<typeof buildModule>;
    onUpdated: jest.Mock;
  }> = {}
) => {
  const module = props.module ?? buildModule();
  const onUpdated = props.onUpdated ?? jest.fn();
  return render(<ConsentBudgetEditor module={module} onUpdated={onUpdated} />);
};

// =============================================================================
// Tests
// =============================================================================

describe('ConsentBudgetEditor', () => {
  beforeEach(() => {
    mockPut.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Rendering — unlimited budget (no consent_budget_per_day)
  // ---------------------------------------------------------------------------

  it('renders the section heading and description', () => {
    renderEditor();

    expect(screen.getByText('Consent Budget')).toBeInTheDocument();
    expect(
      screen.getByText(/daily ceiling on autonomous decisions/i)
    ).toBeInTheDocument();
  });

  it('renders an empty budget input when consent_budget_per_day is null', () => {
    renderEditor({ module: buildModule({ consent_budget_per_day: null }) });

    const input = screen.getByRole('spinbutton');
    expect(input).toHaveValue(null); // empty number input
    expect(input).toHaveAttribute('placeholder', 'unlimited');
  });

  it('renders the budget value from props when set', () => {
    renderEditor({ module: buildModule({ consent_budget_per_day: 50 }) });

    const input = screen.getByRole('spinbutton');
    expect(input).toHaveValue(50);
  });

  it('shows used count and max when budget is set', () => {
    renderEditor({
      module: buildModule({
        consent_budget_per_day: 20,
        consent_budget_used_count: 7,
      }),
    });

    expect(screen.getByText('7/20')).toBeInTheDocument();
  });

  it('shows only used count without /max when budget is null', () => {
    renderEditor({
      module: buildModule({
        consent_budget_per_day: null,
        consent_budget_used_count: 3,
      }),
    });

    expect(screen.getByText('3')).toBeInTheDocument();
  });

  it('shows ∞ for remaining when no budget is set', () => {
    renderEditor({
      module: buildModule({ consent_budget_per_day: null, consent_budget_used_count: 5 }),
    });

    expect(screen.getByText('∞')).toBeInTheDocument();
  });

  it('computes remaining as max minus used', () => {
    renderEditor({
      module: buildModule({ consent_budget_per_day: 10, consent_budget_used_count: 3 }),
    });

    // remaining = 10 - 3 = 7
    expect(screen.getByText('7')).toBeInTheDocument();
  });

  it('clamps remaining to 0 (never negative) when used exceeds budget', () => {
    renderEditor({
      module: buildModule({ consent_budget_per_day: 5, consent_budget_used_count: 99 }),
    });

    // remaining = max(0, 5 - 99) = 0
    expect(screen.getByText('0')).toBeInTheDocument();
  });

  it('shows window start when consent_budget_window_start_at is set', () => {
    const iso = '2026-06-01T08:00:00Z';
    renderEditor({
      module: buildModule({ consent_budget_window_start_at: iso }),
    });

    expect(screen.getByText(/window started:/i)).toBeInTheDocument();
  });

  it('does NOT show window start line when consent_budget_window_start_at is absent', () => {
    renderEditor({ module: buildModule({ consent_budget_window_start_at: undefined }) });

    expect(screen.queryByText(/window started:/i)).not.toBeInTheDocument();
  });

  it('does NOT show window start line when consent_budget_window_start_at is null', () => {
    renderEditor({ module: buildModule({ consent_budget_window_start_at: null }) });

    expect(screen.queryByText(/window started:/i)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Save button — handleSave
  // ---------------------------------------------------------------------------

  it('sends PUT with numeric budget value', async () => {
    mockPut.mockResolvedValueOnce(moduleEnvelope({ id: 'mod-1', name: 'my-module' }));

    renderEditor({ module: buildModule({ consent_budget_per_day: 10 }) });

    const input = screen.getByRole('spinbutton');
    fireEvent.change(input, { target: { value: '25' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockPut).toHaveBeenCalledWith(
        '/system/node_modules/mod-1',
        { node_module: { consent_budget_per_day: 25 } }
      )
    );
  });

  it('sends PUT with null when budget input is cleared', async () => {
    mockPut.mockResolvedValueOnce(moduleEnvelope({ id: 'mod-1', name: 'my-module' }));

    renderEditor({ module: buildModule({ consent_budget_per_day: 10 }) });

    const input = screen.getByRole('spinbutton');
    fireEvent.change(input, { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockPut).toHaveBeenCalledWith(
        '/system/node_modules/mod-1',
        { node_module: { consent_budget_per_day: null } }
      )
    );
  });

  it('clamps negative input to 0 before saving', async () => {
    mockPut.mockResolvedValueOnce(moduleEnvelope({ id: 'mod-1', name: 'my-module' }));

    renderEditor();

    const input = screen.getByRole('spinbutton');
    fireEvent.change(input, { target: { value: '-10' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockPut).toHaveBeenCalledWith(
        '/system/node_modules/mod-1',
        { node_module: { consent_budget_per_day: 0 } }
      )
    );
  });

  it('shows success notification after successful save', async () => {
    mockPut.mockResolvedValueOnce(moduleEnvelope({ id: 'mod-1', name: 'my-module' }));

    renderEditor();

    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Consent budget updated',
      })
    );
  });

  it('calls onUpdated with the updated module after save', async () => {
    const updatedModule = { ...BASE_MODULE, consent_budget_per_day: 30 };
    mockPut.mockResolvedValueOnce(envelope({ node_module: updatedModule }));

    const onUpdated = jest.fn();
    renderEditor({ onUpdated });

    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() => expect(onUpdated).toHaveBeenCalledWith(updatedModule));
  });

  it('shows error notification when save fails', async () => {
    mockPut.mockRejectedValueOnce(new Error('network error'));

    renderEditor();

    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Update failed',
      })
    );
  });

  it('disables buttons while save is in-flight', async () => {
    let resolve!: (v: unknown) => void;
    mockPut.mockReturnValueOnce(new Promise((r) => { resolve = r; }));

    renderEditor({ module: buildModule({ consent_budget_used_count: 5 }) });

    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    // While pending, both buttons should be disabled
    expect(screen.getByRole('button', { name: /save/i })).toBeDisabled();
    expect(screen.getByRole('button', { name: /reset window/i })).toBeDisabled();

    // Resolve to clean up
    resolve(moduleEnvelope({ id: 'mod-1', name: 'my-module' }));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save/i })).not.toBeDisabled()
    );
  });

  // ---------------------------------------------------------------------------
  // Reset Window button — handleReset
  // ---------------------------------------------------------------------------

  it('disables Reset Window when used count is 0', () => {
    renderEditor({ module: buildModule({ consent_budget_used_count: 0 }) });

    expect(screen.getByRole('button', { name: /reset window/i })).toBeDisabled();
  });

  it('enables Reset Window when used count > 0', () => {
    renderEditor({ module: buildModule({ consent_budget_used_count: 3 }) });

    expect(screen.getByRole('button', { name: /reset window/i })).not.toBeDisabled();
  });

  it('sends PUT resetting used_count to 0 and a new window_start_at', async () => {
    const before = Date.now();
    mockPut.mockResolvedValueOnce(
      envelope({
        node_module: {
          ...BASE_MODULE,
          consent_budget_used_count: 0,
          consent_budget_window_start_at: new Date().toISOString(),
        },
      })
    );

    renderEditor({ module: buildModule({ consent_budget_used_count: 5 }) });

    fireEvent.click(screen.getByRole('button', { name: /reset window/i }));

    await waitFor(() => expect(mockPut).toHaveBeenCalled());

    const [url, body] = mockPut.mock.calls[0] as [string, { node_module: Record<string, unknown> }];
    expect(url).toBe('/system/node_modules/mod-1');
    expect(body.node_module.consent_budget_used_count).toBe(0);

    const sentAt = new Date(body.node_module.consent_budget_window_start_at as string).getTime();
    expect(sentAt).toBeGreaterThanOrEqual(before);
  });

  it('shows success notification after successful reset', async () => {
    mockPut.mockResolvedValueOnce(
      envelope({
        node_module: { ...BASE_MODULE, consent_budget_used_count: 0 },
      })
    );

    renderEditor({ module: buildModule({ consent_budget_used_count: 5 }) });

    fireEvent.click(screen.getByRole('button', { name: /reset window/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Window reset',
      })
    );
  });

  it('calls onUpdated with updated module after reset', async () => {
    const resetModule = { ...BASE_MODULE, consent_budget_used_count: 0 };
    mockPut.mockResolvedValueOnce(envelope({ node_module: resetModule }));

    const onUpdated = jest.fn();
    renderEditor({
      module: buildModule({ consent_budget_used_count: 5 }),
      onUpdated,
    });

    fireEvent.click(screen.getByRole('button', { name: /reset window/i }));

    await waitFor(() => expect(onUpdated).toHaveBeenCalledWith(resetModule));
  });

  it('shows error notification when reset fails', async () => {
    mockPut.mockRejectedValueOnce(new Error('server error'));

    renderEditor({ module: buildModule({ consent_budget_used_count: 5 }) });

    fireEvent.click(screen.getByRole('button', { name: /reset window/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Reset failed',
      })
    );
  });

  it('re-enables buttons after reset completes', async () => {
    mockPut.mockResolvedValueOnce(
      envelope({ node_module: { ...BASE_MODULE, consent_budget_used_count: 0 } })
    );

    renderEditor({ module: buildModule({ consent_budget_used_count: 5 }) });

    fireEvent.click(screen.getByRole('button', { name: /reset window/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /save/i })).not.toBeDisabled()
    );
  });
});
