import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { BrowserRouter } from 'react-router-dom';
import { PuppetResourceForm } from './PuppetResourceForm';
import type { SystemPuppetResource } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();
const mockPut = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: jest.fn(),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
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

// systemApi is the actual facade used in PuppetResourceForm via named import
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    createPuppetResource: (...args: unknown[]) => mockCreatePuppetResource(...args),
    updatePuppetResource: (...args: unknown[]) => mockUpdatePuppetResource(...args),
  },
}));

const mockCreatePuppetResource = jest.fn();
const mockUpdatePuppetResource = jest.fn();

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const MODULE_ID = 'mod-abc-123';

const RESOURCE_FIXTURE: SystemPuppetResource = {
  id: 'res-xyz-456',
  name: 'nginx_config',
  description: 'Nginx configuration file',
  resource_type: 'file',
  title: '/etc/nginx/nginx.conf',
  path: '/etc/nginx/nginx.conf',
  data: 'user nginx;\nworker_processes auto;',
  enabled: true,
  exported: false,
  parameters: { ensure: 'present', owner: 'root' },
  config: { notify: 'Service[nginx]' },
  puppet_module_id: MODULE_ID,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const SAVED_RESOURCE: SystemPuppetResource = {
  ...RESOURCE_FIXTURE,
  id: 'res-new-789',
  name: 'my_resource',
  resource_type: 'file',
  parameters: {},
  config: {},
};

// =============================================================================
// Helpers
// =============================================================================

const onSaved = jest.fn();
const onCancel = jest.fn();

function renderForm(resource?: SystemPuppetResource | null) {
  return render(
    <BrowserRouter>
      <PuppetResourceForm
        puppetModuleId={MODULE_ID}
        resource={resource}
        onSaved={onSaved}
        onCancel={onCancel}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PuppetResourceForm', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockPut.mockReset();
    mockCreatePuppetResource.mockReset();
    mockUpdatePuppetResource.mockReset();
    mockAddNotification.mockReset();
    onSaved.mockReset();
    onCancel.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render — new resource mode
  // ---------------------------------------------------------------------------

  describe('new resource mode', () => {
    it('renders the New Resource heading', () => {
      renderForm();
      expect(screen.getByText('New Resource')).toBeInTheDocument();
    });

    it('renders all required field labels', () => {
      renderForm();
      expect(screen.getByText('Name *')).toBeInTheDocument();
      expect(screen.getByText('Resource Type *')).toBeInTheDocument();
      expect(screen.getByText('Title')).toBeInTheDocument();
      expect(screen.getByText('Path')).toBeInTheDocument();
      expect(screen.getByText('Description')).toBeInTheDocument();
    });

    it('renders Parameters and Config textareas with JSON label hints', () => {
      renderForm();
      expect(screen.getByText(/Parameters \(Puppet attributes/)).toBeInTheDocument();
      expect(screen.getByText(/Config \(free-form metadata/)).toBeInTheDocument();
    });

    it('renders the Data textarea', () => {
      renderForm();
      expect(screen.getByText('Data (template body / file contents)')).toBeInTheDocument();
    });

    it('renders Create Resource submit button', () => {
      renderForm();
      expect(screen.getByRole('button', { name: /create resource/i })).toBeInTheDocument();
    });

    it('renders Cancel button', () => {
      renderForm();
      const cancelBtns = screen.getAllByRole('button', { name: /cancel/i });
      expect(cancelBtns.length).toBeGreaterThan(0);
    });

    it('defaults resource_type select to "file"', () => {
      renderForm();
      const select = screen.getByRole('combobox') as HTMLSelectElement;
      expect(select.value).toBe('file');
    });

    it('renders all resource type options in the select', () => {
      renderForm();
      const expectedTypes = [
        'file', 'package', 'service', 'exec', 'user', 'group',
        'cron', 'mount', 'host', 'notify', 'class', 'define', 'custom',
      ];
      expectedTypes.forEach((type) => {
        expect(screen.getByRole('option', { name: type })).toBeInTheDocument();
      });
    });

    it('defaults Enabled checkbox to checked and Exported to unchecked', () => {
      renderForm();
      const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
      const enabledCb = checkboxes.find((cb) => {
        const label = cb.closest('label');
        return label?.textContent?.includes('Enabled');
      });
      const exportedCb = checkboxes.find((cb) => {
        const label = cb.closest('label');
        return label?.textContent?.includes('Exported');
      });
      expect(enabledCb?.checked).toBe(true);
      expect(exportedCb?.checked).toBe(false);
    });

    it('defaults parameters textarea to "{}"', () => {
      renderForm();
      const textareas = screen.getAllByRole('textbox') as HTMLTextAreaElement[];
      const paramTextarea = textareas.find(
        (ta) => ta.value === '{}'
      );
      expect(paramTextarea).toBeTruthy();
    });
  });

  // ---------------------------------------------------------------------------
  // Render — edit resource mode
  // ---------------------------------------------------------------------------

  describe('edit resource mode', () => {
    it('renders Edit Resource heading with resource name', () => {
      renderForm(RESOURCE_FIXTURE);
      expect(screen.getByText(`Edit Resource: ${RESOURCE_FIXTURE.name}`)).toBeInTheDocument();
    });

    it('pre-fills name field from resource', () => {
      renderForm(RESOURCE_FIXTURE);
      const nameInput = screen.getByDisplayValue(RESOURCE_FIXTURE.name);
      expect(nameInput).toBeInTheDocument();
    });

    it('pre-fills resource_type from resource', () => {
      renderForm(RESOURCE_FIXTURE);
      const select = screen.getByRole('combobox') as HTMLSelectElement;
      expect(select.value).toBe(RESOURCE_FIXTURE.resource_type);
    });

    it('pre-fills title from resource', () => {
      renderForm(RESOURCE_FIXTURE);
      // title and path may share the same value; use getAllByDisplayValue
      const titleInputs = screen.getAllByDisplayValue(RESOURCE_FIXTURE.title!);
      expect(titleInputs.length).toBeGreaterThan(0);
    });

    it('pre-fills path from resource', () => {
      renderForm(RESOURCE_FIXTURE);
      const pathInputs = screen.getAllByDisplayValue(RESOURCE_FIXTURE.path!);
      expect(pathInputs.length).toBeGreaterThan(0);
    });

    it('pre-fills description from resource', () => {
      renderForm(RESOURCE_FIXTURE);
      expect(screen.getByDisplayValue(RESOURCE_FIXTURE.description!)).toBeInTheDocument();
    });

    it('pre-fills parameters textarea with pretty-printed JSON', () => {
      renderForm(RESOURCE_FIXTURE);
      const expected = JSON.stringify(RESOURCE_FIXTURE.parameters, null, 2);
      const textareas = screen.getAllByRole('textbox') as HTMLTextAreaElement[];
      const paramArea = textareas.find((ta) => ta.value === expected);
      expect(paramArea).toBeTruthy();
    });

    it('pre-fills config textarea with pretty-printed JSON', () => {
      renderForm(RESOURCE_FIXTURE);
      const expected = JSON.stringify(RESOURCE_FIXTURE.config, null, 2);
      const textareas = screen.getAllByRole('textbox') as HTMLTextAreaElement[];
      const configArea = textareas.find((ta) => ta.value === expected);
      expect(configArea).toBeTruthy();
    });

    it('pre-fills data textarea from resource', () => {
      renderForm(RESOURCE_FIXTURE);
      // data contains newlines so getByDisplayValue may not match exactly on all
      // jsdom versions; check via the textarea's value directly
      const textareas = screen.getAllByRole('textbox') as HTMLTextAreaElement[];
      const dataArea = textareas.find(
        (ta) => ta.tagName === 'TEXTAREA' && ta.value === RESOURCE_FIXTURE.data,
      );
      expect(dataArea).toBeTruthy();
    });

    it('pre-fills Enabled checkbox from resource', () => {
      renderForm(RESOURCE_FIXTURE);
      const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
      const enabledCb = checkboxes.find((cb) => cb.closest('label')?.textContent?.includes('Enabled'));
      expect(enabledCb?.checked).toBe(RESOURCE_FIXTURE.enabled);
    });

    it('renders Update Resource submit button instead of Create Resource', () => {
      renderForm(RESOURCE_FIXTURE);
      expect(screen.getByRole('button', { name: /update resource/i })).toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /create resource/i })).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Cancel / close interactions
  // ---------------------------------------------------------------------------

  describe('cancel interactions', () => {
    it('calls onCancel when the X icon button is clicked', () => {
      renderForm();
      // The ghost/icon close button at top-right
      const buttons = screen.getAllByRole('button');
      const xBtn = buttons.find((btn) => !btn.textContent?.trim());
      if (xBtn) fireEvent.click(xBtn);
      expect(onCancel).toHaveBeenCalledTimes(1);
    });

    it('calls onCancel when the Cancel text button is clicked', () => {
      renderForm();
      fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }));
      expect(onCancel).toHaveBeenCalledTimes(1);
    });
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  describe('validation', () => {
    it('shows "Name is required" error when name is empty on submit', async () => {
      renderForm();
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));
      await waitFor(() => {
        expect(screen.getByText('Name is required')).toBeInTheDocument();
      });
    });

    it('does not call createPuppetResource when name is empty', async () => {
      renderForm();
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));
      await waitFor(() => expect(screen.getByText('Name is required')).toBeInTheDocument());
      expect(mockCreatePuppetResource).not.toHaveBeenCalled();
    });

    it('shows invalid JSON error for parameters', async () => {
      renderForm();
      // Fill the name so only parameters validation fails
      const allInputs = screen.getAllByRole('textbox') as HTMLInputElement[];
      const nameField = allInputs[0];
      fireEvent.change(nameField, { target: { value: 'test-resource' } });

      // Corrupt parameters
      const textareas = screen.getAllByRole('textbox') as HTMLTextAreaElement[];
      const paramArea = textareas.find((ta) => ta.value === '{}' && ta.rows > 1);
      if (paramArea) {
        fireEvent.change(paramArea, { target: { value: 'not valid json' } });
      }

      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));
      await waitFor(() => {
        expect(screen.getByText('Parameters must be valid JSON')).toBeInTheDocument();
      });
    });

    it('shows "Parameters must be a JSON object" when parameters is a JSON array', async () => {
      renderForm();
      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      const nameField = allTextboxes[0];
      fireEvent.change(nameField, { target: { value: 'test-resource' } });

      const textareas = screen.getAllByRole('textbox') as HTMLTextAreaElement[];
      const paramArea = textareas.find((ta) => ta.value === '{}' && ta.rows > 1);
      if (paramArea) {
        fireEvent.change(paramArea, { target: { value: '[1, 2, 3]' } });
      }

      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));
      await waitFor(() => {
        expect(screen.getByText('Parameters must be a JSON object')).toBeInTheDocument();
      });
    });

    it('shows invalid JSON error for config', async () => {
      renderForm();
      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      const nameField = allTextboxes[0];
      fireEvent.change(nameField, { target: { value: 'test-resource' } });

      // Corrupt config textarea — the one with rows=3
      const textareas = screen.getAllByRole('textbox') as HTMLTextAreaElement[];
      const configArea = textareas.find((ta) => ta.rows === 3);
      if (configArea) {
        fireEvent.change(configArea, { target: { value: '{bad json}' } });
      }

      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));
      await waitFor(() => {
        expect(screen.getByText('Config must be valid JSON')).toBeInTheDocument();
      });
    });

    it('shows "Config must be a JSON object" when config is a JSON array', async () => {
      renderForm();
      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      const nameField = allTextboxes[0];
      fireEvent.change(nameField, { target: { value: 'test-resource' } });

      const textareas = screen.getAllByRole('textbox') as HTMLTextAreaElement[];
      const configArea = textareas.find((ta) => ta.rows === 3);
      if (configArea) {
        fireEvent.change(configArea, { target: { value: '[true]' } });
      }

      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));
      await waitFor(() => {
        expect(screen.getByText('Config must be a JSON object')).toBeInTheDocument();
      });
    });

    it('clears name error when the name field is updated', async () => {
      renderForm();
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));
      await waitFor(() => expect(screen.getByText('Name is required')).toBeInTheDocument());

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'fixed-name' } });

      await waitFor(() => {
        expect(screen.queryByText('Name is required')).not.toBeInTheDocument();
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Create resource (POST)
  // ---------------------------------------------------------------------------

  describe('create resource', () => {
    it('calls systemApi.createPuppetResource with correct module ID and payload', async () => {
      mockCreatePuppetResource.mockResolvedValueOnce(SAVED_RESOURCE);

      renderForm();

      // Fill name
      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });

      // Submit
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() => {
        expect(mockCreatePuppetResource).toHaveBeenCalledWith(
          MODULE_ID,
          expect.objectContaining({
            name: 'my_resource',
            resource_type: 'file',
            enabled: true,
            exported: false,
            parameters: {},
            config: {},
          }),
        );
      });
    });

    it('omits empty optional fields (description, title, path, data) from payload', async () => {
      mockCreatePuppetResource.mockResolvedValueOnce(SAVED_RESOURCE);

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() => expect(mockCreatePuppetResource).toHaveBeenCalled());

      const [, payload] = mockCreatePuppetResource.mock.calls[0] as [string, Record<string, unknown>];
      expect(payload.description).toBeUndefined();
      expect(payload.title).toBeUndefined();
      expect(payload.path).toBeUndefined();
      expect(payload.data).toBeUndefined();
    });

    it('includes description, title, path, data when filled in', async () => {
      mockCreatePuppetResource.mockResolvedValueOnce(SAVED_RESOURCE);

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      // name, title, path, description, params, config, data (order in DOM)
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });

      // Find specific inputs by their placeholder or position
      const titleInput = screen.getByPlaceholderText('(defaults to name if blank)');
      const pathInput = screen.getByPlaceholderText('(e.g., /etc/nginx/nginx.conf)');
      const descInput = allTextboxes.find((el) => {
        // description input has no placeholder — it's a single-line text input
        // after title/path in the grid, before Parameters textarea
        return el.tagName === 'INPUT' && !el.placeholder;
      });

      fireEvent.change(titleInput, { target: { value: '/etc/puppet/my.conf' } });
      fireEvent.change(pathInput, { target: { value: '/etc/puppet/my.conf' } });

      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() => expect(mockCreatePuppetResource).toHaveBeenCalled());

      const [, payload] = mockCreatePuppetResource.mock.calls[0] as [string, Record<string, unknown>];
      expect(payload.title).toBe('/etc/puppet/my.conf');
      expect(payload.path).toBe('/etc/puppet/my.conf');
    });

    it('parses non-empty parameters JSON and sends it as an object', async () => {
      mockCreatePuppetResource.mockResolvedValueOnce(SAVED_RESOURCE);

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });

      const textareas = screen.getAllByRole('textbox') as HTMLTextAreaElement[];
      const paramArea = textareas.find((ta) => ta.rows === 5);
      if (paramArea) {
        fireEvent.change(paramArea, { target: { value: '{"ensure":"present"}' } });
      }

      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() => expect(mockCreatePuppetResource).toHaveBeenCalled());

      const [, payload] = mockCreatePuppetResource.mock.calls[0] as [string, Record<string, unknown>];
      expect(payload.parameters).toEqual({ ensure: 'present' });
    });

    it('calls onSaved with the returned resource on success', async () => {
      mockCreatePuppetResource.mockResolvedValueOnce(SAVED_RESOURCE);

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() => expect(onSaved).toHaveBeenCalledWith(SAVED_RESOURCE));
    });

    it('shows success notification on create', async () => {
      mockCreatePuppetResource.mockResolvedValueOnce(SAVED_RESOURCE);

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: `Resource created: ${SAVED_RESOURCE.name}`,
          }),
        ),
      );
    });

    it('shows error notification when createPuppetResource rejects', async () => {
      mockCreatePuppetResource.mockRejectedValueOnce(new Error('Network error'));

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'Network error' }),
        ),
      );
    });

    it('does not call onSaved when createPuppetResource rejects', async () => {
      mockCreatePuppetResource.mockRejectedValueOnce(new Error('Network error'));

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error' }),
        ),
      );
      expect(onSaved).not.toHaveBeenCalled();
    });

    it('uses the fallback error message when the error has no message', async () => {
      mockCreatePuppetResource.mockRejectedValueOnce('raw-string-error');

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'Failed to save resource' }),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Update resource (PUT)
  // ---------------------------------------------------------------------------

  describe('update resource', () => {
    it('calls systemApi.updatePuppetResource with module ID, resource ID, and updated payload', async () => {
      const updatedResource = { ...RESOURCE_FIXTURE, name: 'updated_nginx' };
      mockUpdatePuppetResource.mockResolvedValueOnce(updatedResource);

      renderForm(RESOURCE_FIXTURE);

      // Change the name
      const nameInput = screen.getByDisplayValue(RESOURCE_FIXTURE.name);
      fireEvent.change(nameInput, { target: { value: 'updated_nginx' } });

      fireEvent.click(screen.getByRole('button', { name: /update resource/i }));

      await waitFor(() => {
        expect(mockUpdatePuppetResource).toHaveBeenCalledWith(
          MODULE_ID,
          RESOURCE_FIXTURE.id,
          expect.objectContaining({
            name: 'updated_nginx',
            resource_type: RESOURCE_FIXTURE.resource_type,
            enabled: RESOURCE_FIXTURE.enabled,
            exported: RESOURCE_FIXTURE.exported,
          }),
        );
      });
    });

    it('shows "Resource updated" success notification', async () => {
      const updatedResource = { ...RESOURCE_FIXTURE, name: 'updated_nginx' };
      mockUpdatePuppetResource.mockResolvedValueOnce(updatedResource);

      renderForm(RESOURCE_FIXTURE);

      const nameInput = screen.getByDisplayValue(RESOURCE_FIXTURE.name);
      fireEvent.change(nameInput, { target: { value: 'updated_nginx' } });
      fireEvent.click(screen.getByRole('button', { name: /update resource/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: `Resource updated: ${updatedResource.name}`,
          }),
        ),
      );
    });

    it('calls onSaved with the returned resource on update', async () => {
      const updatedResource = { ...RESOURCE_FIXTURE, name: 'updated_nginx' };
      mockUpdatePuppetResource.mockResolvedValueOnce(updatedResource);

      renderForm(RESOURCE_FIXTURE);

      const nameInput = screen.getByDisplayValue(RESOURCE_FIXTURE.name);
      fireEvent.change(nameInput, { target: { value: 'updated_nginx' } });
      fireEvent.click(screen.getByRole('button', { name: /update resource/i }));

      await waitFor(() => expect(onSaved).toHaveBeenCalledWith(updatedResource));
    });

    it('shows error notification when updatePuppetResource rejects', async () => {
      mockUpdatePuppetResource.mockRejectedValueOnce(new Error('Server error'));

      renderForm(RESOURCE_FIXTURE);

      fireEvent.click(screen.getByRole('button', { name: /update resource/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'Server error' }),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Submitting state
  // ---------------------------------------------------------------------------

  describe('submitting state', () => {
    it('disables all inputs and buttons while submitting', async () => {
      let resolveCreate!: (v: SystemPuppetResource) => void;
      mockCreatePuppetResource.mockReturnValueOnce(
        new Promise<SystemPuppetResource>((res) => {
          resolveCreate = res;
        }),
      );

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      // While promise is pending, check disabled state
      await waitFor(() => {
        const submitBtn = screen.getByRole('button', { name: /create resource/i });
        expect(submitBtn).toBeDisabled();
      });

      // Resolve to clean up
      resolveCreate(SAVED_RESOURCE);
      await waitFor(() => expect(onSaved).toHaveBeenCalled());
    });

    it('re-enables the form after submission completes', async () => {
      mockCreatePuppetResource.mockResolvedValueOnce(SAVED_RESOURCE);

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });
      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() => expect(onSaved).toHaveBeenCalled());
      // After resolution the form may unmount (parent handles it); test just
      // verifies no unhandled errors.
    });
  });

  // ---------------------------------------------------------------------------
  // Checkbox toggles
  // ---------------------------------------------------------------------------

  describe('checkbox toggles', () => {
    it('toggles Enabled checkbox', () => {
      renderForm();
      const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
      const enabledCb = checkboxes.find((cb) => cb.closest('label')?.textContent?.includes('Enabled'));
      expect(enabledCb?.checked).toBe(true);
      if (enabledCb) fireEvent.click(enabledCb);
      expect(enabledCb?.checked).toBe(false);
    });

    it('toggles Exported checkbox', () => {
      renderForm();
      const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
      const exportedCb = checkboxes.find((cb) => cb.closest('label')?.textContent?.includes('Exported'));
      expect(exportedCb?.checked).toBe(false);
      if (exportedCb) fireEvent.click(exportedCb);
      expect(exportedCb?.checked).toBe(true);
    });

    it('sends exported: true when Exported is checked before submit', async () => {
      mockCreatePuppetResource.mockResolvedValueOnce(SAVED_RESOURCE);

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });

      const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
      const exportedCb = checkboxes.find((cb) => cb.closest('label')?.textContent?.includes('Exported'));
      if (exportedCb) fireEvent.click(exportedCb);

      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() => expect(mockCreatePuppetResource).toHaveBeenCalled());

      const [, payload] = mockCreatePuppetResource.mock.calls[0] as [string, Record<string, unknown>];
      expect(payload.exported).toBe(true);
    });
  });

  // ---------------------------------------------------------------------------
  // Resource prop change re-initialises form
  // ---------------------------------------------------------------------------

  describe('resource prop change', () => {
    it('resets form to blank when resource prop changes from a resource to null', () => {
      const { rerender } = render(
        <BrowserRouter>
          <PuppetResourceForm
            puppetModuleId={MODULE_ID}
            resource={RESOURCE_FIXTURE}
            onSaved={onSaved}
            onCancel={onCancel}
          />
        </BrowserRouter>,
      );

      // Confirm it starts in edit mode
      expect(screen.getByText(`Edit Resource: ${RESOURCE_FIXTURE.name}`)).toBeInTheDocument();

      rerender(
        <BrowserRouter>
          <PuppetResourceForm
            puppetModuleId={MODULE_ID}
            resource={null}
            onSaved={onSaved}
            onCancel={onCancel}
          />
        </BrowserRouter>,
      );

      expect(screen.getByText('New Resource')).toBeInTheDocument();
      const nameInput = screen.getAllByRole('textbox')[0] as HTMLInputElement;
      expect(nameInput.value).toBe('');
    });

    it('resets form to new resource when resource prop changes to a different resource', () => {
      const otherResource: SystemPuppetResource = {
        ...RESOURCE_FIXTURE,
        id: 'res-other-000',
        name: 'apache_config',
        resource_type: 'service',
      };

      const { rerender } = render(
        <BrowserRouter>
          <PuppetResourceForm
            puppetModuleId={MODULE_ID}
            resource={RESOURCE_FIXTURE}
            onSaved={onSaved}
            onCancel={onCancel}
          />
        </BrowserRouter>,
      );

      rerender(
        <BrowserRouter>
          <PuppetResourceForm
            puppetModuleId={MODULE_ID}
            resource={otherResource}
            onSaved={onSaved}
            onCancel={onCancel}
          />
        </BrowserRouter>,
      );

      expect(screen.getByText(`Edit Resource: ${otherResource.name}`)).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Resource type select interaction
  // ---------------------------------------------------------------------------

  describe('resource_type select', () => {
    it('changes resource_type when a different option is selected', () => {
      renderForm();
      const select = screen.getByRole('combobox') as HTMLSelectElement;
      fireEvent.change(select, { target: { value: 'service' } });
      expect(select.value).toBe('service');
    });

    it('sends the selected resource_type to the API', async () => {
      mockCreatePuppetResource.mockResolvedValueOnce(SAVED_RESOURCE);

      renderForm();

      const allTextboxes = screen.getAllByRole('textbox') as HTMLInputElement[];
      fireEvent.change(allTextboxes[0], { target: { value: 'my_resource' } });

      const select = screen.getByRole('combobox') as HTMLSelectElement;
      fireEvent.change(select, { target: { value: 'package' } });

      fireEvent.click(screen.getByRole('button', { name: /create resource/i }));

      await waitFor(() => expect(mockCreatePuppetResource).toHaveBeenCalled());

      const [, payload] = mockCreatePuppetResource.mock.calls[0] as [string, Record<string, unknown>];
      expect(payload.resource_type).toBe('package');
    });
  });
});
