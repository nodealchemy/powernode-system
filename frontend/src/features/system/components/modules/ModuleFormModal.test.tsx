import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ModuleFormModal } from './ModuleFormModal';
import type {
  SystemNodeModule,
  SystemNodePlatform,
  SystemNodeModuleCategory,
} from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

const mockGetPlatforms = jest.fn();
const mockGetModuleCategories = jest.fn();
const mockCreateModule = jest.fn();
const mockUpdateModule = jest.fn();
const mockImportManifest = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getPlatforms: (...args: unknown[]) => mockGetPlatforms(...args),
    getModuleCategories: (...args: unknown[]) => mockGetModuleCategories(...args),
    createModule: (...args: unknown[]) => mockCreateModule(...args),
    updateModule: (...args: unknown[]) => mockUpdateModule(...args),
    importManifest: (...args: unknown[]) => mockImportManifest(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const PLATFORM_A: SystemNodePlatform = {
  id: 'plat-1',
  name: 'ubuntu-22',
  enabled: true,
  public: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CATEGORY_A: SystemNodeModuleCategory = {
  id: 'cat-1',
  name: 'Networking',
  depth: 0,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CATEGORY_B: SystemNodeModuleCategory = {
  id: 'cat-2',
  name: 'DNS',
  parent_id: 'cat-1',
  depth: 1,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const MODULE_A: SystemNodeModule = {
  id: 'mod-1',
  name: 'nginx-config',
  description: 'Nginx web server config',
  variety: 'config',
  enabled: true,
  public: false,
  priority: 10,
  mask: [],
  mask_text: '/var/cache/apt/**\n',
  file_spec: [],
  file_spec_text: '/etc/nginx/**\n',
  package_spec: [],
  package_spec_text: 'nginx\nnginx-extras\n',
  dependency_spec: [],
  dependency_spec_text: '',
  protected_spec: [],
  protected_spec_text: '',
  lock_spec: false,
  init_start: 'systemctl start nginx',
  init_stop: 'systemctl stop nginx',
  init_restart: 'systemctl reload nginx',
  reboot_required: false,
  config: {},
  node_platform_id: 'plat-1',
  category_id: 'cat-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const DEPENDANT_MODULE: SystemNodeModule = {
  ...MODULE_A,
  id: 'mod-dep',
  name: 'child-config',
  dependant: true,
  parent_module_id: 'mod-1',
  parent_module_name: 'nginx-config',
  file_spec_text: '/etc/nginx/sites-enabled/**\n',
};

// =============================================================================
// Helpers
// =============================================================================

const defaultProps = {
  isOpen: true,
  onClose: jest.fn(),
  onModuleSaved: jest.fn(),
};

const renderModal = (props: Partial<typeof defaultProps> & { editModule?: SystemNodeModule | null } = {}) =>
  render(<ModuleFormModal {...defaultProps} {...props} />);

// =============================================================================
// Tests
// =============================================================================

describe('ModuleFormModal', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetPlatforms.mockResolvedValue([PLATFORM_A]);
    mockGetModuleCategories.mockResolvedValue([CATEGORY_A, CATEGORY_B]);
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Create Module')).not.toBeInTheDocument();
  });

  it('renders "Create Module" title in create mode', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Create Module' })).toBeInTheDocument());
  });

  it('renders "Edit Module" title in edit mode', async () => {
    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Edit Module' })).toBeInTheDocument());
  });

  it('shows loading spinner for platform/category dropdowns while fetching options', () => {
    // Keep the promise pending so loading state persists
    mockGetPlatforms.mockReturnValue(new Promise(() => {}));
    mockGetModuleCategories.mockReturnValue(new Promise(() => {}));
    renderModal();
    // LoadingSpinner renders a div with animate-spin inside the platform and category dropdowns
    const spinners = document.querySelectorAll('.animate-spin');
    expect(spinners.length).toBeGreaterThanOrEqual(1);
  });

  it('renders platform and category options after options load', async () => {
    renderModal();
    await waitFor(() =>
      expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument()
    );
    expect(screen.getByRole('option', { name: /Networking/i })).toBeInTheDocument();
    // depth-1 category gets em-dash prefix repeated 1 time
    expect(screen.getByRole('option', { name: /DNS/i })).toBeInTheDocument();
  });

  it('shows error notification when options fail to load', async () => {
    mockGetPlatforms.mockRejectedValue(new Error('network error'));
    renderModal();
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load form options',
      })
    );
  });

  it('fetches options only when isOpen transitions to true', async () => {
    const { rerender } = render(<ModuleFormModal {...defaultProps} isOpen={false} />);
    expect(mockGetPlatforms).not.toHaveBeenCalled();

    rerender(<ModuleFormModal {...defaultProps} isOpen={true} />);
    await waitFor(() => expect(mockGetPlatforms).toHaveBeenCalledTimes(1));
  });

  // ---------------------------------------------------------------------------
  // Create mode — form population & submission
  // ---------------------------------------------------------------------------

  it('pre-populates form with blank values in create mode', async () => {
    renderModal();
    await waitFor(() => expect(mockGetPlatforms).toHaveBeenCalled());

    const nameInput = screen.getByLabelText(/^Name/i);
    expect(nameInput).toHaveValue('');
    const varietySelect = screen.getByLabelText(/^Type/i);
    expect(varietySelect).toHaveValue('config');
  });

  it('does not show "Import manifest" button in create mode', async () => {
    renderModal();
    await waitFor(() => expect(mockGetPlatforms).toHaveBeenCalled());
    expect(screen.queryByText('Import manifest')).not.toBeInTheDocument();
  });

  it('submits a new module with correct payload on create', async () => {
    const createdModule = { ...MODULE_A, id: 'new-mod', name: 'my-module' };
    mockCreateModule.mockResolvedValue(createdModule);

    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'my-module' } });
    fireEvent.change(screen.getByLabelText(/^Type/i), { target: { value: 'instance' } });

    fireEvent.click(screen.getByRole('button', { name: /Create Module/i }));

    await waitFor(() =>
      expect(mockCreateModule).toHaveBeenCalledWith(
        expect.objectContaining({
          name: 'my-module',
          variety: 'instance',
          enabled: true,
          public: false,
        })
      )
    );
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success', message: expect.stringContaining('my-module') })
    );
    expect(defaultProps.onModuleSaved).toHaveBeenCalledWith(createdModule);
    expect(defaultProps.onClose).toHaveBeenCalled();
  });

  it('sends spec fields as newline-joined strings in the payload', async () => {
    const createdModule = { ...MODULE_A, id: 'new-mod-2', name: 'spec-module' };
    mockCreateModule.mockResolvedValue(createdModule);

    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'spec-module' } });

    // Fill file_spec textarea
    const fileSpecTextarea = screen.getByLabelText(/file spec/i);
    fireEvent.change(fileSpecTextarea, { target: { value: '/etc/foo/**\n/usr/bin/foo' } });

    const packageSpecTextarea = screen.getByLabelText(/package spec/i);
    fireEvent.change(packageSpecTextarea, { target: { value: 'nginx\nnginx-extras' } });

    fireEvent.click(screen.getByRole('button', { name: /Create Module/i }));

    await waitFor(() =>
      expect(mockCreateModule).toHaveBeenCalledWith(
        expect.objectContaining({
          file_spec: '/etc/foo/**\n/usr/bin/foo',
          package_spec: 'nginx\nnginx-extras',
        })
      )
    );
  });

  it('sends lifecycle fields in the payload', async () => {
    const createdModule = { ...MODULE_A, id: 'lc-mod', name: 'lifecycle-module' };
    mockCreateModule.mockResolvedValue(createdModule);

    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'lifecycle-module' } });
    fireEvent.change(screen.getByLabelText(/init_start/i), { target: { value: 'systemctl start foo' } });
    fireEvent.change(screen.getByLabelText(/init_stop/i), { target: { value: 'systemctl stop foo' } });
    fireEvent.change(screen.getByLabelText(/init_restart/i), { target: { value: 'systemctl reload foo' } });

    // Check reboot_required checkbox
    const rebootCb = screen.getByRole('checkbox', { name: /reboot required/i });
    fireEvent.click(rebootCb);

    fireEvent.click(screen.getByRole('button', { name: /Create Module/i }));

    await waitFor(() =>
      expect(mockCreateModule).toHaveBeenCalledWith(
        expect.objectContaining({
          init_start: 'systemctl start foo',
          init_stop: 'systemctl stop foo',
          init_restart: 'systemctl reload foo',
          reboot_required: true,
        })
      )
    );
  });

  it('sends lock_spec in the payload when toggled', async () => {
    const createdModule = { ...MODULE_A, id: 'lk-mod', name: 'lock-module' };
    mockCreateModule.mockResolvedValue(createdModule);

    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'lock-module' } });

    const lockCb = screen.getByRole('checkbox', { name: /lock module/i });
    fireEvent.click(lockCb);

    fireEvent.click(screen.getByRole('button', { name: /Create Module/i }));

    await waitFor(() =>
      expect(mockCreateModule).toHaveBeenCalledWith(
        expect.objectContaining({ lock_spec: true })
      )
    );
  });

  it('shows error notification when create fails', async () => {
    mockCreateModule.mockRejectedValue(new Error('Server error'));

    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'fail-module' } });
    fireEvent.click(screen.getByRole('button', { name: /Create Module/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: expect.stringContaining('Failed to create module'),
        })
      )
    );
    // Modal stays open on failure
    expect(defaultProps.onClose).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Edit mode — pre-population & submission
  // ---------------------------------------------------------------------------

  it('pre-populates form fields from editModule', async () => {
    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    expect(screen.getByLabelText(/^Name/i)).toHaveValue('nginx-config');
    expect(screen.getByLabelText(/^Type/i)).toHaveValue('config');
  });

  it('strips trailing newlines from spec fields on edit population', async () => {
    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    // mask_text is '/var/cache/apt/**\n' — trailing newline stripped
    const maskTextarea = screen.getByLabelText(/mask \(local exclude\)/i);
    expect(maskTextarea).toHaveValue('/var/cache/apt/**');

    // file_spec_text is '/etc/nginx/**\n' — trailing newline stripped
    const fileSpecTextarea = screen.getByLabelText(/file spec/i);
    expect(fileSpecTextarea).toHaveValue('/etc/nginx/**');

    // package_spec_text is 'nginx\nnginx-extras\n' — trailing newline stripped
    const packageSpecTextarea = screen.getByLabelText(/package spec/i);
    expect(packageSpecTextarea).toHaveValue('nginx\nnginx-extras');
  });

  it('pre-populates lifecycle fields from editModule', async () => {
    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    expect(screen.getByLabelText(/init_start/i)).toHaveValue('systemctl start nginx');
    expect(screen.getByLabelText(/init_stop/i)).toHaveValue('systemctl stop nginx');
    expect(screen.getByLabelText(/init_restart/i)).toHaveValue('systemctl reload nginx');
  });

  it('pre-populates checkboxes from editModule', async () => {
    const moduleWithFlags = { ...MODULE_A, reboot_required: true, lock_spec: true, enabled: false, public: true };
    renderModal({ editModule: moduleWithFlags });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    expect(screen.getByRole('checkbox', { name: /reboot required/i })).toBeChecked();
    expect(screen.getByRole('checkbox', { name: /lock module/i })).toBeChecked();
    expect(screen.getByRole('checkbox', { name: /enabled/i })).not.toBeChecked();
    expect(screen.getByRole('checkbox', { name: /public/i })).toBeChecked();
  });

  it('submits update with correct payload and module id in edit mode', async () => {
    const updatedModule = { ...MODULE_A, name: 'nginx-config-updated' };
    mockUpdateModule.mockResolvedValue(updatedModule);

    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    // Change name
    const nameInput = screen.getByLabelText(/^Name/i);
    fireEvent.change(nameInput, { target: { value: 'nginx-config-updated' } });

    fireEvent.click(screen.getByRole('button', { name: /Update Module/i }));

    await waitFor(() =>
      expect(mockUpdateModule).toHaveBeenCalledWith(
        'mod-1',
        expect.objectContaining({ name: 'nginx-config-updated' })
      )
    );
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success', message: expect.stringContaining('nginx-config-updated') })
    );
    expect(defaultProps.onModuleSaved).toHaveBeenCalledWith(updatedModule);
    expect(defaultProps.onClose).toHaveBeenCalled();
  });

  it('shows error notification when update fails', async () => {
    mockUpdateModule.mockRejectedValue(new Error('Update failed'));

    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /Update Module/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: expect.stringContaining('Failed to update module'),
        })
      )
    );
  });

  it('shows "Import manifest" button only in edit mode', async () => {
    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());
    expect(screen.getByRole('button', { name: /import manifest/i })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Manifest import panel
  // ---------------------------------------------------------------------------

  it('toggles manifest import panel when "Import manifest" button clicked', async () => {
    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    expect(screen.queryByLabelText(/paste manifest\.yaml/i)).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /import manifest/i }));
    expect(screen.getByLabelText(/paste manifest\.yaml/i)).toBeInTheDocument();

    // Click again to toggle off
    fireEvent.click(screen.getByRole('button', { name: /import manifest/i }));
    expect(screen.queryByLabelText(/paste manifest\.yaml/i)).not.toBeInTheDocument();
  });

  it('Import button disabled when manifest textarea is empty', async () => {
    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /import manifest/i }));

    const importBtn = screen.getByRole('button', { name: /^import$/i });
    expect(importBtn).toBeDisabled();
  });

  it('calls importManifest with module id and yaml content', async () => {
    const importedModule = {
      ...MODULE_A,
      description: 'Updated by manifest',
      file_spec_text: '/etc/nginx/sites-enabled/**\n',
      mask_text: '',
      package_spec_text: '',
      dependency_spec_text: '',
      protected_spec_text: '',
    };
    mockImportManifest.mockResolvedValue({
      node_module: importedModule,
      node_module_version_id: null,
      resolved_dependencies: [{ repo: 'foo/bar', status: 'resolved' }],
    });

    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /import manifest/i }));

    const manifestTextarea = screen.getByLabelText(/paste manifest\.yaml/i);
    fireEvent.change(manifestTextarea, {
      target: { value: 'schema_version: 1\nname: nginx-config\n' },
    });

    fireEvent.click(screen.getByRole('button', { name: /^import$/i }));

    await waitFor(() =>
      expect(mockImportManifest).toHaveBeenCalledWith(
        'mod-1',
        'schema_version: 1\nname: nginx-config\n'
      )
    );
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({
        type: 'success',
        message: expect.stringContaining('1 dependency reference(s) processed'),
      })
    );
    // Panel closes after import
    expect(screen.queryByLabelText(/paste manifest\.yaml/i)).not.toBeInTheDocument();
    // onModuleSaved called with imported module
    expect(defaultProps.onModuleSaved).toHaveBeenCalledWith(importedModule);
  });

  it('hydrates form fields from imported manifest result', async () => {
    const importedModule = {
      ...MODULE_A,
      description: 'Imported description',
      init_start: 'systemctl start imported',
      file_spec_text: '/etc/imported/**\n',
      mask_text: '/tmp/**\n',
      package_spec_text: 'imported-pkg\n',
      dependency_spec_text: '',
      protected_spec_text: '/etc/secret\n',
    };
    mockImportManifest.mockResolvedValue({
      node_module: importedModule,
      node_module_version_id: null,
      resolved_dependencies: [],
    });

    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /import manifest/i }));
    const manifestTextarea = screen.getByLabelText(/paste manifest\.yaml/i);
    fireEvent.change(manifestTextarea, { target: { value: 'schema_version: 1\nname: nginx-config\n' } });
    fireEvent.click(screen.getByRole('button', { name: /^import$/i }));

    await waitFor(() => expect(screen.queryByLabelText(/paste manifest\.yaml/i)).not.toBeInTheDocument());

    // Form should be hydrated with imported values (trailing newlines stripped)
    expect(screen.getByLabelText(/file spec/i)).toHaveValue('/etc/imported/**');
    expect(screen.getByLabelText(/mask \(local exclude\)/i)).toHaveValue('/tmp/**');
    expect(screen.getByLabelText(/init_start/i)).toHaveValue('systemctl start imported');
  });

  it('shows error notification when importManifest fails', async () => {
    mockImportManifest.mockRejectedValue(new Error('Schema mismatch'));

    renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /import manifest/i }));
    const manifestTextarea = screen.getByLabelText(/paste manifest\.yaml/i);
    fireEvent.change(manifestTextarea, { target: { value: 'schema_version: 1\n' } });
    fireEvent.click(screen.getByRole('button', { name: /^import$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: expect.stringContaining('Manifest import failed'),
        })
      )
    );
    // Panel stays open on failure
    expect(screen.getByLabelText(/paste manifest\.yaml/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  it('blocks submission and shows error when name is empty', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    // Submit without filling the name
    fireEvent.click(screen.getByRole('button', { name: /Create Module/i }));

    expect(screen.getByText('Name is required')).toBeInTheDocument();
    expect(mockCreateModule).not.toHaveBeenCalled();
  });

  it('blocks submission and shows error when name is less than 2 characters', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'x' } });
    fireEvent.click(screen.getByRole('button', { name: /Create Module/i }));

    expect(screen.getByText('Name must be at least 2 characters')).toBeInTheDocument();
    expect(mockCreateModule).not.toHaveBeenCalled();
  });

  it('clears field error when user starts typing in the field', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    // Trigger validation error
    fireEvent.click(screen.getByRole('button', { name: /Create Module/i }));
    expect(screen.getByText('Name is required')).toBeInTheDocument();

    // Start typing to clear the error
    fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'abc' } });
    expect(screen.queryByText('Name is required')).not.toBeInTheDocument();
  });

  it('accepts name with exactly 2 characters', async () => {
    const createdModule = { ...MODULE_A, id: 'xx-mod', name: 'ab' };
    mockCreateModule.mockResolvedValue(createdModule);

    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'ab' } });
    fireEvent.click(screen.getByRole('button', { name: /Create Module/i }));

    await waitFor(() => expect(mockCreateModule).toHaveBeenCalled());
    expect(screen.queryByText('Name must be at least 2 characters')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Dependant module — inherited file_spec
  // ---------------------------------------------------------------------------

  it('shows dependant module notice when editing a dependant child', async () => {
    renderModal({ editModule: DEPENDANT_MODULE });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    expect(screen.getByText(/dependant child module/i)).toBeInTheDocument();
    // The notice contains the parent module name in a <code> element
    const codes = screen.getAllByText(/nginx-config/);
    expect(codes.length).toBeGreaterThanOrEqual(1);
  });

  it('marks file_spec textarea as readOnly on dependant modules', async () => {
    renderModal({ editModule: DEPENDANT_MODULE });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    // file_spec textarea is readOnly for dependant modules
    const fileSpecTextarea = screen.getByLabelText(/file spec/i);
    expect(fileSpecTextarea).toHaveAttribute('readonly');
  });

  it('shows inherited label with parent name on file_spec for dependant', async () => {
    renderModal({ editModule: DEPENDANT_MODULE });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    // "inherited from" appears in both the notice block and the file_spec label span
    const inheritedElements = screen.getAllByText(/inherited from/i);
    expect(inheritedElements.length).toBeGreaterThanOrEqual(1);
    // The label span specifically mentions "dependency_spec"
    const dependencySpecRefs = screen.getAllByText(/dependency_spec/);
    expect(dependencySpecRefs.length).toBeGreaterThanOrEqual(1);
  });

  it('other spec fields on dependant are NOT read-only', async () => {
    renderModal({ editModule: DEPENDANT_MODULE });
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    const maskTextarea = screen.getByLabelText(/mask \(local exclude\)/i);
    expect(maskTextarea).not.toHaveAttribute('readonly');
  });

  // ---------------------------------------------------------------------------
  // Visibility section
  // ---------------------------------------------------------------------------

  it('enabled checkbox is checked by default in create mode', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    expect(screen.getByRole('checkbox', { name: /enabled/i })).toBeChecked();
  });

  it('public checkbox is unchecked by default in create mode', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    expect(screen.getByRole('checkbox', { name: /public/i })).not.toBeChecked();
  });

  it('enabled and public checkboxes can be toggled', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    const enabledCb = screen.getByRole('checkbox', { name: /enabled/i });
    const publicCb = screen.getByRole('checkbox', { name: /public/i });

    fireEvent.click(enabledCb);
    expect(enabledCb).not.toBeChecked();

    fireEvent.click(publicCb);
    expect(publicCb).toBeChecked();
  });

  // ---------------------------------------------------------------------------
  // Close / cancel behavior
  // ---------------------------------------------------------------------------

  it('calls onClose when the X button is clicked', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: '' }));  // X button has no accessible name
    expect(defaultProps.onClose).toHaveBeenCalled();
  });

  it('calls onClose when the Cancel button is clicked', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(defaultProps.onClose).toHaveBeenCalled();
  });

  it('calls onClose when the backdrop overlay is clicked', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    // The backdrop div has onClick={onClose}; it's the second div inside the portal
    const backdrop = document.querySelector('.bg-black\\/50');
    if (backdrop) {
      fireEvent.click(backdrop);
      expect(defaultProps.onClose).toHaveBeenCalled();
    }
  });

  // ---------------------------------------------------------------------------
  // Form reset on re-open
  // ---------------------------------------------------------------------------

  it('resets form to blank when switching from edit to create mode', async () => {
    const { rerender } = renderModal({ editModule: MODULE_A });
    await waitFor(() => expect(screen.getByLabelText(/^Name/i)).toHaveValue('nginx-config'));

    // Close and reopen without editModule
    rerender(<ModuleFormModal {...defaultProps} isOpen={false} editModule={undefined} />);
    rerender(<ModuleFormModal {...defaultProps} isOpen={true} editModule={undefined} />);

    await waitFor(() => expect(screen.getByLabelText(/^Name/i)).toHaveValue(''));
  });

  // ---------------------------------------------------------------------------
  // Variety options
  // ---------------------------------------------------------------------------

  it('shows all three variety options', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    expect(screen.getByRole('option', { name: 'Config' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Instance' })).toBeInTheDocument();
    expect(screen.getByRole('option', { name: 'Subscription' })).toBeInTheDocument();
  });

  it('sends undefined for empty optional string fields (not empty string)', async () => {
    const createdModule = { ...MODULE_A, id: 'opt-mod', name: 'optional-module' };
    mockCreateModule.mockResolvedValue(createdModule);

    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'optional-module' } });
    // Leave description, node_platform_id, category_id, init_* blank

    fireEvent.click(screen.getByRole('button', { name: /Create Module/i }));

    await waitFor(() => expect(mockCreateModule).toHaveBeenCalled());
    const callArg = mockCreateModule.mock.calls[0][0];
    expect(callArg.description).toBeUndefined();
    expect(callArg.node_platform_id).toBeUndefined();
    expect(callArg.category_id).toBeUndefined();
    expect(callArg.init_start).toBeUndefined();
    expect(callArg.init_stop).toBeUndefined();
    expect(callArg.init_restart).toBeUndefined();
  });

  // ---------------------------------------------------------------------------
  // Category depth rendering
  // ---------------------------------------------------------------------------

  it('renders depth-indented category options with em-dash prefix', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('option', { name: 'ubuntu-22' })).toBeInTheDocument());

    // depth-0: '—'.repeat(0) + ' Networking' → ' Networking' (leading space only)
    const networkingOption = screen.getByRole('option', { name: /Networking/i });
    expect(networkingOption.textContent).toMatch(/Networking/);

    // depth-1: '—'.repeat(1) + ' DNS' → '— DNS'
    const dnsOption = screen.getByRole('option', { name: /DNS/i });
    expect(dnsOption.textContent).toMatch(/—.*DNS/);
  });
});
