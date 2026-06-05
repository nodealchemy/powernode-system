import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ChildrenTab } from './ChildrenTab';
import type { ChildPeerSummary } from '../../types/spawn.types';
import type { SpawnResponse } from '../../types/spawn.types';

// =============================================================================
// Mocks
//
// ChildrenTab is a thin compositor — its only responsibilities are:
//   1. Mount ChildrenPanel + SpawnPlatformModal
//   2. Wire onSpawnClick → setSpawnOpen(true)  → isOpen=true on the modal
//   3. Wire onClose     → setSpawnOpen(false) → isOpen=false on the modal
//   4. Wire onSpawned   → setRefreshKey(k+1) → refreshKey bumped on the panel
//   5. Wire onSelect    → no-op (v1 — row click is informational only)
//
// We mock both children so we can verify the prop-wiring contract without
// re-executing the child component logic (which has its own test suites).
// =============================================================================

// Capture the props each child component received so we can invoke callbacks.
let capturedPanelProps: React.ComponentProps<typeof import('./ChildrenPanel').ChildrenPanel> | null =
  null;
let capturedModalProps: React.ComponentProps<
  typeof import('./SpawnPlatformModal').SpawnPlatformModal
> | null = null;

// We can't import types from the real modules while mocking them, so we use the
// callback shapes directly from the props the mock captures.

jest.mock(
  '@system/features/system/components/federation/ChildrenPanel',
  () => ({
    ChildrenPanel: (props: {
      refreshKey?: number;
      onSpawnClick?: () => void;
      onSelect?: (child: ChildPeerSummary) => void;
    }) => {
      capturedPanelProps = props as never;
      return (
        <div data-testid="children-panel" data-refresh-key={props.refreshKey ?? 0}>
          <button
            data-testid="panel-spawn-btn"
            onClick={props.onSpawnClick}
          >
            Spawn Platform
          </button>
          <button
            data-testid="panel-select-btn"
            onClick={() =>
              props.onSelect?.({
                id: 'child-001',
                remote_instance_url: 'https://child1.example.com',
                spawn_mode: 'managed_child',
                status: 'active',
                created_at: '2026-01-01T00:00:00Z',
                last_heartbeat_at: null,
                acceptance_pending: false,
                acceptance_expires_at: null,
              })
            }
          >
            Select Child
          </button>
        </div>
      );
    },
  }),
);

jest.mock(
  '@system/features/system/components/federation/SpawnPlatformModal',
  () => ({
    SpawnPlatformModal: (props: {
      isOpen: boolean;
      onClose: () => void;
      onSpawned?: (response: SpawnResponse) => void;
    }) => {
      capturedModalProps = props as never;
      if (!props.isOpen) return null;
      return (
        <div data-testid="spawn-modal">
          <button data-testid="modal-close-btn" onClick={props.onClose}>
            Close Modal
          </button>
          <button
            data-testid="modal-spawned-btn"
            onClick={() =>
              props.onSpawned?.({
                child: {
                  id: 'child-new',
                  remote_instance_url: 'https://newchild.example.com',
                  spawn_mode: 'managed_child',
                  status: 'proposed',
                  created_at: '2026-06-05T00:00:00Z',
                  last_heartbeat_at: null,
                  acceptance_pending: true,
                  acceptance_expires_at: '2026-06-12T00:00:00Z',
                  endpoints: [],
                  capabilities: {},
                  metadata: {},
                  signed_at: null,
                },
                acceptance_token: 'tok_test_token',
                spawn_payload: { parent_url: 'https://hub.alice.tld' },
              })
            }
          >
            Simulate Spawned
          </button>
        </div>
      );
    },
  }),
);

// =============================================================================
// Render helper
// =============================================================================

const renderTab = () =>
  render(
    <BrowserRouter>
      <ChildrenTab />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('ChildrenTab', () => {
  beforeEach(() => {
    capturedPanelProps = null;
    capturedModalProps = null;
  });

  // ---------------------------------------------------------------------------
  // Render: basic structure
  // ---------------------------------------------------------------------------

  it('renders ChildrenPanel', () => {
    renderTab();
    expect(screen.getByTestId('children-panel')).toBeInTheDocument();
  });

  it('does NOT render SpawnPlatformModal content when initially closed', () => {
    renderTab();
    // Modal starts closed — our mock returns null when isOpen=false
    expect(screen.queryByTestId('spawn-modal')).not.toBeInTheDocument();
  });

  it('passes refreshKey=0 to ChildrenPanel on initial render', () => {
    renderTab();
    const panel = screen.getByTestId('children-panel');
    expect(panel).toHaveAttribute('data-refresh-key', '0');
  });

  // ---------------------------------------------------------------------------
  // Interaction: opening the modal
  // ---------------------------------------------------------------------------

  it('opens SpawnPlatformModal (isOpen=true) when onSpawnClick is called', async () => {
    renderTab();

    fireEvent.click(screen.getByTestId('panel-spawn-btn'));

    await waitFor(() =>
      expect(screen.getByTestId('spawn-modal')).toBeInTheDocument(),
    );
  });

  it('passes isOpen=true to SpawnPlatformModal after spawn button click', async () => {
    renderTab();

    fireEvent.click(screen.getByTestId('panel-spawn-btn'));

    await waitFor(() =>
      expect(capturedModalProps?.isOpen).toBe(true),
    );
  });

  // ---------------------------------------------------------------------------
  // Interaction: closing the modal
  // ---------------------------------------------------------------------------

  it('closes the modal when onClose callback is invoked', async () => {
    renderTab();

    // Open
    fireEvent.click(screen.getByTestId('panel-spawn-btn'));
    await waitFor(() =>
      expect(screen.getByTestId('spawn-modal')).toBeInTheDocument(),
    );

    // Close via the modal's onClose callback
    fireEvent.click(screen.getByTestId('modal-close-btn'));

    await waitFor(() =>
      expect(screen.queryByTestId('spawn-modal')).not.toBeInTheDocument(),
    );
  });

  it('passes isOpen=false to SpawnPlatformModal after onClose is invoked', async () => {
    renderTab();

    fireEvent.click(screen.getByTestId('panel-spawn-btn'));
    await waitFor(() => expect(capturedModalProps?.isOpen).toBe(true));

    fireEvent.click(screen.getByTestId('modal-close-btn'));

    await waitFor(() => expect(capturedModalProps?.isOpen).toBe(false));
  });

  // ---------------------------------------------------------------------------
  // Interaction: onSpawned increments refreshKey
  // ---------------------------------------------------------------------------

  it('increments refreshKey passed to ChildrenPanel after onSpawned fires', async () => {
    renderTab();

    // Initially 0
    expect(screen.getByTestId('children-panel')).toHaveAttribute(
      'data-refresh-key',
      '0',
    );

    // Open modal, then simulate a successful spawn
    fireEvent.click(screen.getByTestId('panel-spawn-btn'));
    await waitFor(() =>
      expect(screen.getByTestId('spawn-modal')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByTestId('modal-spawned-btn'));

    await waitFor(() =>
      expect(screen.getByTestId('children-panel')).toHaveAttribute(
        'data-refresh-key',
        '1',
      ),
    );
  });

  it('increments refreshKey again on a second spawn', async () => {
    renderTab();

    // First spawn
    fireEvent.click(screen.getByTestId('panel-spawn-btn'));
    await waitFor(() =>
      expect(screen.getByTestId('spawn-modal')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('modal-spawned-btn'));

    await waitFor(() =>
      expect(screen.getByTestId('children-panel')).toHaveAttribute(
        'data-refresh-key',
        '1',
      ),
    );

    // Close and re-open
    fireEvent.click(screen.getByTestId('modal-close-btn'));
    await waitFor(() =>
      expect(screen.queryByTestId('spawn-modal')).not.toBeInTheDocument(),
    );
    fireEvent.click(screen.getByTestId('panel-spawn-btn'));
    await waitFor(() =>
      expect(screen.getByTestId('spawn-modal')).toBeInTheDocument(),
    );

    // Second spawn
    fireEvent.click(screen.getByTestId('modal-spawned-btn'));

    await waitFor(() =>
      expect(screen.getByTestId('children-panel')).toHaveAttribute(
        'data-refresh-key',
        '2',
      ),
    );
  });

  it('keeps the modal open after onSpawned fires (tab does not auto-close)', async () => {
    renderTab();

    fireEvent.click(screen.getByTestId('panel-spawn-btn'));
    await waitFor(() =>
      expect(screen.getByTestId('spawn-modal')).toBeInTheDocument(),
    );

    // Spawned fires (modal handles its own phase transition internally)
    fireEvent.click(screen.getByTestId('modal-spawned-btn'));

    // The tab wires onSpawned to bump refreshKey only — it does NOT call setSpawnOpen(false)
    await waitFor(() =>
      expect(screen.getByTestId('children-panel')).toHaveAttribute(
        'data-refresh-key',
        '1',
      ),
    );
    // Modal is still mounted (isOpen still true from the tab's perspective)
    expect(screen.getByTestId('spawn-modal')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Interaction: onSelect (v1 no-op)
  // ---------------------------------------------------------------------------

  it('accepts row selection without throwing — v1 onSelect is a no-op', () => {
    renderTab();

    // Should not throw; click the select button provided by the mock panel
    expect(() => {
      fireEvent.click(screen.getByTestId('panel-select-btn'));
    }).not.toThrow();
  });

  it('passes an onSelect function to ChildrenPanel', () => {
    renderTab();
    expect(capturedPanelProps?.onSelect).toBeInstanceOf(Function);
  });

  // ---------------------------------------------------------------------------
  // Prop wiring: correct callbacks always passed
  // ---------------------------------------------------------------------------

  it('passes onSpawnClick as a function to ChildrenPanel', () => {
    renderTab();
    expect(capturedPanelProps?.onSpawnClick).toBeInstanceOf(Function);
  });

  it('passes onClose as a function to SpawnPlatformModal', () => {
    renderTab();
    expect(capturedModalProps?.onClose).toBeInstanceOf(Function);
  });

  it('passes onSpawned as a function to SpawnPlatformModal', () => {
    renderTab();
    expect(capturedModalProps?.onSpawned).toBeInstanceOf(Function);
  });

  // ---------------------------------------------------------------------------
  // Container structure
  // ---------------------------------------------------------------------------

  it('wraps content in a div with space-y-4 class', () => {
    const { container } = renderTab();
    const wrapper = container.firstElementChild as HTMLElement;
    expect(wrapper.tagName.toLowerCase()).toBe('div');
    expect(wrapper.className).toContain('space-y-4');
  });
});
