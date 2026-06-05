import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { RequestCertificateModal } from './RequestCertificateModal';

// =============================================================================
// Mocks
//
// The component calls the two ACME API facades directly (not apiClient).
// We mock those facades so tests remain isolated from HTTP.
// =============================================================================

const mockDnsCredsList = jest.fn();
const mockCertificatesCreate = jest.fn();
const mockCertificatesRequestIssue = jest.fn();

jest.mock('@system/features/system/services/api/acmeDnsCredentialsApi', () => ({
  acmeDnsCredentialsApi: {
    list: (...args: unknown[]) => mockDnsCredsList(...args),
  },
}));

jest.mock('@system/features/system/services/api/acmeCertificatesApi', () => ({
  acmeCertificatesApi: {
    create: (...args: unknown[]) => mockCertificatesCreate(...args),
    requestIssue: (...args: unknown[]) => mockCertificatesRequestIssue(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const CRED_VALID = {
  id: 'cred-1',
  name: 'Cloudflare Prod',
  provider: 'cloudflare' as const,
  status: 'valid' as const,
  last_validated_at: '2026-06-01T00:00:00Z',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-06-01T00:00:00Z',
  needs_revalidation: false,
};

const CRED_INVALID = {
  id: 'cred-2',
  name: 'Route53 Dev',
  provider: 'route53' as const,
  status: 'invalid' as const,
  last_validated_at: null,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
  needs_revalidation: true,
};

const CRED_VALID_2 = {
  id: 'cred-3',
  name: 'Hetzner Staging',
  provider: 'hetzner' as const,
  status: 'valid' as const,
  last_validated_at: '2026-05-20T00:00:00Z',
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-05-20T00:00:00Z',
  needs_revalidation: false,
};

function makeDnsListResponse(creds: typeof CRED_VALID[]) {
  return {
    credentials: creds,
    count: creds.length,
    supported_providers: [],
  };
}

const CREATED_CERT = {
  id: 'cert-abc',
  common_name: 'dev.example.com',
  sans: [],
  status: 'pending' as const,
  issuer: 'letsencrypt-staging',
  challenge_type: 'dns-01' as const,
  dns_credential_id: 'cred-1',
  issued_at: null,
  expires_at: null,
  days_until_expiry: null,
  created_at: '2026-06-05T00:00:00Z',
  updated_at: '2026-06-05T00:00:00Z',
  vault_paths_present: false,
  terminal: false,
  last_renewal_error: null,
  dns_credential_name: 'Cloudflare Prod',
  dns_credential_provider: 'cloudflare',
  traefik_resolver_name: null,
  metadata: {},
};

const ISSUERS = ['letsencrypt-staging', 'letsencrypt-prod'];

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  onClose?: jest.Mock;
  onRequested?: jest.Mock;
  availableIssuers?: string[];
}

function renderModal({
  isOpen = true,
  onClose = jest.fn(),
  onRequested = jest.fn(),
  availableIssuers = ISSUERS,
}: RenderProps = {}) {
  return render(
    <RequestCertificateModal
      isOpen={isOpen}
      onClose={onClose}
      onRequested={onRequested}
      availableIssuers={availableIssuers}
    />,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('RequestCertificateModal', () => {
  beforeEach(() => {
    mockDnsCredsList.mockReset();
    mockCertificatesCreate.mockReset();
    mockCertificatesRequestIssue.mockReset();
  });

  // --------------------------------------------------------------------------
  // Render / initial state
  // --------------------------------------------------------------------------

  describe('rendering', () => {
    it('renders nothing when isOpen is false', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal({ isOpen: false });
      expect(screen.queryByText('Request certificate')).not.toBeInTheDocument();
    });

    it('renders the form when isOpen is true', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal();
      await waitFor(() =>
        expect(screen.getByText('Request certificate')).toBeInTheDocument(),
      );
      expect(screen.getByPlaceholderText('dev.powernode.net')).toBeInTheDocument();
      expect(screen.getByPlaceholderText('alt.example.com, www.example.com')).toBeInTheDocument();
      expect(screen.getByPlaceholderText('ops@your-domain.tld')).toBeInTheDocument();
    });

    it('renders Cancel and Issue certificate buttons in form phase', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal();
      await waitFor(() =>
        expect(screen.getByText('Request certificate')).toBeInTheDocument(),
      );
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /issue certificate/i })).toBeInTheDocument();
    });

    it('shows issuer select with all availableIssuers as options', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal({ availableIssuers: ['letsencrypt-staging', 'letsencrypt-prod', 'internal-ca'] });
      await waitFor(() => screen.getByText('Request certificate'));
      const select = screen.getByDisplayValue('letsencrypt-staging');
      expect(select).toBeInTheDocument();
      expect(screen.getByRole('option', { name: 'letsencrypt-staging' })).toBeInTheDocument();
      expect(screen.getByRole('option', { name: 'letsencrypt-prod' })).toBeInTheDocument();
      expect(screen.getByRole('option', { name: 'internal-ca' })).toBeInTheDocument();
    });

    it('defaults issuer to letsencrypt-staging', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));
      const select = screen.getByDisplayValue('letsencrypt-staging');
      expect(select).toBeInTheDocument();
    });
  });

  // --------------------------------------------------------------------------
  // DNS credentials loading
  // --------------------------------------------------------------------------

  describe('DNS credentials loading', () => {
    it('fetches DNS credentials on open and shows only valid ones in the select', async () => {
      mockDnsCredsList.mockResolvedValue(
        makeDnsListResponse([CRED_VALID, CRED_INVALID]),
      );
      renderModal();
      await waitFor(() =>
        expect(screen.getByRole('option', { name: /Cloudflare Prod/i })).toBeInTheDocument(),
      );
      // invalid credential should NOT appear as an option
      expect(screen.queryByRole('option', { name: /Route53 Dev/i })).not.toBeInTheDocument();
    });

    it('shows no-credentials warning when zero valid credentials exist', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_INVALID]));
      renderModal();
      await waitFor(() =>
        expect(
          screen.getByText(/No valid DNS credentials/i),
        ).toBeInTheDocument(),
      );
      expect(screen.queryByRole('combobox', { name: /dns provider/i })).not.toBeInTheDocument();
    });

    it('auto-selects the only valid credential when exactly one exists', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal();
      await waitFor(() =>
        expect(
          screen.getByRole('option', { name: /Cloudflare Prod/i }),
        ).toBeInTheDocument(),
      );
      // The single valid cred should be auto-selected (not the placeholder)
      const select = screen.getAllByRole('combobox').find((el) =>
        el.textContent?.includes('Cloudflare Prod'),
      );
      expect(select).toBeTruthy();
    });

    it('does not auto-select when multiple valid credentials exist', async () => {
      mockDnsCredsList.mockResolvedValue(
        makeDnsListResponse([CRED_VALID, CRED_VALID_2]),
      );
      renderModal();
      await waitFor(() =>
        expect(screen.getByRole('option', { name: /Cloudflare Prod/i })).toBeInTheDocument(),
      );
      // placeholder should still be selected
      const select = screen.getAllByRole('combobox').find((el) =>
        el.textContent?.includes('-- pick one --'),
      );
      expect(select).toBeTruthy();
    });

    it('shows an error banner when DNS credentials fail to load', async () => {
      mockDnsCredsList.mockRejectedValue(new Error('Network error'));
      renderModal();
      await waitFor(() =>
        expect(screen.getByText('Network error')).toBeInTheDocument(),
      );
    });

    it('calls acmeDnsCredentialsApi.list with no arguments', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal();
      await waitFor(() => expect(mockDnsCredsList).toHaveBeenCalledTimes(1));
      expect(mockDnsCredsList).toHaveBeenCalledWith();
    });
  });

  // --------------------------------------------------------------------------
  // Issuer help text
  // --------------------------------------------------------------------------

  describe('issuer help text', () => {
    it('shows staging help text when letsencrypt-staging is selected', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));
      expect(
        screen.getByText(/Use for testing — generous rate limits/i),
      ).toBeInTheDocument();
    });

    it('shows prod help text when letsencrypt-prod is selected', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));

      const issuerSelect = screen.getAllByRole('combobox').find((el) =>
        el.textContent?.includes('letsencrypt-staging'),
      );
      expect(issuerSelect).toBeTruthy();
      fireEvent.change(issuerSelect!, { target: { value: 'letsencrypt-prod' } });

      await waitFor(() =>
        expect(
          screen.getByText(/Browser-trusted/i),
        ).toBeInTheDocument(),
      );
    });

    it('shows no help text when the user switches to an issuer without a ISSUER_HELP entry', async () => {
      // availableIssuers must include 'letsencrypt-staging' as the first option since
      // the component state defaults to that string unconditionally.
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal({ availableIssuers: ['letsencrypt-staging', 'internal-ca'] });
      await waitFor(() => screen.getByText('Request certificate'));

      // Switch to internal-ca which has no ISSUER_HELP entry
      const issuerSelect = screen.getAllByRole('combobox').find((el) =>
        el.textContent?.includes('letsencrypt-staging'),
      );
      fireEvent.change(issuerSelect!, { target: { value: 'internal-ca' } });

      await waitFor(() =>
        expect(screen.queryByText(/generous rate limits/i)).not.toBeInTheDocument(),
      );
      expect(screen.queryByText(/Browser-trusted/i)).not.toBeInTheDocument();
    });
  });

  // --------------------------------------------------------------------------
  // Validation / submit button disabled state
  // --------------------------------------------------------------------------

  describe('validation', () => {
    it('disables Issue certificate button until all required fields are filled', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));
      const btn = screen.getByRole('button', { name: /issue certificate/i });
      // Initial state: commonName empty, acmeEmail empty => disabled
      expect(btn).toBeDisabled();
    });

    it('enables submit button when commonName, acmeEmail, dnsCredId, and issuer are filled', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));

      // CRED_VALID is auto-selected (only one valid cred), issuer defaults to staging
      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'test.example.com' },
      });
      fireEvent.change(screen.getByPlaceholderText('ops@your-domain.tld'), {
        target: { value: 'ops@example.com' },
      });

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /issue certificate/i })).not.toBeDisabled(),
      );
    });

    it('shows validation error on submit when required fields are missing', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([]));
      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));

      // Click submit without filling fields — no valid cred either
      const btn = screen.getByRole('button', { name: /issue certificate/i });
      // Button is disabled so click via form submit
      const form = document.querySelector('form');
      if (form) {
        fireEvent.submit(form);
      }
      await waitFor(() =>
        expect(
          screen.getByText(/Fill all required fields/i),
        ).toBeInTheDocument(),
      );
    });

    it('dismisses the error banner when the X button is clicked', async () => {
      // Trigger an error via a failed DNS credentials load — that populates
      // the error state without needing to submit the form.
      mockDnsCredsList.mockRejectedValue(new Error('Failed to load DNS credentials'));
      renderModal();
      await waitFor(() =>
        expect(screen.getByText('Failed to load DNS credentials')).toBeInTheDocument(),
      );

      // The dismiss button is a plain <button type="button"> with no visible text
      // (only an X icon). It lives inside the error banner div.
      const allButtons = screen.getAllByRole('button');
      // Filter to find the icon-only button (no non-whitespace text content)
      const dismissBtn = allButtons.find(
        (b) => (b.textContent ?? '').trim() === '' && b.getAttribute('type') === 'button',
      );
      expect(dismissBtn).toBeTruthy();
      fireEvent.click(dismissBtn!);

      await waitFor(() =>
        expect(
          screen.queryByText('Failed to load DNS credentials'),
        ).not.toBeInTheDocument(),
      );
    });
  });

  // --------------------------------------------------------------------------
  // Form submission — success path
  // --------------------------------------------------------------------------

  describe('successful certificate request', () => {
    async function fillAndSubmit() {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      mockCertificatesCreate.mockResolvedValue(CREATED_CERT);
      mockCertificatesRequestIssue.mockResolvedValue({
        ok: true,
        certificate: { ...CREATED_CERT, status: 'valid' },
      });

      const onRequested = jest.fn();
      const onClose = jest.fn();
      renderModal({ onRequested, onClose });

      await waitFor(() => screen.getByText('Request certificate'));

      // Fill required fields
      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'dev.example.com' },
      });
      fireEvent.change(screen.getByPlaceholderText('ops@your-domain.tld'), {
        target: { value: 'ops@example.com' },
      });

      // Submit
      const btn = await waitFor(() => {
        const b = screen.getByRole('button', { name: /issue certificate/i });
        expect(b).not.toBeDisabled();
        return b;
      });
      fireEvent.click(btn);

      return { onRequested, onClose };
    }

    it('transitions to issuing phase immediately after submit', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      // Delay resolution so we can observe the issuing state
      let resolveCreate!: (v: unknown) => void;
      mockCertificatesCreate.mockReturnValue(
        new Promise((res) => { resolveCreate = res; }),
      );

      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));

      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'cert.example.com' },
      });
      fireEvent.change(screen.getByPlaceholderText('ops@your-domain.tld'), {
        target: { value: 'ops@example.com' },
      });

      const btn = await waitFor(() => {
        const b = screen.getByRole('button', { name: /issue certificate/i });
        expect(b).not.toBeDisabled();
        return b;
      });
      fireEvent.click(btn);

      await waitFor(() =>
        expect(screen.getByText(/Issuing certificate/i)).toBeInTheDocument(),
      );
      expect(screen.getByText(/ACME ceremony is running/i)).toBeInTheDocument();

      // Clean up pending promise
      act(() => resolveCreate(CREATED_CERT));
    });

    it('shows Done disabled button during issuing phase', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      let resolveCreate!: (v: unknown) => void;
      mockCertificatesCreate.mockReturnValue(
        new Promise((res) => { resolveCreate = res; }),
      );

      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));

      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'cert.example.com' },
      });
      fireEvent.change(screen.getByPlaceholderText('ops@your-domain.tld'), {
        target: { value: 'ops@example.com' },
      });

      const btn = await waitFor(() => {
        const b = screen.getByRole('button', { name: /issue certificate/i });
        expect(b).not.toBeDisabled();
        return b;
      });
      fireEvent.click(btn);

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /done/i })).toBeDisabled(),
      );

      act(() => resolveCreate(CREATED_CERT));
    });

    it('calls acmeCertificatesApi.create with correct payload', async () => {
      const { onRequested } = await fillAndSubmit();
      await waitFor(() => expect(onRequested).toHaveBeenCalled());

      expect(mockCertificatesCreate).toHaveBeenCalledWith({
        common_name: 'dev.example.com',
        dns_credential_id: 'cred-1',
        issuer: 'letsencrypt-staging',
        acme_email: 'ops@example.com',
        sans: [],
      });
    });

    it('calls acmeCertificatesApi.requestIssue with the created cert id', async () => {
      const { onRequested } = await fillAndSubmit();
      await waitFor(() => expect(onRequested).toHaveBeenCalled());

      expect(mockCertificatesRequestIssue).toHaveBeenCalledWith('cert-abc');
    });

    it('passes SANs as a parsed array to create', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      mockCertificatesCreate.mockResolvedValue(CREATED_CERT);
      mockCertificatesRequestIssue.mockResolvedValue({
        ok: true,
        certificate: { ...CREATED_CERT, status: 'valid' },
      });

      const onRequested = jest.fn();
      renderModal({ onRequested });
      await waitFor(() => screen.getByText('Request certificate'));

      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'dev.example.com' },
      });
      fireEvent.change(screen.getByPlaceholderText('alt.example.com, www.example.com'), {
        target: { value: 'alt.example.com,  www.example.com , ' },
      });
      fireEvent.change(screen.getByPlaceholderText('ops@your-domain.tld'), {
        target: { value: 'ops@example.com' },
      });

      const btn = await waitFor(() => {
        const b = screen.getByRole('button', { name: /issue certificate/i });
        expect(b).not.toBeDisabled();
        return b;
      });
      fireEvent.click(btn);

      await waitFor(() => expect(onRequested).toHaveBeenCalled());
      expect(mockCertificatesCreate).toHaveBeenCalledWith(
        expect.objectContaining({
          sans: ['alt.example.com', 'www.example.com'],
        }),
      );
    });

    it('transitions to done phase after successful issuance', async () => {
      const { onRequested } = await fillAndSubmit();
      await waitFor(() => expect(onRequested).toHaveBeenCalled());

      expect(screen.getByText('Certificate issued.')).toBeInTheDocument();
      expect(
        screen.getByText(/stored in Vault/i),
      ).toBeInTheDocument();
    });

    it('renders enabled Done button in done phase', async () => {
      const { onRequested } = await fillAndSubmit();
      await waitFor(() => expect(onRequested).toHaveBeenCalled());

      const done = screen.getByRole('button', { name: /done/i });
      expect(done).not.toBeDisabled();
    });

    it('calls onRequested after issuance succeeds', async () => {
      const { onRequested } = await fillAndSubmit();
      await waitFor(() => expect(onRequested).toHaveBeenCalledTimes(1));
    });

    it('uses the selected non-default issuer when submitting', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      mockCertificatesCreate.mockResolvedValue(CREATED_CERT);
      mockCertificatesRequestIssue.mockResolvedValue({
        ok: true,
        certificate: { ...CREATED_CERT, status: 'valid' },
      });

      const onRequested = jest.fn();
      renderModal({ onRequested });
      await waitFor(() => screen.getByText('Request certificate'));

      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'prod.example.com' },
      });
      fireEvent.change(screen.getByPlaceholderText('ops@your-domain.tld'), {
        target: { value: 'ops@example.com' },
      });

      // Change issuer to prod
      const issuerSelect = screen.getAllByRole('combobox').find((el) =>
        el.textContent?.includes('letsencrypt-staging'),
      );
      fireEvent.change(issuerSelect!, { target: { value: 'letsencrypt-prod' } });

      const btn = await waitFor(() => {
        const b = screen.getByRole('button', { name: /issue certificate/i });
        expect(b).not.toBeDisabled();
        return b;
      });
      fireEvent.click(btn);

      await waitFor(() => expect(onRequested).toHaveBeenCalled());
      expect(mockCertificatesCreate).toHaveBeenCalledWith(
        expect.objectContaining({ issuer: 'letsencrypt-prod' }),
      );
    });
  });

  // --------------------------------------------------------------------------
  // Error path — issuance failure
  // --------------------------------------------------------------------------

  describe('issuance failure', () => {
    it('shows an error and returns to form phase when create fails', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      mockCertificatesCreate.mockRejectedValue(new Error('Quota exceeded'));

      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));

      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'cert.example.com' },
      });
      fireEvent.change(screen.getByPlaceholderText('ops@your-domain.tld'), {
        target: { value: 'ops@example.com' },
      });

      const btn = await waitFor(() => {
        const b = screen.getByRole('button', { name: /issue certificate/i });
        expect(b).not.toBeDisabled();
        return b;
      });
      fireEvent.click(btn);

      await waitFor(() =>
        expect(screen.getByText('Quota exceeded')).toBeInTheDocument(),
      );
      // Should be back in form phase (Cancel button visible)
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
    });

    it('shows an error and returns to form phase when requestIssue fails', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      mockCertificatesCreate.mockResolvedValue(CREATED_CERT);
      mockCertificatesRequestIssue.mockRejectedValue(new Error('ACME challenge failed'));

      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));

      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'cert.example.com' },
      });
      fireEvent.change(screen.getByPlaceholderText('ops@your-domain.tld'), {
        target: { value: 'ops@example.com' },
      });

      const btn = await waitFor(() => {
        const b = screen.getByRole('button', { name: /issue certificate/i });
        expect(b).not.toBeDisabled();
        return b;
      });
      fireEvent.click(btn);

      await waitFor(() =>
        expect(screen.getByText('ACME challenge failed')).toBeInTheDocument(),
      );
      expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
    });

    it('falls back to generic error text for non-Error rejections', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      mockCertificatesCreate.mockRejectedValue('string error');

      renderModal();
      await waitFor(() => screen.getByText('Request certificate'));

      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'cert.example.com' },
      });
      fireEvent.change(screen.getByPlaceholderText('ops@your-domain.tld'), {
        target: { value: 'ops@example.com' },
      });

      const btn = await waitFor(() => {
        const b = screen.getByRole('button', { name: /issue certificate/i });
        expect(b).not.toBeDisabled();
        return b;
      });
      fireEvent.click(btn);

      await waitFor(() =>
        expect(screen.getByText('Issuance failed')).toBeInTheDocument(),
      );
    });
  });

  // --------------------------------------------------------------------------
  // Reset on close/reopen
  // --------------------------------------------------------------------------

  describe('state reset on reopen', () => {
    it('resets form fields when the modal is closed and reopened', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));

      const { rerender } = render(
        <RequestCertificateModal
          isOpen={true}
          onClose={jest.fn()}
          availableIssuers={ISSUERS}
        />,
      );
      await waitFor(() => screen.getByText('Request certificate'));

      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'filled.example.com' },
      });
      expect(screen.getByPlaceholderText('dev.powernode.net')).toHaveValue(
        'filled.example.com',
      );

      // Close
      rerender(
        <RequestCertificateModal
          isOpen={false}
          onClose={jest.fn()}
          availableIssuers={ISSUERS}
        />,
      );

      // Reopen
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      rerender(
        <RequestCertificateModal
          isOpen={true}
          onClose={jest.fn()}
          availableIssuers={ISSUERS}
        />,
      );

      await waitFor(() =>
        expect(screen.getByPlaceholderText('dev.powernode.net')).toHaveValue(''),
      );
    });
  });

  // --------------------------------------------------------------------------
  // onClose wiring
  // --------------------------------------------------------------------------

  describe('onClose callback', () => {
    it('calls onClose when Cancel is clicked', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      const onClose = jest.fn();
      renderModal({ onClose });
      await waitFor(() => screen.getByText('Request certificate'));
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('calls onClose when Done is clicked after successful issuance', async () => {
      mockDnsCredsList.mockResolvedValue(makeDnsListResponse([CRED_VALID]));
      mockCertificatesCreate.mockResolvedValue(CREATED_CERT);
      mockCertificatesRequestIssue.mockResolvedValue({
        ok: true,
        certificate: { ...CREATED_CERT, status: 'valid' },
      });

      const onClose = jest.fn();
      const onRequested = jest.fn();
      renderModal({ onClose, onRequested });
      await waitFor(() => screen.getByText('Request certificate'));

      fireEvent.change(screen.getByPlaceholderText('dev.powernode.net'), {
        target: { value: 'done.example.com' },
      });
      fireEvent.change(screen.getByPlaceholderText('ops@your-domain.tld'), {
        target: { value: 'ops@example.com' },
      });

      const btn = await waitFor(() => {
        const b = screen.getByRole('button', { name: /issue certificate/i });
        expect(b).not.toBeDisabled();
        return b;
      });
      fireEvent.click(btn);

      await waitFor(() => expect(onRequested).toHaveBeenCalled());
      fireEvent.click(screen.getByRole('button', { name: /done/i }));
      expect(onClose).toHaveBeenCalled();
    });
  });
});
