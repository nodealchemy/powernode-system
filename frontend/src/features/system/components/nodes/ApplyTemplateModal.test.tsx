import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { ApplyTemplateModal } from './ApplyTemplateModal';
import type { SystemNode } from '@system/features/system/types/system.types';

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

const mockApplyTemplate = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    applyTemplate: (...args: unknown[]) => mockApplyTemplate(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const NODE: SystemNode = {
  id: 'node-a',
  name: 'edge-01',
  enabled: true,
  node_template_id: 'tpl-a',
  node_template_name: 'ubuntu-base',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
} as SystemNode;

function applyResult(overrides: Record<string, unknown> = {}) {
  return {
    dry_run: true,
    created_count: 2,
    skipped_count: 1,
    purged_count: 0,
    warnings: [],
    errors: [],
    created: [],
    purged_module_ids: [],
    ...overrides,
  };
}

function renderModal(props: Partial<React.ComponentProps<typeof ApplyTemplateModal>> = {}) {
  const onClose = props.onClose ?? jest.fn();
  const onApplied = props.onApplied ?? jest.fn();
  const utils = render(
    <ApplyTemplateModal
      node={props.node === undefined ? NODE : props.node}
      isOpen={props.isOpen ?? true}
      onClose={onClose}
      onApplied={onApplied}
    />,
  );
  return { ...utils, onClose, onApplied };
}

const previewButton = () => screen.getByRole('button', { name: /preview changes|re-run preview/i });
const applyButton = () => screen.getByRole('button', { name: 'Apply Template' });
const purgeCheckbox = () => screen.getByRole('checkbox');

// =============================================================================
// Tests
// =============================================================================

describe('ApplyTemplateModal', () => {
  beforeEach(() => {
    mockApplyTemplate.mockReset();
    mockAddNotification.mockReset();
  });

  it('renders nothing when closed or without a node', () => {
    const { unmount } = renderModal({ isOpen: false });
    expect(screen.queryByText('Apply Template')).not.toBeInTheDocument();
    unmount();

    renderModal({ node: null });
    expect(screen.queryByText('Apply Template')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // The dry run is mandatory
  // ---------------------------------------------------------------------------

  it('disables Apply until a preview has been run', () => {
    renderModal();
    expect(applyButton()).toBeDisabled();
  });

  it('previews with dry_run true and writes nothing', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult());
    renderModal();

    fireEvent.click(previewButton());

    await waitFor(() =>
      expect(mockApplyTemplate).toHaveBeenCalledWith('node-a', { dry_run: true, purge_stale: false }),
    );
    expect(mockApplyTemplate).toHaveBeenCalledTimes(1);
  });

  it('shows the created, skipped and purged counts from the dry run', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult({ created_count: 5, skipped_count: 3, purged_count: 2 }));
    renderModal();

    fireEvent.click(previewButton());

    await waitFor(() => expect(screen.getByText('Dry-run result')).toBeInTheDocument());
    // Scoped to each label: an unanchored getByText('2') stays green if the
    // Created and Purged cells are swapped, and Purged is the count the
    // operator acts on.
    const cell = (label: string) => within(screen.getByText(label).parentElement as HTMLElement);
    expect(cell('Created').getByText('5')).toBeInTheDocument();
    expect(cell('Skipped').getByText('3')).toBeInTheDocument();
    expect(cell('Purged').getByText('2')).toBeInTheDocument();
  });

  it('enables Apply once the preview is on screen', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult());
    renderModal();

    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());
  });

  it('surfaces dry-run warnings and errors', async () => {
    mockApplyTemplate.mockResolvedValue(
      applyResult({ warnings: ['module net-base is disabled'], errors: ['module x not found'] }),
    );
    renderModal();

    fireEvent.click(previewButton());

    await waitFor(() => expect(screen.getByText('module net-base is disabled')).toBeInTheDocument());
    expect(screen.getByText('module x not found')).toBeInTheDocument();
  });

  it('keeps Apply disabled when the preview fails', async () => {
    mockApplyTemplate.mockRejectedValue(new Error('node has no template'));
    renderModal();

    fireEvent.click(previewButton());

    await waitFor(() => expect(screen.getByText('node has no template')).toBeInTheDocument());
    expect(applyButton()).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // The preview is pinned to the flags it was computed with
  // ---------------------------------------------------------------------------

  it('invalidates the preview when purge_stale is toggled afterwards', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult());
    renderModal();

    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());

    fireEvent.click(purgeCheckbox());

    expect(applyButton()).toBeDisabled();
    expect(screen.getByText(/purge option changed since this preview ran/i)).toBeInTheDocument();
  });

  it('re-enables Apply after re-previewing with the new flag', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult());
    renderModal();

    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());

    fireEvent.click(purgeCheckbox());
    fireEvent.click(previewButton());

    await waitFor(() => expect(applyButton()).not.toBeDisabled());
    expect(mockApplyTemplate).toHaveBeenLastCalledWith('node-a', { dry_run: true, purge_stale: true });
  });

  // ---------------------------------------------------------------------------
  // The real apply
  // ---------------------------------------------------------------------------

  it('applies with dry_run false and no confirmation when not purging', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult());
    const { onClose, onApplied } = renderModal();

    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());

    fireEvent.click(applyButton());

    await waitFor(() =>
      expect(mockApplyTemplate).toHaveBeenLastCalledWith('node-a', {
        dry_run: false,
        purge_stale: false,
      }),
    );
    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(onApplied).toHaveBeenCalled();
    expect(mockAddNotification).toHaveBeenCalledWith(expect.objectContaining({ type: 'success' }));
  });

  it('asks for a destructive confirmation before purging, and does not POST until confirmed', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult({ purged_count: 4 }));
    renderModal();

    fireEvent.click(purgeCheckbox());
    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());
    expect(mockApplyTemplate).toHaveBeenCalledTimes(1);

    fireEvent.click(applyButton());

    expect(screen.getByText('Purge stale module assignments')).toBeInTheDocument();
    expect(screen.getByText(/remove 4 module assignment\(s\)/)).toBeInTheDocument();
    expect(mockApplyTemplate).toHaveBeenCalledTimes(1);
  });

  it('purges only after the operator confirms', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult({ purged_count: 4 }));
    renderModal();

    fireEvent.click(purgeCheckbox());
    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());

    fireEvent.click(applyButton());
    fireEvent.click(screen.getByRole('button', { name: 'Apply and purge' }));

    await waitFor(() =>
      expect(mockApplyTemplate).toHaveBeenLastCalledWith('node-a', {
        dry_run: false,
        purge_stale: true,
      }),
    );
  });

  it('does not purge when the confirmation is dismissed', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult({ purged_count: 4 }));
    renderModal();

    fireEvent.click(purgeCheckbox());
    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());

    fireEvent.click(applyButton());
    fireEvent.click(screen.getByRole('button', { name: 'Keep assignments' }));

    expect(mockApplyTemplate).toHaveBeenCalledTimes(1);
    expect(screen.queryByText('Purge stale module assignments')).not.toBeInTheDocument();
  });

  // The shared Modal listens for Escape on document rather than on its own
  // subtree, so without closeOnEscape one press dismisses the confirmation and
  // this modal underneath it in the same keystroke.
  it('stands its own Escape down while the destructive confirmation is open', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult({ purged_count: 1 }));
    const { onClose } = renderModal();

    fireEvent.click(purgeCheckbox());
    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());

    fireEvent.click(applyButton());
    fireEvent.keyDown(document, { key: 'Escape' });

    expect(onClose).not.toHaveBeenCalled();
  });

  it('closes on Escape once the confirmation is gone', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult());
    const { onClose } = renderModal();

    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());

    fireEvent.keyDown(document, { key: 'Escape' });

    expect(onClose).toHaveBeenCalled();
  });

  // TemplateApplyService#preview appends this to every dry run's warnings.
  it('does not render the dry-run mode sentinel as a composition warning', async () => {
    mockApplyTemplate.mockResolvedValue(
      applyResult({ warnings: ['dry_run: no changes persisted', 'module net-base is disabled'] }),
    );
    renderModal();

    fireEvent.click(previewButton());

    await waitFor(() => expect(screen.getByText('module net-base is disabled')).toBeInTheDocument());
    expect(screen.queryByText('dry_run: no changes persisted')).not.toBeInTheDocument();
  });

  it('renders no warnings block when the sentinel is the only warning', async () => {
    mockApplyTemplate.mockResolvedValue(applyResult({ warnings: ['dry_run: no changes persisted'] }));
    renderModal();

    fireEvent.click(previewButton());

    await waitFor(() => expect(screen.getByText('Dry-run result')).toBeInTheDocument());
    expect(screen.queryByText('Warnings')).not.toBeInTheDocument();
  });

  it('invalidates the preview when the real apply is refused', async () => {
    mockApplyTemplate
      .mockResolvedValueOnce(applyResult())
      .mockRejectedValueOnce(new Error('template was deleted'));
    renderModal();

    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());

    fireEvent.click(applyButton());

    await waitFor(() => expect(applyButton()).toBeDisabled());
    expect(screen.queryByText('Dry-run result')).not.toBeInTheDocument();
  });

  it('keeps the modal open and shows the failure when the real apply is refused', async () => {
    mockApplyTemplate
      .mockResolvedValueOnce(applyResult())
      .mockRejectedValueOnce(new Error('template was deleted'));
    const { onClose } = renderModal();

    fireEvent.click(previewButton());
    await waitFor(() => expect(applyButton()).not.toBeDisabled());

    fireEvent.click(applyButton());

    await waitFor(() => expect(screen.getByText('template was deleted')).toBeInTheDocument());
    expect(onClose).not.toHaveBeenCalled();
  });
});
