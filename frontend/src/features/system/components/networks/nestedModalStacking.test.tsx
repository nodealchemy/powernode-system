import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworkDetailModal } from './NetworkDetailModal';

/**
 * Nested-modal stacking guard for the core-`Modal` migration (IMP-a354b985dbf3).
 *
 * `NetworkDetailModal` renders `SubnetFormModal` on top of itself. Before the
 * migration the inner dialog stacked by hand with `z-[60]` over the outer's
 * `z-50` and neither handled Escape at all. The core `Modal` registers its
 * Escape listener on `document`, so BOTH dialogs would otherwise see the same
 * keypress and one Escape would tear down the whole stack — the parent must
 * suppress its own handler while a child is open.
 *
 * Deliberately does NOT mock `SubnetFormModal`: the sibling suite mocks it, and
 * a mocked child registers no listener, so the regression this file exists to
 * catch would be invisible there.
 */

const mockGetNetwork = jest.fn();
const mockGetNetworkSubnets = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getNetwork: (...args: unknown[]) => mockGetNetwork(...args),
    getNetworkSubnetsPage: (...args: unknown[]) => mockGetNetworkSubnets(...args),
    deleteNetworkSubnet: jest.fn(),
    getProviderConnections: jest.fn().mockResolvedValue([]),
    createNetworkSubnet: jest.fn(),
    updateNetworkSubnet: jest.fn(),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => true }),
}));

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({ addNotification: jest.fn(), showNotification: jest.fn() }),
}));

const NETWORK = {
  id: 'net-aaa',
  name: 'production-vpc',
  description: 'Main production VPC',
  cidr_block: '10.0.0.0/16',
  status: 'available',
  is_default: false,
  dns_support: true,
  dns_hostnames: true,
  config: {},
  provider_region_id: 'region-1',
  provider_region_name: 'us-east-1',
  created_at: '2026-05-30T12:00:00Z',
  updated_at: '2026-05-30T12:00:00Z',
};

async function openSubnetForm(onClose: jest.Mock) {
  render(
    <BrowserRouter>
      <NetworkDetailModal networkId="net-aaa" isOpen onClose={onClose} />
    </BrowserRouter>,
  );

  await waitFor(() => expect(screen.getByText('production-vpc')).toBeInTheDocument());
  fireEvent.click(await screen.findByText('Add Subnet'));
  await screen.findByRole('heading', { name: /add subnet/i });
}

describe('NetworkDetailModal + SubnetFormModal stacking', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetNetwork.mockResolvedValue(NETWORK);
    mockGetNetworkSubnets.mockResolvedValue({ subnets: [], total: 0 });
  });

  it('renders the inner dialog after the outer one, so it paints on top', async () => {
    await openSubnetForm(jest.fn());

    const dialogs = Array.from(document.querySelectorAll('[role="dialog"]'));
    expect(dialogs).toHaveLength(2);

    // Both portals share the core Modal's z-index, so paint order is DOM
    // order: the child must come last.
    const inner = screen.getByRole('heading', { name: /add subnet/i }).closest('[role="dialog"]');
    expect(dialogs[dialogs.length - 1]).toBe(inner);
  });

  it('closes only the inner dialog on a single Escape', async () => {
    const onClose = jest.fn();
    await openSubnetForm(onClose);

    fireEvent.keyDown(document, { key: 'Escape' });

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /add subnet/i })).not.toBeInTheDocument(),
    );
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByText('production-vpc')).toBeInTheDocument();
  });

  it('closes the outer dialog on Escape once the inner one is gone', async () => {
    const onClose = jest.fn();
    await openSubnetForm(onClose);

    fireEvent.keyDown(document, { key: 'Escape' });
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /add subnet/i })).not.toBeInTheDocument(),
    );

    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
