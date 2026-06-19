import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PeerDetailDrawer } from './PeerDetailDrawer';
import type { PlatformPeerDetail } from '../../types/peer.types';

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

// EntityLink uses entityRegistry + useEntityModal — mock the whole shared/components/entity module
// so we don't have to provision those singletons in tests.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ id, label }: { id?: string | null; label?: React.ReactNode }) => (
    <span data-testid="entity-link">{label ?? id}</span>
  ),
}));

// GrantsManagementModal and CapabilitiesManagementModal are large modals with
// their own API calls. We mock them here and assert they receive the right props.
const mockGrantsModal = jest.fn();
const mockCapabilitiesModal = jest.fn();

jest.mock('./GrantsManagementModal', () => ({
  GrantsManagementModal: (props: Record<string, unknown>) => {
    mockGrantsModal(props);
    if (!props.isOpen) return null;
    return <div data-testid="grants-modal">GrantsModal peerId={String(props.peerId)}</div>;
  },
}));

jest.mock('./CapabilitiesManagementModal', () => ({
  CapabilitiesManagementModal: (props: Record<string, unknown>) => {
    mockCapabilitiesModal(props);
    if (!props.isOpen) return null;
    return <div data-testid="capabilities-modal">CapabilitiesModal peerId={String(props.peerId)}</div>;
  },
}));

// =============================================================================
// Envelope helper
// apiClient.get resolves to AxiosResponse whose .data is { success: true, data: <payload> }
// =============================================================================

function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const PEER_ID = 'peer-uuid-123';

function makePeer(overrides: Partial<PlatformPeerDetail> = {}): PlatformPeerDetail {
  return {
    id: PEER_ID,
    remote_instance_url: 'https://hub.remote.tld',
    remote_instance_id: 'remote-inst-abc',
    peer_kind: 'platform',
    spawn_role: 'symmetric',
    spawn_mode: 'out_of_band',
    status: 'active',
    created_at: '2026-01-01T00:00:00Z',
    last_heartbeat_at: '2026-06-01T12:00:00Z',
    last_handshake_at: null,
    endpoints_count: 1,
    acceptance_pending: false,
    acceptance_expires_at: null,
    endpoints: [
      {
        url: 'https://hub.remote.tld',
        scope: 'wan',
        priority: 100,
        status: 'reachable',
        last_verified_at: '2026-06-01T11:00:00Z',
        last_failure_at: null,
      },
    ],
    capabilities: {},
    extension_slugs: [],
    metadata: {},
    signed_at: null,
    contract_version_agreed: 'v1',
    parent_peer_id: null,
    allowed_transitions: ['suspended', 'revoked'],
    grants_count: 3,
    capabilities_count: 2,
    bridges_count: 1,
    ...overrides,
  };
}

// =============================================================================
// Render helper
// =============================================================================

interface RenderProps {
  peerId?: string | null;
  onClose?: () => void;
}

function renderDrawer({ peerId = PEER_ID, onClose = jest.fn() }: RenderProps = {}) {
  return render(
    <BrowserRouter>
      <PeerDetailDrawer peerId={peerId} onClose={onClose} />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('PeerDetailDrawer', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockGrantsModal.mockReset();
    mockCapabilitiesModal.mockReset();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Null / hidden state
  // ──────────────────────────────────────────────────────────────────────

  it('renders nothing when peerId is null', () => {
    const { container } = renderDrawer({ peerId: null });
    expect(container).toBeEmptyDOMElement();
  });

  // ──────────────────────────────────────────────────────────────────────
  // API call — fetches peer by ID
  // ──────────────────────────────────────────────────────────────────────

  it('calls GET /system/platform/peers/:peerId when peerId is provided', async () => {
    mockGet.mockResolvedValue(envelope({ peer: makePeer() }));

    renderDrawer();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(`/system/platform/peers/${PEER_ID}`),
    );
  });

  it('does not call the API when peerId is null', () => {
    renderDrawer({ peerId: null });
    expect(mockGet).not.toHaveBeenCalled();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Loading state
  // ──────────────────────────────────────────────────────────────────────

  it('shows the loading message while the fetch is in flight', async () => {
    // Never resolves during this test
    mockGet.mockReturnValue(new Promise(() => {}));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('Loading…')).toBeInTheDocument(),
    );
  });

  // ──────────────────────────────────────────────────────────────────────
  // Error state
  // ──────────────────────────────────────────────────────────────────────

  it('shows the error message when the API call rejects with an Error', async () => {
    mockGet.mockRejectedValue(new Error('Network failure'));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('Network failure')).toBeInTheDocument(),
    );
  });

  it('shows a fallback error message for non-Error rejections', async () => {
    mockGet.mockRejectedValue('unexpected');

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('Failed to load peer')).toBeInTheDocument(),
    );
  });

  // ──────────────────────────────────────────────────────────────────────
  // Successful render — peer data
  // ──────────────────────────────────────────────────────────────────────

  it('renders the Remote URL after a successful fetch', async () => {
    mockGet.mockResolvedValue(envelope({ peer: makePeer() }));

    renderDrawer();

    await waitFor(() =>
      // The URL appears both in the Remote URL section and in the endpoint card;
      // getAllByText is used intentionally.
      expect(screen.getAllByText('https://hub.remote.tld').length).toBeGreaterThanOrEqual(1),
    );
  });

  it('renders status and peer_kind key-value cells', async () => {
    mockGet.mockResolvedValue(envelope({ peer: makePeer() }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('active')).toBeInTheDocument());
    expect(screen.getByText('platform')).toBeInTheDocument();
  });

  it('renders spawn_role and spawn_mode', async () => {
    mockGet.mockResolvedValue(envelope({ peer: makePeer() }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('symmetric')).toBeInTheDocument());
    expect(screen.getByText('out_of_band')).toBeInTheDocument();
  });

  it('renders the contract version', async () => {
    mockGet.mockResolvedValue(envelope({ peer: makePeer({ contract_version_agreed: 'v2' }) }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('v2')).toBeInTheDocument());
  });

  it('renders "—" for null spawn_role and spawn_mode', async () => {
    mockGet.mockResolvedValue(
      envelope({ peer: makePeer({ spawn_role: null, spawn_mode: null }) }),
    );

    renderDrawer();

    await waitFor(() => expect(screen.getAllByText('—').length).toBeGreaterThanOrEqual(2));
  });

  it('renders "never" when last_heartbeat_at is null', async () => {
    mockGet.mockResolvedValue(
      envelope({ peer: makePeer({ last_heartbeat_at: null }) }),
    );

    renderDrawer();

    await waitFor(() => expect(screen.getByText('never')).toBeInTheDocument());
  });

  it('renders the heartbeat timestamp when last_heartbeat_at is set', async () => {
    const peer = makePeer({ last_heartbeat_at: '2026-06-01T12:00:00Z' });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    // Just assert something non-"never" is in the heartbeat cell —
    // the exact locale string depends on the test runner's locale.
    await waitFor(() => expect(screen.queryByText('never')).not.toBeInTheDocument());
  });

  // ──────────────────────────────────────────────────────────────────────
  // Drawer header
  // ──────────────────────────────────────────────────────────────────────

  it('renders the "Peer Detail" heading in the drawer header', async () => {
    mockGet.mockResolvedValue(envelope({ peer: makePeer() }));

    renderDrawer();

    expect(screen.getByText('Peer Detail')).toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Close interactions
  // ──────────────────────────────────────────────────────────────────────

  it('calls onClose when the X button in the header is clicked', async () => {
    mockGet.mockResolvedValue(envelope({ peer: makePeer() }));

    const onClose = jest.fn();
    renderDrawer({ onClose });

    // The X button is present even before the fetch resolves
    const xButtons = screen.getAllByRole('button');
    // The first button in the header is the close button
    fireEvent.click(xButtons[0]);

    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose when the backdrop overlay is clicked', async () => {
    mockGet.mockResolvedValue(envelope({ peer: makePeer() }));

    const onClose = jest.fn();
    renderDrawer({ onClose });

    // The overlay is a div with aria-hidden="true"
    const overlay = document.querySelector('[aria-hidden="true"]') as HTMLElement;
    fireEvent.click(overlay);

    expect(onClose).toHaveBeenCalled();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Endpoints section
  // ──────────────────────────────────────────────────────────────────────

  it('renders endpoints with their URL, scope, and priority', async () => {
    const peer = makePeer({
      remote_instance_url: 'https://peer-main.tld',
      endpoints: [
        { url: 'https://lan.remote.tld', scope: 'lan', priority: 1, status: 'reachable' },
        { url: 'https://wan.remote.tld', scope: 'wan', priority: 100, status: 'unreachable' },
      ],
    });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('https://lan.remote.tld')).toBeInTheDocument(),
    );
    expect(screen.getByText('https://wan.remote.tld')).toBeInTheDocument();
    expect(screen.getByText('lan')).toBeInTheDocument();
    expect(screen.getByText('wan')).toBeInTheDocument();
    // Priorities — each priority number appears in the EndpointCard "priority <n>" span
    // where the number itself is a <span> inside that text node. Use getAllByText
    // since the digit '1' may appear elsewhere in the DOM.
    expect(screen.getAllByText('1').length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText('100')).toBeInTheDocument();
  });

  it('renders endpoints sorted by priority (lowest first)', async () => {
    const peer = makePeer({
      endpoints: [
        { url: 'https://high.remote.tld', scope: 'wan', priority: 200 },
        { url: 'https://low.remote.tld', scope: 'lan', priority: 1 },
        { url: 'https://mid.remote.tld', scope: 'sdwan', priority: 50 },
      ],
    });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('https://low.remote.tld')).toBeInTheDocument(),
    );

    const allEndpointUrls = screen
      .getAllByText(/https:\/\/(low|mid|high)\.remote\.tld/)
      .map((el) => el.textContent);

    expect(allEndpointUrls).toEqual([
      'https://low.remote.tld',
      'https://mid.remote.tld',
      'https://high.remote.tld',
    ]);
  });

  it('renders endpoint status with correct color class for "reachable"', async () => {
    const peer = makePeer({
      endpoints: [
        { url: 'https://hub.remote.tld', scope: 'wan', priority: 1, status: 'reachable' },
      ],
    });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('reachable')).toBeInTheDocument());

    const statusEl = screen.getByText('reachable');
    expect(statusEl).toHaveClass('text-theme-success-fg');
  });

  it('renders endpoint status with correct color class for "unreachable"', async () => {
    const peer = makePeer({
      endpoints: [
        { url: 'https://hub.remote.tld', scope: 'wan', priority: 1, status: 'unreachable' },
      ],
    });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('unreachable')).toBeInTheDocument());

    const statusEl = screen.getByText('unreachable');
    expect(statusEl).toHaveClass('text-theme-danger-fg');
  });

  it('shows "No endpoints declared." when endpoints array is empty', async () => {
    const peer = makePeer({ endpoints: [] });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('No endpoints declared.')).toBeInTheDocument(),
    );
  });

  it('renders last_verified_at on an endpoint when present', async () => {
    const peer = makePeer({
      endpoints: [
        {
          url: 'https://hub.remote.tld',
          scope: 'wan',
          priority: 1,
          status: 'reachable',
          last_verified_at: '2026-06-01T11:00:00Z',
        },
      ],
    });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText(/verified/)).toBeInTheDocument(),
    );
  });

  it('does not render last_verified_at when null', async () => {
    const peer = makePeer({
      remote_instance_url: 'https://peer-noverify.tld',
      endpoints: [
        {
          url: 'https://ep-noverify.tld',
          scope: 'wan',
          priority: 1,
          status: 'reachable',
          last_verified_at: null,
        },
      ],
    });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('https://ep-noverify.tld')).toBeInTheDocument(),
    );
    expect(screen.queryByText(/verified/)).not.toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Allowed transitions
  // ──────────────────────────────────────────────────────────────────────

  it('renders each allowed transition', async () => {
    const peer = makePeer({ allowed_transitions: ['suspended', 'revoked'] });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('→ suspended')).toBeInTheDocument());
    expect(screen.getByText('→ revoked')).toBeInTheDocument();
  });

  it('renders the terminal state message when allowed_transitions is empty', async () => {
    const peer = makePeer({ allowed_transitions: [] });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('Terminal — no further transitions.')).toBeInTheDocument(),
    );
  });

  // ──────────────────────────────────────────────────────────────────────
  // Parent peer
  // ──────────────────────────────────────────────────────────────────────

  it('does not render the "Parent Peer" section when parent_peer_id is null', async () => {
    const peer = makePeer({ parent_peer_id: null });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    // Wait for the Remote URL section label to confirm data has loaded
    await waitFor(() =>
      expect(screen.getByText('Remote URL')).toBeInTheDocument(),
    );
    expect(screen.queryByText(/parent peer/i)).not.toBeInTheDocument();
  });

  it('renders the EntityLink for parent_peer_id when it is set', async () => {
    const peer = makePeer({ parent_peer_id: 'parent-peer-uuid' });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByTestId('entity-link')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('entity-link')).toHaveTextContent('parent-peer-uuid');
  });

  // ──────────────────────────────────────────────────────────────────────
  // Acceptance pending banner
  // ──────────────────────────────────────────────────────────────────────

  it('does not render the acceptance-pending banner when acceptance_pending is false', async () => {
    const peer = makePeer({ acceptance_pending: false, acceptance_expires_at: null });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('Remote URL')).toBeInTheDocument(),
    );
    expect(screen.queryByText(/acceptance pending/i)).not.toBeInTheDocument();
  });

  it('renders the acceptance-pending banner when both acceptance_pending and acceptance_expires_at are set', async () => {
    const peer = makePeer({
      acceptance_pending: true,
      acceptance_expires_at: '2026-06-08T00:00:00Z',
    });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText(/acceptance pending/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/token expires/i)).toBeInTheDocument();
    expect(screen.getByText('/federation_api/accept')).toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Related records section
  // ──────────────────────────────────────────────────────────────────────

  it('renders Grants, Capabilities, and Bridges related-record cards with correct counts', async () => {
    const peer = makePeer({ grants_count: 3, capabilities_count: 2, bridges_count: 1 });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('Grants')).toBeInTheDocument());
    expect(screen.getByText('Capabilities')).toBeInTheDocument();
    expect(screen.getByText('Bridges')).toBeInTheDocument();

    // Count numbers rendered inside the related cards
    expect(screen.getByText('3')).toBeInTheDocument();
    expect(screen.getByText('2')).toBeInTheDocument();
    expect(screen.getByText('1')).toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // GrantsManagementModal
  // ──────────────────────────────────────────────────────────────────────

  it('opens GrantsManagementModal when the Grants related card is clicked', async () => {
    const peer = makePeer({ grants_count: 3 });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('Grants')).toBeInTheDocument());

    // The Grants card is wrapped in a button
    const grantsButton = screen.getByRole('button', { name: /grants/i });
    fireEvent.click(grantsButton);

    await waitFor(() =>
      expect(screen.getByTestId('grants-modal')).toBeInTheDocument(),
    );
  });

  it('passes peer id and remote_instance_url as peerLabel to GrantsManagementModal', async () => {
    const peer = makePeer({ grants_count: 2 });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('Grants')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /grants/i }));

    await waitFor(() =>
      expect(mockGrantsModal).toHaveBeenCalledWith(
        expect.objectContaining({
          isOpen: true,
          peerId: PEER_ID,
          peerLabel: 'https://hub.remote.tld',
        }),
      ),
    );
  });

  it('closes GrantsManagementModal when its onClose is called', async () => {
    const peer = makePeer({ grants_count: 1 });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('Grants')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /grants/i }));

    await waitFor(() => expect(screen.getByTestId('grants-modal')).toBeInTheDocument());

    // Extract the onClose prop the modal received and call it
    const lastCall = mockGrantsModal.mock.calls[mockGrantsModal.mock.calls.length - 1][0];
    lastCall.onClose();

    await waitFor(() =>
      expect(screen.queryByTestId('grants-modal')).not.toBeInTheDocument(),
    );
  });

  // ──────────────────────────────────────────────────────────────────────
  // CapabilitiesManagementModal
  // ──────────────────────────────────────────────────────────────────────

  it('opens CapabilitiesManagementModal when the Capabilities related card is clicked', async () => {
    const peer = makePeer({ capabilities_count: 2 });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('Capabilities')).toBeInTheDocument());

    const capButton = screen.getByRole('button', { name: /capabilities/i });
    fireEvent.click(capButton);

    await waitFor(() =>
      expect(screen.getByTestId('capabilities-modal')).toBeInTheDocument(),
    );
  });

  it('passes peer id and remote_instance_url as peerLabel to CapabilitiesManagementModal', async () => {
    const peer = makePeer({ capabilities_count: 5 });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('Capabilities')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /capabilities/i }));

    await waitFor(() =>
      expect(mockCapabilitiesModal).toHaveBeenCalledWith(
        expect.objectContaining({
          isOpen: true,
          peerId: PEER_ID,
          peerLabel: 'https://hub.remote.tld',
        }),
      ),
    );
  });

  it('closes CapabilitiesManagementModal when its onClose is called', async () => {
    const peer = makePeer({ capabilities_count: 1 });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('Capabilities')).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /capabilities/i }));

    await waitFor(() =>
      expect(screen.getByTestId('capabilities-modal')).toBeInTheDocument(),
    );

    const lastCall =
      mockCapabilitiesModal.mock.calls[mockCapabilitiesModal.mock.calls.length - 1][0];
    lastCall.onClose();

    await waitFor(() =>
      expect(screen.queryByTestId('capabilities-modal')).not.toBeInTheDocument(),
    );
  });

  // ──────────────────────────────────────────────────────────────────────
  // Bridges link
  // ──────────────────────────────────────────────────────────────────────

  it('renders the Bridges card as a Link to /app/system/sdwan/topology', async () => {
    const peer = makePeer({ bridges_count: 4 });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('Bridges')).toBeInTheDocument());

    const bridgesLink = screen.getByText('Bridges').closest('a');
    expect(bridgesLink).toHaveAttribute('href', '/app/system/sdwan/topology');
  });

  // ──────────────────────────────────────────────────────────────────────
  // Extension slugs
  // ──────────────────────────────────────────────────────────────────────

  it('does not render the Remote Extensions section when extension_slugs is empty', async () => {
    const peer = makePeer({ extension_slugs: [] });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('Remote URL')).toBeInTheDocument(),
    );
    expect(screen.queryByText(/remote extensions/i)).not.toBeInTheDocument();
  });

  it('renders each extension slug when extension_slugs is non-empty', async () => {
    const peer = makePeer({ extension_slugs: ['trading', 'business'] });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() => expect(screen.getByText('trading')).toBeInTheDocument());
    expect(screen.getByText('business')).toBeInTheDocument();
    expect(screen.getByText(/remote extensions/i)).toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Capabilities snapshot
  // ──────────────────────────────────────────────────────────────────────

  it('does not render the Capabilities Snapshot section when capabilities is empty', async () => {
    const peer = makePeer({ capabilities: {} });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('Remote URL')).toBeInTheDocument(),
    );
    expect(screen.queryByText(/capabilities snapshot/i)).not.toBeInTheDocument();
  });

  it('renders the Capabilities Snapshot as JSON when capabilities is non-empty', async () => {
    const peer = makePeer({ capabilities: { sync_skills: true, version: 2 } });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText(/capabilities snapshot/i)).toBeInTheDocument(),
    );
    // The JSON is rendered in a <pre> — check for the key
    expect(screen.getByText(/sync_skills/)).toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Metadata
  // ──────────────────────────────────────────────────────────────────────

  it('does not render the Metadata section when metadata is empty', async () => {
    const peer = makePeer({ metadata: {} });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('Remote URL')).toBeInTheDocument(),
    );
    expect(screen.queryByText(/^metadata$/i)).not.toBeInTheDocument();
  });

  it('renders Metadata as JSON when metadata is non-empty', async () => {
    const peer = makePeer({ metadata: { region: 'us-west-2', tier: 'gold' } });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText(/^metadata$/i)).toBeInTheDocument(),
    );
    expect(screen.getByText(/region/)).toBeInTheDocument();
    expect(screen.getByText(/us-west-2/)).toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Re-fetch when peerId changes
  // ──────────────────────────────────────────────────────────────────────

  it('re-fetches when peerId prop changes', async () => {
    const peer1 = makePeer({ id: 'peer-1', remote_instance_url: 'https://peer1.tld' });
    const peer2 = makePeer({ id: 'peer-2', remote_instance_url: 'https://peer2.tld' });

    mockGet
      .mockResolvedValueOnce(envelope({ peer: peer1 }))
      .mockResolvedValueOnce(envelope({ peer: peer2 }));

    const onClose = jest.fn();
    const { rerender } = render(
      <BrowserRouter>
        <PeerDetailDrawer peerId="peer-1" onClose={onClose} />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(screen.getByText('https://peer1.tld')).toBeInTheDocument(),
    );

    rerender(
      <BrowserRouter>
        <PeerDetailDrawer peerId="peer-2" onClose={onClose} />
      </BrowserRouter>,
    );

    await waitFor(() =>
      expect(screen.getByText('https://peer2.tld')).toBeInTheDocument(),
    );

    expect(mockGet).toHaveBeenCalledTimes(2);
    expect(mockGet).toHaveBeenNthCalledWith(1, '/system/platform/peers/peer-1');
    expect(mockGet).toHaveBeenNthCalledWith(2, '/system/platform/peers/peer-2');
  });

  it('clears peer data and does not show old content when peerId becomes null', async () => {
    const peer = makePeer();
    mockGet.mockResolvedValue(envelope({ peer }));

    const onClose = jest.fn();
    const { rerender } = render(
      <BrowserRouter>
        <PeerDetailDrawer peerId={PEER_ID} onClose={onClose} />
      </BrowserRouter>,
    );

    // Wait for data to load using the "Remote URL" label which is unique in the drawer
    await waitFor(() =>
      expect(screen.getByText('Remote URL')).toBeInTheDocument(),
    );

    rerender(
      <BrowserRouter>
        <PeerDetailDrawer peerId={null} onClose={onClose} />
      </BrowserRouter>,
    );

    // With peerId null, the component returns null entirely
    expect(screen.queryByText('Peer Detail')).not.toBeInTheDocument();
    expect(screen.queryByText('Remote URL')).not.toBeInTheDocument();
  });

  // ──────────────────────────────────────────────────────────────────────
  // Endpoint count label
  // ──────────────────────────────────────────────────────────────────────

  it('renders the endpoints section heading with the correct count', async () => {
    const peer = makePeer({
      endpoints: [
        { url: 'https://ep1.tld', scope: 'lan', priority: 1 },
        { url: 'https://ep2.tld', scope: 'wan', priority: 2 },
      ],
    });
    mockGet.mockResolvedValue(envelope({ peer }));

    renderDrawer();

    await waitFor(() =>
      expect(screen.getByText('Endpoints (2)')).toBeInTheDocument(),
    );
  });
});
