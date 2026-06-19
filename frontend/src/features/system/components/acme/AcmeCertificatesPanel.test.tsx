import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { AcmeCertificatesPanel } from './AcmeCertificatesPanel';
import { acmeCertificatesApi } from '../../services/api/acmeCertificatesApi';
import { acmeDnsCredentialsApi } from '../../services/api/acmeDnsCredentialsApi';
import type { AcmeCertificateSummary } from '../../types/acme.types';

// =============================================================================
// Mocks
// =============================================================================

jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { type: string; id: string; label?: string; className?: string }) => (
    <span data-testid="entity-link">{label}</span>
  ),
}));

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

// Mock the API facades directly — the component imports these as named objects.
jest.mock('../../services/api/acmeCertificatesApi', () => ({
  acmeCertificatesApi: {
    list: jest.fn(),
    requestIssue: jest.fn(),
    renew: jest.fn(),
    revoke: jest.fn(),
    destroy: jest.fn(),
    create: jest.fn(),
    get: jest.fn(),
  },
}));

jest.mock('../../services/api/acmeDnsCredentialsApi', () => ({
  acmeDnsCredentialsApi: {
    list: jest.fn(),
  },
}));

// Modal — render children through so form fields are accessible.
jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({
    isOpen,
    children,
    footer,
    title,
  }: {
    isOpen: boolean;
    children: React.ReactNode;
    footer?: React.ReactNode;
    title?: React.ReactNode;
  }) =>
    isOpen ? (
      <div data-testid="modal">
        {title && <div data-testid="modal-title">{title}</div>}
        {children}
        {footer && <div data-testid="modal-footer">{footer}</div>}
      </div>
    ) : null,
}));

// Button — render as plain button so click events work.
jest.mock('@/shared/components/ui/Button', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    variant,
  }: {
    children: React.ReactNode;
    onClick?: React.MouseEventHandler;
    disabled?: boolean;
    variant?: string;
  }) => (
    <button onClick={onClick} disabled={disabled} data-variant={variant}>
      {children}
    </button>
  ),
}));

// =============================================================================
// Typed mock helpers
// =============================================================================

const mockList = acmeCertificatesApi.list as jest.Mock;
const mockRequestIssue = acmeCertificatesApi.requestIssue as jest.Mock;
const mockRenew = acmeCertificatesApi.renew as jest.Mock;
const mockRevoke = acmeCertificatesApi.revoke as jest.Mock;
const mockDestroy = acmeCertificatesApi.destroy as jest.Mock;
const mockCreate = acmeCertificatesApi.create as jest.Mock;
const mockDnsCredsList = acmeDnsCredentialsApi.list as jest.Mock;

// =============================================================================
// Fixtures
// =============================================================================

const PENDING_CERT: AcmeCertificateSummary = {
  id: 'cert-pending-1',
  common_name: 'dev.powernode.net',
  sans: [],
  status: 'pending',
  issuer: 'letsencrypt-staging',
  challenge_type: 'dns-01',
  dns_credential_id: 'cred-123',
  issued_at: null,
  expires_at: null,
  days_until_expiry: null,
  created_at: '2026-06-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
  vault_paths_present: false,
  terminal: false,
  last_renewal_error: null,
};

const VALID_CERT: AcmeCertificateSummary = {
  id: 'cert-valid-1',
  common_name: 'prod.powernode.net',
  sans: ['www.prod.powernode.net', 'api.prod.powernode.net'],
  status: 'valid',
  issuer: 'letsencrypt-prod',
  challenge_type: 'dns-01',
  dns_credential_id: 'cred-456',
  issued_at: '2026-05-01T00:00:00Z',
  expires_at: '2026-08-01T00:00:00Z',
  days_until_expiry: 57,
  created_at: '2026-05-01T00:00:00Z',
  updated_at: '2026-05-01T00:00:00Z',
  vault_paths_present: true,
  terminal: false,
  last_renewal_error: null,
};

const FAILED_CERT: AcmeCertificateSummary = {
  id: 'cert-failed-1',
  common_name: 'fail.powernode.net',
  sans: [],
  status: 'failed',
  issuer: 'letsencrypt-staging',
  challenge_type: 'dns-01',
  dns_credential_id: 'cred-123',
  issued_at: null,
  expires_at: null,
  days_until_expiry: null,
  created_at: '2026-06-02T00:00:00Z',
  updated_at: '2026-06-02T00:00:00Z',
  vault_paths_present: false,
  terminal: false,
  last_renewal_error: 'DNS-01 challenge failed: NXDOMAIN',
};

const EXPIRED_CERT: AcmeCertificateSummary = {
  id: 'cert-expired-1',
  common_name: 'old.powernode.net',
  sans: [],
  status: 'expired',
  issuer: 'letsencrypt-prod',
  challenge_type: 'dns-01',
  dns_credential_id: 'cred-456',
  issued_at: '2025-01-01T00:00:00Z',
  expires_at: '2025-04-01T00:00:00Z',
  days_until_expiry: -60,
  created_at: '2025-01-01T00:00:00Z',
  updated_at: '2025-04-01T00:00:00Z',
  vault_paths_present: true,
  terminal: true,
  last_renewal_error: null,
};

const REVOKED_CERT: AcmeCertificateSummary = {
  id: 'cert-revoked-1',
  common_name: 'revoked.powernode.net',
  sans: [],
  status: 'revoked',
  issuer: 'letsencrypt-prod',
  challenge_type: 'dns-01',
  dns_credential_id: null,
  issued_at: '2026-01-01T00:00:00Z',
  expires_at: '2026-04-01T00:00:00Z',
  days_until_expiry: null,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-04-01T00:00:00Z',
  vault_paths_present: false,
  terminal: true,
  last_renewal_error: null,
};

const RENEWING_CERT: AcmeCertificateSummary = {
  id: 'cert-renewing-1',
  common_name: 'renewing.powernode.net',
  sans: [],
  status: 'renewing',
  issuer: 'letsencrypt-prod',
  challenge_type: 'dns-01',
  dns_credential_id: 'cred-456',
  issued_at: '2026-01-01T00:00:00Z',
  expires_at: '2026-04-01T00:00:00Z',
  days_until_expiry: 15,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
  vault_paths_present: true,
  terminal: false,
  last_renewal_error: null,
};

function makeListResponse(
  certificates: AcmeCertificateSummary[],
  issuers: string[] = ['letsencrypt-staging', 'letsencrypt-prod'],
) {
  return {
    certificates,
    count: certificates.length,
    issuers,
  };
}

function makeActionResponse(cert: AcmeCertificateSummary) {
  return {
    ok: true,
    certificate: { ...cert, dns_credential_name: null, dns_credential_provider: null, traefik_resolver_name: null, metadata: {} },
  };
}

const DNS_CREDS_RESPONSE = {
  credentials: [
    {
      id: 'cred-123',
      name: 'CF Prod',
      provider: 'cloudflare',
      status: 'valid',
      last_validated_at: '2026-06-01T00:00:00Z',
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-06-01T00:00:00Z',
      needs_revalidation: false,
    },
  ],
  count: 1,
  supported_providers: [],
};

// =============================================================================
// Render helper
// =============================================================================

const renderPanel = (props: { refreshKey?: number } = {}) =>
  render(
    <BrowserRouter>
      <AcmeCertificatesPanel {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('AcmeCertificatesPanel', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    // Default DNS creds for modal tests
    mockDnsCredsList.mockResolvedValue(DNS_CREDS_RESPONSE);
    // Restore window.confirm / prompt
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    jest.spyOn(window, 'prompt').mockReturnValue('');
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  // ---------------------------------------------------------------------------
  // Loading / render states
  // ---------------------------------------------------------------------------

  it('shows "loading…" while the fetch is in flight', () => {
    // Never resolves during this test
    mockList.mockReturnValue(new Promise(() => {}));
    renderPanel();
    expect(screen.getByText('loading…')).toBeInTheDocument();
  });

  it('renders the Certificates header and count after load', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT, PENDING_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('2 certificates')).toBeInTheDocument(),
    );
    expect(screen.getByText('Certificates')).toBeInTheDocument();
  });

  it('renders singular "certificate" for exactly one cert', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('1 certificate')).toBeInTheDocument(),
    );
  });

  it('renders empty state when no certificates exist', async () => {
    mockList.mockResolvedValue(makeListResponse([]));
    renderPanel();
    await waitFor(() =>
      expect(
        screen.getByText(/No certificates yet/i),
      ).toBeInTheDocument(),
    );
  });

  it('shows an error notification when the list fetch fails', async () => {
    mockList.mockRejectedValue(new Error('Network error'));
    renderPanel();
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Network error',
      }),
    );
  });

  it('shows a fallback error message for non-Error rejections', async () => {
    mockList.mockRejectedValue('boom');
    renderPanel();
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load certificates',
      }),
    );
  });

  it('calls acmeCertificatesApi.list with no params on initial mount', async () => {
    mockList.mockResolvedValue(makeListResponse([]));
    renderPanel();
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
    expect(mockList).toHaveBeenCalledWith();
  });

  it('re-fetches when refreshKey changes', async () => {
    mockList.mockResolvedValue(makeListResponse([]));
    const { rerender } = renderPanel({ refreshKey: 0 });
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
    rerender(
      <BrowserRouter>
        <AcmeCertificatesPanel refreshKey={1} />
      </BrowserRouter>,
    );
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Table rendering
  // ---------------------------------------------------------------------------

  it('renders domain names in the table', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT, PENDING_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('prod.powernode.net')).toBeInTheDocument());
    expect(screen.getByText('dev.powernode.net')).toBeInTheDocument();
  });

  it('renders SAN count summary when cert has SANs', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText(/\+2 SANs:/)).toBeInTheDocument(),
    );
    expect(screen.getByText(/www\.prod\.powernode\.net/)).toBeInTheDocument();
  });

  it('renders issuer in table row', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getAllByText('letsencrypt-prod').length).toBeGreaterThan(0));
  });

  it('renders expiry date and "in Nd" when days_until_expiry > 0', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('in 57d')).toBeInTheDocument(),
    );
  });

  it('renders "expired Nd ago" when days_until_expiry < 0', async () => {
    mockList.mockResolvedValue(makeListResponse([EXPIRED_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('expired 60d ago')).toBeInTheDocument(),
    );
  });

  it('renders em-dash for expires_at when cert has not been issued yet', async () => {
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('dev.powernode.net')).toBeInTheDocument());
    // The em-dash renders as a span child
    expect(screen.getByText('—')).toBeInTheDocument();
  });

  it('shows the last_renewal_error text in the status cell', async () => {
    mockList.mockResolvedValue(makeListResponse([FAILED_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('DNS-01 challenge failed: NXDOMAIN')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Status pills
  // ---------------------------------------------------------------------------

  it('renders the "pending" status pill', async () => {
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('pending')).toBeInTheDocument());
  });

  it('renders the "valid" status pill', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('valid')).toBeInTheDocument());
  });

  it('renders the "failed" status pill', async () => {
    mockList.mockResolvedValue(makeListResponse([FAILED_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('failed')).toBeInTheDocument());
  });

  it('renders the "expired" status pill', async () => {
    mockList.mockResolvedValue(makeListResponse([EXPIRED_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('expired')).toBeInTheDocument());
  });

  it('renders the "revoked" status pill', async () => {
    mockList.mockResolvedValue(makeListResponse([REVOKED_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('revoked')).toBeInTheDocument());
  });

  it('renders the "renewing" status pill', async () => {
    mockList.mockResolvedValue(makeListResponse([RENEWING_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('renewing')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Action button visibility rules
  // ---------------------------------------------------------------------------

  it('shows Issue button for a pending cert', async () => {
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByTitle('Request ACME issuance')).toBeInTheDocument());
    expect(screen.getByTitle('Request ACME issuance')).toHaveTextContent('Issue');
  });

  it('shows Retry button for a failed cert (not Issue)', async () => {
    mockList.mockResolvedValue(makeListResponse([FAILED_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByTitle('Request ACME issuance')).toBeInTheDocument());
    expect(screen.getByTitle('Request ACME issuance')).toHaveTextContent('Retry');
  });

  it('shows Renew button only for valid cert', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(
        screen.getByTitle('Renew now (force ACME renewal — same account key, fresh cert)'),
      ).toBeInTheDocument(),
    );
    expect(
      screen.queryByTitle('Request ACME issuance'),
    ).not.toBeInTheDocument();
  });

  it('shows Revoke button for a valid cert that is not terminal', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByTitle('Revoke certificate')).toBeInTheDocument(),
    );
  });

  it('shows Revoke button for renewing cert', async () => {
    mockList.mockResolvedValue(makeListResponse([RENEWING_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByTitle('Revoke certificate')).toBeInTheDocument(),
    );
  });

  it('does NOT show Revoke button for a terminal expired cert', async () => {
    mockList.mockResolvedValue(makeListResponse([EXPIRED_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('old.powernode.net')).toBeInTheDocument());
    expect(screen.queryByTitle('Revoke certificate')).not.toBeInTheDocument();
  });

  it('shows Delete button for a pending cert', async () => {
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByTitle('Delete row')).toBeInTheDocument(),
    );
  });

  it('shows Delete button for a terminal cert (expired)', async () => {
    mockList.mockResolvedValue(makeListResponse([EXPIRED_CERT]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByTitle('Delete row')).toBeInTheDocument(),
    );
  });

  it('does NOT show Delete button for valid cert (not terminal, not pending/failed)', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('prod.powernode.net')).toBeInTheDocument());
    expect(screen.queryByTitle('Delete row')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // handleRequestIssue
  // ---------------------------------------------------------------------------

  it('calls acmeCertificatesApi.requestIssue with cert id on Issue click after confirm', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));
    mockRequestIssue.mockResolvedValue(makeActionResponse(PENDING_CERT));

    renderPanel();
    const issueBtn = await waitFor(() => screen.getByTitle('Request ACME issuance'));
    fireEvent.click(issueBtn);

    await waitFor(() =>
      expect(mockRequestIssue).toHaveBeenCalledWith('cert-pending-1'),
    );
    // After action, list is refreshed
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  it('does NOT call requestIssue if user cancels the confirm dialog', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(false);
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));

    renderPanel();
    const issueBtn = await waitFor(() => screen.getByTitle('Request ACME issuance'));
    fireEvent.click(issueBtn);

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
    expect(mockRequestIssue).not.toHaveBeenCalled();
  });

  it('shows error notification when requestIssue fails', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));
    mockRequestIssue.mockRejectedValue(new Error('ACME timeout'));

    renderPanel();
    const issueBtn = await waitFor(() => screen.getByTitle('Request ACME issuance'));
    fireEvent.click(issueBtn);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'ACME timeout',
      }),
    );
    // List is still refreshed even on error
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  it('confirm dialog for Issue contains the common_name and issuer', async () => {
    const confirmSpy = jest.spyOn(window, 'confirm').mockReturnValue(false);
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));

    renderPanel();
    const issueBtn = await waitFor(() => screen.getByTitle('Request ACME issuance'));
    fireEvent.click(issueBtn);

    expect(confirmSpy).toHaveBeenCalledWith(
      expect.stringContaining('dev.powernode.net'),
    );
    expect(confirmSpy).toHaveBeenCalledWith(
      expect.stringContaining('letsencrypt-staging'),
    );
  });

  // ---------------------------------------------------------------------------
  // handleRenew
  // ---------------------------------------------------------------------------

  it('calls acmeCertificatesApi.renew with cert id on Renew click after confirm', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    mockRenew.mockResolvedValue(makeActionResponse(VALID_CERT));

    renderPanel();
    const renewBtn = await waitFor(() =>
      screen.getByTitle('Renew now (force ACME renewal — same account key, fresh cert)'),
    );
    fireEvent.click(renewBtn);

    await waitFor(() =>
      expect(mockRenew).toHaveBeenCalledWith('cert-valid-1'),
    );
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  it('does NOT call renew if user cancels the confirm dialog', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(false);
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));

    renderPanel();
    const renewBtn = await waitFor(() =>
      screen.getByTitle('Renew now (force ACME renewal — same account key, fresh cert)'),
    );
    fireEvent.click(renewBtn);

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
    expect(mockRenew).not.toHaveBeenCalled();
  });

  it('shows error notification when renew fails', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    mockRenew.mockRejectedValue(new Error('LE rate limit'));

    renderPanel();
    const renewBtn = await waitFor(() =>
      screen.getByTitle('Renew now (force ACME renewal — same account key, fresh cert)'),
    );
    fireEvent.click(renewBtn);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'LE rate limit',
      }),
    );
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // handleRevoke
  // ---------------------------------------------------------------------------

  it('calls acmeCertificatesApi.revoke with cert id and reason on Revoke click', async () => {
    jest.spyOn(window, 'prompt').mockReturnValue('security breach');
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    mockRevoke.mockResolvedValue(makeActionResponse({ ...VALID_CERT, status: 'revoked' }));

    renderPanel();
    const revokeBtn = await waitFor(() => screen.getByTitle('Revoke certificate'));
    fireEvent.click(revokeBtn);

    await waitFor(() =>
      expect(mockRevoke).toHaveBeenCalledWith('cert-valid-1', 'security breach'),
    );
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  it('calls revoke without reason when prompt returns empty string', async () => {
    jest.spyOn(window, 'prompt').mockReturnValue('');
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    mockRevoke.mockResolvedValue(makeActionResponse(VALID_CERT));

    renderPanel();
    const revokeBtn = await waitFor(() => screen.getByTitle('Revoke certificate'));
    fireEvent.click(revokeBtn);

    await waitFor(() =>
      expect(mockRevoke).toHaveBeenCalledWith('cert-valid-1', undefined),
    );
  });

  it('does NOT call revoke if user cancels the prompt (null)', async () => {
    jest.spyOn(window, 'prompt').mockReturnValue(null);
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));

    renderPanel();
    const revokeBtn = await waitFor(() => screen.getByTitle('Revoke certificate'));
    fireEvent.click(revokeBtn);

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
    expect(mockRevoke).not.toHaveBeenCalled();
  });

  it('shows error notification when revoke fails', async () => {
    jest.spyOn(window, 'prompt').mockReturnValue('test');
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    mockRevoke.mockRejectedValue(new Error('Revoke failed upstream'));

    renderPanel();
    const revokeBtn = await waitFor(() => screen.getByTitle('Revoke certificate'));
    fireEvent.click(revokeBtn);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Revoke failed upstream',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // handleDelete
  // ---------------------------------------------------------------------------

  it('calls acmeCertificatesApi.destroy with cert id after confirm', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));
    mockDestroy.mockResolvedValue(undefined);

    renderPanel();
    const deleteBtn = await waitFor(() => screen.getByTitle('Delete row'));
    fireEvent.click(deleteBtn);

    await waitFor(() =>
      expect(mockDestroy).toHaveBeenCalledWith('cert-pending-1'),
    );
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  it('does NOT call destroy if user cancels the confirm dialog', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(false);
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));

    renderPanel();
    const deleteBtn = await waitFor(() => screen.getByTitle('Delete row'));
    fireEvent.click(deleteBtn);

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));
    expect(mockDestroy).not.toHaveBeenCalled();
  });

  it('shows error notification when destroy fails', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));
    mockDestroy.mockRejectedValue(new Error('Delete failed'));

    renderPanel();
    const deleteBtn = await waitFor(() => screen.getByTitle('Delete row'));
    fireEvent.click(deleteBtn);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Delete failed',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse (click-to-expand)
  // ---------------------------------------------------------------------------

  it('toggles expanded row on chevron click', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();

    await waitFor(() => expect(screen.getByText('prod.powernode.net')).toBeInTheDocument());

    // Expanded row detail should not be visible initially
    expect(screen.queryByText('Certificate ID')).not.toBeInTheDocument();

    // Click expand chevron
    const expandBtn = screen.getByTitle('Expand details');
    fireEvent.click(expandBtn);

    await waitFor(() =>
      expect(screen.getByText('Certificate ID')).toBeInTheDocument(),
    );
    // cert id shown
    expect(screen.getByText('cert-valid-1')).toBeInTheDocument();

    // Click collapse
    const collapseBtn = screen.getByTitle('Collapse details');
    fireEvent.click(collapseBtn);

    await waitFor(() =>
      expect(screen.queryByText('Certificate ID')).not.toBeInTheDocument(),
    );
  });

  it('shows vault_paths_present indicator in expanded row', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();

    await waitFor(() => expect(screen.getByText('prod.powernode.net')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Present in Vault')).toBeInTheDocument(),
    );
  });

  it('shows "Not yet stored" in expanded row when vault_paths_present is false', async () => {
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));
    renderPanel();

    await waitFor(() => expect(screen.getByText('dev.powernode.net')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Not yet stored')).toBeInTheDocument(),
    );
  });

  it('renders EntityLink for dns_credential_id in expanded row', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();

    await waitFor(() => expect(screen.getByText('prod.powernode.net')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByTestId('entity-link')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('entity-link')).toHaveTextContent('cred-456');
  });

  it('shows em-dash for DNS credential when dns_credential_id is null in expanded row', async () => {
    mockList.mockResolvedValue(makeListResponse([REVOKED_CERT]));
    renderPanel();

    await waitFor(() => expect(screen.getByText('revoked.powernode.net')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('DNS Credential')).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('entity-link')).not.toBeInTheDocument();
  });

  it('shows last_renewal_error in expanded row', async () => {
    mockList.mockResolvedValue(makeListResponse([FAILED_CERT]));
    renderPanel();

    await waitFor(() => expect(screen.getByText('fail.powernode.net')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Last Renewal Error')).toBeInTheDocument(),
    );
    // Error text appears both inline (status cell) and in expanded section
    expect(screen.getAllByText('DNS-01 challenge failed: NXDOMAIN').length).toBeGreaterThan(0);
  });

  it('shows "None" for SANs in expanded row when cert has no SANs', async () => {
    mockList.mockResolvedValue(makeListResponse([PENDING_CERT]));
    renderPanel();

    await waitFor(() => expect(screen.getByText('dev.powernode.net')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('None')).toBeInTheDocument(),
    );
  });

  it('shows challenge type in expanded row', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();

    await waitFor(() => expect(screen.getByText('prod.powernode.net')).toBeInTheDocument());
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('dns-01')).toBeInTheDocument(),
    );
  });

  it('can expand multiple rows simultaneously', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT, PENDING_CERT]));
    renderPanel();

    await waitFor(() => expect(screen.getAllByTitle('Expand details').length).toBe(2));

    // Expand both rows
    const expandBtns = screen.getAllByTitle('Expand details');
    fireEvent.click(expandBtns[0]);
    fireEvent.click(expandBtns[1]);

    // Both should now show collapse title
    await waitFor(() =>
      expect(screen.getAllByTitle('Collapse details').length).toBe(2),
    );
  });

  // ---------------------------------------------------------------------------
  // "Request certificate" modal
  // ---------------------------------------------------------------------------

  it('opens the RequestCertificateModal when "Request certificate" button is clicked', async () => {
    mockList.mockResolvedValue(makeListResponse([]));
    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('Request certificate')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('Request certificate'));

    await waitFor(() =>
      expect(screen.getByTestId('modal')).toBeInTheDocument(),
    );
  });

  it('passes issuers from the list response to the modal as availableIssuers', async () => {
    mockList.mockResolvedValue(
      makeListResponse([], ['letsencrypt-staging', 'letsencrypt-prod']),
    );
    // Modal needs DNS creds to show form
    mockDnsCredsList.mockResolvedValue(DNS_CREDS_RESPONSE);

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('Request certificate')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('Request certificate'));

    await waitFor(() => expect(screen.getByTestId('modal')).toBeInTheDocument());
    // issuer select options come from availableIssuers
    await waitFor(() => {
      const options = screen.getAllByRole('option');
      const texts = options.map((o) => o.textContent);
      expect(texts).toContain('letsencrypt-staging');
      expect(texts).toContain('letsencrypt-prod');
    });
  });

  it('refreshes the cert list after modal submits successfully', async () => {
    mockList.mockResolvedValue(makeListResponse([]));
    mockDnsCredsList.mockResolvedValue(DNS_CREDS_RESPONSE);

    const CREATED_CERT = {
      ...PENDING_CERT,
      id: 'cert-new-1',
      dns_credential_name: null,
      dns_credential_provider: null,
      traefik_resolver_name: null,
      metadata: {},
    };
    mockCreate.mockResolvedValue(CREATED_CERT);
    mockRequestIssue.mockResolvedValue(makeActionResponse(PENDING_CERT));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('Request certificate')).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByText('Request certificate'));

    // Wait for modal and form to be available
    await waitFor(() => expect(screen.getByTestId('modal')).toBeInTheDocument());
    await waitFor(() => expect(mockDnsCredsList).toHaveBeenCalled());

    // Fill in the form
    fireEvent.change(
      screen.getByPlaceholderText('dev.powernode.net'),
      { target: { value: 'test.example.com' } },
    );
    fireEvent.change(
      screen.getByPlaceholderText('ops@your-domain.tld'),
      { target: { value: 'ops@example.com' } },
    );

    // DNS credential select — auto-selected because there's exactly one valid cred
    // Click Issue certificate button
    const issueBtn = screen.getByRole('button', { name: /Issue certificate/i });
    fireEvent.click(issueBtn);

    await waitFor(() => expect(mockCreate).toHaveBeenCalledWith(
      expect.objectContaining({
        common_name: 'test.example.com',
        acme_email: 'ops@example.com',
        dns_credential_id: 'cred-123',
      }),
    ));

    await waitFor(() => expect(mockRequestIssue).toHaveBeenCalledWith('cert-new-1'));
    // Panel list should have been refreshed (2nd call: initial + after modal)
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });

  // ---------------------------------------------------------------------------
  // Days-until-expiry warning threshold
  // ---------------------------------------------------------------------------

  it('applies warning color class for certs expiring in < 30 days', async () => {
    const soonCert: AcmeCertificateSummary = {
      ...VALID_CERT,
      id: 'cert-soon-1',
      days_until_expiry: 10,
      expires_at: '2026-06-15T00:00:00Z',
    };
    mockList.mockResolvedValue(makeListResponse([soonCert]));
    renderPanel();

    await waitFor(() => expect(screen.getByText('in 10d')).toBeInTheDocument());
    const el = screen.getByText('in 10d');
    expect(el.className).toContain('text-theme-warning-fg');
  });

  it('applies tertiary color class for certs expiring in >= 30 days', async () => {
    mockList.mockResolvedValue(makeListResponse([VALID_CERT]));
    renderPanel();

    await waitFor(() => expect(screen.getByText('in 57d')).toBeInTheDocument());
    const el = screen.getByText('in 57d');
    expect(el.className).toContain('text-theme-tertiary');
  });
});
