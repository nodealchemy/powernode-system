import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { CanaryMarker } from './CanaryMarker';
import type { SystemNodeModule } from '@system/features/system/types/system.types';

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

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    markModuleAsCanary: (...args: unknown[]) => mockMarkModuleAsCanary(...args),
    unmarkModuleAsCanary: (...args: unknown[]) => mockUnmarkModuleAsCanary(...args),
  },
}));

const mockMarkModuleAsCanary = jest.fn();
const mockUnmarkModuleAsCanary = jest.fn();

// =============================================================================
// Helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const BASE_MODULE: SystemNodeModule & { config?: Record<string, unknown> } = {
  id: 'mod-abc',
  name: 'ssh-keys-module',
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

const CANARY_MODULE: SystemNodeModule & { config?: Record<string, unknown> } = {
  ...BASE_MODULE,
  config: {
    honeypot: {
      canary: true,
      lure_kind: 'ssh_keys',
      marked_at: '2026-06-01T12:00:00Z',
    },
  },
};

const renderComponent = (
  module: SystemNodeModule & { config?: Record<string, unknown> } = BASE_MODULE,
  onUpdated?: (m: SystemNodeModule) => void,
) => render(<CanaryMarker module={module} onUpdated={onUpdated} />);

// =============================================================================
// Tests
// =============================================================================

describe('CanaryMarker', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockAddNotification.mockReset();
    mockMarkModuleAsCanary.mockReset();
    mockUnmarkModuleAsCanary.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  describe('non-canary module (default state)', () => {
    it('renders the panel heading', () => {
      renderComponent();
      expect(screen.getByText('Honeypot Canary')).toBeInTheDocument();
    });

    it('renders the explanatory paragraph', () => {
      renderComponent();
      expect(
        screen.getByText(/Marking this module as a canary means any access/i),
      ).toBeInTheDocument();
    });

    it('does NOT render the CANARY badge', () => {
      renderComponent();
      expect(screen.queryByText('CANARY')).not.toBeInTheDocument();
    });

    it('renders a "Mark as Canary…" button but not the confirm form', () => {
      renderComponent();
      expect(screen.getByRole('button', { name: /mark as canary/i })).toBeInTheDocument();
      expect(screen.queryByText(/confirm/i)).not.toBeInTheDocument();
    });
  });

  describe('canary module (already marked)', () => {
    it('renders the CANARY warning badge', () => {
      renderComponent(CANARY_MODULE);
      expect(screen.getByText('CANARY')).toBeInTheDocument();
    });

    it('renders lure_kind from config', () => {
      renderComponent(CANARY_MODULE);
      expect(screen.getByText('ssh_keys')).toBeInTheDocument();
    });

    it('renders the marked_at timestamp', () => {
      renderComponent(CANARY_MODULE);
      // Verify the date label is present
      expect(screen.getByText('Marked at:')).toBeInTheDocument();
    });

    it('renders "Remove Canary Marker" button and not the mark button', () => {
      renderComponent(CANARY_MODULE);
      expect(
        screen.getByRole('button', { name: /remove canary marker/i }),
      ).toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /mark as canary/i })).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Confirm-form expansion
  // ---------------------------------------------------------------------------

  describe('clicking "Mark as Canary…"', () => {
    it('shows the lure-kind select and action buttons', () => {
      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      expect(screen.getByRole('combobox')).toBeInTheDocument();
      expect(
        screen.getByRole('button', { name: /confirm.*mark as canary/i }),
      ).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
    });

    it('hides the primary "Mark as Canary…" button once confirming', () => {
      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      expect(
        screen.queryByRole('button', { name: /^mark as canary/i }),
      ).not.toBeInTheDocument();
    });

    it('populates the select with all LURE_KINDS', () => {
      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      const select = screen.getByRole('combobox') as HTMLSelectElement;
      const options = Array.from(select.options).map((o) => o.value);
      expect(options).toContain('credential_store');
      expect(options).toContain('admin_shell');
      expect(options).toContain('production_keys');
      expect(options).toContain('ssh_keys');
      expect(options).toContain('database_root');
      expect(options).toContain('cloud_credentials');
      expect(options).toContain('custom');
    });

    it('defaults to "credential_store" in the select', () => {
      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      const select = screen.getByRole('combobox') as HTMLSelectElement;
      expect(select.value).toBe('credential_store');
    });

    it('clicking Cancel returns to the initial button state', () => {
      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(
        screen.getByRole('button', { name: /mark as canary/i }),
      ).toBeInTheDocument();
      expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Mark as canary — success path
  // ---------------------------------------------------------------------------

  describe('confirming mark as canary', () => {
    it('calls systemApi.markModuleAsCanary with the module id and selected lure kind', async () => {
      const updatedModule = {
        ...BASE_MODULE,
        config: { honeypot: { canary: true, lure_kind: 'credential_store', marked_at: '' } },
      };
      mockMarkModuleAsCanary.mockResolvedValueOnce(updatedModule);

      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      fireEvent.click(screen.getByRole('button', { name: /confirm.*mark as canary/i }));

      await waitFor(() =>
        expect(mockMarkModuleAsCanary).toHaveBeenCalledWith('mod-abc', 'credential_store'),
      );
    });

    it('calls systemApi.markModuleAsCanary with a changed lure kind', async () => {
      const updatedModule = {
        ...BASE_MODULE,
        config: { honeypot: { canary: true, lure_kind: 'ssh_keys', marked_at: '' } },
      };
      mockMarkModuleAsCanary.mockResolvedValueOnce(updatedModule);

      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));

      const select = screen.getByRole('combobox');
      fireEvent.change(select, { target: { value: 'ssh_keys' } });

      fireEvent.click(screen.getByRole('button', { name: /confirm.*mark as canary/i }));

      await waitFor(() =>
        expect(mockMarkModuleAsCanary).toHaveBeenCalledWith('mod-abc', 'ssh_keys'),
      );
    });

    it('fires a success notification with the lure kind after marking', async () => {
      const updatedModule = {
        ...BASE_MODULE,
        config: { honeypot: { canary: true, lure_kind: 'credential_store', marked_at: '' } },
      };
      mockMarkModuleAsCanary.mockResolvedValueOnce(updatedModule);

      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      fireEvent.click(screen.getByRole('button', { name: /confirm.*mark as canary/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Module marked as honeypot canary (lure: credential_store)',
        }),
      );
    });

    it('calls onUpdated with the returned module after success', async () => {
      const updatedModule = {
        ...BASE_MODULE,
        config: { honeypot: { canary: true, lure_kind: 'credential_store', marked_at: '' } },
      };
      mockMarkModuleAsCanary.mockResolvedValueOnce(updatedModule);

      const onUpdated = jest.fn();
      renderComponent(BASE_MODULE, onUpdated);

      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      fireEvent.click(screen.getByRole('button', { name: /confirm.*mark as canary/i }));

      await waitFor(() => expect(onUpdated).toHaveBeenCalledWith(updatedModule));
    });

    it('collapses the confirmation form after success', async () => {
      const updatedModule = {
        ...BASE_MODULE,
        config: { honeypot: { canary: true, lure_kind: 'credential_store', marked_at: '' } },
      };
      mockMarkModuleAsCanary.mockResolvedValueOnce(updatedModule);

      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      fireEvent.click(screen.getByRole('button', { name: /confirm.*mark as canary/i }));

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Mark as canary — error path
  // ---------------------------------------------------------------------------

  describe('mark as canary failure', () => {
    it('fires an error notification when the API call rejects', async () => {
      mockMarkModuleAsCanary.mockRejectedValueOnce(new Error('server error'));

      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      fireEvent.click(screen.getByRole('button', { name: /confirm.*mark as canary/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to mark as canary',
        }),
      );
    });

    it('does NOT call onUpdated when marking fails', async () => {
      mockMarkModuleAsCanary.mockRejectedValueOnce(new Error('network error'));

      const onUpdated = jest.fn();
      renderComponent(BASE_MODULE, onUpdated);

      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      fireEvent.click(screen.getByRole('button', { name: /confirm.*mark as canary/i }));

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      expect(onUpdated).not.toHaveBeenCalled();
    });

    it('re-enables the Confirm button after the error resolves', async () => {
      mockMarkModuleAsCanary.mockRejectedValueOnce(new Error('server error'));

      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));

      const confirmBtn = screen.getByRole('button', { name: /confirm.*mark as canary/i });
      fireEvent.click(confirmBtn);

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      // After the promise settles (finally { setSubmitting(false) }), the
      // button should no longer be disabled
      expect(confirmBtn).not.toBeDisabled();
    });
  });

  // ---------------------------------------------------------------------------
  // Unmark canary — success path
  // ---------------------------------------------------------------------------

  describe('removing the canary marker', () => {
    it('calls systemApi.unmarkModuleAsCanary with the module id', async () => {
      mockUnmarkModuleAsCanary.mockResolvedValueOnce(BASE_MODULE);

      renderComponent(CANARY_MODULE);
      fireEvent.click(screen.getByRole('button', { name: /remove canary marker/i }));

      await waitFor(() =>
        expect(mockUnmarkModuleAsCanary).toHaveBeenCalledWith('mod-abc'),
      );
    });

    it('fires a success notification after unmarking', async () => {
      mockUnmarkModuleAsCanary.mockResolvedValueOnce(BASE_MODULE);

      renderComponent(CANARY_MODULE);
      fireEvent.click(screen.getByRole('button', { name: /remove canary marker/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Canary marker removed',
        }),
      );
    });

    it('calls onUpdated with the returned module after successful unmark', async () => {
      mockUnmarkModuleAsCanary.mockResolvedValueOnce(BASE_MODULE);

      const onUpdated = jest.fn();
      renderComponent(CANARY_MODULE, onUpdated);

      fireEvent.click(screen.getByRole('button', { name: /remove canary marker/i }));

      await waitFor(() => expect(onUpdated).toHaveBeenCalledWith(BASE_MODULE));
    });
  });

  // ---------------------------------------------------------------------------
  // Unmark canary — error path
  // ---------------------------------------------------------------------------

  describe('removing the canary marker failure', () => {
    it('fires an error notification when unmark API call rejects', async () => {
      mockUnmarkModuleAsCanary.mockRejectedValueOnce(new Error('server error'));

      renderComponent(CANARY_MODULE);
      fireEvent.click(screen.getByRole('button', { name: /remove canary marker/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to remove canary marker',
        }),
      );
    });

    it('does NOT call onUpdated when unmarking fails', async () => {
      mockUnmarkModuleAsCanary.mockRejectedValueOnce(new Error('network error'));

      const onUpdated = jest.fn();
      renderComponent(CANARY_MODULE, onUpdated);

      fireEvent.click(screen.getByRole('button', { name: /remove canary marker/i }));

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      expect(onUpdated).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Submitting state (disabled buttons)
  // ---------------------------------------------------------------------------

  describe('submitting state', () => {
    it('disables the Confirm button while the mark request is in flight', async () => {
      let resolve!: (v: SystemNodeModule) => void;
      mockMarkModuleAsCanary.mockReturnValueOnce(
        new Promise<SystemNodeModule>((r) => { resolve = r; }),
      );

      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      fireEvent.click(screen.getByRole('button', { name: /confirm.*mark as canary/i }));

      await waitFor(() =>
        expect(
          screen.getByRole('button', { name: /confirm.*mark as canary/i }),
        ).toBeDisabled(),
      );

      // Settle the promise to avoid act() warnings
      resolve(BASE_MODULE);
    });

    it('disables the Cancel button while the mark request is in flight', async () => {
      let resolve!: (v: SystemNodeModule) => void;
      mockMarkModuleAsCanary.mockReturnValueOnce(
        new Promise<SystemNodeModule>((r) => { resolve = r; }),
      );

      renderComponent();
      fireEvent.click(screen.getByRole('button', { name: /mark as canary/i }));
      fireEvent.click(screen.getByRole('button', { name: /confirm.*mark as canary/i }));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled(),
      );

      resolve(BASE_MODULE);
    });

    it('disables the Remove button while the unmark request is in flight', async () => {
      let resolve!: (v: SystemNodeModule) => void;
      mockUnmarkModuleAsCanary.mockReturnValueOnce(
        new Promise<SystemNodeModule>((r) => { resolve = r; }),
      );

      renderComponent(CANARY_MODULE);
      fireEvent.click(screen.getByRole('button', { name: /remove canary marker/i }));

      await waitFor(() =>
        expect(
          screen.getByRole('button', { name: /remove canary marker/i }),
        ).toBeDisabled(),
      );

      resolve(BASE_MODULE);
    });
  });

  // ---------------------------------------------------------------------------
  // Edge case: module with no config / empty config
  // ---------------------------------------------------------------------------

  describe('module with no honeypot config', () => {
    it('treats a module with config: {} as non-canary', () => {
      renderComponent({ ...BASE_MODULE, config: {} });
      expect(screen.queryByText('CANARY')).not.toBeInTheDocument();
      expect(screen.getByRole('button', { name: /mark as canary/i })).toBeInTheDocument();
    });

    it('treats a module with canary: false as non-canary', () => {
      renderComponent({
        ...BASE_MODULE,
        config: { honeypot: { canary: false } },
      });
      expect(screen.queryByText('CANARY')).not.toBeInTheDocument();
      expect(screen.getByRole('button', { name: /mark as canary/i })).toBeInTheDocument();
    });

    it('treats a module with undefined config as non-canary', () => {
      renderComponent({ ...BASE_MODULE, config: undefined as unknown as Record<string, unknown> });
      expect(screen.queryByText('CANARY')).not.toBeInTheDocument();
    });
  });
});
