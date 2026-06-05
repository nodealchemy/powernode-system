import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { VolumeFormModal } from './VolumeFormModal';
import type { SystemProviderVolume, SystemProviderRegion, SystemProvider } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGetProviders = jest.fn();
const mockGetProviderRegions = jest.fn();
const mockCreateVolume = jest.fn();
const mockUpdateVolume = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getProviders: (...args: unknown[]) => mockGetProviders(...args),
    getProviderRegions: (...args: unknown[]) => mockGetProviderRegions(...args),
    createVolume: (...args: unknown[]) => mockCreateVolume(...args),
    updateVolume: (...args: unknown[]) => mockUpdateVolume(...args),
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

const PROVIDER_A: SystemProvider = {
  id: 'prov-1',
  name: 'AWS Provider',
  provider_type: 'aws',
  enabled: true,
  public: false,
  config: {},
  capabilities: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const REGION_A: SystemProviderRegion = {
  id: 'region-1',
  name: 'US East',
  region_code: 'us-east-1',
  capabilities: {},
  provider_id: 'prov-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const REGION_B: SystemProviderRegion = {
  id: 'region-2',
  name: 'US West',
  region_code: 'us-west-2',
  capabilities: {},
  provider_id: 'prov-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const EXISTING_VOLUME: SystemProviderVolume = {
  id: 'vol-1',
  name: 'my-volume',
  description: 'Test volume description',
  size_gb: 200,
  status: 'available',
  volume_type: 'gp3',
  encrypted: true,
  iops: 3000,
  throughput: 125,
  config: {},
  provider_region_id: 'region-1',
  provider_region_name: 'US East',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const SAVED_VOLUME: SystemProviderVolume = {
  ...EXISTING_VOLUME,
  id: 'vol-new',
  name: 'new-volume',
};

// =============================================================================
// Helpers
// =============================================================================

function setupDefaultMocks() {
  mockGetProviders.mockResolvedValue([PROVIDER_A]);
  mockGetProviderRegions.mockResolvedValue([REGION_A, REGION_B]);
}

interface RenderProps {
  volume?: SystemProviderVolume | null;
  isOpen?: boolean;
  onClose?: () => void;
  onVolumeSaved?: (v: SystemProviderVolume) => void;
}

function renderModal({
  volume = null,
  isOpen = true,
  onClose = jest.fn(),
  onVolumeSaved = jest.fn(),
}: RenderProps = {}) {
  return render(
    <VolumeFormModal
      volume={volume}
      isOpen={isOpen}
      onClose={onClose}
      onVolumeSaved={onVolumeSaved}
    />
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('VolumeFormModal', () => {
  beforeEach(() => {
    mockGetProviders.mockReset();
    mockGetProviderRegions.mockReset();
    mockCreateVolume.mockReset();
    mockUpdateVolume.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Visibility
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    setupDefaultMocks();
    const { container } = renderModal({ isOpen: false });
    expect(container).toBeEmptyDOMElement();
  });

  it('renders the modal when isOpen is true', async () => {
    setupDefaultMocks();
    renderModal();
    expect(screen.getByRole('heading', { name: /create volume/i })).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Create mode
  // ---------------------------------------------------------------------------

  it('shows "Create Volume" header in create mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });
    expect(screen.getByRole('heading', { name: /create volume/i })).toBeInTheDocument();
  });

  it('shows "Edit Volume" header in edit mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: EXISTING_VOLUME });
    expect(screen.getByRole('heading', { name: /edit volume/i })).toBeInTheDocument();
  });

  it('initializes form with default values in create mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    await waitFor(() =>
      expect(mockGetProviders).toHaveBeenCalled()
    );

    const nameInput = screen.getByPlaceholderText('Enter volume name') as HTMLInputElement;
    expect(nameInput.value).toBe('');

    const sizeInput = screen.getByDisplayValue('100') as HTMLInputElement;
    expect(sizeInput).toBeInTheDocument();

    const encryptedCheckbox = screen.getByRole('checkbox') as HTMLInputElement;
    expect(encryptedCheckbox.checked).toBe(true);
  });

  it('initializes form with existing volume data in edit mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: EXISTING_VOLUME });

    await waitFor(() =>
      expect(mockGetProviders).toHaveBeenCalled()
    );

    const nameInput = screen.getByPlaceholderText('Enter volume name') as HTMLInputElement;
    expect(nameInput.value).toBe('my-volume');

    const sizeInput = screen.getByDisplayValue('200') as HTMLInputElement;
    expect(sizeInput).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Region loading
  // ---------------------------------------------------------------------------

  it('fetches providers and their regions when modal opens', async () => {
    setupDefaultMocks();
    renderModal();

    await waitFor(() =>
      expect(mockGetProviders).toHaveBeenCalledTimes(1)
    );
    await waitFor(() =>
      expect(mockGetProviderRegions).toHaveBeenCalledWith('prov-1')
    );
  });

  it('renders region options after loading', async () => {
    setupDefaultMocks();
    renderModal();

    await waitFor(() =>
      expect(screen.getByText('AWS Provider - US East (us-east-1)')).toBeInTheDocument()
    );
    expect(screen.getByText('AWS Provider - US West (us-west-2)')).toBeInTheDocument();
  });

  it('shows error notification when region fetch fails', async () => {
    mockGetProviders.mockRejectedValue(new Error('Network error'));
    renderModal();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load regions',
      })
    );
  });

  it('does not fetch regions when modal is closed', () => {
    renderModal({ isOpen: false });
    expect(mockGetProviders).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Conditional fields: IOPS and Throughput
  // ---------------------------------------------------------------------------

  it('shows IOPS and Throughput fields for gp3 volume type', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    // gp3 is the default — both IOPS and Throughput should be visible
    expect(screen.getByText(/iops \(optional\)/i)).toBeInTheDocument();
    expect(screen.getByText(/throughput \(mb\/s\)/i)).toBeInTheDocument();
  });

  it('hides IOPS and Throughput fields for gp2 volume type', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    const volumeTypeSelect = screen.getAllByRole('combobox').find((el) => {
      const options = Array.from((el as HTMLSelectElement).options);
      return options.some((o) => o.value === 'gp2');
    }) as HTMLSelectElement;

    fireEvent.change(volumeTypeSelect, { target: { value: 'gp2' } });

    await waitFor(() => {
      expect(screen.queryByText(/iops \(optional\)/i)).not.toBeInTheDocument();
      expect(screen.queryByText(/throughput \(mb\/s\)/i)).not.toBeInTheDocument();
    });
  });

  it('shows only IOPS field for io1 volume type', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    const volumeTypeSelect = screen.getAllByRole('combobox').find((el) => {
      const options = Array.from((el as HTMLSelectElement).options);
      return options.some((o) => o.value === 'io1');
    }) as HTMLSelectElement;

    fireEvent.change(volumeTypeSelect, { target: { value: 'io1' } });

    await waitFor(() => {
      expect(screen.getByText(/iops \(optional\)/i)).toBeInTheDocument();
      expect(screen.queryByText(/throughput \(mb\/s\)/i)).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Edit mode: locked fields
  // ---------------------------------------------------------------------------

  it('disables region select in edit mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: EXISTING_VOLUME });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    const regionSelect = screen.getByRole('combobox', {
      name: (name) => !name || name.toLowerCase().includes('region'),
    });
    // In edit mode the region select is disabled
    // We check disability by looking at its attributes in DOM
    const selects = screen.getAllByRole('combobox');
    // Region is the first select rendered after regions load
    const hasDisabledRegionSelect = selects.some(
      (s) => (s as HTMLSelectElement).disabled
    );
    expect(hasDisabledRegionSelect).toBe(true);
  });

  it('disables volume type select in edit mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: EXISTING_VOLUME });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
    const volumeTypeSelect = selects.find((s) =>
      Array.from(s.options).some((o) => o.value === 'io2')
    );
    expect(volumeTypeSelect?.disabled).toBe(true);
  });

  it('disables encrypted checkbox in edit mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: EXISTING_VOLUME });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    const checkbox = screen.getByRole('checkbox') as HTMLInputElement;
    expect(checkbox.disabled).toBe(true);
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  it('shows error when name is empty on submit', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    fireEvent.click(screen.getByRole('button', { name: /create volume/i }));

    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument()
    );
    expect(mockCreateVolume).not.toHaveBeenCalled();
  });

  it('shows error when name is too short (1 character)', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    fireEvent.change(
      screen.getByPlaceholderText('Enter volume name'),
      { target: { value: 'a' } }
    );
    fireEvent.click(screen.getByRole('button', { name: /create volume/i }));

    await waitFor(() =>
      expect(screen.getByText('Name must be at least 2 characters')).toBeInTheDocument()
    );
    expect(mockCreateVolume).not.toHaveBeenCalled();
  });

  it('shows error when region is not selected', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    fireEvent.change(
      screen.getByPlaceholderText('Enter volume name'),
      { target: { value: 'my-vol' } }
    );
    fireEvent.click(screen.getByRole('button', { name: /create volume/i }));

    await waitFor(() =>
      expect(screen.getByText('Region is required')).toBeInTheDocument()
    );
    expect(mockCreateVolume).not.toHaveBeenCalled();
  });

  it('shows error when size is 0', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    // Wait for regions to load before interacting with selects
    await waitFor(() => {
      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const hasRegionOption = selects.some((s) =>
        Array.from(s.options).some((o) => o.value === 'region-1')
      );
      expect(hasRegionOption).toBe(true);
    });

    const nameInput = screen.getByPlaceholderText('Enter volume name');
    const regionSelectEl = (screen.getAllByRole('combobox') as HTMLSelectElement[]).find((s) =>
      Array.from(s.options).some((o) => o.value === 'region-1')
    ) as HTMLSelectElement;
    const sizeInput = (screen.getAllByRole('spinbutton') as HTMLInputElement[]).find(
      (i) => i.getAttribute('min') === '1' && i.getAttribute('max') === '16384'
    ) as HTMLInputElement;

    fireEvent.change(nameInput, { target: { value: 'my-vol' } });
    fireEvent.change(regionSelectEl, { target: { value: 'region-1' } });
    fireEvent.change(sizeInput, { target: { value: '0' } });

    // Wait for React to process all the field changes
    await waitFor(() => {
      expect((sizeInput as HTMLInputElement).value).toBe('0');
    });

    fireEvent.submit(sizeInput.closest('form')!);

    await waitFor(() =>
      expect(screen.getByText('Size must be at least 1 GB')).toBeInTheDocument()
    );
    expect(mockCreateVolume).not.toHaveBeenCalled();
  });

  it('shows error when size exceeds 16384', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    // Wait for regions to load before interacting with selects
    await waitFor(() => {
      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const hasRegionOption = selects.some((s) =>
        Array.from(s.options).some((o) => o.value === 'region-1')
      );
      expect(hasRegionOption).toBe(true);
    });

    const nameInput = screen.getByPlaceholderText('Enter volume name');
    const regionSelectEl = (screen.getAllByRole('combobox') as HTMLSelectElement[]).find((s) =>
      Array.from(s.options).some((o) => o.value === 'region-1')
    ) as HTMLSelectElement;
    const sizeInput = (screen.getAllByRole('spinbutton') as HTMLInputElement[]).find(
      (i) => i.getAttribute('min') === '1' && i.getAttribute('max') === '16384'
    ) as HTMLInputElement;

    fireEvent.change(nameInput, { target: { value: 'my-vol' } });
    fireEvent.change(regionSelectEl, { target: { value: 'region-1' } });
    fireEvent.change(sizeInput, { target: { value: '16385' } });

    // Wait for React to process the field changes
    await waitFor(() => {
      expect((sizeInput as HTMLInputElement).value).toBe('16385');
    });

    fireEvent.submit(sizeInput.closest('form')!);

    await waitFor(() =>
      expect(screen.getByText('Size cannot exceed 16 TB')).toBeInTheDocument()
    );
    expect(mockCreateVolume).not.toHaveBeenCalled();
  });

  it('clears field error when the field is corrected', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    // Trigger name error
    fireEvent.click(screen.getByRole('button', { name: /create volume/i }));
    await waitFor(() =>
      expect(screen.getByText('Name is required')).toBeInTheDocument()
    );

    // Fix the name — error should clear
    fireEvent.change(
      screen.getByPlaceholderText('Enter volume name'),
      { target: { value: 'good-name' } }
    );
    await waitFor(() =>
      expect(screen.queryByText('Name is required')).not.toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Create submission
  // ---------------------------------------------------------------------------

  it('calls createVolume with correct payload and closes modal on success', async () => {
    setupDefaultMocks();
    mockCreateVolume.mockResolvedValue(SAVED_VOLUME);

    const onClose = jest.fn();
    const onVolumeSaved = jest.fn();
    renderModal({ volume: null, onClose, onVolumeSaved });

    await waitFor(() =>
      expect(screen.getByText('AWS Provider - US East (us-east-1)')).toBeInTheDocument()
    );

    // Fill name
    fireEvent.change(
      screen.getByPlaceholderText('Enter volume name'),
      { target: { value: 'new-volume' } }
    );

    // Fill description
    fireEvent.change(
      screen.getByPlaceholderText('Optional description'),
      { target: { value: 'A test volume' } }
    );

    // Select region
    const selects = screen.getAllByRole('combobox');
    const regionSelect = selects.find((s) =>
      Array.from((s as HTMLSelectElement).options).some((o) => o.value === 'region-1')
    ) as HTMLSelectElement;
    fireEvent.change(regionSelect, { target: { value: 'region-1' } });

    // Submit
    fireEvent.click(screen.getByRole('button', { name: /create volume/i }));

    await waitFor(() =>
      expect(mockCreateVolume).toHaveBeenCalledWith(
        expect.objectContaining({
          name: 'new-volume',
          description: 'A test volume',
          provider_region_id: 'region-1',
          volume_type: 'gp3',
          size_gb: 100,
          encrypted: true,
        })
      )
    );

    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'success',
      message: `Volume "${SAVED_VOLUME.name}" created successfully`,
    });

    expect(onVolumeSaved).toHaveBeenCalledWith(SAVED_VOLUME);
    expect(onClose).toHaveBeenCalled();
  });

  it('omits iops from payload when volume type does not support it', async () => {
    setupDefaultMocks();
    mockCreateVolume.mockResolvedValue(SAVED_VOLUME);

    renderModal({ volume: null });

    await waitFor(() =>
      expect(screen.getByText('AWS Provider - US East (us-east-1)')).toBeInTheDocument()
    );

    // Fill name
    fireEvent.change(
      screen.getByPlaceholderText('Enter volume name'),
      { target: { value: 'gp2-volume' } }
    );

    // Select region
    const selects = screen.getAllByRole('combobox');
    const regionSelect = selects.find((s) =>
      Array.from((s as HTMLSelectElement).options).some((o) => o.value === 'region-1')
    ) as HTMLSelectElement;
    fireEvent.change(regionSelect, { target: { value: 'region-1' } });

    // Switch to gp2 (no IOPS/throughput support)
    const volumeTypeSelect = selects.find((s) =>
      Array.from((s as HTMLSelectElement).options).some((o) => o.value === 'gp2')
    ) as HTMLSelectElement;
    fireEvent.change(volumeTypeSelect, { target: { value: 'gp2' } });

    fireEvent.click(screen.getByRole('button', { name: /create volume/i }));

    await waitFor(() =>
      expect(mockCreateVolume).toHaveBeenCalled()
    );

    const callArg = mockCreateVolume.mock.calls[0][0];
    expect(callArg.iops).toBeUndefined();
    expect(callArg.throughput).toBeUndefined();
  });

  it('includes iops in payload when gp3 volume type and iops is set', async () => {
    setupDefaultMocks();
    mockCreateVolume.mockResolvedValue(SAVED_VOLUME);

    renderModal({ volume: null });

    await waitFor(() =>
      expect(screen.getByText('AWS Provider - US East (us-east-1)')).toBeInTheDocument()
    );

    fireEvent.change(
      screen.getByPlaceholderText('Enter volume name'),
      { target: { value: 'gp3-vol' } }
    );

    const selects = screen.getAllByRole('combobox');
    const regionSelect = selects.find((s) =>
      Array.from((s as HTMLSelectElement).options).some((o) => o.value === 'region-1')
    ) as HTMLSelectElement;
    fireEvent.change(regionSelect, { target: { value: 'region-1' } });

    // Set IOPS (gp3 is the default)
    fireEvent.change(
      screen.getByPlaceholderText('e.g., 3000'),
      { target: { value: '5000' } }
    );

    fireEvent.click(screen.getByRole('button', { name: /create volume/i }));

    await waitFor(() =>
      expect(mockCreateVolume).toHaveBeenCalled()
    );

    const callArg = mockCreateVolume.mock.calls[0][0];
    expect(callArg.iops).toBe(5000);
  });

  it('shows error notification on create failure', async () => {
    setupDefaultMocks();
    mockCreateVolume.mockRejectedValue(new Error('Server error'));

    const onClose = jest.fn();
    renderModal({ volume: null, onClose });

    await waitFor(() =>
      expect(screen.getByText('AWS Provider - US East (us-east-1)')).toBeInTheDocument()
    );

    fireEvent.change(
      screen.getByPlaceholderText('Enter volume name'),
      { target: { value: 'fail-vol' } }
    );

    const selects = screen.getAllByRole('combobox');
    const regionSelect = selects.find((s) =>
      Array.from((s as HTMLSelectElement).options).some((o) => o.value === 'region-1')
    ) as HTMLSelectElement;
    fireEvent.change(regionSelect, { target: { value: 'region-1' } });

    fireEvent.click(screen.getByRole('button', { name: /create volume/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create volume: Server error',
      })
    );
    expect(onClose).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Update submission
  // ---------------------------------------------------------------------------

  it('calls updateVolume with correct id and payload on edit mode submit', async () => {
    setupDefaultMocks();
    const updatedVolume = { ...EXISTING_VOLUME, name: 'updated-volume' };
    mockUpdateVolume.mockResolvedValue(updatedVolume);

    const onClose = jest.fn();
    const onVolumeSaved = jest.fn();
    renderModal({ volume: EXISTING_VOLUME, onClose, onVolumeSaved });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    // Change the name
    const nameInput = screen.getByPlaceholderText('Enter volume name');
    fireEvent.change(nameInput, { target: { value: 'updated-volume' } });

    // Submit
    fireEvent.click(screen.getByRole('button', { name: /update volume/i }));

    await waitFor(() =>
      expect(mockUpdateVolume).toHaveBeenCalledWith(
        'vol-1',
        expect.objectContaining({
          name: 'updated-volume',
          provider_region_id: 'region-1',
          volume_type: 'gp3',
          size_gb: 200,
          encrypted: true,
        })
      )
    );

    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'success',
      message: `Volume "${updatedVolume.name}" updated successfully`,
    });

    expect(onVolumeSaved).toHaveBeenCalledWith(updatedVolume);
    expect(onClose).toHaveBeenCalled();
  });

  it('shows error notification on update failure', async () => {
    setupDefaultMocks();
    mockUpdateVolume.mockRejectedValue(new Error('Conflict'));

    const onClose = jest.fn();
    renderModal({ volume: EXISTING_VOLUME, onClose });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    fireEvent.click(screen.getByRole('button', { name: /update volume/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to update volume: Conflict',
      })
    );
    expect(onClose).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Submit button state
  // ---------------------------------------------------------------------------

  it('shows "Create Volume" on submit button in create mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });
    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    expect(
      screen.getByRole('button', { name: /create volume/i })
    ).toBeInTheDocument();
  });

  it('shows "Update Volume" on submit button in edit mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: EXISTING_VOLUME });
    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    expect(
      screen.getByRole('button', { name: /update volume/i })
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Close / Cancel behavior
  // ---------------------------------------------------------------------------

  it('calls onClose when the backdrop is clicked', async () => {
    setupDefaultMocks();
    const onClose = jest.fn();
    const { container } = renderModal({ onClose });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    // The backdrop is the fixed inset-0 bg-black div
    const backdrop = container.querySelector('.bg-black\\/50') as HTMLElement;
    fireEvent.click(backdrop);
    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose when Cancel button is clicked', async () => {
    setupDefaultMocks();
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose when the X close button is clicked', async () => {
    setupDefaultMocks();
    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    // The header X button is the first ghost button in the header
    const closeButtons = screen.getAllByRole('button');
    const xButton = closeButtons.find((b) => b.textContent === '');
    // Click the icon close button (it has only an SVG icon, no text)
    fireEvent.click(closeButtons[0]);
    expect(onClose).toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Encryption defaults
  // ---------------------------------------------------------------------------

  it('has encryption enabled by default in create mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    const checkbox = screen.getByRole('checkbox') as HTMLInputElement;
    expect(checkbox.checked).toBe(true);
  });

  it('allows toggling encryption in create mode', async () => {
    setupDefaultMocks();
    renderModal({ volume: null });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    const checkbox = screen.getByRole('checkbox') as HTMLInputElement;
    expect(checkbox.checked).toBe(true);

    fireEvent.click(checkbox);
    expect(checkbox.checked).toBe(false);
  });

  // ---------------------------------------------------------------------------
  // Re-initialization when volume prop changes
  // ---------------------------------------------------------------------------

  it('resets form to defaults when modal opens again in create mode after edit mode', async () => {
    setupDefaultMocks();
    const { rerender } = renderModal({ volume: EXISTING_VOLUME });

    await waitFor(() => expect(mockGetProviders).toHaveBeenCalled());

    // Now reopen in create mode
    rerender(
      <VolumeFormModal
        volume={null}
        isOpen={false}
        onClose={jest.fn()}
        onVolumeSaved={jest.fn()}
      />
    );
    rerender(
      <VolumeFormModal
        volume={null}
        isOpen={true}
        onClose={jest.fn()}
        onVolumeSaved={jest.fn()}
      />
    );

    await waitFor(() => {
      const nameInput = screen.getByPlaceholderText('Enter volume name') as HTMLInputElement;
      expect(nameInput.value).toBe('');
    });
  });
});
