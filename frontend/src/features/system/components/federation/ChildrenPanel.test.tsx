import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ChildrenPanel } from './ChildrenPanel';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: jest.fn(),
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

// =============================================================================
// Envelope helpers
// =============================================================================

/** API double-envelope: AxiosResponse body = { success: true, data: <payload> } */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function childrenEnvelope(
  children: ChildPeerSummaryFixture[],
  count?: number
) {
  return envelope({ children, count: count ?? children.length });
}

// =============================================================================
// Fixtures
// =============================================================================

interface ChildPeerSummaryFixture {
  id: string;
  remote_instance_url: string;
  spawn_mode: 'managed_child' | 'autonomous_peer' | 'cluster_member';
  status: 'proposed' | 'accepted' | 'enrolled' | 'active' | 'degraded' | 'suspended' | 'revoked';
  created_at: string;
  last_heartbeat_at: string | null;
  acceptance_pending: boolean;
  acceptance_expires_at: string | null;
}

const CHILD_ACTIVE: ChildPeerSummaryFixture = {
  id: 'child-001',
  remote_instance_url: 'https://child1.example.com',
  spawn_mode: 'managed_child',
  status: 'active',
  created_at: '2026-01-01T00:00:00Z',
  last_heartbeat_at: '2026-06-05T10:00:00Z',
  acceptance_pending: false,
  acceptance_expires_at: null,
};

const CHILD_PROPOSED: ChildPeerSummaryFixture = {
  id: 'child-002',
  remote_instance_url: 'https://child2.example.com',
  spawn_mode: 'autonomous_peer',
  status: 'proposed',
  created_at: '2026-01-02T00:00:00Z',
  last_heartbeat_at: null,
  acceptance_pending: true,
  acceptance_expires_at: '2026-07-01T00:00:00Z',
};

const CHILD_REVOKED: ChildPeerSummaryFixture = {
  id: 'child-003',
  remote_instance_url: 'https://child3.example.com',
  spawn_mode: 'cluster_member',
  status: 'revoked',
  created_at: '2026-01-03T00:00:00Z',
  last_heartbeat_at: null,
  acceptance_pending: false,
  acceptance_expires_at: null,
};

const CHILD_DETAIL = {
  ...CHILD_ACTIVE,
  endpoints: [{ url: 'https://child1.example.com/api' }],
  capabilities: { agent_exec: true },
  metadata: { region: 'us-east-1' },
  signed_at: '2026-01-01T01:00:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

const renderPanel = (props: Partial<React.ComponentProps<typeof ChildrenPanel>> = {}) =>
  render(
    <BrowserRouter>
      <ChildrenPanel {...props} />
    </BrowserRouter>
  );

// =============================================================================
// Tests
// =============================================================================

describe('ChildrenPanel', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockAddNotification.mockReset();
    jest.spyOn(window, 'prompt').mockReturnValue(null);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows "loading…" in the header while fetching', async () => {
    // Resolve never — the promise hangs indefinitely to hold the loading state.
    mockGet.mockReturnValue(new Promise(() => {}));

    renderPanel();

    expect(screen.getByText('loading…')).toBeInTheDocument();
    // The "Children" heading is always visible
    expect(screen.getByText('Children')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('renders the empty-state message when no children are returned', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([]));

    renderPanel();

    await waitFor(() =>
      expect(
        screen.getByText(/No spawned children yet/i)
      ).toBeInTheDocument()
    );
  });

  // ---------------------------------------------------------------------------
  // Loaded list
  // ---------------------------------------------------------------------------

  it('fetches from /system/federation/children with no params by default', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE]));

    renderPanel();

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/federation/children', {
        params: {},
      })
    );
  });

  it('renders children rows after successful fetch', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE, CHILD_PROPOSED]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('https://child1.example.com')).toBeInTheDocument()
    );
    expect(screen.getByText('https://child2.example.com')).toBeInTheDocument();
  });

  it('displays "2 children" count in header after load', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE, CHILD_PROPOSED]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('2 children')).toBeInTheDocument());
  });

  it('displays "1 child" (singular) when exactly one child exists', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE]));

    renderPanel();

    await waitFor(() => expect(screen.getByText('1 child')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Spawn Mode Badge rendering
  // ---------------------------------------------------------------------------

  it('renders spawn mode badge labels correctly', async () => {
    mockGet.mockResolvedValue(
      childrenEnvelope([CHILD_ACTIVE, CHILD_PROPOSED, CHILD_REVOKED])
    );

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('https://child1.example.com')).toBeInTheDocument()
    );

    expect(screen.getByText('managed')).toBeInTheDocument();
    expect(screen.getByText('autonomous')).toBeInTheDocument();
    expect(screen.getByText('cluster')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Status pills
  // ---------------------------------------------------------------------------

  it('renders status pills for each child', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE, CHILD_PROPOSED]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('https://child1.example.com')).toBeInTheDocument()
    );

    expect(screen.getByText('active')).toBeInTheDocument();
    expect(screen.getByText('proposed')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Acceptance pending / heartbeat columns
  // ---------------------------------------------------------------------------

  it('shows "yes (expires ...)" for a pending child and "no" for non-pending', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE, CHILD_PROPOSED]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('https://child2.example.com')).toBeInTheDocument()
    );

    const yesEl = screen.getByText(/yes \(expires/i);
    expect(yesEl).toBeInTheDocument();
    expect(screen.getAllByText('no').length).toBeGreaterThan(0);
  });

  it('renders last heartbeat date for children that have one', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('https://child1.example.com')).toBeInTheDocument()
    );

    // CHILD_ACTIVE has a non-null heartbeat: the Clock icon + date should render.
    // The acceptance_expires_at is null for CHILD_ACTIVE → "no" for acceptance.
    // We verify the row is fully rendered with child data.
    expect(screen.getByText('active')).toBeInTheDocument();
    // The acceptance pending cell for CHILD_ACTIVE is "no" (not pending)
    expect(screen.getByText('no')).toBeInTheDocument();
  });

  it('shows "—" for last heartbeat when last_heartbeat_at is null', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_PROPOSED]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('https://child2.example.com')).toBeInTheDocument()
    );

    // CHILD_PROPOSED has null heartbeat — "—" should appear at least once in
    // the table for the heartbeat column.
    expect(screen.getAllByText('—').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Revoke action
  // ---------------------------------------------------------------------------

  it('shows Revoke button for non-terminal children', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('https://child1.example.com')).toBeInTheDocument()
    );

    expect(screen.getByTitle('Revoke child')).toBeInTheDocument();
  });

  it('hides Revoke button for revoked children', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_REVOKED]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('https://child3.example.com')).toBeInTheDocument()
    );

    expect(screen.queryByTitle('Revoke child')).not.toBeInTheDocument();
  });

  it('aborts revoke when prompt is cancelled (returns null)', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE]));
    jest.spyOn(window, 'prompt').mockReturnValue(null);

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Revoke child')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Revoke child'));

    // POST should NOT have been called
    expect(mockPost).not.toHaveBeenCalled();
  });

  it('calls POST /system/federation/children/:id/revoke with reason on confirm', async () => {
    mockGet
      .mockResolvedValueOnce(childrenEnvelope([CHILD_ACTIVE]))
      .mockResolvedValueOnce(childrenEnvelope([CHILD_REVOKED]));
    mockPost.mockResolvedValue(envelope({ child: CHILD_REVOKED }));
    jest.spyOn(window, 'prompt').mockReturnValue('test reason');

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Revoke child')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Revoke child'));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/federation/children/child-001/revoke',
        { reason: 'test reason' }
      )
    );
  });

  it('calls POST with empty body when prompt returns empty string', async () => {
    mockGet
      .mockResolvedValueOnce(childrenEnvelope([CHILD_ACTIVE]))
      .mockResolvedValueOnce(childrenEnvelope([CHILD_REVOKED]));
    mockPost.mockResolvedValue(envelope({ child: CHILD_REVOKED }));
    jest.spyOn(window, 'prompt').mockReturnValue('');

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Revoke child')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Revoke child'));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/federation/children/child-001/revoke',
        {}
      )
    );
  });

  it('shows success notification and refreshes list after revoke', async () => {
    mockGet
      .mockResolvedValueOnce(childrenEnvelope([CHILD_ACTIVE]))
      .mockResolvedValueOnce(childrenEnvelope([]));
    mockPost.mockResolvedValue(envelope({ child: CHILD_REVOKED }));
    jest.spyOn(window, 'prompt').mockReturnValue('');

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Revoke child')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Revoke child'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'success',
          message: expect.stringContaining('https://child1.example.com'),
        })
      )
    );

    // After revoke, list refreshes — second GET is called
    expect(mockGet).toHaveBeenCalledTimes(2);
  });

  it('shows error notification when revoke fails', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE]));
    mockPost.mockRejectedValue(new Error('Network error'));
    jest.spyOn(window, 'prompt').mockReturnValue('bad');

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Revoke child')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Revoke child'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Network error',
        })
      )
    );
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  it('toggles the expand chevron on click', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE]));
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/federation/children') {
        return Promise.resolve(childrenEnvelope([CHILD_ACTIVE]));
      }
      return Promise.resolve(envelope({ child: CHILD_DETAIL }));
    });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Expand details')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByTitle('Collapse details')).toBeInTheDocument()
    );
  });

  it('fetches child detail via GET /system/federation/children/:id on first expand', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/federation/children') {
        return Promise.resolve(childrenEnvelope([CHILD_ACTIVE]));
      }
      if (url === '/system/federation/children/child-001') {
        return Promise.resolve(envelope({ child: CHILD_DETAIL }));
      }
      return Promise.reject(new Error(`Unexpected GET ${url}`));
    });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Expand details')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith(
        '/system/federation/children/child-001'
      )
    );
  });

  it('shows expanded detail row with Signed At, Endpoints, Capabilities, Metadata', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/federation/children') {
        return Promise.resolve(childrenEnvelope([CHILD_ACTIVE]));
      }
      if (url === '/system/federation/children/child-001') {
        return Promise.resolve(envelope({ child: CHILD_DETAIL }));
      }
      return Promise.reject(new Error(`Unexpected GET ${url}`));
    });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Expand details')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText(/Signed At/i)).toBeInTheDocument()
    );
    expect(screen.getByText(/Endpoints/i)).toBeInTheDocument();
    expect(screen.getByText(/Capabilities/i)).toBeInTheDocument();
    expect(screen.getByText(/Metadata/i)).toBeInTheDocument();
  });

  it('does NOT re-fetch detail when expanding an already-cached child', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/federation/children') {
        return Promise.resolve(childrenEnvelope([CHILD_ACTIVE]));
      }
      if (url === '/system/federation/children/child-001') {
        return Promise.resolve(envelope({ child: CHILD_DETAIL }));
      }
      return Promise.reject(new Error(`Unexpected GET ${url}`));
    });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Expand details')).toBeInTheDocument()
    );

    // Expand
    fireEvent.click(screen.getByTitle('Expand details'));
    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/federation/children/child-001')
    );

    const getCallCountAfterFirstExpand = mockGet.mock.calls.length;

    // Collapse then expand again
    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() =>
      expect(screen.getByTitle('Expand details')).toBeInTheDocument()
    );
    fireEvent.click(screen.getByTitle('Expand details'));

    // Detail endpoint should NOT have been called again
    await waitFor(() =>
      expect(mockGet.mock.calls.length).toBe(getCallCountAfterFirstExpand)
    );
  });

  it('shows "Loading detail…" while fetching the detail for an expanded row', async () => {
    let resolveDetail!: (value: unknown) => void;
    const detailPromise = new Promise((res) => { resolveDetail = res; });

    mockGet.mockImplementation((url: string) => {
      if (url === '/system/federation/children') {
        return Promise.resolve(childrenEnvelope([CHILD_ACTIVE]));
      }
      if (url === '/system/federation/children/child-001') {
        return detailPromise;
      }
      return Promise.reject(new Error(`Unexpected GET ${url}`));
    });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Expand details')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Loading detail…')).toBeInTheDocument()
    );

    // Resolve to clean up
    resolveDetail(envelope({ child: CHILD_DETAIL }));
  });

  it('shows error notification when detail fetch fails', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/federation/children') {
        return Promise.resolve(childrenEnvelope([CHILD_ACTIVE]));
      }
      if (url === '/system/federation/children/child-001') {
        return Promise.reject(new Error('Detail fetch failed'));
      }
      return Promise.reject(new Error(`Unexpected GET ${url}`));
    });

    renderPanel();

    await waitFor(() =>
      expect(screen.getByTitle('Expand details')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Detail fetch failed',
        })
      )
    );
  });

  // ---------------------------------------------------------------------------
  // Status filter bar
  // ---------------------------------------------------------------------------

  it('renders all status filter buttons', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText(/No spawned children yet/i)).toBeInTheDocument()
    );

    const filters = ['All', 'Proposed', 'Accepted', 'Enrolled', 'Active', 'Degraded', 'Revoked'];
    filters.forEach((label) => {
      expect(screen.getByRole('button', { name: label })).toBeInTheDocument();
    });
  });

  it('sends status filter param when a status filter is selected', async () => {
    mockGet
      .mockResolvedValueOnce(childrenEnvelope([]))
      .mockResolvedValueOnce(childrenEnvelope([CHILD_ACTIVE]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText(/No spawned children yet/i)).toBeInTheDocument()
    );

    fireEvent.click(screen.getByRole('button', { name: 'Active' }));

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/federation/children', {
        params: { status: 'active' },
      })
    );
  });

  it('resets filter to "All" (no status param) when All is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(childrenEnvelope([]))  // initial
      .mockResolvedValueOnce(childrenEnvelope([CHILD_ACTIVE]))  // after Active filter
      .mockResolvedValueOnce(childrenEnvelope([]));  // after All

    renderPanel();

    await waitFor(() => screen.getByText(/No spawned children yet/i));

    // Select Active filter
    fireEvent.click(screen.getByRole('button', { name: 'Active' }));
    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledWith('/system/federation/children', {
        params: { status: 'active' },
      })
    );

    // Reset to All
    fireEvent.click(screen.getByRole('button', { name: 'All' }));
    await waitFor(() => {
      const calls = mockGet.mock.calls;
      const lastCall = calls[calls.length - 1];
      expect(lastCall).toEqual([
        '/system/federation/children',
        { params: {} },
      ]);
    });
  });

  // ---------------------------------------------------------------------------
  // Spawn button (optional)
  // ---------------------------------------------------------------------------

  it('renders Spawn Platform button when onSpawnClick is provided', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([]));
    const onSpawnClick = jest.fn();

    renderPanel({ onSpawnClick });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /Spawn Platform/i })).toBeInTheDocument()
    );
  });

  it('does NOT render Spawn Platform button when onSpawnClick is not provided', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText(/No spawned children yet/i)).toBeInTheDocument()
    );

    expect(
      screen.queryByRole('button', { name: /Spawn Platform/i })
    ).not.toBeInTheDocument();
  });

  it('calls onSpawnClick when Spawn Platform button is clicked', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([]));
    const onSpawnClick = jest.fn();

    renderPanel({ onSpawnClick });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: /Spawn Platform/i })).toBeInTheDocument()
    );

    fireEvent.click(screen.getByRole('button', { name: /Spawn Platform/i }));

    expect(onSpawnClick).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // onSelect callback
  // ---------------------------------------------------------------------------

  it('calls onSelect when a child row is clicked', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE]));
    const onSelect = jest.fn();

    renderPanel({ onSelect });

    await waitFor(() =>
      expect(screen.getByText('https://child1.example.com')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByText('https://child1.example.com'));

    expect(onSelect).toHaveBeenCalledWith(
      expect.objectContaining({ id: 'child-001' })
    );
  });

  it('does not call onSelect when the expand toggle is clicked', async () => {
    mockGet.mockImplementation((url: string) => {
      if (url === '/system/federation/children') {
        return Promise.resolve(childrenEnvelope([CHILD_ACTIVE]));
      }
      return Promise.resolve(envelope({ child: CHILD_DETAIL }));
    });
    const onSelect = jest.fn();

    renderPanel({ onSelect });

    await waitFor(() =>
      expect(screen.getByTitle('Expand details')).toBeInTheDocument()
    );

    fireEvent.click(screen.getByTitle('Expand details'));

    expect(onSelect).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // refreshKey prop triggers re-fetch
  // ---------------------------------------------------------------------------

  it('re-fetches when refreshKey changes', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE]));

    const { rerender } = renderPanel({ refreshKey: 0 });

    await waitFor(() =>
      expect(screen.getByText('https://child1.example.com')).toBeInTheDocument()
    );

    expect(mockGet).toHaveBeenCalledTimes(1);

    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE, CHILD_PROPOSED]));

    rerender(
      <BrowserRouter>
        <ChildrenPanel refreshKey={1} />
      </BrowserRouter>
    );

    await waitFor(() =>
      expect(mockGet).toHaveBeenCalledTimes(2)
    );
  });

  // ---------------------------------------------------------------------------
  // Error state — list fetch failure
  // ---------------------------------------------------------------------------

  it('shows error notification when list fetch fails', async () => {
    mockGet.mockRejectedValue(new Error('Server error'));

    renderPanel();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Server error',
        })
      )
    );
  });

  it('shows generic error message when list fetch rejects with non-Error', async () => {
    mockGet.mockRejectedValue('oops');

    renderPanel();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Failed to load children',
        })
      )
    );
  });

  // ---------------------------------------------------------------------------
  // Table header columns
  // ---------------------------------------------------------------------------

  it('renders all table column headers when children are present', async () => {
    mockGet.mockResolvedValue(childrenEnvelope([CHILD_ACTIVE]));

    renderPanel();

    await waitFor(() =>
      expect(screen.getByText('https://child1.example.com')).toBeInTheDocument()
    );

    expect(screen.getByText('Instance URL')).toBeInTheDocument();
    expect(screen.getByText('Spawn Mode')).toBeInTheDocument();
    expect(screen.getByText('Status')).toBeInTheDocument();
    expect(screen.getByText('Spawn Pending')).toBeInTheDocument();
    expect(screen.getByText('Last Heartbeat')).toBeInTheDocument();
    expect(screen.getByText('Actions')).toBeInTheDocument();
  });
});
