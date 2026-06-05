import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { PuppetModuleFormModal } from './PuppetModuleFormModal';
import type { SystemPuppetModule } from '@system/features/system/types/system.types';

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

const mockCreatePuppetModule = jest.fn();
const mockUpdatePuppetModule = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    createPuppetModule: (...args: unknown[]) => mockCreatePuppetModule(...args),
    updatePuppetModule: (...args: unknown[]) => mockUpdatePuppetModule(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const MODULE_A: SystemPuppetModule = {
  id: 'mod-001',
  name: 'puppetlabs-apache',
  description: 'Apache HTTP server module',
  enabled: true,
  public: false,
  version: '2.4.0',
  author: 'Puppet Labs',
  license: 'Apache-2.0',
  source_url: 'https://github.com/puppetlabs/puppetlabs-apache',
  project_url: 'https://forge.puppet.com/modules/puppetlabs/apache',
  forge_name: 'puppetlabs/apache',
  dependencies: [{ name: 'puppetlabs/stdlib', version_requirement: '>= 4.0.0' }],
  config: { manage_vhost: true },
  metadata: { category: 'web' },
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

const noop = jest.fn();

function renderModal(
  props: Partial<React.ComponentProps<typeof PuppetModuleFormModal>> = {}
) {
  const defaults = {
    isOpen: true,
    onClose: noop,
    onModuleSaved: undefined,
    editModule: undefined,
  };
  return render(<PuppetModuleFormModal {...defaults} {...props} />);
}

// =============================================================================
// Tests
// =============================================================================

describe('PuppetModuleFormModal', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  // ---------------------------------------------------------------------------
  // Render / visibility
  // ---------------------------------------------------------------------------

  describe('render state', () => {
    it('renders nothing when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(screen.queryByRole('heading', { name: /puppet module/i })).not.toBeInTheDocument();
    });

    it('renders the "Add Puppet Module" heading in create mode', () => {
      renderModal();
      expect(screen.getByText('Add Puppet Module')).toBeInTheDocument();
    });

    it('renders the "Edit Puppet Module" heading in edit mode', () => {
      renderModal({ editModule: MODULE_A });
      expect(screen.getByText('Edit Puppet Module')).toBeInTheDocument();
    });

    it('renders the submit button labelled "Add Module" in create mode', () => {
      renderModal();
      expect(screen.getByRole('button', { name: /add module/i })).toBeInTheDocument();
    });

    it('renders the submit button labelled "Update Module" in edit mode', () => {
      renderModal({ editModule: MODULE_A });
      expect(screen.getByRole('button', { name: /update module/i })).toBeInTheDocument();
    });

    it('renders a Cancel button', () => {
      renderModal();
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
    });

    it('renders all the expected form fields', () => {
      renderModal();
      expect(screen.getByLabelText(/^name/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/version/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/author/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/license/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/forge name/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/description/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/source url/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/project url/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/dependencies/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/configuration/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/metadata/i)).toBeInTheDocument();
    });

    it('renders the Enabled and Public checkboxes', () => {
      renderModal();
      expect(screen.getByRole('checkbox', { name: /enabled/i })).toBeInTheDocument();
      expect(screen.getByRole('checkbox', { name: /public/i })).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Edit mode — pre-populated values
  // ---------------------------------------------------------------------------

  describe('edit mode pre-population', () => {
    it('populates text fields from the editModule prop', () => {
      renderModal({ editModule: MODULE_A });

      expect(screen.getByDisplayValue('puppetlabs-apache')).toBeInTheDocument();
      expect(screen.getByDisplayValue('2.4.0')).toBeInTheDocument();
      expect(screen.getByDisplayValue('Puppet Labs')).toBeInTheDocument();
      expect(screen.getByDisplayValue('Apache-2.0')).toBeInTheDocument();
      expect(screen.getByDisplayValue('puppetlabs/apache')).toBeInTheDocument();
      expect(screen.getByDisplayValue('Apache HTTP server module')).toBeInTheDocument();
      expect(screen.getByDisplayValue('https://github.com/puppetlabs/puppetlabs-apache')).toBeInTheDocument();
      expect(screen.getByDisplayValue('https://forge.puppet.com/modules/puppetlabs/apache')).toBeInTheDocument();
    });

    it('pre-checks the Enabled checkbox when module is enabled', () => {
      renderModal({ editModule: MODULE_A });
      const enabledCheckbox = screen.getByRole('checkbox', { name: /enabled/i }) as HTMLInputElement;
      expect(enabledCheckbox.checked).toBe(true);
    });

    it('leaves the Public checkbox unchecked when module.public is false', () => {
      renderModal({ editModule: MODULE_A });
      const publicCheckbox = screen.getByRole('checkbox', { name: /public/i }) as HTMLInputElement;
      expect(publicCheckbox.checked).toBe(false);
    });

    it('serialises the dependencies JSON into the textarea', () => {
      renderModal({ editModule: MODULE_A });
      const depsTextarea = screen.getByLabelText(/dependencies/i) as HTMLTextAreaElement;
      const parsed = JSON.parse(depsTextarea.value);
      expect(parsed).toEqual(MODULE_A.dependencies);
    });

    it('serialises the config JSON into the textarea', () => {
      renderModal({ editModule: MODULE_A });
      const configTextarea = screen.getByLabelText(/configuration/i) as HTMLTextAreaElement;
      const parsed = JSON.parse(configTextarea.value);
      expect(parsed).toEqual(MODULE_A.config);
    });

    it('serialises the metadata JSON into the textarea', () => {
      renderModal({ editModule: MODULE_A });
      const metadataTextarea = screen.getByLabelText(/metadata/i) as HTMLTextAreaElement;
      const parsed = JSON.parse(metadataTextarea.value);
      expect(parsed).toEqual(MODULE_A.metadata);
    });
  });

  // ---------------------------------------------------------------------------
  // Create mode — default values
  // ---------------------------------------------------------------------------

  describe('create mode defaults', () => {
    it('starts with empty text fields', () => {
      renderModal();
      const nameInput = screen.getByLabelText(/^name/i) as HTMLInputElement;
      expect(nameInput.value).toBe('');
    });

    it('initialises Enabled as checked and Public as unchecked', () => {
      renderModal();
      const enabledCheckbox = screen.getByRole('checkbox', { name: /enabled/i }) as HTMLInputElement;
      const publicCheckbox = screen.getByRole('checkbox', { name: /public/i }) as HTMLInputElement;
      expect(enabledCheckbox.checked).toBe(true);
      expect(publicCheckbox.checked).toBe(false);
    });

    it('initialises the JSON textarea fields with valid empty structures', () => {
      renderModal();
      const depsTextarea = screen.getByLabelText(/dependencies/i) as HTMLTextAreaElement;
      const configTextarea = screen.getByLabelText(/configuration/i) as HTMLTextAreaElement;
      const metadataTextarea = screen.getByLabelText(/metadata/i) as HTMLTextAreaElement;

      expect(() => JSON.parse(depsTextarea.value)).not.toThrow();
      expect(() => JSON.parse(configTextarea.value)).not.toThrow();
      expect(() => JSON.parse(metadataTextarea.value)).not.toThrow();
    });
  });

  // ---------------------------------------------------------------------------
  // Form reset when reopened
  // ---------------------------------------------------------------------------

  describe('form reset on reopen', () => {
    it('resets to blank state when opened without an editModule after being closed', () => {
      const { rerender } = renderModal({ editModule: MODULE_A });

      // close
      rerender(
        <PuppetModuleFormModal isOpen={false} onClose={noop} editModule={MODULE_A} />
      );

      // reopen without a module
      rerender(
        <PuppetModuleFormModal isOpen={true} onClose={noop} editModule={null} />
      );

      const nameInput = screen.getByLabelText(/^name/i) as HTMLInputElement;
      expect(nameInput.value).toBe('');
    });
  });

  // ---------------------------------------------------------------------------
  // Close interactions
  // ---------------------------------------------------------------------------

  describe('close interactions', () => {
    it('calls onClose when Cancel is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('calls onClose when the X icon button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      // The close button is a ghost button containing the X icon — it's the
      // only button without a text label, so we can find it by its role next
      // to the heading.
      const closeBtn = screen.getAllByRole('button').find(
        (b) => !b.textContent?.trim() || b.getAttribute('type') !== 'submit'
      );
      // Grab the first button that's not Cancel/Add Module
      const headerCloseBtn = screen.getAllByRole('button')[0];
      fireEvent.click(headerCloseBtn);
      expect(onClose).toHaveBeenCalled();
    });

    it('calls onClose when the backdrop overlay is clicked', () => {
      const onClose = jest.fn();
      const { container } = renderModal({ onClose });
      // The overlay is the fixed bg-black/50 div
      const overlay = container.querySelector('.fixed.inset-0.bg-black\\/50') as HTMLElement;
      fireEvent.click(overlay);
      expect(onClose).toHaveBeenCalledTimes(1);
    });
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  describe('validation', () => {
    it('shows a "Name is required" error when submitting with an empty name', async () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));
      await waitFor(() =>
        expect(screen.getByText('Name is required')).toBeInTheDocument()
      );
    });

    it('shows a "Name must be at least 2 characters" error for a single-character name', async () => {
      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'x');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));
      await waitFor(() =>
        expect(screen.getByText('Name must be at least 2 characters')).toBeInTheDocument()
      );
    });

    it('shows an "Invalid JSON format" error when dependencies textarea has invalid JSON', async () => {
      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'my-module');
      const depsTextarea = screen.getByLabelText(/dependencies/i);
      await userEvent.clear(depsTextarea);
      await userEvent.type(depsTextarea, 'not-json');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));
      await waitFor(() =>
        expect(screen.getAllByText('Invalid JSON format').length).toBeGreaterThan(0)
      );
    });

    it('shows an "Invalid JSON format" error when config textarea has invalid JSON', async () => {
      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'my-module');
      const configTextarea = screen.getByLabelText(/configuration/i);
      // Use fireEvent.change because userEvent.type interprets { as a special key
      fireEvent.change(configTextarea, { target: { value: '{invalid' } });
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));
      await waitFor(() =>
        expect(screen.getAllByText('Invalid JSON format').length).toBeGreaterThan(0)
      );
    });

    it('shows an "Invalid JSON format" error when metadata textarea has invalid JSON', async () => {
      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'my-module');
      const metadataTextarea = screen.getByLabelText(/metadata/i);
      // Use fireEvent.change because userEvent.type interprets { as a special key
      fireEvent.change(metadataTextarea, { target: { value: 'badjson---' } });
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));
      await waitFor(() =>
        expect(screen.getAllByText('Invalid JSON format').length).toBeGreaterThan(0)
      );
    });

    it('clears the name error when the user starts correcting the name field', async () => {
      renderModal();
      // Trigger the error first
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));
      await waitFor(() => expect(screen.getByText('Name is required')).toBeInTheDocument());

      // Now type in the name field — error should disappear
      await userEvent.type(screen.getByLabelText(/^name/i), 'a');
      await waitFor(() =>
        expect(screen.queryByText('Name is required')).not.toBeInTheDocument()
      );
    });

    it('does not call createPuppetModule when validation fails', async () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));
      await waitFor(() => expect(screen.getByText('Name is required')).toBeInTheDocument());
      expect(mockCreatePuppetModule).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Create submission
  // ---------------------------------------------------------------------------

  describe('create submission', () => {
    it('calls systemApi.createPuppetModule with the correct payload', async () => {
      const newModule: SystemPuppetModule = {
        id: 'new-001',
        name: 'my-module',
        enabled: true,
        public: false,
        dependencies: [],
        config: {},
        metadata: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockCreatePuppetModule.mockResolvedValueOnce(newModule);

      renderModal();

      await userEvent.type(screen.getByLabelText(/^name/i), 'my-module');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() =>
        expect(mockCreatePuppetModule).toHaveBeenCalledWith(
          expect.objectContaining({
            name: 'my-module',
            enabled: true,
            public: false,
            dependencies: [],
            config: {},
            metadata: {},
          })
        )
      );
    });

    it('omits empty optional fields from the create payload', async () => {
      const newModule: SystemPuppetModule = {
        id: 'new-002',
        name: 'minimal-mod',
        enabled: true,
        public: false,
        dependencies: [],
        config: {},
        metadata: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockCreatePuppetModule.mockResolvedValueOnce(newModule);

      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'minimal-mod');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() => expect(mockCreatePuppetModule).toHaveBeenCalled());
      const payload = mockCreatePuppetModule.mock.calls[0][0];
      expect(payload.description).toBeUndefined();
      expect(payload.version).toBeUndefined();
      expect(payload.author).toBeUndefined();
      expect(payload.license).toBeUndefined();
      expect(payload.source_url).toBeUndefined();
      expect(payload.project_url).toBeUndefined();
      expect(payload.forge_name).toBeUndefined();
    });

    it('includes optional fields in the payload when they are provided', async () => {
      const newModule: SystemPuppetModule = {
        id: 'new-003',
        name: 'full-mod',
        enabled: false,
        public: true,
        version: '1.0.0',
        author: 'Me',
        dependencies: [],
        config: {},
        metadata: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockCreatePuppetModule.mockResolvedValueOnce(newModule);

      renderModal();

      await userEvent.type(screen.getByLabelText(/^name/i), 'full-mod');
      await userEvent.type(screen.getByLabelText(/version/i), '1.0.0');
      await userEvent.type(screen.getByLabelText(/author/i), 'Me');

      // Toggle enabled off and public on
      fireEvent.click(screen.getByRole('checkbox', { name: /enabled/i }));
      fireEvent.click(screen.getByRole('checkbox', { name: /public/i }));

      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() => expect(mockCreatePuppetModule).toHaveBeenCalled());
      const payload = mockCreatePuppetModule.mock.calls[0][0];
      expect(payload.version).toBe('1.0.0');
      expect(payload.author).toBe('Me');
      expect(payload.enabled).toBe(false);
      expect(payload.public).toBe(true);
    });

    it('shows a success notification after creation', async () => {
      const createdModule: SystemPuppetModule = {
        id: 'n-1',
        name: 'my-new-module',
        enabled: true,
        public: false,
        dependencies: [],
        config: {},
        metadata: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockCreatePuppetModule.mockResolvedValueOnce(createdModule);

      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'my-new-module');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Puppet module "my-new-module" created successfully`,
        })
      );
    });

    it('calls onModuleSaved with the returned module after creation', async () => {
      const createdModule: SystemPuppetModule = {
        id: 'n-2',
        name: 'saved-module',
        enabled: true,
        public: false,
        dependencies: [],
        config: {},
        metadata: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockCreatePuppetModule.mockResolvedValueOnce(createdModule);

      const onModuleSaved = jest.fn();
      renderModal({ onModuleSaved });
      await userEvent.type(screen.getByLabelText(/^name/i), 'saved-module');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() =>
        expect(onModuleSaved).toHaveBeenCalledWith(createdModule)
      );
    });

    it('calls onClose after successful creation', async () => {
      const createdModule: SystemPuppetModule = {
        id: 'n-3',
        name: 'close-test',
        enabled: true,
        public: false,
        dependencies: [],
        config: {},
        metadata: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockCreatePuppetModule.mockResolvedValueOnce(createdModule);

      const onClose = jest.fn();
      renderModal({ onClose });
      await userEvent.type(screen.getByLabelText(/^name/i), 'close-test');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() => expect(onClose).toHaveBeenCalled());
    });

    it('shows a "Creating..." label while the submission is in flight', async () => {
      let resolve!: (v: SystemPuppetModule) => void;
      const pending = new Promise<SystemPuppetModule>((r) => { resolve = r; });
      mockCreatePuppetModule.mockReturnValueOnce(pending);

      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'inflight-mod');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() =>
        expect(screen.getByText(/creating\.\.\./i)).toBeInTheDocument()
      );

      // resolve to clean up
      resolve({
        id: 'n-4',
        name: 'inflight-mod',
        enabled: true,
        public: false,
        dependencies: [],
        config: {},
        metadata: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Edit submission
  // ---------------------------------------------------------------------------

  describe('edit submission', () => {
    it('calls systemApi.updatePuppetModule with the module id and payload', async () => {
      const updatedModule: SystemPuppetModule = {
        ...MODULE_A,
        name: 'puppetlabs-apache',
        version: '2.5.0',
      };
      mockUpdatePuppetModule.mockResolvedValueOnce(updatedModule);

      renderModal({ editModule: MODULE_A });

      const versionInput = screen.getByLabelText(/version/i) as HTMLInputElement;
      await userEvent.clear(versionInput);
      await userEvent.type(versionInput, '2.5.0');

      fireEvent.click(screen.getByRole('button', { name: /update module/i }));

      await waitFor(() =>
        expect(mockUpdatePuppetModule).toHaveBeenCalledWith(
          MODULE_A.id,
          expect.objectContaining({
            name: 'puppetlabs-apache',
            version: '2.5.0',
          })
        )
      );
    });

    it('shows a success notification after update', async () => {
      const updatedModule: SystemPuppetModule = { ...MODULE_A };
      mockUpdatePuppetModule.mockResolvedValueOnce(updatedModule);

      renderModal({ editModule: MODULE_A });
      fireEvent.click(screen.getByRole('button', { name: /update module/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Puppet module "${MODULE_A.name}" updated successfully`,
        })
      );
    });

    it('shows an "Updating..." label while the edit submission is in flight', async () => {
      let resolve!: (v: SystemPuppetModule) => void;
      const pending = new Promise<SystemPuppetModule>((r) => { resolve = r; });
      mockUpdatePuppetModule.mockReturnValueOnce(pending);

      renderModal({ editModule: MODULE_A });
      fireEvent.click(screen.getByRole('button', { name: /update module/i }));

      await waitFor(() =>
        expect(screen.getByText(/updating\.\.\./i)).toBeInTheDocument()
      );

      resolve(MODULE_A);
    });

    it('calls onModuleSaved with the updated module', async () => {
      const updatedModule: SystemPuppetModule = { ...MODULE_A, version: '3.0.0' };
      mockUpdatePuppetModule.mockResolvedValueOnce(updatedModule);

      const onModuleSaved = jest.fn();
      renderModal({ editModule: MODULE_A, onModuleSaved });
      fireEvent.click(screen.getByRole('button', { name: /update module/i }));

      await waitFor(() => expect(onModuleSaved).toHaveBeenCalledWith(updatedModule));
    });

    it('calls onClose after a successful update', async () => {
      mockUpdatePuppetModule.mockResolvedValueOnce(MODULE_A);

      const onClose = jest.fn();
      renderModal({ editModule: MODULE_A, onClose });
      fireEvent.click(screen.getByRole('button', { name: /update module/i }));

      await waitFor(() => expect(onClose).toHaveBeenCalled());
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  describe('error handling', () => {
    it('shows an error notification when creation fails', async () => {
      mockCreatePuppetModule.mockRejectedValueOnce(new Error('Network error'));

      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'fail-mod');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to create Puppet module: Network error',
        })
      );
    });

    it('shows an error notification when update fails', async () => {
      mockUpdatePuppetModule.mockRejectedValueOnce(new Error('Server error'));

      renderModal({ editModule: MODULE_A });
      fireEvent.click(screen.getByRole('button', { name: /update module/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to update Puppet module: Server error',
        })
      );
    });

    it('uses a generic error message for non-Error rejections on create', async () => {
      mockCreatePuppetModule.mockRejectedValueOnce('raw string error');

      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'bad-mod');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to create Puppet module: An error occurred',
        })
      );
    });

    it('does not call onClose after a failed submission', async () => {
      mockCreatePuppetModule.mockRejectedValueOnce(new Error('Fail'));

      const onClose = jest.fn();
      renderModal({ onClose });
      await userEvent.type(screen.getByLabelText(/^name/i), 'error-test');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      expect(onClose).not.toHaveBeenCalled();
    });

    it('re-enables the submit button after a failed submission', async () => {
      mockCreatePuppetModule.mockRejectedValueOnce(new Error('Fail'));

      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'retry-mod');
      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());

      const submitBtn = screen.getByRole('button', { name: /add module/i });
      expect(submitBtn).not.toBeDisabled();
    });
  });

  // ---------------------------------------------------------------------------
  // JSON field interaction
  // ---------------------------------------------------------------------------

  describe('JSON field interaction', () => {
    it('accepts and parses a valid dependencies JSON array', async () => {
      const newModule: SystemPuppetModule = {
        id: 'json-001',
        name: 'json-mod',
        enabled: true,
        public: false,
        dependencies: [{ name: 'puppetlabs/stdlib' }],
        config: {},
        metadata: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockCreatePuppetModule.mockResolvedValueOnce(newModule);

      renderModal();
      await userEvent.type(screen.getByLabelText(/^name/i), 'json-mod');

      const depsTextarea = screen.getByLabelText(/dependencies/i);
      // Use fireEvent.change because userEvent.type interprets { as a special key
      fireEvent.change(depsTextarea, {
        target: { value: '[{"name":"puppetlabs/stdlib"}]' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add module/i }));

      await waitFor(() => expect(mockCreatePuppetModule).toHaveBeenCalled());
      const payload = mockCreatePuppetModule.mock.calls[0][0];
      expect(payload.dependencies).toEqual([{ name: 'puppetlabs/stdlib' }]);
    });
  });

  // ---------------------------------------------------------------------------
  // Checkbox toggling
  // ---------------------------------------------------------------------------

  describe('checkbox toggling', () => {
    it('toggles the enabled checkbox correctly', async () => {
      renderModal();
      const enabledCheckbox = screen.getByRole('checkbox', { name: /enabled/i }) as HTMLInputElement;

      expect(enabledCheckbox.checked).toBe(true);
      fireEvent.click(enabledCheckbox);
      expect(enabledCheckbox.checked).toBe(false);
      fireEvent.click(enabledCheckbox);
      expect(enabledCheckbox.checked).toBe(true);
    });

    it('toggles the public checkbox correctly', async () => {
      renderModal();
      const publicCheckbox = screen.getByRole('checkbox', { name: /public/i }) as HTMLInputElement;

      expect(publicCheckbox.checked).toBe(false);
      fireEvent.click(publicCheckbox);
      expect(publicCheckbox.checked).toBe(true);
    });
  });
});
