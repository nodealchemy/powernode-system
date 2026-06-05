import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ArchitectureFormModal } from './ArchitectureFormModal';
import type { SystemNodeArchitecture } from '@system/features/system/types/system.types';

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

let mockHasPermission = jest.fn(() => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (...args: unknown[]) => mockHasPermission(...args),
  }),
}));

const mockCreateArchitecture = jest.fn();
const mockUpdateArchitecture = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    createArchitecture: (...args: unknown[]) => mockCreateArchitecture(...args),
    updateArchitecture: (...args: unknown[]) => mockUpdateArchitecture(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Double-envelope helper: apiClient resolves { data: { success, data: payload } }.
 *  systemApi facade unwraps via extractData, so the API mock returns the domain
 *  object directly (the facade returns it, not the raw axios shape). */
function architecture(overrides: Partial<SystemNodeArchitecture> = {}): SystemNodeArchitecture {
  return {
    id: 'arch-1',
    name: 'loongarch64',
    family: 'other',
    enabled: true,
    public: false,
    is_canonical: false,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}

const DEFAULT_PROPS = {
  isOpen: true,
  onClose: jest.fn(),
  onArchitectureSaved: jest.fn(),
};

function renderModal(props: Partial<typeof DEFAULT_PROPS & { editArchitecture?: SystemNodeArchitecture | null }> = {}) {
  return render(
    <BrowserRouter>
      <ArchitectureFormModal {...DEFAULT_PROPS} {...props} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('ArchitectureFormModal', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockHasPermission = jest.fn(() => true);
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  describe('render states', () => {
    it('returns null when isOpen is false', () => {
      const { container } = renderModal({ isOpen: false });
      expect(container.firstChild).toBeNull();
    });

    it('renders create mode with correct title and submit button', () => {
      renderModal();
      expect(screen.getByRole('heading', { name: /create architecture/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /create architecture/i })).toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /update architecture/i })).not.toBeInTheDocument();
    });

    it('renders edit mode title and update button for a non-canonical architecture', () => {
      renderModal({ editArchitecture: architecture() });
      expect(screen.getByRole('heading', { name: /edit architecture/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /update architecture/i })).toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /create architecture/i })).not.toBeInTheDocument();
    });

    it('renders "Architecture (canonical)" title for a canonical architecture', () => {
      renderModal({ editArchitecture: architecture({ is_canonical: true }) });
      expect(screen.getByRole('heading', { name: /architecture \(canonical\)/i })).toBeInTheDocument();
    });

    it('renders all form fields', () => {
      renderModal();
      expect(screen.getByLabelText(/^name/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/^family/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/display name/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/apt name/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/rpm name/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/description/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/kernel options/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/aliases/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/enabled/i)).toBeInTheDocument();
      expect(screen.getByLabelText(/public/i)).toBeInTheDocument();
    });

    it('shows all 7 family options in the select', () => {
      renderModal();
      const select = screen.getByLabelText(/^family/i) as HTMLSelectElement;
      const options = Array.from(select.options).map((o) => o.value);
      expect(options).toEqual(['x86', 'arm', 'power', 'z', 'risc-v', 'mips', 'other']);
    });
  });

  // ---------------------------------------------------------------------------
  // Edit mode: populate form from existing architecture
  // ---------------------------------------------------------------------------

  describe('edit mode population', () => {
    it('pre-populates fields from the editArchitecture prop', () => {
      const arch = architecture({
        name: 'riscv64gc',
        family: 'risc-v',
        apt_name: 'riscv64',
        rpm_name: 'riscv64gc',
        display_name: 'RISC-V 64-bit GC',
        description: 'Standard RV64GC profile',
        kernel_options: 'console=ttyS0',
        aliases: ['rv64gc', 'riscv64-gc'],
        enabled: false,
        public: true,
      });
      renderModal({ editArchitecture: arch });

      expect((screen.getByLabelText(/^name/i) as HTMLInputElement).value).toBe('riscv64gc');
      expect((screen.getByLabelText(/^family/i) as HTMLSelectElement).value).toBe('risc-v');
      expect((screen.getByLabelText(/apt name/i) as HTMLInputElement).value).toBe('riscv64');
      expect((screen.getByLabelText(/rpm name/i) as HTMLInputElement).value).toBe('riscv64gc');
      expect((screen.getByLabelText(/display name/i) as HTMLInputElement).value).toBe('RISC-V 64-bit GC');
      expect((screen.getByLabelText(/description/i) as HTMLTextAreaElement).value).toBe('Standard RV64GC profile');
      expect((screen.getByLabelText(/kernel options/i) as HTMLInputElement).value).toBe('console=ttyS0');
      // aliases rendered one per line
      expect((screen.getByLabelText(/aliases/i) as HTMLTextAreaElement).value).toBe('rv64gc\nriscv64-gc');
      expect((screen.getByLabelText(/enabled/i) as HTMLInputElement).checked).toBe(false);
      expect((screen.getByLabelText(/public/i) as HTMLInputElement).checked).toBe(true);
    });

    it('resets the form to empty when modal reopens without editArchitecture', () => {
      const { rerender } = renderModal({ editArchitecture: architecture({ name: 'prev' }) });
      rerender(
        <BrowserRouter>
          <ArchitectureFormModal {...DEFAULT_PROPS} editArchitecture={null} isOpen={false} />
        </BrowserRouter>,
      );
      rerender(
        <BrowserRouter>
          <ArchitectureFormModal {...DEFAULT_PROPS} editArchitecture={null} isOpen={true} />
        </BrowserRouter>,
      );
      expect((screen.getByLabelText(/^name/i) as HTMLInputElement).value).toBe('');
    });
  });

  // ---------------------------------------------------------------------------
  // Read-only: canonical architectures
  // ---------------------------------------------------------------------------

  describe('read-only mode — canonical architecture', () => {
    it('shows the canonical read-only banner', () => {
      renderModal({ editArchitecture: architecture({ is_canonical: true }) });
      expect(screen.getByText(/seeded canonical architecture/i)).toBeInTheDocument();
    });

    it('disables all form inputs', () => {
      renderModal({ editArchitecture: architecture({ is_canonical: true }) });
      expect(screen.getByLabelText(/^name/i)).toBeDisabled();
      expect(screen.getByLabelText(/^family/i)).toBeDisabled();
      expect(screen.getByLabelText(/enabled/i)).toBeDisabled();
      expect(screen.getByLabelText(/public/i)).toBeDisabled();
    });

    it('hides the submit button and shows "Close" instead of "Cancel"', () => {
      renderModal({ editArchitecture: architecture({ is_canonical: true }) });
      expect(screen.queryByRole('button', { name: /update architecture/i })).not.toBeInTheDocument();
      expect(screen.getByRole('button', { name: /close/i })).toBeInTheDocument();
    });

    it('does not call systemApi when form is submitted in canonical read-only mode', async () => {
      renderModal({ editArchitecture: architecture({ is_canonical: true }) });
      fireEvent.submit(screen.getByRole('button', { name: /close/i }).closest('form')!);
      await waitFor(() => expect(mockCreateArchitecture).not.toHaveBeenCalled());
      expect(mockUpdateArchitecture).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Read-only: insufficient permissions
  // ---------------------------------------------------------------------------

  describe('read-only mode — missing permission', () => {
    beforeEach(() => {
      mockHasPermission = jest.fn(() => false);
    });

    it('shows the permission-missing banner', () => {
      renderModal();
      expect(screen.getByText(/system\.architectures\.manage/i)).toBeInTheDocument();
    });

    it('disables all form inputs', () => {
      renderModal();
      expect(screen.getByLabelText(/^name/i)).toBeDisabled();
      expect(screen.getByLabelText(/^family/i)).toBeDisabled();
    });

    it('hides the submit button', () => {
      renderModal();
      expect(screen.queryByRole('button', { name: /create architecture/i })).not.toBeInTheDocument();
    });

    it('shows "Close" label instead of "Cancel"', () => {
      renderModal();
      expect(screen.getByRole('button', { name: /close/i })).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  describe('form validation', () => {
    it('shows "Name is required" error when name is empty', async () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));
      await waitFor(() =>
        expect(screen.getByText(/name is required/i)).toBeInTheDocument(),
      );
      expect(mockCreateArchitecture).not.toHaveBeenCalled();
    });

    it('shows "Name must be at least 2 characters" for a 1-char name', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'a' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));
      await waitFor(() =>
        expect(screen.getByText(/at least 2 characters/i)).toBeInTheDocument(),
      );
      expect(mockCreateArchitecture).not.toHaveBeenCalled();
    });

    it('clears the name error once the user starts typing', async () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));
      await waitFor(() => expect(screen.getByText(/name is required/i)).toBeInTheDocument());
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'x' } });
      await waitFor(() =>
        expect(screen.queryByText(/name is required/i)).not.toBeInTheDocument(),
      );
    });

    it('does not show a validation error for a valid 2-char name', async () => {
      mockCreateArchitecture.mockResolvedValueOnce(architecture({ name: 'ab' }));
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'ab' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));
      await waitFor(() => expect(mockCreateArchitecture).toHaveBeenCalled());
      expect(screen.queryByText(/at least 2 characters/i)).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Create — happy path
  // ---------------------------------------------------------------------------

  describe('create — happy path', () => {
    it('calls systemApi.createArchitecture with the correct payload', async () => {
      const created = architecture({ name: 'loongarch64', family: 'other' });
      mockCreateArchitecture.mockResolvedValueOnce(created);

      renderModal();

      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'loongarch64' } });
      fireEvent.change(screen.getByLabelText(/apt name/i), { target: { value: 'loong64' } });
      fireEvent.change(screen.getByLabelText(/rpm name/i), { target: { value: 'loongarch64' } });
      fireEvent.change(screen.getByLabelText(/display name/i), { target: { value: 'LoongArch 64' } });
      fireEvent.change(screen.getByLabelText(/description/i), { target: { value: 'Loongson arch' } });
      fireEvent.change(screen.getByLabelText(/kernel options/i), { target: { value: 'console=ttyS0' } });
      fireEvent.change(screen.getByLabelText(/aliases/i), { target: { value: 'loong64\nla64' } });

      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() => expect(mockCreateArchitecture).toHaveBeenCalledTimes(1));

      expect(mockCreateArchitecture).toHaveBeenCalledWith({
        name: 'loongarch64',
        family: 'other',
        apt_name: 'loong64',
        rpm_name: 'loongarch64',
        display_name: 'LoongArch 64',
        description: 'Loongson arch',
        kernel_options: 'console=ttyS0',
        aliases: ['loong64', 'la64'],
        enabled: true,
        public: false,
      });
    });

    it('shows a success notification on create', async () => {
      const created = architecture({ name: 'loongarch64' });
      mockCreateArchitecture.mockResolvedValueOnce(created);

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'loongarch64' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Architecture "loongarch64" created successfully`,
        }),
      );
    });

    it('calls onArchitectureSaved with the returned architecture', async () => {
      const created = architecture({ name: 'loongarch64' });
      mockCreateArchitecture.mockResolvedValueOnce(created);
      const onSaved = jest.fn();

      renderModal({ onArchitectureSaved: onSaved });
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'loongarch64' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() => expect(onSaved).toHaveBeenCalledWith(created));
    });

    it('calls onClose after successful create', async () => {
      const created = architecture({ name: 'loongarch64' });
      mockCreateArchitecture.mockResolvedValueOnce(created);
      const onClose = jest.fn();

      renderModal({ onClose });
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'loongarch64' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    });

    it('omits optional fields when blank (sends undefined)', async () => {
      mockCreateArchitecture.mockResolvedValueOnce(architecture({ name: 'myarch' }));

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'myarch' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() => expect(mockCreateArchitecture).toHaveBeenCalled());
      const payload = mockCreateArchitecture.mock.calls[0][0] as Record<string, unknown>;
      expect(payload.apt_name).toBeUndefined();
      expect(payload.rpm_name).toBeUndefined();
      expect(payload.display_name).toBeUndefined();
      expect(payload.description).toBeUndefined();
      expect(payload.kernel_options).toBeUndefined();
    });

    it('splits aliases by comma as well as newline', async () => {
      mockCreateArchitecture.mockResolvedValueOnce(architecture({ name: 'myarch' }));

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'myarch' } });
      fireEvent.change(screen.getByLabelText(/aliases/i), {
        target: { value: 'alpha,beta\ngamma' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() => expect(mockCreateArchitecture).toHaveBeenCalled());
      expect(mockCreateArchitecture.mock.calls[0][0].aliases).toEqual(['alpha', 'beta', 'gamma']);
    });

    it('sends empty aliases array when aliases textarea is blank', async () => {
      mockCreateArchitecture.mockResolvedValueOnce(architecture({ name: 'myarch' }));

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'myarch' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() => expect(mockCreateArchitecture).toHaveBeenCalled());
      expect(mockCreateArchitecture.mock.calls[0][0].aliases).toEqual([]);
    });

    it('shows a loading spinner and disables submit while creating', async () => {
      let resolveCreate!: (v: SystemNodeArchitecture) => void;
      mockCreateArchitecture.mockReturnValueOnce(
        new Promise<SystemNodeArchitecture>((res) => { resolveCreate = res; }),
      );

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'myarch' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /creating/i })).toBeDisabled(),
      );

      resolveCreate(architecture({ name: 'myarch' }));
      await waitFor(() =>
        expect(screen.queryByRole('button', { name: /creating/i })).not.toBeInTheDocument(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Update — happy path
  // ---------------------------------------------------------------------------

  describe('update — happy path', () => {
    it('calls systemApi.updateArchitecture with the architecture id and payload', async () => {
      const existing = architecture({ id: 'arch-42', name: 'mips32r2', family: 'mips' });
      const updated = { ...existing, name: 'mips32r2-updated' };
      mockUpdateArchitecture.mockResolvedValueOnce(updated);

      renderModal({ editArchitecture: existing });
      fireEvent.change(screen.getByLabelText(/^name/i), {
        target: { value: 'mips32r2-updated' },
      });
      fireEvent.click(screen.getByRole('button', { name: /update architecture/i }));

      await waitFor(() => expect(mockUpdateArchitecture).toHaveBeenCalledTimes(1));
      expect(mockUpdateArchitecture).toHaveBeenCalledWith(
        'arch-42',
        expect.objectContaining({ name: 'mips32r2-updated', family: 'mips' }),
      );
    });

    it('shows success notification on update', async () => {
      const existing = architecture({ id: 'arch-42', name: 'mips32r2', family: 'mips' });
      const updated = { ...existing, name: 'mips32r2' };
      mockUpdateArchitecture.mockResolvedValueOnce(updated);

      renderModal({ editArchitecture: existing });
      fireEvent.click(screen.getByRole('button', { name: /update architecture/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Architecture "mips32r2" updated successfully`,
        }),
      );
    });

    it('shows a loading "Updating..." label during update', async () => {
      const existing = architecture({ id: 'arch-42', name: 'mips32r2', family: 'mips' });
      let resolveUpdate!: (v: SystemNodeArchitecture) => void;
      mockUpdateArchitecture.mockReturnValueOnce(
        new Promise<SystemNodeArchitecture>((res) => { resolveUpdate = res; }),
      );

      renderModal({ editArchitecture: existing });
      fireEvent.click(screen.getByRole('button', { name: /update architecture/i }));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /updating/i })).toBeDisabled(),
      );

      resolveUpdate(existing);
      await waitFor(() =>
        expect(screen.queryByRole('button', { name: /updating/i })).not.toBeInTheDocument(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  describe('error handling', () => {
    it('shows an error notification when createArchitecture throws', async () => {
      mockCreateArchitecture.mockRejectedValueOnce(new Error('Server error'));

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'myarch' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to create architecture: Server error',
        }),
      );
      // Modal stays open on error
      expect(screen.getByRole('heading', { name: /create architecture/i })).toBeInTheDocument();
    });

    it('shows an error notification when updateArchitecture throws', async () => {
      const existing = architecture({ id: 'arch-42', name: 'mips32r2', family: 'mips' });
      mockUpdateArchitecture.mockRejectedValueOnce(new Error('Conflict'));

      renderModal({ editArchitecture: existing });
      fireEvent.click(screen.getByRole('button', { name: /update architecture/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to update architecture: Conflict',
        }),
      );
    });

    it('handles non-Error exceptions gracefully', async () => {
      mockCreateArchitecture.mockRejectedValueOnce('plain string error');

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'myarch' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to create architecture: An error occurred',
        }),
      );
    });

    it('re-enables submit button after a failed request', async () => {
      mockCreateArchitecture.mockRejectedValueOnce(new Error('oops'));

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'myarch' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /create architecture/i })).not.toBeDisabled(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Cancel / close
  // ---------------------------------------------------------------------------

  describe('cancel / close', () => {
    it('calls onClose when Cancel button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('calls onClose when the X button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      // X button has no text label — find by its parent ghost button
      const buttons = screen.getAllByRole('button');
      const xBtn = buttons.find((b) => b.querySelector('svg'));
      fireEvent.click(xBtn!);
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('calls onClose when the overlay backdrop is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      // The backdrop is a fixed div directly above the modal card
      const backdrop = document.querySelector('.fixed.inset-0.bg-black\\/50') as HTMLElement;
      fireEvent.click(backdrop);
      expect(onClose).toHaveBeenCalledTimes(1);
    });
  });

  // ---------------------------------------------------------------------------
  // Checkbox toggles
  // ---------------------------------------------------------------------------

  describe('checkbox toggles', () => {
    it('toggles the enabled checkbox', () => {
      renderModal();
      const enabledCb = screen.getByLabelText(/enabled/i) as HTMLInputElement;
      expect(enabledCb.checked).toBe(true); // EMPTY default is true
      fireEvent.click(enabledCb);
      expect(enabledCb.checked).toBe(false);
      fireEvent.click(enabledCb);
      expect(enabledCb.checked).toBe(true);
    });

    it('toggles the public checkbox', () => {
      renderModal();
      const publicCb = screen.getByLabelText(/public/i) as HTMLInputElement;
      expect(publicCb.checked).toBe(false); // EMPTY default is false
      fireEvent.click(publicCb);
      expect(publicCb.checked).toBe(true);
    });

    it('sends enabled=false and public=true when toggled before submit', async () => {
      mockCreateArchitecture.mockResolvedValueOnce(architecture({ name: 'testarch' }));

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'testarch' } });
      fireEvent.click(screen.getByLabelText(/enabled/i));
      fireEvent.click(screen.getByLabelText(/public/i));
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() => expect(mockCreateArchitecture).toHaveBeenCalled());
      const payload = mockCreateArchitecture.mock.calls[0][0] as Record<string, unknown>;
      expect(payload.enabled).toBe(false);
      expect(payload.public).toBe(true);
    });
  });

  // ---------------------------------------------------------------------------
  // Family select
  // ---------------------------------------------------------------------------

  describe('family select', () => {
    it('defaults to "other" in create mode', () => {
      renderModal();
      const select = screen.getByLabelText(/^family/i) as HTMLSelectElement;
      expect(select.value).toBe('other');
    });

    it('can be changed to arm and that value is sent in the payload', async () => {
      mockCreateArchitecture.mockResolvedValueOnce(architecture({ name: 'myarch', family: 'arm' }));

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'myarch' } });
      fireEvent.change(screen.getByLabelText(/^family/i), { target: { value: 'arm' } });
      fireEvent.click(screen.getByRole('button', { name: /create architecture/i }));

      await waitFor(() => expect(mockCreateArchitecture).toHaveBeenCalled());
      expect(mockCreateArchitecture.mock.calls[0][0].family).toBe('arm');
    });
  });
});
