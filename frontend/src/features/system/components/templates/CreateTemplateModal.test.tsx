import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { CreateTemplateModal } from './CreateTemplateModal';
import type { SystemNodeTemplate, SystemNodePlatform } from '@system/features/system/types/system.types';

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
const mockCreateTemplate = jest.fn();
const mockUpdateTemplate = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getPlatforms: (...args: unknown[]) => mockGetPlatforms(...args),
    createTemplate: (...args: unknown[]) => mockCreateTemplate(...args),
    updateTemplate: (...args: unknown[]) => mockUpdateTemplate(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const PLATFORM_1: SystemNodePlatform = {
  id: 'plat-1',
  name: 'ubuntu-amd64',
  description: 'Ubuntu AMD64 platform',
  enabled: true,
  public: true,
  disk_image_publication_status: 'none',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PLATFORM_2: SystemNodePlatform = {
  id: 'plat-2',
  name: 'arm64-slim',
  enabled: true,
  public: false,
  disk_image_publication_status: 'none',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TEMPLATE: SystemNodeTemplate = {
  id: 'tpl-abc',
  name: 'my-template',
  description: 'A base template',
  enabled: true,
  public: false,
  admin_user: 'ubuntu',
  node_platform_id: 'plat-1',
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Helper
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  onClose?: () => void;
  onTemplateCreated?: (t: SystemNodeTemplate) => void;
  defaultPlatformId?: string;
  editTemplate?: SystemNodeTemplate | null;
  duplicateFrom?: SystemNodeTemplate | null;
}

const renderModal = ({
  isOpen = true,
  onClose = jest.fn(),
  onTemplateCreated = jest.fn(),
  defaultPlatformId,
  editTemplate,
  duplicateFrom,
}: RenderProps = {}) =>
  render(
    <BrowserRouter>
      <CreateTemplateModal
        isOpen={isOpen}
        onClose={onClose}
        onTemplateCreated={onTemplateCreated}
        defaultPlatformId={defaultPlatformId}
        editTemplate={editTemplate}
        duplicateFrom={duplicateFrom}
      />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('CreateTemplateModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockGetPlatforms.mockReset();
    mockCreateTemplate.mockReset();
    mockUpdateTemplate.mockReset();

    mockGetPlatforms.mockResolvedValue([PLATFORM_1, PLATFORM_2]);
  });

  // ---------------------------------------------------------------------------
  // Render / visibility
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Create Template')).not.toBeInTheDocument();
    expect(screen.queryByText('Edit Template')).not.toBeInTheDocument();
  });

  it('renders the create title when isOpen is true with no editTemplate', async () => {
    renderModal();
    await waitFor(() =>
      expect(screen.getAllByText('Create Template').length).toBeGreaterThan(0),
    );
    // The heading specifically (h2) contains the title text
    expect(screen.getByRole('heading', { name: 'Create Template' })).toBeInTheDocument();
  });

  it('renders the edit title when editTemplate is provided', async () => {
    renderModal({ editTemplate: TEMPLATE });
    await waitFor(() =>
      expect(screen.getByText('Edit Template')).toBeInTheDocument(),
    );
  });

  it('renders the duplicate title when duplicateFrom is provided', async () => {
    renderModal({ duplicateFrom: TEMPLATE });
    await waitFor(() =>
      expect(screen.getByText('Duplicate Template')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Platform loading
  // ---------------------------------------------------------------------------

  it('fetches platforms when modal opens', async () => {
    renderModal();
    await waitFor(() => expect(mockGetPlatforms).toHaveBeenCalledTimes(1));
  });

  it('does not fetch platforms when modal is closed', () => {
    renderModal({ isOpen: false });
    expect(mockGetPlatforms).not.toHaveBeenCalled();
  });

  it('renders platform options in the select after loading', async () => {
    renderModal();
    // Wait for spinner to be replaced by the select
    await waitFor(() =>
      expect(screen.getByRole('combobox')).toBeInTheDocument(),
    );
    expect(screen.getByText('ubuntu-amd64')).toBeInTheDocument();
    expect(screen.getByText('arm64-slim')).toBeInTheDocument();
  });

  it('shows error notification when platform fetch fails', async () => {
    mockGetPlatforms.mockRejectedValue(new Error('Network error'));
    renderModal();
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load platforms',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Form initialisation — create mode
  // ---------------------------------------------------------------------------

  it('resets form fields to defaults when opened in create mode', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
    expect(nameInput.value).toBe('');

    const adminUserInput = screen.getByLabelText(/admin user/i) as HTMLInputElement;
    expect(adminUserInput.value).toBe('root');

    const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
    const enabledCb = checkboxes.find((cb) => cb.name === 'enabled');
    const publicCb = checkboxes.find((cb) => cb.name === 'public');
    expect(enabledCb?.checked).toBe(true);
    expect(publicCb?.checked).toBe(false);
  });

  it('pre-selects defaultPlatformId in the platform dropdown', async () => {
    renderModal({ defaultPlatformId: 'plat-2' });
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const select = screen.getByRole('combobox') as HTMLSelectElement;
    expect(select.value).toBe('plat-2');
  });

  // ---------------------------------------------------------------------------
  // Form initialisation — edit mode
  // ---------------------------------------------------------------------------

  it('pre-populates form fields from editTemplate', async () => {
    renderModal({ editTemplate: TEMPLATE });
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
    expect(nameInput.value).toBe('my-template');

    const descTextarea = screen.getByLabelText(/description/i) as HTMLTextAreaElement;
    expect(descTextarea.value).toBe('A base template');

    const adminUserInput = screen.getByLabelText(/admin user/i) as HTMLInputElement;
    expect(adminUserInput.value).toBe('ubuntu');

    const select = screen.getByRole('combobox') as HTMLSelectElement;
    expect(select.value).toBe('plat-1');

    const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
    const enabledCb = checkboxes.find((cb) => cb.name === 'enabled');
    const publicCb = checkboxes.find((cb) => cb.name === 'public');
    expect(enabledCb?.checked).toBe(true);
    expect(publicCb?.checked).toBe(false);
  });

  // ---------------------------------------------------------------------------
  // Form initialisation — duplicate mode
  // ---------------------------------------------------------------------------

  it('pre-populates form with "(Copy)" suffix and forces public=false when duplicating', async () => {
    const publicTemplate: SystemNodeTemplate = { ...TEMPLATE, public: true };
    renderModal({ duplicateFrom: publicTemplate });
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
    expect(nameInput.value).toBe('my-template (Copy)');

    const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
    const publicCb = checkboxes.find((cb) => cb.name === 'public');
    expect(publicCb?.checked).toBe(false);
  });

  // ---------------------------------------------------------------------------
  // Form interactions
  // ---------------------------------------------------------------------------

  it('updates name field on user input', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
    fireEvent.change(nameInput, { target: { value: 'new-template' } });
    expect(nameInput.value).toBe('new-template');
  });

  it('updates description field on user input', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/description/i)).toBeInTheDocument());

    const desc = screen.getByLabelText(/description/i) as HTMLTextAreaElement;
    fireEvent.change(desc, { target: { value: 'Updated desc' } });
    expect(desc.value).toBe('Updated desc');
  });

  it('toggles enabled checkbox', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
    const enabledCb = checkboxes.find((cb) => cb.name === 'enabled')!;
    expect(enabledCb.checked).toBe(true);
    fireEvent.click(enabledCb);
    expect(enabledCb.checked).toBe(false);
  });

  it('toggles public checkbox', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[];
    const publicCb = checkboxes.find((cb) => cb.name === 'public')!;
    expect(publicCb.checked).toBe(false);
    fireEvent.click(publicCb);
    expect(publicCb.checked).toBe(true);
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  it('shows "Name is required" when name is blank on submit', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /create template/i }));
    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument(),
    );
  });

  it('shows error when name is only whitespace', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: '   ' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));
    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument(),
    );
  });

  it('shows error when name is shorter than 2 characters', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'a' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));
    await waitFor(() =>
      expect(screen.getByText('Name must be at least 2 characters')).toBeInTheDocument(),
    );
  });

  it('accepts a name of exactly 2 characters (no error)', async () => {
    const created: SystemNodeTemplate = { ...TEMPLATE, name: 'ab' };
    mockCreateTemplate.mockResolvedValue(created);

    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'ab' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));
    await waitFor(() =>
      expect(mockCreateTemplate).toHaveBeenCalled(),
    );
    expect(screen.queryByText('Name must be at least 2 characters')).not.toBeInTheDocument();
  });

  it('shows error when name exceeds 100 characters', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'a'.repeat(101) },
    });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));
    await waitFor(() =>
      expect(screen.getByText('Name must be less than 100 characters')).toBeInTheDocument(),
    );
  });

  it('shows error when description exceeds 500 characters', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/description/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'valid-name' } });
    fireEvent.change(screen.getByLabelText(/description/i), {
      target: { value: 'x'.repeat(501) },
    });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));
    await waitFor(() =>
      expect(
        screen.getByText('Description must be less than 500 characters'),
      ).toBeInTheDocument(),
    );
  });

  it('shows error when admin_user exceeds 50 characters', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/admin user/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'valid-name' } });
    fireEvent.change(screen.getByLabelText(/admin user/i), {
      target: { value: 'a'.repeat(51) },
    });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));
    await waitFor(() =>
      expect(
        screen.getByText('Admin user must be less than 50 characters'),
      ).toBeInTheDocument(),
    );
  });

  it('clears field error when the user edits that field', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    // Trigger name error
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));
    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument(),
    );

    // Fix by typing
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'fixed-name' } });
    await waitFor(() =>
      expect(screen.queryByText('Name is required')).not.toBeInTheDocument(),
    );
  });

  it('does not call createTemplate when validation fails', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /create template/i }));
    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument(),
    );
    expect(mockCreateTemplate).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Successful create submission
  // ---------------------------------------------------------------------------

  it('calls systemApi.createTemplate with correct payload on submit', async () => {
    const created: SystemNodeTemplate = { ...TEMPLATE, name: 'new-tpl' };
    mockCreateTemplate.mockResolvedValue(created);

    renderModal();
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'new-tpl' } });
    fireEvent.change(screen.getByLabelText(/description/i), {
      target: { value: 'A description' },
    });
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'plat-1' } });
    fireEvent.change(screen.getByLabelText(/admin user/i), { target: { value: 'admin' } });

    fireEvent.click(screen.getByRole('button', { name: /create template/i }));

    await waitFor(() =>
      expect(mockCreateTemplate).toHaveBeenCalledWith({
        name: 'new-tpl',
        description: 'A description',
        node_platform_id: 'plat-1',
        admin_user: 'admin',
        enabled: true,
        public: false,
        config: {},
      }),
    );
  });

  it('shows success notification after create with template name', async () => {
    const created: SystemNodeTemplate = { ...TEMPLATE, name: 'new-tpl' };
    mockCreateTemplate.mockResolvedValue(created);

    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'new-tpl' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Template "new-tpl" created successfully`,
      }),
    );
  });

  it('calls onTemplateCreated callback with the created template', async () => {
    const created: SystemNodeTemplate = { ...TEMPLATE, name: 'new-tpl' };
    mockCreateTemplate.mockResolvedValue(created);

    const onTemplateCreated = jest.fn();
    renderModal({ onTemplateCreated });
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'new-tpl' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));

    await waitFor(() => expect(onTemplateCreated).toHaveBeenCalledWith(created));
  });

  it('calls onClose after successful create', async () => {
    const created: SystemNodeTemplate = { ...TEMPLATE, name: 'new-tpl' };
    mockCreateTemplate.mockResolvedValue(created);

    const onClose = jest.fn();
    renderModal({ onClose });
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'new-tpl' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));

    await waitFor(() => expect(onClose).toHaveBeenCalled());
  });

  // ---------------------------------------------------------------------------
  // Successful update submission
  // ---------------------------------------------------------------------------

  it('calls systemApi.updateTemplate with template id and payload in edit mode', async () => {
    const updated: SystemNodeTemplate = { ...TEMPLATE, name: 'updated-tpl' };
    mockUpdateTemplate.mockResolvedValue(updated);

    renderModal({ editTemplate: TEMPLATE });
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'updated-tpl' } });
    fireEvent.click(screen.getByRole('button', { name: /update template/i }));

    await waitFor(() =>
      expect(mockUpdateTemplate).toHaveBeenCalledWith(
        'tpl-abc',
        expect.objectContaining({ name: 'updated-tpl' }),
      ),
    );
  });

  it('shows success notification after update with template name', async () => {
    const updated: SystemNodeTemplate = { ...TEMPLATE, name: 'updated-tpl' };
    mockUpdateTemplate.mockResolvedValue(updated);

    renderModal({ editTemplate: TEMPLATE });
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'updated-tpl' } });
    fireEvent.click(screen.getByRole('button', { name: /update template/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: `Template "updated-tpl" updated successfully`,
      }),
    );
  });

  it('shows "Update Template" button text in edit mode', async () => {
    renderModal({ editTemplate: TEMPLATE });
    await waitFor(() =>
      expect(
        screen.getByRole('button', { name: /update template/i }),
      ).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Error handling on submit
  // ---------------------------------------------------------------------------

  it('shows error notification when createTemplate throws an Error', async () => {
    mockCreateTemplate.mockRejectedValue(new Error('Server fail'));

    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'valid-name' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create template: Server fail',
      }),
    );
  });

  it('shows generic error message when createTemplate throws a non-Error', async () => {
    mockCreateTemplate.mockRejectedValue('string-error');

    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'valid-name' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create template: An error occurred',
      }),
    );
  });

  it('shows error notification when updateTemplate throws', async () => {
    mockUpdateTemplate.mockRejectedValue(new Error('Update failed'));

    renderModal({ editTemplate: TEMPLATE });
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /update template/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to update template: Update failed',
      }),
    );
  });

  it('does not call onClose or onTemplateCreated when create fails', async () => {
    mockCreateTemplate.mockRejectedValue(new Error('Oops'));

    const onClose = jest.fn();
    const onTemplateCreated = jest.fn();
    renderModal({ onClose, onTemplateCreated });
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'valid-name' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onClose).not.toHaveBeenCalled();
    expect(onTemplateCreated).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Submitting state
  // ---------------------------------------------------------------------------

  it('shows "Creating..." and disables submit while create is in-flight', async () => {
    let resolveCreate!: (v: SystemNodeTemplate) => void;
    mockCreateTemplate.mockImplementation(
      () => new Promise<SystemNodeTemplate>((resolve) => { resolveCreate = resolve; }),
    );

    renderModal();
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'valid-name' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /creating/i })).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: /creating/i })).toBeDisabled();

    resolveCreate({ ...TEMPLATE, name: 'valid-name' });
  });

  it('shows "Updating..." and disables submit while update is in-flight', async () => {
    let resolveUpdate!: (v: SystemNodeTemplate) => void;
    mockUpdateTemplate.mockImplementation(
      () => new Promise<SystemNodeTemplate>((resolve) => { resolveUpdate = resolve; }),
    );

    renderModal({ editTemplate: TEMPLATE });
    await waitFor(() => expect(screen.getByLabelText(/name/i)).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /update template/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /updating/i })).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: /updating/i })).toBeDisabled();

    resolveUpdate({ ...TEMPLATE });
  });

  // ---------------------------------------------------------------------------
  // Cancel button / close via backdrop
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel button is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose when the X close button is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: 'Create Template' })).toBeInTheDocument(),
    );

    // The ghost X button is the first button rendered (in the header)
    const closeButtons = screen.getAllByRole('button');
    const xButton = closeButtons[0];
    fireEvent.click(xButton);
    expect(onClose).toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Platform dropdown — optional field
  // ---------------------------------------------------------------------------

  it('includes "Select a platform (optional)" as first option', async () => {
    renderModal();
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());
    expect(
      screen.getByText('Select a platform (optional)'),
    ).toBeInTheDocument();
  });

  it('allows submitting without selecting a platform', async () => {
    const created: SystemNodeTemplate = { ...TEMPLATE, node_platform_id: undefined };
    mockCreateTemplate.mockResolvedValue(created);

    renderModal();
    await waitFor(() => expect(screen.getByRole('combobox')).toBeInTheDocument());

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'no-platform' } });
    fireEvent.click(screen.getByRole('button', { name: /create template/i }));

    await waitFor(() =>
      expect(mockCreateTemplate).toHaveBeenCalledWith(
        expect.objectContaining({ node_platform_id: '' }),
      ),
    );
  });
});
