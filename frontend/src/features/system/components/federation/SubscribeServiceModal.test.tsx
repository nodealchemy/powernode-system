import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { SubscribeServiceModal } from './SubscribeServiceModal';
import type { RemoteCatalogOffering, ServiceSubscription } from '../../types/service_delivery.types';

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

// Modal passes children + footer through; keep real rendering shape so we
// can query form fields and buttons.
jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({
    isOpen,
    children,
    footer,
  }: {
    isOpen: boolean;
    children: React.ReactNode;
    footer?: React.ReactNode;
    title?: React.ReactNode;
    maxWidth?: string;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="modal">
        {children}
        {footer}
      </div>
    );
  },
}));

jest.mock('@/shared/components/ui/Button', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    variant,
  }: {
    children: React.ReactNode;
    onClick?: (e: React.MouseEvent) => void;
    disabled?: boolean;
    variant?: string;
  }) => (
    <button onClick={onClick} disabled={disabled} data-variant={variant}>
      {children}
    </button>
  ),
}));

const mockSubscribeToPeer = jest.fn();
jest.mock('../../services/api/serviceCatalogApi', () => ({
  serviceCatalogApi: {
    subscribeToPeer: (...args: unknown[]) => mockSubscribeToPeer(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const OFFERING_HTTPS: RemoteCatalogOffering = {
  slug: 'git-service',
  name: 'Git Service',
  description_markdown: null,
  protocol: 'https',
  backend_port: 443,
  capacity_metadata: {},
  latency_metadata: { p50_ms: 12, p95_ms: 45 },
  subscription_terms_markdown: null,
  default_grant_ttl_days: 30,
  default_grant_scopes: ['read'],
  status: 'active',
  accepting_new_subscriptions: true,
};

const OFFERING_TCP: RemoteCatalogOffering = {
  slug: 'pg-service',
  name: 'Postgres Service',
  description_markdown: null,
  protocol: 'tcp',
  backend_port: 5432,
  capacity_metadata: {},
  latency_metadata: {},
  subscription_terms_markdown: null,
  default_grant_ttl_days: 14,
  default_grant_scopes: ['read', 'write'],
  status: 'active',
  accepting_new_subscriptions: true,
};

const OFFERING_WITH_TERMS: RemoteCatalogOffering = {
  ...OFFERING_HTTPS,
  subscription_terms_markdown: 'You agree to the terms of service.',
};

const SUBSCRIPTION: ServiceSubscription = {
  id: 'sub-1',
  service_offering_slug: 'git-service',
  service_offering_id: 'off-1',
  federation_peer_id: 'peer-abc',
  local_hostname: 'git.alice.tld',
  protocol: 'https',
  backend_port: 443,
  status: 'active',
  site_local: false,
  subscribed_at: '2026-06-01T00:00:00Z',
  activated_at: '2026-06-01T00:01:00Z',
};

// Helper: render the modal in open state with an offering
interface RenderProps {
  isOpen?: boolean;
  onClose?: () => void;
  peerId?: string;
  offering?: RemoteCatalogOffering | null;
  onSubscribed?: (sub: ServiceSubscription) => void;
}

function renderModal({
  isOpen = true,
  onClose = jest.fn(),
  peerId = 'peer-abc',
  offering = OFFERING_HTTPS,
  onSubscribed = jest.fn(),
}: RenderProps = {}) {
  return render(
    <BrowserRouter>
      <SubscribeServiceModal
        isOpen={isOpen}
        onClose={onClose}
        peerId={peerId}
        offering={offering}
        onSubscribed={onSubscribed}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('SubscribeServiceModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockSubscribeToPeer.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Visibility / null-offering guard
  // ---------------------------------------------------------------------------

  it('renders nothing when offering is null', () => {
    renderModal({ offering: null });
    expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
  });

  it('renders nothing when isOpen is false (modal closed)', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
  });

  it('renders the modal when isOpen is true and offering is provided', () => {
    renderModal();
    expect(screen.getByTestId('modal')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Offering metadata display
  // ---------------------------------------------------------------------------

  it('shows the offering slug in the info block', () => {
    renderModal();
    expect(screen.getByText('git-service')).toBeInTheDocument();
  });

  it('shows the protocol in the info block', () => {
    renderModal();
    expect(screen.getByText('https')).toBeInTheDocument();
  });

  it('shows the backend port in the info block', () => {
    renderModal();
    expect(screen.getByText(':443')).toBeInTheDocument();
  });

  it('shows latency metadata when p50_ms is present', () => {
    renderModal();
    expect(screen.getByText(/p50 12ms/)).toBeInTheDocument();
    expect(screen.getByText(/p95 45ms/)).toBeInTheDocument();
  });

  it('hides latency metadata when p50_ms is absent', () => {
    renderModal({ offering: OFFERING_TCP });
    expect(screen.queryByText(/p50/)).not.toBeInTheDocument();
  });

  it('shows p95 only when p95_ms is present alongside p50_ms', () => {
    const offering: RemoteCatalogOffering = {
      ...OFFERING_HTTPS,
      latency_metadata: { p50_ms: 10 },
    };
    renderModal({ offering });
    expect(screen.getByText(/p50 10ms/)).toBeInTheDocument();
    expect(screen.queryByText(/p95/)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Subscription terms (conditional)
  // ---------------------------------------------------------------------------

  it('renders the subscription terms section when subscription_terms_markdown is set', () => {
    renderModal({ offering: OFFERING_WITH_TERMS });
    expect(screen.getByText('You agree to the terms of service.')).toBeInTheDocument();
  });

  it('does not render subscription terms section when subscription_terms_markdown is null', () => {
    renderModal({ offering: OFFERING_HTTPS });
    // The "Subscription Terms" label should not appear
    expect(screen.queryByText(/subscription terms/i)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // State reset on open
  // ---------------------------------------------------------------------------

  it('resets localHostname to empty and ttlDays to offering default when modal re-opens', () => {
    const { rerender } = renderModal();

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'old.host' } });
    expect(hostnameInput).toHaveValue('old.host');

    // Close then reopen
    rerender(
      <BrowserRouter>
        <SubscribeServiceModal
          isOpen={false}
          onClose={jest.fn()}
          peerId="peer-abc"
          offering={OFFERING_HTTPS}
        />
      </BrowserRouter>,
    );
    rerender(
      <BrowserRouter>
        <SubscribeServiceModal
          isOpen={true}
          onClose={jest.fn()}
          peerId="peer-abc"
          offering={OFFERING_HTTPS}
        />
      </BrowserRouter>,
    );

    expect(screen.getByPlaceholderText(/git\.alice\.tld/i)).toHaveValue('');
    // TTL should be reset to default_grant_ttl_days (30)
    expect(screen.getByRole('spinbutton')).toHaveValue(30);
  });

  it('initialises ttlDays to offering.default_grant_ttl_days', () => {
    renderModal({ offering: OFFERING_TCP }); // default_grant_ttl_days = 14
    expect(screen.getByRole('spinbutton')).toHaveValue(14);
  });

  // ---------------------------------------------------------------------------
  // Site-local hint text
  // ---------------------------------------------------------------------------

  it('shows site-local hint when hostname starts with localhost:', () => {
    renderModal();
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'localhost:5432' } });
    expect(screen.getByText(/Site-local TCP forward/i)).toBeInTheDocument();
  });

  it('shows site-local hint when hostname starts with 127.0.0.1:', () => {
    renderModal();
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: '127.0.0.1:3000' } });
    expect(screen.getByText(/Site-local TCP forward/i)).toBeInTheDocument();
  });

  it('shows ACME cert hint for https protocol with a public hostname', () => {
    renderModal({ offering: OFFERING_HTTPS });
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });
    expect(screen.getByText(/ACME cert/i)).toBeInTheDocument();
  });

  it('shows ACME cert hint for tls protocol with a public hostname', () => {
    const offering: RemoteCatalogOffering = {
      ...OFFERING_HTTPS,
      protocol: 'tls',
    };
    renderModal({ offering });
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'db.alice.tld' } });
    expect(screen.getByText(/ACME cert/i)).toBeInTheDocument();
  });

  it('shows no-TLS hint for tcp protocol with a public hostname', () => {
    renderModal({ offering: OFFERING_TCP });
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'pg.alice.tld' } });
    expect(screen.getByText(/No TLS termination/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Validation — hostname
  // ---------------------------------------------------------------------------

  it('shows error notification when submitting with empty hostname via form submit', async () => {
    const { container } = renderModal();
    // hostname is empty, so validation.ok = false; the button is disabled but
    // the form's onSubmit handler still contains the guard — submit via form.
    const form = container.querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'error',
      message: 'Local hostname is required.',
    });
    expect(mockSubscribeToPeer).not.toHaveBeenCalled();
  });

  it('shows error notification when hostname has invalid characters via form submit', async () => {
    const { container } = renderModal();
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    // A hostname with spaces is invalid
    fireEvent.change(hostnameInput, { target: { value: 'invalid host name' } });

    const form = container.querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'error',
      message: expect.stringContaining('Hostname looks malformed'),
    });
    expect(mockSubscribeToPeer).not.toHaveBeenCalled();
  });

  it('Subscribe button is disabled when hostname is empty (validation.ok = false)', () => {
    renderModal();
    // No hostname entered — button should be disabled
    const subscribeBtn = screen.getByRole('button', { name: /^Subscribe$/i });
    expect(subscribeBtn).toBeDisabled();
  });

  it('Subscribe button is enabled after a valid hostname is entered', () => {
    renderModal();
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    const subscribeBtn = screen.getByRole('button', { name: /^Subscribe$/i });
    expect(subscribeBtn).not.toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Validation — TTL
  // ---------------------------------------------------------------------------

  it('shows error notification when TTL is below minimum (7) via form submit', async () => {
    const { container } = renderModal();
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    const ttlInput = screen.getByRole('spinbutton');
    fireEvent.change(ttlInput, { target: { value: '3' } });

    // Button is disabled when validation.ok = false, so submit via form
    const form = container.querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'error',
      message: expect.stringContaining('TTL must be'),
    });
    expect(mockSubscribeToPeer).not.toHaveBeenCalled();
  });

  it('accepts an empty TTL field (uses offering default on submit)', async () => {
    mockSubscribeToPeer.mockResolvedValue(SUBSCRIPTION);

    renderModal();
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    // Clear the TTL field
    const ttlInput = screen.getByRole('spinbutton');
    fireEvent.change(ttlInput, { target: { value: '' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(mockSubscribeToPeer).toHaveBeenCalledWith('peer-abc', {
        slug: 'git-service',
        local_hostname: 'git.alice.tld',
        ttl_days: undefined,
      }),
    );
  });

  it('accepts a TTL at the minimum boundary (7)', async () => {
    mockSubscribeToPeer.mockResolvedValue(SUBSCRIPTION);

    renderModal();
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    const ttlInput = screen.getByRole('spinbutton');
    fireEvent.change(ttlInput, { target: { value: '7' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(mockSubscribeToPeer).toHaveBeenCalledWith('peer-abc', {
        slug: 'git-service',
        local_hostname: 'git.alice.tld',
        ttl_days: 7,
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Hostname regex — valid cases
  // ---------------------------------------------------------------------------

  it('accepts a valid public domain as hostname', async () => {
    mockSubscribeToPeer.mockResolvedValue(SUBSCRIPTION);
    renderModal();

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() => expect(mockSubscribeToPeer).toHaveBeenCalledTimes(1));
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'error' }),
    );
  });

  it('accepts localhost:port as hostname', async () => {
    mockSubscribeToPeer.mockResolvedValue(SUBSCRIPTION);
    renderModal();

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'localhost:5432' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(mockSubscribeToPeer).toHaveBeenCalledWith('peer-abc', {
        slug: 'git-service',
        local_hostname: 'localhost:5432',
        ttl_days: 30,
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Happy-path submission
  // ---------------------------------------------------------------------------

  it('calls serviceCatalogApi.subscribeToPeer with correct peerId, slug, local_hostname, and ttl_days', async () => {
    mockSubscribeToPeer.mockResolvedValue(SUBSCRIPTION);
    const onSubscribed = jest.fn();
    const onClose = jest.fn();

    renderModal({ onSubscribed, onClose });

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    const ttlInput = screen.getByRole('spinbutton');
    fireEvent.change(ttlInput, { target: { value: '60' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(mockSubscribeToPeer).toHaveBeenCalledWith('peer-abc', {
        slug: 'git-service',
        local_hostname: 'git.alice.tld',
        ttl_days: 60,
      }),
    );
    expect(onSubscribed).toHaveBeenCalledWith(SUBSCRIPTION);
    expect(onClose).toHaveBeenCalled();
    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'success',
      message: 'Subscribed to "Git Service"',
    });
  });

  it('trims surrounding whitespace from local_hostname before sending', async () => {
    mockSubscribeToPeer.mockResolvedValue(SUBSCRIPTION);
    renderModal();

    // The onChange already trims (target.value.trim()), so typing with spaces around
    // should still produce a trimmed value
    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: '  git.alice.tld  ' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(mockSubscribeToPeer).toHaveBeenCalledWith('peer-abc', {
        slug: 'git-service',
        local_hostname: 'git.alice.tld',
        ttl_days: 30,
      }),
    );
  });

  it('calls form onSubmit (Enter key / native submit) the same as button click', async () => {
    mockSubscribeToPeer.mockResolvedValue(SUBSCRIPTION);
    const onClose = jest.fn();

    const { container } = renderModal({ onClose });

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    const form = container.querySelector('form');
    expect(form).not.toBeNull();
    fireEvent.submit(form!);

    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(mockSubscribeToPeer).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Error path
  // ---------------------------------------------------------------------------

  it('shows error notification with err.message when subscribeToPeer rejects with Error', async () => {
    mockSubscribeToPeer.mockRejectedValue(new Error('Peer unreachable'));
    renderModal();

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Peer unreachable',
      }),
    );
  });

  it('shows generic error when subscribeToPeer rejects with a non-Error value', async () => {
    mockSubscribeToPeer.mockRejectedValue('some string error');
    renderModal();

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Subscribe failed',
      }),
    );
  });

  it('does not call onSubscribed when subscribeToPeer fails', async () => {
    mockSubscribeToPeer.mockRejectedValue(new Error('oops'));
    const onSubscribed = jest.fn();

    renderModal({ onSubscribed });

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onSubscribed).not.toHaveBeenCalled();
  });

  it('does not call onClose when subscribeToPeer fails', async () => {
    mockSubscribeToPeer.mockRejectedValue(new Error('oops'));
    const onClose = jest.fn();

    renderModal({ onClose });

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' }),
      ),
    );

    expect(onClose).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // In-flight state
  // ---------------------------------------------------------------------------

  it('shows "Subscribing…" on the submit button while the request is in-flight', async () => {
    let resolve!: (v: ServiceSubscription) => void;
    mockSubscribeToPeer.mockReturnValue(
      new Promise<ServiceSubscription>((r) => {
        resolve = r;
      }),
    );

    renderModal();

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(screen.getByText('Subscribing…')).toBeInTheDocument(),
    );

    resolve(SUBSCRIPTION);
    await waitFor(() =>
      expect(screen.queryByText('Subscribing…')).not.toBeInTheDocument(),
    );
  });

  it('disables the Cancel button while submitting', async () => {
    let resolve!: (v: ServiceSubscription) => void;
    mockSubscribeToPeer.mockReturnValue(
      new Promise<ServiceSubscription>((r) => {
        resolve = r;
      }),
    );

    renderModal();

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    fireEvent.click(screen.getByRole('button', { name: /^Subscribe$/i }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /cancel/i })).toBeDisabled(),
    );

    resolve(SUBSCRIPTION);
    await waitFor(() =>
      expect(screen.queryByText('Subscribing…')).not.toBeInTheDocument(),
    );
  });

  it('disables the Subscribe button while submitting', async () => {
    let resolve!: (v: ServiceSubscription) => void;
    mockSubscribeToPeer.mockReturnValue(
      new Promise<ServiceSubscription>((r) => {
        resolve = r;
      }),
    );

    renderModal();

    const hostnameInput = screen.getByPlaceholderText(/git\.alice\.tld/i);
    fireEvent.change(hostnameInput, { target: { value: 'git.alice.tld' } });

    const subscribeBtn = screen.getByRole('button', { name: /^Subscribe$/i });
    fireEvent.click(subscribeBtn);

    await waitFor(() =>
      expect(screen.getByText('Subscribing…')).toBeInTheDocument(),
    );

    // The button text changes to "Subscribing…" and it should be disabled
    const inFlightBtn = screen.getByText('Subscribing…').closest('button');
    expect(inFlightBtn).toBeDisabled();

    resolve(SUBSCRIPTION);
    await waitFor(() =>
      expect(screen.queryByText('Subscribing…')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when the Cancel button is clicked', () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(mockSubscribeToPeer).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // TTL default in info text
  // ---------------------------------------------------------------------------

  it('shows the offering default_grant_ttl_days in the TTL description text', () => {
    renderModal({ offering: OFFERING_HTTPS }); // default = 30
    expect(screen.getByText(/30 days/)).toBeInTheDocument();
  });
});
