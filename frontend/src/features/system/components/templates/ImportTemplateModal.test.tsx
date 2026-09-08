import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { ImportTemplateModal } from './ImportTemplateModal';
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

const mockLoggerWarn = jest.fn();
jest.mock('@/shared/utils/logger', () => ({
  logger: {
    warn: (...args: unknown[]) => mockLoggerWarn(...args),
    error: jest.fn(),
    info: jest.fn(),
    debug: jest.fn(),
  },
}));

const mockImportTemplate = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    importTemplate: (...args: unknown[]) => mockImportTemplate(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const IMPORTED: SystemNodeTemplate = {
  id: 'tpl-imported',
  name: 'imported-base',
  enabled: true,
  public: false,
  admin_user: 'root',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
} as SystemNodeTemplate;

const BUNDLE = { node_template: { name: 'imported-base' }, template_modules: [] };

function renderModal(props: Partial<React.ComponentProps<typeof ImportTemplateModal>> = {}) {
  const onClose = props.onClose ?? jest.fn();
  const onImported = props.onImported ?? jest.fn();
  const utils = render(
    <ImportTemplateModal isOpen={props.isOpen ?? true} onClose={onClose} onImported={onImported} />,
  );
  return { ...utils, onClose, onImported };
}

// FormField renders its label as a sibling <label> without htmlFor, so the
// placeholder is the stable handle for these inputs.
const bundleField = () => screen.getByPlaceholderText(/node_template/);
const importButton = () => screen.getByRole('button', { name: 'Import Template' });

// =============================================================================
// Tests
// =============================================================================

describe('ImportTemplateModal', () => {
  beforeEach(() => {
    mockImportTemplate.mockReset();
    mockAddNotification.mockReset();
    mockLoggerWarn.mockReset();
  });

  it('renders nothing when closed', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText('Import Template')).not.toBeInTheDocument();
  });

  it('disables Import until a bundle has been supplied', () => {
    renderModal();
    expect(importButton()).toBeDisabled();

    fireEvent.change(bundleField(), { target: { value: JSON.stringify(BUNDLE) } });
    expect(importButton()).not.toBeDisabled();
  });

  it('POSTs the parsed bundle object, not the raw text', async () => {
    mockImportTemplate.mockResolvedValue({ template: IMPORTED, template_modules_count: 2 });
    renderModal();

    fireEvent.change(bundleField(), { target: { value: JSON.stringify(BUNDLE) } });
    fireEvent.click(importButton());

    await waitFor(() => expect(mockImportTemplate).toHaveBeenCalledWith(BUNDLE, undefined));
  });

  it('sends the operator-supplied name alongside the bundle', async () => {
    mockImportTemplate.mockResolvedValue({ template: IMPORTED, template_modules_count: 0 });
    renderModal();

    fireEvent.change(bundleField(), { target: { value: JSON.stringify(BUNDLE) } });
    fireEvent.change(screen.getByPlaceholderText('Name carried in the bundle'), { target: { value: ' renamed ' } });
    fireEvent.click(importButton());

    await waitFor(() => expect(mockImportTemplate).toHaveBeenCalledWith(BUNDLE, 'renamed'));
  });

  it('rejects malformed JSON in the browser without calling the API', async () => {
    renderModal();

    fireEvent.change(bundleField(), { target: { value: '{"node_template": ' } });
    fireEvent.click(importButton());

    await waitFor(() => expect(screen.getByText(/not valid JSON/)).toBeInTheDocument());
    expect(mockImportTemplate).not.toHaveBeenCalled();
  });

  it('rejects a JSON array, which the endpoint cannot accept as a bundle', async () => {
    renderModal();

    fireEvent.change(bundleField(), { target: { value: '[1, 2, 3]' } });
    fireEvent.click(importButton());

    await waitFor(() =>
      expect(screen.getByText('The bundle must be a JSON object.')).toBeInTheDocument(),
    );
    expect(mockImportTemplate).not.toHaveBeenCalled();
  });

  it('notifies with the module count and closes on a clean import', async () => {
    mockImportTemplate.mockResolvedValue({ template: IMPORTED, template_modules_count: 4 });
    const { onClose, onImported } = renderModal();

    fireEvent.change(bundleField(), { target: { value: JSON.stringify(BUNDLE) } });
    fireEvent.click(importButton());

    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(onImported).toHaveBeenCalledWith(IMPORTED);
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success', message: expect.stringContaining('4 module') }),
    );
  });

  it('stays open and shows the composition report rather than closing over it', async () => {
    mockImportTemplate.mockResolvedValue({
      template: IMPORTED,
      template_modules_count: 3,
      composition_report: [
        { severity: 'error', kind: 'composition_analysis_failed', detail: 'analysis blew up' },
      ],
    });
    const { onClose } = renderModal();

    fireEvent.change(bundleField(), { target: { value: JSON.stringify(BUNDLE) } });
    fireEvent.click(importButton());

    await waitFor(() => expect(screen.getByText(/Composition report/)).toBeInTheDocument());
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByText('composition_analysis_failed')).toBeInTheDocument();
  });

  it('shows a rejected import inline and keeps the form open', async () => {
    mockImportTemplate.mockRejectedValue(new Error('missing modules'));
    const { onClose } = renderModal();

    fireEvent.change(bundleField(), { target: { value: JSON.stringify(BUNDLE) } });
    fireEvent.click(importButton());

    await waitFor(() => expect(screen.getByText('missing modules')).toBeInTheDocument());
    expect(onClose).not.toHaveBeenCalled();
    expect(bundleField()).toBeInTheDocument();
  });
});
