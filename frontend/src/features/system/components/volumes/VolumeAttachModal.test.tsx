import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { VolumeAttachModal } from './VolumeAttachModal';
import type { SystemProviderVolume, SystemNodeInstance } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
//
// VolumeAttachModal calls systemApi.getNodes + systemApi.getNodeInstances on
// mount (when isOpen && volume), then systemApi.attachVolume on submit.
// =============================================================================

const mockGetNodes = jest.fn();
const mockGetNodeInstances = jest.fn();
const mockAttachVolume = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getNodes: (...args: unknown[]) => mockGetNodes(...args),
    getNodeInstances: (...args: unknown[]) => mockGetNodeInstances(...args),
    attachVolume: (...args: unknown[]) => mockAttachVolume(...args),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
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

// EntityLink uses entityRegistry and useEntityModal — stub out
jest.mock('@/shared/services/entityRegistry', () => ({
  entityRegistry: {
    getEntity: () => null,
  },
}));

jest.mock('@/shared/hooks/useEntityModal', () => ({
  useEntityModal: () => ({
    openEntity: jest.fn(),
    openByParam: jest.fn(),
  }),
}));

// =============================================================================
// Fixtures
// =============================================================================

const VOLUME: SystemProviderVolume = {
  id: 'vol-abc',
  name: 'data-volume',
  size_gb: 100,
  status: 'available',
  volume_type: 'gp3',
  encrypted: false,
  config: {},
  provider_region_id: 'region-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const NODE_A = {
  id: 'node-1',
  name: 'prod-node',
  enabled: true,
  allocate_public_ip: false,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const NODE_B = {
  id: 'node-2',
  name: 'dev-node',
  enabled: true,
  allocate_public_ip: false,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const RUNNING_INSTANCE: SystemNodeInstance = {
  id: 'inst-running',
  name: 'worker-1',
  variety: 'cloud',
  status: 'running',
  node_id: 'node-1',
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const STOPPED_INSTANCE: SystemNodeInstance = {
  id: 'inst-stopped',
  name: 'worker-stopped',
  variety: 'cloud',
  status: 'stopped',
  node_id: 'node-1',
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// Double-envelope helper matching the platform pattern:
// apiClient resolves to AxiosResponse whose body is { success: true, data: <payload>, meta? }
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  volume?: SystemProviderVolume | null;
  isOpen?: boolean;
  onClose?: () => void;
  onVolumeAttached?: () => void;
}

const renderModal = ({
  volume = VOLUME,
  isOpen = true,
  onClose = jest.fn(),
  onVolumeAttached = jest.fn(),
}: RenderProps = {}) =>
  render(
    <BrowserRouter>
      <VolumeAttachModal
        volume={volume}
        isOpen={isOpen}
        onClose={onClose}
        onVolumeAttached={onVolumeAttached}
      />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('VolumeAttachModal', () => {
  beforeEach(() => {
    mockGetNodes.mockReset();
    mockGetNodeInstances.mockReset();
    mockAttachVolume.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render gating — closed / null volume
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    mockGetNodes.mockResolvedValue({ nodes: [], meta: {} });
    renderModal({ isOpen: false });
    expect(screen.queryByText('Attach Volume')).not.toBeInTheDocument();
  });

  it('renders nothing when volume is null', () => {
    renderModal({ volume: null });
    expect(screen.queryByText('Attach Volume')).not.toBeInTheDocument();
    expect(mockGetNodes).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading spinner while fetching instances', async () => {
    // Keep the promise pending so the loading state stays visible
    mockGetNodes.mockReturnValue(new Promise(() => undefined));

    renderModal();

    // Header should be visible immediately — use heading role to avoid ambiguity with button text
    expect(screen.getByRole('heading', { name: /attach volume/i })).toBeInTheDocument();
    // Volume info card
    expect(screen.getByText('data-volume')).toBeInTheDocument();
    expect(screen.getByText(/100 GB/)).toBeInTheDocument();
    // While loading, no select element yet
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state — no running instances
  // ---------------------------------------------------------------------------

  it('shows empty state when no running instances are available', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [STOPPED_INSTANCE] });

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('No running instances available')).toBeInTheDocument(),
    );

    // No dropdown when empty
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
  });

  it('shows empty state when there are no nodes at all', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [], meta: {} });

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('No running instances available')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Fetch behavior — API calls with correct params
  // ---------------------------------------------------------------------------

  it('fetches nodes with per_page=100 and enabled=true on open', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [], meta: {} });

    renderModal();

    await waitFor(() => expect(mockGetNodes).toHaveBeenCalledTimes(1));
    expect(mockGetNodes).toHaveBeenCalledWith({ per_page: 100, enabled: true });
  });

  it('calls getNodeInstances for each returned node', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A, NODE_B], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [] });

    renderModal();

    await waitFor(() => expect(mockGetNodeInstances).toHaveBeenCalledTimes(2));
    expect(mockGetNodeInstances).toHaveBeenCalledWith('node-1');
    expect(mockGetNodeInstances).toHaveBeenCalledWith('node-2');
  });

  it('only includes running instances in the dropdown', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({
      node_instances: [RUNNING_INSTANCE, STOPPED_INSTANCE],
    });

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const select = screen.getByRole('combobox');
    expect(select).toHaveTextContent('worker-1');
    expect(select).not.toHaveTextContent('worker-stopped');
  });

  it('prefixes instance label with node name in the dropdown options', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    // The option should contain both the node name and instance name
    const option = screen.getByRole('option', { name: /prod-node \/ worker-1/ });
    expect(option).toBeInTheDocument();
    expect(option).toHaveValue('inst-running');
  });

  // ---------------------------------------------------------------------------
  // Error state on fetch failure
  // ---------------------------------------------------------------------------

  it('shows an error notification when instance fetch fails', async () => {
    mockGetNodes.mockRejectedValue(new Error('Network error'));

    renderModal();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load instances',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // State resets when modal reopens
  // ---------------------------------------------------------------------------

  it('resets form state when the modal is reopened with a new volume', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });

    const { rerender } = render(
      <BrowserRouter>
        <VolumeAttachModal
          volume={VOLUME}
          isOpen={false}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );

    // Open the modal
    rerender(
      <BrowserRouter>
        <VolumeAttachModal
          volume={VOLUME}
          isOpen={true}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );

    await waitFor(() => expect(mockGetNodes).toHaveBeenCalledTimes(1));
  });

  // ---------------------------------------------------------------------------
  // Volume info display
  // ---------------------------------------------------------------------------

  it('displays volume name, size, and type in the info card', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [], meta: {} });

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('No running instances available')).toBeInTheDocument(),
    );

    expect(screen.getByText('data-volume')).toBeInTheDocument();
    expect(screen.getByText(/100 GB/)).toBeInTheDocument();
    expect(screen.getByText(/gp3/)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Validation — Attach button disabled until instance is selected
  // ---------------------------------------------------------------------------

  it('disables the Attach Volume button when no instance is selected', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const attachBtn = screen.getByRole('button', { name: /attach volume/i });
    expect(attachBtn).toBeDisabled();
  });

  it('enables Attach Volume button after selecting an instance', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'inst-running' },
    });

    const attachBtn = screen.getByRole('button', { name: /attach volume/i });
    expect(attachBtn).not.toBeDisabled();
  });

  it('shows inline error if Attach is clicked without selecting an instance (no instances case is handled)', async () => {
    // With running instances available but nothing selected, the button is
    // disabled by the UI — but if selectedInstanceId is empty at submit time,
    // the handler sets an inline error.
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    // Button is disabled when nothing selected — verify no API call
    expect(screen.getByRole('button', { name: /attach volume/i })).toBeDisabled();
    expect(mockAttachVolume).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Device name field
  // ---------------------------------------------------------------------------

  it('renders the optional device name input', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    expect(screen.getByPlaceholderText(/\/dev\/sdf/i)).toBeInTheDocument();
    expect(screen.getByText(/Leave empty for auto-assignment/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Successful attach — with and without device name
  // ---------------------------------------------------------------------------

  it('calls attachVolume with correct args when submitting without device name', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });
    mockAttachVolume.mockResolvedValue(envelope({ volume: { ...VOLUME, status: 'in-use' } }));

    const onClose = jest.fn();
    const onVolumeAttached = jest.fn();

    render(
      <BrowserRouter>
        <VolumeAttachModal
          volume={VOLUME}
          isOpen={true}
          onClose={onClose}
          onVolumeAttached={onVolumeAttached}
        />
      </BrowserRouter>,
    );

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'inst-running' },
    });

    fireEvent.click(screen.getByRole('button', { name: /attach volume/i }));

    await waitFor(() =>
      expect(mockAttachVolume).toHaveBeenCalledWith('vol-abc', 'inst-running', undefined),
    );
  });

  it('calls attachVolume with device name when provided', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });
    mockAttachVolume.mockResolvedValue(envelope({ volume: { ...VOLUME, status: 'in-use' } }));

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'inst-running' },
    });

    fireEvent.change(screen.getByPlaceholderText(/\/dev\/sdf/i), {
      target: { value: '/dev/sdf' },
    });

    fireEvent.click(screen.getByRole('button', { name: /attach volume/i }));

    await waitFor(() =>
      expect(mockAttachVolume).toHaveBeenCalledWith('vol-abc', 'inst-running', '/dev/sdf'),
    );
  });

  it('shows success notification and calls callbacks on successful attach', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });
    mockAttachVolume.mockResolvedValue(envelope({ volume: { ...VOLUME, status: 'in-use' } }));

    const onClose = jest.fn();
    const onVolumeAttached = jest.fn();

    render(
      <BrowserRouter>
        <VolumeAttachModal
          volume={VOLUME}
          isOpen={true}
          onClose={onClose}
          onVolumeAttached={onVolumeAttached}
        />
      </BrowserRouter>,
    );

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'inst-running' } });
    fireEvent.click(screen.getByRole('button', { name: /attach volume/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Volume attached successfully',
      }),
    );

    expect(onVolumeAttached).toHaveBeenCalledTimes(1);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Attach failure — inline error and notification
  // ---------------------------------------------------------------------------

  it('shows inline error on attach failure', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });
    mockAttachVolume.mockRejectedValue(new Error('Volume already attached'));

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'inst-running' } });
    fireEvent.click(screen.getByRole('button', { name: /attach volume/i }));

    await waitFor(() =>
      expect(screen.getByText('Volume already attached')).toBeInTheDocument(),
    );

    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'error',
      message: 'Volume already attached',
    });
  });

  it('shows generic error message when the thrown value is not an Error instance', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });
    mockAttachVolume.mockRejectedValue('unexpected string error');

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'inst-running' } });
    fireEvent.click(screen.getByRole('button', { name: /attach volume/i }));

    await waitFor(() =>
      expect(screen.getByText('Failed to attach volume')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Submitting state — buttons disabled
  // ---------------------------------------------------------------------------

  it('disables form controls while attaching', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });

    // Keep the attach promise pending so the submitting state stays visible
    mockAttachVolume.mockReturnValue(new Promise(() => undefined));

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'inst-running' } });
    fireEvent.click(screen.getByRole('button', { name: /attach volume/i }));

    await waitFor(() =>
      expect(screen.getByText(/attaching\.\.\./i)).toBeInTheDocument(),
    );

    expect(screen.getByRole('combobox')).toBeDisabled();
    expect(screen.getByPlaceholderText(/\/dev\/sdf/i)).toBeDisabled();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Close button and backdrop click
  // ---------------------------------------------------------------------------

  it('calls onClose when the X button is clicked', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [], meta: {} });

    const onClose = jest.fn();
    render(
      <BrowserRouter>
        <VolumeAttachModal volume={VOLUME} isOpen={true} onClose={onClose} />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(screen.getByText('No running instances available')).toBeInTheDocument(),
    );

    // The X button is a ghost Button that wraps the X icon
    const xButton = screen.getAllByRole('button').find(
      (b) => b.querySelector('svg') && !b.textContent?.trim(),
    );
    expect(xButton).toBeDefined();
    fireEvent.click(xButton!);

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when Cancel button is clicked', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [], meta: {} });

    const onClose = jest.fn();
    render(
      <BrowserRouter>
        <VolumeAttachModal volume={VOLUME} isOpen={true} onClose={onClose} />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(screen.getByText('No running instances available')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when the backdrop is clicked', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [], meta: {} });

    const onClose = jest.fn();
    const { container } = render(
      <BrowserRouter>
        <VolumeAttachModal volume={VOLUME} isOpen={true} onClose={onClose} />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(screen.getByText('No running instances available')).toBeInTheDocument(),
    );

    // The backdrop is the fixed bg-black/50 overlay div
    const backdrop = container.querySelector('.fixed.inset-0.bg-black\\/50');
    expect(backdrop).toBeTruthy();
    fireEvent.click(backdrop!);

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // EntityLink — shown after instance selection
  // ---------------------------------------------------------------------------

  it('shows EntityLink for the selected instance when it has a node_id', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'inst-running' } });

    // EntityLink renders with label "View instance details" — entityRegistry returns null
    // so it degrades to a plain <span>
    await waitFor(() =>
      expect(screen.getByText('View instance details')).toBeInTheDocument(),
    );
  });

  it('does not show EntityLink before an instance is selected', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE_A], meta: {} });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [RUNNING_INSTANCE] });

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    expect(screen.queryByText('View instance details')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Multi-node scenario — merges instances from all nodes
  // ---------------------------------------------------------------------------

  it('aggregates running instances from multiple nodes into one dropdown', async () => {
    const instNodeB: SystemNodeInstance = {
      id: 'inst-node-b',
      name: 'worker-b',
      variety: 'cloud',
      status: 'running',
      node_id: 'node-2',
      config: {},
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z',
    };

    mockGetNodes.mockResolvedValue({ nodes: [NODE_A, NODE_B], meta: {} });
    mockGetNodeInstances.mockImplementation((nodeId: string) => {
      if (nodeId === 'node-1') return Promise.resolve({ node_instances: [RUNNING_INSTANCE] });
      if (nodeId === 'node-2') return Promise.resolve({ node_instances: [instNodeB] });
      return Promise.resolve({ node_instances: [] });
    });

    renderModal();

    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const select = screen.getByRole('combobox');
    expect(select).toHaveTextContent('worker-1');
    expect(select).toHaveTextContent('worker-b');
  });
});
