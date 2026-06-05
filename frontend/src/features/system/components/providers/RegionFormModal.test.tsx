import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { RegionFormModal } from './RegionFormModal';
import type { SystemProviderRegion } from '@system/features/system/types/system.types';

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

const mockCreateProviderRegion = jest.fn();
const mockUpdateProviderRegion = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    createProviderRegion: (...args: unknown[]) => mockCreateProviderRegion(...args),
    updateProviderRegion: (...args: unknown[]) => mockUpdateProviderRegion(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const EXISTING_REGION: SystemProviderRegion = {
  id: 'region-abc',
  name: 'US East',
  description: 'Primary east coast region',
  region_code: 'us-east-1',
  endpoint_url: 'https://api.us-east-1.example.com',
  capabilities: {},
  provider_id: 'prov-1',
  provider_name: 'AWS',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

interface RenderOptions {
  providerId?: string;
  region?: SystemProviderRegion | null;
  isOpen?: boolean;
  onClose?: jest.Mock;
  onRegionSaved?: jest.Mock;
}

function renderModal(opts: RenderOptions = {}) {
  const {
    providerId = 'prov-1',
    region = null,
    isOpen = true,
    onClose = jest.fn(),
    onRegionSaved = jest.fn(),
  } = opts;

  return render(
    <BrowserRouter>
      <RegionFormModal
        providerId={providerId}
        region={region}
        isOpen={isOpen}
        onClose={onClose}
        onRegionSaved={onRegionSaved}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('RegionFormModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockCreateProviderRegion.mockReset();
    mockUpdateProviderRegion.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Visibility
  // ---------------------------------------------------------------------------

  describe('visibility', () => {
    it('renders nothing when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(screen.queryByRole('heading', { name: /add region/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('heading', { name: /edit region/i })).not.toBeInTheDocument();
    });

    it('renders the modal when isOpen is true (create mode)', () => {
      renderModal({ isOpen: true });
      expect(screen.getByRole('heading', { name: /add region/i })).toBeInTheDocument();
    });

    it('renders the modal when isOpen is true (edit mode)', () => {
      renderModal({ isOpen: true, region: EXISTING_REGION });
      expect(screen.getByRole('heading', { name: /edit region/i })).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Create mode
  // ---------------------------------------------------------------------------

  describe('create mode (region = null)', () => {
    it('shows "Add Region" title', () => {
      renderModal();
      expect(screen.getByRole('heading', { name: /add region/i })).toBeInTheDocument();
    });

    it('shows "Add Region" submit button', () => {
      renderModal();
      expect(screen.getByRole('button', { name: /add region/i })).toBeInTheDocument();
    });

    it('initializes name field to empty', () => {
      renderModal();
      expect(screen.getByPlaceholderText('Enter region name')).toHaveValue('');
    });

    it('initializes region_code field to empty', () => {
      renderModal();
      expect(screen.getByPlaceholderText('e.g., us-east-1')).toHaveValue('');
    });

    it('initializes description field to empty', () => {
      renderModal();
      expect(screen.getByPlaceholderText('Optional description')).toHaveValue('');
    });

    it('initializes endpoint_url field to empty', () => {
      renderModal();
      expect(screen.getByPlaceholderText('https://api.region.example.com')).toHaveValue('');
    });

    it('shows required asterisk on Name field', () => {
      renderModal();
      const nameLabel = screen.getByText(/^Name/);
      expect(nameLabel).toBeInTheDocument();
    });

    it('shows required asterisk on Region Code field', () => {
      renderModal();
      expect(screen.getByText(/^Region Code/)).toBeInTheDocument();
    });

    it('shows Description label without required asterisk', () => {
      renderModal();
      expect(screen.getByText('Description')).toBeInTheDocument();
    });

    it('shows Endpoint URL label as optional', () => {
      renderModal();
      expect(screen.getByText('Endpoint URL')).toBeInTheDocument();
    });

    it('shows the endpoint URL helper text', () => {
      renderModal();
      expect(
        screen.getByText(/API endpoint for this region/i),
      ).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Edit mode
  // ---------------------------------------------------------------------------

  describe('edit mode (region provided)', () => {
    it('shows "Edit Region" title', () => {
      renderModal({ region: EXISTING_REGION });
      expect(screen.getByRole('heading', { name: /edit region/i })).toBeInTheDocument();
    });

    it('shows "Update Region" submit button', () => {
      renderModal({ region: EXISTING_REGION });
      expect(screen.getByRole('button', { name: /update region/i })).toBeInTheDocument();
    });

    it('pre-fills name from existing region', () => {
      renderModal({ region: EXISTING_REGION });
      expect(screen.getByPlaceholderText('Enter region name')).toHaveValue('US East');
    });

    it('pre-fills region_code from existing region', () => {
      renderModal({ region: EXISTING_REGION });
      expect(screen.getByPlaceholderText('e.g., us-east-1')).toHaveValue('us-east-1');
    });

    it('pre-fills description from existing region', () => {
      renderModal({ region: EXISTING_REGION });
      expect(screen.getByPlaceholderText('Optional description')).toHaveValue(
        'Primary east coast region',
      );
    });

    it('pre-fills endpoint_url from existing region', () => {
      renderModal({ region: EXISTING_REGION });
      expect(screen.getByPlaceholderText('https://api.region.example.com')).toHaveValue(
        'https://api.us-east-1.example.com',
      );
    });

    it('handles region with undefined optional fields gracefully', () => {
      const minimalRegion: SystemProviderRegion = {
        id: 'region-min',
        name: 'Minimal',
        region_code: 'eu-1',
        capabilities: {},
        provider_id: 'prov-1',
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      renderModal({ region: minimalRegion });
      expect(screen.getByPlaceholderText('Optional description')).toHaveValue('');
      expect(screen.getByPlaceholderText('https://api.region.example.com')).toHaveValue('');
    });
  });

  // ---------------------------------------------------------------------------
  // Form re-initialization
  // ---------------------------------------------------------------------------

  describe('form reinitialization', () => {
    it('resets form when modal reopens in create mode', () => {
      const { rerender } = render(
        <BrowserRouter>
          <RegionFormModal
            providerId="prov-1"
            region={null}
            isOpen={false}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      rerender(
        <BrowserRouter>
          <RegionFormModal
            providerId="prov-1"
            region={null}
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      expect(screen.getByPlaceholderText('Enter region name')).toHaveValue('');
      expect(screen.getByPlaceholderText('e.g., us-east-1')).toHaveValue('');
    });

    it('re-populates form when switching from create to edit mode', () => {
      const { rerender } = render(
        <BrowserRouter>
          <RegionFormModal
            providerId="prov-1"
            region={null}
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      expect(screen.getByPlaceholderText('Enter region name')).toHaveValue('');

      rerender(
        <BrowserRouter>
          <RegionFormModal
            providerId="prov-1"
            region={EXISTING_REGION}
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      expect(screen.getByPlaceholderText('Enter region name')).toHaveValue('US East');
    });
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  describe('validation', () => {
    it('shows "Name is required" error when name is empty', async () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /add region/i }));
      await waitFor(() =>
        expect(screen.getByText('Name is required')).toBeInTheDocument(),
      );
    });

    it('shows "Name must be at least 2 characters" when name has 1 char', async () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'A' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add region/i }));
      await waitFor(() =>
        expect(screen.getByText('Name must be at least 2 characters')).toBeInTheDocument(),
      );
    });

    it('shows "Region code is required" error when region_code is empty', async () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Valid Name' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add region/i }));
      await waitFor(() =>
        expect(screen.getByText('Region code is required')).toBeInTheDocument(),
      );
    });

    it('does NOT show name error when name is 2+ characters', async () => {
      mockCreateProviderRegion.mockResolvedValue({ ...EXISTING_REGION, id: 'new-1', name: 'OK' });
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'OK' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'us-1' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add region/i }));
      await waitFor(() =>
        expect(screen.queryByText('Name must be at least 2 characters')).not.toBeInTheDocument(),
      );
    });

    it('does not submit when name is whitespace-only', async () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: '   ' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'us-1' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add region/i }));
      await waitFor(() =>
        expect(screen.getByText('Name is required')).toBeInTheDocument(),
      );
      expect(mockCreateProviderRegion).not.toHaveBeenCalled();
    });

    it('does not submit when region_code is whitespace-only', async () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Valid Name' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: '   ' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add region/i }));
      await waitFor(() =>
        expect(screen.getByText('Region code is required')).toBeInTheDocument(),
      );
      expect(mockCreateProviderRegion).not.toHaveBeenCalled();
    });

    it('clears name error when user types a valid name', async () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /add region/i }));
      await waitFor(() =>
        expect(screen.getByText('Name is required')).toBeInTheDocument(),
      );
      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Fixed' },
      });
      await waitFor(() =>
        expect(screen.queryByText('Name is required')).not.toBeInTheDocument(),
      );
    });

    it('clears region_code error when user types a code', async () => {
      renderModal();
      // Trigger region_code error
      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Valid' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add region/i }));
      await waitFor(() =>
        expect(screen.getByText('Region code is required')).toBeInTheDocument(),
      );
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'eu-1' },
      });
      await waitFor(() =>
        expect(screen.queryByText('Region code is required')).not.toBeInTheDocument(),
      );
    });

    it('resets errors when modal re-opens', () => {
      const { rerender } = render(
        <BrowserRouter>
          <RegionFormModal
            providerId="prov-1"
            region={null}
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      // Trigger an error
      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      // Close and reopen
      rerender(
        <BrowserRouter>
          <RegionFormModal
            providerId="prov-1"
            region={null}
            isOpen={false}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );
      rerender(
        <BrowserRouter>
          <RegionFormModal
            providerId="prov-1"
            region={null}
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      expect(screen.queryByText('Name is required')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Create submission
  // ---------------------------------------------------------------------------

  describe('create submission', () => {
    it('calls systemApi.createProviderRegion with correct providerId and payload', async () => {
      mockCreateProviderRegion.mockResolvedValue({
        ...EXISTING_REGION,
        id: 'region-new',
        name: 'EU West',
      });

      renderModal({ providerId: 'prov-99' });

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'EU West' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'eu-west-1' },
      });
      fireEvent.change(screen.getByPlaceholderText('Optional description'), {
        target: { value: 'European region' },
      });
      fireEvent.change(screen.getByPlaceholderText('https://api.region.example.com'), {
        target: { value: 'https://api.eu-west-1.example.com' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() => expect(mockCreateProviderRegion).toHaveBeenCalledTimes(1));

      const [providerId, payload] = mockCreateProviderRegion.mock.calls[0] as [
        string,
        Record<string, unknown>,
      ];
      expect(providerId).toBe('prov-99');
      expect(payload.name).toBe('EU West');
      expect(payload.region_code).toBe('eu-west-1');
      expect(payload.description).toBe('European region');
      expect(payload.endpoint_url).toBe('https://api.eu-west-1.example.com');
      expect(payload.capabilities).toEqual({});
    });

    it('sends description as undefined when left empty', async () => {
      mockCreateProviderRegion.mockResolvedValue({
        ...EXISTING_REGION,
        id: 'region-new',
        name: 'No Desc',
      });

      renderModal({ providerId: 'prov-1' });

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'No Desc' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'ap-1' },
      });
      // Leave description and endpoint_url empty

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() => expect(mockCreateProviderRegion).toHaveBeenCalledTimes(1));
      const [, payload] = mockCreateProviderRegion.mock.calls[0] as [
        string,
        Record<string, unknown>,
      ];
      expect(payload.description).toBeUndefined();
      expect(payload.endpoint_url).toBeUndefined();
    });

    it('trims whitespace from name and region_code', async () => {
      mockCreateProviderRegion.mockResolvedValue({
        ...EXISTING_REGION,
        id: 'region-new',
        name: 'Trimmed',
      });

      renderModal({ providerId: 'prov-1' });

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: '  Trimmed  ' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: '  us-1  ' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() => expect(mockCreateProviderRegion).toHaveBeenCalledTimes(1));
      const [, payload] = mockCreateProviderRegion.mock.calls[0] as [
        string,
        Record<string, unknown>,
      ];
      expect(payload.name).toBe('Trimmed');
      expect(payload.region_code).toBe('us-1');
    });

    it('shows success notification with region name after create', async () => {
      mockCreateProviderRegion.mockResolvedValue({
        ...EXISTING_REGION,
        id: 'region-new',
        name: 'AP Southeast',
      });

      renderModal();

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'AP Southeast' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'ap-se-1' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('AP Southeast'),
          }),
        ),
      );
    });

    it('calls onRegionSaved and onClose after successful create', async () => {
      const onRegionSaved = jest.fn();
      const onClose = jest.fn();
      mockCreateProviderRegion.mockResolvedValue({
        ...EXISTING_REGION,
        id: 'region-new',
        name: 'Saved',
      });

      renderModal({ onRegionSaved, onClose });

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Saved' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'eu-1' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() => expect(onRegionSaved).toHaveBeenCalledTimes(1));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('does not call onRegionSaved when onRegionSaved is not provided', async () => {
      mockCreateProviderRegion.mockResolvedValue({
        ...EXISTING_REGION,
        id: 'region-new',
        name: 'No Callback',
      });

      // renderModal without onRegionSaved
      const onClose = jest.fn();
      render(
        <BrowserRouter>
          <RegionFormModal
            providerId="prov-1"
            region={null}
            isOpen={true}
            onClose={onClose}
          />
        </BrowserRouter>,
      );

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'No Callback' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'sa-1' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
      // No error thrown — component handles missing onRegionSaved gracefully
    });

    it('shows error notification when create fails', async () => {
      mockCreateProviderRegion.mockRejectedValue(new Error('Network failure'));

      renderModal();

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Fail Region' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'us-1' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: expect.stringContaining('Failed to create region'),
          }),
        ),
      );
    });

    it('includes error message from thrown Error in create failure notification', async () => {
      mockCreateProviderRegion.mockRejectedValue(new Error('Quota exceeded'));

      renderModal();

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Quota Fail' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'us-1' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: expect.stringContaining('Quota exceeded'),
          }),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Update submission
  // ---------------------------------------------------------------------------

  describe('update submission', () => {
    it('calls systemApi.updateProviderRegion with correct providerId, regionId, and payload', async () => {
      mockUpdateProviderRegion.mockResolvedValue({
        ...EXISTING_REGION,
        name: 'Renamed',
      });

      renderModal({ providerId: 'prov-1', region: EXISTING_REGION });

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Renamed' },
      });

      fireEvent.click(screen.getByRole('button', { name: /update region/i }));

      await waitFor(() => expect(mockUpdateProviderRegion).toHaveBeenCalledTimes(1));

      const [providerId, regionId, payload] = mockUpdateProviderRegion.mock.calls[0] as [
        string,
        string,
        Record<string, unknown>,
      ];
      expect(providerId).toBe('prov-1');
      expect(regionId).toBe('region-abc');
      expect(payload.name).toBe('Renamed');
      expect(payload.region_code).toBe('us-east-1');
      expect(payload.capabilities).toEqual({});
    });

    it('shows success notification with region name after update', async () => {
      mockUpdateProviderRegion.mockResolvedValue(EXISTING_REGION);

      renderModal({ region: EXISTING_REGION });

      fireEvent.click(screen.getByRole('button', { name: /update region/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('US East'),
          }),
        ),
      );
    });

    it('shows "updated successfully" in notification after update', async () => {
      mockUpdateProviderRegion.mockResolvedValue(EXISTING_REGION);

      renderModal({ region: EXISTING_REGION });

      fireEvent.click(screen.getByRole('button', { name: /update region/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('updated successfully'),
          }),
        ),
      );
    });

    it('calls onRegionSaved and onClose after successful update', async () => {
      const onRegionSaved = jest.fn();
      const onClose = jest.fn();
      mockUpdateProviderRegion.mockResolvedValue(EXISTING_REGION);

      renderModal({ region: EXISTING_REGION, onRegionSaved, onClose });

      fireEvent.click(screen.getByRole('button', { name: /update region/i }));

      await waitFor(() => expect(onRegionSaved).toHaveBeenCalledTimes(1));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('shows error notification when update fails', async () => {
      mockUpdateProviderRegion.mockRejectedValue(new Error('Server error'));

      renderModal({ region: EXISTING_REGION });

      fireEvent.click(screen.getByRole('button', { name: /update region/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: expect.stringContaining('Failed to update region'),
          }),
        ),
      );
    });

    it('includes error message in update failure notification', async () => {
      mockUpdateProviderRegion.mockRejectedValue(new Error('Conflict'));

      renderModal({ region: EXISTING_REGION });

      fireEvent.click(screen.getByRole('button', { name: /update region/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: expect.stringContaining('Conflict'),
          }),
        ),
      );
    });

    it('sends description as undefined when cleared in edit mode', async () => {
      mockUpdateProviderRegion.mockResolvedValue({
        ...EXISTING_REGION,
        description: undefined,
      });

      renderModal({ region: EXISTING_REGION });

      fireEvent.change(screen.getByPlaceholderText('Optional description'), {
        target: { value: '' },
      });

      fireEvent.click(screen.getByRole('button', { name: /update region/i }));

      await waitFor(() => expect(mockUpdateProviderRegion).toHaveBeenCalledTimes(1));
      const [, , payload] = mockUpdateProviderRegion.mock.calls[0] as [
        string,
        string,
        Record<string, unknown>,
      ];
      expect(payload.description).toBeUndefined();
    });
  });

  // ---------------------------------------------------------------------------
  // Close interactions
  // ---------------------------------------------------------------------------

  describe('close interactions', () => {
    it('calls onClose when the Cancel button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('calls onClose when the backdrop is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      const backdrop = document.querySelector('.fixed.inset-0.bg-black\\/50');
      if (backdrop) {
        fireEvent.click(backdrop);
        expect(onClose).toHaveBeenCalled();
      }
    });

    it('calls onClose when the X button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      // Find the ghost button that contains only the X icon (close button)
      const buttons = screen.getAllByRole('button');
      const xButton = buttons.find(
        (b) =>
          !b.textContent?.trim() ||
          b.getAttribute('type') !== 'submit',
      );
      if (xButton && xButton !== screen.getByRole('button', { name: /cancel/i })) {
        fireEvent.click(xButton);
      } else {
        // Fallback: click the backdrop
        const backdrop = document.querySelector('.fixed.inset-0.bg-black\\/50');
        if (backdrop) fireEvent.click(backdrop);
      }
      expect(onClose).toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Submitting state
  // ---------------------------------------------------------------------------

  describe('submitting state', () => {
    it('shows "Creating..." and disables fields while submitting in create mode', async () => {
      let resolveCreate!: (val: SystemProviderRegion) => void;
      mockCreateProviderRegion.mockReturnValue(
        new Promise<SystemProviderRegion>((res) => {
          resolveCreate = res;
        }),
      );

      renderModal();

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Pending' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'us-1' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() =>
        expect(screen.getByText('Creating...')).toBeInTheDocument(),
      );
      expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();

      // Clean up
      resolveCreate(EXISTING_REGION);
    });

    it('shows "Updating..." and disables fields while submitting in edit mode', async () => {
      let resolveUpdate!: (val: SystemProviderRegion) => void;
      mockUpdateProviderRegion.mockReturnValue(
        new Promise<SystemProviderRegion>((res) => {
          resolveUpdate = res;
        }),
      );

      renderModal({ region: EXISTING_REGION });

      fireEvent.click(screen.getByRole('button', { name: /update region/i }));

      await waitFor(() =>
        expect(screen.getByText('Updating...')).toBeInTheDocument(),
      );
      expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();

      // Clean up
      resolveUpdate(EXISTING_REGION);
    });

    it('re-enables the submit button after a failed create', async () => {
      mockCreateProviderRegion.mockRejectedValue(new Error('Network failure'));

      renderModal();

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Fail' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'us-1' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      // After failure, "Add Region" button should be re-enabled (not "Creating...")
      await waitFor(() =>
        expect(screen.getByRole('button', { name: /add region/i })).toBeInTheDocument(),
      );
      await waitFor(() =>
        expect(screen.queryByText('Creating...')).not.toBeInTheDocument(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Input disabling during submit
  // ---------------------------------------------------------------------------

  describe('inputs disabled while submitting', () => {
    it('disables name input while submitting', async () => {
      let resolveCreate!: (val: SystemProviderRegion) => void;
      mockCreateProviderRegion.mockReturnValue(
        new Promise<SystemProviderRegion>((res) => {
          resolveCreate = res;
        }),
      );

      renderModal();

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Test' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'us-1' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() =>
        expect(screen.getByPlaceholderText('Enter region name')).toBeDisabled(),
      );

      resolveCreate(EXISTING_REGION);
    });

    it('disables region_code input while submitting', async () => {
      let resolveCreate!: (val: SystemProviderRegion) => void;
      mockCreateProviderRegion.mockReturnValue(
        new Promise<SystemProviderRegion>((res) => {
          resolveCreate = res;
        }),
      );

      renderModal();

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Test' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'us-1' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() =>
        expect(screen.getByPlaceholderText('e.g., us-east-1')).toBeDisabled(),
      );

      resolveCreate(EXISTING_REGION);
    });
  });

  // ---------------------------------------------------------------------------
  // Payload construction edge cases
  // ---------------------------------------------------------------------------

  describe('payload construction', () => {
    it('always includes capabilities: {} in the create payload', async () => {
      mockCreateProviderRegion.mockResolvedValue({
        ...EXISTING_REGION,
        id: 'region-new',
      });

      renderModal({ providerId: 'prov-1' });

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'Caps Test' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'us-2' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() => expect(mockCreateProviderRegion).toHaveBeenCalledTimes(1));
      const [, payload] = mockCreateProviderRegion.mock.calls[0] as [
        string,
        Record<string, unknown>,
      ];
      expect(payload.capabilities).toEqual({});
    });

    it('always includes capabilities: {} in the update payload', async () => {
      mockUpdateProviderRegion.mockResolvedValue(EXISTING_REGION);

      renderModal({ region: EXISTING_REGION });

      fireEvent.click(screen.getByRole('button', { name: /update region/i }));

      await waitFor(() => expect(mockUpdateProviderRegion).toHaveBeenCalledTimes(1));
      const [, , payload] = mockUpdateProviderRegion.mock.calls[0] as [
        string,
        string,
        Record<string, unknown>,
      ];
      expect(payload.capabilities).toEqual({});
    });

    it('omits endpoint_url from payload when left empty in create mode', async () => {
      mockCreateProviderRegion.mockResolvedValue({
        ...EXISTING_REGION,
        id: 'region-new',
      });

      renderModal({ providerId: 'prov-1' });

      fireEvent.change(screen.getByPlaceholderText('Enter region name'), {
        target: { value: 'No URL' },
      });
      fireEvent.change(screen.getByPlaceholderText('e.g., us-east-1'), {
        target: { value: 'us-1' },
      });
      // Leave endpoint_url empty

      fireEvent.click(screen.getByRole('button', { name: /add region/i }));

      await waitFor(() => expect(mockCreateProviderRegion).toHaveBeenCalledTimes(1));
      const [, payload] = mockCreateProviderRegion.mock.calls[0] as [
        string,
        Record<string, unknown>,
      ];
      expect(payload.endpoint_url).toBeUndefined();
    });
  });
});
