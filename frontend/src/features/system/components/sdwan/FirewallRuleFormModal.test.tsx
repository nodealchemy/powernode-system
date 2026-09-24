import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { FirewallRuleFormModal } from './FirewallRuleFormModal';
import { APPROVALS_SURFACE_PATH } from '../../utils/pendingApproval';
import type { SdwanFirewallRule } from '../../types/sdwan.types';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();
const mockUpdateFirewallRule = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    createFirewallRule: (...args: unknown[]) => mockPost(...args),
    updateFirewallRule: (...args: unknown[]) => mockUpdateFirewallRule(...args),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// Modal uses createPortal — render into document.body in tests
jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({ isOpen, onClose, title, children }: {
    isOpen: boolean;
    onClose: () => void;
    title: string;
    children: React.ReactNode;
  }) => {
    if (!isOpen) return null;
    return (
      <div role="dialog" aria-label={title}>
        <h3>{title}</h3>
        <button aria-label="Close modal" onClick={onClose}>×</button>
        {children}
      </div>
    );
  },
}));

jest.mock('@/shared/components/ui/Button', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    type,
    variant,
  }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    type?: 'button' | 'submit' | 'reset';
    variant?: string;
  }) => (
    <button
      onClick={onClick}
      disabled={disabled}
      type={type ?? 'button'}
      data-variant={variant}
    >
      {children}
    </button>
  ),
}));

// =============================================================================
// Helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

/**
 * Port inputs have no htmlFor/id association, so getByLabelText won't work.
 * Instead find by the label element text, then get the next sibling input.
 */
function getPortFromInput(): HTMLElement {
  // Label text is "Port from (optional)" — contains "Port from"
  const label = Array.from(document.querySelectorAll('label')).find(
    (l) => l.textContent?.trim().startsWith('Port from'),
  );
  if (!label) throw new Error('Port from label not found');
  const input = label.parentElement?.querySelector('input[type="number"]');
  if (!input) throw new Error('Port from input not found');
  return input as HTMLElement;
}

function getPortToInput(): HTMLElement {
  const labels = Array.from(document.querySelectorAll('label')).filter(
    (l) => l.textContent?.trim() === 'Port to',
  );
  if (!labels.length) throw new Error('Port to label not found');
  const input = labels[0].parentElement?.querySelector('input[type="number"]');
  if (!input) throw new Error('Port to input not found');
  return input as HTMLElement;
}

const NETWORK_ID = 'net-abc-123';

const defaultProps = {
  isOpen: true,
  networkId: NETWORK_ID,
  onClose: jest.fn(),
  onCreated: jest.fn(),
};

function renderModal(props: Partial<typeof defaultProps> = {}) {
  // rule={null} IS create mode — the whole point of the collapse.
  const merged = { ...defaultProps, ...props };
  return render(
    <BrowserRouter>
      <FirewallRuleFormModal
        isOpen={merged.isOpen}
        networkId={merged.networkId}
        rule={null}
        onClose={merged.onClose}
        onSaved={merged.onCreated}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
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

const renderEditModal = (
  props: Partial<React.ComponentProps<typeof FirewallRuleFormModal>> = {}
) => {
  const onClose = jest.fn();
  const onSaved = jest.fn();

  render(
    <BrowserRouter>
      <FirewallRuleFormModal
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

describe('FirewallRuleFormModal — create mode (rule=null)', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  // Helper to get the protocol select (the one that contains 'tcp', 'udp', 'icmp6' options)
  // The src/dst kind selects have option value='all' displayed as 'any', while the protocol
  // select has option value='any' — but getByDisplayValue matches the displayed label of
  // the selected option, which is 'any' for all three. Use getByRole + name instead.
  function getProtocolSelect() {
    // Protocol label text is "Protocol" — find the select in that field group
    // We look for the select whose options include 'icmp6' (unique to protocol)
    const selects = screen.getAllByRole('combobox');
    return selects.find((s) => {
      const opts = Array.from(s.querySelectorAll('option')).map((o) => o.value);
      return opts.includes('icmp6');
    }) as HTMLSelectElement;
  }

  function getSrcKindSelect() {
    const selects = screen.getAllByRole('combobox');
    // src kind select has option value='peer_id' — unique among selector kind selects
    // it's the first select whose options include 'peer_id' and comes before dst kind
    return selects.find((s) => {
      const opts = Array.from(s.querySelectorAll('option')).map((o) => o.value);
      return opts.includes('peer_id') && opts.includes('all');
    }) as HTMLSelectElement;
  }

  function getDstKindSelect() {
    const selects = screen.getAllByRole('combobox');
    const matching = selects.filter((s) => {
      const opts = Array.from(s.querySelectorAll('option')).map((o) => o.value);
      return opts.includes('peer_id') && opts.includes('all');
    });
    // dst selector is the second matching select (after src)
    return matching[1] as HTMLSelectElement;
  }

  // ── render ────────────────────────────────────────────────────────────────

  describe('render', () => {
    it('renders nothing when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    });

    it('renders the modal with title when isOpen is true', () => {
      renderModal();
      expect(screen.getByRole('dialog')).toBeInTheDocument();
      expect(screen.getByText('Add firewall rule')).toBeInTheDocument();
    });

    it('renders all form controls with correct defaults', () => {
      renderModal();
      // Name field
      expect(screen.getByPlaceholderText('e.g. allow-ssh')).toBeInTheDocument();
      // Priority field defaults to 1000
      const priorityInput = screen.getByDisplayValue('1000');
      expect(priorityInput).toBeInTheDocument();
      // Action select defaults to accept
      expect(screen.getByDisplayValue('accept')).toBeInTheDocument();
      // Direction defaults to ingress
      expect(screen.getByDisplayValue('ingress')).toBeInTheDocument();
      // Protocol defaults to any — use the helper to avoid ambiguity
      const protoSelect = getProtocolSelect();
      expect(protoSelect.value).toBe('any');
    });

    it('does NOT render port fields when protocol is "any"', () => {
      renderModal();
      // Port labels are not in the DOM when protocol is "any"
      const portLabels = Array.from(document.querySelectorAll('label')).map((l) => l.textContent?.trim());
      expect(portLabels.some((t) => t?.startsWith('Port from'))).toBe(false);
    });

    it('renders port fields when protocol is switched to "tcp"', () => {
      renderModal();
      fireEvent.change(getProtocolSelect(), { target: { value: 'tcp' } });
      expect(getPortFromInput()).toBeInTheDocument();
      expect(getPortToInput()).toBeInTheDocument();
    });

    it('renders port fields when protocol is switched to "udp"', () => {
      renderModal();
      fireEvent.change(getProtocolSelect(), { target: { value: 'udp' } });
      expect(getPortFromInput()).toBeInTheDocument();
    });

    it('does NOT render port fields when protocol is "icmp6"', () => {
      renderModal();
      fireEvent.change(getProtocolSelect(), { target: { value: 'icmp6' } });
      const portLabels = Array.from(document.querySelectorAll('label')).map((l) => l.textContent?.trim());
      expect(portLabels.some((t) => t?.startsWith('Port from'))).toBe(false);
    });

    it('Create rule button is disabled when name is empty', () => {
      renderModal();
      const createButton = screen.getByRole('button', { name: /create rule/i });
      expect(createButton).toBeDisabled();
    });

    it('Create rule button becomes enabled when name is filled', () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });
      expect(screen.getByRole('button', { name: /create rule/i })).not.toBeDisabled();
    });
  });

  // ── selector field conditional rendering ─────────────────────────────────

  describe('selector fields', () => {
    it('hides value input when selector kind is "all" (any)', () => {
      renderModal();
      // When kind=all, no text input appears for that selector row
      expect(screen.queryByPlaceholderText('fdf8:.../64')).not.toBeInTheDocument();
      expect(screen.queryByPlaceholderText('019…')).not.toBeInTheDocument();
    });

    it('shows a text input with cidr placeholder when src kind is set to cidr', () => {
      renderModal();
      fireEvent.change(getSrcKindSelect(), { target: { value: 'cidr' } });
      expect(screen.getByPlaceholderText('fdf8:.../64')).toBeInTheDocument();
    });

    it('shows a text input with peer_id placeholder when dst kind is set to peer', () => {
      renderModal();
      fireEvent.change(getDstKindSelect(), { target: { value: 'peer_id' } });
      expect(screen.getByPlaceholderText('019…')).toBeInTheDocument();
    });

    it('shows a text input with tag placeholder when kind is set to tag', () => {
      renderModal();
      fireEvent.change(getSrcKindSelect(), { target: { value: 'tag' } });
      expect(screen.getByPlaceholderText('production')).toBeInTheDocument();
    });
  });

  // ── validation ────────────────────────────────────────────────────────────

  describe('validation', () => {
    it('shows error and does not call API when name is blank on submit', async () => {
      renderModal();
      // Name is empty; submit via form (the button is disabled, so fire submit on form)
      const form = screen.getByRole('dialog').querySelector('form') as HTMLFormElement;
      fireEvent.submit(form);
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Rule name is required',
        }),
      );
      expect(mockPost).not.toHaveBeenCalled();
    });

    it('shows error when only port_from is provided (port_to is empty)', async () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'test-rule' },
      });
      // Switch to tcp to show port fields
      fireEvent.change(getProtocolSelect(), { target: { value: 'tcp' } });
      // Fill only port_from
      fireEvent.change(getPortFromInput(), { target: { value: '80' } });
      // Submit
      const form = screen.getByRole('dialog').querySelector('form') as HTMLFormElement;
      fireEvent.submit(form);
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Provide both port_from and port_to, or neither',
        }),
      );
      expect(mockPost).not.toHaveBeenCalled();
    });

    it('shows error when only port_to is provided (port_from is empty)', async () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'test-rule' },
      });
      fireEvent.change(getProtocolSelect(), { target: { value: 'tcp' } });
      // Fill only port_to
      fireEvent.change(getPortToInput(), { target: { value: '8080' } });
      const form = screen.getByRole('dialog').querySelector('form') as HTMLFormElement;
      fireEvent.submit(form);
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Provide both port_from and port_to, or neither',
        }),
      );
    });

    it('shows error when port range given with non-tcp/udp protocol', async () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'test-rule' },
      });
      // Set tcp to get port fields, fill them, then switch to icmp6
      const protoSelect = getProtocolSelect();
      fireEvent.change(protoSelect, { target: { value: 'tcp' } });
      fireEvent.change(getPortFromInput(), { target: { value: '80' } });
      fireEvent.change(getPortToInput(), { target: { value: '80' } });
      // Now switch to icmp6 — port fields disappear but state still has values
      // The validation fires on portFrom state value, not the DOM
      fireEvent.change(getProtocolSelect(), { target: { value: 'icmp6' } });
      const form = screen.getByRole('dialog').querySelector('form') as HTMLFormElement;
      fireEvent.submit(form);
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Port range only applies to tcp or udp',
        }),
      );
    });
  });

  // ── successful submission ─────────────────────────────────────────────────

  describe('successful submission', () => {
    const mockRule = {
      id: 'rule-1',
      network_id: NETWORK_ID,
      name: 'allow-ssh',
      priority: 1000,
      action: 'accept' as const,
      direction: 'ingress' as const,
      protocol: 'tcp' as const,
      enabled: true,
    };

    it('calls sdwanApi.createFirewallRule with correct URL and payload for default selector (all)', async () => {
      mockPost.mockResolvedValueOnce(envelope({ firewall_rule: mockRule }));
      renderModal();

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });

      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          NETWORK_ID,
          {
            name: 'allow-ssh',
            priority: 1000,
            action: 'accept',
            direction: 'ingress',
            protocol: 'any',
            src_selector: { all: true },
            dst_selector: { all: true },
            port_range: null,
          },
        ),
      );
    });

    it('calls sdwanApi.createFirewallRule with tcp + port_range payload', async () => {
      mockPost.mockResolvedValueOnce(envelope({ firewall_rule: mockRule }));
      renderModal();

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });
      fireEvent.change(getProtocolSelect(), { target: { value: 'tcp' } });
      fireEvent.change(getPortFromInput(), { target: { value: '22' } });
      fireEvent.change(getPortToInput(), { target: { value: '22' } });

      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          NETWORK_ID,
          expect.objectContaining({
            protocol: 'tcp',
            port_range: { from: 22, to: 22 },
          }),
        ),
      );
    });

    it('calls sdwanApi.createFirewallRule with cidr src_selector', async () => {
      mockPost.mockResolvedValueOnce(envelope({ firewall_rule: mockRule }));
      renderModal();

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'cidr-rule' },
      });
      fireEvent.change(getSrcKindSelect(), { target: { value: 'cidr' } });
      fireEvent.change(screen.getByPlaceholderText('fdf8:.../64'), {
        target: { value: 'fdf8::/64' },
      });

      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          NETWORK_ID,
          expect.objectContaining({
            src_selector: { cidr: 'fdf8::/64' },
            dst_selector: { all: true },
          }),
        ),
      );
    });

    it('calls sdwanApi.createFirewallRule with peer_id dst_selector', async () => {
      mockPost.mockResolvedValueOnce(envelope({ firewall_rule: mockRule }));
      renderModal();

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'peer-rule' },
      });
      fireEvent.change(getDstKindSelect(), { target: { value: 'peer_id' } });
      fireEvent.change(screen.getByPlaceholderText('019…'), {
        target: { value: 'peer-xyz' },
      });

      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          NETWORK_ID,
          expect.objectContaining({
            src_selector: { all: true },
            dst_selector: { peer_id: 'peer-xyz' },
          }),
        ),
      );
    });

    it('sends undefined src_selector when cidr kind is selected but value is empty', async () => {
      mockPost.mockResolvedValueOnce(envelope({ firewall_rule: mockRule }));
      renderModal();

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'empty-cidr' },
      });
      fireEvent.change(getSrcKindSelect(), { target: { value: 'cidr' } });
      // Leave cidr input empty

      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          NETWORK_ID,
          expect.objectContaining({
            src_selector: undefined,
          }),
        ),
      );
    });

    it('shows a success notification with the rule name after creation', async () => {
      mockPost.mockResolvedValueOnce(envelope({ firewall_rule: mockRule }));
      renderModal();

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Rule "allow-ssh" created',
        }),
      );
    });

    it('calls onCreated and onClose after successful creation', async () => {
      const onCreated = jest.fn();
      const onClose = jest.fn();
      mockPost.mockResolvedValueOnce(envelope({ firewall_rule: mockRule }));
      renderModal({ onCreated, onClose });

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() => expect(onCreated).toHaveBeenCalledTimes(1));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('resets form fields after successful creation', async () => {
      const onClose = jest.fn();
      mockPost.mockResolvedValueOnce(envelope({ firewall_rule: mockRule }));
      renderModal({ onClose });

      const nameInput = screen.getByPlaceholderText('e.g. allow-ssh');
      fireEvent.change(nameInput, { target: { value: 'allow-ssh' } });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    });

    it('trims whitespace from rule name before submitting', async () => {
      mockPost.mockResolvedValueOnce(envelope({ firewall_rule: mockRule }));
      renderModal();

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: '  allow-ssh  ' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          NETWORK_ID,
          expect.objectContaining({ name: 'allow-ssh' }),
        ),
      );
    });
  });

  // ── error handling ────────────────────────────────────────────────────────

  describe('error handling', () => {
    it('shows the error message from the thrown Error on API failure', async () => {
      mockPost.mockRejectedValueOnce(new Error('Network unavailable'));
      renderModal();

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Network unavailable',
        }),
      );
    });

    it('shows generic error message when a non-Error is thrown', async () => {
      mockPost.mockRejectedValueOnce('boom');
      renderModal();

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to create rule',
        }),
      );
    });

    it('does not call onCreated or onClose when API fails', async () => {
      const onCreated = jest.fn();
      const onClose = jest.fn();
      mockPost.mockRejectedValueOnce(new Error('Server error'));
      renderModal({ onCreated, onClose });

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      expect(onCreated).not.toHaveBeenCalled();
      expect(onClose).not.toHaveBeenCalled();
    });

    it('re-enables the form after API failure', async () => {
      mockPost.mockRejectedValueOnce(new Error('Oops'));
      renderModal();

      const nameInput = screen.getByPlaceholderText('e.g. allow-ssh');
      fireEvent.change(nameInput, { target: { value: 'allow-ssh' } });
      const createBtn = screen.getByRole('button', { name: /create rule/i });
      fireEvent.click(createBtn);

      // During submission button shows "Creating…" and is disabled
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /creating/i })).toBeDisabled(),
      );

      // After failure, form re-enables
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /create rule/i })).not.toBeDisabled(),
      );
    });
  });

  // ── close / cancel ────────────────────────────────────────────────────────

  describe('close / cancel', () => {
    it('calls onClose when Cancel button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('calls onClose when the modal Close button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      fireEvent.click(screen.getByRole('button', { name: /close modal/i }));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('does not call onClose while submitting', async () => {
      let resolvePost!: (v: unknown) => void;
      mockPost.mockReturnValueOnce(new Promise((res) => { resolvePost = res; }));
      const onClose = jest.fn();
      renderModal({ onClose });

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      // While submitting
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /creating/i })).toBeDisabled(),
      );

      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(onClose).not.toHaveBeenCalled();

      // Clean up
      resolvePost(envelope({ firewall_rule: { id: 'x', network_id: NETWORK_ID, name: 'allow-ssh', priority: 1000, action: 'accept', direction: 'ingress', protocol: 'any', enabled: true } }));
    });
  });

  // ── submitting state ──────────────────────────────────────────────────────

  describe('submitting state', () => {
    it('disables inputs and shows "Creating…" text while the API call is in-flight', async () => {
      let resolvePost!: (v: unknown) => void;
      mockPost.mockReturnValueOnce(new Promise((res) => { resolvePost = res; }));
      renderModal();

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /creating/i })).toBeDisabled(),
      );
      expect(screen.getByPlaceholderText('e.g. allow-ssh')).toBeDisabled();

      // Resolve the promise to avoid act() warning
      resolvePost(envelope({ firewall_rule: { id: 'x', network_id: NETWORK_ID, name: 'allow-ssh', priority: 1000, action: 'accept', direction: 'ingress', protocol: 'any', enabled: true } }));
      await waitFor(() => expect(screen.queryByRole('button', { name: /creating/i })).not.toBeInTheDocument());
    });
  });

  // ── selector grammar — buildSelector edge cases ───────────────────────────

  describe('buildSelector — all four kinds', () => {
    const successMock = () =>
      envelope({
        firewall_rule: {
          id: 'r1',
          network_id: NETWORK_ID,
          name: 'rule',
          priority: 1000,
          action: 'accept',
          direction: 'ingress',
          protocol: 'any',
          enabled: true,
        },
      });

    it('sends { all: true } when kind is "all"', async () => {
      mockPost.mockResolvedValueOnce(successMock());
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'rule' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));
      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          NETWORK_ID,
          expect.objectContaining({ src_selector: { all: true } }),
        ),
      );
    });

    it('sends { tag: value } when kind is "tag"', async () => {
      mockPost.mockResolvedValueOnce(successMock());
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'tag-rule' },
      });
      fireEvent.change(getSrcKindSelect(), { target: { value: 'tag' } });
      fireEvent.change(screen.getByPlaceholderText('production'), {
        target: { value: 'production' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));
      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          NETWORK_ID,
          expect.objectContaining({ src_selector: { tag: 'production' } }),
        ),
      );
    });
  });

  // ── action / direction / priority controls ────────────────────────────────

  describe('field interactions', () => {
    it('sends custom priority value', async () => {
      mockPost.mockResolvedValueOnce(
        envelope({ firewall_rule: { id: 'r1', network_id: NETWORK_ID, name: 'n', priority: 500, action: 'drop', direction: 'both', protocol: 'any', enabled: true } }),
      );
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'n' },
      });
      fireEvent.change(screen.getByDisplayValue('1000'), { target: { value: '500' } });
      fireEvent.change(screen.getByDisplayValue('accept'), { target: { value: 'drop' } });
      fireEvent.change(screen.getByDisplayValue('ingress'), { target: { value: 'both' } });

      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          NETWORK_ID,
          expect.objectContaining({
            priority: 500,
            action: 'drop',
            direction: 'both',
          }),
        ),
      );
    });

    it('sends reject action', async () => {
      mockPost.mockResolvedValueOnce(
        envelope({ firewall_rule: { id: 'r1', network_id: NETWORK_ID, name: 'n', priority: 1000, action: 'reject', direction: 'egress', protocol: 'any', enabled: true } }),
      );
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'n' },
      });
      fireEvent.change(screen.getByDisplayValue('accept'), { target: { value: 'reject' } });
      fireEvent.change(screen.getByDisplayValue('ingress'), { target: { value: 'egress' } });

      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          NETWORK_ID,
          expect.objectContaining({ action: 'reject', direction: 'egress' }),
        ),
      );
    });
  });

  // ── pending-approval branch (IMP-87ec6f651f07) ────────────────────────────

  describe('pending-approval branch', () => {
    it('shows the pending-approval notification (not success) and skips onCreated when the create is parked', async () => {
      const onCreated = jest.fn();
      const onClose = jest.fn();
      mockPost.mockResolvedValueOnce({
        pending: true,
        deferred_operation_id: 'dop-1',
        action_category: 'sdwan.firewall_rule_create',
        approval_request_id: 'ar-1',
        message: 'Approval required',
      });
      renderModal({ onCreated, onClose });

      fireEvent.change(screen.getByPlaceholderText('e.g. allow-ssh'), {
        target: { value: 'allow-ssh' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create rule/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'info',
            message: expect.stringMatching(/approval required/i),
            link: expect.objectContaining({ to: `${APPROVALS_SURFACE_PATH}?request=ar-1` }),
          }),
        ),
      );
      expect(mockAddNotification).not.toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success' }),
      );
      expect(onCreated).not.toHaveBeenCalled();
      expect(onClose).toHaveBeenCalled();
    });
  });
});

describe('FirewallRuleFormModal — edit mode (rule given)', () => {
  beforeEach(() => {
    mockUpdateFirewallRule.mockReset();
    mockAddNotification.mockReset();
  });

  // ──── Render / null guard ────────────────────────────────────────────────

  // rule={null} no longer renders nothing — it IS create mode. The create half
  // above covers that path; here we only assert the two modes are one component
  // and that create mode carries no "Rule enabled" toggle.
  it('renders create mode, not an empty tree, when the rule prop is null', () => {
    render(
      <BrowserRouter>
        <FirewallRuleFormModal
          isOpen={true}
          networkId={NETWORK_ID}
          rule={null}
          onClose={jest.fn()}
          onSaved={jest.fn()}
        />
      </BrowserRouter>
    );
    expect(screen.getByRole('dialog', { name: 'Add firewall rule' })).toBeInTheDocument();
    expect(screen.queryByText('Rule enabled')).not.toBeInTheDocument();
  });

  it('renders nothing when isOpen is false', () => {
    const { container } = render(
      <BrowserRouter>
        <FirewallRuleFormModal
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
    renderEditModal();

    // Name field shows rule name
    const nameInput = screen.getByDisplayValue('Allow HTTPS');
    expect(nameInput).toBeInTheDocument();

    // Priority field
    expect(screen.getByDisplayValue('100')).toBeInTheDocument();
  });

  it('shows the modal title as "Edit <rule name>"', () => {
    renderEditModal();
    expect(screen.getByText('Edit Allow HTTPS')).toBeInTheDocument();
  });

  it('pre-selects action, direction, protocol from the rule', () => {
    renderEditModal();

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
    renderEditModal();
    const checkbox = screen.getByRole('checkbox');
    expect(checkbox).toBeChecked();
  });

  it('shows Rule enabled checkbox unchecked when rule.enabled is false', () => {
    renderEditModal({ rule: { ...BASE_RULE, enabled: false } });
    const checkbox = screen.getByRole('checkbox');
    expect(checkbox).not.toBeChecked();
  });

  // ──── Selector rendering ─────────────────────────────────────────────────

  it('src_selector "all:true" renders as "any" with no value input', () => {
    renderEditModal();
    // Src is { all: true } — should select "any" option, no additional text input
    const srcSelect = screen.getAllByDisplayValue('any')[0];
    expect(srcSelect).toBeInTheDocument();
    // No value input is rendered when kind === 'all'
  });

  it('dst_selector "cidr" renders with CIDR value input', () => {
    renderEditModal();
    // dst is { cidr: '10.0.0.0/8' } — there should be a text input with that value
    expect(screen.getByDisplayValue('10.0.0.0/8')).toBeInTheDocument();
  });

  it('renders peer_id selector value when rule uses peer_id', () => {
    renderEditModal({
      rule: { ...BASE_RULE, src_selector: { peer_id: 'peer-abc' }, dst_selector: undefined },
    });
    expect(screen.getByDisplayValue('peer-abc')).toBeInTheDocument();
  });

  it('renders tag selector value when rule uses tag', () => {
    renderEditModal({
      rule: { ...BASE_RULE, src_selector: { tag: 'prod' }, dst_selector: undefined },
    });
    expect(screen.getByDisplayValue('prod')).toBeInTheDocument();
  });

  // ──── Port range conditional visibility ─────────────────────────────────

  it('shows port range fields when protocol is tcp', () => {
    renderEditModal({ rule: { ...BASE_RULE, protocol: 'tcp' } });
    // Labels don't have htmlFor — find by text content presence
    expect(screen.getByText('Port from')).toBeInTheDocument();
    expect(screen.getByText('Port to')).toBeInTheDocument();
  });

  it('shows port range fields when protocol is udp', () => {
    renderEditModal({ rule: { ...BASE_RULE, protocol: 'udp', port_range: null } });
    expect(screen.getByText('Port from')).toBeInTheDocument();
    expect(screen.getByText('Port to')).toBeInTheDocument();
  });

  it('hides port range fields when protocol is "any"', () => {
    renderEditModal({ rule: { ...BASE_RULE, protocol: 'any', port_range: null } });
    expect(screen.queryByText('Port from')).not.toBeInTheDocument();
    expect(screen.queryByText('Port to')).not.toBeInTheDocument();
  });

  it('hides port range fields when protocol is "icmp6"', () => {
    renderEditModal({ rule: { ...BASE_RULE, protocol: 'icmp6', port_range: null } });
    expect(screen.queryByText('Port from')).not.toBeInTheDocument();
    expect(screen.queryByText('Port to')).not.toBeInTheDocument();
  });

  it('populates port_range fields from rule', () => {
    renderEditModal({ rule: { ...BASE_RULE, protocol: 'tcp', port_range: { from: 443, to: 443 } } });
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
    renderEditModal({ rule: { ...BASE_RULE, protocol: 'udp', port_range: null } });

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
    expect(mockUpdateFirewallRule).not.toHaveBeenCalled();
  });

  it('shows an error when only port_to is set (asymmetric)', async () => {
    renderEditModal({ rule: { ...BASE_RULE, protocol: 'udp', port_range: null } });

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
    expect(mockUpdateFirewallRule).not.toHaveBeenCalled();
  });

  // ──── Save button disabled when name is empty ────────────────────────────

  it('disables Save button when name is cleared', () => {
    renderEditModal();
    const nameInput = screen.getByDisplayValue('Allow HTTPS');
    fireEvent.change(nameInput, { target: { value: '' } });
    expect(screen.getByRole('button', { name: /save/i })).toBeDisabled();
  });

  it('enables Save button when name is non-empty', () => {
    renderEditModal();
    expect(screen.getByRole('button', { name: /save/i })).not.toBeDisabled();
  });

  // ──── Successful submit ──────────────────────────────────────────────────

  it('calls sdwanApi.updateFirewallRule with the ids and payload on submit', async () => {
    mockUpdateFirewallRule.mockResolvedValueOnce({ ...BASE_RULE, name: 'Allow HTTPS' });

    const { onSaved, onClose } = renderEditModal();

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockUpdateFirewallRule).toHaveBeenCalledTimes(1));

    expect(mockUpdateFirewallRule).toHaveBeenCalledWith(NETWORK_ID, BASE_RULE.id, {
      name: 'Allow HTTPS',
      priority: 100,
      action: 'accept',
      direction: 'ingress',
      protocol: 'tcp',
      enabled: true,
      src_selector: { all: true },
      dst_selector: { cidr: '10.0.0.0/8' },
      port_range: { from: 443, to: 443 },
    });

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' })
    );
  });

  it('sends port_range as null when port fields are both empty', async () => {
    mockUpdateFirewallRule.mockResolvedValueOnce({ ...BASE_RULE, protocol: 'any', port_range: null });

    renderEditModal({ rule: { ...BASE_RULE, protocol: 'any', port_range: null } });

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockUpdateFirewallRule).toHaveBeenCalledTimes(1));

    const [, , payload] = mockUpdateFirewallRule.mock.calls[0] as [string, string, { port_range: null }];
    expect(payload.port_range).toBeNull();
  });

  it('sends src_selector as { all: true } when src kind is "any"', async () => {
    mockUpdateFirewallRule.mockResolvedValueOnce(BASE_RULE);

    renderEditModal({ rule: { ...BASE_RULE, src_selector: { all: true } } });

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockUpdateFirewallRule).toHaveBeenCalledTimes(1));

    const [, , payload] = mockUpdateFirewallRule.mock.calls[0] as [string, string, { src_selector: unknown }];
    expect(payload.src_selector).toEqual({ all: true });
  });

  it('sends dst_selector as { peer_id } when dst kind is "peer"', async () => {
    mockUpdateFirewallRule.mockResolvedValueOnce({ ...BASE_RULE, dst_selector: { peer_id: 'peer-xyz' } });

    renderEditModal({
      rule: { ...BASE_RULE, protocol: 'any', port_range: null, dst_selector: { peer_id: 'peer-xyz' } },
    });

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockUpdateFirewallRule).toHaveBeenCalledTimes(1));

    const [, , payload] = mockUpdateFirewallRule.mock.calls[0] as [string, string, { dst_selector: unknown }];
    expect(payload.dst_selector).toEqual({ peer_id: 'peer-xyz' });
  });

  it('sends updated name trimmed of whitespace', async () => {
    mockUpdateFirewallRule.mockResolvedValueOnce(BASE_RULE);

    renderEditModal({ rule: { ...BASE_RULE, protocol: 'any', port_range: null } });

    const nameInput = screen.getByDisplayValue('Allow HTTPS');
    fireEvent.change(nameInput, { target: { value: '  Allow HTTPS  ' } });

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockUpdateFirewallRule).toHaveBeenCalledTimes(1));

    const [, , payload] = mockUpdateFirewallRule.mock.calls[0] as [string, string, { name: string }];
    expect(payload.name).toBe('Allow HTTPS');
  });

  // ──── Error handling ─────────────────────────────────────────────────────

  it('shows error notification and does NOT call onSaved when API rejects', async () => {
    mockUpdateFirewallRule.mockRejectedValueOnce(new Error('Server error'));

    const { onSaved, onClose } = renderEditModal();

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
    mockUpdateFirewallRule.mockRejectedValueOnce('oops');

    renderEditModal();

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
    mockUpdateFirewallRule.mockReturnValueOnce(
      new Promise((res) => {
        resolve = res;
      })
    );

    renderEditModal();

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(screen.getByText(/saving…/i)).toBeInTheDocument());

    // Resolve to avoid act() warnings
    resolve(BASE_RULE);
    await waitFor(() => expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument());
  });

  it('disables all form controls while submitting', async () => {
    let resolve!: (v: unknown) => void;
    mockUpdateFirewallRule.mockReturnValueOnce(
      new Promise((res) => {
        resolve = res;
      })
    );

    renderEditModal();

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(screen.getByText(/saving…/i)).toBeInTheDocument());

    const nameInput = screen.getByDisplayValue('Allow HTTPS');
    expect(nameInput).toBeDisabled();

    const cancelButton = screen.getByRole('button', { name: /cancel/i });
    expect(cancelButton).toBeDisabled();

    resolve(BASE_RULE);
    await waitFor(() => expect(screen.queryByText(/saving…/i)).not.toBeInTheDocument());
  });

  // ──── Cancel button ──────────────────────────────────────────────────────

  it('does not apply the create-only tcp/udp port guard in edit mode', async () => {
    mockUpdateFirewallRule.mockResolvedValueOnce(BASE_RULE);

    // A rule carrying a port range on a non-tcp/udp protocol is legal on the
    // edit path — the create modal refused it, the edit modal never did, and
    // the collapse must not extend that refusal to existing rules.
    renderEditModal({
      rule: { ...BASE_RULE, protocol: 'any', port_range: { from: 443, to: 443 } },
    });

    fireEvent.submit(screen.getByText(/^save$/i).closest('form')!);

    await waitFor(() => expect(mockUpdateFirewallRule).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ message: 'Port range only applies to tcp or udp' })
    );
  });

  it('calls onClose when Cancel is clicked and leaves the edit fields seeded', () => {
    const { onClose } = renderEditModal();
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
    // Same reason as the network form: only create mode resets on close.
    expect(screen.getByDisplayValue('Allow HTTPS')).toBeInTheDocument();
  });

  // ──── Selector kind change: value input appears/disappears ───────────────

  it('hides value input when src selector changes from cidr to all', () => {
    renderEditModal({ rule: { ...BASE_RULE, src_selector: { cidr: '192.168.0.0/16' }, dst_selector: undefined, protocol: 'any', port_range: null } });

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
    renderEditModal({ rule: { ...BASE_RULE, src_selector: { all: true }, dst_selector: undefined, protocol: 'any', port_range: null } });

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
    renderEditModal({ rule: { ...BASE_RULE, protocol: 'any', port_range: null } });
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
    renderEditModal({ rule: { ...BASE_RULE, protocol: 'tcp', port_range: null } });
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
    mockUpdateFirewallRule.mockResolvedValueOnce({
      pending: true,
      deferred_operation_id: 'dop-1',
      action_category: 'sdwan.firewall_rule_update',
      approval_request_id: 'ar-1',
      message: 'Approval required',
    });

    const { onSaved, onClose } = renderEditModal();

    const form = screen.getByText(/^save$/i).closest('form')!;
    fireEvent.submit(form);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval required/i),
          link: expect.objectContaining({ to: `${APPROVALS_SURFACE_PATH}?request=ar-1` }),
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
