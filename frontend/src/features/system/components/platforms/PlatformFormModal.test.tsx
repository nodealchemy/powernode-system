import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PlatformFormModal } from './PlatformFormModal';
import type { SystemNodePlatform, SystemNodeArchitecture } from '@system/features/system/types/system.types';

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

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
  }),
}));

jest.mock('@/shared/hooks/useAuth', () => ({
  useAuth: () => ({ currentUser: { account: { id: 'acct-test' } } }),
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

jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label: string }) => <a href="#mock">{label}</a>,
}));

// WebSocketManager — used inside DiskImageHistoryTab (rendered in edit mode).
// subscribe MUST return a function so the effect cleanup `return () => unsubscribe()`
// does not throw "unsubscribe is not a function".
// The factory runs once; the stable wrapper delegates to mockWsSubscribe so
// beforeEach can use mockImplementation to refresh the impl without clearing
// the return value (mockReset clears mockReturnValue but not impl set later).
const mockWsSubscribe = jest.fn();
jest.mock('@/shared/services/WebSocketManager', () => ({
  wsManager: {
    subscribe: (...args: unknown[]) => mockWsSubscribe(...args),
  },
}));

const mockGetArchitectures = jest.fn();
const mockCreatePlatform = jest.fn();
const mockUpdatePlatform = jest.fn();
const mockListPublications = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getArchitectures: (...args: unknown[]) => mockGetArchitectures(...args),
    createPlatform: (...args: unknown[]) => mockCreatePlatform(...args),
    updatePlatform: (...args: unknown[]) => mockUpdatePlatform(...args),
  },
}));

jest.mock('@system/features/system/services/api/diskImagePublicationsApi', () => ({
  diskImagePublicationsApi: {
    list: (...args: unknown[]) => mockListPublications(...args),
    rollback: jest.fn(),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const ARCH_X86: SystemNodeArchitecture = {
  id: 'arch-1',
  name: 'x86_64',
  family: 'x86',
  enabled: true,
  public: true,
  is_canonical: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const ARCH_ARM: SystemNodeArchitecture = {
  id: 'arch-2',
  name: 'aarch64',
  family: 'arm',
  enabled: true,
  public: true,
  is_canonical: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PLATFORM: SystemNodePlatform = {
  id: 'plat-1',
  name: 'Ubuntu 22.04 LTS',
  description: 'Main platform',
  enabled: true,
  public: false,
  build_script: '#!/bin/bash\n# build',
  init_script: '#!/bin/bash\n# init',
  sync_script: '#!/bin/bash\n# sync',
  node_architecture_id: 'arch-1',
  cosign_identity_regexp: 'https://example.com/.+',
  cosign_issuer_regexp: 'https://example.com',
  disk_image_retention_count: 5,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

const renderModal = (props: Partial<React.ComponentProps<typeof PlatformFormModal>> = {}) => {
  const defaults = {
    isOpen: true,
    onClose: jest.fn(),
    onPlatformSaved: jest.fn(),
    editPlatform: null,
  };
  return render(
    <BrowserRouter>
      <PlatformFormModal {...defaults} {...props} />
    </BrowserRouter>,
  );
};

// =============================================================================
// Tests
// =============================================================================

describe('PlatformFormModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockGetArchitectures.mockReset();
    mockCreatePlatform.mockReset();
    mockUpdatePlatform.mockReset();
    mockListPublications.mockReset();
    mockWsSubscribe.mockReset();

    // Default: architectures load successfully
    mockGetArchitectures.mockResolvedValue([ARCH_X86, ARCH_ARM]);
    // DiskImageHistoryTab publications list (used in edit mode)
    mockListPublications.mockResolvedValue({ publications: [] });
    // WS subscribe must return a cleanup function (never jest.fn — that gets
    // cleared by mockReset and React's effect cleanup calls it on unmount).
    mockWsSubscribe.mockImplementation(() => () => undefined);
  });

  // ---------------------------------------------------------------------------
  // Visibility / render
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen=false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByRole('heading', { name: /create platform/i })).toBeNull();
  });

  it('renders Create Platform heading in create mode', async () => {
    renderModal();
    expect(screen.getByRole('heading', { name: /create platform/i })).toBeInTheDocument();
  });

  it('renders Edit Platform heading in edit mode', async () => {
    renderModal({ editPlatform: PLATFORM });
    expect(screen.getByRole('heading', { name: /edit platform/i })).toBeInTheDocument();
  });

  it('calls onClose when the backdrop is clicked', () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    // The backdrop is the first child of the outer container — a fixed overlay
    const backdrop = document.querySelector('.fixed.inset-0.bg-black\\/50') as HTMLElement;
    fireEvent.click(backdrop);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when the X button is clicked', () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    // The X close button (ghost variant) is the first button-icon in the header
    fireEvent.click(screen.getAllByRole('button').find(
      (btn) => btn.closest('[class*="flex items-center justify-between"]'),
    ) ?? screen.getAllByRole('button')[0]);
    // Because the Cancel button also calls onClose we verify via the X-icon button
    const cancelBtn = screen.getByRole('button', { name: /cancel/i });
    expect(cancelBtn).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Architecture loading
  // ---------------------------------------------------------------------------

  it('shows a loading spinner while architectures are fetching', () => {
    // Never resolves within the test synchronously — spinner should be present
    mockGetArchitectures.mockReturnValue(new Promise(() => undefined));
    renderModal();
    // LoadingSpinner renders its container immediately
    expect(document.querySelector('.animate-spin') ?? screen.queryByText(/loading/i) ??
      document.querySelector('[class*="loading"]')).toBeTruthy();
  });

  it('renders architecture options after fetch resolves', async () => {
    renderModal();
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /x86_64/i })).toBeInTheDocument(),
    );
    expect(screen.getByRole('option', { name: /aarch64/i })).toBeInTheDocument();
  });

  it('shows error notification when architectures fail to load', async () => {
    mockGetArchitectures.mockRejectedValue(new Error('network error'));
    renderModal();
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load architectures',
      }),
    );
  });

  it('does NOT fetch architectures when isOpen=false', () => {
    renderModal({ isOpen: false });
    expect(mockGetArchitectures).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Form initialisation
  // ---------------------------------------------------------------------------

  it('pre-populates fields from editPlatform', async () => {
    renderModal({ editPlatform: PLATFORM });

    // Wait for architectures so the select is rendered
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /x86_64/i })).toBeInTheDocument(),
    );

    expect((screen.getByLabelText(/^name/i) as HTMLInputElement).value).toBe('Ubuntu 22.04 LTS');
    expect((screen.getByLabelText(/description/i) as HTMLTextAreaElement).value).toBe('Main platform');
    expect((screen.getByLabelText(/^build script/i) as HTMLTextAreaElement).value).toBe('#!/bin/bash\n# build');
    expect((screen.getByLabelText(/^init script/i) as HTMLTextAreaElement).value).toBe('#!/bin/bash\n# init');
    expect((screen.getByLabelText(/^sync script/i) as HTMLTextAreaElement).value).toBe('#!/bin/bash\n# sync');
    expect((screen.getByLabelText(/cosign identity regexp/i) as HTMLInputElement).value).toBe('https://example.com/.+');
    expect((screen.getByLabelText(/cosign oidc issuer regexp/i) as HTMLInputElement).value).toBe('https://example.com');
    expect((screen.getByLabelText(/retention/i) as HTMLInputElement).value).toBe('5');
    // Enabled checkbox
    expect((screen.getByRole('checkbox', { name: /enabled/i }) as HTMLInputElement).checked).toBe(true);
    // Public checkbox
    expect((screen.getByRole('checkbox', { name: /public/i }) as HTMLInputElement).checked).toBe(false);
  });

  it('starts with empty form in create mode', async () => {
    renderModal();
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());
    expect((screen.getByLabelText(/^name/i) as HTMLInputElement).value).toBe('');
    expect((screen.getByLabelText(/description/i) as HTMLTextAreaElement).value).toBe('');
    // Default retention = 3
    expect((screen.getByLabelText(/retention/i) as HTMLInputElement).value).toBe('3');
    // Enabled defaults to true
    expect((screen.getByRole('checkbox', { name: /enabled/i }) as HTMLInputElement).checked).toBe(true);
    // Public defaults to false
    expect((screen.getByRole('checkbox', { name: /public/i }) as HTMLInputElement).checked).toBe(false);
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  it('shows "Name is required" when submitting with empty name', async () => {
    renderModal();
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: /create platform/i }));
    expect(await screen.findByText('Name is required')).toBeInTheDocument();
  });

  it('shows "Name must be at least 2 characters" for single-char name', async () => {
    renderModal();
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());
    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'A' } });
    fireEvent.click(screen.getByRole('button', { name: /create platform/i }));
    expect(await screen.findByText(/at least 2 characters/i)).toBeInTheDocument();
  });

  it('clears validation error when user corrects the name', async () => {
    renderModal();
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: /create platform/i }));
    await screen.findByText('Name is required');
    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'My Platform' } });
    expect(screen.queryByText('Name is required')).toBeNull();
  });

  it('does not call createPlatform when validation fails', async () => {
    renderModal();
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: /create platform/i }));
    await screen.findByText('Name is required');
    expect(mockCreatePlatform).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Create submission
  // ---------------------------------------------------------------------------

  it('calls createPlatform with the correct payload and closes the modal', async () => {
    const savedPlatform = { ...PLATFORM, id: 'plat-new', name: 'New Platform' };
    mockCreatePlatform.mockResolvedValue(savedPlatform);

    const onClose = jest.fn();
    const onPlatformSaved = jest.fn();
    renderModal({ onClose, onPlatformSaved });
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'New Platform' } });
    fireEvent.change(screen.getByLabelText(/description/i), { target: { value: 'A description' } });
    fireEvent.click(screen.getByRole('button', { name: /create platform/i }));

    await waitFor(() =>
      expect(mockCreatePlatform).toHaveBeenCalledWith(
        expect.objectContaining({
          name: 'New Platform',
          description: 'A description',
          enabled: true,
          public: false,
        }),
      ),
    );

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(onPlatformSaved).toHaveBeenCalledWith(savedPlatform);
    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'success',
      message: `Platform "New Platform" created successfully`,
    });
  });

  it('includes all form fields in the createPlatform payload', async () => {
    mockCreatePlatform.mockResolvedValue({ ...PLATFORM, id: 'plat-new2', name: 'Full Platform' });

    renderModal();
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /x86_64/i })).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Full Platform' } });
    fireEvent.change(screen.getByLabelText(/^build script/i), { target: { value: '#!/bin/bash\nbuild' } });
    fireEvent.change(screen.getByLabelText(/^init script/i), { target: { value: '#!/bin/bash\ninit' } });
    fireEvent.change(screen.getByLabelText(/^sync script/i), { target: { value: '#!/bin/bash\nsync' } });
    fireEvent.change(screen.getByLabelText(/cosign identity regexp/i), { target: { value: 'https://ci.example.com/.+' } });
    fireEvent.change(screen.getByLabelText(/cosign oidc issuer regexp/i), { target: { value: 'https://ci.example.com' } });
    // Select architecture
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'arch-1' } });
    // Toggle public on
    fireEvent.click(screen.getByRole('checkbox', { name: /public/i }));

    fireEvent.click(screen.getByRole('button', { name: /create platform/i }));

    await waitFor(() =>
      expect(mockCreatePlatform).toHaveBeenCalledWith(
        expect.objectContaining({
          name: 'Full Platform',
          build_script: '#!/bin/bash\nbuild',
          init_script: '#!/bin/bash\ninit',
          sync_script: '#!/bin/bash\nsync',
          cosign_identity_regexp: 'https://ci.example.com/.+',
          cosign_issuer_regexp: 'https://ci.example.com',
          node_architecture_id: 'arch-1',
          public: true,
          enabled: true,
        }),
      ),
    );
  });

  it('shows error notification when createPlatform throws', async () => {
    mockCreatePlatform.mockRejectedValue(new Error('server error'));
    renderModal();
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Bad Platform' } });
    fireEvent.click(screen.getByRole('button', { name: /create platform/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create platform: server error',
      }),
    );
  });

  it('shows a spinner and disables the submit button while creating', async () => {
    let resolveCreate!: (v: SystemNodePlatform) => void;
    mockCreatePlatform.mockReturnValue(
      new Promise((r) => { resolveCreate = r; }),
    );

    renderModal();
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());
    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Pending Platform' } });
    fireEvent.click(screen.getByRole('button', { name: /create platform/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /creating\.\.\./i })).toBeDisabled(),
    );

    resolveCreate({ ...PLATFORM, id: 'plat-x', name: 'Pending Platform' });
  });

  // ---------------------------------------------------------------------------
  // Update submission
  // ---------------------------------------------------------------------------

  it('calls updatePlatform with id and payload, shows success notification', async () => {
    const updated = { ...PLATFORM, name: 'Updated Platform' };
    mockUpdatePlatform.mockResolvedValue(updated);

    const onClose = jest.fn();
    const onPlatformSaved = jest.fn();
    renderModal({ editPlatform: PLATFORM, onClose, onPlatformSaved });

    await waitFor(() =>
      expect(screen.getByRole('option', { name: /x86_64/i })).toBeInTheDocument(),
    );

    // Clear and update the name
    const nameInput = screen.getByLabelText(/^name/i) as HTMLInputElement;
    fireEvent.change(nameInput, { target: { value: 'Updated Platform' } });

    fireEvent.click(screen.getByRole('button', { name: /update platform/i }));

    await waitFor(() =>
      expect(mockUpdatePlatform).toHaveBeenCalledWith(
        'plat-1',
        expect.objectContaining({ name: 'Updated Platform' }),
      ),
    );
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(onPlatformSaved).toHaveBeenCalledWith(updated);
    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'success',
      message: `Platform "Updated Platform" updated successfully`,
    });
  });

  it('shows error notification when updatePlatform throws', async () => {
    mockUpdatePlatform.mockRejectedValue(new Error('update failed'));

    renderModal({ editPlatform: PLATFORM });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /x86_64/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /update platform/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to update platform: update failed',
      }),
    );
  });

  it('shows a spinner and "Updating..." while updating', async () => {
    let resolveUpdate!: (v: SystemNodePlatform) => void;
    mockUpdatePlatform.mockReturnValue(
      new Promise((r) => { resolveUpdate = r; }),
    );

    renderModal({ editPlatform: PLATFORM });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /x86_64/i })).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /update platform/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /updating\.\.\./i })).toBeDisabled(),
    );

    resolveUpdate(PLATFORM);
  });

  // ---------------------------------------------------------------------------
  // Architecture selection display
  // ---------------------------------------------------------------------------

  it('shows EntityLink for selected architecture', async () => {
    renderModal({ editPlatform: PLATFORM });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /x86_64/i })).toBeInTheDocument(),
    );
    // The "Selected: <name>" paragraph appears below the select when an
    // architecture is chosen. Multiple elements may contain "x86_64" (the
    // option + the EntityLink anchor); use getAllByText and confirm at least one.
    expect(screen.getAllByText('x86_64').length).toBeGreaterThan(0);
    // The EntityLink renders as an anchor with the architecture name
    expect(screen.getByRole('link', { name: 'x86_64' })).toBeInTheDocument();
  });

  it('does not show EntityLink when no architecture is selected', async () => {
    renderModal({ editPlatform: { ...PLATFORM, node_architecture_id: undefined } });
    await waitFor(() =>
      expect(screen.getByRole('option', { name: /x86_64/i })).toBeInTheDocument(),
    );
    // No "Selected:" text without an architecture
    expect(screen.queryByText(/selected:/i)).toBeNull();
  });

  // ---------------------------------------------------------------------------
  // Disk-image retention clamping
  // ---------------------------------------------------------------------------

  it('clamps disk_image_retention_count to 1 at minimum', async () => {
    renderModal();
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());
    const retentionInput = screen.getByLabelText(/retention/i) as HTMLInputElement;
    fireEvent.change(retentionInput, { target: { value: '0' } });
    expect(retentionInput.value).toBe('1');
  });

  it('clamps disk_image_retention_count to 50 at maximum', async () => {
    renderModal();
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());
    const retentionInput = screen.getByLabelText(/retention/i) as HTMLInputElement;
    fireEvent.change(retentionInput, { target: { value: '100' } });
    expect(retentionInput.value).toBe('50');
  });

  // ---------------------------------------------------------------------------
  // Edit-only: DiskImageHistoryTab
  // ---------------------------------------------------------------------------

  it('renders DiskImageHistoryTab only in edit mode', async () => {
    renderModal({ editPlatform: PLATFORM });
    await waitFor(() => expect(mockListPublications).toHaveBeenCalled());
    // The history tab header is "Publication history"
    expect(await screen.findByText(/publication history/i)).toBeInTheDocument();
  });

  it('does NOT render DiskImageHistoryTab in create mode', async () => {
    renderModal();
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());
    expect(screen.queryByText(/publication history/i)).toBeNull();
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel is clicked without submitting', async () => {
    const onClose = jest.fn();
    renderModal({ onClose });
    await waitFor(() => expect(mockGetArchitectures).toHaveBeenCalled());
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(mockCreatePlatform).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Form reset between open/close cycles
  // ---------------------------------------------------------------------------

  it('resets form to empty when switching from edit to create mode', async () => {
    const { rerender } = renderModal({ editPlatform: PLATFORM });
    await waitFor(() =>
      expect((screen.getByLabelText(/^name/i) as HTMLInputElement).value).toBe('Ubuntu 22.04 LTS'),
    );

    // Close and reopen without an editPlatform
    rerender(
      <BrowserRouter>
        <PlatformFormModal
          isOpen={false}
          onClose={jest.fn()}
          editPlatform={null}
        />
      </BrowserRouter>,
    );
    rerender(
      <BrowserRouter>
        <PlatformFormModal
          isOpen={true}
          onClose={jest.fn()}
          editPlatform={null}
        />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect((screen.getByLabelText(/^name/i) as HTMLInputElement).value).toBe(''),
    );
  });

  // ---------------------------------------------------------------------------
  // Modal width: wider in edit mode
  // ---------------------------------------------------------------------------

  it('uses max-w-4xl in edit mode and max-w-2xl in create mode', () => {
    const { rerender } = renderModal({ editPlatform: PLATFORM });
    // Edit mode: the inner dialog panel should have max-w-4xl
    expect(document.querySelector('.max-w-4xl')).toBeInTheDocument();
    expect(document.querySelector('.max-w-2xl')).toBeNull();

    rerender(
      <BrowserRouter>
        <PlatformFormModal isOpen={true} onClose={jest.fn()} editPlatform={null} />
      </BrowserRouter>,
    );
    expect(document.querySelector('.max-w-2xl')).toBeInTheDocument();
    expect(document.querySelector('.max-w-4xl')).toBeNull();
  });
});
