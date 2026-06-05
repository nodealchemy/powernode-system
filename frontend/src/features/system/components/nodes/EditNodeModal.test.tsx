import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { EditNodeModal } from './EditNodeModal';
import type { SystemNode, SystemNodeTemplate } from '@system/features/system/types/system.types';

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

const mockGetTemplates = jest.fn();
const mockUpdateNode = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getTemplates: (...args: unknown[]) => mockGetTemplates(...args),
    updateNode: (...args: unknown[]) => mockUpdateNode(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const TEMPLATE_1: SystemNodeTemplate = {
  id: 'tpl-1',
  name: 'ubuntu-base',
  description: 'Ubuntu base template',
  enabled: true,
  public: true,
  admin_user: 'ubuntu',
  node_platform_name: 'amd64',
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const TEMPLATE_2: SystemNodeTemplate = {
  id: 'tpl-2',
  name: 'arm-slim',
  description: 'ARM slim template',
  enabled: false,
  public: false,
  config: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const NODE: SystemNode = {
  id: 'node-abc',
  name: 'my-node-01',
  description: 'A test node',
  enabled: true,
  allocate_public_ip: false,
  node_template_id: 'tpl-1',
  instance_count: 3,
  public_address: '1.2.3.4',
  config: {},
  created_at: '2026-05-01T12:00:00Z',
  updated_at: '2026-05-10T08:30:00Z',
};

const TEMPLATES_RESPONSE = {
  templates: [TEMPLATE_1, TEMPLATE_2],
  meta: {
    current_page: 1,
    per_page: 200,
    total_count: 2,
    total_pages: 1,
    next_page: null,
    prev_page: null,
  },
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  node?: SystemNode | null;
  isOpen?: boolean;
  onClose?: () => void;
  onNodeUpdated?: (node: SystemNode) => void;
}

const renderModal = ({
  node = NODE,
  isOpen = true,
  onClose = jest.fn(),
  onNodeUpdated = jest.fn(),
}: RenderProps = {}) =>
  render(
    <BrowserRouter>
      <EditNodeModal
        node={node}
        isOpen={isOpen}
        onClose={onClose}
        onNodeUpdated={onNodeUpdated}
      />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('EditNodeModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockGetTemplates.mockReset();
    mockUpdateNode.mockReset();
    mockGetTemplates.mockResolvedValue(TEMPLATES_RESPONSE);
  });

  // ---------------------------------------------------------------------------
  // Render / open state
  // ---------------------------------------------------------------------------

  it('renders the modal when isOpen is true with node data', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Edit Node')).toBeInTheDocument(),
    );
    expect(screen.getByText(/Editing: my-node-01/)).toBeInTheDocument();
  });

  it('does not render modal content when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Edit Node')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Form pre-population from node prop
  // ---------------------------------------------------------------------------

  it('pre-populates the name field with the node name', async () => {
    renderModal();

    await waitFor(() => {
      const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
      expect(nameInput.value).toBe('my-node-01');
    });
  });

  it('pre-populates the description textarea', async () => {
    renderModal();

    await waitFor(() => {
      const descTextarea = screen.getByLabelText(/description/i) as HTMLTextAreaElement;
      expect(descTextarea.value).toBe('A test node');
    });
  });

  // ---------------------------------------------------------------------------
  // Template loading
  // ---------------------------------------------------------------------------

  it('fetches templates when modal opens and populates the dropdown', async () => {
    renderModal();

    await waitFor(() =>
      expect(mockGetTemplates).toHaveBeenCalledTimes(1),
    );

    await waitFor(() => {
      const select = screen.getByLabelText(/template/i);
      expect(select).toBeInTheDocument();
    });

    // Both templates appear, disabled template shows [Disabled]
    await waitFor(() => {
      expect(screen.getByText('ubuntu-base (amd64)')).toBeInTheDocument();
      expect(screen.getByText('arm-slim [Disabled]')).toBeInTheDocument();
    });
  });

  it('shows error notification when template fetch fails', async () => {
    mockGetTemplates.mockRejectedValue(new Error('Network error'));

    renderModal();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load templates',
      }),
    );
  });

  it('does not fetch templates when modal is closed', () => {
    renderModal({ isOpen: false });
    expect(mockGetTemplates).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Template info panel
  // ---------------------------------------------------------------------------

  it('shows template info panel when a template with description is selected', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('ubuntu-base (amd64)')).toBeInTheDocument(),
    );

    // Select template 1 which has a description and admin_user
    fireEvent.change(screen.getByLabelText(/template/i), {
      target: { value: 'tpl-1' },
    });

    await waitFor(() => {
      expect(screen.getByText('Ubuntu base template')).toBeInTheDocument();
      expect(screen.getByText('ubuntu')).toBeInTheDocument();
    });
  });

  it('shows template platform name in info panel', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('ubuntu-base (amd64)')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/template/i), {
      target: { value: 'tpl-1' },
    });

    await waitFor(() => {
      expect(screen.getByText('amd64')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Node metadata section
  // ---------------------------------------------------------------------------

  it('renders node metadata (instance count, public address)', async () => {
    renderModal();

    await waitFor(() => {
      expect(screen.getByText('3')).toBeInTheDocument(); // instance_count
      expect(screen.getByText('1.2.3.4')).toBeInTheDocument(); // public_address
    });
  });

  it('renders created/updated timestamps', async () => {
    renderModal();

    await waitFor(() => {
      expect(screen.getByText('Created:')).toBeInTheDocument();
      expect(screen.getByText('Updated:')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Form interactions
  // ---------------------------------------------------------------------------

  it('updates name field on user input', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    const nameInput = screen.getByLabelText(/name/i) as HTMLInputElement;
    fireEvent.change(nameInput, { target: { value: 'new-node-name' } });
    expect(nameInput.value).toBe('new-node-name');
  });

  it('updates description on user input', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/description/i)).toBeInTheDocument(),
    );

    const desc = screen.getByLabelText(/description/i) as HTMLTextAreaElement;
    fireEvent.change(desc, { target: { value: 'Updated description' } });
    expect(desc.value).toBe('Updated description');
  });

  it('toggles allocate_public_ip checkbox', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Allocate Public IP')).toBeInTheDocument(),
    );

    // Find the sr-only checkbox for allocate_public_ip (it's labelled by adjacent span text)
    const checkboxes = screen.getAllByRole('checkbox');
    // First checkbox = allocate_public_ip, second = enabled
    const allocateIpCheckbox = checkboxes[0] as HTMLInputElement;
    expect(allocateIpCheckbox.checked).toBe(false);
    fireEvent.click(allocateIpCheckbox);
    expect(allocateIpCheckbox.checked).toBe(true);
  });

  it('toggles enabled checkbox', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('Enabled')).toBeInTheDocument(),
    );

    const checkboxes = screen.getAllByRole('checkbox');
    const enabledCheckbox = checkboxes[1] as HTMLInputElement;
    expect(enabledCheckbox.checked).toBe(true);
    fireEvent.click(enabledCheckbox);
    expect(enabledCheckbox.checked).toBe(false);
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  it('shows "Name is required" when name is cleared', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    const nameInput = screen.getByLabelText(/name/i);
    fireEvent.change(nameInput, { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument(),
    );
  });

  it('shows error when name is shorter than 3 characters', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'ab' } });
    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(
        screen.getByText('Name must be at least 3 characters'),
      ).toBeInTheDocument(),
    );
  });

  it('shows error when name exceeds 100 characters', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    const longName = 'a'.repeat(101);
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: longName } });
    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(
        screen.getByText('Name must be less than 100 characters'),
      ).toBeInTheDocument(),
    );
  });

  it('shows error when name starts with a non-alphanumeric character', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: '-bad-name' } });
    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(
        screen.getByText(
          'Name must start with alphanumeric and contain only letters, numbers, hyphens, underscores, and dots',
        ),
      ).toBeInTheDocument(),
    );
  });

  it('shows error when name contains invalid characters', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: 'my node!' } });
    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(
        screen.getByText(
          'Name must start with alphanumeric and contain only letters, numbers, hyphens, underscores, and dots',
        ),
      ).toBeInTheDocument(),
    );
  });

  it('accepts names with hyphens, underscores, and dots', async () => {
    const updatedNode: SystemNode = { ...NODE, name: 'my-node_v1.0' };
    mockUpdateNode.mockResolvedValue(updatedNode);

    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'my-node_v1.0' },
    });
    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(mockUpdateNode).toHaveBeenCalledWith(
        'node-abc',
        expect.objectContaining({ name: 'my-node_v1.0' }),
      ),
    );
  });

  it('shows "Template is required" when template is cleared', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/template/i)).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/template/i), { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(screen.getByText('Template is required')).toBeInTheDocument(),
    );
  });

  it('clears name error when user edits the field', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    // Trigger validation error
    fireEvent.change(screen.getByLabelText(/name/i), { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument(),
    );

    // Edit the field → error should disappear
    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: 'fixed-name' },
    });

    await waitFor(() =>
      expect(screen.queryByText('Name is required')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Successful submission
  // ---------------------------------------------------------------------------

  it('calls systemApi.updateNode with correct payload and node id on submit', async () => {
    const updatedNode: SystemNode = {
      ...NODE,
      name: 'my-node-01',
      description: 'A test node',
    };
    mockUpdateNode.mockResolvedValue(updatedNode);

    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(mockUpdateNode).toHaveBeenCalledWith('node-abc', {
        name: 'my-node-01',
        description: 'A test node',
        node_template_id: 'tpl-1',
        allocate_public_ip: false,
        enabled: true,
      }),
    );
  });

  it('trims whitespace from name before submitting', async () => {
    const updatedNode: SystemNode = { ...NODE, name: 'trimmed-name' };
    mockUpdateNode.mockResolvedValue(updatedNode);

    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: '  trimmed-name  ' },
    });
    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(mockUpdateNode).toHaveBeenCalledWith(
        'node-abc',
        expect.objectContaining({ name: 'trimmed-name' }),
      ),
    );
  });

  it('sends description as undefined when empty', async () => {
    const updatedNode: SystemNode = { ...NODE, description: undefined };
    mockUpdateNode.mockResolvedValue(updatedNode);

    renderModal({ node: { ...NODE, description: '' } });

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(mockUpdateNode).toHaveBeenCalledWith(
        'node-abc',
        expect.objectContaining({ description: undefined }),
      ),
    );
  });

  it('shows success notification with node name after successful update', async () => {
    const updatedNode: SystemNode = { ...NODE, name: 'my-node-01' };
    mockUpdateNode.mockResolvedValue(updatedNode);

    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'Node "my-node-01" updated successfully',
      }),
    );
  });

  it('calls onNodeUpdated callback with the updated node', async () => {
    const updatedNode: SystemNode = { ...NODE, name: 'my-node-01' };
    mockUpdateNode.mockResolvedValue(updatedNode);

    const onNodeUpdated = jest.fn();
    renderModal({ onNodeUpdated });

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(onNodeUpdated).toHaveBeenCalledWith(updatedNode),
    );
  });

  it('calls onClose after successful update', async () => {
    const updatedNode: SystemNode = { ...NODE };
    mockUpdateNode.mockResolvedValue(updatedNode);

    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() => expect(onClose).toHaveBeenCalled());
  });

  // ---------------------------------------------------------------------------
  // Error handling on submit
  // ---------------------------------------------------------------------------

  it('shows error notification when updateNode throws an Error', async () => {
    mockUpdateNode.mockRejectedValue(new Error('Server error'));

    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Server error',
      }),
    );
  });

  it('shows generic error message when updateNode throws a non-Error', async () => {
    mockUpdateNode.mockRejectedValue('string error');

    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to update node',
      }),
    );
  });

  it('does not close or call onNodeUpdated after a failed update', async () => {
    mockUpdateNode.mockRejectedValue(new Error('Oops'));

    const onClose = jest.fn();
    const onNodeUpdated = jest.fn();
    renderModal({ onClose, onNodeUpdated });

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onClose).not.toHaveBeenCalled();
    expect(onNodeUpdated).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Submitting state / disabled controls
  // ---------------------------------------------------------------------------

  it('shows "Saving..." text and disables buttons while submitting', async () => {
    let resolveUpdate: (value: SystemNode) => void;
    mockUpdateNode.mockImplementation(
      () =>
        new Promise<SystemNode>((resolve) => {
          resolveUpdate = resolve;
        }),
    );

    renderModal();

    await waitFor(() =>
      expect(screen.getByLabelText(/name/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /saving/i })).toBeInTheDocument(),
    );

    expect(screen.getByRole('button', { name: /saving/i })).toBeDisabled();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();

    // Resolve so state clears
    resolveUpdate!({ ...NODE });
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel is clicked', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Template dropdown options
  // ---------------------------------------------------------------------------

  it('shows disabled template with [Disabled] suffix', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('arm-slim [Disabled]')).toBeInTheDocument(),
    );
  });

  it('shows template with platform name in parentheses', async () => {
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('ubuntu-base (amd64)')).toBeInTheDocument(),
    );
  });

  it('shows template without platform suffix when node_platform_name is absent', async () => {
    renderModal();

    await waitFor(() => {
      // arm-slim has no node_platform_name — just "arm-slim [Disabled]"
      const option = screen.getByText('arm-slim [Disabled]');
      expect(option.textContent).not.toContain('(');
    });
  });

  // ---------------------------------------------------------------------------
  // Null node guard
  // ---------------------------------------------------------------------------

  it('renders nothing meaningful when node is null but isOpen is true', () => {
    renderModal({ node: null });
    // Modal may open but the subtitle and metadata section should be absent
    // because node is null. No crash.
    expect(screen.queryByText(/Editing:/)).not.toBeInTheDocument();
  });
});
