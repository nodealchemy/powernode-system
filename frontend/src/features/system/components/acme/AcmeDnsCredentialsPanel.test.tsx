import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { AcmeDnsCredentialsPanel } from './AcmeDnsCredentialsPanel';

// =============================================================================
// Mocks
//
// The panel calls `acmeDnsCredentialsApi` directly (list, testConnectivity,
// destroy). We stub the facade and the notification + modal child components
// so tests only observe the panel's own state and API calls.
// =============================================================================

const mockList = jest.fn();
const mockTestConnectivity = jest.fn();
const mockDestroy = jest.fn();

jest.mock(
  '@system/features/system/services/api/acmeDnsCredentialsApi',
  () => ({
    acmeDnsCredentialsApi: {
      list: (...args: unknown[]) => mockList(...args),
      testConnectivity: (...args: unknown[]) => mockTestConnectivity(...args),
      destroy: (...args: unknown[]) => mockDestroy(...args),
    },
  }),
);

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// Stub child modals so they do not pull in unrelated deps and we can control
// their open state via the panel's own button clicks.
jest.mock(
  '@system/features/system/components/acme/AcmeDnsCredentialModal',
  () => ({
    AcmeDnsCredentialModal: ({
      isOpen,
      onClose,
      onCreated,
    }: {
      isOpen: boolean;
      onClose: () => void;
      onCreated?: () => void;
    }) =>
      isOpen ? (
        <div data-testid="add-credential-modal">
          <button onClick={onClose} data-testid="modal-close">
            close
          </button>
          <button onClick={() => onCreated?.()} data-testid="modal-created">
            created
          </button>
        </div>
      ) : null,
  }),
);

jest.mock(
  '@system/features/system/components/acme/DnsRecordsModal',
  () => ({
    DnsRecordsModal: ({
      isOpen,
      credentialId,
      credentialName,
      onClose,
    }: {
      isOpen: boolean;
      credentialId: string | null;
      credentialName: string;
      onClose: () => void;
    }) =>
      isOpen ? (
        <div data-testid="dns-records-modal" data-credential-id={credentialId ?? ''}>
          <span data-testid="dns-modal-name">{credentialName}</span>
          <button onClick={onClose} data-testid="dns-modal-close">
            close
          </button>
        </div>
      ) : null,
  }),
);

// =============================================================================
// Fixtures
// =============================================================================

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const CRED_CF = {
  id: 'cred-cf-1',
  name: 'production-cloudflare',
  provider: 'cloudflare' as const,
  status: 'valid' as const,
  last_validated_at: '2026-06-01T10:00:00Z',
  created_at: '2026-05-01T00:00:00Z',
  updated_at: '2026-06-01T10:00:00Z',
  needs_revalidation: false,
};

const CRED_DO = {
  id: 'cred-do-1',
  name: 'staging-do',
  provider: 'digitalocean' as const,
  status: 'untested' as const,
  last_validated_at: null,
  created_at: '2026-05-10T00:00:00Z',
  updated_at: '2026-05-10T00:00:00Z',
  needs_revalidation: false,
};

const CRED_STALE = {
  id: 'cred-stale-1',
  name: 'stale-hetzner',
  provider: 'hetzner' as const,
  status: 'valid' as const,
  last_validated_at: '2026-05-01T00:00:00Z',
  created_at: '2026-04-01T00:00:00Z',
  updated_at: '2026-05-01T00:00:00Z',
  needs_revalidation: true,
};

const SUPPORTED_PROVIDERS = [
  { slug: 'cloudflare', required_fields: ['api_token'], description: 'Cloudflare' },
  { slug: 'digitalocean', required_fields: ['auth_token'], description: 'DigitalOcean' },
];

function makeListResponse(credentials: typeof CRED_CF[]) {
  return {
    credentials,
    count: credentials.length,
    supported_providers: SUPPORTED_PROVIDERS,
  };
}

// =============================================================================
// Helpers
// =============================================================================

const renderPanel = (refreshKey = 0) =>
  render(
    <BrowserRouter>
      <AcmeDnsCredentialsPanel refreshKey={refreshKey} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('AcmeDnsCredentialsPanel', () => {
  beforeEach(() => {
    mockList.mockReset();
    mockTestConnectivity.mockReset();
    mockDestroy.mockReset();
    mockAddNotification.mockReset();
    jest.spyOn(window, 'confirm').mockReturnValue(true);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows "loading…" while the list request is pending', async () => {
    // Never resolve so we stay in loading state
    mockList.mockReturnValue(new Promise(() => undefined));

    renderPanel();

    expect(screen.getByText('loading…')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows the empty-state prompt when no credentials are configured', async () => {
    mockList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    await waitFor(() =>
      expect(
        screen.getByText(/No DNS credentials configured yet/i),
      ).toBeInTheDocument(),
    );
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
  });

  it('shows "0 credentials" in the header when the list is empty', async () => {
    mockList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('0 credentials')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Populated list
  // ---------------------------------------------------------------------------

  it('renders one row per credential fetched from the API', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF, CRED_DO]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('production-cloudflare')).toBeInTheDocument());
    expect(screen.getByText('staging-do')).toBeInTheDocument();
  });

  it('calls acmeDnsCredentialsApi.list on mount', async () => {
    mockList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
    expect(mockList).toHaveBeenCalledWith();
  });

  it('re-fetches when refreshKey changes', async () => {
    mockList.mockResolvedValue(makeListResponse([]));

    const { rerender } = renderPanel(0);
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    rerender(
      <BrowserRouter>
        <AcmeDnsCredentialsPanel refreshKey={1} />
      </BrowserRouter>,
    );
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  it('shows "N credentials" (plural) for multiple results', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF, CRED_DO]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('2 credentials')).toBeInTheDocument());
  });

  it('shows "1 credential" (singular) for a single result', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('1 credential')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Load error
  // ---------------------------------------------------------------------------

  it('fires addNotification with the error message on list failure', async () => {
    mockList.mockRejectedValue(new Error('Network error'));

    renderPanel();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network error',
      }),
    );
  });

  it('fires a generic error notification when list rejects with a non-Error', async () => {
    mockList.mockRejectedValue('oops');

    renderPanel();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load credentials',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Status pills
  // ---------------------------------------------------------------------------

  it('renders the "valid" status pill for a valid credential', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('valid')).toBeInTheDocument());
  });

  it('renders the "untested" status pill for an untested credential', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_DO]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('untested')).toBeInTheDocument());
  });

  it('shows "stale" badge when needs_revalidation is true', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_STALE]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('stale')).toBeInTheDocument());
  });

  it('shows "never" when last_validated_at is null', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_DO]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('never')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Expand/collapse row
  // ---------------------------------------------------------------------------

  it('expands a row to reveal detail labels when the expand button is clicked', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('production-cloudflare')).toBeInTheDocument());

    // Find the expand button — it has title "Expand details"
    const expandBtn = screen.getByTitle('Expand details');
    fireEvent.click(expandBtn);

    await waitFor(() => expect(screen.getByText('Credential ID')).toBeInTheDocument());
    expect(screen.getByText('Revalidation')).toBeInTheDocument();
    expect(screen.getByText('Last Validated')).toBeInTheDocument();
  });

  it('collapses an expanded row when the chevron is clicked again', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('production-cloudflare')).toBeInTheDocument());

    const expandBtn = screen.getByTitle('Expand details');
    fireEvent.click(expandBtn);
    await waitFor(() => expect(screen.getByText('Credential ID')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() => expect(screen.queryByText('Credential ID')).not.toBeInTheDocument());
  });

  it('can expand two rows independently', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF, CRED_DO]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('production-cloudflare')).toBeInTheDocument());

    const expandBtns = screen.getAllByTitle('Expand details');
    expect(expandBtns).toHaveLength(2);

    fireEvent.click(expandBtns[0]);
    fireEvent.click(expandBtns[1]);

    // Both rows expose detail labels — there'll be two instances
    await waitFor(() => expect(screen.getAllByText('Credential ID').length).toBe(2));
  });

  // ---------------------------------------------------------------------------
  // Test connectivity action
  // ---------------------------------------------------------------------------

  it('calls testConnectivity with the credential id when Test is clicked', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));
    mockTestConnectivity.mockResolvedValue({
      ok: true,
      reason: 'Token valid',
      credential: CRED_CF,
    });

    renderPanel();

    await waitFor(() => expect(screen.getByText('Test')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Test'));

    await waitFor(() =>
      expect(mockTestConnectivity).toHaveBeenCalledWith('cred-cf-1'),
    );
  });

  it('shows the reason message inline after a test completes', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));
    mockTestConnectivity.mockResolvedValue({
      ok: true,
      reason: 'Connection verified',
      credential: CRED_CF,
    });

    renderPanel();

    await waitFor(() => expect(screen.getByText('Test')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Test'));

    await waitFor(() =>
      expect(screen.getByText('Connection verified')).toBeInTheDocument(),
    );
  });

  it('shows the error reason inline when testConnectivity rejects', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));
    mockTestConnectivity.mockRejectedValue(new Error('Auth failed'));

    renderPanel();

    await waitFor(() => expect(screen.getByText('Test')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Test'));

    await waitFor(() => expect(screen.getByText('Auth failed')).toBeInTheDocument());
  });

  it('shows "Testing…" while testConnectivity is in progress', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));
    // Keep the test promise pending so we can observe the interim state
    let resolveTest!: (v: unknown) => void;
    mockTestConnectivity.mockReturnValue(
      new Promise((r) => {
        resolveTest = r;
      }),
    );

    renderPanel();

    await waitFor(() => expect(screen.getByText('Test')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Test'));

    await waitFor(() => expect(screen.getByText('Testing…')).toBeInTheDocument());

    // Resolve to avoid lingering state
    resolveTest({ ok: true, reason: '', credential: CRED_CF });
  });

  it('re-fetches the list after a successful test', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));
    mockTestConnectivity.mockResolvedValue({
      ok: true,
      reason: 'ok',
      credential: CRED_CF,
    });

    renderPanel();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    fireEvent.click(await screen.findByText('Test'));

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Delete action
  // ---------------------------------------------------------------------------

  it('asks for confirmation before deleting', async () => {
    const confirmSpy = jest.spyOn(window, 'confirm').mockReturnValue(false);
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Delete'));

    expect(confirmSpy).toHaveBeenCalled();
    expect(mockDestroy).not.toHaveBeenCalled();
  });

  it('calls acmeDnsCredentialsApi.destroy with the credential id after confirmation', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));
    mockDestroy.mockResolvedValue(undefined);

    renderPanel();

    await waitFor(() => expect(screen.getByText('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Delete'));

    await waitFor(() => expect(mockDestroy).toHaveBeenCalledWith('cred-cf-1'));
  });

  it('shows the delete error via addNotification on failure', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));
    mockDestroy.mockRejectedValue(new Error('Cannot delete — active certs'));

    renderPanel();

    await waitFor(() => expect(screen.getByText('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Delete'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Cannot delete — active certs',
      }),
    );
  });

  it('re-fetches the list after a successful delete', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));
    mockDestroy.mockResolvedValue(undefined);

    renderPanel();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
    fireEvent.click(await screen.findByText('Delete'));

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  it('shows "Deleting…" text while the destroy request is in flight', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));
    let resolveDestroy!: () => void;
    mockDestroy.mockReturnValue(new Promise<void>((r) => { resolveDestroy = r; }));

    renderPanel();

    await waitFor(() => expect(screen.getByText('Delete')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Delete'));

    await waitFor(() => expect(screen.getByText('Deleting…')).toBeInTheDocument());

    resolveDestroy();
  });

  // ---------------------------------------------------------------------------
  // Add credential modal
  // ---------------------------------------------------------------------------

  it('opens the Add credential modal when the header button is clicked', async () => {
    mockList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('Add credential')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Add credential'));

    expect(screen.getByTestId('add-credential-modal')).toBeInTheDocument();
  });

  it('closes the Add credential modal via onClose', async () => {
    mockList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('Add credential')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Add credential'));

    fireEvent.click(screen.getByTestId('modal-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('add-credential-modal')).not.toBeInTheDocument(),
    );
  });

  it('closes the modal and re-fetches when onCreated is called', async () => {
    mockList.mockResolvedValue(makeListResponse([]));

    renderPanel();

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
    fireEvent.click(screen.getByText('Add credential'));
    fireEvent.click(screen.getByTestId('modal-created'));

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
    expect(screen.queryByTestId('add-credential-modal')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // DNS records modal (Cloudflare-only)
  // ---------------------------------------------------------------------------

  it('renders a "DNS Records" button only for cloudflare credentials', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF, CRED_DO]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('production-cloudflare')).toBeInTheDocument());

    // Only cloudflare row should have DNS Records button
    expect(screen.getAllByText('DNS Records')).toHaveLength(1);
  });

  it('does not render a "DNS Records" button for non-cloudflare credentials', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_DO]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('staging-do')).toBeInTheDocument());
    expect(screen.queryByText('DNS Records')).not.toBeInTheDocument();
  });

  it('opens the DnsRecordsModal with the correct credential when DNS Records is clicked', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('DNS Records')).toBeInTheDocument());
    fireEvent.click(screen.getByText('DNS Records'));

    const modal = await screen.findByTestId('dns-records-modal');
    expect(modal).toBeInTheDocument();
    expect(modal.getAttribute('data-credential-id')).toBe('cred-cf-1');
    expect(screen.getByTestId('dns-modal-name')).toHaveTextContent('production-cloudflare');
  });

  it('closes the DnsRecordsModal via onClose', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('DNS Records')).toBeInTheDocument());
    fireEvent.click(screen.getByText('DNS Records'));
    await screen.findByTestId('dns-records-modal');

    fireEvent.click(screen.getByTestId('dns-modal-close'));

    await waitFor(() =>
      expect(screen.queryByTestId('dns-records-modal')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Table structure
  // ---------------------------------------------------------------------------

  it('renders the table header columns', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('Name')).toBeInTheDocument());
    expect(screen.getByText('Provider')).toBeInTheDocument();
    expect(screen.getByText('Status')).toBeInTheDocument();
    expect(screen.getByText('Last validated')).toBeInTheDocument();
    expect(screen.getByText('Actions')).toBeInTheDocument();
  });

  it('shows provider slug as a badge in each row', async () => {
    mockList.mockResolvedValue(makeListResponse([CRED_CF]));

    renderPanel();

    // The provider badge is rendered as a <span> with the slug
    await waitFor(() => {
      const badges = screen.getAllByText('cloudflare');
      expect(badges.length).toBeGreaterThan(0);
    });
  });
});
