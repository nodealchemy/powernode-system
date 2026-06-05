import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { FirewallRuleList } from './FirewallRuleList';
import type { SdwanFirewallRule } from '../../types/sdwan.types';

// =============================================================================
// Mocks
//
// FirewallRuleList imports sdwanApi which internally calls apiClient.get.
// We mock the sdwanApi facade directly because the component calls
// sdwanApi.getFirewallRules — not apiClient.get directly.
// =============================================================================

const mockGetFirewallRules = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    getFirewallRules: (...args: unknown[]) => mockGetFirewallRules(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

function envelope(rules: SdwanFirewallRule[], defaultPolicy = 'accept') {
  return { rules, defaultPolicy };
}

const RULE_ACCEPT: SdwanFirewallRule = {
  id: 'rule-001',
  network_id: 'net-abc',
  name: 'allow-web',
  priority: 10,
  action: 'accept',
  direction: 'ingress',
  protocol: 'tcp',
  src_selector: { cidr: '10.0.0.0/8' },
  dst_selector: { all: true },
  port_range: { from: 443, to: 443 },
  enabled: true,
  created_at: '2026-01-01T00:00:00Z',
};

const RULE_DROP: SdwanFirewallRule = {
  id: 'rule-002',
  network_id: 'net-abc',
  name: 'block-telnet',
  priority: 20,
  action: 'drop',
  direction: 'both',
  protocol: 'tcp',
  src_selector: { all: true },
  dst_selector: { tag: 'internal' },
  port_range: { from: 23, to: 23 },
  enabled: false,
  compiled_preview: 'iptables -A INPUT -p tcp --dport 23 -j DROP',
  last_compiled_at: '2026-02-15T12:00:00Z',
  created_at: '2026-02-01T00:00:00Z',
};

const RULE_REJECT: SdwanFirewallRule = {
  id: 'rule-003',
  network_id: 'net-abc',
  name: 'reject-smtp',
  priority: 30,
  action: 'reject',
  direction: 'egress',
  protocol: 'any',
  port_range: { from: 25, to: 587 },
  enabled: true,
  metadata: { owner: 'security', ticket: 'SEC-42' },
};

const RULE_PEER_SELECTOR: SdwanFirewallRule = {
  id: 'rule-004',
  network_id: 'net-abc',
  name: 'peer-rule',
  priority: 40,
  action: 'accept',
  direction: 'ingress',
  protocol: 'udp',
  src_selector: { peer_id: 'abcdef1234567890' },
  dst_selector: {},
  enabled: true,
};

// =============================================================================
// Tests
// =============================================================================

const renderList = (
  props: Partial<React.ComponentProps<typeof FirewallRuleList>> = {}
) =>
  render(
    <FirewallRuleList
      networkId="net-abc"
      {...props}
    />
  );

describe('FirewallRuleList', () => {
  beforeEach(() => {
    mockGetFirewallRules.mockReset();
  });

  // ── Loading state ──────────────────────────────────────────────────────────

  it('shows a loading indicator while fetching', () => {
    // Never resolves during this test — loading stays true
    mockGetFirewallRules.mockReturnValue(new Promise(() => {}));
    renderList();
    expect(screen.getByText(/loading firewall rules/i)).toBeInTheDocument();
  });

  // ── Error state ────────────────────────────────────────────────────────────

  it('shows an error message when the API call fails', async () => {
    mockGetFirewallRules.mockRejectedValue(new Error('Network timeout'));
    renderList();
    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument()
    );
  });

  it('shows a fallback error message for non-Error rejections', async () => {
    mockGetFirewallRules.mockRejectedValue('bad');
    renderList();
    await waitFor(() =>
      expect(screen.getByText('Failed to load firewall rules')).toBeInTheDocument()
    );
  });

  // ── API call ───────────────────────────────────────────────────────────────

  it('calls sdwanApi.getFirewallRules with the correct networkId', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([]));
    renderList({ networkId: 'net-xyz' });
    await waitFor(() =>
      expect(mockGetFirewallRules).toHaveBeenCalledWith('net-xyz')
    );
  });

  // ── Empty state ────────────────────────────────────────────────────────────

  it('renders empty state with accept policy hint when rules is empty and defaultPolicy=accept', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([], 'accept'));
    renderList();
    await waitFor(() =>
      expect(
        screen.getByText(/no rules — all traffic is accepted by default/i)
      ).toBeInTheDocument()
    );
  });

  it('renders empty state with drop policy hint when rules is empty and defaultPolicy=drop', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([], 'drop'));
    renderList();
    await waitFor(() =>
      expect(
        screen.getByText(/no rules — all traffic is dropped/i)
      ).toBeInTheDocument()
    );
  });

  // ── Default policy banner ──────────────────────────────────────────────────

  it('renders "Allow all" label for accept default policy', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();
    await waitFor(() => expect(screen.getByText('Allow all')).toBeInTheDocument());
    expect(screen.getByText(/default policy:/i)).toBeInTheDocument();
  });

  it('renders "Drop all (allowlist mode)" label for drop default policy', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT], 'drop'));
    renderList();
    await waitFor(() =>
      expect(screen.getByText('Drop all (allowlist mode)')).toBeInTheDocument()
    );
  });

  it('shows rule count in the policy banner', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT, RULE_DROP]));
    renderList();
    await waitFor(() => expect(screen.getByText('2 rules')).toBeInTheDocument());
  });

  it('uses singular "rule" when count is 1', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();
    await waitFor(() => expect(screen.getByText('1 rule')).toBeInTheDocument());
  });

  // ── Rule table rendering ───────────────────────────────────────────────────

  it('renders table headers when rules are present', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();
    await waitFor(() => expect(screen.getByText('Priority')).toBeInTheDocument());
    expect(screen.getByText('Name')).toBeInTheDocument();
    expect(screen.getByText('Action')).toBeInTheDocument();
    expect(screen.getByText('Match')).toBeInTheDocument();
    expect(screen.getAllByText('Actions').length).toBeGreaterThan(0);
  });

  it('renders rule name, priority, direction and protocol in collapsed row', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();
    await waitFor(() =>
      expect(screen.getByText('allow-web')).toBeInTheDocument()
    );
    expect(screen.getByText('10')).toBeInTheDocument();
    expect(screen.getByText(/ingress · tcp/i)).toBeInTheDocument();
  });

  it('shows "· disabled" suffix for disabled rules', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_DROP]));
    renderList();
    await waitFor(() =>
      expect(screen.getByText(/both · tcp · disabled/i)).toBeInTheDocument()
    );
  });

  it('does not show "· disabled" suffix for enabled rules', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();
    await waitFor(() =>
      expect(screen.getByText('allow-web')).toBeInTheDocument()
    );
    const subtitle = screen.getByText(/ingress · tcp/i);
    expect(subtitle.textContent).not.toContain('disabled');
  });

  // ── Match column ───────────────────────────────────────────────────────────

  it('renders CIDR source + any dest + single port match in Match column', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();
    await waitFor(() =>
      // describeMatch: "from 10.0.0.0/8 · to any · port 443"
      expect(screen.getByText(/from 10\.0\.0\.0\/8/)).toBeInTheDocument()
    );
    expect(screen.getByText(/to any/)).toBeInTheDocument();
    expect(screen.getByText(/port 443/)).toBeInTheDocument();
  });

  it('renders peer selector in match column as truncated peer reference', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_PEER_SELECTOR]));
    renderList();
    await waitFor(() =>
      // peer_id 'abcdef1234567890' → truncated to 'peer abcdef12…'
      expect(screen.getByText(/peer abcdef12…/)).toBeInTheDocument()
    );
  });

  it('renders "any" for empty selectors and no port_range', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_REJECT]));
    renderList();
    await waitFor(() =>
      // RULE_REJECT has no src_selector, no dst_selector, only a port range
      expect(screen.getByText(/ports 25-587/)).toBeInTheDocument()
    );
  });

  it('renders "any" match text when both selectors and port are absent', async () => {
    const noMatch: SdwanFirewallRule = {
      ...RULE_ACCEPT,
      id: 'rule-any',
      name: 'wildcard',
      src_selector: undefined,
      dst_selector: undefined,
      port_range: null,
    };
    mockGetFirewallRules.mockResolvedValue(envelope([noMatch]));
    renderList();
    await waitFor(() =>
      expect(screen.getByText('any')).toBeInTheDocument()
    );
  });

  // ── Expand / collapse row ─────────────────────────────────────────────────

  it('expands a rule row when the expand button is clicked', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();

    await waitFor(() =>
      expect(screen.getByLabelText('Expand rule allow-web')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByLabelText('Expand rule allow-web'));

    await waitFor(() =>
      // Expanded row reveals detail labels
      expect(screen.getByText('Source Selector')).toBeInTheDocument()
    );
    expect(screen.getByText('Destination Selector')).toBeInTheDocument();
    expect(screen.getByText('Enabled')).toBeInTheDocument();
    // RULE_ACCEPT enabled=true
    expect(screen.getByText('Yes')).toBeInTheDocument();
  });

  it('collapses an expanded row when the button is clicked again', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();

    await waitFor(() =>
      expect(screen.getByLabelText('Expand rule allow-web')).toBeInTheDocument()
    );

    const btn = screen.getByLabelText('Expand rule allow-web');
    fireEvent.click(btn);

    await waitFor(() =>
      expect(screen.getByLabelText('Collapse rule allow-web')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByLabelText('Collapse rule allow-web'));

    await waitFor(() =>
      expect(screen.getByLabelText('Expand rule allow-web')).toBeInTheDocument()
    );
    expect(screen.queryByText('Source Selector')).not.toBeInTheDocument();
  });

  it('shows "No (disabled)" in expanded details for a disabled rule', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_DROP]));
    renderList();

    await waitFor(() =>
      expect(screen.getByLabelText('Expand rule block-telnet')).toBeInTheDocument()
    );
    fireEvent.click(screen.getByLabelText('Expand rule block-telnet'));

    await waitFor(() =>
      expect(screen.getByText('No (disabled)')).toBeInTheDocument()
    );
  });

  it('shows full peer_id in expanded Source Selector', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_PEER_SELECTOR]));
    renderList();

    await waitFor(() =>
      expect(screen.getByLabelText('Expand rule peer-rule')).toBeInTheDocument()
    );
    fireEvent.click(screen.getByLabelText('Expand rule peer-rule'));

    await waitFor(() =>
      expect(screen.getByText('peer abcdef1234567890')).toBeInTheDocument()
    );
  });

  it('shows "any (wildcard)" for empty dst_selector in expanded details', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_PEER_SELECTOR]));
    renderList();

    await waitFor(() =>
      expect(screen.getByLabelText('Expand rule peer-rule')).toBeInTheDocument()
    );
    fireEvent.click(screen.getByLabelText('Expand rule peer-rule'));

    await waitFor(() => {
      const dstLabel = screen.getByText('Destination Selector');
      const dstParent = dstLabel.parentElement;
      expect(dstParent).toBeTruthy();
      expect(dstParent!.textContent).toContain('any (wildcard)');
    });
  });

  it('renders compiled preview in expanded row when present', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_DROP]));
    renderList();

    await waitFor(() =>
      expect(screen.getByLabelText('Expand rule block-telnet')).toBeInTheDocument()
    );
    fireEvent.click(screen.getByLabelText('Expand rule block-telnet'));

    await waitFor(() =>
      expect(
        screen.getByText('iptables -A INPUT -p tcp --dport 23 -j DROP')
      ).toBeInTheDocument()
    );
  });

  it('shows "No compiled preview" message when compiled_preview is absent', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();

    fireEvent.click(await screen.findByLabelText('Expand rule allow-web'));

    await waitFor(() =>
      expect(
        screen.getByText(/no compiled preview available/i)
      ).toBeInTheDocument()
    );
  });

  it('renders metadata JSON when metadata is present and non-empty', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_REJECT]));
    renderList();

    fireEvent.click(await screen.findByLabelText('Expand rule reject-smtp'));

    await waitFor(() =>
      expect(screen.getByText('Metadata')).toBeInTheDocument()
    );
    // JSON.stringify renders the metadata keys
    expect(screen.getByText(/"owner": "security"/)).toBeInTheDocument();
    expect(screen.getByText(/"ticket": "SEC-42"/)).toBeInTheDocument();
  });

  it('does not render Metadata section when metadata is absent', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();

    fireEvent.click(await screen.findByLabelText('Expand rule allow-web'));

    await waitFor(() =>
      expect(screen.getByText('Source Selector')).toBeInTheDocument()
    );
    expect(screen.queryByText('Metadata')).not.toBeInTheDocument();
  });

  it('renders Last Compiled date in expanded row when last_compiled_at is set', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_DROP]));
    renderList();

    fireEvent.click(await screen.findByLabelText('Expand rule block-telnet'));

    await waitFor(() =>
      expect(screen.getByText('Last Compiled')).toBeInTheDocument()
    );
  });

  it('renders Created date in expanded row when created_at is set', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_DROP]));
    renderList();

    fireEvent.click(await screen.findByLabelText('Expand rule block-telnet'));

    await waitFor(() =>
      expect(screen.getByText('Created')).toBeInTheDocument()
    );
  });

  // ── Multiple rules expand independently ──────────────────────────────────

  it('can expand multiple rows independently', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT, RULE_DROP]));
    renderList();

    await waitFor(() =>
      expect(screen.getByLabelText('Expand rule allow-web')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByLabelText('Expand rule allow-web'));
    fireEvent.click(screen.getByLabelText('Expand rule block-telnet'));

    await waitFor(() => {
      // Both should show their detail labels — two expanded rows produce two of each heading
      expect(screen.getAllByText('Enabled').length).toBe(2);
    });
  });

  // ── Edit / Delete callbacks ───────────────────────────────────────────────

  it('renders Edit button when onEdit prop is supplied', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    const onEdit = jest.fn();
    renderList({ onEdit });

    await waitFor(() =>
      expect(screen.getByLabelText('Edit rule allow-web')).toBeInTheDocument()
    );
  });

  it('does not render Edit button when onEdit prop is absent', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();

    await waitFor(() =>
      expect(screen.queryByLabelText('Edit rule allow-web')).not.toBeInTheDocument()
    );
  });

  it('calls onEdit with the correct rule when Edit is clicked', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    const onEdit = jest.fn();
    renderList({ onEdit });

    fireEvent.click(await screen.findByLabelText('Edit rule allow-web'));

    expect(onEdit).toHaveBeenCalledWith(RULE_ACCEPT);
  });

  it('renders Delete button when onDelete prop is supplied', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    const onDelete = jest.fn();
    renderList({ onDelete });

    await waitFor(() =>
      expect(screen.getByLabelText('Delete rule allow-web')).toBeInTheDocument()
    );
  });

  it('does not render Delete button when onDelete prop is absent', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();

    await waitFor(() =>
      expect(screen.queryByLabelText('Delete rule allow-web')).not.toBeInTheDocument()
    );
  });

  it('calls onDelete with the correct rule when Delete is clicked', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    const onDelete = jest.fn();
    renderList({ onDelete });

    fireEvent.click(await screen.findByLabelText('Delete rule allow-web'));

    expect(onDelete).toHaveBeenCalledWith(RULE_ACCEPT);
  });

  // ── refreshKey re-fetches ─────────────────────────────────────────────────

  it('re-fetches rules when refreshKey prop changes', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    const { rerender } = renderList({ refreshKey: 0 });

    await waitFor(() =>
      expect(mockGetFirewallRules).toHaveBeenCalledTimes(1)
    );

    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT, RULE_DROP]));

    rerender(
      <FirewallRuleList networkId="net-abc" refreshKey={1} />
    );

    await waitFor(() =>
      expect(mockGetFirewallRules).toHaveBeenCalledTimes(2)
    );
  });

  // ── Port range display ────────────────────────────────────────────────────

  it('renders "port N" for single-port range in match column', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_ACCEPT]));
    renderList();
    await waitFor(() =>
      expect(screen.getByText(/port 443/)).toBeInTheDocument()
    );
  });

  it('renders "ports N-M" for a multi-port range in match column', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_REJECT]));
    renderList();
    await waitFor(() =>
      expect(screen.getByText(/ports 25-587/)).toBeInTheDocument()
    );
  });

  it('renders expanded Port Range as "port N" for a single port', async () => {
    mockGetFirewallRules.mockResolvedValue(envelope([RULE_DROP]));
    renderList();

    fireEvent.click(await screen.findByLabelText('Expand rule block-telnet'));

    await waitFor(() =>
      expect(screen.getByText('Port Range')).toBeInTheDocument()
    );
    // describePortRange for {from:23, to:23} → "port 23"
    expect(screen.getAllByText(/port 23/).length).toBeGreaterThan(0);
  });

  it('renders "any port" in expanded Port Range when port_range is absent', async () => {
    const noPort: SdwanFirewallRule = {
      ...RULE_ACCEPT,
      id: 'rule-noport',
      name: 'no-port',
      port_range: null,
    };
    mockGetFirewallRules.mockResolvedValue(envelope([noPort]));
    renderList();

    fireEvent.click(await screen.findByLabelText('Expand rule no-port'));

    await waitFor(() =>
      expect(screen.getByText('any port')).toBeInTheDocument()
    );
  });

  // ── Tag selector ─────────────────────────────────────────────────────────

  it('renders tag selector as "tag <name> (deferred)" in match column', async () => {
    const tagRule: SdwanFirewallRule = {
      ...RULE_ACCEPT,
      id: 'rule-tag',
      name: 'tag-rule',
      src_selector: { tag: 'dmz' },
      dst_selector: undefined,
      port_range: null,
    };
    mockGetFirewallRules.mockResolvedValue(envelope([tagRule]));
    renderList();

    await waitFor(() =>
      expect(screen.getByText(/tag dmz \(deferred\)/)).toBeInTheDocument()
    );
  });
});
