import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ProviderDetailModal } from './ProviderDetailModal';

/**
 * Nested-modal stacking guard for the core-`Modal` migration (IMP-a354b985dbf3).
 *
 * `ProviderDetailModal` can carry six dialogs above it: the region,
 * instance-type, availability-zone and connection forms, plus the two delete
 * confirmations. The finding named two of them — `ConnectionFormModal` and
 * `RegionFormModal` — as the ones that stacked by hand at `z-[60]`.
 *
 * All are core `Modal`s now, and the core `Modal` registers Escape on
 * `document`: without the parent standing its handler down, one keypress closes
 * the child and the provider dialog underneath it.
 *
 * The child form modals are deliberately NOT mocked here. The sibling suite
 * mocks them, and a mocked child registers no Escape listener at all, so the
 * regression this file exists to catch cannot appear there.
 */

const mockGetProvider = jest.fn();
const mockGetProviderRegions = jest.fn();
const mockGetProviderConnections = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getProvider: (...args: unknown[]) => mockGetProvider(...args),
    getProviderRegions: (...args: unknown[]) => mockGetProviderRegions(...args),
    getProviderConnections: (...args: unknown[]) => mockGetProviderConnections(...args),
    deleteProviderRegion: jest.fn(),
    deleteProviderConnection: jest.fn(),
    testProviderConnection: jest.fn(),
    syncProviderConnectionCatalog: jest.fn(),
    getProviderInstanceTypesPage: jest.fn().mockResolvedValue({ instance_types: [], total: 0 }),
    deleteProviderInstanceType: jest.fn(),
    getProviderAvailabilityZonesPage: jest
      .fn()
      .mockResolvedValue({ availability_zones: [], total: 0 }),
    deleteProviderAvailabilityZone: jest.fn(),
    createProviderRegion: jest.fn(),
    updateProviderRegion: jest.fn(),
    createProviderConnection: jest.fn(),
    updateProviderConnection: jest.fn(),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => true }),
}));

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({ addNotification: jest.fn(), showNotification: jest.fn() }),
}));

jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label, id }: { label?: React.ReactNode; id?: string | null }) => (
    <span>{label ?? id}</span>
  ),
}));

const PROVIDER = {
  id: 'prov-1',
  name: 'My AWS Provider',
  description: 'Primary AWS account',
  provider_type: 'aws',
  enabled: true,
  public: false,
  config: { region: 'us-east-1' },
  capabilities: { spot: true },
  region_count: 1,
  connection_count: 1,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-03-01T00:00:00Z',
};

const REGION = {
  id: 'reg-a',
  name: 'us-east-1',
  description: 'US East Virginia',
  endpoint_url: 'https://ec2.us-east-1.amazonaws.com',
  region_code: 'use1',
  capabilities: {},
  provider_id: 'prov-1',
  provider_name: 'My AWS Provider',
  zone_count: 3,
  instance_type_count: 42,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CONNECTION = {
  id: 'conn-a',
  name: 'prod-creds',
  description: 'Production IAM credentials',
  endpoint_url: 'https://aws.example.com',
  config: {},
  provider_id: 'prov-1',
  provider_name: 'My AWS Provider',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const dialogs = () => Array.from(document.querySelectorAll('[role="dialog"]'));

async function renderLoaded(onClose: jest.Mock) {
  render(
    <BrowserRouter>
      <ProviderDetailModal providerId="prov-1" isOpen onClose={onClose} />
    </BrowserRouter>,
  );
  await waitFor(() =>
    expect(screen.getByRole('heading', { name: 'My AWS Provider' })).toBeInTheDocument(),
  );
}

async function openRegionForm(onClose: jest.Mock) {
  await renderLoaded(onClose);
  fireEvent.click(screen.getByRole('tab', { name: /regions/i }));
  fireEvent.click(await screen.findByText('Add Region'));
  await waitFor(() => expect(dialogs()).toHaveLength(2));
}

async function openConnectionForm(onClose: jest.Mock) {
  await renderLoaded(onClose);
  fireEvent.click(screen.getByRole('tab', { name: /connections/i }));
  fireEvent.click(await screen.findByText('Add Connection'));
  await waitFor(() => expect(dialogs()).toHaveLength(2));
}

async function openRegionDeleteConfirm(onClose: jest.Mock) {
  await renderLoaded(onClose);
  fireEvent.click(screen.getByRole('tab', { name: /regions/i }));
  fireEvent.click(await screen.findByTitle('Delete region'));
  await waitFor(() => expect(dialogs()).toHaveLength(2));
}

describe('ProviderDetailModal nested dialog stacking', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetProvider.mockResolvedValue(PROVIDER);
    mockGetProviderRegions.mockResolvedValue([REGION]);
    mockGetProviderConnections.mockResolvedValue([CONNECTION]);
  });

  describe('RegionFormModal', () => {
    it('renders after the provider dialog, so it paints on top', async () => {
      await openRegionForm(jest.fn());

      const open = dialogs();
      const inner = screen
        .getByRole('heading', { name: /add region/i })
        .closest('[role="dialog"]');
      expect(open[open.length - 1]).toBe(inner);
    });

    it('closes only the region form on a single Escape', async () => {
      const onClose = jest.fn();
      await openRegionForm(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });

      await waitFor(() => expect(dialogs()).toHaveLength(1));
      expect(onClose).not.toHaveBeenCalled();
    });

    it('closes the provider dialog on Escape once the region form is gone', async () => {
      const onClose = jest.fn();
      await openRegionForm(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });
      await waitFor(() => expect(dialogs()).toHaveLength(1));

      fireEvent.keyDown(document, { key: 'Escape' });
      expect(onClose).toHaveBeenCalledTimes(1);
    });
  });

  describe('ConnectionFormModal', () => {
    it('closes only the connection form on a single Escape', async () => {
      const onClose = jest.fn();
      await openConnectionForm(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });

      await waitFor(() => expect(dialogs()).toHaveLength(1));
      expect(onClose).not.toHaveBeenCalled();
    });
  });

  describe('region delete confirmation', () => {
    it('closes only the confirmation on a single Escape', async () => {
      const onClose = jest.fn();
      await openRegionDeleteConfirm(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });

      await waitFor(() => expect(dialogs()).toHaveLength(1));
      expect(onClose).not.toHaveBeenCalled();
    });
  });
});
