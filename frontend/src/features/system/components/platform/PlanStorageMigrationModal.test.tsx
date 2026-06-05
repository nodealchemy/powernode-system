import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PlanStorageMigrationModal } from './PlanStorageMigrationModal';
import type { SystemProviderVolume } from '../../types/system.types';
import type { StorageMigrationSummary } from '../../types/storageMigration.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => true,
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
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

// =============================================================================
// Fixtures
// =============================================================================

const VOL_A: SystemProviderVolume = {
  id: 'vol-aaa',
  name: 'primary-disk',
  size_gb: 100,
  status: 'available',
  volume_type: 'ssd',
  encrypted: false,
  config: {},
  provider_region_id: 'region-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const VOL_B: SystemProviderVolume = {
  id: 'vol-bbb',
  name: 'backup-disk',
  size_gb: 200,
  status: 'available',
  volume_type: 'ssd',
  encrypted: true,
  config: {},
  provider_region_id: 'region-1',
  created_at: '2026-01-02T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const MIGRATION_RESULT: StorageMigrationSummary = {
  id: 'mig-123',
  status: 'planned',
  role: 'postgres',
  node_instance_id: 'inst-xyz',
  source_volume_id: 'vol-aaa',
  target_volume_id: 'vol-bbb',
  source_subpath: null,
  target_subpath: null,
  bytes_copied: null,
  bytes_total: null,
  terminal: false,
  error_message: null,
  created_at: '2026-01-01T00:00:00Z',
  approved_at: null,
  started_at: null,
  completed_at: null,
  failed_at: null,
  cancelled_at: null,
};

// Double-envelope: AxiosResponse whose body is { success: true, data: <payload>, meta? }
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// volumesApi.getVolumes uses extractPaginated — returns { volumes, meta } from body.data
function volumesEnvelope(volumes: SystemProviderVolume[]) {
  return {
    data: {
      success: true,
      data: { volumes },
      meta: {
        current_page: 1,
        per_page: 200,
        total_count: volumes.length,
        total_pages: 1,
        next_page: null,
        prev_page: null,
      },
    },
  };
}

// storageMigrationsApi.create uses extractData — returns body.data.storage_migration
function migrationEnvelope(migration: StorageMigrationSummary) {
  return envelope({ storage_migration: migration });
}

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  onClose?: () => void;
  onPlanned?: (m: StorageMigrationSummary) => void;
  defaultInstanceId?: string;
  defaultRole?: string;
}

const renderModal = (props: RenderProps = {}) => {
  const {
    isOpen = true,
    onClose = jest.fn(),
    onPlanned,
    defaultInstanceId,
    defaultRole,
  } = props;

  return render(
    <BrowserRouter>
      <PlanStorageMigrationModal
        isOpen={isOpen}
        onClose={onClose}
        onPlanned={onPlanned}
        defaultInstanceId={defaultInstanceId}
        defaultRole={defaultRole}
      />
    </BrowserRouter>,
  );
};

// =============================================================================
// Tests
// =============================================================================

describe('PlanStorageMigrationModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render & closed state
  // ---------------------------------------------------------------------------

  it('does not render when isOpen is false', () => {
    mockGet.mockResolvedValue(volumesEnvelope([]));
    renderModal({ isOpen: false });
    expect(screen.queryByText('Plan Storage Migration')).not.toBeInTheDocument();
  });

  it('renders the modal title and informational banner when open', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([]));
    renderModal();
    await waitFor(() => expect(screen.getByText('Plan Storage Migration')).toBeInTheDocument());
    expect(
      screen.getByText(/Move a stateful component/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Volume loading
  // ---------------------------------------------------------------------------

  it('fetches volumes from the correct endpoint with page_size=200 on open', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    renderModal();
    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/provider_volumes', {
        params: { page_size: 200 },
      }),
    );
  });

  it('shows "Loading…" while volumes are being fetched', () => {
    // Never resolve — stays in loading state
    mockGet.mockReturnValue(new Promise(() => undefined));
    renderModal();
    // Both source and target selects show loading placeholder
    expect(screen.getAllByText('Loading…').length).toBeGreaterThanOrEqual(1);
  });

  it('populates source and target volume selects with loaded volumes', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    renderModal();
    // Both selects transition from "Loading…" to "Select a volume…" then render options
    await waitFor(() => {
      expect(screen.getAllByText('Select a volume…').length).toBeGreaterThanOrEqual(1);
    });
    // VOL_A appears in at least the source select
    expect(screen.getAllByText(`${VOL_A.name} (${VOL_A.size_gb} GB · ${VOL_A.status})`).length).toBeGreaterThan(0);
    // VOL_B appears in at least one select
    expect(screen.getAllByText(`${VOL_B.name} (${VOL_B.size_gb} GB · ${VOL_B.status})`).length).toBeGreaterThan(0);
  });

  it('shows an inline error when volume loading fails', async () => {
    mockGet.mockRejectedValue(new Error('Network timeout'));
    renderModal();
    await waitFor(() =>
      expect(screen.getByText('Network timeout')).toBeInTheDocument(),
    );
  });

  it('shows a generic error message when the volume error is not an Error instance', async () => {
    mockGet.mockRejectedValue('string error');
    renderModal();
    await waitFor(() =>
      expect(screen.getByText('Failed to load volumes')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Default prop pre-filling
  // ---------------------------------------------------------------------------

  it('pre-fills instanceId and role from defaultInstanceId and defaultRole props', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([]));
    renderModal({ defaultInstanceId: 'inst-xyz', defaultRole: 'postgres' });
    await waitFor(() => expect(mockGet).toHaveBeenCalled());

    const instanceInput = screen.getByPlaceholderText(/UUID of the instance/i);
    const roleInput = screen.getByPlaceholderText(/postgres, redis/i);
    expect((instanceInput as HTMLInputElement).value).toBe('inst-xyz');
    expect((roleInput as HTMLInputElement).value).toBe('postgres');
  });

  it('resets state and re-fetches volumes when isOpen transitions from false to true', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A]));
    const { rerender } = renderModal({ isOpen: false });

    // No fetch while closed
    expect(mockGet).not.toHaveBeenCalled();

    rerender(
      <BrowserRouter>
        <PlanStorageMigrationModal
          isOpen={true}
          onClose={jest.fn()}
        />
      </BrowserRouter>,
    );

    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));
  });

  // ---------------------------------------------------------------------------
  // Form interactions
  // ---------------------------------------------------------------------------

  it('allows typing into the Node Instance ID field', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([]));
    renderModal();
    await waitFor(() => expect(mockGet).toHaveBeenCalled());

    const input = screen.getByPlaceholderText(/UUID of the instance/i);
    fireEvent.change(input, { target: { value: 'new-instance-id' } });
    expect((input as HTMLInputElement).value).toBe('new-instance-id');
  });

  it('allows typing into the Role field', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([]));
    renderModal();
    await waitFor(() => expect(mockGet).toHaveBeenCalled());

    const input = screen.getByPlaceholderText(/postgres, redis/i);
    fireEvent.change(input, { target: { value: 'redis' } });
    expect((input as HTMLInputElement).value).toBe('redis');
  });

  // ---------------------------------------------------------------------------
  // Submit button disabled states (canSubmit logic)
  // ---------------------------------------------------------------------------

  it('disables the Plan Migration button when fields are empty', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    renderModal();
    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));

    const btn = screen.getByRole('button', { name: /Plan Migration/i });
    expect(btn).toBeDisabled();
  });

  it('disables Plan Migration button when state has same volume for source and target', async () => {
    // The target VolumeSelect excludes the source via `excludeId`, so we drive
    // the equal-state by setting target first, then changing source to match it.
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    renderModal({ defaultInstanceId: 'inst-xyz', defaultRole: 'postgres' });
    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));

    const selects = screen.getAllByRole('combobox');
    // Set target to VOL_B first, then source to VOL_B → sourceId === targetId
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });
    fireEvent.change(selects[0], { target: { value: 'vol-bbb' } });

    const btn = screen.getByRole('button', { name: /Plan Migration/i });
    expect(btn).toBeDisabled();
  });

  it('shows a "Source and target must differ" warning when state has same volume for both', async () => {
    // The target VolumeSelect excludes the currently-selected source via `excludeId`,
    // so normal UI interaction cannot result in both selects having the same volume.
    // The warning is displayed based on React state (sourceId === targetId && sourceId !== ''),
    // which can occur if source is changed to match an already-selected target.
    // We verify the component's conditional rendering by checking: when source is NOT set
    // but target IS set, then changing source to match target triggers the warning.
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    renderModal({ defaultInstanceId: 'inst-xyz', defaultRole: 'postgres' });
    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));

    const selects = screen.getAllByRole('combobox');
    // Pick VOL_B for the target first (source is still empty, so it's not excluded)
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });
    // Now pick VOL_B for the source — state becomes sourceId === targetId
    fireEvent.change(selects[0], { target: { value: 'vol-bbb' } });

    await waitFor(() =>
      expect(screen.getByText('Source and target must differ.')).toBeInTheDocument(),
    );
  });

  it('does NOT show the "must differ" warning when volumes are empty strings (initial state)', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    renderModal();
    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));
    expect(screen.queryByText('Source and target must differ.')).not.toBeInTheDocument();
  });

  it('enables Plan Migration button when all required fields are filled with different volumes', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    renderModal({ defaultInstanceId: 'inst-xyz', defaultRole: 'postgres' });
    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));

    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    const btn = screen.getByRole('button', { name: /Plan Migration/i });
    expect(btn).not.toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Target volume excludes selected source
  // ---------------------------------------------------------------------------

  it('excludes the selected source volume from the target volume dropdown', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    renderModal();
    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));

    const selects = screen.getAllByRole('combobox');
    // Select VOL_A as source
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });

    // Target select (second select) should not contain VOL_A
    const targetSelect = selects[1];
    const targetOptions = Array.from(targetSelect.querySelectorAll('option')).map(
      (o) => (o as HTMLOptionElement).value,
    );
    expect(targetOptions).not.toContain('vol-aaa');
    expect(targetOptions).toContain('vol-bbb');
  });

  // ---------------------------------------------------------------------------
  // Successful form submission
  // ---------------------------------------------------------------------------

  it('calls storageMigrationsApi.create with correct payload on submit', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    mockPost.mockResolvedValue(migrationEnvelope(MIGRATION_RESULT));

    const onClose = jest.fn();
    const onPlanned = jest.fn();

    renderModal({
      defaultInstanceId: 'inst-xyz',
      defaultRole: 'postgres',
      onClose,
      onPlanned,
    });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));

    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/platform/storage_migrations', {
        node_instance_id: 'inst-xyz',
        source_volume_id: 'vol-aaa',
        target_volume_id: 'vol-bbb',
        role: 'postgres',
      }),
    );
  });

  it('calls onPlanned with the returned migration summary after successful submit', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    mockPost.mockResolvedValue(migrationEnvelope(MIGRATION_RESULT));

    const onPlanned = jest.fn();
    const onClose = jest.fn();

    renderModal({
      defaultInstanceId: 'inst-xyz',
      defaultRole: 'postgres',
      onClose,
      onPlanned,
    });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));
    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));

    await waitFor(() => expect(onPlanned).toHaveBeenCalledWith(MIGRATION_RESULT));
    expect(onClose).toHaveBeenCalled();
  });

  it('shows a success notification with the role name after planned', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    mockPost.mockResolvedValue(migrationEnvelope(MIGRATION_RESULT));

    renderModal({
      defaultInstanceId: 'inst-xyz',
      defaultRole: 'postgres',
      onClose: jest.fn(),
    });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));
    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: "Storage migration planned for 'postgres'.",
      }),
    );
  });

  it('trims whitespace from instanceId and role before submitting', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    mockPost.mockResolvedValue(migrationEnvelope(MIGRATION_RESULT));

    renderModal({ onClose: jest.fn() });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));

    fireEvent.change(screen.getByPlaceholderText(/UUID of the instance/i), {
      target: { value: '  inst-xyz  ' },
    });
    fireEvent.change(screen.getByPlaceholderText(/postgres, redis/i), {
      target: { value: '  postgres  ' },
    });

    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/platform/storage_migrations', {
        node_instance_id: 'inst-xyz',
        source_volume_id: 'vol-aaa',
        target_volume_id: 'vol-bbb',
        role: 'postgres',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Submission loading state
  // ---------------------------------------------------------------------------

  it('shows "Planning…" on the submit button while the request is in flight', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    let resolvePost!: (v: unknown) => void;
    mockPost.mockReturnValue(new Promise((res) => { resolvePost = res; }));

    renderModal({
      defaultInstanceId: 'inst-xyz',
      defaultRole: 'postgres',
      onClose: jest.fn(),
    });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));
    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /Planning…/i })).toBeInTheDocument(),
    );

    // Resolve to avoid act() warnings
    resolvePost(migrationEnvelope(MIGRATION_RESULT));
  });

  it('disables inputs during submission', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    let resolvePost!: (v: unknown) => void;
    mockPost.mockReturnValue(new Promise((res) => { resolvePost = res; }));

    renderModal({
      defaultInstanceId: 'inst-xyz',
      defaultRole: 'postgres',
      onClose: jest.fn(),
    });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));
    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));

    await waitFor(() => screen.getByRole('button', { name: /Planning…/i }));

    expect(screen.getByPlaceholderText(/UUID of the instance/i)).toBeDisabled();
    expect(screen.getByPlaceholderText(/postgres, redis/i)).toBeDisabled();

    resolvePost(migrationEnvelope(MIGRATION_RESULT));
  });

  // ---------------------------------------------------------------------------
  // Error handling on submit
  // ---------------------------------------------------------------------------

  it('shows an error notification when the create request fails with an Error', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    mockPost.mockRejectedValue(new Error('Server rejected the plan'));

    renderModal({
      defaultInstanceId: 'inst-xyz',
      defaultRole: 'postgres',
      onClose: jest.fn(),
    });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));
    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Server rejected the plan',
      }),
    );
  });

  it('shows a generic error notification when the create request fails with a non-Error', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    mockPost.mockRejectedValue('opaque failure');

    renderModal({
      defaultInstanceId: 'inst-xyz',
      defaultRole: 'postgres',
      onClose: jest.fn(),
    });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));
    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Plan failed',
      }),
    );
  });

  it('does NOT call onClose after a failed submission', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    mockPost.mockRejectedValue(new Error('fail'));

    const onClose = jest.fn();

    renderModal({
      defaultInstanceId: 'inst-xyz',
      defaultRole: 'postgres',
      onClose,
    });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));
    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));

    await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
    expect(onClose).not.toHaveBeenCalled();
  });

  it('re-enables the Plan Migration button after a failed submission', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    mockPost.mockRejectedValue(new Error('fail'));

    renderModal({
      defaultInstanceId: 'inst-xyz',
      defaultRole: 'postgres',
      onClose: jest.fn(),
    });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));
    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /Plan Migration/i })).not.toBeDisabled(),
    );
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel is clicked', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([]));
    const onClose = jest.fn();
    renderModal({ onClose });
    await waitFor(() => expect(mockGet).toHaveBeenCalled());

    fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('disables Cancel button while submitting', async () => {
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A, VOL_B]));
    let resolvePost!: (v: unknown) => void;
    mockPost.mockReturnValue(new Promise((res) => { resolvePost = res; }));

    renderModal({
      defaultInstanceId: 'inst-xyz',
      defaultRole: 'postgres',
      onClose: jest.fn(),
    });

    await waitFor(() => expect(screen.getAllByText('Select a volume…').length).toBeGreaterThan(0));
    const selects = screen.getAllByRole('combobox');
    fireEvent.change(selects[0], { target: { value: 'vol-aaa' } });
    fireEvent.change(selects[1], { target: { value: 'vol-bbb' } });

    fireEvent.click(screen.getByRole('button', { name: /Plan Migration/i }));
    await waitFor(() => screen.getByRole('button', { name: /Planning…/i }));

    expect(screen.getByRole('button', { name: /Cancel/i })).toBeDisabled();

    resolvePost(migrationEnvelope(MIGRATION_RESULT));
  });

  // ---------------------------------------------------------------------------
  // State reset on reopen
  // ---------------------------------------------------------------------------

  it('resets error state and field values when modal is reopened with new defaults', async () => {
    mockGet.mockResolvedValueOnce(volumesEnvelope([]));
    // First open — force a load error
    mockGet.mockRejectedValueOnce(new Error('timeout'));

    const { rerender } = renderModal({ defaultInstanceId: 'old-inst', defaultRole: 'old-role' });
    // Wait for first open
    await waitFor(() => expect(mockGet).toHaveBeenCalledTimes(1));

    // Reopen with different defaults — should reset error and values
    mockGet.mockResolvedValue(volumesEnvelope([VOL_A]));

    rerender(
      <BrowserRouter>
        <PlanStorageMigrationModal
          isOpen={false}
          onClose={jest.fn()}
          defaultInstanceId="new-inst"
          defaultRole="new-role"
        />
      </BrowserRouter>,
    );
    rerender(
      <BrowserRouter>
        <PlanStorageMigrationModal
          isOpen={true}
          onClose={jest.fn()}
          defaultInstanceId="new-inst"
          defaultRole="new-role"
        />
      </BrowserRouter>,
    );

    await waitFor(() => {
      const instanceInput = screen.getByPlaceholderText(/UUID of the instance/i);
      expect((instanceInput as HTMLInputElement).value).toBe('new-inst');
    });
    const roleInput = screen.getByPlaceholderText(/postgres, redis/i);
    expect((roleInput as HTMLInputElement).value).toBe('new-role');
  });
});
