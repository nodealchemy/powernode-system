import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PuppetModuleDetailModal } from './PuppetModuleDetailModal';
import type { SystemPuppetModule, SystemPuppetResource } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGetPuppetModule = jest.fn();
const mockGetPuppetResources = jest.fn();
const mockDeletePuppetResource = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getPuppetModule: (...args: unknown[]) => mockGetPuppetModule(...args),
    getPuppetResources: (...args: unknown[]) => mockGetPuppetResources(...args),
    deletePuppetResource: (...args: unknown[]) => mockDeletePuppetResource(...args),
  },
}));

// PuppetResourceForm is an internal child — mock it so we can simulate
// onSaved / onCancel callbacks without testing the form internals here.
let capturedOnSaved: ((r: SystemPuppetResource) => void) | null = null;
let capturedOnCancel: (() => void) | null = null;

jest.mock(
  '@system/features/system/components/puppet/PuppetResourceForm',
  () => ({
    PuppetResourceForm: ({
      puppetModuleId,
      resource,
      onSaved,
      onCancel,
    }: {
      puppetModuleId: string;
      resource: SystemPuppetResource | null;
      onSaved: (r: SystemPuppetResource) => void;
      onCancel: () => void;
    }) => {
      capturedOnSaved = onSaved;
      capturedOnCancel = onCancel;
      return (
        <div data-testid="puppet-resource-form">
          <span data-testid="form-module-id">{puppetModuleId}</span>
          <span data-testid="form-resource-id">{resource?.id ?? 'create-mode'}</span>
          <button type="button" onClick={onCancel}>Cancel Form</button>
        </div>
      );
    },
  }),
);

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

// =============================================================================
// Fixtures
// =============================================================================

const MODULE: SystemPuppetModule = {
  id: 'mod-1',
  name: 'nginx',
  description: 'Manages nginx web server',
  enabled: true,
  public: false,
  version: '1.2.3',
  author: 'ops-team',
  license: 'MIT',
  source_url: 'https://github.com/example/nginx',
  project_url: 'https://example.com/nginx',
  forge_name: 'example-nginx',
  dependencies: [
    { name: 'stdlib', version_requirement: '>= 4.0.0' },
    { name: 'apt' },
  ],
  config: { worker_processes: 4 },
  metadata: { tags: ['web'] },
  resource_count: 2,
  resource_types: ['file', 'service'],
  assigned_modules_count: 3,
  created_at: '2024-01-15T10:00:00Z',
  updated_at: '2024-02-20T14:30:00Z',
};

const RESOURCE_A: SystemPuppetResource = {
  id: 'res-a',
  name: 'nginx_conf',
  description: 'Main config',
  resource_type: 'file',
  title: '/etc/nginx/nginx.conf',
  path: '/etc/nginx/nginx.conf',
  data: 'worker_processes auto;',
  enabled: true,
  exported: false,
  parameters: { owner: 'root' },
  config: {},
  puppet_module_id: 'mod-1',
  created_at: '2024-01-16T10:00:00Z',
  updated_at: '2024-01-16T10:00:00Z',
};

const RESOURCE_B: SystemPuppetResource = {
  id: 'res-b',
  name: 'nginx_service',
  resource_type: 'service',
  enabled: false,
  exported: true,
  parameters: {},
  config: {},
  puppet_module_id: 'mod-1',
  created_at: '2024-01-17T10:00:00Z',
  updated_at: '2024-01-17T10:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  moduleId?: string | null;
  isOpen?: boolean;
  onClose?: jest.Mock;
  onEdit?: jest.Mock;
}

const renderModal = ({
  moduleId = 'mod-1',
  isOpen = true,
  onClose = jest.fn(),
  onEdit = jest.fn(),
}: RenderProps = {}) =>
  render(
    <BrowserRouter>
      <PuppetModuleDetailModal
        moduleId={moduleId}
        isOpen={isOpen}
        onClose={onClose}
        onEdit={onEdit}
      />
    </BrowserRouter>,
  );

// Wait for the modal to finish loading by checking the h2 heading shows the module name
const waitForModuleLoaded = async (name = 'nginx') => {
  await waitFor(() => {
    const heading = screen.getByRole('heading', { level: 2 });
    expect(heading).toHaveTextContent(name);
  });
};

// =============================================================================
// Tests
// =============================================================================

describe('PuppetModuleDetailModal', () => {
  beforeEach(() => {
    jest.resetAllMocks();
    capturedOnSaved = null;
    capturedOnCancel = null;
    // Default: both API calls succeed
    mockGetPuppetModule.mockResolvedValue(MODULE);
    mockGetPuppetResources.mockResolvedValue([RESOURCE_A, RESOURCE_B]);
  });

  // ---------------------------------------------------------------------------
  // Closed state
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Puppet Module Details')).not.toBeInTheDocument();
    expect(screen.queryByRole('heading', { level: 2 })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows "Loading..." in the heading while fetching data', async () => {
    // Never resolve to keep it in loading state
    mockGetPuppetModule.mockReturnValue(new Promise(() => {}));
    mockGetPuppetResources.mockReturnValue(new Promise(() => {}));

    renderModal();

    expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('Loading...');
  });

  // ---------------------------------------------------------------------------
  // Data fetching — correct API calls
  // ---------------------------------------------------------------------------

  it('calls getPuppetModule and getPuppetResources with the correct moduleId', async () => {
    renderModal({ moduleId: 'mod-1' });

    await waitForModuleLoaded();

    expect(mockGetPuppetModule).toHaveBeenCalledWith('mod-1');
    expect(mockGetPuppetResources).toHaveBeenCalledWith('mod-1');
  });

  it('does not fetch when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(mockGetPuppetModule).not.toHaveBeenCalled();
    expect(mockGetPuppetResources).not.toHaveBeenCalled();
  });

  it('does not fetch when moduleId is null', () => {
    renderModal({ moduleId: null });
    expect(mockGetPuppetModule).not.toHaveBeenCalled();
    expect(mockGetPuppetResources).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error message when fetching fails', async () => {
    mockGetPuppetModule.mockRejectedValue(new Error('Network Error'));
    mockGetPuppetResources.mockRejectedValue(new Error('Network Error'));

    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Failed to load module details')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Info tab — renders after load
  // ---------------------------------------------------------------------------

  it('renders the module name in the h2 header after loading', async () => {
    renderModal();
    await waitForModuleLoaded('nginx');
    expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent('nginx');
  });

  it('shows version in header subtitle', async () => {
    renderModal();
    await waitForModuleLoaded();
    expect(screen.getByText('v1.2.3')).toBeInTheDocument();
  });

  it('renders Info tab content: description, author, license, forge_name', async () => {
    renderModal();
    await waitForModuleLoaded();

    expect(screen.getByText('Manages nginx web server')).toBeInTheDocument();
    expect(screen.getByText('ops-team')).toBeInTheDocument();
    expect(screen.getByText('MIT')).toBeInTheDocument();
    expect(screen.getByText('example-nginx')).toBeInTheDocument();
  });

  it('renders source_url and project_url as external links', async () => {
    renderModal();
    await waitForModuleLoaded();

    const sourceLink = screen.getByText('https://github.com/example/nginx');
    expect(sourceLink.closest('a')).toHaveAttribute('href', 'https://github.com/example/nginx');
    expect(sourceLink.closest('a')).toHaveAttribute('target', '_blank');

    const projectLink = screen.getByText('https://example.com/nginx');
    expect(projectLink.closest('a')).toHaveAttribute('href', 'https://example.com/nginx');
    expect(projectLink.closest('a')).toHaveAttribute('target', '_blank');
  });

  it('shows Enabled status when module.enabled is true', async () => {
    renderModal();
    await waitForModuleLoaded();
    // Status area shows "Enabled"
    expect(screen.getByText('Enabled')).toBeInTheDocument();
  });

  it('shows Disabled status when module.enabled is false', async () => {
    mockGetPuppetModule.mockResolvedValue({ ...MODULE, enabled: false });
    renderModal();
    await waitForModuleLoaded();
    expect(screen.getByText('Disabled')).toBeInTheDocument();
  });

  it('shows Private when module.public is false', async () => {
    renderModal();
    await waitForModuleLoaded();
    expect(screen.getByText('Private')).toBeInTheDocument();
  });

  it('shows Public when module.public is true', async () => {
    mockGetPuppetModule.mockResolvedValue({ ...MODULE, public: true });
    renderModal();
    await waitForModuleLoaded();
    expect(screen.getByText('Public')).toBeInTheDocument();
  });

  it('shows resource_count and assigned_modules_count in status area', async () => {
    renderModal();
    await waitForModuleLoaded();
    expect(screen.getByText('2 Resources')).toBeInTheDocument();
    expect(screen.getByText('3 Assigned')).toBeInTheDocument();
  });

  it('renders Created and Updated timestamp labels', async () => {
    renderModal();
    await waitForModuleLoaded();
    expect(screen.getByText(/Created:/)).toBeInTheDocument();
    expect(screen.getByText(/Updated:/)).toBeInTheDocument();
  });

  it('does not show Forge Name label when forge_name is absent', async () => {
    mockGetPuppetModule.mockResolvedValue({ ...MODULE, forge_name: undefined });
    renderModal();
    await waitForModuleLoaded();
    expect(screen.queryByText('Forge Name')).not.toBeInTheDocument();
  });

  it('renders — for empty description field', async () => {
    mockGetPuppetModule.mockResolvedValue({ ...MODULE, description: undefined });
    renderModal();
    await waitForModuleLoaded();
    // The — dash for empty description
    expect(screen.getAllByText('—').length).toBeGreaterThan(0);
  });

  it('does not show URL section when both source_url and project_url are absent', async () => {
    mockGetPuppetModule.mockResolvedValue({
      ...MODULE,
      source_url: undefined,
      project_url: undefined,
    });
    renderModal();
    await waitForModuleLoaded();
    expect(screen.queryByText('Source URL')).not.toBeInTheDocument();
    expect(screen.queryByText('Project URL')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tab navigation
  // ---------------------------------------------------------------------------

  it('renders all four tab buttons', async () => {
    renderModal();
    await waitForModuleLoaded();

    // Tabs are plain buttons containing the label text
    expect(screen.getByText('Information')).toBeInTheDocument();
    expect(screen.getByText('Resources')).toBeInTheDocument();
    expect(screen.getByText('Dependencies')).toBeInTheDocument();
    expect(screen.getByText('Metadata')).toBeInTheDocument();
  });

  it('defaults to the Info tab showing module details', async () => {
    renderModal();
    await waitForModuleLoaded();
    // Info tab content is visible by default
    expect(screen.getByText('Manages nginx web server')).toBeInTheDocument();
    expect(screen.getByText('ops-team')).toBeInTheDocument();
  });

  it('switches to Resources tab when clicked', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));

    await waitFor(() =>
      expect(screen.getByText('nginx_conf')).toBeInTheDocument(),
    );
  });

  it('switches to Dependencies tab when clicked', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Dependencies'));

    await waitFor(() =>
      expect(screen.getByText('stdlib')).toBeInTheDocument(),
    );
  });

  it('switches to Metadata tab when clicked', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Metadata'));

    await waitFor(() =>
      expect(screen.getByText('Configuration')).toBeInTheDocument(),
    );
  });

  it('shows count badges on Resources and Dependencies tabs', async () => {
    renderModal();
    await waitForModuleLoaded();

    // Resources tab: count = resources.length = 2
    // Dependencies tab: count = module.dependencies.length = 2
    // Both badges show "2"
    const countBadges = screen.getAllByText('2');
    expect(countBadges.length).toBeGreaterThanOrEqual(2);
  });

  // ---------------------------------------------------------------------------
  // Resources tab — rendering
  // ---------------------------------------------------------------------------

  it('renders each resource name and type on the Resources tab', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));

    await waitFor(() => expect(screen.getByText('nginx_conf')).toBeInTheDocument());
    expect(screen.getByText('nginx_service')).toBeInTheDocument();
    // resource type badges
    const fileBadges = screen.getAllByText('file');
    expect(fileBadges.length).toBeGreaterThan(0);
    const serviceBadges = screen.getAllByText('service');
    expect(serviceBadges.length).toBeGreaterThan(0);
  });

  it('shows exported badge on exported resources', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));

    await waitFor(() => expect(screen.getByText('nginx_service')).toBeInTheDocument());
    expect(screen.getByText('exported')).toBeInTheDocument();
  });

  it('shows enabled/disabled status badge for each resource', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));

    await waitFor(() => expect(screen.getByText('nginx_conf')).toBeInTheDocument());
    // resource A: Enabled, resource B: Disabled
    const enabledBadges = screen.getAllByText('Enabled');
    const disabledBadges = screen.getAllByText('Disabled');
    expect(enabledBadges.length).toBeGreaterThan(0);
    expect(disabledBadges.length).toBeGreaterThan(0);
  });

  it('renders resource parameters as formatted JSON', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));

    await waitFor(() => expect(screen.getByText('nginx_conf')).toBeInTheDocument());
    // RESOURCE_A has parameters: { owner: 'root' }
    expect(screen.getByText(/"owner"/)).toBeInTheDocument();
  });

  it('renders resource data field content', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));

    await waitFor(() =>
      expect(screen.getByText('worker_processes auto;')).toBeInTheDocument(),
    );
  });

  it('renders resource description', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));

    await waitFor(() =>
      expect(screen.getByText('Main config')).toBeInTheDocument(),
    );
  });

  it('renders resource path in monospace', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));

    await waitFor(() =>
      expect(screen.getAllByText('/etc/nginx/nginx.conf').length).toBeGreaterThan(0),
    );
  });

  it('shows empty state when there are no resources', async () => {
    mockGetPuppetResources.mockResolvedValue([]);
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));

    await waitFor(() =>
      expect(screen.getByText('No resources defined')).toBeInTheDocument(),
    );
    expect(
      screen.getByText('Click "Add Resource" to define your first Puppet resource.'),
    ).toBeInTheDocument();
  });

  it('shows "Add Resource" button when user has create permission', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add resource/i })).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Resources tab — Add Resource form flow
  // ---------------------------------------------------------------------------

  it('opens the resource form in create mode when "Add Resource" is clicked', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add resource/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /add resource/i }));

    await waitFor(() =>
      expect(screen.getByTestId('puppet-resource-form')).toBeInTheDocument(),
    );
    // Form is in create mode — no resource.id
    expect(screen.getByTestId('form-resource-id')).toHaveTextContent('create-mode');
    // Passes correct module id
    expect(screen.getByTestId('form-module-id')).toHaveTextContent('mod-1');
  });

  it('hides the "Add Resource" button while the form is open', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add resource/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /add resource/i }));

    await waitFor(() =>
      expect(screen.queryByRole('button', { name: /add resource/i })).not.toBeInTheDocument(),
    );
  });

  it('closes the form and re-shows "Add Resource" when cancel is clicked', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add resource/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add resource/i }));
    await waitFor(() =>
      expect(screen.getByTestId('puppet-resource-form')).toBeInTheDocument(),
    );

    // Click the cancel button inside the mocked form
    fireEvent.click(screen.getByRole('button', { name: /cancel form/i }));

    await waitFor(() =>
      expect(screen.queryByTestId('puppet-resource-form')).not.toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: /add resource/i })).toBeInTheDocument();
  });

  it('adds a new resource to the list when onSaved is called with a new resource', async () => {
    mockGetPuppetResources.mockResolvedValue([]);
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add resource/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /add resource/i }));

    await waitFor(() =>
      expect(screen.getByTestId('puppet-resource-form')).toBeInTheDocument(),
    );

    // Simulate form saving a new resource via the captured callback
    const newResource: SystemPuppetResource = { ...RESOURCE_A, id: 'res-new', name: 'new_res' };
    await waitFor(() => expect(capturedOnSaved).not.toBeNull());
    capturedOnSaved!(newResource);

    await waitFor(() =>
      expect(screen.getByText('new_res')).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('puppet-resource-form')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Resources tab — Edit flow
  // ---------------------------------------------------------------------------

  it('opens the form in edit mode when the Edit button is clicked', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() => expect(screen.getByText('nginx_conf')).toBeInTheDocument());

    const editButtons = screen.getAllByTitle('Edit Resource');
    fireEvent.click(editButtons[0]);

    await waitFor(() =>
      expect(screen.getByTestId('puppet-resource-form')).toBeInTheDocument(),
    );
    // Edit mode shows the resource id, not "create-mode"
    expect(screen.getByTestId('form-resource-id')).toHaveTextContent('res-a');
  });

  it('updates an existing resource in the list when onSaved is called with the same id', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() => expect(screen.getByText('nginx_conf')).toBeInTheDocument());

    fireEvent.click(screen.getAllByTitle('Edit Resource')[0]);
    await waitFor(() =>
      expect(screen.getByTestId('puppet-resource-form')).toBeInTheDocument(),
    );

    // Simulate saving an updated version of RESOURCE_A
    const updated: SystemPuppetResource = { ...RESOURCE_A, name: 'nginx_conf_updated' };
    await waitFor(() => expect(capturedOnSaved).not.toBeNull());
    capturedOnSaved!(updated);

    await waitFor(() =>
      expect(screen.getByText('nginx_conf_updated')).toBeInTheDocument(),
    );
    expect(screen.queryByText('nginx_conf')).not.toBeInTheDocument();
    expect(screen.queryByTestId('puppet-resource-form')).not.toBeInTheDocument();
  });

  it('disables Edit and Delete buttons while a form is already open', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /add resource/i })).toBeInTheDocument(),
    );

    // Open form
    fireEvent.click(screen.getByRole('button', { name: /add resource/i }));
    await waitFor(() =>
      expect(screen.getByTestId('puppet-resource-form')).toBeInTheDocument(),
    );

    // Edit and Delete buttons should be disabled
    screen.queryAllByTitle('Edit Resource').forEach(btn => expect(btn).toBeDisabled());
    screen.queryAllByTitle('Delete Resource').forEach(btn => expect(btn).toBeDisabled());
  });

  // ---------------------------------------------------------------------------
  // Resources tab — Delete flow
  // ---------------------------------------------------------------------------

  it('calls deletePuppetResource with correct ids after confirm', async () => {
    mockDeletePuppetResource.mockResolvedValue(undefined);
    jest.spyOn(window, 'confirm').mockReturnValue(true);

    renderModal({ moduleId: 'mod-1' });
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() => expect(screen.getByText('nginx_conf')).toBeInTheDocument());

    fireEvent.click(screen.getAllByTitle('Delete Resource')[0]);

    await waitFor(() =>
      expect(mockDeletePuppetResource).toHaveBeenCalledWith('mod-1', 'res-a'),
    );

    // Resource removed from list
    await waitFor(() =>
      expect(screen.queryByText('nginx_conf')).not.toBeInTheDocument(),
    );
  });

  it('shows a success notification after deleting a resource', async () => {
    mockDeletePuppetResource.mockResolvedValue(undefined);
    jest.spyOn(window, 'confirm').mockReturnValue(true);

    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() => expect(screen.getByText('nginx_conf')).toBeInTheDocument());

    fireEvent.click(screen.getAllByTitle('Delete Resource')[0]);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Deleted nginx_conf',
      }),
    );
  });

  it('shows an error notification when delete fails', async () => {
    mockDeletePuppetResource.mockRejectedValue(new Error('Server Error'));
    jest.spyOn(window, 'confirm').mockReturnValue(true);

    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() => expect(screen.getByText('nginx_conf')).toBeInTheDocument());

    fireEvent.click(screen.getAllByTitle('Delete Resource')[0]);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to delete nginx_conf',
      }),
    );
  });

  it('does not call deletePuppetResource when window.confirm is cancelled', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(false);

    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Resources'));
    await waitFor(() => expect(screen.getByText('nginx_conf')).toBeInTheDocument());

    fireEvent.click(screen.getAllByTitle('Delete Resource')[0]);

    // Small tick to let any async code settle
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(mockDeletePuppetResource).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Dependencies tab
  // ---------------------------------------------------------------------------

  it('renders each dependency name and version requirement', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Dependencies'));

    await waitFor(() => expect(screen.getByText('stdlib')).toBeInTheDocument());
    expect(screen.getByText('>= 4.0.0')).toBeInTheDocument();
    expect(screen.getByText('apt')).toBeInTheDocument();
  });

  it('shows no-dependencies empty state when dependencies list is empty', async () => {
    mockGetPuppetModule.mockResolvedValue({ ...MODULE, dependencies: [] });
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Dependencies'));

    await waitFor(() =>
      expect(screen.getByText('No dependencies')).toBeInTheDocument(),
    );
    expect(
      screen.getByText('This module has no external dependencies'),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Metadata tab
  // ---------------------------------------------------------------------------

  it('renders Configuration heading and JSON on Metadata tab', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Metadata'));

    await waitFor(() => expect(screen.getByText('Configuration')).toBeInTheDocument());
    expect(screen.getByText(/"worker_processes"/)).toBeInTheDocument();
  });

  it('shows "No configuration defined" when config is empty', async () => {
    mockGetPuppetModule.mockResolvedValue({ ...MODULE, config: {} });
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Metadata'));

    await waitFor(() =>
      expect(screen.getByText('No configuration defined')).toBeInTheDocument(),
    );
  });

  it('shows "No metadata defined" when metadata is empty', async () => {
    mockGetPuppetModule.mockResolvedValue({ ...MODULE, metadata: {} });
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Metadata'));

    await waitFor(() =>
      expect(screen.getByText('No metadata defined')).toBeInTheDocument(),
    );
  });

  it('renders resource_types as badges on Metadata tab', async () => {
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Metadata'));

    await waitFor(() => expect(screen.getByText('Resource Types')).toBeInTheDocument());
    const fileBadges = screen.getAllByText('file');
    expect(fileBadges.length).toBeGreaterThan(0);
    const serviceBadges = screen.getAllByText('service');
    expect(serviceBadges.length).toBeGreaterThan(0);
  });

  it('does not render Resource Types section when resource_types is empty', async () => {
    mockGetPuppetModule.mockResolvedValue({ ...MODULE, resource_types: [] });
    renderModal();
    await waitForModuleLoaded();

    fireEvent.click(screen.getByText('Metadata'));

    await waitFor(() => expect(screen.getByText('Configuration')).toBeInTheDocument());
    expect(screen.queryByText('Resource Types')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Header actions
  // ---------------------------------------------------------------------------

  it('calls onClose when the ghost X button is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    await waitForModuleLoaded();

    // The X button has an svg icon inside; find it by its container role
    // The ghost close button is in the header flex row alongside the Edit button
    const ghostButtons = screen.getAllByRole('button');
    // Find the button with no text that is in the header (contains an X svg)
    // The header close is before the footer "Close" button
    // We can find the ghost button because it comes before the footer
    const xButton = ghostButtons.find(b => b.title === '' && !b.textContent?.trim());
    if (xButton) {
      fireEvent.click(xButton);
    } else {
      // Fallback: find button closest to the header containing an svg with X paths
      const allButtons = screen.getAllByRole('button');
      // The ghost X button is typically found by clicking at position near svg
      fireEvent.click(allButtons.find(b => b.className.includes('ghost')) ?? allButtons[0]);
    }

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when the backdrop overlay is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    await waitForModuleLoaded();

    // The backdrop is the fixed overlay div with bg-black/50
    const backdrop = document.querySelector('.fixed.inset-0.bg-black\\/50');
    if (backdrop) fireEvent.click(backdrop);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onEdit with the loaded module when the Edit button is clicked', async () => {
    const onEdit = jest.fn();
    renderModal({ onEdit });
    await waitForModuleLoaded();

    fireEvent.click(screen.getByRole('button', { name: /^edit$/i }));
    expect(onEdit).toHaveBeenCalledWith(MODULE);
  });

  it('does not render the module Edit button when onEdit prop is not provided', async () => {
    render(
      <BrowserRouter>
        <PuppetModuleDetailModal moduleId="mod-1" isOpen onClose={jest.fn()} />
      </BrowserRouter>,
    );
    await waitForModuleLoaded();
    // No Edit button (only Close footer button remains)
    expect(screen.queryByRole('button', { name: /^edit$/i })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Footer close button
  // ---------------------------------------------------------------------------

  it('calls onClose when the footer Close button is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    await waitForModuleLoaded();

    // The footer has a button with text "Close"
    fireEvent.click(screen.getByRole('button', { name: /^close$/i }));
    expect(onClose).toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Re-fetch on moduleId/isOpen change
  // ---------------------------------------------------------------------------

  it('re-fetches when moduleId changes while modal stays open', async () => {
    const MODULE_2: SystemPuppetModule = { ...MODULE, id: 'mod-2', name: 'apache' };

    const { rerender } = renderModal({ moduleId: 'mod-1' });
    await waitForModuleLoaded('nginx');

    mockGetPuppetModule.mockResolvedValue(MODULE_2);
    mockGetPuppetResources.mockResolvedValue([]);

    rerender(
      <BrowserRouter>
        <PuppetModuleDetailModal moduleId="mod-2" isOpen onClose={jest.fn()} />
      </BrowserRouter>,
    );

    await waitForModuleLoaded('apache');
    expect(mockGetPuppetModule).toHaveBeenCalledWith('mod-2');
  });

  it('resets to Info tab and clears resource form when re-fetching a new moduleId', async () => {
    const MODULE_2: SystemPuppetModule = {
      ...MODULE,
      id: 'mod-2',
      name: 'apache',
      dependencies: [],
      description: 'Apache HTTP',
    };

    const { rerender } = renderModal({ moduleId: 'mod-1', isOpen: true });
    await waitForModuleLoaded('nginx');

    // Switch to Dependencies tab
    fireEvent.click(screen.getByText('Dependencies'));
    await waitFor(() => expect(screen.getByText('stdlib')).toBeInTheDocument());

    // Reopen with new module
    mockGetPuppetModule.mockResolvedValue(MODULE_2);
    mockGetPuppetResources.mockResolvedValue([]);

    rerender(
      <BrowserRouter>
        <PuppetModuleDetailModal moduleId="mod-2" isOpen onClose={jest.fn()} />
      </BrowserRouter>,
    );

    // After reload, heading shows the new module name
    await waitForModuleLoaded('apache');
    // Info tab is active — shows the new description
    await waitFor(() =>
      expect(screen.getByText('Apache HTTP')).toBeInTheDocument(),
    );
    // Dependencies empty state should not be visible (we're on info tab)
    expect(screen.queryByText('No dependencies')).not.toBeInTheDocument();
  });
});
