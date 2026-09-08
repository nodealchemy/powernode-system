import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { CloneTemplateModal } from './CloneTemplateModal';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';

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

const mockCloneTemplate = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    cloneTemplate: (...args: unknown[]) => mockCloneTemplate(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const TEMPLATE: SystemNodeTemplate = {
  id: 'tpl-a',
  name: 'ubuntu-base',
  description: 'Base template',
  enabled: true,
  public: false,
  admin_user: 'root',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
} as SystemNodeTemplate;

const CLONE: SystemNodeTemplate = { ...TEMPLATE, id: 'tpl-clone', name: 'ubuntu-base-copy' };

function renderModal(props: Partial<React.ComponentProps<typeof CloneTemplateModal>> = {}) {
  const onClose = props.onClose ?? jest.fn();
  const onCloned = props.onCloned ?? jest.fn();
  const utils = render(
    <CloneTemplateModal
      template={props.template === undefined ? TEMPLATE : props.template}
      isOpen={props.isOpen ?? true}
      onClose={onClose}
      onCloned={onCloned}
    />,
  );
  return { ...utils, onClose, onCloned };
}

// =============================================================================
// Tests
// =============================================================================

describe('CloneTemplateModal', () => {
  beforeEach(() => {
    mockCloneTemplate.mockReset();
    mockAddNotification.mockReset();
  });

  it('renders nothing when closed', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Clone Template')).not.toBeInTheDocument();
  });

  it('renders nothing when there is no source template', () => {
    renderModal({ template: null });
    expect(screen.queryByText('Clone Template')).not.toBeInTheDocument();
  });

  it('names the source template and defaults the new name to "<source>-copy"', () => {
    renderModal();
    expect(screen.getByPlaceholderText('ubuntu-base-copy')).toBeInTheDocument();
  });

  it('clones with no name so the backend applies its default', async () => {
    mockCloneTemplate.mockResolvedValue({ template: CLONE });
    renderModal();

    fireEvent.click(screen.getByRole('button', { name: 'Clone Template' }));

    await waitFor(() => expect(mockCloneTemplate).toHaveBeenCalledWith('tpl-a', undefined));
  });

  it('sends the operator-supplied name, trimmed', async () => {
    mockCloneTemplate.mockResolvedValue({ template: CLONE });
    renderModal();

    fireEvent.change(screen.getByPlaceholderText('ubuntu-base-copy'), {
      target: { value: '  staging-base  ' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Clone Template' }));

    await waitFor(() => expect(mockCloneTemplate).toHaveBeenCalledWith('tpl-a', 'staging-base'));
  });

  it('notifies, reports the clone upward and closes on a clean clone', async () => {
    mockCloneTemplate.mockResolvedValue({ template: CLONE });
    const { onClose, onCloned } = renderModal();

    fireEvent.click(screen.getByRole('button', { name: 'Clone Template' }));

    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(onCloned).toHaveBeenCalledWith(CLONE);
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' }),
    );
  });

  it('stays open and shows the composition report rather than closing over it', async () => {
    mockCloneTemplate.mockResolvedValue({
      template: CLONE,
      composition_report: [
        { severity: 'error', kind: 'instance_variety_collision', detail: 'two instance modules in one category' },
        { severity: 'warning', kind: 'mount_path_collision', detail: '/var/lib claimed twice' },
      ],
    });
    const { onClose } = renderModal();

    fireEvent.click(screen.getByRole('button', { name: 'Clone Template' }));

    await waitFor(() => expect(screen.getByText(/Composition report/)).toBeInTheDocument());
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByText('instance_variety_collision')).toBeInTheDocument();
    expect(screen.getByText(/two instance modules in one category/)).toBeInTheDocument();
  });

  it('labels each report entry with its own severity', async () => {
    mockCloneTemplate.mockResolvedValue({
      template: CLONE,
      composition_report: [
        { severity: 'error', kind: 'module_dependency_conflict', detail: 'a conflicts with b' },
        { severity: 'warning', kind: 'mount_path_collision', detail: '/var/lib claimed twice' },
      ],
    });
    renderModal();

    fireEvent.click(screen.getByRole('button', { name: 'Clone Template' }));

    await waitFor(() => expect(screen.getByText('error')).toBeInTheDocument());
    expect(screen.getByText('warning')).toBeInTheDocument();
  });

  it('shows the failure inline and keeps the form open when the clone is refused', async () => {
    mockCloneTemplate.mockRejectedValue(new Error('name has already been taken'));
    const { onClose } = renderModal();

    fireEvent.click(screen.getByRole('button', { name: 'Clone Template' }));

    await waitFor(() =>
      expect(screen.getByText('name has already been taken')).toBeInTheDocument(),
    );
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Clone Template' })).toBeInTheDocument();
  });
});
