import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { FirewallRuleEditModal } from './FirewallRuleEditModal';
import type { SdwanFirewallRule } from '../../types/sdwan.types';

// =============================================================================
// Mocks
//
// FirewallRuleEditModal calls sdwanApi.updateFirewallRule, which internally
// calls apiClient.put. We mock the sdwanApi facade directly (the path the
// source imports) and also mock the apiClient so the facade's put/get are
// interceptable. We mock useNotifications to spy on notifications.
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

/** Wrap the double-envelope that apiClient resolves to. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// =============================================================================
// Fixtures
// =============================================================================

const BASE_RULE: SdwanFirewallRule = {
  id: 'rule-1',
  network_id: 'net-1',
  name: 'Allow HTTPS',
  priority: 100,
  action: 'accept',
  direction: 'ingress',
  protocol: 'tcp',
  enabled: true,
  src_selector: { all: true },
  dst_selector: { cidr: '10.0.0.0/8' },
  port_range: { from: 443, to: 443 },
};

const NETWORK_ID = 'net-1';

const renderModal = (
  props: Partial<React.ComponentProps<typeof FirewallRuleEditModal>> = {}
) => {
  const onClose = jest.fn();
  const onSaved = jest.fn();

  render(
    <BrowserRouter>
      <FirewallRuleEditModal
        isOpen={true}
        networkId={NETWORK_ID}
        rule={BASE_RULE}
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

describe('FirewallRuleEditModal', () => {
  beforeEach(() => {
    mockPut.mockReset();
    mockAddNotification.mockReset();
  });

  // ──── Render / null guard ────────────────────────────────────────────────

  it('renders nothing when rule is null', () => {
    const { container } = render(
      <BrowserRouter>
        <FirewallRuleEditModal
          isOpen={true}
          networkId={NETWORK_ID}
          rule={null}
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
        <FirewallRuleEditModal
          isOpen={false}
          networkId={NETWORK_ID}
          rule={BASE_RULE}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );
    // Modal returns null when closed
    expect(container).toBeEmptyDOMElement();
  });

  // ──── Initial state populated from rule prop ─────────────────────────────

  it('populates form fields from the rule prop on open', () => {
    renderModal();

    // Name field shows rule name
    const nameInput = screen.getByDisplayValue('Allow HTTPS');
    expect(nameInput).toBeInTheDocument();

    // Priority field
    expect(screen.getByDisplayValue('100')).toBeInTheDocument();
  });

  it('shows the modal title as "Edit <rule name>"', () => {
    renderModal();
    expect(screen.getByText('Edit Allow HTTPS')).toBeInTheDocument();
  });

  it('pre-selects action, direction, protocol from the rule', () => {
    renderModal();

    // The selects don't have id/htmlFor — query all comboboxes by display value.
    // Order in DOM: Action, Direction, Protocol (3 selects in the second row).
    const comboboxes = screen.getAllByRole('combobox');
    // Find the action select (value = 'accept')
    const actionSelect = comboboxes.find(
      (s) => (s as HTMLSelectElement).value === 'accept'
    );
    expect(actionSelect).toBeTruthy();

    const directionSelect = comboboxes.find(
      (s) => (s as HTMLSelectElement).value === 'ingress'
    );
    expect(directionSelect).toBeTruthy();

    const protocolSelect = comboboxes.find(
      (s) => (s as HTMLSelectElement).value === 'tcp'
    );
    expect(protocolSelect).toBeTruthy();
  });

  it('shows Rule enabled checkbox checked when rule.enabled is true', () => {
    renderModal();
    const checkbox = screen.getByRole('checkbox');
    expect(checkbox).toBeChecked();
  });

  it('shows Rule enabled checkbox unchecked when rule.enabled is false', () => {
    renderModal({ rule: { ...BASE_RULE, enabled: false } });
    const checkbox = screen.getByRole('checkbox');
    expect(checkbox).not.toBeChecked();
  });

  // ──── Selector rendering ─────────────────────────────────────────────────

  it('src_selector "all:true" renders as "any" with no value input', () => {
    renderModal();
    // Src is { all: true } — should select "any" option, no additional text input
    const srcSelect = screen.getAllByDisplayValue('any')[0];
    expect(srcSelect).toBeInTheDocument();
    // No value input is rendered when kind === 'all'
  });

  it('dst_selector "cidr" renders with CIDR value input', () => {
    renderModal();
    // dst is { cidr: '10.0.0.0/8' } — there should be a text input with that value
    expect(screen.getByDisplayValue('10.0.0.0/8')).toBeInTheDocument();
  });

  it('renders peer_id selector value when rule uses peer_id', () => {
    renderModal({
      rule: { ...BASE_RULE, src_selector: { peer_id: 'peer-abc' }, dst_selector: undefined },
    });
    expect(screen.getByDisplayValue('peer-abc')).toBeInTheDocument();
  });

  it('renders tag selector value when rule uses tag', () => {
    renderModal({
      rule: { ...BASE_RULE, src_selector: { tag: 'prod' }, dst_selector: undefined },
    });
    expect(screen.getByDisplayValue('prod')).toBeInTheDocument();
  });

  // ──── Port range conditional visibility ─────────────────────────────────

  it('shows port range fields when protocol is tcp', () => {
    renderModal({ rule: { ...BASE_RULE, protocol: 'tcp' } });
    // Labels don't have htmlFor — find by text content presence
    expect(screen.getByText('Port from')).toBeInTheDocument();
    expect(screen.getByText('Port to')).toBeInTheDocument();
  });

  it('shows port range fields when protocol is udp', () => {
    renderModal({ rule: { ...BASE_RULE, protocol: 'udp', port_range: null } });
    expect(screen.getByText('Port from')).toBeInTheDocument();
    expect(screen.getByText('Port to')).toBeInTheDocument();
  });

  it('hides port range fields when protocol is "any"', () => {
    renderModal({ rule: { ...BASE_RULE, protocol: 'any', port_range: null } });
    expect(screen.queryByText('Port from')).not.toBeInTheDocument();
    expect(screen.queryByText('Port to')).not.toBeInTheDocument();
  });

  it('hides port range fields when protocol is "icmp6"', () => {
    renderModal({ rule: { ...BASE_RULE, protocol: 'icmp6', port_range: null } });
    expect(screen.queryByText('Port from')).not.toBeInTheDocument();
    expect(screen.queryByText('Port to')).not.toBeInTheDocument();
  });

  it('populates port_range fields from rule', () => {
    renderModal({ rule: { ...BASE_RULE, protocol: 'tcp', port_range: { from: 443, to: 443 } } });
    // Two number inputs appear when protocol is tcp; they carry values 443 each
    expect(screen.getByText('Port from')).toBeInTheDocument();
    expect(screen.getByText('Port to')).toBeInTheDocument();
    // Both spinbuttons have value 443
    const spinbuttons = screen.getAllByRole('spinbutton');
    // Priority field + port_from + port_to
    const portInputs = spinbuttons.filter(
      (el) => (el as HTMLInputElement).min === '1'
    );
    expect(portInputs).toHaveLength(2);
    expect(portInputs[0]).toHaveValue(443);
    expect(portInputs[1]).toHaveValue(443);
  });

  // ──── Validation: port range asymmetry ──────────────────────────────────

  it('shows an error and does NOT call API when only port_from is set', async () => {
    // Use udp with no port_range so we can fill one field
    renderModal({ rule: { ...BASE_RULE, protocol: 'udp', port_range: null } });

    // Labels have no htmlFor — find port inputs by spinbutton role; filter by min=1 to skip priority
    const spinbuttons = screen.getAllByRole('spinbutton');
    const portInputs = spinbuttons.filter(
      (el) => (el as HTMLInputElement).min === '1'
    );
    // Fill only port_from (first port input)
    fireEvent.change(portInputs[0], { target: { value: '80' } });
    // Leave port_to (second) empty

    const form = screen.getByText(/^save$/i).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => {
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' })
      );
    });
    expect(mockPut).not.toHaveBeenCalled();
  });

  it('shows an error when only port_to is set (asymmetric)', async () => {
    renderModal({ rule: { ...BASE_RULE, protocol: 'udp', port_range: null } });

    const spinbuttons = screen.getAllByRole('spinbutton');
    const portInputs = spinbuttons.filter(
      (el) => (el as HTMLInputElement).min === '1'
    );
    // Fill only port_to (second port input)
    fireEvent.change(portInputs[1], { target: { value: '8080' } });

    const form = screen.getByText(/^save$/i).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() => {
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' })
      );
    });
    expect(mockPut).not.toHaveBeenCalled();
  });

  // ──── Save button disabled when name is empty ────────────────────────────

  it('disables Save button when name is cleared', () => {
    renderModal();
    const nameInput = screen.getByDisplayValue('Allow HTTPS');
    fireEvent.change(nameInput, { target: { value: '' } });
    expect(screen.getByRole('button', { name: /save/i })).toBeDisabled();
  });

  it('enables Save button when name is non-empty', () => {
    renderModal();
    expect(screen.getByRole('button', { name: /save/i })).not.toBeDisabled();
  });

  // ──── Successful submit ──────────────────────────────────────────────────

  it('calls apiClient.put with correct URL and payload on submit', async () => {
    mockPut.mockResolvedValueOnce(
      envelope({ firewall_rule: { ...BASE_RULE, name: 'Allow HTTPS' } })
    );

    const { onSaved, onClose } = renderModal();

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    expect(mockPut).toHaveBeenCalledWith(
      `/system/sdwan/networks/${NETWORK_ID}/firewall_rules/${BASE_RULE.id}`,
      {
        firewall_rule: {
          name: 'Allow HTTPS',
          priority: 100,
          action: 'accept',
          direction: 'ingress',
          protocol: 'tcp',
          enabled: true,
          src_selector: { all: true },
          dst_selector: { cidr: '10.0.0.0/8' },
          port_range: { from: 443, to: 443 },
        },
      }
    );

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' })
    );
  });

  it('sends port_range as null when port fields are both empty', async () => {
    mockPut.mockResolvedValueOnce(
      envelope({ firewall_rule: { ...BASE_RULE, protocol: 'any', port_range: null } })
    );

    renderModal({ rule: { ...BASE_RULE, protocol: 'any', port_range: null } });

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { firewall_rule: { port_range: null } }];
    expect(payload.firewall_rule.port_range).toBeNull();
  });

  it('sends src_selector as { all: true } when src kind is "any"', async () => {
    mockPut.mockResolvedValueOnce(envelope({ firewall_rule: BASE_RULE }));

    renderModal({ rule: { ...BASE_RULE, src_selector: { all: true } } });

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { firewall_rule: { src_selector: unknown } }];
    expect(payload.firewall_rule.src_selector).toEqual({ all: true });
  });

  it('sends dst_selector as { peer_id } when dst kind is "peer"', async () => {
    mockPut.mockResolvedValueOnce(
      envelope({ firewall_rule: { ...BASE_RULE, dst_selector: { peer_id: 'peer-xyz' } } })
    );

    renderModal({
      rule: { ...BASE_RULE, protocol: 'any', port_range: null, dst_selector: { peer_id: 'peer-xyz' } },
    });

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { firewall_rule: { dst_selector: unknown } }];
    expect(payload.firewall_rule.dst_selector).toEqual({ peer_id: 'peer-xyz' });
  });

  it('sends updated name trimmed of whitespace', async () => {
    mockPut.mockResolvedValueOnce(envelope({ firewall_rule: BASE_RULE }));

    renderModal({ rule: { ...BASE_RULE, protocol: 'any', port_range: null } });

    const nameInput = screen.getByDisplayValue('Allow HTTPS');
    fireEvent.change(nameInput, { target: { value: '  Allow HTTPS  ' } });

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockPut).toHaveBeenCalledTimes(1));

    const [, payload] = mockPut.mock.calls[0] as [string, { firewall_rule: { name: string } }];
    expect(payload.firewall_rule.name).toBe('Allow HTTPS');
  });

  // ──── Error handling ─────────────────────────────────────────────────────

  it('shows error notification and does NOT call onSaved when API rejects', async () => {
    mockPut.mockRejectedValueOnce(new Error('Server error'));

    const { onSaved, onClose } = renderModal();

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Server error' })
      )
    );

    expect(onSaved).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('shows generic error message when API rejects with a non-Error value', async () => {
    mockPut.mockRejectedValueOnce('oops');

    renderModal();

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Update failed' })
      )
    );
  });

  // ──── Submitting state ───────────────────────────────────────────────────

  it('shows "Saving…" text on the button while submitting', async () => {
    let resolve!: (v: unknown) => void;
    mockPut.mockReturnValueOnce(
      new Promise((res) => {
        resolve = res;
      })
    );

    renderModal();

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(screen.getByText(/saving…/i)).toBeInTheDocument());

    // Resolve to avoid act() warnings
    resolve(envelope({ firewall_rule: BASE_RULE }));
    await waitFor(() => expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument());
  });

  it('disables all form controls while submitting', async () => {
    let resolve!: (v: unknown) => void;
    mockPut.mockReturnValueOnce(
      new Promise((res) => {
        resolve = res;
      })
    );

    renderModal();

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(screen.getByText(/saving…/i)).toBeInTheDocument());

    const nameInput = screen.getByDisplayValue('Allow HTTPS');
    expect(nameInput).toBeDisabled();

    const cancelButton = screen.getByRole('button', { name: /cancel/i });
    expect(cancelButton).toBeDisabled();

    resolve(envelope({ firewall_rule: BASE_RULE }));
    await waitFor(() => expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument());
  });

  // ──── Cancel button ──────────────────────────────────────────────────────

  it('calls onClose when Cancel is clicked', () => {
    const { onClose } = renderModal();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ──── Selector kind change: value input appears/disappears ───────────────

  it('hides value input when src selector changes from cidr to all', () => {
    renderModal({ rule: { ...BASE_RULE, src_selector: { cidr: '192.168.0.0/16' }, dst_selector: undefined, protocol: 'any', port_range: null } });

    // CIDR value should be visible initially
    expect(screen.getByDisplayValue('192.168.0.0/16')).toBeInTheDocument();

    // Change the src selector kind to 'any'
    const selects = screen.getAllByRole('combobox');
    // Source selector is the first selector select
    const srcKindSelect = selects.find(
      (s) => (s as HTMLSelectElement).value === 'cidr'
    );
    expect(srcKindSelect).toBeTruthy();
    fireEvent.change(srcKindSelect!, { target: { value: 'all' } });

    // Value input should now be gone
    expect(screen.queryByDisplayValue('192.168.0.0/16')).not.toBeInTheDocument();
  });

  it('shows value input when src selector changes from all to cidr', () => {
    renderModal({ rule: { ...BASE_RULE, src_selector: { all: true }, dst_selector: undefined, protocol: 'any', port_range: null } });

    // Src kind is 'any' — no value input
    const selects = screen.getAllByRole('combobox');
    const srcKindSelect = selects.find(
      (s) => (s as HTMLSelectElement).value === 'all'
    );
    expect(srcKindSelect).toBeTruthy();
    fireEvent.change(srcKindSelect!, { target: { value: 'cidr' } });

    // Now a text input for the CIDR should appear
    // (value will be empty string initially)
    const inputs = screen.getAllByRole('textbox');
    expect(inputs.length).toBeGreaterThan(0);
  });

  // ──── Protocol change shows/hides port range ─────────────────────────────

  it('shows port range fields when protocol is changed to tcp', () => {
    renderModal({ rule: { ...BASE_RULE, protocol: 'any', port_range: null } });
    expect(screen.queryByText('Port from')).not.toBeInTheDocument();

    // Protocol select is the combobox with value 'any' that is NOT the src/dst selectors
    // The src/dst selectors also use 'any' option label; protocol has value 'any' from Protocol label position
    // Find by display value 'any' among comboboxes that also have option value='tcp'
    const comboboxes = screen.getAllByRole('combobox');
    const protocolSelect = comboboxes.find((s) => {
      const el = s as HTMLSelectElement;
      return (
        el.value === 'any' &&
        Array.from(el.options).some((o) => o.value === 'icmp6')
      );
    });
    expect(protocolSelect).toBeTruthy();
    fireEvent.change(protocolSelect!, { target: { value: 'tcp' } });

    expect(screen.getByText('Port from')).toBeInTheDocument();
    expect(screen.getByText('Port to')).toBeInTheDocument();
  });

  it('hides port range fields when protocol is changed from tcp to any', () => {
    renderModal({ rule: { ...BASE_RULE, protocol: 'tcp', port_range: null } });
    expect(screen.getByText('Port from')).toBeInTheDocument();

    // Protocol select has value 'tcp' and contains icmp6 option
    const comboboxes = screen.getAllByRole('combobox');
    const protocolSelect = comboboxes.find((s) => {
      const el = s as HTMLSelectElement;
      return (
        el.value === 'tcp' &&
        Array.from(el.options).some((o) => o.value === 'icmp6')
      );
    });
    expect(protocolSelect).toBeTruthy();
    fireEvent.change(protocolSelect!, { target: { value: 'any' } });

    expect(screen.queryByText('Port from')).not.toBeInTheDocument();
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
          action_category: 'sdwan.firewall_rule_update',
          approval_request_id: 'ar-1',
          message: 'Approval required',
        },
      },
    });

    const { onSaved, onClose } = renderModal();

    const form = screen.getByText(/^save$/i).closest('form')!;
    fireEvent.submit(form);

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
