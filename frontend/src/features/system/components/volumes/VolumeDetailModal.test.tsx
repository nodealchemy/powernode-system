import React from 'react';
import { render, screen, fireEvent, waitFor, within, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { VolumeDetailModal } from './VolumeDetailModal';
import type { SystemProviderVolume } from '@system/features/system/types/system.types';
import { VolumeRestoreError } from '@system/features/system/services/api/volumesApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGetVolume = jest.fn();
const mockDetachVolume = jest.fn();
const mockCreateVolumeSnapshot = jest.fn();
const mockGetVolumeSnapshots = jest.fn();
const mockRestoreVolumeSnapshot = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getVolume: (...args: unknown[]) => mockGetVolume(...args),
    detachVolume: (...args: unknown[]) => mockDetachVolume(...args),
    createVolumeSnapshot: (...args: unknown[]) => mockCreateVolumeSnapshot(...args),
    getVolumeSnapshots: (...args: unknown[]) => mockGetVolumeSnapshots(...args),
    restoreVolumeSnapshot: (...args: unknown[]) => mockRestoreVolumeSnapshot(...args),
  },
}));

const mockHasPermission = jest.fn().mockReturnValue(true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (...args: unknown[]) => mockHasPermission(...args),
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// EntityLink uses entityRegistry + useEntityModal + usePermissions internally.
// Mock it as a plain span to avoid those side-effects.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label, id }: { label?: React.ReactNode; id?: string | null }) => (
    <span data-testid="entity-link">{label ?? id}</span>
  ),
}));

// =============================================================================
// Fixtures
// =============================================================================

/** Double-envelope helper — mirrors AxiosResponse whose body is { success, data, meta? }. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

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
  // Extra extension fields used by VolumeWithAttachment
  // (cast to unknown to avoid TS type error on the test fixture)
  ...({ node_id: 'node-abc', instance_name: 'web-01' } as unknown as Partial<SystemProviderVolume>),
};

const VOLUME_ENCRYPTED: SystemProviderVolume = {
  ...VOLUME_AVAILABLE,
  id: 'vol-enc',
  name: 'encrypted-vol',
  encrypted: true,
};

const VOLUME_IOPS: SystemProviderVolume = {
  ...VOLUME_AVAILABLE,
  id: 'vol-iops',
  name: 'iops-vol',
  volume_type: 'io1',
  iops: 3000,
  throughput: 125,
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderOpts {
  volumeId?: string | null;
  isOpen?: boolean;
  onClose?: () => void;
  onVolumeUpdated?: () => void;
  onEdit?: (v: SystemProviderVolume) => void;
}

function renderModal(opts: RenderOpts = {}) {
  const {
    volumeId = 'vol-abc',
    isOpen = true,
    onClose = jest.fn(),
    onVolumeUpdated = jest.fn(),
  } = opts;

  // onEdit intentionally not defaulted — pass undefined to omit from props
  const onEdit = 'onEdit' in opts ? opts.onEdit : jest.fn();

  return render(
    <BrowserRouter>
      <VolumeDetailModal
        volumeId={volumeId}
        isOpen={isOpen}
        onClose={onClose}
        onVolumeUpdated={onVolumeUpdated}
        onEdit={onEdit}
      />
    </BrowserRouter>
  );
}

// =============================================================================
// Tests
// =============================================================================

// The detail modal is itself a core `Modal` now, so role="dialog" matches both
// it and any nested dialog. The nested one portals last, so it is the final
// match; `noNestedDialog` asserts we are back to just the detail modal.
async function findNestedDialog() {
  return waitFor(() => {
    const dialogs = screen.getAllByRole('dialog');
    if (dialogs.length < 2) throw new Error('nested dialog not open');
    return dialogs[dialogs.length - 1];
  });
}

async function expectNoNestedDialog() {
  await waitFor(() => expect(screen.getAllByRole('dialog')).toHaveLength(1));
}

describe('VolumeDetailModal', () => {
  beforeEach(() => {
    mockGetVolume.mockReset();
    mockDetachVolume.mockReset();
    mockGetVolumeSnapshots.mockReset();
    mockGetVolumeSnapshots.mockResolvedValue({
      snapshots: [],
      meta: { current_page: 1, per_page: 10, total_count: 0, total_pages: 1, next_page: null, prev_page: null },
    });
    mockRestoreVolumeSnapshot.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
    mockCreateVolumeSnapshot.mockReset();
    mockAddNotification.mockReset();
  });

  // -------------------------------------------------------------------------
  // Visibility / render gate
  // -------------------------------------------------------------------------

  describe('visibility', () => {
    it('renders nothing when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(screen.queryByText(/loading/i)).not.toBeInTheDocument();
      expect(screen.queryByText(/volume details/i)).not.toBeInTheDocument();
    });

    it('renders immediately when isOpen is true (shows loading state first)', () => {
      // Never resolves — we check the loading state
      mockGetVolume.mockImplementation(() => new Promise(() => { /* never */ }));
      renderModal();
      expect(screen.getByText('Loading...')).toBeInTheDocument();
    });

    it('renders nothing when volumeId is null even if isOpen is true', () => {
      // With null volumeId the useEffect guard returns early — loading stays
      // true forever (initial state). We test that the close button is visible
      // (modal frame is rendered) but getVolume was never called.
      mockGetVolume.mockImplementation(() => new Promise(() => { /* never */ }));
      renderModal({ volumeId: null });
      // Modal frame should still be visible (no early-return on null volumeId
      // for the outer modal shell)
      expect(mockGetVolume).not.toHaveBeenCalled();
    });
  });

  // -------------------------------------------------------------------------
  // Loading state
  // -------------------------------------------------------------------------

  describe('loading state', () => {
    it('shows "Loading..." header text while fetching', () => {
      mockGetVolume.mockImplementation(() => new Promise(() => { /* never */ }));
      renderModal();
      expect(screen.getByText('Loading...')).toBeInTheDocument();
    });

    it('calls systemApi.getVolume with the correct volume id', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal({ volumeId: 'vol-abc' });

      await waitFor(() => expect(mockGetVolume).toHaveBeenCalledWith('vol-abc'));
    });
  });

  // -------------------------------------------------------------------------
  // Success / detail rendering
  // -------------------------------------------------------------------------

  describe('detail rendering', () => {
    it('renders volume name in header after loading', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      await waitFor(() => expect(screen.getByText('my-volume')).toBeInTheDocument());
    });

    it('renders size in GB for volumes under 1 TB', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      await waitFor(() => expect(screen.getByText('100.0 GB')).toBeInTheDocument());
    });

    it('renders size in TB for volumes >= 1024 GB', async () => {
      mockGetVolume.mockResolvedValue({ ...VOLUME_AVAILABLE, size_gb: 2048 });
      renderModal();

      await waitFor(() => expect(screen.getByText('2.0 TB')).toBeInTheDocument());
    });

    it('renders the friendly label for known volume types', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE); // volume_type: 'gp3'
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('General Purpose SSD (gp3)')).toBeInTheDocument()
      );
    });

    it('renders the raw volume type when not in the label map', async () => {
      mockGetVolume.mockResolvedValue({ ...VOLUME_AVAILABLE, volume_type: 'custom-type' });
      renderModal();

      await waitFor(() => expect(screen.getByText('custom-type')).toBeInTheDocument());
    });

    it('renders region name when present', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      await waitFor(() => expect(screen.getByText('us-east-1')).toBeInTheDocument());
    });

    it('renders "—" when neither region_name nor provider_region_id is set', async () => {
      mockGetVolume.mockResolvedValue({
        ...VOLUME_AVAILABLE,
        region_name: undefined,
        provider_region_id: '',
      } as SystemProviderVolume);
      renderModal();

      await waitFor(() => expect(screen.getByText('—')).toBeInTheDocument());
    });

    it('renders IOPS and Throughput fields when present', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_IOPS);
      renderModal();

      await waitFor(() => {
        expect(screen.getByText('3,000')).toBeInTheDocument(); // IOPS with toLocaleString
        expect(screen.getByText('125 MB/s')).toBeInTheDocument();
      });
    });

    it('does not render IOPS or Throughput labels when absent', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      await waitFor(() => expect(screen.getByText('my-volume')).toBeInTheDocument());
      expect(screen.queryByText(/iops/i)).not.toBeInTheDocument();
      expect(screen.queryByText(/throughput/i)).not.toBeInTheDocument();
    });

    it('renders description when volume has one', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      await waitFor(() => expect(screen.getByText('A test volume')).toBeInTheDocument());
    });

    it('does not render description section when volume has none', async () => {
      mockGetVolume.mockResolvedValue({ ...VOLUME_AVAILABLE, description: undefined });
      renderModal();

      await waitFor(() => expect(screen.getByText('my-volume')).toBeInTheDocument());
      // The description label is only rendered when the field is present
      const labels = screen.queryAllByText('Description');
      expect(labels.length).toBe(0);
    });

    it('renders the status badge for available volumes', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      await waitFor(() => expect(screen.getByText('available')).toBeInTheDocument());
    });

    it('renders the Encrypted badge for encrypted volumes', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_ENCRYPTED);
      renderModal();

      await waitFor(() => expect(screen.getByText('Encrypted')).toBeInTheDocument());
    });

    it('does not render Encrypted badge for unencrypted volumes', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE); // encrypted: false
      renderModal();

      await waitFor(() => expect(screen.getByText('my-volume')).toBeInTheDocument());
      expect(screen.queryByText('Encrypted')).not.toBeInTheDocument();
    });

    it('renders formatted created_at and updated_at timestamps', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      // Check the "Created:" label exists alongside a formatted date
      await waitFor(() => expect(screen.getByText(/created:/i)).toBeInTheDocument());
      expect(screen.getByText(/updated:/i)).toBeInTheDocument();
    });
  });

  // -------------------------------------------------------------------------
  // Attachment rendering
  // -------------------------------------------------------------------------

  describe('attachment rendering', () => {
    it('renders "Not attached" when volume has no node_instance_id', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      await waitFor(() => expect(screen.getByText('Not attached')).toBeInTheDocument());
    });

    it('renders EntityLink when volume has both node_id and node_instance_id', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_IN_USE);
      renderModal();

      await waitFor(() => expect(screen.getByTestId('entity-link')).toBeInTheDocument());
      // EntityLink receives label=instance_name ('web-01')
      expect(screen.getByTestId('entity-link')).toHaveTextContent('web-01');
    });

    it('renders plain span with instance_name when node_id is absent', async () => {
      const noNodeId: SystemProviderVolume = {
        ...VOLUME_IN_USE,
        ...({ node_id: undefined } as unknown as Partial<SystemProviderVolume>),
      };
      mockGetVolume.mockResolvedValue(noNodeId);
      renderModal();

      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());
      // EntityLink should NOT be rendered when node_id is absent
      expect(screen.queryByTestId('entity-link')).not.toBeInTheDocument();
    });

    it('renders device_name in parentheses next to attachment', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_IN_USE);
      renderModal();

      await waitFor(() => expect(screen.getByText('(/dev/xvdf)')).toBeInTheDocument());
    });
  });

  // -------------------------------------------------------------------------
  // Error state (failed to load volume)
  // -------------------------------------------------------------------------

  describe('error state', () => {
    it('shows error notification when getVolume rejects', async () => {
      mockGetVolume.mockRejectedValue(new Error('Not found'));
      renderModal();

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to load volume details',
        })
      );
    });

    it('shows "Volume not found" when volume is null after failed fetch', async () => {
      mockGetVolume.mockRejectedValue(new Error('Not found'));
      renderModal();

      await waitFor(() => expect(screen.getByText('Volume not found')).toBeInTheDocument());
    });
  });

  // -------------------------------------------------------------------------
  // Actions visibility (permission + status gating)
  // -------------------------------------------------------------------------

  describe('action button visibility', () => {
    it('renders "Detach Volume" button for in-use volumes with node_instance_id', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_IN_USE);
      renderModal();

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /detach volume/i })).toBeInTheDocument()
      );
    });

    it('does not render "Detach Volume" for available volumes', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      await waitFor(() => expect(screen.getByText('my-volume')).toBeInTheDocument());
      expect(screen.queryByRole('button', { name: /detach volume/i })).not.toBeInTheDocument();
    });

    it('does not render "Detach Volume" for in-use volumes without node_instance_id', async () => {
      mockGetVolume.mockResolvedValue({ ...VOLUME_IN_USE, node_instance_id: undefined });
      renderModal();

      await waitFor(() => expect(screen.getByText('attached-vol')).toBeInTheDocument());
      expect(screen.queryByRole('button', { name: /detach volume/i })).not.toBeInTheDocument();
    });

    it('renders "Create Snapshot" button when user has snapshot permission', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /create snapshot/i })).toBeInTheDocument()
      );
    });

    it('hides "Create Snapshot" button when user lacks snapshot permission', async () => {
      // Override the usePermissions mock for this single test: deny snapshot, allow update
      const permMock = require('@/shared/hooks/usePermissions');
      const origImpl = permMock.usePermissions;
      permMock.usePermissions = () => ({
        hasPermission: (p: string) => p !== 'system.volumes.snapshot',
      });

      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);

      render(
        <BrowserRouter>
          <VolumeDetailModal
            volumeId="vol-abc"
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>
      );

      await waitFor(() => expect(screen.getByText('my-volume')).toBeInTheDocument());
      expect(screen.queryByRole('button', { name: /create snapshot/i })).not.toBeInTheDocument();

      // Restore original
      permMock.usePermissions = origImpl;
    });

    it('renders "Edit Volume" button in footer when canUpdate=true, onEdit provided, volume loaded', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      const onEdit = jest.fn();
      renderModal({ onEdit });

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /edit volume/i })).toBeInTheDocument()
      );
    });

    it('does not render "Edit Volume" button when onEdit is not provided', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal({ onEdit: undefined });

      await waitFor(() => expect(screen.getByText('my-volume')).toBeInTheDocument());
      expect(screen.queryByRole('button', { name: /edit volume/i })).not.toBeInTheDocument();
    });

    it('hides action buttons for volumes with status "deleted"', async () => {
      mockGetVolume.mockResolvedValue({ ...VOLUME_AVAILABLE, status: 'deleted' });
      renderModal();

      await waitFor(() => expect(screen.getByText(/deleted/i)).toBeInTheDocument());
      expect(screen.queryByRole('button', { name: /detach volume/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /create snapshot/i })).not.toBeInTheDocument();
    });
  });

  // -------------------------------------------------------------------------
  // Detach action
  // -------------------------------------------------------------------------

  describe('detach action', () => {
    // Detach is confirm-gated (IMP-443984320078): pulling a mounted volume out
    // from under a running instance breaks its workload and the only undo is a
    // re-attach. The footer button opens the dialog; the POST fires from the
    // dialog's own "Detach Volume" button, so it must be scoped with within().
    async function openDetachDialog() {
      const detachBtn = await waitFor(() =>
        screen.getByRole('button', { name: /detach volume/i })
      );
      fireEvent.click(detachBtn);
      return findNestedDialog();
    }

    async function confirmDetach() {
      const dialog = await openDetachDialog();
      fireEvent.click(within(dialog).getByRole('button', { name: 'Detach Volume' }));
    }

    it('does not call systemApi.detachVolume until the operator confirms', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_IN_USE);
      renderModal();

      const dialog = await openDetachDialog();

      expect(within(dialog).getByRole('button', { name: 'Detach Volume' })).toBeInTheDocument();
      expect(mockDetachVolume).not.toHaveBeenCalled();
    });

    it('leaves the volume attached when the operator dismisses the confirmation', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_IN_USE);
      renderModal();

      const dialog = await openDetachDialog();
      fireEvent.click(within(dialog).getByRole('button', { name: 'Keep Attached' }));

      await expectNoNestedDialog();
      expect(mockDetachVolume).not.toHaveBeenCalled();
    });

    it('does not fire a pending confirmation at a different volume', async () => {
      // useConfirmation's dialog state outlives the modal's volumeId prop, so a
      // dialog opened against vol-inuse must not detach a volume loaded since.
      const OTHER = { ...VOLUME_IN_USE, id: 'vol-other', name: 'other-vol' };
      mockGetVolume.mockResolvedValueOnce(VOLUME_IN_USE).mockResolvedValue(OTHER);
      const { rerender } = renderModal({ volumeId: 'vol-inuse' });

      const dialog = await openDetachDialog();

      rerender(
        <BrowserRouter>
          <VolumeDetailModal
            volumeId="vol-other"
            isOpen={true}
            onClose={jest.fn()}
            onVolumeUpdated={jest.fn()}
            onEdit={jest.fn()}
          />
        </BrowserRouter>,
      );
      await waitFor(() => expect(screen.getByText('other-vol')).toBeInTheDocument());

      fireEvent.click(within(dialog).getByRole('button', { name: 'Detach Volume' }));

      await expectNoNestedDialog();
      expect(mockDetachVolume).not.toHaveBeenCalled();
    });

    it('calls systemApi.detachVolume with the correct volume id', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_IN_USE);
      mockDetachVolume.mockResolvedValue({ ...VOLUME_IN_USE, status: 'available', node_instance_id: undefined });
      // Second getVolume call (refresh after detach)
      mockGetVolume.mockResolvedValueOnce(VOLUME_IN_USE).mockResolvedValueOnce({
        ...VOLUME_IN_USE,
        status: 'available',
        node_instance_id: undefined,
      });
      renderModal();

      await confirmDetach();

      await waitFor(() =>
        expect(mockDetachVolume).toHaveBeenCalledWith('vol-inuse')
      );
      expect(mockDetachVolume).toHaveBeenCalledTimes(1);
    });

    it('shows success notification after detach', async () => {
      mockGetVolume
        .mockResolvedValueOnce(VOLUME_IN_USE)
        .mockResolvedValueOnce({ ...VOLUME_IN_USE, status: 'available', node_instance_id: undefined });
      mockDetachVolume.mockResolvedValue({ ...VOLUME_IN_USE, status: 'available', node_instance_id: undefined });

      renderModal();

      await confirmDetach();

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Volume detached successfully',
        })
      );
    });

    it('refreshes volume data by calling getVolume again after detach', async () => {
      const detached = { ...VOLUME_IN_USE, status: 'available', node_instance_id: undefined };
      mockGetVolume
        .mockResolvedValueOnce(VOLUME_IN_USE)
        .mockResolvedValueOnce(detached);
      mockDetachVolume.mockResolvedValue(detached);

      renderModal();

      await confirmDetach();

      await waitFor(() =>
        expect(mockGetVolume).toHaveBeenCalledTimes(2)
      );
    });

    it('calls onVolumeUpdated callback after detach', async () => {
      const onVolumeUpdated = jest.fn();
      const detached = { ...VOLUME_IN_USE, status: 'available', node_instance_id: undefined };
      mockGetVolume
        .mockResolvedValueOnce(VOLUME_IN_USE)
        .mockResolvedValueOnce(detached);
      mockDetachVolume.mockResolvedValue(detached);

      renderModal({ onVolumeUpdated });

      await confirmDetach();

      await waitFor(() => expect(onVolumeUpdated).toHaveBeenCalled());
    });

    it('shows error notification when detachVolume rejects', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_IN_USE);
      mockDetachVolume.mockRejectedValue(new Error('Detach failed'));

      renderModal();

      await confirmDetach();

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to detach volume: Detach failed',
        })
      );
    });

    it('disables the Detach button while the action is in-flight', async () => {
      let resolveDetach!: (v: SystemProviderVolume) => void;
      mockGetVolume.mockResolvedValue(VOLUME_IN_USE);
      mockDetachVolume.mockImplementation(
        () => new Promise<SystemProviderVolume>(r => { resolveDetach = r; })
      );

      renderModal();

      await confirmDetach();

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /detach volume/i })).toBeDisabled()
      );

      // Resolve to clean up the promise
      resolveDetach({ ...VOLUME_IN_USE, status: 'available', node_instance_id: undefined });
    });
  });

  // -------------------------------------------------------------------------
  // Snapshot modal
  // -------------------------------------------------------------------------

  describe('snapshot modal', () => {
    it('opens snapshot modal when "Create Snapshot" is clicked', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      const snapshotBtn = await waitFor(() =>
        screen.getByRole('button', { name: /create snapshot/i })
      );
      fireEvent.click(snapshotBtn);

      await waitFor(() =>
        expect(screen.getByRole('heading', { name: /create snapshot/i })).toBeInTheDocument()
      );
      expect(screen.getByLabelText(/snapshot name/i)).toBeInTheDocument();
      expect(screen.getByPlaceholderText(/snapshot description/i)).toBeInTheDocument();
    });

    it('shows placeholder with volume name in snapshot name field', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      const snapshotBtn = await waitFor(() =>
        screen.getByRole('button', { name: /create snapshot/i })
      );
      fireEvent.click(snapshotBtn);

      await waitFor(() => {
        const input = screen.getByLabelText(/snapshot name/i) as HTMLInputElement;
        expect(input.placeholder).toBe('my-volume-snapshot');
      });
    });

    it('closes snapshot modal when Cancel is clicked', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      const snapshotBtn = await waitFor(() =>
        screen.getByRole('button', { name: /create snapshot/i })
      );
      fireEvent.click(snapshotBtn);

      // Wait for the snapshot sub-modal to appear
      await waitFor(() => expect(screen.getAllByText('Create Snapshot').length).toBeGreaterThan(0));

      fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }));

      // Snapshot Name input should be gone
      await waitFor(() =>
        expect(screen.queryByLabelText(/snapshot name/i)).not.toBeInTheDocument()
      );
    });

    it('calls systemApi.createVolumeSnapshot with default name when name is empty', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      mockCreateVolumeSnapshot.mockResolvedValue({ id: 'snap-1', name: 'my-volume-snapshot' });
      renderModal();

      const snapshotBtn = await waitFor(() =>
        screen.getByRole('button', { name: /create snapshot/i })
      );
      fireEvent.click(snapshotBtn);

      // Snapshot modal open — leave name empty and click Create Snapshot
      await waitFor(() => expect(screen.getByLabelText(/snapshot name/i)).toBeInTheDocument());
      // Click the primary Create Snapshot button inside the sub-modal
      const createBtns = screen.getAllByRole('button', { name: /create snapshot/i });
      // Last one should be inside the sub-modal
      fireEvent.click(createBtns[createBtns.length - 1]);

      await waitFor(() =>
        expect(mockCreateVolumeSnapshot).toHaveBeenCalledWith(
          'vol-abc',
          'my-volume-snapshot', // volume.name + '-snapshot' fallback
          ''
        )
      );
    });

    it('calls systemApi.createVolumeSnapshot with user-provided name and description', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      mockCreateVolumeSnapshot.mockResolvedValue({ id: 'snap-2', name: 'my-snap' });
      renderModal();

      const snapshotBtn = await waitFor(() =>
        screen.getByRole('button', { name: /create snapshot/i })
      );
      fireEvent.click(snapshotBtn);

      await waitFor(() => expect(screen.getByLabelText(/snapshot name/i)).toBeInTheDocument());

      fireEvent.change(screen.getByLabelText(/snapshot name/i), {
        target: { value: 'my-snap' },
      });
      fireEvent.change(screen.getByPlaceholderText(/snapshot description/i), {
        target: { value: 'Before migration' },
      });

      const createBtns = screen.getAllByRole('button', { name: /create snapshot/i });
      fireEvent.click(createBtns[createBtns.length - 1]);

      await waitFor(() =>
        expect(mockCreateVolumeSnapshot).toHaveBeenCalledWith(
          'vol-abc',
          'my-snap',
          'Before migration'
        )
      );
    });

    it('shows success notification and closes snapshot modal on success', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      mockCreateVolumeSnapshot.mockResolvedValue({ id: 'snap-3' });
      renderModal();

      const snapshotBtn = await waitFor(() =>
        screen.getByRole('button', { name: /create snapshot/i })
      );
      fireEvent.click(snapshotBtn);

      await waitFor(() => expect(screen.getByLabelText(/snapshot name/i)).toBeInTheDocument());

      const createBtns = screen.getAllByRole('button', { name: /create snapshot/i });
      fireEvent.click(createBtns[createBtns.length - 1]);

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Snapshot creation started',
        })
      );
      // Sub-modal dismissed
      expect(screen.queryByLabelText(/snapshot name/i)).not.toBeInTheDocument();
    });

    it('shows error notification when createVolumeSnapshot rejects', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      mockCreateVolumeSnapshot.mockRejectedValue(new Error('Quota exceeded'));
      renderModal();

      const snapshotBtn = await waitFor(() =>
        screen.getByRole('button', { name: /create snapshot/i })
      );
      fireEvent.click(snapshotBtn);

      await waitFor(() => expect(screen.getByLabelText(/snapshot name/i)).toBeInTheDocument());

      const createBtns = screen.getAllByRole('button', { name: /create snapshot/i });
      fireEvent.click(createBtns[createBtns.length - 1]);

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to create snapshot: Quota exceeded',
        })
      );
    });

    it('clears snapshot form fields when snapshot modal is closed and reopened', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      renderModal();

      const openSnapshot = async () => {
        const btn = await waitFor(() => screen.getByRole('button', { name: /create snapshot/i }));
        fireEvent.click(btn);
        await waitFor(() => expect(screen.getByLabelText(/snapshot name/i)).toBeInTheDocument());
      };

      await openSnapshot();
      fireEvent.change(screen.getByLabelText(/snapshot name/i), { target: { value: 'old-name' } });

      // Close via Cancel button
      fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }));

      await waitFor(() =>
        expect(screen.queryByLabelText(/snapshot name/i)).not.toBeInTheDocument()
      );

      // Re-open and verify fields are cleared
      await openSnapshot();
      const input = screen.getByLabelText(/snapshot name/i) as HTMLInputElement;
      expect(input.value).toBe('');
    });
  });

  // -------------------------------------------------------------------------
  // Close / onClose
  // -------------------------------------------------------------------------

  describe('close behaviour', () => {
    it('calls onClose when the X button is clicked', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      const onClose = jest.fn();
      renderModal({ onClose });

      await waitFor(() => expect(screen.getByText('my-volume')).toBeInTheDocument());

      // X button is a ghost Button in the header
      const ghostButtons = screen.getAllByRole('button');
      const xBtn = ghostButtons.find(b => b.querySelector('svg'));
      if (xBtn) fireEvent.click(xBtn);

      expect(onClose).toHaveBeenCalled();
    });

    it('calls onClose when the backdrop overlay is clicked', async () => {
      mockGetVolume.mockImplementation(() => new Promise(() => { /* stay loading */ }));
      const onClose = jest.fn();
      renderModal({ onClose });

      // The core Modal dismisses on a click that lands on its positioning
      // container, which is what a click outside the panel resolves to.
      const backdrops = document.querySelectorAll('[class*="justify-center"]');
      if (backdrops.length > 0) fireEvent.click(backdrops[0] as HTMLElement);

      expect(onClose).toHaveBeenCalled();
    });

    it('calls onClose when the "Close" footer button is clicked', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      const onClose = jest.fn();
      renderModal({ onClose });

      await waitFor(() => expect(screen.getByText('my-volume')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: /^close$/i }));
      expect(onClose).toHaveBeenCalled();
    });

    it('resets volume state when isOpen transitions to false', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      const { rerender } = renderModal();

      await waitFor(() => expect(screen.getByText('my-volume')).toBeInTheDocument());

      rerender(
        <BrowserRouter>
          <VolumeDetailModal
            volumeId="vol-abc"
            isOpen={false}
            onClose={jest.fn()}
          />
        </BrowserRouter>
      );

      // When closed, nothing is rendered
      expect(screen.queryByText('my-volume')).not.toBeInTheDocument();
    });
  });

  // -------------------------------------------------------------------------
  // onEdit callback
  // -------------------------------------------------------------------------

  describe('onEdit callback', () => {
    it('calls onEdit with the loaded volume when "Edit Volume" is clicked', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      const onEdit = jest.fn();
      renderModal({ onEdit });

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /edit volume/i })).toBeInTheDocument()
      );

      fireEvent.click(screen.getByRole('button', { name: /edit volume/i }));

      expect(onEdit).toHaveBeenCalledWith(VOLUME_AVAILABLE);
    });
  });

  // -------------------------------------------------------------------------
  // Re-fetch on volumeId change
  // -------------------------------------------------------------------------

  describe('re-fetch on props change', () => {
    it('re-fetches when volumeId changes while modal is open', async () => {
      mockGetVolume.mockResolvedValueOnce(VOLUME_AVAILABLE);
      const { rerender } = renderModal({ volumeId: 'vol-abc' });

      await waitFor(() => expect(mockGetVolume).toHaveBeenCalledWith('vol-abc'));

      const secondVolume: SystemProviderVolume = { ...VOLUME_AVAILABLE, id: 'vol-xyz', name: 'second-vol' };
      mockGetVolume.mockResolvedValueOnce(secondVolume);

      rerender(
        <BrowserRouter>
          <VolumeDetailModal
            volumeId="vol-xyz"
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>
      );

      await waitFor(() => expect(mockGetVolume).toHaveBeenCalledWith('vol-xyz'));
      await waitFor(() => expect(screen.getByText('second-vol')).toBeInTheDocument());
    });
  });

  // -------------------------------------------------------------------------
  // Snapshots section — list + restore — IMP-f17e2c0bae12
  // -------------------------------------------------------------------------

  describe('snapshots section', () => {
    const SNAP_A = {
      id: 'snap-a',
      name: 'nightly-2026-03-01',
      description: 'nightly',
      status: 'completed',
      size_gb: 100,
      can_restore: true,
      created_at: '2026-03-01T02:00:00Z',
    };
    const SNAP_PENDING = {
      id: 'snap-b',
      name: 'in-flight',
      status: 'pending',
      size_gb: 100,
      can_restore: false,
      created_at: '2026-03-02T02:00:00Z',
    };
    // Deliberately decorrelated from `status`: an implementation that read
    // `status === 'completed'` instead of the server's can_restore boolean
    // would offer Restore on this one.
    const SNAP_COMPLETED_NOT_RESTORABLE = {
      id: 'snap-c',
      name: 'archived-away',
      status: 'completed',
      size_gb: 100,
      can_restore: false,
      created_at: '2026-03-03T02:00:00Z',
    };

    function snapshotPage(
      snapshots: Array<Record<string, unknown>>,
      meta: Partial<{ current_page: number; total_pages: number; total_count: number }> = {},
    ) {
      return {
        snapshots,
        meta: {
          current_page: 1,
          per_page: 10,
          total_count: snapshots.length,
          total_pages: 1,
          next_page: null,
          prev_page: null,
          ...meta,
        },
      };
    }

    async function openWithSnapshots(
      snapshots = [SNAP_A],
      meta = {},
      volume = VOLUME_AVAILABLE,
    ) {
      mockGetVolume.mockResolvedValue(volume);
      mockGetVolumeSnapshots.mockResolvedValue(snapshotPage(snapshots, meta));
      renderModal();
      await waitFor(() => expect(screen.getByText('Snapshots')).toBeInTheDocument());
    }

    it('lists the volume snapshots', async () => {
      await openWithSnapshots();

      expect(mockGetVolumeSnapshots).toHaveBeenCalledWith('vol-abc', { page: 1 });
      await waitFor(() =>
        expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument(),
      );
    });

    it('shows an empty state when the volume has no snapshots', async () => {
      await openWithSnapshots([]);

      await waitFor(() =>
        expect(screen.getByText(/no snapshots/i)).toBeInTheDocument(),
      );
    });

    it('pages through snapshots', async () => {
      await openWithSnapshots([SNAP_A], { total_pages: 3, total_count: 25 });

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: '2' }));

      await waitFor(() =>
        expect(mockGetVolumeSnapshots).toHaveBeenCalledWith('vol-abc', { page: 2 }),
      );
    });

    it('offers Restore only for snapshots the server says can be restored', async () => {
      await openWithSnapshots([SNAP_A, SNAP_PENDING, SNAP_COMPLETED_NOT_RESTORABLE]);

      await waitFor(() => expect(screen.getByText('archived-away')).toBeInTheDocument());
      expect(screen.getByText('in-flight')).toBeInTheDocument();
      // Only SNAP_A — the completed-but-not-restorable one must not get a
      // button, which is what separates can_restore from status.
      expect(screen.getAllByRole('button', { name: 'Restore' })).toHaveLength(1);
    });

    it('hides Restore entirely without the system.volumes.manage permission', async () => {
      mockHasPermission.mockImplementation((p: string) => p !== 'system.volumes.manage');
      await openWithSnapshots();

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      expect(screen.queryByRole('button', { name: 'Restore' })).not.toBeInTheDocument();
    });

    it('does not restore until the operator confirms', async () => {
      await openWithSnapshots();

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));

      await findNestedDialog();
      expect(mockRestoreVolumeSnapshot).not.toHaveBeenCalled();
    });

    it('explains copy-restore in the confirmation', async () => {
      await openWithSnapshots();

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));

      const dialog = await findNestedDialog();
      // The copy path is the one that surprises operators: the data lands in a
      // different disk and this volume is untouched.
      expect(
        within(dialog).getByText(/the snapshot into a new volume/i),
      ).toBeInTheDocument();
      expect(within(dialog).getByText(/left untouched/i)).toBeInTheDocument();
      expect(within(dialog).getByLabelText(/swap/i)).toBeInTheDocument();
    });

    it('restores without a swap by default', async () => {
      await openWithSnapshots();
      mockRestoreVolumeSnapshot.mockResolvedValue({
        restored_in_place: false,
        restored_volume: { ...VOLUME_AVAILABLE, id: 'vol-copy', name: 'restored-copy' },
        restored_from: SNAP_A,
        swapped: false,
        swap_skipped: null,
      });

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
      const dialog = await findNestedDialog();
      fireEvent.click(within(dialog).getByRole('button', { name: 'Restore Snapshot' }));

      await waitFor(() =>
        expect(mockRestoreVolumeSnapshot).toHaveBeenCalledWith('vol-abc', 'snap-a', false),
      );
    });

    it('opts into swap_into_place when the operator ticks the box', async () => {
      await openWithSnapshots();
      mockRestoreVolumeSnapshot.mockResolvedValue({
        restored_in_place: false,
        restored_volume: { ...VOLUME_AVAILABLE, id: 'vol-copy', name: 'restored-copy' },
        restored_from: SNAP_A,
        swapped: true,
        swap_skipped: null,
        swapped_instance_id: 'inst-1',
        swapped_device: '/dev/xvdf',
      });

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
      const dialog = await findNestedDialog();
      fireEvent.click(within(dialog).getByLabelText(/swap/i));
      fireEvent.click(within(dialog).getByRole('button', { name: 'Restore Snapshot' }));

      await waitFor(() =>
        expect(mockRestoreVolumeSnapshot).toHaveBeenCalledWith('vol-abc', 'snap-a', true),
      );
    });

    it('reports that the data landed in a NEW volume when the restore was a copy', async () => {
      await openWithSnapshots();
      mockRestoreVolumeSnapshot.mockResolvedValue({
        restored_in_place: false,
        restored_volume: { ...VOLUME_AVAILABLE, id: 'vol-copy', name: 'restored-copy' },
        restored_from: SNAP_A,
        swapped: false,
        swap_skipped: null,
      });

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
      const dialog = await findNestedDialog();
      fireEvent.click(within(dialog).getByRole('button', { name: 'Restore Snapshot' }));

      // The operator must not be told "restored" when this volume is unchanged.
      await expectNoNestedDialog();
      const panel = await screen.findByText(/This volume is unchanged/i);
      expect(panel).toHaveTextContent(/new volume/i);
      expect(panel).toHaveTextContent(/restored-copy/);
      expect(panel).toHaveTextContent(/vol-copy/);
    });

    it('reports an in-place restore as this volume being rolled back', async () => {
      await openWithSnapshots();
      mockRestoreVolumeSnapshot.mockResolvedValue({
        restored_in_place: true,
        restored_volume: null,
        restored_from: SNAP_A,
        swapped: false,
        swap_skipped: null,
      });

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
      const dialog = await findNestedDialog();
      fireEvent.click(within(dialog).getByRole('button', { name: 'Restore Snapshot' }));

      await waitFor(() => expect(screen.getByText(/rolled back/i)).toBeInTheDocument());
    });

    it('names the reason when a requested swap was skipped', async () => {
      await openWithSnapshots();
      mockRestoreVolumeSnapshot.mockResolvedValue({
        restored_in_place: false,
        restored_volume: { ...VOLUME_AVAILABLE, id: 'vol-copy', name: 'restored-copy' },
        restored_from: SNAP_A,
        swapped: false,
        swap_skipped: 'source_not_attached',
      });

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
      const dialog = await findNestedDialog();
      fireEvent.click(within(dialog).getByLabelText(/swap/i));
      fireEvent.click(within(dialog).getByRole('button', { name: 'Restore Snapshot' }));

      await waitFor(() =>
        expect(screen.getByText(/source_not_attached/)).toBeInTheDocument(),
      );
    });

    it('reports the swap when one happened', async () => {
      await openWithSnapshots();
      mockRestoreVolumeSnapshot.mockResolvedValue({
        restored_in_place: false,
        restored_volume: { ...VOLUME_AVAILABLE, id: 'vol-copy', name: 'restored-copy' },
        restored_from: SNAP_A,
        swapped: true,
        swap_skipped: null,
        swapped_instance_id: 'inst-1',
        swapped_device: '/dev/xvdf',
      });

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
      const dialog = await findNestedDialog();
      fireEvent.click(within(dialog).getByLabelText(/swap/i));
      fireEvent.click(within(dialog).getByRole('button', { name: 'Restore Snapshot' }));

      await waitFor(() => expect(screen.getByText(/\/dev\/xvdf/)).toBeInTheDocument());
    });

    it('shows an error notification when the restore fails', async () => {
      await openWithSnapshots();
      mockRestoreVolumeSnapshot.mockRejectedValue(new Error('provider refused'));

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
      const dialog = await findNestedDialog();
      fireEvent.click(within(dialog).getByRole('button', { name: 'Restore Snapshot' }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to restore snapshot: provider refused',
        }),
      );
    });

    it('keeps the orphaned copy visible when a restore fails after creating one', async () => {
      // The controller's render_restore_error carries the copy's id precisely
      // because losing it strands a billable, unattached disk. A toast
      // auto-dismisses, so the id has to land somewhere durable.
      await openWithSnapshots();
      mockRestoreVolumeSnapshot.mockRejectedValue(
        new VolumeRestoreError('Swap failed after the copy was created', {
          restored_volume_id: 'vol-orphan',
          swap_stage: 'attach',
          swapped: false,
        }),
      );

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
      const dialog = await findNestedDialog();
      fireEvent.click(within(dialog).getByLabelText(/swap/i));
      fireEvent.click(within(dialog).getByRole('button', { name: 'Restore Snapshot' }));

      const orphanLine = await screen.findByText(/vol-orphan/);
      expect(orphanLine).toHaveTextContent(/billable/i);
      // The stage the swap stopped at, so the operator knows what to undo.
      expect(screen.getByText(/the swap stopped at: attach/i)).toBeInTheDocument();
    });

    it('discards a snapshot listing that arrives after the modal moved on', async () => {
      let resolveStale!: (v: unknown) => void;
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      mockGetVolumeSnapshots
        .mockReturnValueOnce(new Promise((res) => { resolveStale = res; }))
        .mockResolvedValue(snapshotPage([SNAP_PENDING]));
      const { rerender } = renderModal({ volumeId: 'vol-abc' });

      mockGetVolume.mockResolvedValue({ ...VOLUME_AVAILABLE, id: 'vol-other', name: 'other-vol' });
      rerender(
        <BrowserRouter>
          <VolumeDetailModal
            volumeId="vol-other"
            isOpen={true}
            onClose={jest.fn()}
            onVolumeUpdated={jest.fn()}
            onEdit={jest.fn()}
          />
        </BrowserRouter>,
      );
      await waitFor(() => expect(screen.getByText('in-flight')).toBeInTheDocument());

      // The first volume's listing lands late and must not replace the list.
      await act(async () => { resolveStale(snapshotPage([SNAP_A])); });

      expect(screen.getByText('in-flight')).toBeInTheDocument();
      expect(screen.queryByText('nightly-2026-03-01')).not.toBeInTheDocument();
    });

    it('clears a previous restore outcome when the modal moves to another volume', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      mockGetVolumeSnapshots.mockResolvedValue(snapshotPage([SNAP_A]));
      mockRestoreVolumeSnapshot.mockResolvedValue({
        restored_in_place: true,
        restored_volume: null,
        restored_from: SNAP_A,
        swapped: false,
        swap_skipped: null,
      });
      const { rerender } = renderModal();

      await waitFor(() => expect(screen.getByText('nightly-2026-03-01')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
      const dialog = await findNestedDialog();
      fireEvent.click(within(dialog).getByRole('button', { name: 'Restore Snapshot' }));
      await waitFor(() => expect(screen.getByText(/rolled back/i)).toBeInTheDocument());

      // A destructive outcome must not be reported under a different volume.
      mockGetVolume.mockResolvedValue({ ...VOLUME_AVAILABLE, id: 'vol-other', name: 'other-vol' });
      rerender(
        <BrowserRouter>
          <VolumeDetailModal
            volumeId="vol-other"
            isOpen={true}
            onClose={jest.fn()}
            onVolumeUpdated={jest.fn()}
            onEdit={jest.fn()}
          />
        </BrowserRouter>,
      );

      await waitFor(() => expect(screen.getByText('other-vol')).toBeInTheDocument());
      expect(screen.queryByText(/rolled back/i)).not.toBeInTheDocument();
    });

    it('refreshes the snapshot list after a snapshot is created', async () => {
      await openWithSnapshots([]);
      mockCreateVolumeSnapshot.mockResolvedValue(SNAP_A);

      await waitFor(() => expect(mockGetVolumeSnapshots).toHaveBeenCalledTimes(1));
      fireEvent.click(screen.getByRole('button', { name: /create snapshot/i }));
      const dialogButtons = await screen.findAllByRole('button', { name: /create snapshot/i });
      fireEvent.click(dialogButtons[dialogButtons.length - 1]);

      await waitFor(() => expect(mockGetVolumeSnapshots).toHaveBeenCalledTimes(2));
    });

    it('surfaces a failure to load the snapshot list instead of showing it as empty', async () => {
      mockGetVolume.mockResolvedValue(VOLUME_AVAILABLE);
      mockGetVolumeSnapshots.mockRejectedValue(new Error('boom'));
      renderModal();

      await waitFor(() =>
        expect(screen.getByText(/could not load snapshots/i)).toBeInTheDocument(),
      );
      expect(screen.queryByText(/no snapshots yet/i)).not.toBeInTheDocument();
    });
  });
});
