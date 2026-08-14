import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworkEditModal } from './NetworkEditModal';
import type { SdwanNetwork } from '../../types/sdwan.types';

// =============================================================================
// Mocks
//
// NetworkEditModal calls sdwanApi.updateNetwork, which internally calls
// apiClient.put. We mock the sdwanApi facade at the path the source imports
// and also stub apiClient so extractData/extractPaginated helpers work.
// We mock useNotifications to spy on success/error notifications.
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

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
  }),
}));

jest.mock('@/shared/hooks/BreadcrumbContext', () => ({
  __esModule: true,
  BreadcrumbProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
  useBreadcrumb: () => ({
    breadcrumbs: [],
    setBreadcrumbs: jest.fn(),
    getCurrentBreadcrumbs: () => [],
    setCurrentPage: jest.fn(),
  }),
}));

// =============================================================================
// Helpers
// =============================================================================

/** Double-envelope shape that apiClient resolves to. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// =============================================================================
// Fixtures
// =============================================================================

const BASE_NETWORK: SdwanNetwork = {
  id: 'net-abc',
  name: 'prod-overlay',
  slug: 'prod-overlay',
  status: 'active',
  cidr_64: 'fd00::/64',
  description: 'Production WireGuard overlay',
  peer_count: 3,
  settings: { firewall_default_policy: 'accept' },
  created_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

const renderModal = (
  props: Partial<React.ComponentProps<typeof NetworkEditModal>> = {}
) => {
  const onClose = jest.fn();
  const onSaved = jest.fn();

  render(
    <BrowserRouter>
      <NetworkEditModal
        isOpen={true}
        network={BASE_NETWORK}
        onClose={onClose}
        onSaved={onSaved}
        {...props}
      />
    </BrowserRouter>
  );

  return { onClose, onSaved };
};

// =============================================================================
// Tests
// =============================================================================

describe('NetworkEditModal', () => {
  beforeEach(() => {
    mockPut.mockReset();
    mockAddNotification.mockReset();
  });

  // ──── Null / closed guard ─────────────────────────────────────────────────

  it('renders nothing when network prop is null', () => {
    const { container } = render(
      <BrowserRouter>
        <NetworkEditModal
          isOpen={true}
          network={null}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );
    expect(container).toBeEmptyDOMElement();
  });

  it('renders nothing when isOpen is false', () => {
    const { container } = render(
      <BrowserRouter>
        <NetworkEditModal
          isOpen={false}
          network={BASE_NETWORK}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );
    expect(container).toBeEmptyDOMElement();
  });

  // ──── Initial render + field population ──────────────────────────────────

  it('shows modal title as "Edit <network name>"', () => {
    renderModal();
    expect(screen.getByText('Edit prod-overlay')).toBeInTheDocument();
  });

  it('populates name field from network prop', () => {
    renderModal();
    expect(screen.getByDisplayValue('prod-overlay')).toBeInTheDocument();
  });

  it('populates description field from network prop', () => {
    renderModal();
    expect(screen.getByDisplayValue('Production WireGuard overlay')).toBeInTheDocument();
  });

  it('populates status select from network prop', () => {
    renderModal();
    const statusSelect = screen.getByRole('combobox') as HTMLSelectElement;
    expect(statusSelect.value).toBe('active');
  });

  it('pre-selects "Accept all" firewall policy radio from network settings', () => {
    renderModal();
    const acceptRadio = screen.getByRole('radio', { name: /accept all/i }) as HTMLInputElement;
    expect(acceptRadio.checked).toBe(true);
  });

  it('pre-selects "Drop all" radio when network settings has drop policy', () => {
    renderModal({
      network: {
        ...BASE_NETWORK,
        settings: { firewall_default_policy: 'drop' },
      },
    });
    const dropRadio = screen.getByRole('radio', { name: /drop all/i }) as HTMLInputElement;
    expect(dropRadio.checked).toBe(true);
  });

  it('defaults firewall policy to "accept" when settings is absent', () => {
    renderModal({
      network: { ...BASE_NETWORK, settings: undefined },
    });
    const acceptRadio = screen.getByRole('radio', { name: /accept all/i }) as HTMLInputElement;
    expect(acceptRadio.checked).toBe(true);
  });

  it('renders empty description when network has no description', () => {
    renderModal({
      network: { ...BASE_NETWORK, description: undefined },
    });
    // The textarea has no htmlFor/aria-label — query all textboxes and find
    // the one that is a <textarea> element (i.e. the description field).
    const textboxes = screen.getAllByRole('textbox');
    const textarea = textboxes.find(
      (el) => el.tagName.toLowerCase() === 'textarea'
    ) as HTMLTextAreaElement | undefined;
    expect(textarea).toBeTruthy();
    expect(textarea!.value).toBe('');
  });

  // ──── Status select options ───────────────────────────────────────────────

  it('shows all four status options', () => {
    renderModal();
    const select = screen.getByRole('combobox') as HTMLSelectElement;
    const optionValues = Array.from(select.options).map((o) => o.value);
    expect(optionValues).toEqual(['registered', 'active', 'suspended', 'archived']);
  });

  it('shows suspended-network hint text', () => {
    renderModal();
    expect(
      screen.getByText(/suspended networks compile a default-deny ruleset/i)
    ).toBeInTheDocument();
  });

  // ──── Validation: name required ───────────────────────────────────────────

  it('disables Save button when name is cleared', () => {
    renderModal();
    const nameInput = screen.getByDisplayValue('prod-overlay');
    fireEvent.change(nameInput, { target: { value: '' } });
    expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();
  });

  it('disables Save button when name is whitespace only', () => {
    renderModal();
    const nameInput = screen.getByDisplayValue('prod-overlay');
    fireEvent.change(nameInput, { target: { value: '   ' } });
    expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();
  });

  it('enables Save button when name is non-empty', () => {
    renderModal();
    expect(screen.getByRole('button', { name: /save changes/i })).not.toBeDisabled();
  });

  // ──── Successful submit ───────────────────────────────────────────────────

  it('calls apiClient.put with correct URL and payload on submit', async () => {
    mockPut.mockResolvedValueOnce(
      envelope({ network: { ...BASE_NETWORK } })
    );

    const { onSaved, onClose } = renderModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    expect(mockPut).toHaveBeenCalledWith(
      `/system/sdwan/networks/${BASE_NETWORK.id}`,
      {
        network: {
          name: 'prod-overlay',
          description: 'Production WireGuard overlay',
          status: 'active',
          settings: { firewall_default_policy: 'accept' },
        },
      }
    );

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' })
    );
  });

  it('sends trimmed name in the payload', async () => {
    mockPut.mockResolvedValueOnce(envelope({ network: BASE_NETWORK }));

    renderModal();

    const nameInput = screen.getByDisplayValue('prod-overlay');
    fireEvent.change(nameInput, { target: { value: '  trimmed-name  ' } });

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { network: { name: string } }];
    expect(payload.network.name).toBe('trimmed-name');
  });

  it('sends description as undefined when textarea is blank', async () => {
    mockPut.mockResolvedValueOnce(envelope({ network: BASE_NETWORK }));

    renderModal({ network: { ...BASE_NETWORK, description: undefined } });

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { network: { description: unknown } }];
    expect(payload.network.description).toBeUndefined();
  });

  it('sends trimmed description in the payload', async () => {
    mockPut.mockResolvedValueOnce(envelope({ network: BASE_NETWORK }));

    renderModal();

    const descField = screen.getByDisplayValue('Production WireGuard overlay');
    fireEvent.change(descField, { target: { value: '  new description  ' } });

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { network: { description: string } }];
    expect(payload.network.description).toBe('new description');
  });

  it('sends selected status in the payload', async () => {
    mockPut.mockResolvedValueOnce(envelope({ network: BASE_NETWORK }));

    renderModal();

    const statusSelect = screen.getByRole('combobox');
    fireEvent.change(statusSelect, { target: { value: 'suspended' } });

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { network: { status: string } }];
    expect(payload.network.status).toBe('suspended');
  });

  it('sends updated firewall policy when "Drop all" is selected', async () => {
    mockPut.mockResolvedValueOnce(envelope({ network: BASE_NETWORK }));

    renderModal();

    const dropRadio = screen.getByRole('radio', { name: /drop all/i });
    fireEvent.click(dropRadio);

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [
      string,
      { network: { settings: { firewall_default_policy: string } } }
    ];
    expect(payload.network.settings.firewall_default_policy).toBe('drop');
  });

  it('merges existing settings keys when updating firewall policy', async () => {
    mockPut.mockResolvedValueOnce(envelope({ network: BASE_NETWORK }));

    renderModal({
      network: {
        ...BASE_NETWORK,
        settings: { firewall_default_policy: 'accept', custom_key: 'preserved' },
      },
    });

    const dropRadio = screen.getByRole('radio', { name: /drop all/i });
    fireEvent.click(dropRadio);

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [
      string,
      { network: { settings: Record<string, unknown> } }
    ];
    expect(payload.network.settings.custom_key).toBe('preserved');
    expect(payload.network.settings.firewall_default_policy).toBe('drop');
  });

  it('sends settings: { firewall_default_policy: "accept" } when network has no prior settings', async () => {
    mockPut.mockResolvedValueOnce(envelope({ network: BASE_NETWORK }));

    renderModal({ network: { ...BASE_NETWORK, settings: undefined } });

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [
      string,
      { network: { settings: { firewall_default_policy: string } } }
    ];
    expect(payload.network.settings.firewall_default_policy).toBe('accept');
  });

  // ──── Success notification message content ───────────────────────────────

  it('includes the network name in the success notification', async () => {
    mockPut.mockResolvedValueOnce(envelope({ network: BASE_NETWORK }));

    renderModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'success',
          message: 'Network "prod-overlay" updated',
        })
      )
    );
  });

  // ──── Error handling ──────────────────────────────────────────────────────

  it('shows error notification when API rejects with an Error', async () => {
    mockPut.mockRejectedValueOnce(new Error('Network unreachable'));

    const { onSaved, onClose } = renderModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Network unreachable' })
      )
    );

    expect(onSaved).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('shows generic "Update failed" message when API rejects with a non-Error', async () => {
    mockPut.mockRejectedValueOnce('oops');

    renderModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Update failed' })
      )
    );
  });

  // ──── Submitting state ────────────────────────────────────────────────────

  it('shows "Saving…" text on the button while submitting', async () => {
    let resolvePut!: (v: unknown) => void;
    mockPut.mockReturnValueOnce(
      new Promise((res) => { resolvePut = res; })
    );

    renderModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(screen.getByText(/saving…/i)).toBeInTheDocument()
    );

    // Resolve to avoid act() warnings
    resolvePut(envelope({ network: BASE_NETWORK }));
    await waitFor(() =>
      expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument()
    );
  });

  it('disables all form controls while submitting', async () => {
    let resolvePut!: (v: unknown) => void;
    mockPut.mockReturnValueOnce(
      new Promise((res) => { resolvePut = res; })
    );

    renderModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(screen.getByText(/saving…/i)).toBeInTheDocument()
    );

    // All inputs/selects/textareas should be disabled
    expect(screen.getByDisplayValue('prod-overlay')).toBeDisabled();
    expect(screen.getByRole('combobox')).toBeDisabled();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();
    // Both radios should be disabled
    screen.getAllByRole('radio').forEach((r) => expect(r).toBeDisabled());

    resolvePut(envelope({ network: BASE_NETWORK }));
    await waitFor(() =>
      expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument()
    );
  });

  it('does not re-submit if form is submitted while already submitting', async () => {
    let resolvePut!: (v: unknown) => void;
    mockPut.mockReturnValue(
      new Promise((res) => { resolvePut = res; })
    );

    renderModal();

    const form = screen.getByRole('button', { name: /save changes/i }).closest('form')!;
    fireEvent.submit(form);
    fireEvent.submit(form);
    fireEvent.submit(form);

    await waitFor(() =>
      expect(screen.getByText(/saving…/i)).toBeInTheDocument()
    );

    expect(mockPut).toHaveBeenCalledTimes(1);

    resolvePut(envelope({ network: BASE_NETWORK }));
    await waitFor(() =>
      expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument()
    );
  });

  // ──── Cancel button ───────────────────────────────────────────────────────

  it('calls onClose when Cancel is clicked', () => {
    const { onClose } = renderModal();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ──── Re-initialisation when network prop changes ─────────────────────────

  it('updates form fields when network prop changes', () => {
    const { rerender } = render(
      <BrowserRouter>
        <NetworkEditModal
          isOpen={true}
          network={BASE_NETWORK}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );

    expect(screen.getByDisplayValue('prod-overlay')).toBeInTheDocument();

    const newNetwork: SdwanNetwork = {
      ...BASE_NETWORK,
      id: 'net-xyz',
      name: 'dev-overlay',
      description: 'Dev network',
      status: 'registered',
      settings: { firewall_default_policy: 'drop' },
    };

    rerender(
      <BrowserRouter>
        <NetworkEditModal
          isOpen={true}
          network={newNetwork}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );

    expect(screen.getByDisplayValue('dev-overlay')).toBeInTheDocument();
    expect(screen.getByDisplayValue('Dev network')).toBeInTheDocument();
    const statusSelect = screen.getByRole('combobox') as HTMLSelectElement;
    expect(statusSelect.value).toBe('registered');
    const dropRadio = screen.getByRole('radio', { name: /drop all/i }) as HTMLInputElement;
    expect(dropRadio.checked).toBe(true);
  });

  // ──── Pending-approval branch (IMP-87ec6f651f07) ──────────────────────────

  it('shows the pending-approval notification (not success) and skips onSaved when the update is parked', async () => {
    mockPut.mockResolvedValueOnce({
      status: 202,
      data: {
        success: true,
        data: {
          pending: true,
          deferred_operation_id: 'dop-1',
          action_category: 'sdwan.network_update',
          approval_request_id: 'ar-1',
          message: 'Approval required',
        },
      },
    });

    const { onSaved, onClose } = renderModal();

    fireEvent.submit(
      screen.getByRole('button', { name: /save changes/i }).closest('form')!
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval required/i),
          link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
        })
      )
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' })
    );
    expect(onSaved).not.toHaveBeenCalled();
    expect(onClose).toHaveBeenCalled();
  });
});
