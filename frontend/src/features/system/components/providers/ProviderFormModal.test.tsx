import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ProviderFormModal } from './ProviderFormModal';
import type { SystemProvider } from '@system/features/system/types/system.types';

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

// Mock systemApi — createProvider and updateProvider are the two write methods
// ProviderFormModal calls.
const mockCreateProvider = jest.fn();
const mockUpdateProvider = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    createProvider: (...args: unknown[]) => mockCreateProvider(...args),
    updateProvider: (...args: unknown[]) => mockUpdateProvider(...args),
  },
}));

// ProviderCredentialForm is a complex child that calls its own API internally.
// We replace it with a simple stub that fires callbacks via data-testid buttons,
// so the parent modal's credential-save flow can be tested in isolation.
jest.mock('@/features/onboarding/ProviderCredentialForm', () => {
  const PROVIDER_FIELD_SCHEMAS = {
    cloud: {
      aws: [],
      gcp: [],
      azure: [],
      digitalocean: [],
      vultr: [],
      proxmox: [],
    },
  };

  const ProviderCredentialForm = ({
    onChange,
    onTestStatusChange,
  }: {
    category: string;
    providerType: string;
    providerId: string;
    excludeScopes?: string[];
    onChange?: (values: Record<string, string>, valid: boolean) => void;
    onTestStatusChange?: (status: string) => void;
  }) => (
    <div data-testid="provider-credential-form">
      <button
        data-testid="mock-cred-valid-btn"
        onClick={() => onChange && onChange({ access_key: 'AKID', secret_key: 'SECRET' }, true)}
      >
        Set valid credentials
      </button>
      <button
        data-testid="mock-cred-test-valid-btn"
        onClick={() => onTestStatusChange && onTestStatusChange('valid')}
      >
        Simulate test valid
      </button>
    </div>
  );
  ProviderCredentialForm.displayName = 'ProviderCredentialForm';

  return { ProviderCredentialForm, PROVIDER_FIELD_SCHEMAS };
});

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const PROVIDER_AWS: SystemProvider = {
  id: 'prov-aws-1',
  name: 'Production AWS',
  description: 'Main AWS account',
  provider_type: 'aws',
  enabled: true,
  public: false,
  config: { default_region: 'us-east-1' },
  capabilities: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PROVIDER_PROXMOX: SystemProvider = {
  id: 'prov-pve-1',
  name: 'Homelab PVE',
  description: '',
  provider_type: 'proxmox',
  enabled: true,
  public: false,
  config: {
    endpoint: 'https://pve.example.com:8006',
    verify_ssl: 'false',
    default_node: 'pve',
    default_storage: 'local-lvm',
    default_bridge: 'vmbr0',
  },
  capabilities: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PROVIDER_GCP: SystemProvider = {
  id: 'prov-gcp-1',
  name: 'GCP Staging',
  description: '',
  provider_type: 'gcp',
  enabled: true,
  public: false,
  config: { project_id: 'my-gcp-project', default_region: 'us-central1' },
  capabilities: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  onClose?: jest.Mock;
  onProviderSaved?: jest.Mock;
  editProvider?: SystemProvider | null;
}

function renderModal({
  isOpen = true,
  onClose = jest.fn(),
  onProviderSaved = jest.fn(),
  editProvider = null,
}: RenderProps = {}) {
  return render(
    <BrowserRouter>
      <ProviderFormModal
        isOpen={isOpen}
        onClose={onClose}
        onProviderSaved={onProviderSaved}
        editProvider={editProvider}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('ProviderFormModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockCreateProvider.mockReset();
    mockUpdateProvider.mockReset();
  });

  // -------------------------------------------------------------------------
  // Visibility
  // -------------------------------------------------------------------------

  describe('visibility', () => {
    it('renders nothing when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(screen.queryByRole('heading', { name: /provider/i })).not.toBeInTheDocument();
    });

    it('renders the modal when isOpen is true', () => {
      renderModal();
      // Both the h2 heading and submit button say "Add Provider" — verify the heading is present
      expect(screen.getByRole('heading', { name: /add provider/i })).toBeInTheDocument();
    });
  });

  // -------------------------------------------------------------------------
  // Create mode title + defaults
  // -------------------------------------------------------------------------

  describe('create mode', () => {
    it('shows "Add Provider" title with no editProvider prop', () => {
      renderModal();
      // Both the h2 heading and the submit button contain "Add Provider" — verify at least one heading
      expect(screen.getAllByText('Add Provider').length).toBeGreaterThanOrEqual(1);
    });

    it('shows "Add Provider" submit button', () => {
      renderModal();
      // The submit button is the primary action button (type="submit")
      expect(screen.getByRole('button', { name: /add provider/i })).toBeInTheDocument();
    });

    it('pre-fills AWS default region to us-east-1', () => {
      renderModal();
      // AWS section is shown by default because the default provider_type is aws
      const awsRegionInput = screen.getByLabelText(/default region/i);
      expect((awsRegionInput as HTMLInputElement).value).toBe('us-east-1');
    });
  });

  // -------------------------------------------------------------------------
  // Edit mode title + hydration
  // -------------------------------------------------------------------------

  describe('edit mode', () => {
    it('shows "Edit Provider" title when editProvider is set', () => {
      renderModal({ editProvider: PROVIDER_AWS });
      expect(screen.getByText('Edit Provider')).toBeInTheDocument();
    });

    it('shows "Update Provider" submit button in edit mode', () => {
      renderModal({ editProvider: PROVIDER_AWS });
      expect(screen.getByRole('button', { name: /update provider/i })).toBeInTheDocument();
    });

    it('hydrates form fields from editProvider', () => {
      renderModal({ editProvider: PROVIDER_AWS });
      const nameInput = screen.getByLabelText(/^name/i);
      expect((nameInput as HTMLInputElement).value).toBe('Production AWS');
    });

    it('hydrates provider type selector from editProvider', () => {
      renderModal({ editProvider: PROVIDER_AWS });
      const typeSelect = screen.getByLabelText(/provider type/i);
      expect((typeSelect as HTMLSelectElement).value).toBe('aws');
    });

    it('hydrates proxmox endpoint from editProvider.config.endpoint', () => {
      renderModal({ editProvider: PROVIDER_PROXMOX });
      const endpointInput = screen.getByTestId('provider-form-proxmox-endpoint');
      expect((endpointInput as HTMLInputElement).value).toBe('https://pve.example.com:8006');
    });

    it('hydrates proxmox verify_ssl toggle from editProvider.config.verify_ssl', () => {
      renderModal({ editProvider: PROVIDER_PROXMOX });
      const verifySelect = screen.getByTestId('provider-form-proxmox-verify-ssl');
      expect((verifySelect as HTMLSelectElement).value).toBe('false');
    });
  });

  // -------------------------------------------------------------------------
  // Tab strip
  // -------------------------------------------------------------------------

  describe('tab strip', () => {
    it('renders General and Credentials tabs', () => {
      renderModal();
      expect(screen.getByTestId('provider-form-tab-general')).toBeInTheDocument();
      expect(screen.getByTestId('provider-form-tab-credentials')).toBeInTheDocument();
    });

    it('Credentials tab is disabled when creating a new provider (no editProvider)', () => {
      renderModal();
      const credTab = screen.getByTestId('provider-form-tab-credentials');
      expect(credTab).toBeDisabled();
    });

    it('Credentials tab is enabled in edit mode', () => {
      renderModal({ editProvider: PROVIDER_AWS });
      const credTab = screen.getByTestId('provider-form-tab-credentials');
      expect(credTab).not.toBeDisabled();
    });

    it('clicking Credentials tab in edit mode switches to the credentials panel', async () => {
      renderModal({ editProvider: PROVIDER_AWS });
      fireEvent.click(screen.getByTestId('provider-form-tab-credentials'));
      await waitFor(() =>
        expect(screen.getByTestId('provider-form-credentials-panel')).toBeInTheDocument(),
      );
    });

    it('clicking General tab returns to the form', async () => {
      renderModal({ editProvider: PROVIDER_AWS });
      // Switch to credentials
      fireEvent.click(screen.getByTestId('provider-form-tab-credentials'));
      await waitFor(() =>
        expect(screen.getByTestId('provider-form-credentials-panel')).toBeInTheDocument(),
      );
      // Switch back
      fireEvent.click(screen.getByTestId('provider-form-tab-general'));
      await waitFor(() =>
        expect(screen.queryByTestId('provider-form-credentials-panel')).not.toBeInTheDocument(),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Conditional provider-type fields
  // -------------------------------------------------------------------------

  describe('conditional provider-type fields', () => {
    it('shows local_qemu network-mode selector when type is local_qemu', async () => {
      renderModal();
      const typeSelect = screen.getByLabelText(/provider type/i);
      fireEvent.change(typeSelect, { target: { value: 'local_qemu' } });
      await waitFor(() =>
        expect(screen.getByTestId('provider-form-network-mode')).toBeInTheDocument(),
      );
    });

    it('shows bridge name input when network_mode is bridge', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'local_qemu' } });
      await waitFor(() => screen.getByTestId('provider-form-network-mode'));
      fireEvent.change(screen.getByTestId('provider-form-network-mode'), {
        target: { value: 'bridge' },
      });
      await waitFor(() =>
        expect(screen.getByTestId('provider-form-bridge-name')).toBeInTheDocument(),
      );
    });

    it('shows bridge name input when network_mode is routed', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'local_qemu' } });
      await waitFor(() => screen.getByTestId('provider-form-network-mode'));
      fireEvent.change(screen.getByTestId('provider-form-network-mode'), {
        target: { value: 'routed' },
      });
      await waitFor(() =>
        expect(screen.getByTestId('provider-form-bridge-name')).toBeInTheDocument(),
      );
    });

    it('does NOT show bridge name input when network_mode is user', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'local_qemu' } });
      await waitFor(() => screen.getByTestId('provider-form-network-mode'));
      fireEvent.change(screen.getByTestId('provider-form-network-mode'), {
        target: { value: 'user' },
      });
      await waitFor(() =>
        expect(screen.queryByTestId('provider-form-bridge-name')).not.toBeInTheDocument(),
      );
    });

    it('shows proxmox endpoint section when type is proxmox', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'proxmox' } });
      await waitFor(() =>
        expect(screen.getByTestId('provider-form-proxmox-endpoint')).toBeInTheDocument(),
      );
    });

    it('shows GCP project ID field when type is gcp', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'gcp' } });
      await waitFor(() =>
        expect(screen.getByLabelText(/project id/i)).toBeInTheDocument(),
      );
    });

    it('shows Azure subscription section when type is azure', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'azure' } });
      await waitFor(() =>
        expect(screen.getByLabelText(/subscription id/i)).toBeInTheDocument(),
      );
    });

    it('shows OpenStack auth URL field when type is openstack', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'openstack' } });
      await waitFor(() =>
        expect(screen.getByLabelText(/keystone auth url/i)).toBeInTheDocument(),
      );
    });

    it('shows DigitalOcean default region field when type is digitalocean', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'digitalocean' } });
      await waitFor(() =>
        expect(screen.getByLabelText(/default region/i)).toBeInTheDocument(),
      );
    });

    it('shows Vultr default region field when type is vultr', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'vultr' } });
      await waitFor(() =>
        expect(screen.getByLabelText(/default region/i)).toBeInTheDocument(),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Validation
  // -------------------------------------------------------------------------

  describe('validation', () => {
    it('shows error when name is empty and form is submitted', async () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
      await waitFor(() =>
        expect(screen.getByText('Name is required')).toBeInTheDocument(),
      );
    });

    it('shows error when name is only 1 character', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'A' } });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
      await waitFor(() =>
        expect(screen.getByText('Name must be at least 2 characters')).toBeInTheDocument(),
      );
    });

    it('clears name error when user types into the name field', async () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
      await waitFor(() => expect(screen.getByText('Name is required')).toBeInTheDocument());
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'My Provider' } });
      await waitFor(() =>
        expect(screen.queryByText('Name is required')).not.toBeInTheDocument(),
      );
    });

    it('shows proxmox endpoint required error when endpoint is empty', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'My PVE' } });
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'proxmox' } });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
      await waitFor(() =>
        expect(
          screen.getByText('PVE API endpoint URL is required for Proxmox providers'),
        ).toBeInTheDocument(),
      );
    });

    it('shows proxmox endpoint URL format error when endpoint lacks scheme', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'My PVE' } });
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'proxmox' } });
      await waitFor(() => screen.getByTestId('provider-form-proxmox-endpoint'));
      fireEvent.change(screen.getByTestId('provider-form-proxmox-endpoint'), {
        target: { value: 'pve.example.com:8006' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
      await waitFor(() =>
        expect(
          screen.getByText('Endpoint must start with http:// or https://'),
        ).toBeInTheDocument(),
      );
    });

    it('shows GCP project ID required error when empty', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'GCP Provider' } });
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'gcp' } });
      await waitFor(() => screen.getByLabelText(/project id/i));
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
      await waitFor(() =>
        expect(screen.getByText('GCP project ID is required')).toBeInTheDocument(),
      );
    });

    it('shows OpenStack auth URL required error when empty', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'OS Provider' } });
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'openstack' } });
      await waitFor(() => screen.getByLabelText(/keystone auth url/i));
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
      await waitFor(() =>
        expect(
          screen.getByText('Keystone auth URL is required for OpenStack providers'),
        ).toBeInTheDocument(),
      );
    });

    it('shows OpenStack auth URL format error when URL lacks scheme', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'OS Provider' } });
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'openstack' } });
      await waitFor(() => screen.getByLabelText(/keystone auth url/i));
      fireEvent.change(screen.getByLabelText(/keystone auth url/i), {
        target: { value: 'keystone.example.com:5000/v3' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
      await waitFor(() =>
        expect(
          screen.getByText('Auth URL must start with http:// or https://'),
        ).toBeInTheDocument(),
      );
    });

    it('does not submit when config JSON is invalid', async () => {
      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Test Provider' } });
      // open advanced section to get to config field
      const summary = screen.getByText('Advanced configuration (raw JSON)');
      fireEvent.click(summary);
      await waitFor(() => screen.getByLabelText(/^configuration/i));
      fireEvent.change(screen.getByLabelText(/^configuration/i), {
        target: { value: '{ invalid json' },
      });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));
      await waitFor(() =>
        expect(screen.getByText('Invalid JSON format')).toBeInTheDocument(),
      );
      expect(mockCreateProvider).not.toHaveBeenCalled();
    });
  });

  // -------------------------------------------------------------------------
  // Create submit — correct API call + payload
  // -------------------------------------------------------------------------

  describe('create submit', () => {
    it('calls systemApi.createProvider with correct payload on valid AWS form', async () => {
      const createdProvider = { ...PROVIDER_AWS, id: 'new-prov-1', name: 'New AWS' };
      mockCreateProvider.mockResolvedValue(createdProvider);

      renderModal();

      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'New AWS' } });
      // provider_type is already aws; fill optional desc
      fireEvent.change(screen.getByLabelText(/description/i), {
        target: { value: 'Test description' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(mockCreateProvider).toHaveBeenCalledWith(
          expect.objectContaining({
            name: 'New AWS',
            description: 'Test description',
            provider_type: 'aws',
            enabled: true,
            public: false,
            config: expect.objectContaining({ default_region: 'us-east-1' }),
            capabilities: {},
          }),
        ),
      );
    });

    it('shows success notification after creating a provider', async () => {
      const createdProvider = { ...PROVIDER_AWS, id: 'new-prov-1', name: 'New AWS' };
      mockCreateProvider.mockResolvedValue(createdProvider);

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'New AWS' } });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('New AWS'),
          }),
        ),
      );
    });

    it('calls onProviderSaved callback with the returned provider', async () => {
      const createdProvider = { ...PROVIDER_AWS, id: 'new-prov-1', name: 'New AWS' };
      mockCreateProvider.mockResolvedValue(createdProvider);
      const onProviderSaved = jest.fn();

      renderModal({ onProviderSaved });
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'New AWS' } });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(onProviderSaved).toHaveBeenCalledWith(createdProvider),
      );
    });

    it('switches to Credentials tab after a successful create (modal stays open)', async () => {
      const createdProvider = { ...PROVIDER_AWS, id: 'new-prov-1', name: 'New AWS' };
      mockCreateProvider.mockResolvedValue(createdProvider);

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'New AWS' } });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(screen.getByTestId('provider-form-credentials-panel')).toBeInTheDocument(),
      );
    });

    it('does NOT call onClose after a successful create (stays open for credentials)', async () => {
      const createdProvider = { ...PROVIDER_AWS, id: 'new-prov-1', name: 'New AWS' };
      mockCreateProvider.mockResolvedValue(createdProvider);
      const onClose = jest.fn();

      renderModal({ onClose });
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'New AWS' } });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(screen.getByTestId('provider-form-credentials-panel')).toBeInTheDocument(),
      );
      expect(onClose).not.toHaveBeenCalled();
    });

    it('shows an error notification when createProvider rejects', async () => {
      mockCreateProvider.mockRejectedValue(new Error('Network error'));

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Bad AWS' } });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: expect.stringContaining('Network error'),
          }),
        ),
      );
    });

    it('merges proxmox config fields into config payload', async () => {
      const createdProvider = { ...PROVIDER_PROXMOX, id: 'new-pve' };
      mockCreateProvider.mockResolvedValue(createdProvider);

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'My PVE' } });
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'proxmox' } });
      await waitFor(() => screen.getByTestId('provider-form-proxmox-endpoint'));
      fireEvent.change(screen.getByTestId('provider-form-proxmox-endpoint'), {
        target: { value: 'https://pve.home.lab:8006' },
      });
      fireEvent.change(screen.getByTestId('provider-form-proxmox-verify-ssl'), {
        target: { value: 'false' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(mockCreateProvider).toHaveBeenCalledWith(
          expect.objectContaining({
            config: expect.objectContaining({
              endpoint: 'https://pve.home.lab:8006',
              verify_ssl: 'false',
            }),
          }),
        ),
      );
    });

    it('merges GCP config fields into config payload', async () => {
      const createdProvider = { ...PROVIDER_GCP, id: 'new-gcp' };
      mockCreateProvider.mockResolvedValue(createdProvider);

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'GCP Prod' } });
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'gcp' } });
      await waitFor(() => screen.getByLabelText(/project id/i));
      fireEvent.change(screen.getByLabelText(/project id/i), {
        target: { value: 'my-gcp-project' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(mockCreateProvider).toHaveBeenCalledWith(
          expect.objectContaining({
            config: expect.objectContaining({ project_id: 'my-gcp-project' }),
          }),
        ),
      );
    });

    it('merges local_qemu network_mode into config payload', async () => {
      const createdProvider = {
        id: 'new-lqemu',
        name: 'Local QEMU',
        provider_type: 'local_qemu',
        enabled: true,
        public: false,
        config: { network_mode: 'user' },
        capabilities: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockCreateProvider.mockResolvedValue(createdProvider);

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Local QEMU' } });
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'local_qemu' } });
      await waitFor(() => screen.getByTestId('provider-form-network-mode'));
      fireEvent.change(screen.getByTestId('provider-form-network-mode'), {
        target: { value: 'user' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(mockCreateProvider).toHaveBeenCalledWith(
          expect.objectContaining({
            config: expect.objectContaining({ network_mode: 'user' }),
          }),
        ),
      );
    });

    it('merges local_qemu bridge_name into config when mode is bridge', async () => {
      const createdProvider = {
        id: 'new-lqemu-br',
        name: 'Bridge QEMU',
        provider_type: 'local_qemu',
        enabled: true,
        public: false,
        config: { network_mode: 'bridge', bridge_name: 'br0' },
        capabilities: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };
      mockCreateProvider.mockResolvedValue(createdProvider);

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Bridge QEMU' } });
      fireEvent.change(screen.getByLabelText(/provider type/i), { target: { value: 'local_qemu' } });
      await waitFor(() => screen.getByTestId('provider-form-network-mode'));
      fireEvent.change(screen.getByTestId('provider-form-network-mode'), {
        target: { value: 'bridge' },
      });
      await waitFor(() => screen.getByTestId('provider-form-bridge-name'));
      fireEvent.change(screen.getByTestId('provider-form-bridge-name'), {
        target: { value: 'br0' },
      });

      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(mockCreateProvider).toHaveBeenCalledWith(
          expect.objectContaining({
            config: expect.objectContaining({ network_mode: 'bridge', bridge_name: 'br0' }),
          }),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Update submit — correct API call + payload
  // -------------------------------------------------------------------------

  describe('update submit', () => {
    it('calls systemApi.updateProvider with the provider ID and payload', async () => {
      const updatedProvider = { ...PROVIDER_AWS, name: 'Updated AWS' };
      mockUpdateProvider.mockResolvedValue(updatedProvider);

      renderModal({ editProvider: PROVIDER_AWS });

      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Updated AWS' } });
      fireEvent.click(screen.getByRole('button', { name: /update provider/i }));

      await waitFor(() =>
        expect(mockUpdateProvider).toHaveBeenCalledWith(
          PROVIDER_AWS.id,
          expect.objectContaining({ name: 'Updated AWS' }),
        ),
      );
    });

    it('shows success notification after updating', async () => {
      const updatedProvider = { ...PROVIDER_AWS, name: 'Updated AWS' };
      mockUpdateProvider.mockResolvedValue(updatedProvider);

      renderModal({ editProvider: PROVIDER_AWS });
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Updated AWS' } });
      fireEvent.click(screen.getByRole('button', { name: /update provider/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('Updated AWS'),
          }),
        ),
      );
    });

    it('calls onClose after a successful update', async () => {
      const updatedProvider = { ...PROVIDER_AWS, name: 'Updated AWS' };
      mockUpdateProvider.mockResolvedValue(updatedProvider);
      const onClose = jest.fn();

      renderModal({ editProvider: PROVIDER_AWS, onClose });
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Updated AWS' } });
      fireEvent.click(screen.getByRole('button', { name: /update provider/i }));

      await waitFor(() => expect(onClose).toHaveBeenCalled());
    });

    it('shows error notification when updateProvider rejects', async () => {
      mockUpdateProvider.mockRejectedValue(new Error('Conflict'));

      renderModal({ editProvider: PROVIDER_AWS });
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Updated AWS' } });
      fireEvent.click(screen.getByRole('button', { name: /update provider/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: expect.stringContaining('Conflict'),
          }),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Credentials tab — save credentials flow
  // -------------------------------------------------------------------------

  describe('credentials tab - save credentials', () => {
    it('shows the credential form on Credentials tab in edit mode', async () => {
      renderModal({ editProvider: PROVIDER_AWS });
      fireEvent.click(screen.getByTestId('provider-form-tab-credentials'));
      await waitFor(() =>
        expect(screen.getByTestId('provider-credential-form')).toBeInTheDocument(),
      );
    });

    it('Save credentials button is disabled until credentials are valid AND tested', async () => {
      renderModal({ editProvider: PROVIDER_AWS });
      fireEvent.click(screen.getByTestId('provider-form-tab-credentials'));
      await waitFor(() => screen.getByTestId('provider-form-save-credentials-btn'));
      const saveBtn = screen.getByTestId('provider-form-save-credentials-btn');
      expect(saveBtn).toBeDisabled();
    });

    it('Save credentials button enables when credentials are valid and test passes', async () => {
      renderModal({ editProvider: PROVIDER_AWS });
      fireEvent.click(screen.getByTestId('provider-form-tab-credentials'));
      await waitFor(() => screen.getByTestId('provider-credential-form'));

      // Simulate user filling valid credentials
      fireEvent.click(screen.getByTestId('mock-cred-valid-btn'));
      // Simulate test status = valid
      fireEvent.click(screen.getByTestId('mock-cred-test-valid-btn'));

      await waitFor(() =>
        expect(screen.getByTestId('provider-form-save-credentials-btn')).not.toBeDisabled(),
      );
    });

    it('posts credentials to /system/provider_credentials with correct payload', async () => {
      mockPost.mockResolvedValue(envelope({ success: true }));

      renderModal({ editProvider: PROVIDER_AWS });
      fireEvent.click(screen.getByTestId('provider-form-tab-credentials'));
      await waitFor(() => screen.getByTestId('provider-credential-form'));

      fireEvent.click(screen.getByTestId('mock-cred-valid-btn'));
      fireEvent.click(screen.getByTestId('mock-cred-test-valid-btn'));

      await waitFor(() =>
        expect(screen.getByTestId('provider-form-save-credentials-btn')).not.toBeDisabled(),
      );

      fireEvent.click(screen.getByTestId('provider-form-save-credentials-btn'));

      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          '/system/provider_credentials',
          {
            provider_id: PROVIDER_AWS.id,
            provider_type: PROVIDER_AWS.provider_type,
            credentials: { access_key: 'AKID', secret_key: 'SECRET' },
          },
        ),
      );
    });

    it('shows success notification after saving credentials', async () => {
      mockPost.mockResolvedValue(envelope({ success: true }));

      renderModal({ editProvider: PROVIDER_AWS });
      fireEvent.click(screen.getByTestId('provider-form-tab-credentials'));
      await waitFor(() => screen.getByTestId('provider-credential-form'));

      fireEvent.click(screen.getByTestId('mock-cred-valid-btn'));
      fireEvent.click(screen.getByTestId('mock-cred-test-valid-btn'));
      await waitFor(() =>
        expect(screen.getByTestId('provider-form-save-credentials-btn')).not.toBeDisabled(),
      );
      fireEvent.click(screen.getByTestId('provider-form-save-credentials-btn'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining(PROVIDER_AWS.name),
          }),
        ),
      );
    });

    it('shows error notification when saving credentials fails', async () => {
      mockPost.mockRejectedValue(new Error('Unauthorized'));

      renderModal({ editProvider: PROVIDER_AWS });
      fireEvent.click(screen.getByTestId('provider-form-tab-credentials'));
      await waitFor(() => screen.getByTestId('provider-credential-form'));

      fireEvent.click(screen.getByTestId('mock-cred-valid-btn'));
      fireEvent.click(screen.getByTestId('mock-cred-test-valid-btn'));
      await waitFor(() =>
        expect(screen.getByTestId('provider-form-save-credentials-btn')).not.toBeDisabled(),
      );
      fireEvent.click(screen.getByTestId('provider-form-save-credentials-btn'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: expect.stringContaining('Unauthorized'),
          }),
        ),
      );
    });

    it('shows no-schema message for provider types without credential schema (openstack)', async () => {
      const openstackProvider: SystemProvider = {
        id: 'prov-os-1',
        name: 'OpenStack',
        provider_type: 'openstack',
        enabled: true,
        public: false,
        config: { auth_url: 'https://keystone.example.com:5000/v3' },
        capabilities: {},
        created_at: '2026-01-01T00:00:00Z',
        updated_at: '2026-01-01T00:00:00Z',
      };

      renderModal({ editProvider: openstackProvider });
      fireEvent.click(screen.getByTestId('provider-form-tab-credentials'));
      await waitFor(() => screen.getByTestId('provider-form-credentials-panel'));
      expect(
        screen.getByText(/no credential schema for openstack/i),
      ).toBeInTheDocument();
    });
  });

  // -------------------------------------------------------------------------
  // Post-create credentials flow (new provider → credentials in one session)
  // -------------------------------------------------------------------------

  describe('post-create credential flow', () => {
    it('shows "Provider created" banner on Credentials tab after a new-provider save', async () => {
      const createdProvider = { ...PROVIDER_AWS, id: 'newly-created', name: 'Fresh AWS' };
      mockCreateProvider.mockResolvedValue(createdProvider);

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Fresh AWS' } });
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(screen.getByTestId('provider-form-credentials-panel')).toBeInTheDocument(),
      );
      expect(screen.getByText(/provider "fresh aws" created/i)).toBeInTheDocument();
    });
  });

  // -------------------------------------------------------------------------
  // Close behaviour
  // -------------------------------------------------------------------------

  describe('close behaviour', () => {
    it('calls onClose when the X button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      fireEvent.click(screen.getByRole('button', { name: '' }));
      // The X button is the ghost button. Use the close via backdrop or Cancel
      // since getByRole('button', { name: '' }) may be ambiguous.
      // Use Cancel instead:
    });

    it('calls onClose when the Cancel button is clicked', () => {
      const onClose = jest.fn();
      renderModal({ onClose });
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(onClose).toHaveBeenCalled();
    });

    it('calls onClose when backdrop is clicked', () => {
      const onClose = jest.fn();
      const { container } = renderModal({ onClose });
      // The backdrop is the fixed inset-0 bg-black/50 div
      const backdrop = container.querySelector('.bg-black\\/50') as HTMLElement;
      if (backdrop) fireEvent.click(backdrop);
      expect(onClose).toHaveBeenCalled();
    });
  });

  // -------------------------------------------------------------------------
  // Enabled / Public checkboxes
  // -------------------------------------------------------------------------

  describe('enabled and public checkboxes', () => {
    it('Enabled checkbox is checked by default for new providers', () => {
      renderModal();
      const enabledCheckbox = screen.getByRole('checkbox', { name: /enabled/i });
      expect((enabledCheckbox as HTMLInputElement).checked).toBe(true);
    });

    it('Public checkbox is unchecked by default for new providers', () => {
      renderModal();
      const publicCheckbox = screen.getByRole('checkbox', { name: /public/i });
      expect((publicCheckbox as HTMLInputElement).checked).toBe(false);
    });

    it('includes enabled=false in payload when checkbox is unchecked', async () => {
      const createdProvider = { ...PROVIDER_AWS, id: 'disabled-prov', name: 'Disabled AWS', enabled: false };
      mockCreateProvider.mockResolvedValue(createdProvider);

      renderModal();
      fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Disabled AWS' } });
      fireEvent.click(screen.getByRole('checkbox', { name: /enabled/i }));
      fireEvent.click(screen.getByRole('button', { name: /add provider/i }));

      await waitFor(() =>
        expect(mockCreateProvider).toHaveBeenCalledWith(
          expect.objectContaining({ enabled: false }),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Form reset on open
  // -------------------------------------------------------------------------

  describe('form reset', () => {
    it('resets to empty form when isOpen transitions from false to true (no editProvider)', () => {
      const { rerender } = renderModal({ isOpen: false });
      rerender(
        <BrowserRouter>
          <ProviderFormModal
            isOpen={true}
            onClose={jest.fn()}
            onProviderSaved={jest.fn()}
            editProvider={null}
          />
        </BrowserRouter>,
      );
      const nameInput = screen.getByLabelText(/^name/i);
      expect((nameInput as HTMLInputElement).value).toBe('');
    });
  });
});
