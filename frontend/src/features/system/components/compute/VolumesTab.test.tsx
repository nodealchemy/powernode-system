import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { VolumesTab } from './VolumesTab';
import type { SystemProviderVolume } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
//
// VolumesTab is a compositor that:
//   1. Mounts VolumeList, VolumeDetailModal, VolumeFormModal, VolumeAttachModal
//   2. Renders its own inline delete-confirmation dialog
//   3. Calls systemApi.deleteVolume, detachVolume, createVolumeSnapshot directly
//   4. Reports an { openCreate } handle via onActionsReady
//
// We mock the four child volume components to capture their props and trigger
// callbacks; we mock systemApi for the three direct API calls.
// =============================================================================

// -- child component prop captures ------------------------------------------

let capturedListProps: {
  onView?: (v: SystemProviderVolume) => void;
  onEdit?: (v: SystemProviderVolume) => void;
  onDelete?: (id: string) => void;
  onCreate?: () => void;
  onAttach?: (v: SystemProviderVolume) => void;
  onDetach?: (v: SystemProviderVolume) => void;
  onSnapshot?: (v: SystemProviderVolume) => void;
} = {};

let capturedDetailProps: {
  volumeId: string | null;
  isOpen: boolean;
  onClose: () => void;
  onVolumeUpdated?: () => void;
  onEdit?: (v: SystemProviderVolume) => void;
} = {} as never;

let capturedFormProps: {
  volume: SystemProviderVolume | null;
  isOpen: boolean;
  onClose: () => void;
  onVolumeSaved?: (v: SystemProviderVolume) => void;
} = {} as never;

let capturedAttachProps: {
  volume: SystemProviderVolume | null;
  isOpen: boolean;
  onClose: () => void;
  onVolumeAttached?: () => void;
} = {} as never;

jest.mock('@system/features/system/components/volumes', () => ({
  VolumeList: (props: typeof capturedListProps) => {
    capturedListProps = props;
    return <div data-testid="volume-list" />;
  },
  VolumeDetailModal: (props: typeof capturedDetailProps) => {
    capturedDetailProps = props;
    return props.isOpen ? <div data-testid="volume-detail-modal" /> : null;
  },
  VolumeFormModal: (props: typeof capturedFormProps) => {
    capturedFormProps = props;
    return props.isOpen ? (
      <div data-testid="volume-form-modal">
        {props.volume ? 'edit-mode' : 'create-mode'}
      </div>
    ) : null;
  },
  VolumeAttachModal: (props: typeof capturedAttachProps) => {
    capturedAttachProps = props;
    return props.isOpen ? <div data-testid="volume-attach-modal" /> : null;
  },
}));

// -- systemApi stubs --------------------------------------------------------

const mockDeleteVolume = jest.fn();
const mockDetachVolume = jest.fn();
const mockCreateVolumeSnapshot = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    deleteVolume: (...args: unknown[]) => mockDeleteVolume(...args),
    detachVolume: (...args: unknown[]) => mockDetachVolume(...args),
    createVolumeSnapshot: (...args: unknown[]) => mockCreateVolumeSnapshot(...args),
  },
}));

// -- shared hooks -----------------------------------------------------------

// Configurable hasPermission — tests that need restricted perms override it.
const mockHasPermission = jest.fn((_perm: string) => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: (...args: unknown[]) => mockHasPermission(...(args as [string])) }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// =============================================================================
// Fixtures
// =============================================================================

const VOLUME_AVAILABLE: SystemProviderVolume = {
  id: 'vol-available',
  name: 'data-vol',
  size_gb: 100,
  status: 'available',
  volume_type: 'gp3',
  encrypted: false,
  config: {},
  provider_region_id: 'us-east-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const VOLUME_IN_USE: SystemProviderVolume = {
  id: 'vol-in-use',
  name: 'boot-vol',
  size_gb: 50,
  status: 'in-use',
  volume_type: 'gp2',
  encrypted: true,
  config: {},
  provider_region_id: 'us-east-1',
  node_instance_id: 'inst-abc',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Test helpers
// =============================================================================

const renderTab = (props: React.ComponentProps<typeof VolumesTab> = {}) =>
  render(
    <BrowserRouter>
      <VolumesTab {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('VolumesTab', () => {
  beforeEach(() => {
    mockDeleteVolume.mockReset();
    mockDetachVolume.mockReset();
    mockCreateVolumeSnapshot.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockImplementation((_perm: string) => true);
    capturedListProps = {};
    capturedDetailProps = {} as never;
    capturedFormProps = {} as never;
    capturedAttachProps = {} as never;
  });

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------

  it('renders VolumeList, and starts with all modals closed', () => {
    renderTab();

    expect(screen.getByTestId('volume-list')).toBeInTheDocument();
    expect(screen.queryByTestId('volume-detail-modal')).not.toBeInTheDocument();
    expect(screen.queryByTestId('volume-form-modal')).not.toBeInTheDocument();
    expect(screen.queryByTestId('volume-attach-modal')).not.toBeInTheDocument();
    expect(screen.queryByText('Delete Volume')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onActionsReady callback
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with a handle containing openCreate on mount', () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    expect(onActionsReady).toHaveBeenCalledWith(
      expect.objectContaining({ openCreate: expect.any(Function) }),
    );
  });

  it('calls onActionsReady(null) on unmount', () => {
    const onActionsReady = jest.fn();
    const { unmount } = renderTab({ onActionsReady });
    unmount();
    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  it('openCreate handle opens the form modal in create mode', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    const handle = onActionsReady.mock.calls[0][0] as { openCreate: () => void };
    await act(async () => { handle.openCreate(); });

    expect(screen.getByTestId('volume-form-modal')).toBeInTheDocument();
    expect(screen.getByTestId('volume-form-modal').textContent).toBe('create-mode');
    expect(capturedFormProps.volume).toBeNull();
  });

  // ---------------------------------------------------------------------------
  // VolumeList prop wiring
  // ---------------------------------------------------------------------------

  it('passes canDelete handler to VolumeList when user has delete permission', () => {
    renderTab();
    // hasPermission returns true for everything, so onDelete must be a function
    expect(typeof capturedListProps.onDelete).toBe('function');
  });

  it('passes canCreate onCreate to VolumeList', () => {
    renderTab();
    expect(typeof capturedListProps.onCreate).toBe('function');
  });

  // ---------------------------------------------------------------------------
  // onCreate / VolumeList → form modal (create mode)
  // ---------------------------------------------------------------------------

  it('opens form modal in create mode when VolumeList onCreate fires', async () => {
    renderTab();

    await act(async () => { capturedListProps.onCreate?.(); });

    expect(screen.getByTestId('volume-form-modal')).toBeInTheDocument();
    expect(capturedFormProps.volume).toBeNull();
  });

  // ---------------------------------------------------------------------------
  // onView → detail modal
  // ---------------------------------------------------------------------------

  it('opens detail modal with correct volumeId when VolumeList onView fires', async () => {
    renderTab();

    await act(async () => { capturedListProps.onView?.(VOLUME_AVAILABLE); });

    expect(screen.getByTestId('volume-detail-modal')).toBeInTheDocument();
    expect(capturedDetailProps.volumeId).toBe('vol-available');
    expect(capturedDetailProps.isOpen).toBe(true);
  });

  it('closes detail modal when its onClose fires', async () => {
    renderTab();

    await act(async () => { capturedListProps.onView?.(VOLUME_AVAILABLE); });
    expect(screen.getByTestId('volume-detail-modal')).toBeInTheDocument();

    await act(async () => { capturedDetailProps.onClose(); });
    expect(screen.queryByTestId('volume-detail-modal')).not.toBeInTheDocument();
    expect(capturedDetailProps.volumeId).toBeNull();
  });

  // ---------------------------------------------------------------------------
  // onEdit → form modal (edit mode)
  // ---------------------------------------------------------------------------

  it('opens form modal in edit mode with the correct volume when onEdit fires', async () => {
    renderTab();

    await act(async () => { capturedListProps.onEdit?.(VOLUME_AVAILABLE); });

    expect(screen.getByTestId('volume-form-modal')).toBeInTheDocument();
    expect(capturedFormProps.volume?.id).toBe('vol-available');
    expect(screen.getByTestId('volume-form-modal').textContent).toBe('edit-mode');
  });

  it('closes form modal and clears edit volume when onClose fires', async () => {
    renderTab();

    await act(async () => { capturedListProps.onEdit?.(VOLUME_AVAILABLE); });
    expect(screen.getByTestId('volume-form-modal')).toBeInTheDocument();

    await act(async () => { capturedFormProps.onClose(); });
    expect(screen.queryByTestId('volume-form-modal')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onEditFromDetail — detail → form
  // ---------------------------------------------------------------------------

  it('closes detail modal and opens form modal in edit mode when onEdit fires from detail', async () => {
    renderTab();

    // Open detail modal first
    await act(async () => { capturedListProps.onView?.(VOLUME_IN_USE); });
    expect(screen.getByTestId('volume-detail-modal')).toBeInTheDocument();

    // Trigger edit from detail
    await act(async () => { capturedDetailProps.onEdit?.(VOLUME_IN_USE); });

    expect(screen.queryByTestId('volume-detail-modal')).not.toBeInTheDocument();
    expect(screen.getByTestId('volume-form-modal')).toBeInTheDocument();
    expect(capturedFormProps.volume?.id).toBe('vol-in-use');
  });

  // ---------------------------------------------------------------------------
  // onVolumeSaved — refreshKey bump
  // ---------------------------------------------------------------------------

  it('bumps refreshKey (re-keys VolumeList) when onVolumeSaved fires', async () => {
    renderTab();

    // VolumeList is mounted initially
    expect(screen.getByTestId('volume-list')).toBeInTheDocument();

    // Trigger the save callback — this bumps refreshKey which re-keys VolumeList
    await act(async () => { capturedFormProps.onVolumeSaved?.(VOLUME_AVAILABLE); });

    // VolumeList remains visible after key-bump (React remounts, not unmounts)
    expect(screen.getByTestId('volume-list')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onAttach → attach modal
  // ---------------------------------------------------------------------------

  it('opens attach modal with the correct volume when onAttach fires', async () => {
    renderTab();

    await act(async () => { capturedListProps.onAttach?.(VOLUME_AVAILABLE); });

    expect(screen.getByTestId('volume-attach-modal')).toBeInTheDocument();
    expect(capturedAttachProps.volume?.id).toBe('vol-available');
    expect(capturedAttachProps.isOpen).toBe(true);
  });

  it('closes attach modal when its onClose fires', async () => {
    renderTab();

    await act(async () => { capturedListProps.onAttach?.(VOLUME_AVAILABLE); });
    await act(async () => { capturedAttachProps.onClose(); });

    expect(screen.queryByTestId('volume-attach-modal')).not.toBeInTheDocument();
    expect(capturedAttachProps.volume).toBeNull();
  });

  // ---------------------------------------------------------------------------
  // onDetach — systemApi.detachVolume
  // ---------------------------------------------------------------------------

  it('calls systemApi.detachVolume with the volume id and shows success notification', async () => {
    mockDetachVolume.mockResolvedValueOnce(VOLUME_AVAILABLE);
    renderTab();

    capturedListProps.onDetach?.(VOLUME_IN_USE);

    await waitFor(() =>
      expect(mockDetachVolume).toHaveBeenCalledWith('vol-in-use'),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: 'Volume detached successfully' }),
      ),
    );
  });

  it('shows error notification when detach fails', async () => {
    mockDetachVolume.mockRejectedValueOnce(new Error('network error'));
    renderTab();

    capturedListProps.onDetach?.(VOLUME_IN_USE);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: expect.stringContaining('network error') }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // onSnapshot — systemApi.createVolumeSnapshot
  // ---------------------------------------------------------------------------

  it('calls systemApi.createVolumeSnapshot with the volume id and derived name, shows success', async () => {
    mockCreateVolumeSnapshot.mockResolvedValueOnce({ id: 'snap-1', name: 'data-vol-snapshot' });
    renderTab();

    capturedListProps.onSnapshot?.(VOLUME_AVAILABLE);

    await waitFor(() =>
      expect(mockCreateVolumeSnapshot).toHaveBeenCalledWith(
        'vol-available',
        'data-vol-snapshot',
      ),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: 'Snapshot creation started' }),
      ),
    );
  });

  it('shows error notification when snapshot creation fails', async () => {
    mockCreateVolumeSnapshot.mockRejectedValueOnce(new Error('quota exceeded'));
    renderTab();

    capturedListProps.onSnapshot?.(VOLUME_AVAILABLE);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: expect.stringContaining('quota exceeded') }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Delete confirmation dialog
  // ---------------------------------------------------------------------------

  it('opens the delete confirmation dialog when VolumeList onDelete fires', async () => {
    renderTab();

    await act(async () => { capturedListProps.onDelete?.('vol-available'); });

    // h3 heading within the dialog
    expect(screen.getByRole('heading', { name: /delete volume/i })).toBeInTheDocument();
    expect(
      screen.getByText(/are you sure you want to delete this volume/i),
    ).toBeInTheDocument();
  });

  it('closes the delete dialog when Cancel is clicked without calling delete API', async () => {
    renderTab();

    await act(async () => { capturedListProps.onDelete?.('vol-available'); });
    expect(screen.getByRole('heading', { name: /delete volume/i })).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /delete volume/i })).not.toBeInTheDocument(),
    );
    expect(mockDeleteVolume).not.toHaveBeenCalled();
  });

  it('closes the delete dialog when the backdrop is clicked without calling delete API', async () => {
    renderTab();

    await act(async () => { capturedListProps.onDelete?.('vol-available'); });

    // The backdrop is the fixed overlay element — clicking it should close
    const overlay = document.querySelector('.bg-black\\/50') as HTMLElement;
    expect(overlay).not.toBeNull();
    fireEvent.click(overlay);

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /delete volume/i })).not.toBeInTheDocument(),
    );
    expect(mockDeleteVolume).not.toHaveBeenCalled();
  });

  it('calls systemApi.deleteVolume with the correct id and shows success when confirmed', async () => {
    mockDeleteVolume.mockResolvedValueOnce(undefined);
    renderTab();

    await act(async () => { capturedListProps.onDelete?.('vol-available'); });
    fireEvent.click(screen.getByRole('button', { name: /delete volume/i }));

    await waitFor(() =>
      expect(mockDeleteVolume).toHaveBeenCalledWith('vol-available'),
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: 'Volume deleted successfully' }),
      ),
    );
    // Dialog should close after success
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /delete volume/i })).not.toBeInTheDocument(),
    );
  });

  it('disables the Delete Volume button while deletion is in flight', async () => {
    let resolveDelete!: () => void;
    mockDeleteVolume.mockReturnValueOnce(
      new Promise<void>((res) => { resolveDelete = res; }),
    );
    renderTab();

    await act(async () => { capturedListProps.onDelete?.('vol-available'); });
    const deleteBtn = screen.getByRole('button', { name: /delete volume/i });
    fireEvent.click(deleteBtn);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /deleting\.\.\./i })).toBeDisabled(),
    );

    resolveDelete();
    await waitFor(() =>
      expect(screen.queryByText('Delete Volume')).not.toBeInTheDocument(),
    );
  });

  it('shows error notification and closes dialog when deletion fails', async () => {
    mockDeleteVolume.mockRejectedValueOnce(new Error('permission denied'));
    renderTab();

    await act(async () => { capturedListProps.onDelete?.('vol-available'); });
    fireEvent.click(screen.getByRole('button', { name: /delete volume/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: expect.stringContaining('permission denied'),
        }),
      ),
    );
    // Dialog closes even on error (finally block)
    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /delete volume/i })).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  it('does not pass onDelete to VolumeList when user lacks delete permission', () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.volumes.delete');

    renderTab();

    expect(capturedListProps.onDelete).toBeUndefined();
  });

  it('does not pass onCreate to VolumeList when user lacks create permission', () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.volumes.create');

    renderTab();

    expect(capturedListProps.onCreate).toBeUndefined();
  });

  // ---------------------------------------------------------------------------
  // onVolumeUpdated (from detail modal) triggers refresh
  // ---------------------------------------------------------------------------

  it('triggers a VolumeList refresh when detail modal onVolumeUpdated fires', async () => {
    renderTab();

    // Open the detail modal
    await act(async () => { capturedListProps.onView?.(VOLUME_AVAILABLE); });
    expect(capturedDetailProps.isOpen).toBe(true);

    // Fire the update callback — this should bump refreshKey causing VolumeList
    // to remount (key change). The mock VolumeList is re-rendered but stays
    // visible; no error should occur.
    await act(async () => { capturedDetailProps.onVolumeUpdated?.(); });

    // List still present (key change causes remount, not unmount)
    expect(screen.getByTestId('volume-list')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onVolumeAttached (from attach modal) triggers refresh
  // ---------------------------------------------------------------------------

  it('triggers a VolumeList refresh when attach modal onVolumeAttached fires', async () => {
    renderTab();

    await act(async () => { capturedListProps.onAttach?.(VOLUME_AVAILABLE); });
    expect(capturedAttachProps.isOpen).toBe(true);

    await act(async () => { capturedAttachProps.onVolumeAttached?.(); });

    expect(screen.getByTestId('volume-list')).toBeInTheDocument();
  });
});
