import React from 'react';
import { render, screen, within } from '@testing-library/react';
import {
  PeerTable,
  PeerUrlCell,
  PeerStatusCell,
  PeerHeartbeatCell,
} from './PeerTable';
import type { PlatformPeerSummary } from '../../types/peer.types';

// =============================================================================
// Mocks
//
// PeerTable.tsx and its sub-components are pure presentational — no API calls,
// no state, no hooks. The only child that needs a mock is PeerStatusPill, which
// is imported by PeerStatusCell. We let the real PeerStatusPill render because
// it too is purely presentational and adds meaningful assertions (status label).
// =============================================================================

// PeerTable, PeerUrlCell, PeerStatusCell, PeerHeartbeatCell compose without
// hooks — no apiClient / permission / notification mocks are needed.

// =============================================================================
// Fixtures
// =============================================================================

const PEER_ACTIVE: PlatformPeerSummary = {
  id: 'peer-active-1',
  remote_instance_url: 'https://active.example.com',
  remote_instance_id: 'rid-001',
  peer_kind: 'platform',
  spawn_role: 'symmetric',
  spawn_mode: 'out_of_band',
  status: 'active',
  created_at: '2026-01-01T00:00:00Z',
  last_heartbeat_at: '2026-05-01T12:00:00Z',
  last_handshake_at: '2026-05-01T12:00:00Z',
  endpoints_count: 2,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

const PEER_NO_HEARTBEAT: PlatformPeerSummary = {
  ...PEER_ACTIVE,
  id: 'peer-no-hb',
  remote_instance_url: 'https://no-hb.example.com',
  last_heartbeat_at: null,
  status: 'degraded',
};

const PEER_STALE: PlatformPeerSummary = {
  ...PEER_ACTIVE,
  id: 'peer-stale',
  remote_instance_url: 'https://stale.example.com',
  status: 'enrolled',
  // Use an absolute timestamp so the formatted output is deterministic
  last_heartbeat_at: '2025-12-31T08:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

/**
 * Render a minimal <table><tbody><tr> wrapper around the cell component so
 * <td> elements are valid HTML (required by jsdom's table parsing).
 */
function renderRow(ui: React.ReactNode) {
  return render(
    <table>
      <tbody>
        <tr>{ui}</tr>
      </tbody>
    </table>,
  );
}

// =============================================================================
// PeerTable
// =============================================================================

describe('PeerTable', () => {
  describe('column headers', () => {
    it('renders a <table> element', () => {
      const { container } = render(
        <PeerTable columns={[{ label: 'Remote URL' }]}>
          <tr>
            <td>row</td>
          </tr>
        </PeerTable>,
      );
      expect(container.querySelector('table')).toBeInTheDocument();
    });

    it('renders every column label as a <th>', () => {
      const columns = [
        { label: 'Remote URL' },
        { label: 'Status' },
        { label: 'Last Heartbeat', align: 'right' as const },
      ];
      render(
        <PeerTable columns={columns}>
          <tr>
            <td colSpan={3} />
          </tr>
        </PeerTable>,
      );
      expect(screen.getByText('Remote URL')).toBeInTheDocument();
      expect(screen.getByText('Status')).toBeInTheDocument();
      expect(screen.getByText('Last Heartbeat')).toBeInTheDocument();
    });

    it('applies text-left to a header with no align prop', () => {
      render(
        <PeerTable columns={[{ label: 'Remote URL' }]}>
          <tr>
            <td />
          </tr>
        </PeerTable>,
      );
      const th = screen.getByText('Remote URL');
      expect(th).toHaveClass('text-left');
    });

    it('applies text-right to a header with align="right"', () => {
      render(
        <PeerTable columns={[{ label: 'Actions', align: 'right' }]}>
          <tr>
            <td />
          </tr>
        </PeerTable>,
      );
      const th = screen.getByText('Actions');
      expect(th).toHaveClass('text-right');
      expect(th).not.toHaveClass('text-left');
    });

    it('applies text-left when align="left" is explicit', () => {
      render(
        <PeerTable columns={[{ label: 'Mode', align: 'left' }]}>
          <tr>
            <td />
          </tr>
        </PeerTable>,
      );
      expect(screen.getByText('Mode')).toHaveClass('text-left');
    });

    it('renders as many <th> elements as columns provided', () => {
      const columns = [
        { label: 'A' },
        { label: 'B' },
        { label: 'C' },
        { label: 'D' },
      ];
      const { container } = render(
        <PeerTable columns={columns}>
          <tr>
            <td colSpan={4} />
          </tr>
        </PeerTable>,
      );
      expect(container.querySelectorAll('th')).toHaveLength(4);
    });

    it('renders an empty table with no columns', () => {
      const { container } = render(
        <PeerTable columns={[]}>
          <tr />
        </PeerTable>,
      );
      expect(container.querySelectorAll('th')).toHaveLength(0);
    });

    it('renders the thead with background and uppercase classes', () => {
      const { container } = render(
        <PeerTable columns={[{ label: 'X' }]}>
          <tr>
            <td />
          </tr>
        </PeerTable>,
      );
      const thead = container.querySelector('thead');
      expect(thead).toHaveClass('bg-theme-background-secondary');
      expect(thead).toHaveClass('uppercase');
    });
  });

  describe('children / body', () => {
    it('renders children inside <tbody>', () => {
      render(
        <PeerTable columns={[{ label: 'Col' }]}>
          <tr data-testid="test-row">
            <td>cell content</td>
          </tr>
        </PeerTable>,
      );
      const row = screen.getByTestId('test-row');
      expect(row).toBeInTheDocument();
      expect(row.closest('tbody')).toBeInTheDocument();
    });

    it('renders multiple children rows', () => {
      render(
        <PeerTable columns={[{ label: 'Col' }]}>
          <tr data-testid="row-1">
            <td>first</td>
          </tr>
          <tr data-testid="row-2">
            <td>second</td>
          </tr>
        </PeerTable>,
      );
      expect(screen.getByTestId('row-1')).toBeInTheDocument();
      expect(screen.getByTestId('row-2')).toBeInTheDocument();
    });

    it('renders a full table layout: table → thead/tbody → tr/th/td', () => {
      const { container } = render(
        <PeerTable columns={[{ label: 'Col' }]}>
          <tr>
            <td>body cell</td>
          </tr>
        </PeerTable>,
      );
      expect(container.querySelector('table thead tr th')).toBeInTheDocument();
      expect(container.querySelector('table tbody tr td')).toBeInTheDocument();
    });
  });
});

// =============================================================================
// PeerUrlCell
// =============================================================================

describe('PeerUrlCell', () => {
  describe('default (live=false)', () => {
    it('renders the remote_instance_url as text', () => {
      renderRow(<PeerUrlCell peer={PEER_ACTIVE} />);
      expect(screen.getByText('https://active.example.com')).toBeInTheDocument();
    });

    it('renders inside a <td> element', () => {
      renderRow(<PeerUrlCell peer={PEER_ACTIVE} />);
      const td = screen.getByText('https://active.example.com').closest('td');
      expect(td).toBeInTheDocument();
    });

    it('applies font-mono and text-xs to the <td>', () => {
      renderRow(<PeerUrlCell peer={PEER_ACTIVE} />);
      const td = screen.getByText('https://active.example.com').closest('td');
      expect(td).toHaveClass('font-mono', 'text-xs');
    });

    it('does not render the live pulse dot when live is false', () => {
      renderRow(<PeerUrlCell peer={PEER_ACTIVE} live={false} />);
      expect(
        screen.queryByTitle('Live event received this session'),
      ).not.toBeInTheDocument();
    });

    it('does not render the live pulse dot when live prop is omitted', () => {
      renderRow(<PeerUrlCell peer={PEER_ACTIVE} />);
      expect(
        screen.queryByTitle('Live event received this session'),
      ).not.toBeInTheDocument();
    });
  });

  describe('live=true', () => {
    it('renders the pulse dot with the correct title', () => {
      renderRow(<PeerUrlCell peer={PEER_ACTIVE} live />);
      expect(
        screen.getByTitle('Live event received this session'),
      ).toBeInTheDocument();
    });

    it('still renders the remote_instance_url alongside the pulse dot', () => {
      renderRow(<PeerUrlCell peer={PEER_ACTIVE} live />);
      expect(screen.getByText('https://active.example.com')).toBeInTheDocument();
    });

    it('applies animate-pulse class to the pulse dot', () => {
      renderRow(<PeerUrlCell peer={PEER_ACTIVE} live />);
      const dot = screen.getByTitle('Live event received this session');
      expect(dot).toHaveClass('animate-pulse');
    });

    it('applies the success background class to the pulse dot', () => {
      renderRow(<PeerUrlCell peer={PEER_ACTIVE} live />);
      const dot = screen.getByTitle('Live event received this session');
      expect(dot).toHaveClass('bg-theme-success-solid');
    });

    it('renders the URL and dot inside an inline-flex wrapper when live', () => {
      renderRow(<PeerUrlCell peer={PEER_ACTIVE} live />);
      const dot = screen.getByTitle('Live event received this session');
      // The dot <span> is nested inside the outer wrapper <span>.
      const wrapper = dot.parentElement;
      expect(wrapper).toHaveClass('inline-flex', 'items-center', 'gap-2');
    });
  });
});

// =============================================================================
// PeerStatusCell
// =============================================================================

describe('PeerStatusCell', () => {
  it('renders inside a <td> element', () => {
    const { container } = renderRow(<PeerStatusCell peer={PEER_ACTIVE} />);
    expect(container.querySelector('td')).toBeInTheDocument();
  });

  it('renders the PeerStatusPill with the peer status label', () => {
    renderRow(<PeerStatusCell peer={PEER_ACTIVE} />);
    // PeerStatusPill renders the status string as text
    expect(screen.getByText('active')).toBeInTheDocument();
  });

  it('renders "degraded" status via PeerStatusPill', () => {
    renderRow(<PeerStatusCell peer={PEER_NO_HEARTBEAT} />);
    expect(screen.getByText('degraded')).toBeInTheDocument();
  });

  it('renders "enrolled" status via PeerStatusPill', () => {
    renderRow(<PeerStatusCell peer={PEER_STALE} />);
    expect(screen.getByText('enrolled')).toBeInTheDocument();
  });

  it('renders status text inside a span with the pill classes', () => {
    renderRow(<PeerStatusCell peer={PEER_ACTIVE} />);
    const pill = screen.getByText('active');
    // PeerStatusPill always applies these structural classes
    expect(pill).toHaveClass('inline-block', 'px-2', 'rounded', 'text-xs', 'font-medium');
  });

  it('applies the success theme class for active status', () => {
    renderRow(<PeerStatusCell peer={PEER_ACTIVE} />);
    const pill = screen.getByText('active');
    expect(pill).toHaveClass('bg-theme-success');
  });

  it('applies the danger theme class for revoked status', () => {
    const revokedPeer: PlatformPeerSummary = { ...PEER_ACTIVE, status: 'revoked' };
    renderRow(<PeerStatusCell peer={revokedPeer} />);
    const pill = screen.getByText('revoked');
    expect(pill).toHaveClass('bg-theme-danger');
  });
});

// =============================================================================
// PeerHeartbeatCell
// =============================================================================

describe('PeerHeartbeatCell', () => {
  describe('with last_heartbeat_at present', () => {
    it('renders inside a <td>', () => {
      const { container } = renderRow(<PeerHeartbeatCell peer={PEER_ACTIVE} />);
      expect(container.querySelector('td')).toBeInTheDocument();
    });

    it('renders the formatted heartbeat timestamp', () => {
      renderRow(<PeerHeartbeatCell peer={PEER_ACTIVE} />);
      // The component calls new Date(last_heartbeat_at).toLocaleString() —
      // verify the formatted date string appears somewhere in the cell text.
      const expected = new Date('2026-05-01T12:00:00Z').toLocaleString();
      expect(screen.getByText(expected)).toBeInTheDocument();
    });

    it('renders a Clock icon (svg) in the timestamp wrapper', () => {
      const { container } = renderRow(<PeerHeartbeatCell peer={PEER_ACTIVE} />);
      // lucide-react Clock renders as <svg>
      expect(container.querySelector('svg')).toBeInTheDocument();
    });

    it('does not render "never" when a heartbeat timestamp exists', () => {
      renderRow(<PeerHeartbeatCell peer={PEER_ACTIVE} />);
      expect(screen.queryByText('never')).not.toBeInTheDocument();
    });

    it('does not render "stale" label when stale is false (default)', () => {
      renderRow(<PeerHeartbeatCell peer={PEER_ACTIVE} />);
      expect(screen.queryByText('stale')).not.toBeInTheDocument();
    });

    it('applies text-theme-secondary class when stale is false', () => {
      renderRow(<PeerHeartbeatCell peer={PEER_ACTIVE} />);
      const ts = screen.getByText(new Date('2026-05-01T12:00:00Z').toLocaleString());
      const wrapper = ts.closest('span');
      expect(wrapper).toHaveClass('text-theme-secondary');
      expect(wrapper).not.toHaveClass('text-theme-warning');
    });
  });

  describe('stale=true', () => {
    it('renders the "stale" suffix label', () => {
      renderRow(<PeerHeartbeatCell peer={PEER_STALE} stale />);
      expect(screen.getByText('stale')).toBeInTheDocument();
    });

    it('applies text-theme-warning class when stale is true', () => {
      renderRow(<PeerHeartbeatCell peer={PEER_STALE} stale />);
      const ts = screen.getByText(new Date('2025-12-31T08:00:00Z').toLocaleString());
      const wrapper = ts.closest('span');
      expect(wrapper).toHaveClass('text-theme-warning');
      expect(wrapper).not.toHaveClass('text-theme-secondary');
    });

    it('renders the "stale" span with font-medium', () => {
      renderRow(<PeerHeartbeatCell peer={PEER_STALE} stale />);
      const staleSpan = screen.getByText('stale');
      expect(staleSpan).toHaveClass('font-medium');
    });

    it('still renders the formatted timestamp alongside the stale label', () => {
      renderRow(<PeerHeartbeatCell peer={PEER_STALE} stale />);
      const expected = new Date('2025-12-31T08:00:00Z').toLocaleString();
      expect(screen.getByText(expected)).toBeInTheDocument();
    });

    it('still renders the Clock icon when stale', () => {
      const { container } = renderRow(<PeerHeartbeatCell peer={PEER_STALE} stale />);
      expect(container.querySelector('svg')).toBeInTheDocument();
    });
  });

  describe('no last_heartbeat_at', () => {
    it('renders "never" text', () => {
      renderRow(<PeerHeartbeatCell peer={PEER_NO_HEARTBEAT} />);
      expect(screen.getByText('never')).toBeInTheDocument();
    });

    it('applies text-theme-tertiary to the "never" span', () => {
      renderRow(<PeerHeartbeatCell peer={PEER_NO_HEARTBEAT} />);
      const neverSpan = screen.getByText('never');
      expect(neverSpan).toHaveClass('text-theme-tertiary');
    });

    it('does not render the Clock icon when there is no heartbeat', () => {
      const { container } = renderRow(<PeerHeartbeatCell peer={PEER_NO_HEARTBEAT} />);
      expect(container.querySelector('svg')).not.toBeInTheDocument();
    });

    it('does not render "stale" even when stale=true and heartbeat is null', () => {
      // When last_heartbeat_at is null the component renders "never" branch —
      // the stale span only appears inside the non-null branch.
      renderRow(<PeerHeartbeatCell peer={PEER_NO_HEARTBEAT} stale />);
      expect(screen.queryByText('stale')).not.toBeInTheDocument();
      expect(screen.getByText('never')).toBeInTheDocument();
    });
  });

  describe('structural classes on the <td>', () => {
    it('always applies px-4 and py-3 to the outer <td>', () => {
      const { container } = renderRow(<PeerHeartbeatCell peer={PEER_ACTIVE} />);
      const td = container.querySelector('td');
      expect(td).toHaveClass('px-4', 'py-3', 'text-xs');
    });
  });
});

// =============================================================================
// Integration — PeerTable composed with cell sub-components
// =============================================================================

describe('PeerTable composed with sub-components', () => {
  const columns = [
    { label: 'Remote URL' },
    { label: 'Status' },
    { label: 'Last Heartbeat', align: 'right' as const },
  ];

  function renderComposedTable(peer: PlatformPeerSummary) {
    return render(
      <PeerTable columns={columns}>
        <tr data-testid={`peer-row-${peer.id}`}>
          <PeerUrlCell peer={peer} />
          <PeerStatusCell peer={peer} />
          <PeerHeartbeatCell peer={peer} />
        </tr>
      </PeerTable>,
    );
  }

  it('renders all column headers', () => {
    renderComposedTable(PEER_ACTIVE);
    expect(screen.getByText('Remote URL')).toBeInTheDocument();
    expect(screen.getByText('Status')).toBeInTheDocument();
    expect(screen.getByText('Last Heartbeat')).toBeInTheDocument();
  });

  it('renders a row with the correct testid', () => {
    renderComposedTable(PEER_ACTIVE);
    expect(screen.getByTestId('peer-row-peer-active-1')).toBeInTheDocument();
  });

  it('renders the URL, status, and timestamp in the row', () => {
    renderComposedTable(PEER_ACTIVE);
    const row = screen.getByTestId('peer-row-peer-active-1');
    expect(within(row).getByText('https://active.example.com')).toBeInTheDocument();
    expect(within(row).getByText('active')).toBeInTheDocument();
    expect(
      within(row).getByText(new Date('2026-05-01T12:00:00Z').toLocaleString()),
    ).toBeInTheDocument();
  });

  it('renders "never" for a peer with no heartbeat', () => {
    renderComposedTable(PEER_NO_HEARTBEAT);
    const row = screen.getByTestId('peer-row-peer-no-hb');
    expect(within(row).getByText('never')).toBeInTheDocument();
  });

  it('renders the Last Heartbeat header right-aligned', () => {
    renderComposedTable(PEER_ACTIVE);
    const th = screen.getByText('Last Heartbeat');
    expect(th).toHaveClass('text-right');
  });

  it('renders multiple peer rows inside a single PeerTable', () => {
    render(
      <PeerTable columns={columns}>
        <tr data-testid="row-active">
          <PeerUrlCell peer={PEER_ACTIVE} />
          <PeerStatusCell peer={PEER_ACTIVE} />
          <PeerHeartbeatCell peer={PEER_ACTIVE} />
        </tr>
        <tr data-testid="row-no-hb">
          <PeerUrlCell peer={PEER_NO_HEARTBEAT} />
          <PeerStatusCell peer={PEER_NO_HEARTBEAT} />
          <PeerHeartbeatCell peer={PEER_NO_HEARTBEAT} />
        </tr>
      </PeerTable>,
    );
    expect(screen.getByTestId('row-active')).toBeInTheDocument();
    expect(screen.getByTestId('row-no-hb')).toBeInTheDocument();
    expect(screen.getByText('https://active.example.com')).toBeInTheDocument();
    expect(screen.getByText('https://no-hb.example.com')).toBeInTheDocument();
  });
});
