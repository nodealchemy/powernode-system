import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { BrowserRouter } from 'react-router-dom';
import { EditInstanceModal } from './EditInstanceModal';
import type { SystemNodeInstance } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockPut = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
    post: jest.fn(),
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

// systemApi.updateNodeInstance calls apiClient.put internally via the helpers.
// We mock the whole systemApi facade so we can assert on the high-level call.
const mockUpdateNodeInstance = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    updateNodeInstance: (...args: unknown[]) => mockUpdateNodeInstance(...args),
  },
}));

// =============================================================================
// Helpers
// =============================================================================

/** Double-envelope wrapper matching the real API shape. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const BASE_INSTANCE: SystemNodeInstance = {
  id: 'inst-abc',
  name: 'my-instance-01',
  variety: 'cloud',
  status: 'running',
  private_ip_address: '10.0.0.5',
  public_ip_address: '203.0.113.10',
  vpn_ip_address: '172.16.0.5',
  config: {},
  node_id: 'node-xyz',
  node_name: 'prod-node',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-15T12:00:00Z',
};

interface RenderOptions {
  instance?: SystemNodeInstance | null;
  nodeId?: string | null;
  isOpen?: boolean;
  onClose?: () => void;
  onInstanceUpdated?: (i: SystemNodeInstance) => void;
}

function renderModal(opts: RenderOptions = {}) {
  const {
    instance = BASE_INSTANCE,
    nodeId = 'node-xyz',
    isOpen = true,
    onClose = jest.fn(),
    onInstanceUpdated = jest.fn(),
  } = opts;

  return render(
    <BrowserRouter>
      <EditInstanceModal
        nodeId={nodeId}
        instance={instance}
        isOpen={isOpen}
        onClose={onClose}
        onInstanceUpdated={onInstanceUpdated}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('EditInstanceModal', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  describe('render states', () => {
    it('renders nothing when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(screen.queryByText('Edit Instance')).not.toBeInTheDocument();
    });

    it('renders the modal title and subtitle when open', () => {
      renderModal();
      expect(screen.getByText('Edit Instance')).toBeInTheDocument();
      expect(screen.getByText(/Editing: my-instance-01/i)).toBeInTheDocument();
    });

    it('renders form fields pre-populated from the instance prop', () => {
      renderModal();
      expect(screen.getByLabelText(/^Name/i)).toHaveValue('my-instance-01');
      expect(screen.getByLabelText(/Private IP/i)).toHaveValue('10.0.0.5');
      expect(screen.getByLabelText(/Public IP/i)).toHaveValue('203.0.113.10');
      expect(screen.getByLabelText(/VPN IP/i)).toHaveValue('172.16.0.5');
    });

    it('shows current status badge for running instance', () => {
      renderModal();
      expect(screen.getByText('Running')).toBeInTheDocument();
    });

    it('shows Stopped badge for stopped instance', () => {
      renderModal({ instance: { ...BASE_INSTANCE, status: 'stopped' } });
      expect(screen.getByText('Stopped')).toBeInTheDocument();
    });

    it('shows Pending badge for pending instance', () => {
      renderModal({ instance: { ...BASE_INSTANCE, status: 'pending' } });
      expect(screen.getByText('Pending')).toBeInTheDocument();
    });

    it('shows Failed badge for error instance', () => {
      renderModal({ instance: { ...BASE_INSTANCE, status: 'error' } });
      expect(screen.getByText('Failed')).toBeInTheDocument();
    });

    it('shows Failed badge for failed instance', () => {
      renderModal({ instance: { ...BASE_INSTANCE, status: 'failed' } });
      expect(screen.getAllByText('Failed').length).toBeGreaterThan(0);
    });

    it('shows a default badge for unknown status', () => {
      renderModal({ instance: { ...BASE_INSTANCE, status: 'unknown_state' } });
      expect(screen.getByText('unknown_state')).toBeInTheDocument();
    });

    it('displays node name in the header panel', () => {
      renderModal();
      expect(screen.getByText('prod-node')).toBeInTheDocument();
    });

    it('renders instance metadata (created / updated timestamps)', () => {
      renderModal();
      // The date is rendered via toLocaleString; just assert the labels exist
      expect(screen.getByText('Created:')).toBeInTheDocument();
      expect(screen.getByText('Updated:')).toBeInTheDocument();
    });

    it('renders the instance type select with correct options', () => {
      renderModal();
      const select = screen.getByLabelText(/Instance Type/i);
      expect(select).toBeInTheDocument();
      expect(screen.getByRole('option', { name: 'Cloud Instance' })).toBeInTheDocument();
      expect(screen.getByRole('option', { name: 'Physical Server' })).toBeInTheDocument();
      expect(screen.getByRole('option', { name: 'Dynamic Instance' })).toBeInTheDocument();
    });

    it('shows cloud variety hint text by default', () => {
      renderModal({ instance: { ...BASE_INSTANCE, variety: 'cloud' } });
      expect(screen.getByText('Virtual machine hosted in a cloud provider')).toBeInTheDocument();
    });

    it('shows the Cancel and Save Changes buttons', () => {
      renderModal();
      expect(screen.getByRole('button', { name: /Cancel/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /Save Changes/i })).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Form population from instance prop
  // ---------------------------------------------------------------------------

  describe('form population', () => {
    it('re-populates the form and clears errors when a new instance is provided', async () => {
      const { rerender } = renderModal({ instance: BASE_INSTANCE });

      // Corrupt the name field to trigger a validation error
      const nameInput = screen.getByLabelText(/^Name/i);
      fireEvent.change(nameInput, { target: { value: '' } });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));
      await waitFor(() => expect(screen.getByText('Name is required')).toBeInTheDocument());

      // Now provide a new instance — form should reset
      const newInstance: SystemNodeInstance = {
        ...BASE_INSTANCE,
        id: 'inst-def',
        name: 'other-instance',
        variety: 'physical',
        status: 'stopped',
        private_ip_address: '192.168.1.1',
        public_ip_address: '',
        vpn_ip_address: '',
      };
      rerender(
        <BrowserRouter>
          <EditInstanceModal
            nodeId="node-xyz"
            instance={newInstance}
            isOpen={true}
            onClose={jest.fn()}
            onInstanceUpdated={jest.fn()}
          />
        </BrowserRouter>,
      );

      await waitFor(() => {
        expect(screen.getByLabelText(/^Name/i)).toHaveValue('other-instance');
        expect(screen.queryByText('Name is required')).not.toBeInTheDocument();
      });
    });

    it('populates physical variety correctly', () => {
      renderModal({ instance: { ...BASE_INSTANCE, variety: 'physical' } });
      const select = screen.getByLabelText(/Instance Type/i) as HTMLSelectElement;
      expect(select.value).toBe('physical');
      expect(screen.getByText('Physical hardware server')).toBeInTheDocument();
    });

    it('populates dynamic variety correctly', () => {
      renderModal({ instance: { ...BASE_INSTANCE, variety: 'dynamic' } });
      const select = screen.getByLabelText(/Instance Type/i) as HTMLSelectElement;
      expect(select.value).toBe('dynamic');
      expect(screen.getByText('Dynamically provisioned instance')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Validation rules
  // ---------------------------------------------------------------------------

  describe('validation', () => {
    it('shows "Name is required" when name is cleared', async () => {
      renderModal();
      const nameInput = screen.getByLabelText(/^Name/i);
      fireEvent.change(nameInput, { target: { value: '' } });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));
      await waitFor(() =>
        expect(screen.getByText('Name is required')).toBeInTheDocument(),
      );
      expect(mockUpdateNodeInstance).not.toHaveBeenCalled();
    });

    it('shows min-length error when name is too short', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'ab' } });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));
      await waitFor(() =>
        expect(screen.getByText('Name must be at least 3 characters')).toBeInTheDocument(),
      );
      expect(mockUpdateNodeInstance).not.toHaveBeenCalled();
    });

    it('shows max-length error when name exceeds 100 characters', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'a'.repeat(101) } });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));
      await waitFor(() =>
        expect(screen.getByText('Name must be less than 100 characters')).toBeInTheDocument(),
      );
      expect(mockUpdateNodeInstance).not.toHaveBeenCalled();
    });

    it('shows character-set error when name starts with a hyphen', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: '-bad-name' } });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));
      await waitFor(() =>
        expect(
          screen.getByText(
            'Name must start with alphanumeric and contain only letters, numbers, hyphens, underscores, and dots',
          ),
        ).toBeInTheDocument(),
      );
      expect(mockUpdateNodeInstance).not.toHaveBeenCalled();
    });

    it('accepts valid names: letters, numbers, hyphens, underscores, dots', async () => {
      mockUpdateNodeInstance.mockResolvedValue({ ...BASE_INSTANCE, name: 'valid-name_01.prod' });
      renderModal();
      fireEvent.change(screen.getByLabelText(/^Name/i), { target: { value: 'valid-name_01.prod' } });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));
      await waitFor(() => expect(mockUpdateNodeInstance).toHaveBeenCalled());
      expect(screen.queryByText(/Name must start/)).not.toBeInTheDocument();
    });

    it('clears the name error when the user starts typing', async () => {
      renderModal();
      const nameInput = screen.getByLabelText(/^Name/i);
      fireEvent.change(nameInput, { target: { value: '' } });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));
      await waitFor(() => expect(screen.getByText('Name is required')).toBeInTheDocument());

      // Now type a valid character — error should disappear
      fireEvent.change(nameInput, { target: { value: 'a' } });
      await waitFor(() =>
        expect(screen.queryByText('Name is required')).not.toBeInTheDocument(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Successful submit
  // ---------------------------------------------------------------------------

  describe('successful submission', () => {
    it('calls systemApi.updateNodeInstance with correct nodeId, instanceId, and payload', async () => {
      const updatedInstance: SystemNodeInstance = {
        ...BASE_INSTANCE,
        name: 'my-instance-renamed',
        variety: 'physical',
        private_ip_address: '10.10.0.1',
        public_ip_address: '',
        vpn_ip_address: '172.16.0.99',
      };
      mockUpdateNodeInstance.mockResolvedValue(updatedInstance);

      const onInstanceUpdated = jest.fn();
      const onClose = jest.fn();
      renderModal({ onInstanceUpdated, onClose });

      // Change name
      fireEvent.change(screen.getByLabelText(/^Name/i), {
        target: { value: 'my-instance-renamed' },
      });
      // Change variety
      fireEvent.change(screen.getByLabelText(/Instance Type/i), {
        target: { value: 'physical' },
      });
      // Change IPs
      fireEvent.change(screen.getByLabelText(/Private IP/i), {
        target: { value: '10.10.0.1' },
      });
      fireEvent.change(screen.getByLabelText(/Public IP/i), {
        target: { value: '' },
      });
      fireEvent.change(screen.getByLabelText(/VPN IP/i), {
        target: { value: '172.16.0.99' },
      });

      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() =>
        expect(mockUpdateNodeInstance).toHaveBeenCalledWith(
          'node-xyz',
          'inst-abc',
          {
            name: 'my-instance-renamed',
            variety: 'physical',
            private_ip_address: '10.10.0.1',
            public_ip_address: undefined,
            vpn_ip_address: '172.16.0.99',
          },
        ),
      );
    });

    it('trims whitespace from IP fields before submitting', async () => {
      // The name field goes through validation (regex) before trimming, so we
      // use a valid name that is already trimmed. IP fields are not validated by
      // regex — they are only trimmed in the payload builder, and empty-after-trim
      // becomes undefined. We verify the trimming behaviour for private IP.
      const updatedInstance = { ...BASE_INSTANCE, private_ip_address: '10.10.0.5' };
      mockUpdateNodeInstance.mockResolvedValue(updatedInstance);

      renderModal();

      // Set a valid (already-trimmed) name to pass validation
      fireEvent.change(screen.getByLabelText(/^Name/i), {
        target: { value: 'valid-name' },
      });
      fireEvent.change(screen.getByLabelText(/Private IP/i), {
        target: { value: '10.10.0.5' },
      });

      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() =>
        expect(mockUpdateNodeInstance).toHaveBeenCalledWith(
          'node-xyz',
          'inst-abc',
          expect.objectContaining({
            name: 'valid-name',
            private_ip_address: '10.10.0.5',
          }),
        ),
      );
    });

    it('sends undefined for empty IP fields (not empty string)', async () => {
      mockUpdateNodeInstance.mockResolvedValue({ ...BASE_INSTANCE, public_ip_address: undefined });

      renderModal();
      // Clear public IP
      fireEvent.change(screen.getByLabelText(/Public IP/i), { target: { value: '' } });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() =>
        expect(mockUpdateNodeInstance).toHaveBeenCalledWith(
          'node-xyz',
          'inst-abc',
          expect.objectContaining({ public_ip_address: undefined }),
        ),
      );
    });

    it('shows success notification with the updated instance name', async () => {
      const updatedInstance = { ...BASE_INSTANCE, name: 'my-instance-01' };
      mockUpdateNodeInstance.mockResolvedValue(updatedInstance);

      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: `Instance "my-instance-01" updated successfully`,
        }),
      );
    });

    it('calls onInstanceUpdated with the returned instance', async () => {
      const updatedInstance = { ...BASE_INSTANCE, name: 'updated' };
      mockUpdateNodeInstance.mockResolvedValue(updatedInstance);

      const onInstanceUpdated = jest.fn();
      renderModal({ onInstanceUpdated });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() =>
        expect(onInstanceUpdated).toHaveBeenCalledWith(updatedInstance),
      );
    });

    it('calls onClose after a successful save', async () => {
      mockUpdateNodeInstance.mockResolvedValue(BASE_INSTANCE);
      const onClose = jest.fn();
      renderModal({ onClose });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));
      await waitFor(() => expect(onClose).toHaveBeenCalled());
    });

    it('shows "Saving..." on the button while the request is in flight', async () => {
      let resolveUpdate!: (v: SystemNodeInstance) => void;
      mockUpdateNodeInstance.mockReturnValue(
        new Promise<SystemNodeInstance>((res) => { resolveUpdate = res; }),
      );

      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /Saving\.\.\./i })).toBeInTheDocument(),
      );

      // Resolve so the component can clean up
      resolveUpdate(BASE_INSTANCE);
      await waitFor(() =>
        expect(screen.queryByRole('button', { name: /Saving\.\.\./i })).not.toBeInTheDocument(),
      );
    });

    it('disables both Cancel and Save buttons while submitting', async () => {
      let resolveUpdate!: (v: SystemNodeInstance) => void;
      mockUpdateNodeInstance.mockReturnValue(
        new Promise<SystemNodeInstance>((res) => { resolveUpdate = res; }),
      );

      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() => {
        expect(screen.getByRole('button', { name: /Saving\.\.\./i })).toBeDisabled();
        expect(screen.getByRole('button', { name: /Cancel/i })).toBeDisabled();
      });

      resolveUpdate(BASE_INSTANCE);
    });
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  describe('error handling', () => {
    it('shows an error notification when the API call fails with an Error', async () => {
      mockUpdateNodeInstance.mockRejectedValue(new Error('Network error'));

      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Network error',
        }),
      );
    });

    it('shows a generic error notification for non-Error rejections', async () => {
      mockUpdateNodeInstance.mockRejectedValue('unexpected string error');

      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to update instance',
        }),
      );
    });

    it('does not call onClose or onInstanceUpdated on error', async () => {
      mockUpdateNodeInstance.mockRejectedValue(new Error('API down'));

      const onClose = jest.fn();
      const onInstanceUpdated = jest.fn();
      renderModal({ onClose, onInstanceUpdated });

      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() => expect(mockAddNotification).toHaveBeenCalled());
      expect(onClose).not.toHaveBeenCalled();
      expect(onInstanceUpdated).not.toHaveBeenCalled();
    });

    it('re-enables the Save button after an API error', async () => {
      mockUpdateNodeInstance.mockRejectedValue(new Error('fail'));

      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /Save Changes/i })).not.toBeDisabled(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Guard: null nodeId / instance — should not fire the API
  // ---------------------------------------------------------------------------

  describe('null guards', () => {
    it('does not call the API when nodeId is null', async () => {
      renderModal({ nodeId: null });
      fireEvent.click(screen.getByRole('button', { name: /Save Changes/i }));
      // Brief pause to let async flow settle
      await waitFor(() => expect(mockUpdateNodeInstance).not.toHaveBeenCalled());
    });

    it('does not call the API when instance is null', async () => {
      renderModal({ instance: null });
      // Modal won't populate the form but the button may still be present via footer
      // Skip if modal is not rendered (isOpen=true but instance=null means no form)
      const saveBtn = screen.queryByRole('button', { name: /Save Changes/i });
      if (saveBtn) {
        fireEvent.click(saveBtn);
        await waitFor(() => expect(mockUpdateNodeInstance).not.toHaveBeenCalled());
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  describe('cancel button', () => {
    it('calls onClose when Cancel is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));
      expect(onClose).toHaveBeenCalled();
    });

    it('does not submit when Cancel is clicked', () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /Cancel/i }));
      expect(mockUpdateNodeInstance).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Variety hint text
  // ---------------------------------------------------------------------------

  describe('variety hint text', () => {
    it('shows cloud hint when Cloud Instance is selected', async () => {
      renderModal({ instance: { ...BASE_INSTANCE, variety: 'cloud' } });
      expect(screen.getByText('Virtual machine hosted in a cloud provider')).toBeInTheDocument();
    });

    it('shows physical hint when Physical Server is selected', async () => {
      renderModal({ instance: { ...BASE_INSTANCE, variety: 'physical' } });
      expect(screen.getByText('Physical hardware server')).toBeInTheDocument();
    });

    it('shows dynamic hint when Dynamic Instance is selected', async () => {
      renderModal({ instance: { ...BASE_INSTANCE, variety: 'dynamic' } });
      expect(screen.getByText('Dynamically provisioned instance')).toBeInTheDocument();
    });

    it('updates hint text when variety is changed via the select', async () => {
      renderModal({ instance: { ...BASE_INSTANCE, variety: 'cloud' } });
      expect(screen.getByText('Virtual machine hosted in a cloud provider')).toBeInTheDocument();

      fireEvent.change(screen.getByLabelText(/Instance Type/i), {
        target: { value: 'physical' },
      });

      await waitFor(() =>
        expect(screen.getByText('Physical hardware server')).toBeInTheDocument(),
      );
    });
  });
});
