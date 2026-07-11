import React from 'react';
import { render, screen, fireEvent, waitFor, within, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NodeDetailModal } from './NodeDetailModal';

// =============================================================================
// Mocks
// =============================================================================

const mockGetNode = jest.fn();
const mockGetNodeInstances = jest.fn();
const mockGetNodeModules = jest.fn();
const mockGetTasks = jest.fn();
const mockDeleteNodeInstance = jest.fn();
const mockAssociatePublicIp = jest.fn();
const mockDisassociatePublicIp = jest.fn();
const mockDownloadInstanceBootConfig = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getNode: (...args: unknown[]) => mockGetNode(...args),
    getNodeInstances: (...args: unknown[]) => mockGetNodeInstances(...args),
    getNodeModules: (...args: unknown[]) => mockGetNodeModules(...args),
    getTasks: (...args: unknown[]) => mockGetTasks(...args),
    deleteNodeInstance: (...args: unknown[]) => mockDeleteNodeInstance(...args),
    associatePublicIp: (...args: unknown[]) => mockAssociatePublicIp(...args),
    disassociatePublicIp: (...args: unknown[]) => mockDisassociatePublicIp(...args),
    downloadInstanceBootConfig: (...args: unknown[]) => mockDownloadInstanceBootConfig(...args),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => true }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// WebSocket hook — inert stub; tests drive state via API mocks and captured callbacks
let capturedWsOptions: {
  onOperationProgress?: (p: unknown) => void;
  onOperationUpdate?: (p: unknown) => void;
  onInstanceUpdate?: (p: unknown) => void;
  onNodeUpdate?: (p: unknown) => void;
} = {};

jest.mock('@system/features/system/hooks/useSystemWebSocket', () => ({
  useSystemWebSocket: (opts: typeof capturedWsOptions) => {
    capturedWsOptions = opts;
    return {
      isConnected: false,
      error: null,
      refreshOperations: jest.fn(),
      getTask: jest.fn(),
      refreshStats: jest.fn(),
      ping: jest.fn(),
    };
  },
}));

// Child modals — return test-friendly stubs so we can trigger callbacks
jest.mock('./EditNodeModal', () => ({
  EditNodeModal: ({
    isOpen,
    onNodeUpdated,
  }: {
    isOpen: boolean;
    onClose: () => void;
    node: unknown;
    onNodeUpdated?: (n: unknown) => void;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="edit-node-modal">
        <button
          onClick={() =>
            onNodeUpdated?.({
              id: 'node-1',
              name: 'Updated Node',
              enabled: true,
              allocate_public_ip: false,
              config: {},
              created_at: '',
              updated_at: '',
            })
          }
        >
          save-node
        </button>
      </div>
    );
  },
}));

jest.mock('./CreateInstanceModal', () => ({
  CreateInstanceModal: ({
    isOpen,
    onInstanceCreated,
  }: {
    isOpen: boolean;
    onClose: () => void;
    node: unknown;
    onInstanceCreated?: (i: unknown) => void;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="create-instance-modal">
        <button
          onClick={() =>
            onInstanceCreated?.({
              id: 'inst-new',
              name: 'New Instance',
              variety: 'cloud',
              status: 'pending',
              config: {},
              node_id: 'node-1',
              created_at: '',
              updated_at: '',
            })
          }
        >
          create-instance
        </button>
      </div>
    );
  },
}));

jest.mock('./EditInstanceModal', () => ({
  EditInstanceModal: ({
    isOpen,
    onInstanceUpdated,
  }: {
    isOpen: boolean;
    instance: unknown;
    nodeId: string | null;
    onClose: () => void;
    onInstanceUpdated?: (i: unknown) => void;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="edit-instance-modal">
        <button
          onClick={() =>
            onInstanceUpdated?.({
              id: 'inst-1',
              name: 'Updated Instance',
              variety: 'cloud',
              status: 'running',
              config: {},
              node_id: 'node-1',
              created_at: '',
              updated_at: '',
            })
          }
        >
          save-instance
        </button>
      </div>
    );
  },
}));

// NodeInstanceControls — blank stub so we don't need its own deps
jest.mock('./NodeInstanceControls', () => ({
  __esModule: true,
  default: () => null,
}));

// EntityLink — render plain text so tests can assert on it
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { type: string; id: string; label?: string }) => <span>{label}</span>,
}));

// =============================================================================
// Fixtures
// =============================================================================

const NODE = {
  id: 'node-1',
  name: 'prod-cluster',
  description: 'Production cluster',
  enabled: true,
  status: 'running',
  public_address: '1.2.3.4',
  allocate_public_ip: true,
  config: { datacenter: 'us-east' },
  node_template_id: 'tpl-1',
  node_template_name: 'base-template',
  instance_count: 2,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const INSTANCE_CLOUD = {
  id: 'inst-1',
  name: 'web-01',
  variety: 'cloud' as const,
  status: 'running',
  private_ip_address: '10.0.0.1',
  public_ip_address: '5.5.5.5',
  config: {},
  node_id: 'node-1',
  created_at: '2026-01-02T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const INSTANCE_PHYSICAL = {
  id: 'inst-2',
  name: 'baremetal-01',
  variety: 'physical' as const,
  status: 'stopped',
  claimed: false,
  config: {},
  node_id: 'node-1',
  created_at: '2026-01-03T00:00:00Z',
  updated_at: '2026-01-03T00:00:00Z',
};

const INSTANCE_DRIFTED = {
  id: 'inst-3',
  name: 'edge-01',
  variety: 'cloud' as const,
  status: 'running',
  config: {},
  node_id: 'node-1',
  booted_image_git_sha: 'abc123def456789',
  promoted_image_git_sha: 'zzz999yyy888777',
  boot_image_drifted: true,
  created_at: '2026-01-03T00:00:00Z',
  updated_at: '2026-01-03T00:00:00Z',
};

const MODULE = {
  id: 'mod-1',
  name: 'nginx',
  variety: 'config' as const,
  enabled: true,
  public: false,
  priority: 10,
  mask: [],
  file_spec: [],
  reboot_required: false,
  assignments_count: 2,
  dependencies_count: 1,
  dependents_count: 0,
  lock_spec: false,
  latest_version: {
    id: 'ver-1',
    version_number: '1.2.3',
    promotion_state: 'live',
  },
  updated_at: '2026-01-01T00:00:00Z',
};

const TASK_RUNNING = {
  id: 'task-1',
  command: 'deploy',
  status: 'running' as const,
  progress: 45,
  description: 'Deploying application',
  exclusive: false,
  events: [],
  options: {},
  operable_type: 'System::Node',
  operable_id: 'node-1',
  created_at: '2026-01-04T00:00:00Z',
  updated_at: '2026-01-04T00:00:00Z',
};

const TASK_FAILED = {
  id: 'task-2',
  command: 'provision',
  status: 'failed' as const,
  progress: 0,
  error_message: 'Connection refused',
  exclusive: false,
  events: [],
  options: {},
  operable_type: 'System::Node',
  operable_id: 'node-1',
  created_at: '2026-01-05T00:00:00Z',
  updated_at: '2026-01-05T00:00:00Z',
};

const META = {
  current_page: 1,
  per_page: 50,
  total_count: 2,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

// =============================================================================
// Helpers
// =============================================================================

const renderModal = (
  props: Partial<{
    nodeId: string | null;
    isOpen: boolean;
    onClose: () => void;
    onNodeUpdated: () => void;
  }> = {},
) => {
  const defaults = {
    nodeId: 'node-1',
    isOpen: true,
    onClose: jest.fn(),
    onNodeUpdated: jest.fn(),
  };
  return render(
    <BrowserRouter>
      <NodeDetailModal {...defaults} {...props} />
    </BrowserRouter>,
  );
};

const setupDefaultMocks = () => {
  mockGetNode.mockResolvedValue(NODE);
  mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_CLOUD, INSTANCE_PHYSICAL] });
  mockGetNodeModules.mockResolvedValue({ node_modules: [MODULE] });
  mockGetTasks.mockResolvedValue({ tasks: [TASK_RUNNING, TASK_FAILED], meta: META });
};

/**
 * Wait until the modal is fully loaded — node name appears at least once.
 * The name appears both in the modal title h3 AND in the Info tab content,
 * so we use getAllByText to avoid ambiguity.
 */
const waitForModal = () =>
  waitFor(() => {
    const matches = screen.getAllByText('prod-cluster');
    expect(matches.length).toBeGreaterThan(0);
  });

/**
 * Click a tab by its label text using role="tab" queries so the badge
 * numbers included in the accessible name don't cause ambiguity.
 */
const clickTab = (label: string) => {
  const tabs = screen.getAllByRole('tab');
  const found = tabs.find(t => t.textContent?.includes(label));
  if (!found) throw new Error(`Tab not found: ${label}`);
  fireEvent.click(found);
};

// =============================================================================
// Tests
// =============================================================================

describe('NodeDetailModal', () => {
  beforeEach(() => {
    capturedWsOptions = {};
    mockGetNode.mockReset();
    mockGetNodeInstances.mockReset();
    mockGetNodeModules.mockReset();
    mockGetTasks.mockReset();
    mockDeleteNodeInstance.mockReset();
    mockAssociatePublicIp.mockReset();
    mockDisassociatePublicIp.mockReset();
    mockDownloadInstanceBootConfig.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  describe('loading state', () => {
    it('does not show node name while loading', async () => {
      mockGetNode.mockReturnValue(new Promise(() => {}));
      mockGetNodeInstances.mockReturnValue(new Promise(() => {}));
      mockGetNodeModules.mockReturnValue(new Promise(() => {}));
      mockGetTasks.mockReturnValue(new Promise(() => {}));

      renderModal();

      expect(screen.queryByText('Production cluster')).not.toBeInTheDocument();
    });
  });

  describe('closed / null state', () => {
    it('renders nothing meaningful when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(screen.queryByText('prod-cluster')).not.toBeInTheDocument();
    });

    it('renders "Node not found" when API returns null', async () => {
      mockGetNode.mockResolvedValue(null);
      mockGetNodeInstances.mockResolvedValue({ node_instances: [] });
      mockGetNodeModules.mockResolvedValue({ node_modules: [] });
      mockGetTasks.mockResolvedValue({ tasks: [], meta: META });

      renderModal();

      await waitFor(() => expect(screen.getByText('Node not found')).toBeInTheDocument());
    });
  });

  // ---------------------------------------------------------------------------
  // Info tab (default)
  // ---------------------------------------------------------------------------

  describe('info tab (default)', () => {
    it('fetches node with the correct nodeId on mount', async () => {
      setupDefaultMocks();
      renderModal();
      await waitFor(() => expect(mockGetNode).toHaveBeenCalledWith('node-1'));
    });

    it('fetches instances, modules and tasks in parallel', async () => {
      setupDefaultMocks();
      renderModal();
      await waitFor(() => {
        expect(mockGetNodeInstances).toHaveBeenCalledWith('node-1');
        expect(mockGetNodeModules).toHaveBeenCalledWith({ node_id: 'node-1' });
        expect(mockGetTasks).toHaveBeenCalledWith({ per_page: 50 });
      });
    });

    it('renders node name in the modal', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      expect(screen.getAllByText('prod-cluster').length).toBeGreaterThan(0);
    });

    it('renders node description', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      expect(screen.getByText('Production cluster')).toBeInTheDocument();
    });

    it('renders public address', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      expect(screen.getByText('1.2.3.4')).toBeInTheDocument();
    });

    it('renders template name', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      expect(screen.getByText('base-template')).toBeInTheDocument();
    });

    it('renders configuration JSON for non-empty config', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      expect(screen.getByText(/"datacenter"/)).toBeInTheDocument();
    });

    it('renders Running badge for status=running node', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      expect(screen.getAllByText('Running').length).toBeGreaterThan(0);
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling on fetch
  // ---------------------------------------------------------------------------

  describe('error handling', () => {
    it('shows an error notification when getNode rejects', async () => {
      mockGetNode.mockRejectedValue(new Error('Server error'));
      mockGetNodeInstances.mockResolvedValue({ node_instances: [] });
      mockGetNodeModules.mockResolvedValue({ node_modules: [] });
      mockGetTasks.mockResolvedValue({ tasks: [], meta: META });

      renderModal();

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to load node details',
        }),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Instances tab
  // ---------------------------------------------------------------------------

  describe('Instances tab', () => {
    const openInstancesTab = async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      clickTab('Instances');
    };

    it('shows instance names after switching to Instances tab', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());
      expect(screen.getByText('baremetal-01')).toBeInTheDocument();
    });

    it('shows empty state when no instances exist', async () => {
      mockGetNode.mockResolvedValue(NODE);
      mockGetNodeInstances.mockResolvedValue({ node_instances: [] });
      mockGetNodeModules.mockResolvedValue({ node_modules: [] });
      mockGetTasks.mockResolvedValue({ tasks: [], meta: META });

      renderModal();
      await waitForModal();
      clickTab('Instances');

      await waitFor(() => expect(screen.getByText('No instances found')).toBeInTheDocument());
    });

    it('shows "Add Instance" button when canCreateInstances', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('Add Instance')).toBeInTheDocument());
    });

    it('opens CreateInstanceModal when "Add Instance" is clicked', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('Add Instance')).toBeInTheDocument());
      fireEvent.click(screen.getByText('Add Instance'));
      expect(screen.getByTestId('create-instance-modal')).toBeInTheDocument();
    });

    it('adds new instance to list when onInstanceCreated fires', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('Add Instance')).toBeInTheDocument());
      fireEvent.click(screen.getByText('Add Instance'));
      const createModal = screen.getByTestId('create-instance-modal');
      fireEvent.click(within(createModal).getByText('create-instance'));

      await waitFor(() => expect(screen.getByText('New Instance')).toBeInTheDocument());
      expect(screen.queryByTestId('create-instance-modal')).not.toBeInTheDocument();
    });

    it('expands instance row on click to reveal network details', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());

      const expandBtn = screen.getByText('web-01').closest('button');
      expect(expandBtn).not.toBeNull();
      fireEvent.click(expandBtn!);

      await waitFor(() => expect(screen.getByText('10.0.0.1')).toBeInTheDocument());
    });

    it('does not show a boot-image-drift badge for instances without drift', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());
      expect(screen.queryByText('Boot image outdated')).not.toBeInTheDocument();
    });

    it('shows a boot-image-drift badge when boot_image_drifted is true', async () => {
      mockGetNode.mockResolvedValue(NODE);
      mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_CLOUD, INSTANCE_DRIFTED] });
      mockGetNodeModules.mockResolvedValue({ node_modules: [] });
      mockGetTasks.mockResolvedValue({ tasks: [], meta: META });

      renderModal();
      await waitForModal();
      clickTab('Instances');

      await waitFor(() => expect(screen.getByText('edge-01')).toBeInTheDocument());
      expect(screen.getByText('Boot image outdated')).toBeInTheDocument();
    });

    it('shows Download button for unclaimed physical instance', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('baremetal-01')).toBeInTheDocument());

      const downloadBtns = screen.getAllByTitle(/Download claim-by-ID/i);
      expect(downloadBtns.length).toBeGreaterThan(0);
    });

    it('calls downloadInstanceBootConfig when Download button is clicked', async () => {
      mockDownloadInstanceBootConfig.mockResolvedValue(undefined);
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('baremetal-01')).toBeInTheDocument());

      fireEvent.click(screen.getByTitle(/Download claim-by-ID/i));

      await waitFor(() =>
        expect(mockDownloadInstanceBootConfig).toHaveBeenCalledWith('node-1', 'inst-2'),
      );
    });

    it('shows success notification after boot config download', async () => {
      mockDownloadInstanceBootConfig.mockResolvedValue(undefined);
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('baremetal-01')).toBeInTheDocument());

      fireEvent.click(screen.getByTitle(/Download claim-by-ID/i));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('baremetal-01'),
          }),
        ),
      );
    });

    it('shows error notification when boot config download fails', async () => {
      mockDownloadInstanceBootConfig.mockRejectedValue(new Error('Download failed'));
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('baremetal-01')).toBeInTheDocument());

      fireEvent.click(screen.getByTitle(/Download claim-by-ID/i));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Download failed',
        }),
      );
    });

    it('opens EditInstanceModal when edit button is clicked', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());

      fireEvent.click(screen.getAllByTitle('Edit Instance')[0]);

      expect(screen.getByTestId('edit-instance-modal')).toBeInTheDocument();
    });

    it('updates instance in list when EditInstanceModal fires onInstanceUpdated', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());

      fireEvent.click(screen.getAllByTitle('Edit Instance')[0]);
      const editModal = screen.getByTestId('edit-instance-modal');
      fireEvent.click(within(editModal).getByText('save-instance'));

      await waitFor(() => expect(screen.getByText('Updated Instance')).toBeInTheDocument());
      expect(screen.queryByTestId('edit-instance-modal')).not.toBeInTheDocument();
    });

    it('opens delete confirmation when trash button is clicked', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());

      fireEvent.click(screen.getAllByTitle('Delete Instance')[0]);

      await waitFor(() =>
        expect(screen.getByText(/Are you sure you want to delete/)).toBeInTheDocument(),
      );
    });

    it('calls deleteNodeInstance and removes the instance from the list on confirm', async () => {
      mockDeleteNodeInstance.mockResolvedValue(undefined);
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());

      fireEvent.click(screen.getAllByTitle('Delete Instance')[0]);
      await waitFor(() =>
        expect(screen.getByText(/Are you sure you want to delete/)).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /^delete$/i }));

      await waitFor(() =>
        expect(mockDeleteNodeInstance).toHaveBeenCalledWith('node-1', 'inst-1'),
      );
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'success', message: expect.stringContaining('web-01') }),
        ),
      );
    });

    it('cancels delete dialog without deleting when Cancel is clicked', async () => {
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());

      fireEvent.click(screen.getAllByTitle('Delete Instance')[0]);
      await waitFor(() =>
        expect(screen.getByText(/Are you sure you want to delete/)).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

      expect(screen.queryByText(/Are you sure you want to delete/)).not.toBeInTheDocument();
      expect(mockDeleteNodeInstance).not.toHaveBeenCalled();
    });

    it('shows error notification when deleteNodeInstance fails', async () => {
      mockDeleteNodeInstance.mockRejectedValue(new Error('Delete failed'));
      await openInstancesTab();
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());

      fireEvent.click(screen.getAllByTitle('Delete Instance')[0]);
      await waitFor(() =>
        expect(screen.getByText(/Are you sure you want to delete/)).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /^delete$/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Delete failed',
        }),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // IP associate / disassociate (cloud instance expanded)
  // ---------------------------------------------------------------------------

  describe('IP actions', () => {
    const expandCloudInstance = async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      clickTab('Instances');
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());
      // Expand web-01 row to reveal network section
      const expandBtn = screen.getByText('web-01').closest('button');
      fireEvent.click(expandBtn!);
      await waitFor(() => expect(screen.getByText('10.0.0.1')).toBeInTheDocument());
    };

    it('shows disassociate button for cloud instance with public IP', async () => {
      await expandCloudInstance();
      expect(screen.getByTitle('Release public IP')).toBeInTheDocument();
    });

    it('arms disassociate on first click (shows Confirm?)', async () => {
      await expandCloudInstance();
      fireEvent.click(screen.getByTitle('Release public IP'));
      await waitFor(() =>
        expect(screen.getByTitle('Click again to confirm release')).toBeInTheDocument(),
      );
    });

    it('calls disassociatePublicIp on second click after arming', async () => {
      mockDisassociatePublicIp.mockResolvedValue(INSTANCE_CLOUD);
      await expandCloudInstance();

      // First click — arm
      fireEvent.click(screen.getByTitle('Release public IP'));
      await waitFor(() =>
        expect(screen.getByTitle('Click again to confirm release')).toBeInTheDocument(),
      );

      // Second click — fire
      fireEvent.click(screen.getByTitle('Click again to confirm release'));

      await waitFor(() =>
        expect(mockDisassociatePublicIp).toHaveBeenCalledWith('node-1', 'inst-1'),
      );
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'success', message: expect.stringContaining('web-01') }),
        ),
      );
    });

    it('shows associate button for cloud instance WITHOUT public IP', async () => {
      const instanceNoIp = {
        ...INSTANCE_CLOUD,
        id: 'inst-3',
        name: 'cloud-no-ip',
        public_ip_address: undefined,
      };
      mockGetNode.mockResolvedValue(NODE);
      mockGetNodeInstances.mockResolvedValue({ node_instances: [instanceNoIp] });
      mockGetNodeModules.mockResolvedValue({ node_modules: [] });
      mockGetTasks.mockResolvedValue({ tasks: [], meta: META });

      renderModal();
      await waitForModal();
      clickTab('Instances');
      await waitFor(() => expect(screen.getByText('cloud-no-ip')).toBeInTheDocument());

      // Expand row
      fireEvent.click(screen.getByText('cloud-no-ip').closest('button')!);

      await waitFor(() =>
        expect(screen.getByText('Associate Public IP')).toBeInTheDocument(),
      );
    });

    it('calls associatePublicIp when Associate button is clicked', async () => {
      mockAssociatePublicIp.mockResolvedValue({
        ...INSTANCE_CLOUD,
        public_ip_address: '9.9.9.9',
      });
      const instanceNoIp = {
        ...INSTANCE_CLOUD,
        id: 'inst-3',
        name: 'cloud-no-ip',
        public_ip_address: undefined,
      };
      mockGetNode.mockResolvedValue(NODE);
      mockGetNodeInstances.mockResolvedValue({ node_instances: [instanceNoIp] });
      mockGetNodeModules.mockResolvedValue({ node_modules: [] });
      mockGetTasks.mockResolvedValue({ tasks: [], meta: META });

      renderModal();
      await waitForModal();
      clickTab('Instances');
      await waitFor(() => expect(screen.getByText('cloud-no-ip')).toBeInTheDocument());
      fireEvent.click(screen.getByText('cloud-no-ip').closest('button')!);

      await waitFor(() => expect(screen.getByText('Associate Public IP')).toBeInTheDocument());
      fireEvent.click(screen.getByText('Associate Public IP'));

      await waitFor(() =>
        expect(mockAssociatePublicIp).toHaveBeenCalledWith('node-1', 'inst-3'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Modules tab
  // ---------------------------------------------------------------------------

  describe('Modules tab', () => {
    const openModulesTab = async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      clickTab('Modules');
    };

    it('shows module name in the list', async () => {
      await openModulesTab();
      await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
    });

    it('shows empty state when no modules are assigned', async () => {
      mockGetNode.mockResolvedValue(NODE);
      mockGetNodeInstances.mockResolvedValue({ node_instances: [] });
      mockGetNodeModules.mockResolvedValue({ node_modules: [] });
      mockGetTasks.mockResolvedValue({ tasks: [], meta: META });

      renderModal();
      await waitForModal();
      clickTab('Modules');

      await waitFor(() => expect(screen.getByText('No modules assigned')).toBeInTheDocument());
    });

    it('expands module row to show version metadata on click', async () => {
      await openModulesTab();
      await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());

      fireEvent.click(screen.getByText('nginx').closest('button')!);

      await waitFor(() => expect(screen.getByText('Priority')).toBeInTheDocument());
      expect(screen.getAllByText('v1.2.3').length).toBeGreaterThan(0);
    });

    it('shows assignment counts in expanded module', async () => {
      await openModulesTab();
      await waitFor(() => expect(screen.getByText('nginx')).toBeInTheDocument());
      fireEvent.click(screen.getByText('nginx').closest('button')!);

      // The counts row renders the number in a <span> and the label as sibling text,
      // so the regex cannot match across element boundaries — query the parent span.
      await waitFor(() => {
        const el = screen.getByText((content, element) => {
          return element?.tagName.toLowerCase() === 'span' &&
            (element?.textContent ?? '').replace(/\s+/g, ' ').includes('2 assignment');
        });
        expect(el).toBeInTheDocument();
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Operations tab
  // ---------------------------------------------------------------------------

  describe('Operations tab', () => {
    const openOperationsTab = async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      clickTab('Operations');
    };

    it('filters tasks to only those belonging to this node', async () => {
      const otherTask = {
        ...TASK_RUNNING,
        id: 'task-other',
        command: 'other-cmd',
        operable_id: 'node-99',
      };
      mockGetNode.mockResolvedValue(NODE);
      mockGetNodeInstances.mockResolvedValue({ node_instances: [] });
      mockGetNodeModules.mockResolvedValue({ node_modules: [] });
      mockGetTasks.mockResolvedValue({ tasks: [TASK_RUNNING, otherTask], meta: META });

      renderModal();
      await waitForModal();
      clickTab('Operations');

      await waitFor(() => expect(screen.getByText('deploy')).toBeInTheDocument());
      expect(screen.queryByText('other-cmd')).not.toBeInTheDocument();
    });

    it('shows running operation with progress bar', async () => {
      await openOperationsTab();
      await waitFor(() => expect(screen.getByText('deploy')).toBeInTheDocument());
      expect(screen.getByText('45%')).toBeInTheDocument();
    });

    it('shows failed operation with error message', async () => {
      await openOperationsTab();
      await waitFor(() => expect(screen.getByText('provision')).toBeInTheDocument());
      expect(screen.getByText('Connection refused')).toBeInTheDocument();
    });

    it('shows empty state when no operations exist', async () => {
      mockGetNode.mockResolvedValue(NODE);
      mockGetNodeInstances.mockResolvedValue({ node_instances: [] });
      mockGetNodeModules.mockResolvedValue({ node_modules: [] });
      mockGetTasks.mockResolvedValue({ tasks: [], meta: META });

      renderModal();
      await waitForModal();
      clickTab('Operations');

      await waitFor(() => expect(screen.getByText('No operations found')).toBeInTheDocument());
    });
  });

  // ---------------------------------------------------------------------------
  // Edit node
  // ---------------------------------------------------------------------------

  describe('Edit Node button', () => {
    it('opens EditNodeModal when "Edit Node" button is clicked', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();

      fireEvent.click(screen.getByRole('button', { name: /edit node/i }));
      expect(screen.getByTestId('edit-node-modal')).toBeInTheDocument();
    });

    it('updates node name when EditNodeModal fires onNodeUpdated', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();

      fireEvent.click(screen.getByRole('button', { name: /edit node/i }));
      const editModal = screen.getByTestId('edit-node-modal');
      fireEvent.click(within(editModal).getByText('save-node'));

      await waitFor(() => expect(screen.getAllByText('Updated Node').length).toBeGreaterThan(0));
      expect(screen.queryByTestId('edit-node-modal')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Close button
  // ---------------------------------------------------------------------------

  describe('Close button', () => {
    it('calls onClose when the Close button is clicked', async () => {
      setupDefaultMocks();
      const onClose = jest.fn();
      renderModal({ onClose });
      await waitForModal();

      // The modal has two "close" affordances: the X icon ("Close modal") and
      // the footer "Close" text button. Click the footer button by its exact text.
      fireEvent.click(screen.getByRole('button', { name: /^close$/i }));
      expect(onClose).toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Copy to clipboard
  // ---------------------------------------------------------------------------

  describe('Copy to clipboard', () => {
    it('copies public address to clipboard when copy button is clicked', async () => {
      const writeText = jest.fn().mockResolvedValue(undefined);
      Object.assign(navigator, { clipboard: { writeText } });

      setupDefaultMocks();
      renderModal();
      await waitForModal();

      fireEvent.click(screen.getByTitle('Copy address'));

      await waitFor(() => expect(writeText).toHaveBeenCalledWith('1.2.3.4'));
    });

    it('shows error notification when clipboard write fails', async () => {
      Object.assign(navigator, {
        clipboard: {
          writeText: jest.fn().mockRejectedValue(new Error('Clipboard denied')),
        },
      });

      setupDefaultMocks();
      renderModal();
      await waitForModal();

      fireEvent.click(screen.getByTitle('Copy address'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to copy to clipboard',
        }),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // WebSocket real-time updates
  // ---------------------------------------------------------------------------

  describe('WebSocket real-time updates', () => {
    it('updates operation progress via onOperationProgress', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      clickTab('Operations');
      await waitFor(() => expect(screen.getByText('45%')).toBeInTheDocument());

      act(() => {
        capturedWsOptions.onOperationProgress?.({
          operation_id: 'task-1',
          status: 'running',
          progress: 80,
          description: 'Almost done',
        });
      });

      await waitFor(() => expect(screen.getByText('80%')).toBeInTheDocument());
    });

    it('adds a new node-scoped operation via onOperationUpdate', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      clickTab('Operations');
      await waitFor(() => expect(screen.getByText('deploy')).toBeInTheDocument());

      act(() => {
        capturedWsOptions.onOperationUpdate?.({
          id: 'task-new',
          command: 'rollback',
          status: 'pending',
          progress: 0,
          operable_type: 'System::Node',
          operable_id: 'node-1',
          created_at: '2026-01-06T00:00:00Z',
          updated_at: '2026-01-06T00:00:00Z',
        });
      });

      await waitFor(() => expect(screen.getByText('rollback')).toBeInTheDocument());
    });

    it('does NOT add an operation via onOperationUpdate for a different node', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      clickTab('Operations');
      await waitFor(() => expect(screen.getByText('deploy')).toBeInTheDocument());

      act(() => {
        capturedWsOptions.onOperationUpdate?.({
          id: 'task-foreign',
          command: 'foreign-cmd',
          status: 'pending',
          progress: 0,
          operable_type: 'System::Node',
          operable_id: 'node-99',
          created_at: '2026-01-06T00:00:00Z',
          updated_at: '2026-01-06T00:00:00Z',
        });
      });

      // Give React a tick to process and confirm it never appears
      await waitFor(() => expect(screen.queryByText('foreign-cmd')).not.toBeInTheDocument());
    });

    it('updates instance status via onInstanceUpdate when node_id matches', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      clickTab('Instances');
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());

      act(() => {
        capturedWsOptions.onInstanceUpdate?.({
          id: 'inst-1',
          name: 'web-01',
          status: 'stopped',
          variety: 'cloud',
          node_id: 'node-1',
          created_at: '2026-01-02T00:00:00Z',
          updated_at: '2026-01-02T01:00:00Z',
        });
      });

      // INSTANCE_PHYSICAL already shows "Stopped". After the WS update,
      // INSTANCE_CLOUD (web-01) also becomes "Stopped" so we expect at least 2.
      await waitFor(() => expect(screen.getAllByText('Stopped').length).toBeGreaterThanOrEqual(2));
    });

    it('ignores onInstanceUpdate when node_id does not match', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();
      clickTab('Instances');
      await waitFor(() => expect(screen.getByText('web-01')).toBeInTheDocument());

      act(() => {
        capturedWsOptions.onInstanceUpdate?.({
          id: 'inst-1',
          name: 'web-01',
          status: 'terminated',
          variety: 'cloud',
          node_id: 'node-99',
          created_at: '2026-01-02T00:00:00Z',
          updated_at: '2026-01-02T01:00:00Z',
        });
      });

      // Running should still be there; Terminated should not appear
      await waitFor(() => expect(screen.getAllByText('Running').length).toBeGreaterThan(0));
      expect(screen.queryByText('Terminated')).not.toBeInTheDocument();
    });

    it('updates node name via onNodeUpdate when id matches', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();

      act(() => {
        capturedWsOptions.onNodeUpdate?.({
          id: 'node-1',
          name: 'prod-cluster-v2',
          enabled: true,
          instances_count: 3,
          created_at: '2026-01-01T00:00:00Z',
          updated_at: '2026-01-01T01:00:00Z',
        });
      });

      await waitFor(() =>
        expect(screen.getAllByText('prod-cluster-v2').length).toBeGreaterThan(0),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Tab badge counts
  // ---------------------------------------------------------------------------

  describe('tab badge counts', () => {
    it('shows instance count badge on Instances tab', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();

      // Two instances — badge "2" should appear somewhere in the tab area
      await waitFor(() => {
        const badges = screen.getAllByText('2');
        expect(badges.length).toBeGreaterThan(0);
      });
    });

    it('shows active operation badge for running operations', async () => {
      setupDefaultMocks();
      renderModal();
      await waitForModal();

      // TASK_RUNNING is 'running' → badge count 1
      await waitFor(() => {
        const badges = screen.getAllByText('1');
        expect(badges.length).toBeGreaterThan(0);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Re-fetch when modal reopens
  // ---------------------------------------------------------------------------

  describe('re-fetch when modal reopens', () => {
    it('fetches fresh data when isOpen transitions from false to true', async () => {
      setupDefaultMocks();
      const { rerender } = renderModal({ isOpen: false });

      rerender(
        <BrowserRouter>
          <NodeDetailModal nodeId="node-1" isOpen onClose={jest.fn()} />
        </BrowserRouter>,
      );

      await waitFor(() => expect(mockGetNode).toHaveBeenCalledWith('node-1'));
    });
  });
});
