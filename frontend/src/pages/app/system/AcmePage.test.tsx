import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import AcmePage from './AcmePage';

// =============================================================================
// Mocks
//
// AcmePage is a thin routing/permission hub. It mounts AcmeDnsCredentialsPanel
// and AcmeCertificatesPanel as child routes gated by two permissions. We stub
// both child panels so tests isolate the page's own routing/permission logic,
// and stub the shared hooks so no real backend is needed.
// =============================================================================

const mockHasPermission = jest.fn<boolean, [string]>();

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (p: string) => mockHasPermission(p),
  }),
}));

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: jest.fn(),
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

// Stub child panels — they each call their own APIs which are covered in
// their own dedicated test files.
jest.mock(
  '@system/features/system/components/acme/AcmeDnsCredentialsPanel',
  () => ({
    AcmeDnsCredentialsPanel: () => (
      <div data-testid="dns-credentials-panel">DNS Credentials Panel</div>
    ),
  }),
);

jest.mock(
  '@system/features/system/components/acme/AcmeCertificatesPanel',
  () => ({
    AcmeCertificatesPanel: () => (
      <div data-testid="certificates-panel">Certificates Panel</div>
    ),
  }),
);

// =============================================================================
// Helpers
// =============================================================================

/**
 * Render AcmePage inside a MemoryRouter with the route structure matching
 * the real app: `/app/system/acme/*`. The initialPath lets tests simulate
 * landing on a specific sub-path.
 */
const renderPage = (initialPath = '/app/system/acme') =>
  render(
    <MemoryRouter initialEntries={[initialPath]}>
      <Routes>
        <Route path="/app/system/acme/*" element={<AcmePage />} />
      </Routes>
    </MemoryRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('AcmePage', () => {
  beforeEach(() => {
    mockHasPermission.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Page title + description
  // ---------------------------------------------------------------------------

  it('renders the page title "ACME" when user has at least one permission', () => {
    mockHasPermission.mockImplementation(() => true);

    renderPage();

    expect(screen.getByText('ACME')).toBeInTheDocument();
  });

  it('renders the full description including DNS-01 mention when user has access', () => {
    mockHasPermission.mockImplementation(() => true);

    renderPage();

    expect(
      screen.getByText(/DNS-01 challenges automatically/i),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permission-denied state (no permissions)
  // ---------------------------------------------------------------------------

  it('renders a permission-denied message when user has neither permission', () => {
    mockHasPermission.mockReturnValue(false);

    renderPage();

    expect(
      screen.getByText(/You don't have permission to view any ACME resources/i),
    ).toBeInTheDocument();
  });

  it('mentions both required permission codes in the denied state', () => {
    mockHasPermission.mockReturnValue(false);

    renderPage();

    expect(screen.getByText('system.acme_dns.read')).toBeInTheDocument();
    expect(screen.getByText('system.acme.read')).toBeInTheDocument();
  });

  it('still renders the page title "ACME" in the denied state', () => {
    mockHasPermission.mockReturnValue(false);

    renderPage();

    expect(screen.getByText('ACME')).toBeInTheDocument();
  });

  it('does not render any tab links in the denied state', () => {
    mockHasPermission.mockReturnValue(false);

    renderPage();

    expect(screen.queryByText('DNS Credentials')).not.toBeInTheDocument();
    expect(screen.queryByText('Certificates')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tab rendering — both permissions
  // ---------------------------------------------------------------------------

  it('renders both tab links when user has both permissions', () => {
    mockHasPermission.mockReturnValue(true);

    renderPage();

    expect(screen.getByText('DNS Credentials')).toBeInTheDocument();
    expect(screen.getByText('Certificates')).toBeInTheDocument();
  });

  it('DNS Credentials tab links to /app/system/acme/dns-credentials', () => {
    mockHasPermission.mockReturnValue(true);

    renderPage();

    const dnsLink = screen.getByRole('link', { name: /DNS Credentials/i });
    expect(dnsLink).toHaveAttribute('href', '/app/system/acme/dns-credentials');
  });

  it('Certificates tab links to /app/system/acme/certificates', () => {
    mockHasPermission.mockReturnValue(true);

    renderPage();

    const certLink = screen.getByRole('link', { name: /Certificates/i });
    expect(certLink).toHaveAttribute('href', '/app/system/acme/certificates');
  });

  // ---------------------------------------------------------------------------
  // Tab rendering — only dns-credentials permission
  // ---------------------------------------------------------------------------

  it('renders only the DNS Credentials tab when user lacks system.acme.read', () => {
    mockHasPermission.mockImplementation(
      (p) => p === 'system.acme_dns.read',
    );

    renderPage();

    expect(screen.getByText('DNS Credentials')).toBeInTheDocument();
    expect(screen.queryByText('Certificates')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Tab rendering — only certificates permission
  // ---------------------------------------------------------------------------

  it('renders only the Certificates tab when user lacks system.acme_dns.read', () => {
    mockHasPermission.mockImplementation(
      (p) => p === 'system.acme.read',
    );

    renderPage();

    expect(screen.queryByText('DNS Credentials')).not.toBeInTheDocument();
    expect(screen.getByText('Certificates')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Default redirect — both permissions
  // ---------------------------------------------------------------------------

  it('redirects the root path to dns-credentials (first tab) when both permissions are held', async () => {
    mockHasPermission.mockReturnValue(true);

    renderPage('/app/system/acme');

    await waitFor(() =>
      expect(screen.getByTestId('dns-credentials-panel')).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('certificates-panel')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Default redirect — only certificates permission
  // ---------------------------------------------------------------------------

  it('redirects to certificates when only system.acme.read is held', async () => {
    mockHasPermission.mockImplementation(
      (p) => p === 'system.acme.read',
    );

    renderPage('/app/system/acme');

    await waitFor(() =>
      expect(screen.getByTestId('certificates-panel')).toBeInTheDocument(),
    );
    expect(screen.queryByTestId('dns-credentials-panel')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Child panel routing — explicit paths
  // ---------------------------------------------------------------------------

  it('mounts AcmeDnsCredentialsPanel at /app/system/acme/dns-credentials', async () => {
    mockHasPermission.mockReturnValue(true);

    renderPage('/app/system/acme/dns-credentials');

    await waitFor(() =>
      expect(screen.getByTestId('dns-credentials-panel')).toBeInTheDocument(),
    );
  });

  it('mounts AcmeCertificatesPanel at /app/system/acme/certificates', async () => {
    mockHasPermission.mockReturnValue(true);

    renderPage('/app/system/acme/certificates');

    await waitFor(() =>
      expect(screen.getByTestId('certificates-panel')).toBeInTheDocument(),
    );
  });

  it('redirects an unknown sub-path to the first accessible tab', async () => {
    mockHasPermission.mockReturnValue(true);

    renderPage('/app/system/acme/unknown-path');

    await waitFor(() =>
      expect(screen.getByTestId('dns-credentials-panel')).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Active-tab styling
  // ---------------------------------------------------------------------------

  it('marks the dns-credentials tab as active when on that route', async () => {
    mockHasPermission.mockReturnValue(true);

    renderPage('/app/system/acme/dns-credentials');

    await waitFor(() =>
      expect(screen.getByTestId('dns-credentials-panel')).toBeInTheDocument(),
    );

    // The active tab gets `border-theme-info` class (from PathTabs implementation)
    const dnsLink = screen.getByRole('link', { name: /DNS Credentials/i });
    expect(dnsLink.className).toContain('border-theme-info');
  });

  it('marks the certificates tab as active when on that route', async () => {
    mockHasPermission.mockReturnValue(true);

    renderPage('/app/system/acme/certificates');

    await waitFor(() =>
      expect(screen.getByTestId('certificates-panel')).toBeInTheDocument(),
    );

    const certLink = screen.getByRole('link', { name: /Certificates/i });
    expect(certLink.className).toContain('border-theme-info');
  });

  it('does not mark the inactive tab as active', async () => {
    mockHasPermission.mockReturnValue(true);

    renderPage('/app/system/acme/dns-credentials');

    await waitFor(() =>
      expect(screen.getByTestId('dns-credentials-panel')).toBeInTheDocument(),
    );

    const certLink = screen.getByRole('link', { name: /Certificates/i });
    expect(certLink.className).not.toContain('border-theme-info');
  });

  // ---------------------------------------------------------------------------
  // Permission check calls
  // ---------------------------------------------------------------------------

  it('checks system.acme_dns.read and system.acme.read permissions', () => {
    mockHasPermission.mockReturnValue(true);

    renderPage();

    const checkedPerms = mockHasPermission.mock.calls.map(([p]) => p);
    expect(checkedPerms).toContain('system.acme_dns.read');
    expect(checkedPerms).toContain('system.acme.read');
  });
});
