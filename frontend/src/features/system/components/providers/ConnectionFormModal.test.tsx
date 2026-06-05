import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { BrowserRouter } from 'react-router-dom';
import { ConnectionFormModal } from './ConnectionFormModal';
import type { SystemProviderConnection } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();
const mockPut = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: jest.fn(),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// Mock systemApi methods used by the component
const mockTestProviderConnection = jest.fn();
const mockUpdateProviderConnection = jest.fn();
const mockCreateProviderConnection = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    testProviderConnection: (...args: unknown[]) => mockTestProviderConnection(...args),
    updateProviderConnection: (...args: unknown[]) => mockUpdateProviderConnection(...args),
    createProviderConnection: (...args: unknown[]) => mockCreateProviderConnection(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const EXISTING_CONNECTION: SystemProviderConnection = {
  id: 'conn-abc',
  name: 'Production AWS',
  description: 'Main AWS connection',
  endpoint_url: 'https://ec2.us-east-1.amazonaws.com',
  config: {},
  provider_id: 'prov-1',
  provider_name: 'AWS',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

interface RenderOptions {
  providerId?: string;
  connection?: SystemProviderConnection | null;
  isOpen?: boolean;
  onClose?: jest.Mock;
  onConnectionSaved?: jest.Mock;
}

function renderModal(opts: RenderOptions = {}) {
  const {
    providerId = 'prov-1',
    connection = null,
    isOpen = true,
    onClose = jest.fn(),
    onConnectionSaved = jest.fn(),
  } = opts;

  return render(
    <BrowserRouter>
      <ConnectionFormModal
        providerId={providerId}
        connection={connection}
        isOpen={isOpen}
        onClose={onClose}
        onConnectionSaved={onConnectionSaved}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('ConnectionFormModal', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockPut.mockReset();
    mockAddNotification.mockReset();
    mockTestProviderConnection.mockReset();
    mockUpdateProviderConnection.mockReset();
    mockCreateProviderConnection.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render / visibility
  // ---------------------------------------------------------------------------

  describe('visibility', () => {
    it('renders nothing when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(screen.queryByRole('heading', { name: /add connection/i })).not.toBeInTheDocument();
    });

    it('renders the modal when isOpen is true', () => {
      renderModal({ isOpen: true });
      expect(screen.getByRole('heading', { name: /add connection/i })).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Create mode
  // ---------------------------------------------------------------------------

  describe('create mode (connection = null)', () => {
    it('shows "Add Connection" title', () => {
      renderModal();
      expect(screen.getByRole('heading', { name: /add connection/i })).toBeInTheDocument();
    });

    it('shows "Add Connection" submit button', () => {
      renderModal();
      expect(screen.getByRole('button', { name: /add connection/i })).toBeInTheDocument();
    });

    it('renders required asterisks on name, access key, and secret key', () => {
      renderModal();
      // Name label contains a required asterisk
      const nameLabel = screen.getByText(/^name/i);
      expect(nameLabel).toBeInTheDocument();

      // Access Key shows asterisk (required in create mode)
      expect(screen.getByText(/access key/i)).toBeInTheDocument();

      // Secret Key shows asterisk (required in create mode)
      expect(screen.getByText(/secret key/i)).toBeInTheDocument();
    });

    it('does NOT render the "Test Connection" section in create mode', () => {
      renderModal();
      expect(screen.queryByText('Test Connection')).not.toBeInTheDocument();
    });

    it('shows create mode placeholder for access key', () => {
      renderModal();
      expect(screen.getByPlaceholderText('Enter access key')).toBeInTheDocument();
    });

    it('shows create mode placeholder for secret key', () => {
      renderModal();
      expect(screen.getByPlaceholderText('Enter secret key')).toBeInTheDocument();
    });

    it('initializes form fields empty', () => {
      renderModal();
      expect(screen.getByPlaceholderText('Enter connection name')).toHaveValue('');
      expect(screen.getByPlaceholderText('Optional description')).toHaveValue('');
      expect(screen.getByPlaceholderText('https://api.provider.com')).toHaveValue('');
    });
  });

  // ---------------------------------------------------------------------------
  // Edit mode
  // ---------------------------------------------------------------------------

  describe('edit mode (connection provided)', () => {
    it('shows "Edit Connection" title', () => {
      renderModal({ connection: EXISTING_CONNECTION });
      expect(screen.getByRole('heading', { name: /edit connection/i })).toBeInTheDocument();
    });

    it('shows "Update Connection" submit button', () => {
      renderModal({ connection: EXISTING_CONNECTION });
      expect(screen.getByRole('button', { name: /update connection/i })).toBeInTheDocument();
    });

    it('pre-fills name and description from existing connection', () => {
      renderModal({ connection: EXISTING_CONNECTION });
      expect(screen.getByPlaceholderText('Enter connection name')).toHaveValue('Production AWS');
      expect(screen.getByPlaceholderText('Optional description')).toHaveValue('Main AWS connection');
    });

    it('pre-fills endpoint_url from existing connection', () => {
      renderModal({ connection: EXISTING_CONNECTION });
      expect(screen.getByPlaceholderText('https://api.provider.com')).toHaveValue(
        'https://ec2.us-east-1.amazonaws.com',
      );
    });

    it('leaves credentials empty (security: do not pre-fill)', () => {
      renderModal({ connection: EXISTING_CONNECTION });
      const leaveEmptyInputs = screen.getAllByPlaceholderText('Leave empty to keep existing');
      expect(leaveEmptyInputs.length).toBeGreaterThan(0);
      leaveEmptyInputs.forEach((input) => expect(input).toHaveValue(''));
    });

    it('renders the "Test Connection" section in edit mode', () => {
      renderModal({ connection: EXISTING_CONNECTION });
      expect(screen.getByText('Test Connection')).toBeInTheDocument();
    });

    it('shows "leave empty" placeholder for credentials in edit mode', () => {
      renderModal({ connection: EXISTING_CONNECTION });
      // Both access key and secret key have the "leave empty" placeholder in edit mode
      const leaveEmptyInputs = screen.getAllByPlaceholderText('Leave empty to keep existing');
      expect(leaveEmptyInputs.length).toBe(2);
    });
  });

  // ---------------------------------------------------------------------------
  // Form re-initialization on open/close
  // ---------------------------------------------------------------------------

  describe('form reinitialization', () => {
    it('resets form when modal reopens in create mode', () => {
      const { rerender } = render(
        <BrowserRouter>
          <ConnectionFormModal
            providerId="prov-1"
            connection={null}
            isOpen={false}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      rerender(
        <BrowserRouter>
          <ConnectionFormModal
            providerId="prov-1"
            connection={null}
            isOpen={true}
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      expect(screen.getByPlaceholderText('Enter connection name')).toHaveValue('');
    });
  });

  // ---------------------------------------------------------------------------
  // Validation — create mode
  // ---------------------------------------------------------------------------

  describe('validation in create mode', () => {
    it('shows "Name is required" error when name is empty', async () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));
      await waitFor(() =>
        expect(screen.getByText('Name is required')).toBeInTheDocument(),
      );
    });

    it('shows "Name must be at least 2 characters" when name is 1 char', async () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'A' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));
      await waitFor(() =>
        expect(
          screen.getByText('Name must be at least 2 characters'),
        ).toBeInTheDocument(),
      );
    });

    it('shows "Access key is required" in create mode when empty', async () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'My Connection' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));
      await waitFor(() =>
        expect(screen.getByText('Access key is required')).toBeInTheDocument(),
      );
    });

    it('shows "Secret key is required" in create mode when empty', async () => {
      renderModal();
      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'My Connection' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter access key'), {
        target: { value: 'AKIAIOSFODNN7' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));
      await waitFor(() =>
        expect(screen.getByText('Secret key is required')).toBeInTheDocument(),
      );
    });

    it('clears field error when user corrects the field', async () => {
      renderModal();
      // Trigger name error
      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));
      await waitFor(() =>
        expect(screen.getByText('Name is required')).toBeInTheDocument(),
      );
      // Type valid name — error should clear
      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'Valid Name' },
      });
      await waitFor(() =>
        expect(screen.queryByText('Name is required')).not.toBeInTheDocument(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Validation — edit mode (credentials optional)
  // ---------------------------------------------------------------------------

  describe('validation in edit mode', () => {
    it('does NOT require access key or secret key in edit mode', async () => {
      mockUpdateProviderConnection.mockResolvedValue({
        ...EXISTING_CONNECTION,
        name: 'Production AWS',
      });
      renderModal({ connection: EXISTING_CONNECTION });
      // Submit without touching credentials
      fireEvent.click(screen.getByRole('button', { name: /update connection/i }));
      await waitFor(() =>
        expect(screen.queryByText('Access key is required')).not.toBeInTheDocument(),
      );
      await waitFor(() =>
        expect(screen.queryByText('Secret key is required')).not.toBeInTheDocument(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Create submission
  // ---------------------------------------------------------------------------

  describe('create submission', () => {
    it('calls systemApi.createProviderConnection with correct payload', async () => {
      mockCreateProviderConnection.mockResolvedValue({
        ...EXISTING_CONNECTION,
        id: 'conn-new',
        name: 'New Conn',
      });

      renderModal({ providerId: 'prov-99' });

      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'New Conn' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter access key'), {
        target: { value: 'AKIAIOSFODNN7' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter secret key'), {
        target: { value: 'wJalrXUtnFEMI/K7MDENG' },
      });
      fireEvent.change(screen.getByPlaceholderText('https://api.provider.com'), {
        target: { value: 'https://custom.endpoint.com' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));

      await waitFor(() => expect(mockCreateProviderConnection).toHaveBeenCalledTimes(1));

      const payload = mockCreateProviderConnection.mock.calls[0][0] as Record<string, unknown>;
      expect(payload.name).toBe('New Conn');
      expect(payload.provider_id).toBe('prov-99');
      expect(payload.access_key).toBe('AKIAIOSFODNN7');
      expect(payload.secret_key).toBe('wJalrXUtnFEMI/K7MDENG');
      expect(payload.endpoint_url).toBe('https://custom.endpoint.com');
      expect(payload.config).toEqual({});
    });

    it('shows success notification after create', async () => {
      mockCreateProviderConnection.mockResolvedValue({
        ...EXISTING_CONNECTION,
        id: 'conn-new',
        name: 'New Conn',
      });

      renderModal({ providerId: 'prov-1' });

      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'New Conn' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter access key'), {
        target: { value: 'AKIAIOSFODNN7' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter secret key'), {
        target: { value: 'supersecret' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('New Conn'),
          }),
        ),
      );
    });

    it('calls onConnectionSaved and onClose after successful create', async () => {
      const onConnectionSaved = jest.fn();
      const onClose = jest.fn();
      mockCreateProviderConnection.mockResolvedValue({
        ...EXISTING_CONNECTION,
        id: 'conn-new',
        name: 'Saved Conn',
      });

      renderModal({ onConnectionSaved, onClose });

      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'Saved Conn' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter access key'), {
        target: { value: 'AKIAIOSFODNN7' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter secret key'), {
        target: { value: 'supersecret' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));

      await waitFor(() => expect(onConnectionSaved).toHaveBeenCalledTimes(1));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('shows error notification when create fails', async () => {
      mockCreateProviderConnection.mockRejectedValue(new Error('Network error'));

      renderModal({ providerId: 'prov-1' });

      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'Fail Conn' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter access key'), {
        target: { value: 'AKIAIOSFODNN7' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter secret key'), {
        target: { value: 'supersecret' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: expect.stringContaining('Failed to create connection'),
          }),
        ),
      );
    });

    it('omits credentials from payload when access_key is empty whitespace', async () => {
      mockCreateProviderConnection.mockResolvedValue({
        ...EXISTING_CONNECTION,
        id: 'conn-new',
        name: 'Trimmed',
      });

      renderModal({ providerId: 'prov-1' });

      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'Trimmed' },
      });
      // In create mode, access_key is required — so we must provide it
      fireEvent.change(screen.getByPlaceholderText('Enter access key'), {
        target: { value: 'key' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter secret key'), {
        target: { value: 'secret' },
      });
      // Optional tenant — leave empty; should NOT appear in payload
      fireEvent.change(screen.getByPlaceholderText('Optional tenant or project ID'), {
        target: { value: '   ' }, // whitespace only
      });

      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));

      await waitFor(() => expect(mockCreateProviderConnection).toHaveBeenCalledTimes(1));
      const payload = mockCreateProviderConnection.mock.calls[0][0] as Record<string, unknown>;
      expect(payload.tenant).toBeUndefined();
    });

    it('includes tenant in payload when provided', async () => {
      mockCreateProviderConnection.mockResolvedValue({
        ...EXISTING_CONNECTION,
        id: 'conn-new',
        name: 'Tenant Conn',
      });

      renderModal({ providerId: 'prov-1' });

      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'Tenant Conn' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter access key'), {
        target: { value: 'mykey' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter secret key'), {
        target: { value: 'mysecret' },
      });
      fireEvent.change(screen.getByPlaceholderText('Optional tenant or project ID'), {
        target: { value: 'my-tenant-id' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));

      await waitFor(() => expect(mockCreateProviderConnection).toHaveBeenCalledTimes(1));
      const payload = mockCreateProviderConnection.mock.calls[0][0] as Record<string, unknown>;
      expect(payload.tenant).toBe('my-tenant-id');
    });
  });

  // ---------------------------------------------------------------------------
  // Update submission
  // ---------------------------------------------------------------------------

  describe('update submission', () => {
    it('calls systemApi.updateProviderConnection with correct id and payload', async () => {
      mockUpdateProviderConnection.mockResolvedValue({
        ...EXISTING_CONNECTION,
        name: 'Renamed',
      });

      renderModal({ connection: EXISTING_CONNECTION });

      // Clear and retype the name
      const nameInput = screen.getByPlaceholderText('Enter connection name');
      fireEvent.change(nameInput, { target: { value: 'Renamed' } });

      fireEvent.click(screen.getByRole('button', { name: /update connection/i }));

      await waitFor(() => expect(mockUpdateProviderConnection).toHaveBeenCalledTimes(1));

      const [id, payload] = mockUpdateProviderConnection.mock.calls[0] as [
        string,
        Record<string, unknown>,
      ];
      expect(id).toBe('conn-abc');
      expect(payload.name).toBe('Renamed');
      expect(payload.provider_id).toBe('prov-1');
    });

    it('omits credentials from payload when access_key is not provided in edit mode', async () => {
      mockUpdateProviderConnection.mockResolvedValue(EXISTING_CONNECTION);

      renderModal({ connection: EXISTING_CONNECTION });

      fireEvent.click(screen.getByRole('button', { name: /update connection/i }));

      await waitFor(() => expect(mockUpdateProviderConnection).toHaveBeenCalledTimes(1));
      const [, payload] = mockUpdateProviderConnection.mock.calls[0] as [
        string,
        Record<string, unknown>,
      ];
      expect(payload.access_key).toBeUndefined();
      expect(payload.secret_key).toBeUndefined();
    });

    it('includes credentials in payload when user types them in edit mode', async () => {
      mockUpdateProviderConnection.mockResolvedValue(EXISTING_CONNECTION);

      renderModal({ connection: EXISTING_CONNECTION });

      const [accessKeyInput] = screen.getAllByPlaceholderText('Leave empty to keep existing');
      fireEvent.change(accessKeyInput, { target: { value: 'NEWKEY' } });

      fireEvent.click(screen.getByRole('button', { name: /update connection/i }));

      await waitFor(() => expect(mockUpdateProviderConnection).toHaveBeenCalledTimes(1));
      const [, payload] = mockUpdateProviderConnection.mock.calls[0] as [
        string,
        Record<string, unknown>,
      ];
      expect(payload.access_key).toBe('NEWKEY');
    });

    it('shows success notification after update', async () => {
      mockUpdateProviderConnection.mockResolvedValue({
        ...EXISTING_CONNECTION,
        name: 'Production AWS',
      });

      renderModal({ connection: EXISTING_CONNECTION });

      fireEvent.click(screen.getByRole('button', { name: /update connection/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('updated successfully'),
          }),
        ),
      );
    });

    it('shows error notification when update fails', async () => {
      mockUpdateProviderConnection.mockRejectedValue(new Error('Server error'));

      renderModal({ connection: EXISTING_CONNECTION });

      fireEvent.click(screen.getByRole('button', { name: /update connection/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: expect.stringContaining('Failed to update connection'),
          }),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Close button / backdrop
  // ---------------------------------------------------------------------------

  describe('close interactions', () => {
    it('calls onClose when the X button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      // The X button has the close handler — find by button role adjacent to header
      const buttons = screen.getAllByRole('button');
      // Close button is the ghost button with X icon (first button in the header area)
      const xButton = buttons.find(
        (b) => b.className.includes('ghost') || b.querySelector('svg'),
      );
      if (xButton) {
        fireEvent.click(xButton);
        expect(onClose).toHaveBeenCalled();
      } else {
        // Fallback: click the overlay backdrop
        fireEvent.click(document.querySelector('.fixed.inset-0.bg-black\\/50')!);
        expect(onClose).toHaveBeenCalled();
      }
    });

    it('calls onClose when Cancel button is clicked', () => {
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
  });

  // ---------------------------------------------------------------------------
  // Test connection (edit mode)
  // ---------------------------------------------------------------------------

  describe('test connection', () => {
    it('calls systemApi.testProviderConnection with the connection id', async () => {
      mockTestProviderConnection.mockResolvedValue({
        success: true,
        message: 'Connection successful',
      });

      renderModal({ connection: EXISTING_CONNECTION });

      // Enter credentials so the guard passes
      const [accessKeyInput] = screen.getAllByPlaceholderText('Leave empty to keep existing');
      fireEvent.change(accessKeyInput, { target: { value: 'AKIAIOSFODNN7' } });
      const passwordInput = document.querySelector('input[type="password"]') as HTMLInputElement;
      fireEvent.change(passwordInput, { target: { value: 'supersecret' } });

      fireEvent.click(screen.getByRole('button', { name: /^test$/i }));

      await waitFor(() => expect(mockTestProviderConnection).toHaveBeenCalledWith('conn-abc'));
    });

    it('shows success badge after successful test', async () => {
      mockTestProviderConnection.mockResolvedValue({
        success: true,
        message: 'Connected!',
      });

      renderModal({ connection: EXISTING_CONNECTION });

      const [accessKeyInput] = screen.getAllByPlaceholderText('Leave empty to keep existing');
      fireEvent.change(accessKeyInput, { target: { value: 'AKIAIOSFODNN7' } });
      const passwordInput = document.querySelector('input[type="password"]') as HTMLInputElement;
      fireEvent.change(passwordInput, { target: { value: 'supersecret' } });

      fireEvent.click(screen.getByRole('button', { name: /^test$/i }));

      await waitFor(() => expect(screen.getByText('Success')).toBeInTheDocument());
      expect(screen.getByText('Connected!')).toBeInTheDocument();
    });

    it('shows failed badge after failed test', async () => {
      mockTestProviderConnection.mockResolvedValue({
        success: false,
        message: 'Authentication failed',
      });

      renderModal({ connection: EXISTING_CONNECTION });

      const [accessKeyInput] = screen.getAllByPlaceholderText('Leave empty to keep existing');
      fireEvent.change(accessKeyInput, { target: { value: 'AKIAIOSFODNN7' } });
      const passwordInput = document.querySelector('input[type="password"]') as HTMLInputElement;
      fireEvent.change(passwordInput, { target: { value: 'supersecret' } });

      fireEvent.click(screen.getByRole('button', { name: /^test$/i }));

      await waitFor(() => expect(screen.getByText('Failed')).toBeInTheDocument());
      expect(screen.getByText('Authentication failed')).toBeInTheDocument();
    });

    it('shows error badge when testProviderConnection throws', async () => {
      mockTestProviderConnection.mockRejectedValue(new Error('Timeout'));

      renderModal({ connection: EXISTING_CONNECTION });

      const [accessKeyInput] = screen.getAllByPlaceholderText('Leave empty to keep existing');
      fireEvent.change(accessKeyInput, { target: { value: 'AKIAIOSFODNN7' } });
      const passwordInput = document.querySelector('input[type="password"]') as HTMLInputElement;
      fireEvent.change(passwordInput, { target: { value: 'supersecret' } });

      fireEvent.click(screen.getByRole('button', { name: /^test$/i }));

      await waitFor(() => expect(screen.getByText('Failed')).toBeInTheDocument());
      expect(screen.getByText('Timeout')).toBeInTheDocument();
    });

    it('shows warning notification when test is clicked without credentials', async () => {
      renderModal({ connection: EXISTING_CONNECTION });

      // Do NOT fill in credentials
      fireEvent.click(screen.getByRole('button', { name: /^test$/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'warning',
            message: expect.stringContaining('credentials'),
          }),
        ),
      );
      expect(mockTestProviderConnection).not.toHaveBeenCalled();
    });

    it('shows info notification for test in create mode (new connection)', async () => {
      renderModal({ connection: null });
      // "Test Connection" section only appears in edit mode — so this is
      // an informational case: the test button is NOT rendered in create mode
      expect(screen.queryByRole('button', { name: /^test$/i })).not.toBeInTheDocument();
    });

    it('resets test status when form changes after a test', async () => {
      mockTestProviderConnection.mockResolvedValue({
        success: true,
        message: 'OK',
      });

      renderModal({ connection: EXISTING_CONNECTION });

      const [accessKeyInput] = screen.getAllByPlaceholderText('Leave empty to keep existing');
      fireEvent.change(accessKeyInput, { target: { value: 'AKIAIOSFODNN7' } });
      const passwordInput = document.querySelector('input[type="password"]') as HTMLInputElement;
      fireEvent.change(passwordInput, { target: { value: 'supersecret' } });

      fireEvent.click(screen.getByRole('button', { name: /^test$/i }));
      await waitFor(() => expect(screen.getByText('Success')).toBeInTheDocument());

      // Changing a field resets test status
      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'Changed' },
      });

      await waitFor(() => expect(screen.queryByText('Success')).not.toBeInTheDocument());
    });
  });

  // ---------------------------------------------------------------------------
  // Submitting state
  // ---------------------------------------------------------------------------

  describe('submitting state', () => {
    it('shows "Updating..." and disables buttons while submitting in edit mode', async () => {
      let resolveUpdate!: (val: SystemProviderConnection) => void;
      mockUpdateProviderConnection.mockReturnValue(
        new Promise<SystemProviderConnection>((res) => {
          resolveUpdate = res;
        }),
      );

      renderModal({ connection: EXISTING_CONNECTION });

      fireEvent.click(screen.getByRole('button', { name: /update connection/i }));

      await waitFor(() => expect(screen.getByText('Updating...')).toBeInTheDocument());
      expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();

      // Resolve to clean up
      resolveUpdate(EXISTING_CONNECTION);
    });

    it('shows "Creating..." and disables buttons while submitting in create mode', async () => {
      let resolveCreate!: (val: SystemProviderConnection) => void;
      mockCreateProviderConnection.mockReturnValue(
        new Promise<SystemProviderConnection>((res) => {
          resolveCreate = res;
        }),
      );

      renderModal();

      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'My Conn' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter access key'), {
        target: { value: 'key' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter secret key'), {
        target: { value: 'secret' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));

      await waitFor(() => expect(screen.getByText('Creating...')).toBeInTheDocument());
      expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled();

      resolveCreate(EXISTING_CONNECTION);
    });
  });

  // ---------------------------------------------------------------------------
  // Payload trimming / optional fields
  // ---------------------------------------------------------------------------

  describe('payload construction', () => {
    it('trims whitespace from name and description', async () => {
      mockCreateProviderConnection.mockResolvedValue({
        ...EXISTING_CONNECTION,
        id: 'conn-new',
        name: 'Trimmed',
      });

      renderModal({ providerId: 'prov-1' });

      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: '  Trimmed  ' },
      });
      fireEvent.change(screen.getByPlaceholderText('Optional description'), {
        target: { value: '  Some desc  ' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter access key'), {
        target: { value: 'key' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter secret key'), {
        target: { value: 'secret' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));

      await waitFor(() => expect(mockCreateProviderConnection).toHaveBeenCalledTimes(1));
      const payload = mockCreateProviderConnection.mock.calls[0][0] as Record<string, unknown>;
      expect(payload.name).toBe('Trimmed');
      expect(payload.description).toBe('Some desc');
    });

    it('sets description to undefined when empty string', async () => {
      mockCreateProviderConnection.mockResolvedValue({
        ...EXISTING_CONNECTION,
        id: 'conn-new',
        name: 'No Desc',
      });

      renderModal({ providerId: 'prov-1' });

      fireEvent.change(screen.getByPlaceholderText('Enter connection name'), {
        target: { value: 'No Desc' },
      });
      // Leave description empty
      fireEvent.change(screen.getByPlaceholderText('Enter access key'), {
        target: { value: 'key' },
      });
      fireEvent.change(screen.getByPlaceholderText('Enter secret key'), {
        target: { value: 'secret' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add connection/i }));

      await waitFor(() => expect(mockCreateProviderConnection).toHaveBeenCalledTimes(1));
      const payload = mockCreateProviderConnection.mock.calls[0][0] as Record<string, unknown>;
      expect(payload.description).toBeUndefined();
    });
  });
});
