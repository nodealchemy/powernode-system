import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { VolumeDetailModal } from './VolumeDetailModal';
import type { SystemProviderVolume } from '@system/features/system/types/system.types';

/**
 * Nested-modal stacking guard for the core-`Modal` migration (IMP-a354b985dbf3).
 *
 * `VolumeDetailModal` raises TWO nested dialogs: its own snapshot form (which
 * used to stack by hand at `z-[60]`) and the shared confirmation used by the
 * detach action. Both are now core `Modal`s, and the core `Modal` registers its
 * Escape listener on `document` — so one keypress would close the nested dialog
 * AND the detail modal beneath it unless the parent stands its handler down.
 *
 * Two nested dialogs from different sources means the parent's guard is a
 * conjunction, and a guard that names only one of them still passes a test that
 * exercises only that one. Both paths are covered here for that reason.
 */

const mockGetVolume = jest.fn();
const mockGetVolumeSnapshots = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getVolume: (...args: unknown[]) => mockGetVolume(...args),
    detachVolume: jest.fn(),
    createVolumeSnapshot: jest.fn(),
    getVolumeSnapshots: (...args: unknown[]) => mockGetVolumeSnapshots(...args),
    restoreVolumeSnapshot: jest.fn(),
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
    <span data-testid="entity-link">{label ?? id}</span>
  ),
}));

const VOLUME_AVAILABLE: SystemProviderVolume = {
  id: 'vol-abc',
  name: 'my-volume',
  description: 'A test volume',
  size_gb: 100,
  status: 'available',
  volume_type: 'gp3',
  encrypted: false,
  config: {},
  provider_region_id: 'region-1',
  region_name: 'us-east-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const VOLUME_IN_USE: SystemProviderVolume = {
  ...VOLUME_AVAILABLE,
  id: 'vol-inuse',
  name: 'attached-vol',
  status: 'in-use',
  node_instance_id: 'inst-xyz',
  device_name: '/dev/xvdf',
  ...({ node_id: 'node-abc', instance_name: 'web-01' } as unknown as Partial<SystemProviderVolume>),
};

function renderModal(onClose: jest.Mock) {
  render(
    <BrowserRouter>
      <VolumeDetailModal volumeId="vol-abc" isOpen onClose={onClose} />
    </BrowserRouter>,
  );
}

const dialogs = () => Array.from(document.querySelectorAll('[role="dialog"]'));

async function openSnapshotForm(onClose: jest.Mock) {
  mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
  renderModal(onClose);

  const btn = await screen.findByRole('button', { name: /create snapshot/i });
  fireEvent.click(btn);
  await screen.findByRole('heading', { name: /create snapshot/i });
}

async function openDetachConfirm(onClose: jest.Mock) {
  mockGetVolume.mockResolvedValue(VOLUME_IN_USE);
  renderModal(onClose);

  const btn = await screen.findByRole('button', { name: /detach volume/i });
  fireEvent.click(btn);
  await waitFor(() => expect(dialogs()).toHaveLength(2));
}

describe('VolumeDetailModal nested dialog stacking', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetVolumeSnapshots.mockResolvedValue([]);
  });

  describe('snapshot form', () => {
    it('renders after the detail dialog, so it paints on top', async () => {
      await openSnapshotForm(jest.fn());

      const open = dialogs();
      expect(open).toHaveLength(2);
      const inner = screen
        .getByRole('heading', { name: /create snapshot/i })
        .closest('[role="dialog"]');
      expect(open[open.length - 1]).toBe(inner);
    });

    it('closes only the snapshot form on a single Escape', async () => {
      const onClose = jest.fn();
      await openSnapshotForm(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });

      await waitFor(() =>
        expect(
          screen.queryByRole('heading', { name: /create snapshot/i }),
        ).not.toBeInTheDocument(),
      );
      expect(onClose).not.toHaveBeenCalled();
      expect(dialogs()).toHaveLength(1);
    });

    it('closes the detail dialog on Escape once the snapshot form is gone', async () => {
      const onClose = jest.fn();
      await openSnapshotForm(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });
      await waitFor(() => expect(dialogs()).toHaveLength(1));

      fireEvent.keyDown(document, { key: 'Escape' });
      expect(onClose).toHaveBeenCalledTimes(1);
    });
  });

  describe('detach confirmation', () => {
    it('closes only the confirmation on a single Escape', async () => {
      const onClose = jest.fn();
      await openDetachConfirm(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });

      await waitFor(() => expect(dialogs()).toHaveLength(1));
      expect(onClose).not.toHaveBeenCalled();
    });
  });
});
