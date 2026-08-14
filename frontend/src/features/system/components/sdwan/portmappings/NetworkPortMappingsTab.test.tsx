import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NetworkPortMappingsTab } from './NetworkPortMappingsTab';
import type { SdwanPortMapping, SdwanPeer, SdwanVirtualIp } from '../../../types/sdwan.types';

// =============================================================================
// Mocks
//
// NetworkPortMappingsTab delegates rendering to PortMappingList and
// PortMappingCreateModal, and calls sdwanApi.deletePortMapping /
// sdwanApi.updatePortMapping for the delete/toggle actions. Both child
// components are stubbed to lightweight sentinels so this test isolates
// the tab's own orchestration: state management, API calls, notifications,
// permission gating, and action handle propagation via onActionsReady.
// =============================================================================

const mockListPortMappings = jest.fn();
const mockGetPeers = jest.fn();
const mockListVirtualIps = jest.fn();
const mockDeletePortMapping = jest.fn();
const mockUpdatePortMapping = jest.fn();
const mockCreatePortMapping = jest.fn();
const mockPatchPortMapping = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    listPortMappings: (...a: unknown[]) => mockListPortMappings(...a),
    getPeers: (...a: unknown[]) => mockGetPeers(...a),
    listVirtualIps: (...a: unknown[]) => mockListVirtualIps(...a),
    deletePortMapping: (...a: unknown[]) => mockDeletePortMapping(...a),
    updatePortMapping: (...a: unknown[]) => mockUpdatePortMapping(...a),
    createPortMapping: (...a: unknown[]) => mockCreatePortMapping(...a),
    patchPortMapping: (...a: unknown[]) => mockPatchPortMapping(...a),
  },
}));

const mockHasPermission = jest.fn();
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (perm: string) => mockHasPermission(perm),
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
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

// EntityLink renders an anchor — stub it to avoid router dependency inside the list
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label: string }) => <span data-testid="entity-link">{label}</span>,
}));

// Stub PortMappingCreateModal: renders a sentinel + exposes Save/Cancel triggers
// so we can verify that the tab opens it for create and edit modes.
jest.mock('./PortMappingCreateModal', () => ({
  PortMappingCreateModal: ({
    networkId,
    mapping,
    onClose,
    onSaved,
  }: {
    networkId: string;
    mapping?: SdwanPortMapping | null;
    onClose: () => void;
    onSaved: (m: SdwanPortMapping) => void;
  }) => (
    <div data-testid="port-mapping-create-modal" data-network-id={networkId} data-is-edit={mapping ? 'true' : 'false'}>
      <span data-testid="modal-mapping-name">{mapping?.name ?? 'create-mode'}</span>
      <button data-testid="modal-save" onClick={() => onSaved({ id: 'saved-id', name: 'saved', network_id: networkId } as SdwanPortMapping)}>
        Save
      </button>
      <button data-testid="modal-close" onClick={onClose}>Close</button>
    </div>
  ),
}));

// Stub PortMappingList: renders a minimal sentinel that exposes onEdit / onDelete / onToggle triggers
jest.mock('./PortMappingList', () => ({
  PortMappingList: ({
    networkId,
    refreshKey,
    onEdit,
    onDelete,
    onToggle,
  }: {
    networkId: string;
    refreshKey?: number;
    onEdit?: (m: SdwanPortMapping) => void;
    onDelete?: (m: SdwanPortMapping) => void;
    onToggle?: (m: SdwanPortMapping) => void;
  }) => (
    <div data-testid="port-mapping-list" data-network-id={networkId} data-refresh-key={String(refreshKey ?? 0)}>
      {onEdit && (
        <button
          data-testid="trigger-edit"
          onClick={() => onEdit({ id: 'pm-1', name: 'my-mapping', network_id: networkId, hub_peer_id: 'hub-1', listen_port: 5432, protocol: 'tcp', enabled: true, effective_target_port: 5432 } as SdwanPortMapping)}
        >
          Edit
        </button>
      )}
      {onDelete && (
        <button
          data-testid="trigger-delete"
          onClick={() => onDelete({ id: 'pm-1', name: 'my-mapping', protocol: 'tcp', listen_port: 5432, network_id: networkId, hub_peer_id: 'hub-1', enabled: true, effective_target_port: 5432 } as SdwanPortMapping)}
        >
          Delete
        </button>
      )}
      {onToggle && (
        <button
          data-testid="trigger-toggle"
          onClick={() => onToggle({ id: 'pm-1', name: 'my-mapping', network_id: networkId, hub_peer_id: 'hub-1', listen_port: 5432, protocol: 'tcp', enabled: true, effective_target_port: 5432 } as SdwanPortMapping)}
        >
          Toggle
        </button>
      )}
    </div>
  ),
}));

// =============================================================================
// Fixtures
// =============================================================================

const NETWORK_ID = 'net-abc';

const MAPPING_1: SdwanPortMapping = {
  id: 'pm-1',
  network_id: NETWORK_ID,
  hub_peer_id: 'hub-1',
  name: 'my-mapping',
  listen_port: 5432,
  protocol: 'tcp',
  enabled: true,
  effective_target_port: 5432,
};

// =============================================================================
// Helper
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const renderTab = (props: Partial<React.ComponentProps<typeof NetworkPortMappingsTab>> = {}) =>
  render(
    <BrowserRouter>
      <NetworkPortMappingsTab networkId={NETWORK_ID} {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('NetworkPortMappingsTab', () => {
  beforeEach(() => {
    mockListPortMappings.mockReset();
    mockGetPeers.mockReset();
    mockListVirtualIps.mockReset();
    mockDeletePortMapping.mockReset();
    mockUpdatePortMapping.mockReset();
    mockCreatePortMapping.mockReset();
    mockPatchPortMapping.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    // Default: user has manage permission
    mockHasPermission.mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Render / initial state
  // ---------------------------------------------------------------------------

  it('renders the explanatory paragraph and the PortMappingList', () => {
    renderTab();

    expect(screen.getByText(/hub peers publish overlay services/i)).toBeInTheDocument();
    expect(screen.getByTestId('port-mapping-list')).toBeInTheDocument();
    expect(screen.getByTestId('port-mapping-list')).toHaveAttribute('data-network-id', NETWORK_ID);
  });

  it('does not render the create modal on initial render (editTarget is undefined)', () => {
    renderTab();
    expect(screen.queryByTestId('port-mapping-create-modal')).not.toBeInTheDocument();
  });

  it('does not render the delete confirm modal on initial render', () => {
    renderTab();
    expect(screen.queryByText(/delete port mapping/i)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // onActionsReady — exposes openCreate handle to parent
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with an openCreate handle on mount', () => {
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

  it('opens the create modal when openCreate handle is invoked', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    // Grab the handle from the first call
    const handle = onActionsReady.mock.calls[0][0] as { openCreate: () => void };
    expect(handle).toBeTruthy();

    // Invoke the create handle (simulates PageContainer New button click)
    handle.openCreate();

    await waitFor(() =>
      expect(screen.getByTestId('port-mapping-create-modal')).toBeInTheDocument(),
    );
    // Should open in create mode (no mapping)
    expect(screen.getByTestId('modal-mapping-name')).toHaveTextContent('create-mode');
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  it('passes onEdit / onDelete / onToggle to PortMappingList when user has manage permission', () => {
    mockHasPermission.mockReturnValue(true);
    renderTab();

    // The stubs expose trigger buttons only when callbacks are passed
    expect(screen.getByTestId('trigger-edit')).toBeInTheDocument();
    expect(screen.getByTestId('trigger-delete')).toBeInTheDocument();
    expect(screen.getByTestId('trigger-toggle')).toBeInTheDocument();
  });

  it('does NOT pass onEdit / onDelete / onToggle to PortMappingList when user lacks manage permission', () => {
    mockHasPermission.mockReturnValue(false);
    renderTab();

    expect(screen.queryByTestId('trigger-edit')).not.toBeInTheDocument();
    expect(screen.queryByTestId('trigger-delete')).not.toBeInTheDocument();
    expect(screen.queryByTestId('trigger-toggle')).not.toBeInTheDocument();
  });

  it('checks the sdwan.port_mappings.manage permission', () => {
    renderTab();
    expect(mockHasPermission).toHaveBeenCalledWith('system.sdwan.port_mappings.manage');
  });

  // ---------------------------------------------------------------------------
  // Edit flow
  // ---------------------------------------------------------------------------

  it('opens PortMappingCreateModal in edit mode when onEdit is triggered', async () => {
    renderTab();

    fireEvent.click(screen.getByTestId('trigger-edit'));

    await waitFor(() =>
      expect(screen.getByTestId('port-mapping-create-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('port-mapping-create-modal')).toHaveAttribute('data-is-edit', 'true');
  });

  it('closes the edit modal when modal calls onClose', async () => {
    renderTab();

    fireEvent.click(screen.getByTestId('trigger-edit'));
    await waitFor(() => expect(screen.getByTestId('port-mapping-create-modal')).toBeInTheDocument());

    fireEvent.click(screen.getByTestId('modal-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('port-mapping-create-modal')).not.toBeInTheDocument(),
    );
  });

  it('closes the modal and fires a success notification after onSaved', async () => {
    renderTab();

    fireEvent.click(screen.getByTestId('trigger-edit'));
    await waitFor(() => expect(screen.getByTestId('port-mapping-create-modal')).toBeInTheDocument());

    fireEvent.click(screen.getByTestId('modal-save'));

    await waitFor(() =>
      expect(screen.queryByTestId('port-mapping-create-modal')).not.toBeInTheDocument(),
    );
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success', message: 'Port mapping saved.' }),
    );
  });

  it('increments refreshKey on PortMappingList after a save', async () => {
    renderTab();

    const listBefore = screen.getByTestId('port-mapping-list');
    const keyBefore = listBefore.getAttribute('data-refresh-key');

    fireEvent.click(screen.getByTestId('trigger-edit'));
    await waitFor(() => expect(screen.getByTestId('port-mapping-create-modal')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('modal-save'));

    await waitFor(() => {
      const keyAfter = screen.getByTestId('port-mapping-list').getAttribute('data-refresh-key');
      expect(Number(keyAfter)).toBeGreaterThan(Number(keyBefore));
    });
  });

  // ---------------------------------------------------------------------------
  // Delete flow
  // ---------------------------------------------------------------------------

  // Helper: returns the dialog element once the delete modal is visible
  async function openDeleteModal() {
    fireEvent.click(screen.getByTestId('trigger-delete'));
    await waitFor(() => expect(screen.getByText('Delete port mapping')).toBeInTheDocument());
    // The Modal renders a role="dialog" element
    return screen.getByRole('dialog');
  }

  it('opens the delete confirm modal when onDelete is triggered', async () => {
    renderTab();

    const dialog = await openDeleteModal();
    expect(within(dialog).getByText(/my-mapping/)).toBeInTheDocument();
    // protocol and listen_port appear as sibling text nodes; use getAllByText with substring matching
    expect(within(dialog).getAllByText(/tcp/).length).toBeGreaterThan(0);
    expect(within(dialog).getAllByText(/5432/).length).toBeGreaterThan(0);
  });

  it('closes the delete modal when Cancel is clicked', async () => {
    renderTab();

    const dialog = await openDeleteModal();
    fireEvent.click(within(dialog).getByRole('button', { name: /cancel/i }));

    await waitFor(() =>
      expect(screen.queryByText('Delete port mapping')).not.toBeInTheDocument(),
    );
  });

  it('calls sdwanApi.deletePortMapping with correct networkId and mappingId on confirm', async () => {
    mockDeletePortMapping.mockResolvedValue(undefined);
    renderTab();

    const dialog = await openDeleteModal();
    fireEvent.click(within(dialog).getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockDeletePortMapping).toHaveBeenCalledWith(NETWORK_ID, 'pm-1'),
    );
  });

  it('shows success notification and closes modal after successful delete', async () => {
    mockDeletePortMapping.mockResolvedValue(undefined);
    renderTab();

    const dialog = await openDeleteModal();
    fireEvent.click(within(dialog).getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: "Port mapping 'my-mapping' deleted." }),
      ),
    );
    await waitFor(() =>
      expect(screen.queryByText('Delete port mapping')).not.toBeInTheDocument(),
    );
  });

  it('increments refreshKey after successful delete', async () => {
    mockDeletePortMapping.mockResolvedValue(undefined);
    renderTab();

    const keyBefore = Number(screen.getByTestId('port-mapping-list').getAttribute('data-refresh-key'));

    const dialog = await openDeleteModal();
    fireEvent.click(within(dialog).getByRole('button', { name: /^delete$/i }));

    await waitFor(() => {
      const keyAfter = Number(screen.getByTestId('port-mapping-list').getAttribute('data-refresh-key'));
      expect(keyAfter).toBeGreaterThan(keyBefore);
    });
  });

  // ---------------------------------------------------------------------------
  // Pending-approval branch (IMP-87ec6f651f07): gated verbs answer 202 with a
  // pending marker — the tab must surface "awaiting approval", never "deleted".
  // ---------------------------------------------------------------------------

  const PENDING = {
    pending: true,
    deferred_operation_id: 'dop-1',
    action_category: 'sdwan.port_mapping_delete',
    approval_request_id: 'ar-1',
    message: 'Approval required: sdwan.port_mapping_delete',
  };

  it('shows a pending-approval notification (not the success toast) when delete is parked for approval', async () => {
    mockDeletePortMapping.mockResolvedValue(PENDING);
    renderTab();

    const dialog = await openDeleteModal();
    fireEvent.click(within(dialog).getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval/i),
        }),
      ),
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' }),
    );
    // The request was accepted — the confirm modal closes either way.
    await waitFor(() =>
      expect(screen.queryByText('Delete port mapping')).not.toBeInTheDocument(),
    );
  });

  it('links the pending-approval notification to the approvals surface and names the mapping', async () => {
    mockDeletePortMapping.mockResolvedValue(PENDING);
    renderTab();

    const dialog = await openDeleteModal();
    fireEvent.click(within(dialog).getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          message: expect.stringContaining('my-mapping'),
          link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
        }),
      ),
    );
  });

  it('shows a pending-approval notification when the enable toggle is parked for approval', async () => {
    mockUpdatePortMapping.mockResolvedValue({ ...PENDING, action_category: 'sdwan.port_mapping_update' });
    renderTab();

    fireEvent.click(screen.getByTestId('trigger-toggle'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval/i),
        }),
      ),
    );
  });

  it('shows an error notification and leaves modal open when delete fails', async () => {
    mockDeletePortMapping.mockRejectedValue(new Error('Network error'));
    renderTab();

    const dialog = await openDeleteModal();
    fireEvent.click(within(dialog).getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Network error' }),
      ),
    );
  });

  it('uses generic error message when delete throws a non-Error rejection', async () => {
    mockDeletePortMapping.mockRejectedValue('oops');
    renderTab();

    const dialog = await openDeleteModal();
    fireEvent.click(within(dialog).getByRole('button', { name: /^delete$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Failed to delete mapping' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Toggle flow
  // ---------------------------------------------------------------------------

  it('calls sdwanApi.updatePortMapping with enabled toggled to false for an enabled mapping', async () => {
    mockUpdatePortMapping.mockResolvedValue({ ...MAPPING_1, enabled: false });
    renderTab();

    fireEvent.click(screen.getByTestId('trigger-toggle'));

    await waitFor(() =>
      expect(mockUpdatePortMapping).toHaveBeenCalledWith(NETWORK_ID, 'pm-1', { enabled: false }),
    );
  });

  it('increments refreshKey after a successful toggle', async () => {
    mockUpdatePortMapping.mockResolvedValue({ ...MAPPING_1, enabled: false });
    renderTab();

    const keyBefore = Number(screen.getByTestId('port-mapping-list').getAttribute('data-refresh-key'));

    fireEvent.click(screen.getByTestId('trigger-toggle'));

    await waitFor(() => {
      const keyAfter = Number(screen.getByTestId('port-mapping-list').getAttribute('data-refresh-key'));
      expect(keyAfter).toBeGreaterThan(keyBefore);
    });
  });

  it('shows an error notification when toggle fails', async () => {
    mockUpdatePortMapping.mockRejectedValue(new Error('Toggle failed'));
    renderTab();

    fireEvent.click(screen.getByTestId('trigger-toggle'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Toggle failed' }),
      ),
    );
  });

  it('uses generic error message when toggle throws a non-Error rejection', async () => {
    mockUpdatePortMapping.mockRejectedValue('boom');
    renderTab();

    fireEvent.click(screen.getByTestId('trigger-toggle'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Failed to toggle mapping' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Create flow (via openCreate handle)
  // ---------------------------------------------------------------------------

  it('opens the create modal in create mode (no mapping prop) via openCreate handle', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    const handle = onActionsReady.mock.calls[0][0] as { openCreate: () => void };
    handle.openCreate();

    await waitFor(() =>
      expect(screen.getByTestId('port-mapping-create-modal')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('port-mapping-create-modal')).toHaveAttribute('data-is-edit', 'false');
    expect(screen.getByTestId('modal-mapping-name')).toHaveTextContent('create-mode');
  });

  it('fires success notification and increments refreshKey after creating a mapping', async () => {
    const onActionsReady = jest.fn();
    renderTab({ onActionsReady });

    const handle = onActionsReady.mock.calls[0][0] as { openCreate: () => void };
    handle.openCreate();

    await waitFor(() => expect(screen.getByTestId('port-mapping-create-modal')).toBeInTheDocument());

    const keyBefore = Number(screen.getByTestId('port-mapping-list').getAttribute('data-refresh-key'));

    fireEvent.click(screen.getByTestId('modal-save'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: 'Port mapping saved.' }),
      ),
    );
    await waitFor(() => {
      const keyAfter = Number(screen.getByTestId('port-mapping-list').getAttribute('data-refresh-key'));
      expect(keyAfter).toBeGreaterThan(keyBefore);
    });
  });
});
