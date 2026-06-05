import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { SpawnPlatformModal } from './SpawnPlatformModal';
import type { SpawnResponse } from '../../types/spawn.types';

// =============================================================================
// Mocks
//
// SpawnPlatformModal uses childrenApi.spawn (which delegates to apiClient.post)
// and useNotifications. We mock the childrenApi service directly so we can
// control resolved/rejected outcomes without needing the apiClient shim.
// =============================================================================

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

const mockSpawn = jest.fn();
jest.mock('@system/features/system/services/api/childrenApi', () => ({
  childrenApi: {
    spawn: (...args: unknown[]) => mockSpawn(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const SPAWN_RESPONSE: SpawnResponse = {
  child: {
    id: 'child-abc123',
    remote_instance_url: 'https://child.example.com',
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
  acceptance_token: 'tok_abc_supersecret_xyz',
  spawn_payload: {
    parent_url: 'https://hub.alice.tld',
    spawn_mode: 'managed_child',
    template_id: 'powernode-hub',
  },
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  onClose?: () => void;
  onSpawned?: (r: SpawnResponse) => void;
}

const renderModal = ({
  isOpen = true,
  onClose = jest.fn(),
  onSpawned = jest.fn(),
}: RenderProps = {}) =>
  render(
    <BrowserRouter>
      <SpawnPlatformModal isOpen={isOpen} onClose={onClose} onSpawned={onSpawned} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('SpawnPlatformModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockSpawn.mockReset();
    // Stub clipboard API so copy tests don't blow up in jsdom
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: jest.fn().mockResolvedValue(undefined) },
      writable: true,
      configurable: true,
    });
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen=false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Spawn Platform')).not.toBeInTheDocument();
  });

  it('renders the form phase with title "Spawn Platform" when isOpen=true', () => {
    renderModal();
    expect(screen.getByText('Spawn Platform')).toBeInTheDocument();
  });

  it('renders all three spawn mode radio options', () => {
    renderModal();
    expect(screen.getByLabelText(/managed child/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/autonomous peer/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/cluster member/i)).toBeInTheDocument();
  });

  it('defaults spawn mode to managed_child (first radio checked)', () => {
    renderModal();
    const managedChildRadio = screen.getByLabelText(/managed child/i);
    expect((managedChildRadio as HTMLInputElement).checked).toBe(true);
  });

  it('renders Parent URL, Template ID, Region, and TTL fields', () => {
    renderModal();
    expect(screen.getByPlaceholderText('https://hub.alice.tld')).toBeInTheDocument();
    expect(screen.getByPlaceholderText('powernode-hub')).toBeInTheDocument();
    expect(screen.getByPlaceholderText('us-west')).toBeInTheDocument();
    // TTL is an unlinked number input — query by role/type
    expect(screen.getByRole('spinbutton')).toBeInTheDocument();
    expect(screen.getByText(/acceptance token ttl/i)).toBeInTheDocument();
  });

  it('defaults Template ID to "powernode-hub" and TTL to "7"', () => {
    renderModal();
    const templateInput = screen.getByPlaceholderText('powernode-hub') as HTMLInputElement;
    expect(templateInput.value).toBe('powernode-hub');
    const ttlInput = screen.getByRole('spinbutton') as HTMLInputElement;
    expect(ttlInput.value).toBe('7');
  });

  it('renders Cancel and Spawn buttons in the footer', () => {
    renderModal();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /^spawn$/i })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Validation: Spawn button disabled state
  // ---------------------------------------------------------------------------

  it('disables the Spawn button when Parent URL is empty (initial state)', () => {
    renderModal();
    expect(screen.getByRole('button', { name: /^spawn$/i })).toBeDisabled();
  });

  it('disables Spawn button when Parent URL is filled but template is cleared', () => {
    renderModal();
    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    const templateInput = screen.getByPlaceholderText('powernode-hub');

    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.change(templateInput, { target: { value: '' } });

    expect(screen.getByRole('button', { name: /^spawn$/i })).toBeDisabled();
  });

  it('enables Spawn button when URL and Template are both valid', () => {
    renderModal();
    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });

    expect(screen.getByRole('button', { name: /^spawn$/i })).not.toBeDisabled();
  });

  it('disables Spawn button when TTL is out of range (0)', () => {
    renderModal();
    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });

    const ttlInput = screen.getByRole('spinbutton');
    fireEvent.change(ttlInput, { target: { value: '0' } });

    expect(screen.getByRole('button', { name: /^spawn$/i })).toBeDisabled();
  });

  it('disables Spawn button when TTL is out of range (31)', () => {
    renderModal();
    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });

    const ttlInput = screen.getByRole('spinbutton');
    fireEvent.change(ttlInput, { target: { value: '31' } });

    expect(screen.getByRole('button', { name: /^spawn$/i })).toBeDisabled();
  });

  it('disables Spawn button for non-https URL (http)', () => {
    renderModal();
    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'http://hub.alice.tld' } });

    expect(screen.getByRole('button', { name: /^spawn$/i })).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Validation errors shown via notification
  // ---------------------------------------------------------------------------

  it('calls addNotification with URL error when form is submitted with no URL', async () => {
    renderModal();
    // Force submit via form element (Spawn button is disabled, but form can still be
    // submitted via Enter key / programmatic dispatch on the form)
    const form = document.querySelector('form') as HTMLFormElement;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );
  });

  it('calls addNotification with URL pattern error for invalid URL', async () => {
    renderModal();
    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    // Set an invalid URL directly to bypass disabled button (submit via form)
    fireEvent.change(urlInput, { target: { value: 'ftp://bad' } });

    const form = document.querySelector('form') as HTMLFormElement;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: expect.stringContaining('https://'),
        }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Successful spawn flow
  // ---------------------------------------------------------------------------

  it('calls childrenApi.spawn with the correct payload on submit', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    const onSpawned = jest.fn();
    renderModal({ onSpawned });

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });

    const regionInput = screen.getByPlaceholderText('us-west');
    fireEvent.change(regionInput, { target: { value: 'us-west' } });

    const ttlInput = screen.getByRole('spinbutton');
    fireEvent.change(ttlInput, { target: { value: '14' } });

    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(mockSpawn).toHaveBeenCalledWith({
        spawn_mode: 'managed_child',
        parent_url: 'https://hub.alice.tld',
        spawn_target: {
          template_id: 'powernode-hub',
          region: 'us-west',
        },
        token_ttl_seconds: 14 * 86_400,
      }),
    );
  });

  it('omits region from spawn_target when region is empty', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });

    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(mockSpawn).toHaveBeenCalledWith(
        expect.objectContaining({
          spawn_target: { template_id: 'powernode-hub' },
        }),
      ),
    );
    // region key must be absent
    const call = mockSpawn.mock.calls[0][0] as Record<string, unknown>;
    const target = call.spawn_target as Record<string, unknown>;
    expect(Object.keys(target)).not.toContain('region');
  });

  it('calls onSpawned callback with the API response after successful spawn', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    const onSpawned = jest.fn();
    renderModal({ onSpawned });

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });

    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() => expect(onSpawned).toHaveBeenCalledWith(SPAWN_RESPONSE));
  });

  // ---------------------------------------------------------------------------
  // Phase 2: token display
  // ---------------------------------------------------------------------------

  it('transitions to token phase after a successful spawn', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(screen.getByText('Spawn Token')).toBeInTheDocument(),
    );
  });

  it('shows the acceptance token value in phase 2', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(
        screen.getByDisplayValue('tok_abc_supersecret_xyz'),
      ).toBeInTheDocument(),
    );
  });

  it('shows the "Capture this token now" warning in phase 2', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(screen.getByText(/capture this token now/i)).toBeInTheDocument(),
    );
  });

  it('shows child id and status in phase 2', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(screen.getByText(/child-abc123/)).toBeInTheDocument(),
    );
    expect(screen.getByText(/proposed/)).toBeInTheDocument();
  });

  it('shows the spawn payload JSON in a pre element in phase 2', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(
        screen.getByText(/"parent_url": "https:\/\/hub\.alice\.tld"/),
      ).toBeInTheDocument(),
    );
  });

  it('renders a Done button (no Spawn or Cancel) in phase 2', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^done$/i })).toBeInTheDocument(),
    );
    expect(screen.queryByRole('button', { name: /^spawn$/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /cancel/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Copy token interaction
  // ---------------------------------------------------------------------------

  it('copies the acceptance token to clipboard when Copy button is clicked', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(screen.getByText(/copy/i, { selector: 'button' })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText(/copy/i, { selector: 'button' }));

    await waitFor(() =>
      expect(navigator.clipboard.writeText).toHaveBeenCalledWith('tok_abc_supersecret_xyz'),
    );
  });

  it('shows "Copied" text briefly after clicking the copy button', async () => {
    jest.useFakeTimers();
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(screen.getByText(/copy/i, { selector: 'button' })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByText(/copy/i, { selector: 'button' }));

    await waitFor(() => expect(screen.getByText(/copied/i)).toBeInTheDocument());

    // After 2s timer the label reverts to "Copy"
    act(() => {
      jest.advanceTimersByTime(2100);
    });
    await waitFor(() => expect(screen.getByText(/^copy$/i, { selector: 'button' })).toBeInTheDocument());
    jest.useRealTimers();
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  it('calls addNotification with error type when spawn API call fails', async () => {
    mockSpawn.mockRejectedValueOnce(new Error('Network error'));
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network error',
      }),
    );
  });

  it('shows generic "Spawn failed" error when the rejection is not an Error instance', async () => {
    mockSpawn.mockRejectedValueOnce('oops');
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Spawn failed',
      }),
    );
  });

  it('stays in form phase (no transition) when spawn API call fails', async () => {
    mockSpawn.mockRejectedValueOnce(new Error('Server error'));
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
    // Still in form phase — Spawn title still visible
    expect(screen.getByText('Spawn Platform')).toBeInTheDocument();
    expect(screen.queryByText('Spawn Token')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Spawn mode selection
  // ---------------------------------------------------------------------------

  it('changes spawn mode when Autonomous Peer radio is selected', () => {
    renderModal();
    const autonomousPeerRadio = screen.getByLabelText(/autonomous peer/i);
    fireEvent.click(autonomousPeerRadio);
    expect((autonomousPeerRadio as HTMLInputElement).checked).toBe(true);
    expect((screen.getByLabelText(/managed child/i) as HTMLInputElement).checked).toBe(false);
  });

  it('sends the selected spawn_mode in the API payload', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    renderModal();

    fireEvent.click(screen.getByLabelText(/cluster member/i));
    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(mockSpawn).toHaveBeenCalledWith(
        expect.objectContaining({ spawn_mode: 'cluster_member' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Reset on re-open
  // ---------------------------------------------------------------------------

  it('resets form to defaults when the modal is closed and re-opened', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);

    const { rerender } = render(
      <BrowserRouter>
        <SpawnPlatformModal isOpen={true} onClose={jest.fn()} />
      </BrowserRouter>,
    );

    // Fill some fields
    fireEvent.change(screen.getByPlaceholderText('https://hub.alice.tld'), {
      target: { value: 'https://hub.alice.tld' },
    });
    fireEvent.change(screen.getByPlaceholderText('us-west'), {
      target: { value: 'eu-central' },
    });

    // Close then re-open
    rerender(
      <BrowserRouter>
        <SpawnPlatformModal isOpen={false} onClose={jest.fn()} />
      </BrowserRouter>,
    );
    rerender(
      <BrowserRouter>
        <SpawnPlatformModal isOpen={true} onClose={jest.fn()} />
      </BrowserRouter>,
    );

    await waitFor(() => {
      const urlInput = screen.getByPlaceholderText('https://hub.alice.tld') as HTMLInputElement;
      expect(urlInput.value).toBe('');
      const regionInput = screen.getByPlaceholderText('us-west') as HTMLInputElement;
      expect(regionInput.value).toBe('');
      const ttlInput = screen.getByRole('spinbutton') as HTMLInputElement;
      expect(ttlInput.value).toBe('7');
    });
  });

  it('resets to form phase when the modal is closed and re-opened after a successful spawn', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);

    const { rerender } = render(
      <BrowserRouter>
        <SpawnPlatformModal isOpen={true} onClose={jest.fn()} />
      </BrowserRouter>,
    );

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() => expect(screen.getByText('Spawn Token')).toBeInTheDocument());

    // Close then re-open
    rerender(
      <BrowserRouter>
        <SpawnPlatformModal isOpen={false} onClose={jest.fn()} />
      </BrowserRouter>,
    );
    rerender(
      <BrowserRouter>
        <SpawnPlatformModal isOpen={true} onClose={jest.fn()} />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(screen.getByText('Spawn Platform')).toBeInTheDocument(),
    );
    expect(screen.queryByText('Spawn Token')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Cancel / onClose
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel button is clicked', () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when Done button is clicked in phase 2', async () => {
    mockSpawn.mockResolvedValueOnce(SPAWN_RESPONSE);
    const onClose = jest.fn();
    renderModal({ onClose });

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^done$/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /^done$/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Submitting state
  // ---------------------------------------------------------------------------

  it('shows "Spawning…" label on the Spawn button while request is in-flight', async () => {
    let resolveSpawn!: (v: SpawnResponse) => void;
    mockSpawn.mockReturnValueOnce(
      new Promise<SpawnResponse>((res) => {
        resolveSpawn = res;
      }),
    );
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(screen.getByText(/spawning…/i)).toBeInTheDocument(),
    );

    // Resolve so we don't leave a dangling promise
    act(() => {
      resolveSpawn(SPAWN_RESPONSE);
    });
  });

  it('disables Cancel and Spawn buttons while submitting', async () => {
    let resolveSpawn!: (v: SpawnResponse) => void;
    mockSpawn.mockReturnValueOnce(
      new Promise<SpawnResponse>((res) => {
        resolveSpawn = res;
      }),
    );
    renderModal();

    const urlInput = screen.getByPlaceholderText('https://hub.alice.tld');
    fireEvent.change(urlInput, { target: { value: 'https://hub.alice.tld' } });
    fireEvent.click(screen.getByRole('button', { name: /^spawn$/i }));

    await waitFor(() =>
      expect(screen.getByText(/spawning…/i)).toBeInTheDocument(),
    );

    expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();

    act(() => {
      resolveSpawn(SPAWN_RESPONSE);
    });
  });
});
