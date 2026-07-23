import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ModuleDetailModal } from './ModuleDetailModal';
import type { SystemNodeModule } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// Track whether the mock returns true or false — mutable via tests
let mockHasPermission = true;

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => mockHasPermission,
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// Mock child components so their own API calls don't interfere.
jest.mock('./ConsentBudgetEditor', () => ({
  ConsentBudgetEditor: ({ module }: { module: { name: string } }) => (
    <div data-testid="consent-budget-editor">ConsentBudgetEditor:{module.name}</div>
  ),
}));

jest.mock('./CanaryMarker', () => ({
  CanaryMarker: ({ module }: { module: { name: string } }) => (
    <div data-testid="canary-marker">CanaryMarker:{module.name}</div>
  ),
}));

// EntityLink renders interactive elements that need entityRegistry + useEntityModal —
// stub it so the modal content is renderable without a full app context.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label: string }) => <span>{label}</span>,
}));

// systemApi facade used directly in the component
const mockGetModule = jest.fn();
const mockGetModuleDependencies = jest.fn();
const mockGetModules = jest.fn();
const mockAddModuleDependency = jest.fn();
const mockRemoveModuleDependency = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getModule: (...args: unknown[]) => mockGetModule(...args),
    getModuleDependencies: (...args: unknown[]) => mockGetModuleDependencies(...args),
    getModules: (...args: unknown[]) => mockGetModules(...args),
    addModuleDependency: (...args: unknown[]) => mockAddModuleDependency(...args),
    removeModuleDependency: (...args: unknown[]) => mockRemoveModuleDependency(...args),
    // Other methods used by child stubs
    updateModule: jest.fn(),
    markModuleAsCanary: jest.fn(),
    unmarkModuleAsCanary: jest.fn(),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Mirrors the double-envelope shape: AxiosResponse.data = { success, data, meta? } */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

// Expose envelope for callers that need it (avoid "declared but unused" lint errors)
void envelope;

/**
 * Wait for the module to finish loading.
 * The module name appears in both the header <h2> and the Info tab content;
 * using the heading role is unambiguous.
 */
async function waitForModuleLoad(name: string) {
  await waitFor(() =>
    expect(screen.getByRole('heading', { name })).toBeInTheDocument(),
  );
}

// =============================================================================
// Fixtures
// =============================================================================

const BASE_MODULE: SystemNodeModule = {
  id: 'mod-001',
  name: 'ssh-base',
  description: 'SSH base module',
  variety: 'config',
  enabled: true,
  public: false,
  priority: 10,
  mask: [],
  file_spec: [],
  config: {},
  category_id: 'cat-001',
  category_name: 'Security',
  node_platform_id: 'plt-001',
  node_platform_name: 'Ubuntu 24.04',
  dependencies_count: 0,
  dependents_count: 0,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

const INSTANCE_MODULE: SystemNodeModule = {
  ...BASE_MODULE,
  id: 'mod-002',
  name: 'web-server',
  variety: 'instance',
  enabled: false,
  public: true,
};

const SUBSCRIPTION_MODULE: SystemNodeModule = {
  ...BASE_MODULE,
  id: 'mod-003',
  name: 'app-sub',
  variety: 'subscription',
};

const DEP_MODULE: SystemNodeModule = {
  id: 'mod-dep-1',
  name: 'ssl-certs',
  variety: 'config',
  enabled: true,
  public: false,
  priority: 5,
  mask: [],
  file_spec: [],
  config: {},
  node_platform_id: 'plt-001',
  node_platform_name: 'Ubuntu 24.04',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// Minimal meta shape for paginated responses
const EMPTY_META = {
  current_page: 1,
  per_page: 200,
  total_count: 0,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  moduleId?: string | null;
  isOpen?: boolean;
  onClose?: jest.Mock;
  onEdit?: jest.Mock;
}

function renderModal({
  moduleId = 'mod-001',
  isOpen = true,
  onClose = jest.fn(),
  onEdit,
}: RenderProps = {}) {
  return render(
    <BrowserRouter>
      <ModuleDetailModal
        moduleId={moduleId}
        isOpen={isOpen}
        onClose={onClose}
        onEdit={onEdit}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('ModuleDetailModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockGetModule.mockReset();
    mockGetModuleDependencies.mockReset();
    mockGetModules.mockReset();
    mockAddModuleDependency.mockReset();
    mockRemoveModuleDependency.mockReset();
    // Reset permission back to default (true) before each test
    mockHasPermission = true;
  });

  // ===========================================================================
  // Closed state
  // ===========================================================================

  describe('closed state', () => {
    it('renders nothing when isOpen is false', () => {
      mockGetModule.mockResolvedValue(BASE_MODULE);
      renderModal({ isOpen: false });
      expect(screen.queryByText('Module Details')).not.toBeInTheDocument();
    });

    it('does not call systemApi.getModule when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(mockGetModule).not.toHaveBeenCalled();
    });

    it('does not violate Rules of Hooks when toggled closed -> open on the same instance (regression: hook declared after early-return)', async () => {
      mockGetModule.mockResolvedValue(BASE_MODULE);
      const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

      try {
        const { rerender } = renderModal({ isOpen: false });
        expect(screen.queryByText('Module Details')).not.toBeInTheDocument();

        rerender(
          <BrowserRouter>
            <ModuleDetailModal moduleId="mod-001" isOpen={true} onClose={jest.fn()} />
          </BrowserRouter>,
        );

        await waitForModuleLoad('ssh-base');

        const hookOrderErrors = consoleErrorSpy.mock.calls.filter(([msg]) =>
          typeof msg === 'string' && /Rendered (more|fewer) hooks/i.test(msg),
        );
        expect(hookOrderErrors).toHaveLength(0);
      } finally {
        // resetMocks only clears call history, it doesn't restore the spied
        // implementation — without this in a finally, a failing assertion
        // above would leave console.error silently mocked for later tests.
        consoleErrorSpy.mockRestore();
      }
    });
  });

  // ===========================================================================
  // Webhook signing secret (D9-step-2 — permission-gated, masked)
  // ===========================================================================

  describe('webhook signing secret', () => {
    // Obviously-fake value — never a real signing secret.
    const FAKE_SECRET = 'whsec_test_FAKE_not_a_real_secret_0000';

    it('does not render the section when the API omits webhook_secret', async () => {
      mockGetModule.mockResolvedValue(BASE_MODULE);
      renderModal();
      await waitForModuleLoad('ssh-base');
      expect(screen.queryByText('Webhook signing secret')).not.toBeInTheDocument();
    });

    it('renders masked by default and reveals on click (never auto-shown)', async () => {
      mockGetModule.mockResolvedValue({ ...BASE_MODULE, webhook_secret: FAKE_SECRET });
      renderModal();
      await waitForModuleLoad('ssh-base');

      expect(screen.getByText('Webhook signing secret')).toBeInTheDocument();
      // Masked: the raw value is NOT in the DOM until revealed.
      expect(screen.queryByText(FAKE_SECRET)).not.toBeInTheDocument();

      fireEvent.click(screen.getByRole('button', { name: 'Reveal webhook secret' }));
      expect(screen.getByText(FAKE_SECRET)).toBeInTheDocument();
    });

    it('copies the secret to the clipboard on demand', async () => {
      const writeText = jest.fn().mockResolvedValue(undefined);
      Object.assign(navigator, { clipboard: { writeText } });

      mockGetModule.mockResolvedValue({ ...BASE_MODULE, webhook_secret: FAKE_SECRET });
      renderModal();
      await waitForModuleLoad('ssh-base');

      fireEvent.click(screen.getByRole('button', { name: 'Copy webhook secret' }));
      await waitFor(() => expect(writeText).toHaveBeenCalledWith(FAKE_SECRET));
    });
  });

  // ===========================================================================
  // Loading state
  // ===========================================================================

  describe('loading state', () => {
    it('shows "Loading..." in the header while the fetch is in progress', async () => {
      let resolve!: (m: SystemNodeModule) => void;
      mockGetModule.mockReturnValueOnce(new Promise<SystemNodeModule>((r) => { resolve = r; }));

      renderModal();

      expect(screen.getByText('Loading...')).toBeInTheDocument();

      // Settle to avoid act() warnings
      resolve(BASE_MODULE);
      await waitForModuleLoad('ssh-base');
    });

    it('"Loading..." disappears after the module resolves', async () => {
      let resolve!: (m: SystemNodeModule) => void;
      mockGetModule.mockReturnValueOnce(new Promise<SystemNodeModule>((r) => { resolve = r; }));

      renderModal();

      expect(screen.getByText('Loading...')).toBeInTheDocument();

      resolve(BASE_MODULE);
      await waitFor(() => expect(screen.queryByText('Loading...')).not.toBeInTheDocument());
    });
  });

  // ===========================================================================
  // Error state
  // ===========================================================================

  describe('error state', () => {
    it('shows an error message when getModule rejects', async () => {
      mockGetModule.mockRejectedValueOnce(new Error('Network error'));

      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Failed to load module details')).toBeInTheDocument(),
      );
    });

    it('shows "Module Details" fallback in the header when fetch fails', async () => {
      mockGetModule.mockRejectedValueOnce(new Error('Not found'));

      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Failed to load module details')).toBeInTheDocument(),
      );
      expect(screen.getByRole('heading', { name: 'Module Details' })).toBeInTheDocument();
    });
  });

  // ===========================================================================
  // Successful load — header rendering
  // ===========================================================================

  describe('successful load — header', () => {
    it('calls systemApi.getModule with the correct moduleId', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal({ moduleId: 'mod-001' });

      await waitFor(() => expect(mockGetModule).toHaveBeenCalledWith('mod-001'));
    });

    it('renders the module name in the header after load', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      expect(screen.getByRole('heading', { name: 'ssh-base' })).toBeInTheDocument();
    });

    it('renders variety label subtitle for config module', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitFor(() => expect(screen.getByText('Config Module')).toBeInTheDocument());
    });

    it('renders variety label subtitle for instance module', async () => {
      mockGetModule.mockResolvedValueOnce(INSTANCE_MODULE);

      renderModal({ moduleId: 'mod-002' });

      await waitFor(() => expect(screen.getByText('Instance Module')).toBeInTheDocument());
    });

    it('renders variety label subtitle for subscription module', async () => {
      mockGetModule.mockResolvedValueOnce(SUBSCRIPTION_MODULE);

      renderModal({ moduleId: 'mod-003' });

      await waitFor(() => expect(screen.getByText('Subscription Module')).toBeInTheDocument());
    });

    it('shows Edit button when onEdit prop is provided', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      const onEdit = jest.fn();

      renderModal({ onEdit });

      await waitFor(() => expect(screen.getByRole('button', { name: /edit/i })).toBeInTheDocument());
    });

    it('does NOT show Edit button when onEdit prop is omitted', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      expect(screen.queryByRole('button', { name: /edit/i })).not.toBeInTheDocument();
    });

    it('calls onEdit with the module when Edit is clicked', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      const onEdit = jest.fn();

      renderModal({ onEdit });

      await waitFor(() => expect(screen.getByRole('button', { name: /edit/i })).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: /edit/i }));

      expect(onEdit).toHaveBeenCalledWith(BASE_MODULE);
    });

    it('renders all five tab buttons', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      expect(screen.getByRole('button', { name: /information/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /specifications/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /dependencies/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /versions/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /autonomy/i })).toBeInTheDocument();
    });

    it('defaults to the Information tab on open', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      // Info tab content — "Name" label in the info grid
      expect(screen.getByText('Name')).toBeInTheDocument();
    });

    it('resets to the information tab when re-opened with a new moduleId', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      const { rerender } = renderModal();

      await waitForModuleLoad('ssh-base');

      // Click to Specs tab
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));
      expect(screen.getByText('File spec')).toBeInTheDocument();

      // Re-open with a different module → should reset to info
      mockGetModule.mockResolvedValueOnce(INSTANCE_MODULE);
      rerender(
        <BrowserRouter>
          <ModuleDetailModal moduleId="mod-002" isOpen={true} onClose={jest.fn()} />
        </BrowserRouter>,
      );

      await waitForModuleLoad('web-server');
      // Info tab should be active — "Name" label is present
      expect(screen.getByText('Name')).toBeInTheDocument();
    });
  });

  // ===========================================================================
  // Close behaviour
  // ===========================================================================

  describe('close behaviour', () => {
    it('calls onClose when the footer Close button is clicked', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      const onClose = jest.fn();

      renderModal({ onClose });

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /close/i }));

      expect(onClose).toHaveBeenCalled();
    });

    it('calls onClose when the backdrop is clicked', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      const onClose = jest.fn();

      const { container } = renderModal({ onClose });

      await waitForModuleLoad('ssh-base');
      // Backdrop is the first fixed inset-0 bg-black/50 div
      const backdrop = container.querySelector('.fixed.inset-0.bg-black\\/50');
      expect(backdrop).toBeInTheDocument();
      fireEvent.click(backdrop!);

      expect(onClose).toHaveBeenCalled();
    });
  });

  // ===========================================================================
  // Information Tab
  // ===========================================================================

  describe('Information tab', () => {
    it('renders module name in info grid', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      // The Name label + value in the info grid
      expect(screen.getByText('Name')).toBeInTheDocument();
      // getAllByText because the name appears in h2 AND the p tag in the info grid
      expect(screen.getAllByText('ssh-base').length).toBeGreaterThanOrEqual(2);
    });

    it('renders the description', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      expect(screen.getByText('SSH base module')).toBeInTheDocument();
    });

    it('renders category via EntityLink stub', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      expect(screen.getByText('Security')).toBeInTheDocument();
    });

    it('renders "—" for description when not set', async () => {
      const mod = { ...BASE_MODULE, description: undefined };
      mockGetModule.mockResolvedValueOnce(mod);

      renderModal();

      await waitForModuleLoad('ssh-base');
      const descriptionLabel = screen.getByText('Description');
      const parentDiv = descriptionLabel.closest('div');
      expect(parentDiv).toHaveTextContent('—');
    });

    it('renders Config badge for config variety', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      // "Config" appears in the badge in the info tab
      await waitFor(() => expect(screen.getAllByText('Config').length).toBeGreaterThan(0));
    });

    it('renders Instance badge for instance variety', async () => {
      mockGetModule.mockResolvedValueOnce(INSTANCE_MODULE);

      renderModal({ moduleId: 'mod-002' });

      await waitFor(() => expect(screen.getAllByText('Instance').length).toBeGreaterThan(0));
    });

    it('renders Subscription badge for subscription variety', async () => {
      mockGetModule.mockResolvedValueOnce(SUBSCRIPTION_MODULE);

      renderModal({ moduleId: 'mod-003' });

      await waitFor(() => expect(screen.getAllByText('Subscription').length).toBeGreaterThan(0));
    });

    it('renders platform name via EntityLink stub', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitFor(() => expect(screen.getByText('Ubuntu 24.04')).toBeInTheDocument());
    });

    it('renders priority value', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitFor(() => expect(screen.getByText('10')).toBeInTheDocument());
    });

    it('shows Enabled status for enabled module', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitFor(() => expect(screen.getByText('Enabled')).toBeInTheDocument());
    });

    it('shows Disabled status for disabled module', async () => {
      mockGetModule.mockResolvedValueOnce(INSTANCE_MODULE);

      renderModal({ moduleId: 'mod-002' });

      await waitFor(() => expect(screen.getByText('Disabled')).toBeInTheDocument());
    });

    it('shows Public for public modules', async () => {
      mockGetModule.mockResolvedValueOnce(INSTANCE_MODULE);

      renderModal({ moduleId: 'mod-002' });

      await waitFor(() => expect(screen.getByText('Public')).toBeInTheDocument());
    });

    it('shows Private for non-public modules', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitFor(() => expect(screen.getByText('Private')).toBeInTheDocument());
    });

    it('renders Created: and Updated: timestamp labels', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitFor(() => expect(screen.getByText('Created:')).toBeInTheDocument());
      expect(screen.getByText('Updated:')).toBeInTheDocument();
    });

    it('shows "—" for category when both category_id and category_name are absent', async () => {
      const mod = { ...BASE_MODULE, category_id: undefined, category_name: undefined };
      mockGetModule.mockResolvedValueOnce(mod);

      renderModal();

      await waitForModuleLoad('ssh-base');
      const categoryLabel = screen.getByText('Category');
      const parentDiv = categoryLabel.closest('div');
      expect(parentDiv).toHaveTextContent('—');
    });

    it('shows "—" for platform when node_platform_id and node_platform_name are absent', async () => {
      const mod = { ...BASE_MODULE, node_platform_id: undefined, node_platform_name: undefined };
      mockGetModule.mockResolvedValueOnce(mod);

      renderModal();

      await waitForModuleLoad('ssh-base');
      const platformLabel = screen.getByText('Platform');
      const parentDiv = platformLabel.closest('div');
      expect(parentDiv).toHaveTextContent('—');
    });
  });

  // ===========================================================================
  // Specifications Tab
  // ===========================================================================

  describe('Specifications tab', () => {
    it('switches to specs tab on click and shows File spec heading', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      expect(screen.getByText('File spec')).toBeInTheDocument();
    });

    it('renders "No entries." for empty file_spec_text', async () => {
      mockGetModule.mockResolvedValueOnce({ ...BASE_MODULE, file_spec_text: '' });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      const noEntries = screen.getAllByText('No entries.');
      expect(noEntries.length).toBeGreaterThan(0);
    });

    it('renders file_spec lines from file_spec_text', async () => {
      const mod = {
        ...BASE_MODULE,
        file_spec_text: '/etc/ssh/**\n/etc/ssh/sshd_config',
      };
      mockGetModule.mockResolvedValueOnce(mod);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      expect(screen.getByText('/etc/ssh/**')).toBeInTheDocument();
      expect(screen.getByText('/etc/ssh/sshd_config')).toBeInTheDocument();
    });

    it('shows a count badge equal to the number of lines', async () => {
      const mod = {
        ...BASE_MODULE,
        file_spec_text: '/etc/ssh/**\n/etc/ssh/sshd_config',
      };
      mockGetModule.mockResolvedValueOnce(mod);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      // Badge shows count = 2
      expect(screen.getByText('2')).toBeInTheDocument();
    });

    it('shows dependant file spec title with parent module name when dependant is true', async () => {
      const mod = {
        ...BASE_MODULE,
        dependant: true,
        parent_module_name: 'base-subscription',
        file_spec_text: '/etc/app/**',
      };
      mockGetModule.mockResolvedValueOnce(mod);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      expect(
        screen.getByText(/file spec.*inherited from base-subscription/i),
      ).toBeInTheDocument();
    });

    it('renders Package spec section with package names', async () => {
      const mod = { ...BASE_MODULE, package_spec_text: 'openssh-server\nopenssl' };
      mockGetModule.mockResolvedValueOnce(mod);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      expect(screen.getByText('Package spec')).toBeInTheDocument();
      expect(screen.getByText('openssh-server')).toBeInTheDocument();
    });

    it('renders Lifecycle section with init_start value', async () => {
      const mod = {
        ...BASE_MODULE,
        init_start: 'systemctl start ssh',
        init_stop: 'systemctl stop ssh',
        init_restart: 'systemctl restart ssh',
      };
      mockGetModule.mockResolvedValueOnce(mod);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      expect(screen.getByText('Lifecycle')).toBeInTheDocument();
      expect(screen.getByText('systemctl start ssh')).toBeInTheDocument();
    });

    it('shows "reboot required on attach/detach" badge when reboot_required is true', async () => {
      mockGetModule.mockResolvedValueOnce({ ...BASE_MODULE, reboot_required: true });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      expect(screen.getByText('reboot required on attach/detach')).toBeInTheDocument();
    });

    it('shows "hot-swap allowed" badge when reboot_required is false', async () => {
      mockGetModule.mockResolvedValueOnce({ ...BASE_MODULE, reboot_required: false });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      expect(screen.getByText('hot-swap allowed')).toBeInTheDocument();
    });

    it('renders Configuration section with JSON content', async () => {
      const mod = { ...BASE_MODULE, config: { key: 'value', count: 42 } };
      mockGetModule.mockResolvedValueOnce(mod);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      expect(screen.getByText('Configuration')).toBeInTheDocument();
      expect(screen.getByText(/"key"/)).toBeInTheDocument();
    });

    it('renders "No configuration set." when config is empty', async () => {
      mockGetModule.mockResolvedValueOnce({ ...BASE_MODULE, config: {} });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /specifications/i }));

      expect(screen.getByText('No configuration set.')).toBeInTheDocument();
    });
  });

  // ===========================================================================
  // Dependencies Tab — load behaviour
  // ===========================================================================

  describe('Dependencies tab — loading', () => {
    it('calls systemApi.getModuleDependencies when the tab is clicked', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() =>
        expect(mockGetModuleDependencies).toHaveBeenCalledWith('mod-001'),
      );
    });

    it('shows empty state when there are no dependencies', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() =>
        expect(screen.getByText('No dependencies configured')).toBeInTheDocument(),
      );
    });

    it('renders dependency items when dependencies are loaded', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([DEP_MODULE]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() => expect(screen.getByText('ssl-certs')).toBeInTheDocument());
    });

    it('shows empty state when getModuleDependencies rejects', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockRejectedValueOnce(new Error('Network error'));

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() =>
        expect(screen.getByText('No dependencies configured')).toBeInTheDocument(),
      );
    });
  });

  // ===========================================================================
  // Dependencies Tab — Add Dependency modal
  // ===========================================================================

  describe('Dependencies tab — Add Dependency', () => {
    it('shows "Add Dependency" button when user has system.modules.update permission', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add dependency/i })).toBeInTheDocument(),
      );
    });

    it('opens the Add Dependency modal when "Add Dependency" is clicked', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);
      mockGetModules.mockResolvedValueOnce({ modules: [DEP_MODULE], meta: EMPTY_META });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add dependency/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));

      // The modal's h3 heading (level 3) confirms it is open
      await waitFor(() =>
        expect(screen.getByRole('heading', { level: 3, name: /add dependency/i })).toBeInTheDocument(),
      );
    });

    it('calls systemApi.getModules when Add Dependency modal opens', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);
      mockGetModules.mockResolvedValueOnce({ modules: [DEP_MODULE], meta: EMPTY_META });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add dependency/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));

      await waitFor(() => expect(mockGetModules).toHaveBeenCalled());
    });

    it('filters out the current module and existing dependencies from the available list', async () => {
      const anotherModule: SystemNodeModule = {
        ...DEP_MODULE,
        id: 'mod-other',
        name: 'kernel-base',
      };
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([DEP_MODULE]); // ssl-certs already a dep
      mockGetModules.mockResolvedValueOnce({
        modules: [BASE_MODULE, DEP_MODULE, anotherModule],
        meta: { ...EMPTY_META, total_count: 3 },
      });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));
      await waitFor(() => expect(screen.getByText('ssl-certs')).toBeInTheDocument());

      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));

      await waitFor(() => expect(mockGetModules).toHaveBeenCalled());

      await waitFor(() => {
        const select = screen.getByRole('combobox');
        const options = Array.from((select as HTMLSelectElement).options).map((o) => o.value);
        // ssh-base (current) and ssl-certs (existing dep) filtered out; kernel-base remains
        expect(options).toContain('mod-other');
        expect(options).not.toContain('mod-001');
        expect(options).not.toContain('mod-dep-1');
      });
    });

    it('shows "No available modules" when all modules are filtered', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);
      // Only the current module is returned — will be filtered
      mockGetModules.mockResolvedValueOnce({ modules: [BASE_MODULE], meta: EMPTY_META });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add dependency/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));

      await waitFor(() =>
        expect(
          screen.getByText('No available modules to add as dependencies'),
        ).toBeInTheDocument(),
      );
    });

    it('calls systemApi.addModuleDependency with correct moduleId and dependencyId', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);
      mockGetModules.mockResolvedValueOnce({ modules: [DEP_MODULE], meta: EMPTY_META });
      mockAddModuleDependency.mockResolvedValueOnce(undefined);
      // Refresh after add
      mockGetModuleDependencies.mockResolvedValueOnce([DEP_MODULE]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add dependency/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));
      await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

      fireEvent.change(screen.getByRole('combobox'), { target: { value: 'mod-dep-1' } });

      // There are two "Add Dependency" buttons: the tab header + the modal confirm
      const addButtons = screen.getAllByRole('button', { name: /add dependency/i });
      fireEvent.click(addButtons[addButtons.length - 1]);

      await waitFor(() =>
        expect(mockAddModuleDependency).toHaveBeenCalledWith('mod-001', 'mod-dep-1'),
      );
    });

    it('shows success notification after adding dependency', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);
      mockGetModules.mockResolvedValueOnce({ modules: [DEP_MODULE], meta: EMPTY_META });
      mockAddModuleDependency.mockResolvedValueOnce(undefined);
      mockGetModuleDependencies.mockResolvedValueOnce([DEP_MODULE]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add dependency/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));
      await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

      fireEvent.change(screen.getByRole('combobox'), { target: { value: 'mod-dep-1' } });
      const addButtons = screen.getAllByRole('button', { name: /add dependency/i });
      fireEvent.click(addButtons[addButtons.length - 1]);

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Dependency added successfully',
        }),
      );
    });

    it('shows error notification when adding dependency fails', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);
      mockGetModules.mockResolvedValueOnce({ modules: [DEP_MODULE], meta: EMPTY_META });
      mockAddModuleDependency.mockRejectedValueOnce(new Error('Conflict'));

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add dependency/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));
      await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

      fireEvent.change(screen.getByRole('combobox'), { target: { value: 'mod-dep-1' } });
      const addButtons = screen.getAllByRole('button', { name: /add dependency/i });
      fireEvent.click(addButtons[addButtons.length - 1]);

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to add dependency: Conflict',
        }),
      );
    });

    it('keeps Add Dependency confirm button disabled when no module is selected', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);
      mockGetModules.mockResolvedValueOnce({ modules: [DEP_MODULE], meta: EMPTY_META });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add dependency/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));
      await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

      // No selection made — the modal Add Dependency confirm button should be disabled
      const addButtons = screen.getAllByRole('button', { name: /add dependency/i });
      expect(addButtons[addButtons.length - 1]).toBeDisabled();
    });

    it('closes the Add Dependency modal when Cancel is clicked', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);
      mockGetModules.mockResolvedValueOnce({ modules: [DEP_MODULE], meta: EMPTY_META });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add dependency/i })).toBeInTheDocument(),
      );

      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));
      await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

      expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
    });

    it('resets selectedDependency when Cancel is clicked', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);
      mockGetModules.mockResolvedValueOnce({ modules: [DEP_MODULE], meta: EMPTY_META });
      // Second open of the modal
      mockGetModules.mockResolvedValueOnce({ modules: [DEP_MODULE], meta: EMPTY_META });

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add dependency/i })).toBeInTheDocument(),
      );

      // Open modal, select, then cancel
      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));
      await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());
      fireEvent.change(screen.getByRole('combobox'), { target: { value: 'mod-dep-1' } });
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

      // Re-open the modal
      fireEvent.click(screen.getByRole('button', { name: /add dependency/i }));
      await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

      // The select should be back to the default empty option
      const select = screen.getByRole('combobox') as HTMLSelectElement;
      expect(select.value).toBe('');
    });
  });

  // ===========================================================================
  // Dependencies Tab — Remove Dependency
  // ===========================================================================

  describe('Dependencies tab — Remove Dependency', () => {
    it('calls systemApi.removeModuleDependency with moduleId and dependencyId', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([DEP_MODULE]);
      mockRemoveModuleDependency.mockResolvedValueOnce(undefined);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() => expect(screen.getByText('ssl-certs')).toBeInTheDocument());

      fireEvent.click(screen.getByTitle('Remove dependency'));

      await waitFor(() =>
        expect(mockRemoveModuleDependency).toHaveBeenCalledWith('mod-001', 'mod-dep-1'),
      );
    });

    it('shows success notification after removing dependency', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([DEP_MODULE]);
      mockRemoveModuleDependency.mockResolvedValueOnce(undefined);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() => expect(screen.getByText('ssl-certs')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Remove dependency'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Dependency removed successfully',
        }),
      );
    });

    it('removes the dependency from the displayed list after successful remove', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([DEP_MODULE]);
      mockRemoveModuleDependency.mockResolvedValueOnce(undefined);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() => expect(screen.getByText('ssl-certs')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Remove dependency'));

      await waitFor(() =>
        expect(screen.queryByText('ssl-certs')).not.toBeInTheDocument(),
      );
      expect(screen.getByText('No dependencies configured')).toBeInTheDocument();
    });

    it('shows error notification when remove fails', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([DEP_MODULE]);
      mockRemoveModuleDependency.mockRejectedValueOnce(new Error('Forbidden'));

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() => expect(screen.getByText('ssl-certs')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Remove dependency'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to remove dependency: Forbidden',
        }),
      );
    });

    it('keeps the dependency in the list when remove fails', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([DEP_MODULE]);
      mockRemoveModuleDependency.mockRejectedValueOnce(new Error('Forbidden'));

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() => expect(screen.getByText('ssl-certs')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Remove dependency'));

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      expect(screen.getByText('ssl-certs')).toBeInTheDocument();
    });
  });

  // ===========================================================================
  // Dependencies Tab — Dependents count link
  // ===========================================================================

  describe('Dependencies tab — dependents count', () => {
    it('shows the dependents count link when dependents_count > 0', async () => {
      const mod = { ...BASE_MODULE, dependents_count: 3 };
      mockGetModule.mockResolvedValueOnce(mod);
      mockGetModuleDependencies.mockResolvedValueOnce([]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      // The dependents count button has text split across <strong> + text nodes;
      // getByRole concatenates all text content within the element.
      await waitFor(() =>
        expect(
          screen.getByRole('button', { name: /3 other modules depend on this module/i }),
        ).toBeInTheDocument(),
      );
    });

    it('uses singular "module depends" for dependents_count === 1', async () => {
      const mod = { ...BASE_MODULE, dependents_count: 1 };
      mockGetModule.mockResolvedValueOnce(mod);
      mockGetModuleDependencies.mockResolvedValueOnce([]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() =>
        expect(
          screen.getByRole('button', { name: /1 other module depends on this module/i }),
        ).toBeInTheDocument(),
      );
    });

    it('does NOT show dependents link when dependents_count is 0', async () => {
      const mod = { ...BASE_MODULE, dependents_count: 0 };
      mockGetModule.mockResolvedValueOnce(mod);
      mockGetModuleDependencies.mockResolvedValueOnce([]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() =>
        expect(screen.getByText('No dependencies configured')).toBeInTheDocument(),
      );
      expect(screen.queryByRole('button', { name: /depend on this module/i })).not.toBeInTheDocument();
    });
  });

  // ===========================================================================
  // Autonomy Tab
  // ===========================================================================

  describe('Autonomy tab', () => {
    it('switches to autonomy tab on click and renders child components', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /autonomy/i }));

      expect(screen.getByTestId('consent-budget-editor')).toBeInTheDocument();
      expect(screen.getByTestId('canary-marker')).toBeInTheDocument();
    });

    it('passes the module to ConsentBudgetEditor', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /autonomy/i }));

      expect(screen.getByText('ConsentBudgetEditor:ssh-base')).toBeInTheDocument();
    });

    it('passes the module to CanaryMarker', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /autonomy/i }));

      expect(screen.getByText('CanaryMarker:ssh-base')).toBeInTheDocument();
    });

    it('renders the consent budget explanation text', async () => {
      mockGetModule.mockResolvedValueOnce(BASE_MODULE);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /autonomy/i }));

      expect(screen.getByText(/consent budget is a per-module ceiling/i)).toBeInTheDocument();
    });
  });

  // ===========================================================================
  // Permission gating — canManageDependencies = false
  // ===========================================================================

  describe('permission gating', () => {
    it('hides Add Dependency button when user lacks system.modules.update', async () => {
      mockHasPermission = false;

      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() =>
        expect(screen.getByText('No dependencies configured')).toBeInTheDocument(),
      );

      expect(
        screen.queryByRole('button', { name: /add dependency/i }),
      ).not.toBeInTheDocument();
    });

    it('hides Remove buttons when user lacks system.modules.update', async () => {
      mockHasPermission = false;

      mockGetModule.mockResolvedValueOnce(BASE_MODULE);
      mockGetModuleDependencies.mockResolvedValueOnce([DEP_MODULE]);

      renderModal();

      await waitForModuleLoad('ssh-base');
      fireEvent.click(screen.getByRole('button', { name: /dependencies/i }));

      await waitFor(() => expect(screen.getByText('ssl-certs')).toBeInTheDocument());

      expect(screen.queryByTitle('Remove dependency')).not.toBeInTheDocument();
    });
  });

  // ===========================================================================
  // moduleId = null guard
  // ===========================================================================

  describe('moduleId null guard', () => {
    it('does not fetch when moduleId is null', () => {
      renderModal({ moduleId: null });
      expect(mockGetModule).not.toHaveBeenCalled();
    });
  });
});
