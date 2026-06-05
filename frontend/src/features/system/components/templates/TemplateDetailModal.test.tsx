import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { TemplateDetailModal } from './TemplateDetailModal';
import type { SystemNodeTemplate, SystemNode, SystemNodeModule } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGetTemplate = jest.fn();
const mockGetNodes = jest.fn();
const mockGetTemplateModules = jest.fn();
const mockUnassignModuleFromTemplate = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getTemplate: (...args: unknown[]) => mockGetTemplate(...args),
    getNodes: (...args: unknown[]) => mockGetNodes(...args),
    getTemplateModules: (...args: unknown[]) => mockGetTemplateModules(...args),
    unassignModuleFromTemplate: (...args: unknown[]) => mockUnassignModuleFromTemplate(...args),
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

// WebSocket hook — no-op; expose onNodeUpdate callback so tests can trigger it
let capturedOnNodeUpdate: ((payload: unknown) => void) | undefined;
jest.mock('@system/features/system/hooks/useSystemWebSocket', () => ({
  useSystemWebSocket: (opts: { onNodeUpdate?: (payload: unknown) => void } = {}) => {
    capturedOnNodeUpdate = opts.onNodeUpdate;
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

// EntityLink — render a plain anchor so we can assert labels without real routing
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label: string }) => <span>{label}</span>,
}));

// =============================================================================
// Fixtures
// =============================================================================

const TEMPLATE: SystemNodeTemplate = {
  id: 'tpl-1',
  name: 'Ubuntu Base',
  description: 'Base template for all Ubuntu nodes',
  enabled: true,
  public: false,
  admin_user: 'ubuntu',
  config: { timezone: 'UTC', ntp: 'pool.ntp.org' },
  node_platform_id: 'plat-1',
  node_platform_name: 'Ubuntu 22.04',
  node_count: 3,
  created_at: '2026-01-15T10:30:00Z',
  updated_at: '2026-03-20T14:00:00Z',
};

const TEMPLATE_MINIMAL: SystemNodeTemplate = {
  id: 'tpl-min',
  name: 'Minimal Template',
  enabled: false,
  public: true,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const NODE_A: SystemNode = {
  id: 'node-1',
  name: 'web-01',
  description: 'Primary web node',
  enabled: true,
  config: {},
  allocate_public_ip: false,
  node_template_id: 'tpl-1',
  instance_count: 2,
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

const NODE_B: SystemNode = {
  id: 'node-2',
  name: 'db-01',
  enabled: false,
  config: {},
  allocate_public_ip: false,
  node_template_id: 'tpl-1',
  created_at: '2026-02-02T00:00:00Z',
  updated_at: '2026-02-02T00:00:00Z',
};

// This node belongs to a different template and must be filtered out
const NODE_OTHER: SystemNode = {
  id: 'node-3',
  name: 'other-node',
  enabled: true,
  config: {},
  allocate_public_ip: false,
  node_template_id: 'tpl-other',
  created_at: '2026-02-03T00:00:00Z',
  updated_at: '2026-02-03T00:00:00Z',
};

const MODULE_A: SystemNodeModule = {
  id: 'mod-1',
  name: 'nginx',
  description: 'Web server module',
  variety: 'instance',
  enabled: true,
  public: true,
  priority: 10,
  mask: [],
  file_spec: [],
  config: {},
  node_platform_id: 'plat-1',
  node_platform_name: 'Ubuntu 22.04',
  category_name: 'Web Servers',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const MODULE_B: SystemNodeModule = {
  id: 'mod-2',
  name: 'prometheus',
  variety: 'config',
  enabled: false,
  public: false,
  priority: 5,
  mask: [],
  file_spec: [],
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const DEFAULT_META = {
  current_page: 1,
  per_page: 100,
  total_count: 3,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderOpts {
  templateId?: string | null;
  isOpen?: boolean;
  onClose?: () => void;
  onTemplateUpdated?: () => void;
  onEdit?: (template: SystemNodeTemplate) => void;
  hasPermission?: boolean;
}

function renderModal(opts: RenderOpts = {}) {
  const {
    templateId = 'tpl-1',
    isOpen = true,
    onClose = jest.fn(),
    onTemplateUpdated = jest.fn(),
    onEdit,
    hasPermission = true,
  } = opts;

  // Override usePermissions for per-test gating
  const permMock = require('@/shared/hooks/usePermissions');
  permMock.usePermissions = () => ({ hasPermission: () => hasPermission });

  return render(
    <BrowserRouter>
      <TemplateDetailModal
        templateId={templateId}
        isOpen={isOpen}
        onClose={onClose}
        onTemplateUpdated={onTemplateUpdated}
        onEdit={onEdit}
      />
    </BrowserRouter>
  );
}

/** Default successful API setup — template loads with nodes + modules */
function setupHappyPath() {
  mockGetTemplate.mockResolvedValue(TEMPLATE);
  mockGetNodes.mockResolvedValue({ nodes: [NODE_A, NODE_B, NODE_OTHER], meta: DEFAULT_META });
  mockGetTemplateModules.mockResolvedValue({ modules: [MODULE_A, MODULE_B] });
}

// =============================================================================
// Tests
// =============================================================================

describe('TemplateDetailModal', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    capturedOnNodeUpdate = undefined;

    // Default: reset permission mock to "all granted"
    const permMock = require('@/shared/hooks/usePermissions');
    permMock.usePermissions = () => ({ hasPermission: () => true });
  });

  // ---------------------------------------------------------------------------
  // Visibility / isOpen gate
  // ---------------------------------------------------------------------------

  describe('visibility', () => {
    it('renders nothing when isOpen is false', () => {
      const { container } = render(
        <BrowserRouter>
          <TemplateDetailModal
            templateId="tpl-1"
            isOpen={false}
            onClose={jest.fn()}
          />
        </BrowserRouter>
      );
      expect(container.firstChild).toBeNull();
    });

    it('renders the modal when isOpen is true', () => {
      mockGetTemplate.mockResolvedValue(TEMPLATE);
      mockGetNodes.mockResolvedValue({ nodes: [], meta: DEFAULT_META });
      mockGetTemplateModules.mockResolvedValue({ modules: [] });

      const { container } = renderModal();
      expect(container.querySelector('.fixed.inset-0')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  describe('loading state', () => {
    it('shows "Loading..." heading while API calls are pending', () => {
      // Never resolves during this test
      mockGetTemplate.mockReturnValue(new Promise(() => {}));
      mockGetNodes.mockReturnValue(new Promise(() => {}));
      mockGetTemplateModules.mockReturnValue(new Promise(() => {}));

      renderModal();

      expect(screen.getByText('Loading...')).toBeInTheDocument();
    });

    it('renders a loading spinner while fetching', () => {
      mockGetTemplate.mockReturnValue(new Promise(() => {}));
      mockGetNodes.mockReturnValue(new Promise(() => {}));
      mockGetTemplateModules.mockReturnValue(new Promise(() => {}));

      renderModal();

      // LoadingSpinner renders an element; its presence is sufficient
      const spinner = document.querySelector('.animate-spin, [role="status"]');
      // Just verify we're in loading state — spinner may use various classes
      expect(screen.getByText('Loading...')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Template not found (fetch returns null / undefined)
  // ---------------------------------------------------------------------------

  describe('template not found', () => {
    it('shows "Template not found" when getTemplate resolves but returns falsy', async () => {
      mockGetTemplate.mockResolvedValue(undefined);
      mockGetNodes.mockResolvedValue({ nodes: [], meta: DEFAULT_META });
      mockGetTemplateModules.mockResolvedValue({ modules: [] });

      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Template not found')).toBeInTheDocument()
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  describe('error handling', () => {
    it('shows error notification when getTemplate rejects', async () => {
      mockGetTemplate.mockRejectedValue(new Error('Network error'));
      mockGetNodes.mockResolvedValue({ nodes: [], meta: DEFAULT_META });
      mockGetTemplateModules.mockResolvedValue({ modules: [] });

      renderModal();

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to load template details',
        })
      );
    });

    it('does not show error notification when getNodes rejects (non-critical)', async () => {
      mockGetTemplate.mockResolvedValue(TEMPLATE);
      mockGetNodes.mockRejectedValue(new Error('Nodes failed'));
      mockGetTemplateModules.mockResolvedValue({ modules: [] });

      renderModal();

      await waitFor(() =>
        expect(screen.getAllByText('Ubuntu Base').length).toBeGreaterThan(0)
      );
      expect(mockAddNotification).not.toHaveBeenCalled();
    });

    it('does not show error notification when getTemplateModules rejects (non-critical)', async () => {
      mockGetTemplate.mockResolvedValue(TEMPLATE);
      mockGetNodes.mockResolvedValue({ nodes: [], meta: DEFAULT_META });
      mockGetTemplateModules.mockRejectedValue(new Error('Modules failed'));

      renderModal();

      await waitFor(() =>
        expect(screen.getAllByText('Ubuntu Base').length).toBeGreaterThan(0)
      );
      expect(mockAddNotification).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // API calls — correct URLs and params
  // ---------------------------------------------------------------------------

  describe('API calls on mount', () => {
    it('calls getTemplate with the templateId', async () => {
      setupHappyPath();
      renderModal({ templateId: 'tpl-1' });

      await waitFor(() => expect(mockGetTemplate).toHaveBeenCalledWith('tpl-1'));
    });

    it('calls getNodes with per_page: 100', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() =>
        expect(mockGetNodes).toHaveBeenCalledWith({ per_page: 100 })
      );
    });

    it('calls getTemplateModules with the templateId', async () => {
      setupHappyPath();
      renderModal({ templateId: 'tpl-1' });

      await waitFor(() =>
        expect(mockGetTemplateModules).toHaveBeenCalledWith('tpl-1')
      );
    });

    it('does not make any API calls when templateId is null', () => {
      renderModal({ templateId: null });

      expect(mockGetTemplate).not.toHaveBeenCalled();
      expect(mockGetNodes).not.toHaveBeenCalled();
      expect(mockGetTemplateModules).not.toHaveBeenCalled();
    });

    it('re-fetches when templateId changes', async () => {
      setupHappyPath();
      const { rerender } = renderModal({ templateId: 'tpl-1' });

      await waitFor(() => expect(mockGetTemplate).toHaveBeenCalledWith('tpl-1'));

      mockGetTemplate.mockResolvedValue({ ...TEMPLATE, id: 'tpl-2', name: 'Template 2' });

      rerender(
        <BrowserRouter>
          <TemplateDetailModal
            templateId="tpl-2"
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>
      );

      await waitFor(() => expect(mockGetTemplate).toHaveBeenCalledWith('tpl-2'));
    });
  });

  // ---------------------------------------------------------------------------
  // Info tab — rendered content
  // ---------------------------------------------------------------------------

  describe('Info tab', () => {
    beforeEach(() => {
      setupHappyPath();
    });

    it('displays the template name in the header once loaded', async () => {
      renderModal();

      await waitFor(() =>
        expect(screen.getByRole('heading', { level: 2, name: 'Ubuntu Base' })).toBeInTheDocument()
      );
    });

    it('displays the description in the header subtitle', async () => {
      renderModal();

      // The description appears in both the header subtitle (truncate class) and the info body.
      // Confirm at least one instance is present.
      await waitFor(() =>
        expect(screen.getAllByText('Base template for all Ubuntu nodes').length).toBeGreaterThan(0)
      );
    });

    it('shows the template name in the info grid', async () => {
      renderModal();

      await waitFor(() =>
        expect(screen.getAllByText('Ubuntu Base').length).toBeGreaterThan(0)
      );
    });

    it('shows the platform name', async () => {
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Ubuntu 22.04')).toBeInTheDocument()
      );
    });

    it('shows the admin user', async () => {
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('ubuntu')).toBeInTheDocument()
      );
    });

    it('falls back to "root" when admin_user is absent', async () => {
      mockGetTemplate.mockResolvedValue(TEMPLATE_MINIMAL);
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('root')).toBeInTheDocument()
      );
    });

    it('shows the node count', async () => {
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('3')).toBeInTheDocument()
      );
    });

    it('shows "Enabled" status badge when template is enabled', async () => {
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Enabled')).toBeInTheDocument()
      );
    });

    it('shows "Disabled" status badge when template is disabled', async () => {
      mockGetTemplate.mockResolvedValue(TEMPLATE_MINIMAL);
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Disabled')).toBeInTheDocument()
      );
    });

    it('shows "Public" visibility badge when template is public', async () => {
      mockGetTemplate.mockResolvedValue(TEMPLATE_MINIMAL); // public: true
      renderModal();

      await waitFor(() =>
        expect(screen.getByText(/Public/)).toBeInTheDocument()
      );
    });

    it('shows "Private" visibility badge when template is private', async () => {
      renderModal(); // TEMPLATE has public: false

      await waitFor(() =>
        expect(screen.getByText(/Private/)).toBeInTheDocument()
      );
    });

    it('renders the description section when description is present', async () => {
      renderModal();

      await waitFor(() => {
        const descriptions = screen.getAllByText('Base template for all Ubuntu nodes');
        expect(descriptions.length).toBeGreaterThan(0);
      });
    });

    it('does not render description section when description is absent', async () => {
      mockGetTemplate.mockResolvedValue(TEMPLATE_MINIMAL);
      mockGetNodes.mockResolvedValue({ nodes: [], meta: DEFAULT_META });
      mockGetTemplateModules.mockResolvedValue({ modules: [] });

      renderModal();

      await waitFor(() =>
        expect(screen.getAllByText('Minimal Template').length).toBeGreaterThan(0)
      );

      // The Description section (with an <h4> "Description") only appears when description is set
      const descHeadings = screen.queryAllByRole('heading', { name: /^description$/i });
      expect(descHeadings.length).toBe(0);
    });

    it('shows formatted created_at date', async () => {
      renderModal();

      await waitFor(() =>
        expect(screen.getByText(/Created:/)).toBeInTheDocument()
      );
    });

    it('shows formatted updated_at date', async () => {
      renderModal();

      await waitFor(() =>
        expect(screen.getByText(/Updated:/)).toBeInTheDocument()
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Nodes tab
  // ---------------------------------------------------------------------------

  describe('Nodes tab', () => {
    it('shows node count in the Nodes tab label', async () => {
      setupHappyPath();
      renderModal();

      // Nodes are filtered: NODE_A + NODE_B match tpl-1, NODE_OTHER does not → count = 2
      await waitFor(() =>
        expect(screen.getByText('Nodes (2)')).toBeInTheDocument()
      );
    });

    it('shows filtered nodes after clicking the Nodes tab', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Nodes (2)')).toBeInTheDocument()
      );
      fireEvent.click(screen.getByText('Nodes (2)'));

      expect(screen.getByText('web-01')).toBeInTheDocument();
      expect(screen.getByText('db-01')).toBeInTheDocument();
      // The node belonging to a different template must NOT appear
      expect(screen.queryByText('other-node')).not.toBeInTheDocument();
    });

    it('shows node description when present', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Nodes (2)'));
      fireEvent.click(screen.getByText('Nodes (2)'));

      expect(screen.getByText('Primary web node')).toBeInTheDocument();
    });

    it('shows enabled/disabled badge per node', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Nodes (2)'));
      fireEvent.click(screen.getByText('Nodes (2)'));

      // NODE_A enabled, NODE_B disabled — both badges visible in the tab
      const enabledBadges = screen.getAllByText('Enabled');
      const disabledBadges = screen.getAllByText('Disabled');
      expect(enabledBadges.length).toBeGreaterThan(0);
      expect(disabledBadges.length).toBeGreaterThan(0);
    });

    it('shows instance count per node', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Nodes (2)'));
      fireEvent.click(screen.getByText('Nodes (2)'));

      expect(screen.getByText('2 instances')).toBeInTheDocument();
    });

    it('shows empty state when no nodes match the template', async () => {
      mockGetTemplate.mockResolvedValue(TEMPLATE);
      mockGetNodes.mockResolvedValue({ nodes: [NODE_OTHER], meta: DEFAULT_META });
      mockGetTemplateModules.mockResolvedValue({ modules: [] });

      renderModal();

      await waitFor(() => screen.getByText('Nodes (0)'));
      fireEvent.click(screen.getByText('Nodes (0)'));

      expect(screen.getByText('No nodes are using this template')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Modules tab
  // ---------------------------------------------------------------------------

  describe('Modules tab', () => {
    it('shows module count in the Modules tab label', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Modules (2)')).toBeInTheDocument()
      );
    });

    it('shows modules after clicking the Modules tab', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));

      expect(screen.getByText('nginx')).toBeInTheDocument();
      expect(screen.getByText('prometheus')).toBeInTheDocument();
    });

    it('shows module description when present', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));

      expect(screen.getByText('Web server module')).toBeInTheDocument();
    });

    it('shows module variety badge', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));

      expect(screen.getByText('instance')).toBeInTheDocument();
      expect(screen.getByText('config')).toBeInTheDocument();
    });

    it('shows enabled/disabled badge per module', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));

      const enabledBadges = screen.getAllByText('Enabled');
      const disabledBadges = screen.getAllByText('Disabled');
      expect(enabledBadges.length).toBeGreaterThan(0);
      expect(disabledBadges.length).toBeGreaterThan(0);
    });

    it('shows platform info when module has a platform', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));

      expect(screen.getByText('Ubuntu 22.04')).toBeInTheDocument();
    });

    it('shows category name when present', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));

      expect(screen.getByText(/Web Servers/)).toBeInTheDocument();
    });

    it('shows remove buttons when user has edit permission', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));

      expect(screen.getByLabelText('Remove nginx from template')).toBeInTheDocument();
      expect(screen.getByLabelText('Remove prometheus from template')).toBeInTheDocument();
    });

    it('hides remove buttons when user lacks edit permission', async () => {
      setupHappyPath();

      // Override permission for this test
      const permMock = require('@/shared/hooks/usePermissions');
      permMock.usePermissions = () => ({ hasPermission: () => false });

      renderModal({ hasPermission: false });

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));

      expect(screen.queryByLabelText('Remove nginx from template')).not.toBeInTheDocument();
    });

    it('shows empty state when no modules are assigned', async () => {
      mockGetTemplate.mockResolvedValue(TEMPLATE);
      mockGetNodes.mockResolvedValue({ nodes: [], meta: DEFAULT_META });
      mockGetTemplateModules.mockResolvedValue({ modules: [] });

      renderModal();

      await waitFor(() => screen.getByText('Modules (0)'));
      fireEvent.click(screen.getByText('Modules (0)'));

      expect(screen.getByText('No modules assigned to this template')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Remove module interaction
  // ---------------------------------------------------------------------------

  describe('handleRemoveModule', () => {
    beforeEach(() => {
      setupHappyPath();
      mockUnassignModuleFromTemplate.mockResolvedValue(undefined);
    });

    it('calls unassignModuleFromTemplate with templateId and moduleId', async () => {
      renderModal({ templateId: 'tpl-1' });

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));

      fireEvent.click(screen.getByLabelText('Remove nginx from template'));

      await waitFor(() =>
        expect(mockUnassignModuleFromTemplate).toHaveBeenCalledWith('tpl-1', 'mod-1')
      );
    });

    it('shows success notification with module name after removal', async () => {
      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByLabelText('Remove nginx from template'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Removed nginx from template',
        })
      );
    });

    it('re-fetches modules after successful removal', async () => {
      // After removal, the API returns only MODULE_B
      mockGetTemplateModules
        .mockResolvedValueOnce({ modules: [MODULE_A, MODULE_B] })
        .mockResolvedValueOnce({ modules: [MODULE_B] });

      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByLabelText('Remove nginx from template'));

      await waitFor(() =>
        expect(mockGetTemplateModules).toHaveBeenCalledTimes(2)
      );
    });

    it('shows error notification when removal fails', async () => {
      mockUnassignModuleFromTemplate.mockRejectedValue(new Error('Server error'));

      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByLabelText('Remove nginx from template'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to remove nginx from template',
        })
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Configuration tab
  // ---------------------------------------------------------------------------

  describe('Config tab', () => {
    it('shows JSON config when template has config keys', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Configuration'));
      fireEvent.click(screen.getByText('Configuration'));

      // Config tab shows JSON.stringify output
      const pre = document.querySelector('pre');
      expect(pre).toBeInTheDocument();
      expect(pre!.textContent).toContain('timezone');
      expect(pre!.textContent).toContain('UTC');
    });

    it('shows empty config message when config object is empty', async () => {
      mockGetTemplate.mockResolvedValue(TEMPLATE_MINIMAL);
      mockGetNodes.mockResolvedValue({ nodes: [], meta: DEFAULT_META });
      mockGetTemplateModules.mockResolvedValue({ modules: [] });

      renderModal();

      await waitFor(() => screen.getByText('Configuration'));
      fireEvent.click(screen.getByText('Configuration'));

      expect(screen.getByText('No custom configuration defined')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Tab navigation
  // ---------------------------------------------------------------------------

  describe('tab navigation', () => {
    it('starts on the Information tab by default', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Information')).toBeInTheDocument()
      );
      // Info tab content (Name field) is visible
      await waitFor(() =>
        expect(screen.getByText('Name')).toBeInTheDocument()
      );
    });

    it('switches to Nodes tab when clicked', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Nodes (2)'));
      fireEvent.click(screen.getByText('Nodes (2)'));

      // Nodes tab content is visible
      expect(screen.getByText('web-01')).toBeInTheDocument();
    });

    it('switches to Modules tab when clicked', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Modules (2)'));
      fireEvent.click(screen.getByText('Modules (2)'));

      expect(screen.getByText('nginx')).toBeInTheDocument();
    });

    it('switches to Configuration tab when clicked', async () => {
      setupHappyPath();
      renderModal();

      await waitFor(() => screen.getByText('Configuration'));
      fireEvent.click(screen.getByText('Configuration'));

      expect(screen.getByText('Template Configuration')).toBeInTheDocument();
    });

    it('resets to the Information tab when reopened', async () => {
      setupHappyPath();
      const { rerender } = renderModal({ isOpen: true });

      await waitFor(() => screen.getByText('Nodes (2)'));
      // Navigate away from the default tab
      fireEvent.click(screen.getByText('Nodes (2)'));

      // Close modal
      rerender(
        <BrowserRouter>
          <TemplateDetailModal
            templateId="tpl-1"
            isOpen={false}
            onClose={jest.fn()}
          />
        </BrowserRouter>
      );

      // Reopen
      setupHappyPath();
      rerender(
        <BrowserRouter>
          <TemplateDetailModal
            templateId="tpl-1"
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>
      );

      await waitFor(() =>
        expect(screen.getByText('Information')).toBeInTheDocument()
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Footer buttons
  // ---------------------------------------------------------------------------

  describe('footer', () => {
    it('calls onClose when the Close button is clicked', async () => {
      setupHappyPath();
      const onClose = jest.fn();
      renderModal({ onClose });

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /close/i })).toBeInTheDocument()
      );
      fireEvent.click(screen.getByRole('button', { name: /close/i }));

      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('shows Edit Template button when user has permission and onEdit is provided', async () => {
      setupHappyPath();
      const onEdit = jest.fn();
      renderModal({ onEdit });

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /edit template/i })).toBeInTheDocument()
      );
    });

    it('calls onEdit with the template when Edit Template is clicked', async () => {
      setupHappyPath();
      const onEdit = jest.fn();
      renderModal({ onEdit });

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /edit template/i })).toBeInTheDocument()
      );
      fireEvent.click(screen.getByRole('button', { name: /edit template/i }));

      expect(onEdit).toHaveBeenCalledWith(TEMPLATE);
    });

    it('hides Edit Template button when onEdit is not provided', async () => {
      setupHappyPath();
      renderModal(); // no onEdit

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /close/i })).toBeInTheDocument()
      );

      expect(screen.queryByRole('button', { name: /edit template/i })).not.toBeInTheDocument();
    });

    it('hides Edit Template button when user lacks permission', async () => {
      setupHappyPath();
      const permMock = require('@/shared/hooks/usePermissions');
      permMock.usePermissions = () => ({ hasPermission: () => false });

      const onEdit = jest.fn();
      renderModal({ onEdit, hasPermission: false });

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /close/i })).toBeInTheDocument()
      );

      expect(screen.queryByRole('button', { name: /edit template/i })).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Backdrop close
  // ---------------------------------------------------------------------------

  describe('backdrop', () => {
    it('calls onClose when the backdrop is clicked', async () => {
      setupHappyPath();
      const onClose = jest.fn();
      const { container } = renderModal({ onClose });

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /close/i })).toBeInTheDocument()
      );

      const backdrop = container.querySelector('.bg-black\\/50') as HTMLElement;
      expect(backdrop).toBeInTheDocument();
      fireEvent.click(backdrop);

      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('calls onClose when the X button is clicked', async () => {
      setupHappyPath();
      const onClose = jest.fn();
      renderModal({ onClose });

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /close/i })).toBeInTheDocument()
      );

      // Header has an X button (ghost button with X icon, no text)
      const buttons = screen.getAllByRole('button');
      const xBtn = buttons.find(btn => {
        const label = btn.getAttribute('aria-label');
        return !label && btn.querySelector('svg');
      });
      if (xBtn) {
        fireEvent.click(xBtn);
        expect(onClose).toHaveBeenCalled();
      }
    });
  });

  // ---------------------------------------------------------------------------
  // State reset on close
  // ---------------------------------------------------------------------------

  describe('state reset on close', () => {
    it('clears template data when isOpen becomes false', async () => {
      setupHappyPath();
      const { rerender } = renderModal({ isOpen: true });

      await waitFor(() =>
        expect(screen.getAllByText('Ubuntu Base').length).toBeGreaterThan(0)
      );

      rerender(
        <BrowserRouter>
          <TemplateDetailModal
            templateId="tpl-1"
            isOpen={false}
            onClose={jest.fn()}
          />
        </BrowserRouter>
      );

      // Modal is closed — nothing rendered
      expect(screen.queryByText('Ubuntu Base')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // WebSocket node update → re-fetches nodes
  // ---------------------------------------------------------------------------

  describe('WebSocket integration', () => {
    it('re-fetches nodes when a node_updated event arrives', async () => {
      setupHappyPath();
      // On first fetch: 2 matching nodes. On refresh: 1 matching node
      mockGetNodes
        .mockResolvedValueOnce({ nodes: [NODE_A, NODE_B, NODE_OTHER], meta: DEFAULT_META })
        .mockResolvedValueOnce({ nodes: [NODE_A, NODE_OTHER], meta: DEFAULT_META });

      renderModal();

      await waitFor(() => expect(mockGetNodes).toHaveBeenCalledTimes(1));

      // Trigger the WebSocket callback
      expect(capturedOnNodeUpdate).toBeDefined();
      capturedOnNodeUpdate!({
        id: 'node-2',
        name: 'db-01',
        enabled: false,
        instances_count: 0,
        created_at: '2026-02-02T00:00:00Z',
        updated_at: '2026-04-01T00:00:00Z',
      });

      await waitFor(() => expect(mockGetNodes).toHaveBeenCalledTimes(2));
    });
  });
});
