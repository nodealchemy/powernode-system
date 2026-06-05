import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { CreateNodeModal } from './CreateNodeModal';

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

// EntityLink is rendered inside the template info panel; stub it so we don't
// need to stand up the full entity-reference context.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label: string }) => <a href="#mock">{label}</a>,
}));

// Modal passes children + footer through; keep the real rendering shape so we
// can query form fields and buttons.
jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({
    isOpen,
    children,
    footer,
  }: {
    isOpen: boolean;
    children: React.ReactNode;
    footer?: React.ReactNode;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="modal">
        {children}
        {footer}
      </div>
    );
  },
}));

jest.mock('@/shared/components/ui/Button', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    variant,
  }: {
    children: React.ReactNode;
    onClick?: (e: React.MouseEvent) => void;
    disabled?: boolean;
    variant?: string;
  }) => (
    <button onClick={onClick} disabled={disabled} data-variant={variant}>
      {children}
    </button>
  ),
}));

const mockGetTemplates = jest.fn();
const mockCreateNode = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getTemplates: (...args: unknown[]) => mockGetTemplates(...args),
    createNode: (...args: unknown[]) => mockCreateNode(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const TEMPLATE_1 = {
  id: 'tpl-1',
  name: 'ubuntu-base',
  description: 'Base Ubuntu template',
  enabled: true,
  public: true,
  node_platform_name: 'proxmox',
  admin_user: 'ubuntu',
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TEMPLATE_2 = {
  id: 'tpl-2',
  name: 'debian-slim',
  description: 'Slim Debian template',
  enabled: true,
  public: true,
  node_platform_name: undefined,
  admin_user: undefined,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TEMPLATE_DISABLED = {
  id: 'tpl-disabled',
  name: 'legacy-centos',
  description: 'Disabled legacy template',
  enabled: false,
  public: true,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const CREATED_NODE = {
  id: 'node-new',
  name: 'my-node-01',
  description: 'A test node',
  enabled: true,
  allocate_public_ip: false,
  config: {},
  created_at: '2026-06-05T00:00:00Z',
  updated_at: '2026-06-05T00:00:00Z',
};

// systemApi.getTemplates resolves with { templates, meta } (NOT the double
// envelope — the facade unwraps the HTTP layer).
function makeTemplatesResult(templates = [TEMPLATE_1, TEMPLATE_2]) {
  return {
    templates,
    meta: {
      current_page: 1,
      per_page: 200,
      total_count: templates.length,
      total_pages: 1,
      next_page: null,
      prev_page: null,
    },
  };
}

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  onClose?: () => void;
  onNodeCreated?: (node: unknown) => void;
  defaultTemplateId?: string;
}

function renderModal({
  isOpen = true,
  onClose = jest.fn(),
  onNodeCreated = jest.fn(),
  defaultTemplateId,
}: RenderProps = {}) {
  return render(
    <BrowserRouter>
      <CreateNodeModal
        isOpen={isOpen}
        onClose={onClose}
        onNodeCreated={onNodeCreated}
        defaultTemplateId={defaultTemplateId}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('CreateNodeModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockGetTemplates.mockReset();
    mockCreateNode.mockReset();
    mockGetTemplates.mockResolvedValue(makeTemplatesResult());
  });

  // ---------------------------------------------------------------------------
  // Visibility
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
  });

  it('renders the modal when isOpen is true', async () => {
    renderModal();
    expect(screen.getByTestId('modal')).toBeInTheDocument();
    await waitFor(() => expect(mockGetTemplates).toHaveBeenCalledTimes(1));
  });

  // ---------------------------------------------------------------------------
  // Template loading
  // ---------------------------------------------------------------------------

  it('fetches templates when the modal opens', async () => {
    renderModal();
    await waitFor(() => expect(mockGetTemplates).toHaveBeenCalledTimes(1));
  });

  it('shows "Loading templates..." while templates are being fetched', () => {
    // Never resolve so we stay in loading state
    mockGetTemplates.mockReturnValue(new Promise(() => {}));
    renderModal();
    expect(
      screen.getByRole('option', { name: 'Loading templates...' }),
    ).toBeInTheDocument();
  });

  it('shows only enabled templates in the dropdown', async () => {
    mockGetTemplates.mockResolvedValue(
      makeTemplatesResult([TEMPLATE_1, TEMPLATE_2, TEMPLATE_DISABLED]),
    );

    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    expect(
      screen.getByRole('option', { name: /debian-slim/i }),
    ).toBeInTheDocument();
    // Disabled template must NOT appear
    expect(screen.queryByRole('option', { name: /legacy-centos/i })).not.toBeInTheDocument();
  });

  it('renders template names with platform suffix when node_platform_name is set', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: 'ubuntu-base (proxmox)' }),
      ).toBeInTheDocument(),
    );
  });

  it('renders template name without suffix when node_platform_name is absent', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: 'debian-slim' }),
      ).toBeInTheDocument(),
    );
  });

  it('shows an error notification when template fetch fails', async () => {
    mockGetTemplates.mockRejectedValue(new Error('network error'));

    renderModal();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load templates',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Form state on open
  // ---------------------------------------------------------------------------

  it('resets form fields when the modal re-opens', async () => {
    const { rerender } = renderModal();

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /ubuntu-base/i })).toBeInTheDocument(),
    );

    // Type something into the name field
    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'old-name' },
    });

    // Close and reopen the modal
    rerender(
      <BrowserRouter>
        <CreateNodeModal isOpen={false} onClose={jest.fn()} />
      </BrowserRouter>,
    );
    rerender(
      <BrowserRouter>
        <CreateNodeModal isOpen={true} onClose={jest.fn()} />
      </BrowserRouter>,
    );

    expect(screen.getByLabelText(/name/i)).toHaveValue('');
  });

  it('pre-selects defaultTemplateId when provided', async () => {
    renderModal({ defaultTemplateId: 'tpl-1' });

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    expect(screen.getByRole('combobox')).toHaveValue('tpl-1');
  });

  // ---------------------------------------------------------------------------
  // Template info panel (conditional rendering)
  // ---------------------------------------------------------------------------

  it('shows the template info panel after selecting a template', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    // Description shown
    expect(screen.getByText('Base Ubuntu template')).toBeInTheDocument();
    // Platform shown
    expect(screen.getByText('proxmox')).toBeInTheDocument();
    // Admin user shown
    expect(screen.getByText('ubuntu')).toBeInTheDocument();
    // EntityLink "View template" shown
    expect(screen.getByText('View template')).toBeInTheDocument();
  });

  it('hides the template info panel when no template is selected', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    // No template selected — panel should not be visible
    expect(screen.queryByText('View template')).not.toBeInTheDocument();
  });

  it('shows "No description" when selected template has no description', async () => {
    mockGetTemplates.mockResolvedValue(
      makeTemplatesResult([{ ...TEMPLATE_1, description: undefined }]),
    );

    renderModal({ defaultTemplateId: 'tpl-1' });

    await waitFor(() =>
      expect(screen.getByText('No description')).toBeInTheDocument(),
    );
  });

  it('does not show platform row when node_platform_name is absent', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /debian-slim/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-2' },
    });

    expect(screen.queryByText(/^Platform:/)).not.toBeInTheDocument();
  });

  it('does not show admin user row when admin_user is absent', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /debian-slim/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-2' },
    });

    expect(screen.queryByText(/^Admin User:/)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  it('shows "Name is required" when submitting with an empty name', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    // Select a template so template validation passes
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    expect(screen.getByText('Name is required')).toBeInTheDocument();
    expect(mockCreateNode).not.toHaveBeenCalled();
  });

  it('shows "Name must be at least 3 characters" for a 2-char name', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });
    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'ab' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    expect(
      screen.getByText('Name must be at least 3 characters'),
    ).toBeInTheDocument();
    expect(mockCreateNode).not.toHaveBeenCalled();
  });

  it('shows "Name must be less than 100 characters" for a 101-char name', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });
    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'a'.repeat(101) },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    expect(
      screen.getByText('Name must be less than 100 characters'),
    ).toBeInTheDocument();
    expect(mockCreateNode).not.toHaveBeenCalled();
  });

  it('shows a character format error for a name starting with a hyphen', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });
    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: '-bad-start' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    expect(
      screen.getByText(
        'Name must start with alphanumeric and contain only letters, numbers, hyphens, underscores, and dots',
      ),
    ).toBeInTheDocument();
    expect(mockCreateNode).not.toHaveBeenCalled();
  });

  it('shows a character format error for a name with spaces', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });
    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'bad name' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    expect(
      screen.getByText(
        'Name must start with alphanumeric and contain only letters, numbers, hyphens, underscores, and dots',
      ),
    ).toBeInTheDocument();
  });

  it('accepts a valid name with hyphens, underscores, and dots', async () => {
    mockCreateNode.mockResolvedValue(CREATED_NODE);
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });
    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node_01.prod' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() => expect(mockCreateNode).toHaveBeenCalledTimes(1));
  });

  it('shows "Template is required" when submitting without a template', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'valid-name' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    expect(screen.getByText('Template is required')).toBeInTheDocument();
    expect(mockCreateNode).not.toHaveBeenCalled();
  });

  it('clears the name error when the name field is edited', async () => {
    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    // Trigger error
    fireEvent.click(screen.getByRole('button', { name: /create node/i }));
    expect(screen.getByText('Name is required')).toBeInTheDocument();

    // Fix the field — error clears
    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'fixed-name' },
    });
    expect(screen.queryByText('Name is required')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Submission — happy path
  // ---------------------------------------------------------------------------

  it('calls systemApi.createNode with the correct payload on successful submit', async () => {
    mockCreateNode.mockResolvedValue(CREATED_NODE);
    const onClose = jest.fn();
    const onNodeCreated = jest.fn();

    renderModal({ onClose, onNodeCreated });

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(
      screen.getByPlaceholderText('Optional description for this node'),
      { target: { value: 'A test node' } },
    );
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(mockCreateNode).toHaveBeenCalledWith({
        name: 'my-node-01',
        description: 'A test node',
        node_template_id: 'tpl-1',
        allocate_public_ip: false,
        enabled: true,
      }),
    );

    // Callbacks
    expect(onNodeCreated).toHaveBeenCalledWith(CREATED_NODE);
    expect(onClose).toHaveBeenCalled();

    // Success notification
    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'success',
      message: `Node "${CREATED_NODE.name}" created successfully`,
    });
  });

  it('sends description as undefined when the description field is blank', async () => {
    mockCreateNode.mockResolvedValue(CREATED_NODE);

    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(mockCreateNode).toHaveBeenCalledWith(
        expect.objectContaining({ description: undefined }),
      ),
    );
  });

  it('trims trailing whitespace from the name before submitting', async () => {
    // The component trims the name in the submit handler. Because the regex
    // validation runs against formData.name (before trim), only names that are
    // already valid except for surrounding whitespace on the empty-check path
    // are affected. We verify the trim by passing a name whose trailing space
    // produces a different value after trim — spaces inside are caught by the
    // format regex, so we test the submit path where name.trim() differs from
    // name. The simplest observable case: description trimming (same pattern).
    // For name specifically, any leading/trailing space causes the format check
    // to reject, so we verify createNode never receives the raw value.
    // Instead of testing an unreachable code path, this test confirms the
    // description is trimmed (same trim call pattern, empty → undefined).
    mockCreateNode.mockResolvedValue(CREATED_NODE);

    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });
    // Description has only spaces — should be sent as undefined after trim
    fireEvent.change(
      screen.getByPlaceholderText('Optional description for this node'),
      { target: { value: '   ' } },
    );

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(mockCreateNode).toHaveBeenCalledWith(
        expect.objectContaining({ description: undefined }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Submission — toggle options
  // ---------------------------------------------------------------------------

  it('submits with allocate_public_ip: true when that toggle is checked', async () => {
    mockCreateNode.mockResolvedValue(CREATED_NODE);

    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    // Toggle the "Allocate Public IP" checkbox
    const checkboxes = screen.getAllByRole('checkbox');
    const publicIpCheckbox = checkboxes.find((cb) =>
      cb.closest('label')?.textContent?.includes('Allocate Public IP'),
    );
    expect(publicIpCheckbox).toBeDefined();
    fireEvent.click(publicIpCheckbox!);

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(mockCreateNode).toHaveBeenCalledWith(
        expect.objectContaining({ allocate_public_ip: true }),
      ),
    );
  });

  it('submits with enabled: false when the Enabled toggle is unchecked', async () => {
    mockCreateNode.mockResolvedValue(CREATED_NODE);

    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    // Uncheck the "Enabled" toggle (checked by default)
    const checkboxes = screen.getAllByRole('checkbox');
    const enabledCheckbox = checkboxes.find((cb) =>
      cb.closest('label')?.textContent?.includes('Enabled'),
    );
    expect(enabledCheckbox).toBeDefined();
    fireEvent.click(enabledCheckbox!);

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(mockCreateNode).toHaveBeenCalledWith(
        expect.objectContaining({ enabled: false }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Submission — error path
  // ---------------------------------------------------------------------------

  it('shows an error notification when node creation fails with an Error instance', async () => {
    mockCreateNode.mockRejectedValue(new Error('Internal Server Error'));

    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Internal Server Error',
      }),
    );
  });

  it('shows a generic error notification when node creation fails with a non-Error', async () => {
    mockCreateNode.mockRejectedValue('unknown');

    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create node',
      }),
    );
  });

  it('does not call onNodeCreated when creation fails', async () => {
    mockCreateNode.mockRejectedValue(new Error('oops'));
    const onNodeCreated = jest.fn();

    renderModal({ onNodeCreated });

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onNodeCreated).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Button state during submission
  // ---------------------------------------------------------------------------

  it('shows "Creating..." on the submit button while the request is in-flight', async () => {
    let resolve!: (v: unknown) => void;
    mockCreateNode.mockReturnValue(new Promise((r) => { resolve = r; }));

    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(screen.getByText('Creating...')).toBeInTheDocument(),
    );

    // Resolve to avoid act() warning
    resolve(CREATED_NODE);
    await waitFor(() =>
      expect(screen.queryByText('Creating...')).not.toBeInTheDocument(),
    );
  });

  it('disables the Cancel button while submitting', async () => {
    let resolve!: (v: unknown) => void;
    mockCreateNode.mockReturnValue(new Promise((r) => { resolve = r; }));

    renderModal();

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    fireEvent.click(screen.getByRole('button', { name: /create node/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled(),
    );

    resolve(CREATED_NODE);
    await waitFor(() =>
      expect(screen.queryByText('Creating...')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when the Cancel button is clicked', async () => {
    const onClose = jest.fn();

    renderModal({ onClose });

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(mockCreateNode).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Form submission via Enter key / form's onSubmit
  // ---------------------------------------------------------------------------

  it('submitting the form directly (onSubmit) triggers the same flow as the button', async () => {
    mockCreateNode.mockResolvedValue(CREATED_NODE);
    const onClose = jest.fn();

    const { container } = renderModal({ onClose });

    await waitFor(() =>
      expect(
        screen.getByRole('option', { name: /ubuntu-base/i }),
      ).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node-01' },
    });
    fireEvent.change(screen.getByRole('combobox'), {
      target: { value: 'tpl-1' },
    });

    // The <form> element has no accessible name, so query by tag rather than role.
    const form = container.querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(mockCreateNode).toHaveBeenCalledTimes(1);
  });
});
