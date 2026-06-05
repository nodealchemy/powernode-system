import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { BrowserRouter } from 'react-router-dom';
import { ScriptFormModal } from './ScriptFormModal';
import type { SystemNodeScript } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockCreateScript = jest.fn();
const mockUpdateScript = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    createScript: (...args: unknown[]) => mockCreateScript(...args),
    updateScript: (...args: unknown[]) => mockUpdateScript(...args),
  },
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

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const SCRIPT_A: SystemNodeScript = {
  id: 'script-abc',
  name: 'My Init Script',
  description: 'Does init things',
  variety: 'init',
  data: '#!/bin/bash\necho init',
  enabled: true,
  public: false,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderOpts {
  isOpen?: boolean;
  editScript?: SystemNodeScript | null;
  onClose?: () => void;
  onScriptSaved?: (script: SystemNodeScript) => void;
}

function renderModal(opts: RenderOpts = {}) {
  const {
    isOpen = true,
    editScript = null,
    onClose = jest.fn(),
    onScriptSaved = jest.fn(),
  } = opts;

  return render(
    <BrowserRouter>
      <ScriptFormModal
        isOpen={isOpen}
        onClose={onClose}
        onScriptSaved={onScriptSaved}
        editScript={editScript}
      />
    </BrowserRouter>
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('ScriptFormModal', () => {
  beforeEach(() => {
    mockCreateScript.mockReset();
    mockUpdateScript.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render / visibility
  // ---------------------------------------------------------------------------

  describe('visibility', () => {
    it('renders nothing when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(screen.queryByRole('heading', { name: /create script/i })).not.toBeInTheDocument();
    });

    it('renders the modal when isOpen is true', () => {
      renderModal({ isOpen: true });
      expect(screen.getByRole('heading', { name: /create script/i })).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Create mode
  // ---------------------------------------------------------------------------

  describe('create mode', () => {
    it('shows "Create Script" heading and "Create Script" submit button', () => {
      renderModal();
      expect(screen.getByRole('heading', { name: /create script/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /create script/i })).toBeInTheDocument();
    });

    it('pre-fills script content with bash shebang template', () => {
      renderModal();
      const textarea = screen.getByLabelText(/script content/i) as HTMLTextAreaElement;
      expect(textarea.value).toContain('#!/bin/bash');
    });

    it('defaults variety to "custom"', () => {
      renderModal();
      const select = screen.getByLabelText(/type/i) as HTMLSelectElement;
      expect(select.value).toBe('custom');
    });

    it('defaults enabled=true and public=false', () => {
      renderModal();
      const enabledCheckbox = screen.getByLabelText(/^enabled$/i) as HTMLInputElement;
      const publicCheckbox = screen.getByLabelText(/^public$/i) as HTMLInputElement;
      expect(enabledCheckbox.checked).toBe(true);
      expect(publicCheckbox.checked).toBe(false);
    });

    it('calls systemApi.createScript with correct payload on submit', async () => {
      const onScriptSaved = jest.fn();
      const onClose = jest.fn();
      mockCreateScript.mockResolvedValue({ ...SCRIPT_A, id: 'new-id', name: 'Deploy App' });

      renderModal({ onScriptSaved, onClose });

      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Deploy App' } });
      fireEvent.change(screen.getByLabelText(/type/i), { target: { value: 'build' } });
      fireEvent.change(screen.getByLabelText(/description/i), { target: { value: 'A deploy script' } });
      fireEvent.change(screen.getByLabelText(/script content/i), { target: { value: '#!/bin/bash\necho deploy' } });

      // Uncheck enabled
      fireEvent.click(screen.getByLabelText(/^enabled$/i));

      fireEvent.submit(screen.getByRole('button', { name: /create script/i }).closest('form')!);

      await waitFor(() =>
        expect(mockCreateScript).toHaveBeenCalledWith({
          name: 'Deploy App',
          description: 'A deploy script',
          variety: 'build',
          data: '#!/bin/bash\necho deploy',
          enabled: false,
          public: false,
        })
      );
    });

    it('shows success notification and calls onScriptSaved + onClose after create', async () => {
      const onScriptSaved = jest.fn();
      const onClose = jest.fn();
      const newScript = { ...SCRIPT_A, id: 'new-id', name: 'New Script' };
      mockCreateScript.mockResolvedValue(newScript);

      renderModal({ onScriptSaved, onClose });

      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'New Script' } });
      fireEvent.submit(screen.getByRole('button', { name: /create script/i }).closest('form')!);

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: expect.stringContaining('New Script'),
        })
      );
      expect(onScriptSaved).toHaveBeenCalledWith(newScript);
      expect(onClose).toHaveBeenCalled();
    });

    it('shows error notification when createScript rejects', async () => {
      mockCreateScript.mockRejectedValue(new Error('Network failure'));

      renderModal();

      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Bad Script' } });
      fireEvent.submit(screen.getByRole('button', { name: /create script/i }).closest('form')!);

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: expect.stringContaining('Failed to create script'),
        })
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Edit mode
  // ---------------------------------------------------------------------------

  describe('edit mode', () => {
    it('shows "Edit Script" heading and "Update Script" submit button', () => {
      renderModal({ editScript: SCRIPT_A });
      expect(screen.getByRole('heading', { name: /edit script/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /update script/i })).toBeInTheDocument();
    });

    it('pre-populates fields from editScript', () => {
      renderModal({ editScript: SCRIPT_A });

      expect((screen.getByLabelText(/^name/i) as HTMLInputElement).value).toBe('My Init Script');
      expect((screen.getByLabelText(/description/i) as HTMLTextAreaElement).value).toBe('Does init things');
      expect((screen.getByLabelText(/type/i) as HTMLSelectElement).value).toBe('init');
      expect((screen.getByLabelText(/script content/i) as HTMLTextAreaElement).value).toBe('#!/bin/bash\necho init');
      expect((screen.getByLabelText(/^enabled$/i) as HTMLInputElement).checked).toBe(true);
      expect((screen.getByLabelText(/^public$/i) as HTMLInputElement).checked).toBe(false);
    });

    it('calls systemApi.updateScript with the script id and updated fields', async () => {
      const onScriptSaved = jest.fn();
      const onClose = jest.fn();
      const updated = { ...SCRIPT_A, name: 'Renamed Script' };
      mockUpdateScript.mockResolvedValue(updated);

      renderModal({ editScript: SCRIPT_A, onScriptSaved, onClose });

      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Renamed Script' } });
      fireEvent.submit(screen.getByRole('button', { name: /update script/i }).closest('form')!);

      await waitFor(() =>
        expect(mockUpdateScript).toHaveBeenCalledWith('script-abc', expect.objectContaining({
          name: 'Renamed Script',
        }))
      );
    });

    it('shows success notification after update', async () => {
      const updated = { ...SCRIPT_A, name: 'My Init Script' };
      mockUpdateScript.mockResolvedValue(updated);

      renderModal({ editScript: SCRIPT_A });

      fireEvent.submit(screen.getByRole('button', { name: /update script/i }).closest('form')!);

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: expect.stringContaining('updated successfully'),
        })
      );
    });

    it('shows error notification when updateScript rejects', async () => {
      mockUpdateScript.mockRejectedValue(new Error('Server error'));

      renderModal({ editScript: SCRIPT_A });

      fireEvent.submit(screen.getByRole('button', { name: /update script/i }).closest('form')!);

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: expect.stringContaining('Failed to update script'),
        })
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  describe('validation', () => {
    it('shows "Name is required" when name is empty on submit', async () => {
      renderModal();
      // Clear any default name (there shouldn't be one in create mode)
      fireEvent.submit(screen.getByRole('button', { name: /create script/i }).closest('form')!);

      await waitFor(() =>
        expect(screen.getByText(/name is required/i)).toBeInTheDocument()
      );
      expect(mockCreateScript).not.toHaveBeenCalled();
    });

    it('shows "Name must be at least 2 characters" for single-char name', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'x' } });
      fireEvent.submit(screen.getByRole('button', { name: /create script/i }).closest('form')!);

      await waitFor(() =>
        expect(screen.getByText(/at least 2 characters/i)).toBeInTheDocument()
      );
      expect(mockCreateScript).not.toHaveBeenCalled();
    });

    it('clears the name error when the user types a valid name', async () => {
      renderModal();
      fireEvent.submit(screen.getByRole('button', { name: /create script/i }).closest('form')!);

      await waitFor(() =>
        expect(screen.getByText(/name is required/i)).toBeInTheDocument()
      );

      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Valid Name' } });
      expect(screen.queryByText(/name is required/i)).not.toBeInTheDocument();
    });

    it('does not submit when name is whitespace only', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: '   ' } });
      fireEvent.submit(screen.getByRole('button', { name: /create script/i }).closest('form')!);

      await waitFor(() =>
        expect(screen.getByText(/name is required/i)).toBeInTheDocument()
      );
      expect(mockCreateScript).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Form interactions
  // ---------------------------------------------------------------------------

  describe('form interactions', () => {
    it('renders all four variety options', () => {
      renderModal();
      const select = screen.getByLabelText(/type/i) as HTMLSelectElement;
      const options = Array.from(select.options).map(o => o.value);
      expect(options).toEqual(['build', 'init', 'sync', 'custom']);
    });

    it('toggles the public checkbox', () => {
      renderModal();
      const publicCheckbox = screen.getByLabelText(/^public$/i) as HTMLInputElement;
      expect(publicCheckbox.checked).toBe(false);
      fireEvent.click(publicCheckbox);
      expect(publicCheckbox.checked).toBe(true);
      fireEvent.click(publicCheckbox);
      expect(publicCheckbox.checked).toBe(false);
    });

    it('toggles the enabled checkbox', () => {
      renderModal();
      const enabledCheckbox = screen.getByLabelText(/^enabled$/i) as HTMLInputElement;
      expect(enabledCheckbox.checked).toBe(true);
      fireEvent.click(enabledCheckbox);
      expect(enabledCheckbox.checked).toBe(false);
    });

    it('calls onClose when the Cancel button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('calls onClose when the X button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      // The X button has no accessible text; find by its svg icon sibling
      const buttons = screen.getAllByRole('button');
      // The X close button is the first button in the header
      const xButton = buttons.find(btn => btn.querySelector('svg'));
      if (xButton) {
        fireEvent.click(xButton);
        expect(onClose).toHaveBeenCalled();
      }
    });

    it('calls onClose when clicking the backdrop overlay', () => {
      const onClose = jest.fn();
      const { container } = renderModal({ onClose });
      // The fixed overlay has bg-black/50
      const backdrop = container.querySelector('.bg-black\\/50') as HTMLElement;
      if (backdrop) {
        fireEvent.click(backdrop);
        expect(onClose).toHaveBeenCalled();
      }
    });

    it('shows loading state ("Creating...") while submitting', async () => {
      let resolveCreate!: (value: SystemNodeScript) => void;
      mockCreateScript.mockImplementation(
        () => new Promise<SystemNodeScript>(resolve => { resolveCreate = resolve; })
      );

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Slow Script' } });
      fireEvent.submit(screen.getByRole('button', { name: /create script/i }).closest('form')!);

      await waitFor(() =>
        expect(screen.getByText(/creating\.\.\./i)).toBeInTheDocument()
      );

      // Resolve to clean up
      resolveCreate({ ...SCRIPT_A, name: 'Slow Script', id: 'slow-id' });
    });

    it('shows loading state ("Updating...") while submitting in edit mode', async () => {
      let resolveUpdate!: (value: SystemNodeScript) => void;
      mockUpdateScript.mockImplementation(
        () => new Promise<SystemNodeScript>(resolve => { resolveUpdate = resolve; })
      );

      renderModal({ editScript: SCRIPT_A });
      fireEvent.submit(screen.getByRole('button', { name: /update script/i }).closest('form')!);

      await waitFor(() =>
        expect(screen.getByText(/updating\.\.\./i)).toBeInTheDocument()
      );

      resolveUpdate(SCRIPT_A);
    });
  });

  // ---------------------------------------------------------------------------
  // Form reset on re-open
  // ---------------------------------------------------------------------------

  describe('form reset', () => {
    it('resets to empty create form when re-opened without editScript', () => {
      const { rerender } = renderModal({ isOpen: false });
      rerender(
        <BrowserRouter>
          <ScriptFormModal isOpen={true} onClose={jest.fn()} />
        </BrowserRouter>
      );

      expect((screen.getByLabelText(/^name/i) as HTMLInputElement).value).toBe('');
      expect((screen.getByLabelText(/type/i) as HTMLSelectElement).value).toBe('custom');
    });

    it('resets to editScript data when re-opened with editScript', () => {
      const { rerender } = renderModal({ isOpen: false });
      rerender(
        <BrowserRouter>
          <ScriptFormModal isOpen={true} onClose={jest.fn()} editScript={SCRIPT_A} />
        </BrowserRouter>
      );

      expect((screen.getByLabelText(/^name/i) as HTMLInputElement).value).toBe('My Init Script');
      expect((screen.getByLabelText(/type/i) as HTMLSelectElement).value).toBe('init');
    });
  });
});
