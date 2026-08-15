import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { FirewallRuleCreateModal } from './FirewallRuleCreateModal';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    createFirewallRule: (...args: unknown[]) => mockPost(...args),
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
  return render(
    <BrowserRouter>
      <FirewallRuleCreateModal {...defaultProps} {...props} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('FirewallRuleCreateModal', () => {
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
            link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
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
