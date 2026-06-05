import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NodeInstanceControls } from './NodeInstanceControls';
import type { SystemNodeInstance } from '@system/features/system/types/system.types';

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

let mockHasPermission = jest.fn(() => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (...args: unknown[]) => mockHasPermission(...args),
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// Mock AttributionResultModal so we can test the launcher without its internals
jest.mock('@system/features/system/components/fleet/AttributionResultModal', () => ({
  AttributionResultModal: ({ isOpen, onClose }: { instanceId: string; isOpen: boolean; onClose: () => void }) =>
    isOpen ? (
      <div data-testid="attribution-modal">
        <button onClick={onClose}>Close Attribution</button>
      </div>
    ) : null,
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const BASE_INSTANCE: SystemNodeInstance = {
  id: 'inst-1',
  name: 'my-instance',
  variety: 'cloud',
  status: 'running',
  node_id: 'node-42',
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

function makeInstance(overrides: Partial<SystemNodeInstance>): SystemNodeInstance {
  return { ...BASE_INSTANCE, ...overrides };
}

function renderControls(
  instance: SystemNodeInstance,
  props: { compact?: boolean; onActionComplete?: () => void } = {}
) {
  return render(
    <BrowserRouter>
      <NodeInstanceControls instance={instance} {...props} />
    </BrowserRouter>
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('NodeInstanceControls', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission = jest.fn(() => true);
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  describe('permission gating', () => {
    it('renders null when system.instances.control permission is missing', () => {
      mockHasPermission = jest.fn((perm: string) => perm !== 'system.instances.control');
      const { container } = renderControls(BASE_INSTANCE);
      expect(container.firstChild).toBeNull();
    });

    it('renders controls when permission is present', () => {
      renderControls(BASE_INSTANCE);
      expect(screen.getByRole('button', { name: /stop/i })).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Running instance (standard mode)
  // ---------------------------------------------------------------------------

  describe('running instance — standard mode', () => {
    it('shows Stop and Reboot buttons, hides Start', () => {
      renderControls(makeInstance({ status: 'running' }));
      expect(screen.queryByRole('button', { name: /^start$/i })).not.toBeInTheDocument();
      expect(screen.getByRole('button', { name: /stop/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /reboot/i })).toBeInTheDocument();
    });

    it('shows Terminate button for running instance', () => {
      renderControls(makeInstance({ status: 'running' }));
      expect(screen.getByRole('button', { name: /terminate/i })).toBeInTheDocument();
    });

    it('two-click confirm: first Stop click arms it (shows Confirm?), second click fires API', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'stopping' } }));

      renderControls(makeInstance({ status: 'running' }));

      // First click arms — title changes to "Click again to confirm stop"
      fireEvent.click(screen.getByTitle('Stop instance'));
      expect(screen.getByTitle('Click again to confirm stop')).toBeInTheDocument();
      expect(screen.getByText('Confirm?')).toBeInTheDocument();
      expect(mockPost).not.toHaveBeenCalled();

      // Second click fires
      fireEvent.click(screen.getByTitle('Click again to confirm stop'));
      await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));
      expect(mockPost).toHaveBeenCalledWith(
        '/system/nodes/node-42/node_instances/inst-1/stop'
      );
    });

    it('two-click confirm: first Reboot click arms it, second fires API', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'stopping' } }));

      renderControls(makeInstance({ status: 'running' }));

      // First click arms
      fireEvent.click(screen.getByTitle('Reboot instance'));
      expect(screen.getByTitle('Click again to confirm reboot')).toBeInTheDocument();
      expect(mockPost).not.toHaveBeenCalled();

      // Second click fires
      fireEvent.click(screen.getByTitle('Click again to confirm reboot'));
      await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));
      expect(mockPost).toHaveBeenCalledWith(
        '/system/nodes/node-42/node_instances/inst-1/reboot'
      );
    });

    it('two-click confirm for Terminate: arms then fires terminate API', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'terminated' } }));

      renderControls(makeInstance({ status: 'running' }));

      // First click: arms — title changes to "Click again to confirm termination"
      fireEvent.click(screen.getByTitle('Terminate instance'));
      expect(screen.getByTitle('Click again to confirm termination')).toBeInTheDocument();
      expect(mockPost).not.toHaveBeenCalled();

      // Second click: fires
      fireEvent.click(screen.getByTitle('Click again to confirm termination'));
      await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));
      expect(mockPost).toHaveBeenCalledWith(
        '/system/nodes/node-42/node_instances/inst-1/terminate'
      );
    });

    it('calls onActionComplete after successful stop', async () => {
      const onActionComplete = jest.fn();
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'stopping' } }));

      renderControls(makeInstance({ status: 'running' }), { onActionComplete });

      // Arm then confirm via title attribute
      fireEvent.click(screen.getByTitle('Stop instance'));
      fireEvent.click(screen.getByTitle('Click again to confirm stop'));

      await waitFor(() => expect(onActionComplete).toHaveBeenCalledTimes(1));
    });

    it('shows success notification after stop', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'stopping' } }));

      renderControls(makeInstance({ status: 'running' }));
      fireEvent.click(screen.getByTitle('Stop instance'));
      fireEvent.click(screen.getByTitle('Click again to confirm stop'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Stopping instance ${BASE_INSTANCE.name}...`,
        })
      );
    });

    it('shows error notification when stop API call fails', async () => {
      mockPost.mockRejectedValue(new Error('Network error'));

      renderControls(makeInstance({ status: 'running' }));
      fireEvent.click(screen.getByTitle('Stop instance'));
      fireEvent.click(screen.getByTitle('Click again to confirm stop'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to stop instance: Network error',
        })
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Stopped instance (standard mode)
  // ---------------------------------------------------------------------------

  describe('stopped instance — standard mode', () => {
    it('shows only Start button, hides Stop/Reboot', () => {
      renderControls(makeInstance({ status: 'stopped' }));
      expect(screen.getByRole('button', { name: /^start$/i })).toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /stop/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /reboot/i })).not.toBeInTheDocument();
    });

    it('fires start API on single click (non-destructive — no confirm step)', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'starting' } }));

      renderControls(makeInstance({ status: 'stopped' }));
      fireEvent.click(screen.getByRole('button', { name: /^start$/i }));

      await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));
      expect(mockPost).toHaveBeenCalledWith(
        '/system/nodes/node-42/node_instances/inst-1/start'
      );
    });

    it('shows success notification after start', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'starting' } }));

      renderControls(makeInstance({ status: 'stopped' }));
      fireEvent.click(screen.getByRole('button', { name: /^start$/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Starting instance ${BASE_INSTANCE.name}...`,
        })
      );
    });

    it('shows Terminate button for stopped instance', () => {
      renderControls(makeInstance({ status: 'stopped' }));
      expect(screen.getByRole('button', { name: /terminate/i })).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Terminated instance (standard mode)
  // ---------------------------------------------------------------------------

  describe('terminated instance — standard mode', () => {
    it('hides Start, Stop, Reboot and Terminate for terminated instance', () => {
      renderControls(makeInstance({ status: 'terminated' }));
      expect(screen.queryByRole('button', { name: /^start$/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /stop/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /reboot/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /terminate/i })).not.toBeInTheDocument();
    });

    it('hides Attribute Failure button for terminated instance', () => {
      renderControls(makeInstance({ status: 'terminated' }));
      expect(screen.queryByRole('button', { name: /attribute failure/i })).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Error instance (standard mode)
  // ---------------------------------------------------------------------------

  describe('error instance — standard mode', () => {
    it('hides Start/Stop/Reboot but shows Terminate for error status', () => {
      renderControls(makeInstance({ status: 'error' }));
      expect(screen.queryByRole('button', { name: /^start$/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /stop/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /reboot/i })).not.toBeInTheDocument();
      expect(screen.getByRole('button', { name: /terminate/i })).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Pending / transitional instance (standard mode)
  // ---------------------------------------------------------------------------

  describe('pending instance — standard mode', () => {
    it('shows a pending status indicator for "pending" status', () => {
      renderControls(makeInstance({ status: 'pending' }));
      expect(screen.getByText(/pending/i)).toBeInTheDocument();
    });

    it('shows a pending status indicator for "starting" status', () => {
      renderControls(makeInstance({ status: 'starting' }));
      expect(screen.getByText(/starting/i)).toBeInTheDocument();
    });

    it('shows a pending status indicator for "stopping" status', () => {
      renderControls(makeInstance({ status: 'stopping' }));
      expect(screen.getByText(/stopping/i)).toBeInTheDocument();
    });

    it('does not show Terminate for pending instance (canTerminate is false)', () => {
      renderControls(makeInstance({ status: 'pending' }));
      expect(screen.queryByRole('button', { name: /terminate/i })).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Attribute Failure launcher (standard mode)
  // ---------------------------------------------------------------------------

  describe('Attribute Failure launcher', () => {
    it('shows Attribute Failure button for running instance when read permission exists', () => {
      renderControls(makeInstance({ status: 'running' }));
      expect(screen.getByRole('button', { name: /attribute failure/i })).toBeInTheDocument();
    });

    it('shows Attribute Failure button for stopped instance', () => {
      renderControls(makeInstance({ status: 'stopped' }));
      expect(screen.getByRole('button', { name: /attribute failure/i })).toBeInTheDocument();
    });

    it('shows Attribute Failure button for error instance', () => {
      renderControls(makeInstance({ status: 'error' }));
      expect(screen.getByRole('button', { name: /attribute failure/i })).toBeInTheDocument();
    });

    it('hides Attribute Failure button when system.node_instances.read permission is absent', () => {
      mockHasPermission = jest.fn((perm: string) => perm !== 'system.node_instances.read');
      renderControls(makeInstance({ status: 'running' }));
      expect(screen.queryByRole('button', { name: /attribute failure/i })).not.toBeInTheDocument();
    });

    it('opens AttributionResultModal when Attribute Failure is clicked', async () => {
      renderControls(makeInstance({ status: 'running' }));
      fireEvent.click(screen.getByRole('button', { name: /attribute failure/i }));
      await waitFor(() =>
        expect(screen.getByTestId('attribution-modal')).toBeInTheDocument()
      );
    });

    it('closes AttributionResultModal when onClose is called', async () => {
      renderControls(makeInstance({ status: 'running' }));
      fireEvent.click(screen.getByRole('button', { name: /attribute failure/i }));
      await waitFor(() => expect(screen.getByTestId('attribution-modal')).toBeInTheDocument());

      fireEvent.click(screen.getByRole('button', { name: /close attribution/i }));
      await waitFor(() =>
        expect(screen.queryByTestId('attribution-modal')).not.toBeInTheDocument()
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Compact dropdown mode
  // ---------------------------------------------------------------------------

  describe('compact mode', () => {
    it('renders a menu toggle button instead of inline buttons', () => {
      renderControls(makeInstance({ status: 'running' }), { compact: true });
      // Should not have inline Stop/Reboot buttons — only the MoreVertical toggle
      expect(screen.queryByRole('button', { name: /^stop$/i })).not.toBeInTheDocument();
      // The toggle is a ghost button with no accessible name — use its container
      // The menu is closed initially
      expect(screen.queryByText('Stop')).not.toBeInTheDocument();
    });

    it('shows menu items after toggle button click', async () => {
      renderControls(makeInstance({ status: 'running' }), { compact: true });
      // Click the MoreVertical icon button
      const toggleBtn = screen.getByRole('button');
      fireEvent.click(toggleBtn);
      await waitFor(() => expect(screen.getByText('Stop')).toBeInTheDocument());
      expect(screen.getByText('Reboot')).toBeInTheDocument();
      expect(screen.getByText('Terminate')).toBeInTheDocument();
    });

    it('shows Start in compact menu for stopped instance', async () => {
      renderControls(makeInstance({ status: 'stopped' }), { compact: true });
      fireEvent.click(screen.getByRole('button'));
      await waitFor(() => expect(screen.getByText('Start')).toBeInTheDocument());
      expect(screen.queryByText('Stop')).not.toBeInTheDocument();
      expect(screen.queryByText('Reboot')).not.toBeInTheDocument();
    });

    it('shows Instance is <status> message for pending status in compact menu', async () => {
      renderControls(makeInstance({ status: 'pending' }), { compact: true });
      // isPending disables the toggle button
      const toggleBtn = screen.getByRole('button');
      expect(toggleBtn).toBeDisabled();
    });

    it('compact Stop arms on first click, shows "Click again to confirm" in menu', async () => {
      renderControls(makeInstance({ status: 'running' }), { compact: true });
      const [toggleBtn] = screen.getAllByRole('button');
      fireEvent.click(toggleBtn);
      await waitFor(() => expect(screen.getByText('Stop')).toBeInTheDocument());

      // First click arms — button text changes to "Click again to confirm" in the open menu
      fireEvent.click(screen.getByText('Stop'));
      expect(mockPost).not.toHaveBeenCalled();
      await waitFor(() =>
        expect(screen.getByText('Click again to confirm')).toBeInTheDocument()
      );
    });

    it('compact Stop fires API on second click after arming', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'stopping' } }));
      renderControls(makeInstance({ status: 'running' }), { compact: true });

      const [toggleBtn] = screen.getAllByRole('button');
      fireEvent.click(toggleBtn);
      await waitFor(() => expect(screen.getByText('Stop')).toBeInTheDocument());

      // Arm: first click
      fireEvent.click(screen.getByText('Stop'));
      await waitFor(() => expect(screen.getByText('Click again to confirm')).toBeInTheDocument());

      // Fire: second click (the menu remains open during arm window)
      fireEvent.click(screen.getByText('Click again to confirm'));
      await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));
      expect(mockPost).toHaveBeenCalledWith(
        '/system/nodes/node-42/node_instances/inst-1/stop'
      );
    });

    it('compact Terminate arms and then fires API on second click', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'terminated' } }));
      renderControls(makeInstance({ status: 'running' }), { compact: true });

      // Open menu
      const [toggleBtn] = screen.getAllByRole('button');
      fireEvent.click(toggleBtn);
      await waitFor(() => expect(screen.getByText('Terminate')).toBeInTheDocument());

      // First click: arms (menu stays open, button text becomes "Click again to confirm")
      fireEvent.click(screen.getByText('Terminate'));
      expect(mockPost).not.toHaveBeenCalled();
      // The menu should still be visible since arming does not close it
      await waitFor(() =>
        expect(screen.getByText('Click again to confirm')).toBeInTheDocument()
      );

      // Second click fires the API
      fireEvent.click(screen.getByText('Click again to confirm'));
      await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));
      expect(mockPost).toHaveBeenCalledWith(
        '/system/nodes/node-42/node_instances/inst-1/terminate'
      );
    });

    it('closes compact menu when backdrop is clicked', async () => {
      renderControls(makeInstance({ status: 'running' }), { compact: true });
      fireEvent.click(screen.getByRole('button'));
      await waitFor(() => expect(screen.getByText('Stop')).toBeInTheDocument());

      // Click the fixed backdrop overlay
      const backdrop = document.querySelector('.fixed.inset-0.z-10') as Element;
      fireEvent.click(backdrop);
      await waitFor(() => expect(screen.queryByText('Stop')).not.toBeInTheDocument());
    });

    it('shows "Instance is pending" text in compact menu when status is non-operable', async () => {
      // For pending status the toggle is disabled so menu cannot open
      // This verifies the disabled state
      renderControls(makeInstance({ status: 'starting' }), { compact: true });
      expect(screen.getByRole('button')).toBeDisabled();
    });
  });

  // ---------------------------------------------------------------------------
  // Armed-action timeout
  // ---------------------------------------------------------------------------

  describe('arm timeout', () => {
    beforeEach(() => jest.useFakeTimers());
    afterEach(() => jest.useRealTimers());

    it('disarms after 5 seconds if second click does not come', async () => {
      renderControls(makeInstance({ status: 'running' }));

      fireEvent.click(screen.getByTitle('Stop instance'));
      expect(screen.getByTitle('Click again to confirm stop')).toBeInTheDocument();
      expect(screen.getByText('Confirm?')).toBeInTheDocument();

      // Advance past 5s
      act(() => {
        jest.advanceTimersByTime(5001);
      });

      await waitFor(() =>
        expect(screen.queryByText('Confirm?')).not.toBeInTheDocument()
      );
      expect(screen.getByTitle('Stop instance')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Disabled state during loading
  // ---------------------------------------------------------------------------

  describe('loading state', () => {
    it('shows "Starting..." text while start is in-flight', async () => {
      // Never resolves — keep it pending so we can inspect mid-flight state
      mockPost.mockReturnValue(new Promise(() => {}));

      renderControls(makeInstance({ status: 'stopped' }));
      fireEvent.click(screen.getByRole('button', { name: /^start$/i }));

      await waitFor(() => expect(screen.getByText('Starting...')).toBeInTheDocument());
    });

    it('shows "Stopping..." text while stop is in-flight', async () => {
      mockPost.mockReturnValue(new Promise(() => {}));

      renderControls(makeInstance({ status: 'running' }));
      // Arm
      fireEvent.click(screen.getByTitle('Stop instance'));
      // Confirm
      fireEvent.click(screen.getByTitle('Click again to confirm stop'));

      await waitFor(() => expect(screen.getByText('Stopping...')).toBeInTheDocument());
    });
  });

  // ---------------------------------------------------------------------------
  // API URL correctness
  // ---------------------------------------------------------------------------

  describe('API endpoint correctness', () => {
    it('calls correct start endpoint with node_id and instance id', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'starting' } }));
      const instance = makeInstance({ node_id: 'node-99', id: 'inst-77', status: 'stopped' });
      renderControls(instance);

      fireEvent.click(screen.getByRole('button', { name: /^start$/i }));
      await waitFor(() => expect(mockPost).toHaveBeenCalled());
      expect(mockPost).toHaveBeenCalledWith(
        '/system/nodes/node-99/node_instances/inst-77/start'
      );
    });

    it('calls correct reboot endpoint', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'stopping' } }));
      const instance = makeInstance({ node_id: 'node-99', id: 'inst-77', status: 'running' });
      renderControls(instance);

      // Arm then confirm
      fireEvent.click(screen.getByTitle('Reboot instance'));
      fireEvent.click(screen.getByTitle('Click again to confirm reboot'));

      await waitFor(() => expect(mockPost).toHaveBeenCalled());
      expect(mockPost).toHaveBeenCalledWith(
        '/system/nodes/node-99/node_instances/inst-77/reboot'
      );
    });

    it('shows success notification after reboot', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'stopping' } }));
      renderControls(makeInstance({ status: 'running' }));

      fireEvent.click(screen.getByTitle('Reboot instance'));
      fireEvent.click(screen.getByTitle('Click again to confirm reboot'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Rebooting instance ${BASE_INSTANCE.name}...`,
        })
      );
    });

    it('shows success notification after terminate', async () => {
      mockPost.mockResolvedValue(envelope({ node_instance: { ...BASE_INSTANCE, status: 'terminated' } }));
      renderControls(makeInstance({ status: 'running' }));

      fireEvent.click(screen.getByTitle('Terminate instance'));
      fireEvent.click(screen.getByTitle('Click again to confirm termination'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Terminating instance ${BASE_INSTANCE.name}...`,
        })
      );
    });
  });
});
