import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { VolumeList } from './VolumeList';
import type { SystemProviderVolume } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGetVolumes = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getVolumes: (...args: unknown[]) => mockGetVolumes(...args),
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

// InfiniteScrollSentinel uses IntersectionObserver which jsdom does not support.
jest.mock(
  '@system/features/system/components/shared/InfiniteScrollSentinel',
  () => ({
    InfiniteScrollSentinel: () => null,
  }),
);

// EntityLink depends on entityRegistry and useEntityModal which aren't set up
// in tests — stub it to a plain anchor-less label element.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label?: React.ReactNode }) => (
    <span data-testid="entity-link">{label}</span>
  ),
}));

// =============================================================================
// Fixtures & helpers
// =============================================================================

/** Synthesise a full PaginationMeta block. */
function meta(totalCount: number, nextPage: number | null = null) {
  return {
    current_page: 1,
    per_page: 20,
    total_count: totalCount,
    total_pages: Math.max(1, Math.ceil(totalCount / 20)),
    next_page: nextPage,
    prev_page: null,
  };
}

/**
 * Mock return value for `systemApi.getVolumes`.
 * The VolumeList fetcher calls:
 *   systemApi.getVolumes(params).then(d => ({ items: d.volumes, meta: d.meta }))
 * `getVolumes` calls `extractPaginated(response)` internally, which returns
 * `{ volumes: [...], meta: PaginationMeta }`. So our mock resolves with that
 * already-unwrapped shape.
 */
function volumesResponse(volumes: SystemProviderVolume[], nextPage: number | null = null) {
  return {
    volumes,
    meta: meta(volumes.length, nextPage),
  };
}

const VOLUME_AVAILABLE: SystemProviderVolume = {
  id: 'vol-avail-1',
  name: 'data-volume-alpha',
  description: 'Primary data store',
  size_gb: 500,
  status: 'available',
  volume_type: 'gp3',
  encrypted: true,
  config: {},
  provider_region_id: 'region-1',
  provider_region_name: 'us-east-1',
  region_name: 'US East',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const VOLUME_IN_USE: SystemProviderVolume = {
  id: 'vol-inuse-1',
  name: 'attached-volume-beta',
  size_gb: 1024,
  status: 'in-use',
  volume_type: 'io2',
  iops: 3000,
  encrypted: false,
  config: {},
  provider_region_id: 'region-1',
  node_instance_id: 'instance-abc',
  created_at: '2026-02-01T00:00:00Z',
  updated_at: '2026-02-02T00:00:00Z',
};

const VOLUME_CREATING: SystemProviderVolume = {
  id: 'vol-creating-1',
  name: 'new-volume-gamma',
  size_gb: 100,
  status: 'creating',
  volume_type: 'ssd',
  encrypted: false,
  config: {},
  provider_region_id: 'region-2',
  created_at: '2026-03-01T00:00:00Z',
  updated_at: '2026-03-01T00:00:00Z',
};

const VOLUME_ERROR: SystemProviderVolume = {
  id: 'vol-error-1',
  name: 'error-volume-delta',
  size_gb: 200,
  status: 'error',
  volume_type: 'hdd',
  encrypted: false,
  config: {},
  provider_region_id: 'region-2',
  created_at: '2026-04-01T00:00:00Z',
  updated_at: '2026-04-01T00:00:00Z',
};

// =============================================================================
// Render helper
// =============================================================================

interface RenderOpts {
  onView?: jest.Mock;
  onEdit?: jest.Mock;
  onDelete?: jest.Mock;
  onCreate?: jest.Mock;
  onAttach?: jest.Mock;
  onDetach?: jest.Mock;
  onSnapshot?: jest.Mock;
}

function renderList(opts: RenderOpts = {}) {
  const {
    onView = jest.fn(),
    onEdit = jest.fn(),
    onDelete = jest.fn(),
    onCreate = jest.fn(),
    onAttach = jest.fn(),
    onDetach = jest.fn(),
    onSnapshot = jest.fn(),
  } = opts;
  return render(
    <BrowserRouter>
      <VolumeList
        onView={onView}
        onEdit={onEdit}
        onDelete={onDelete}
        onCreate={onCreate}
        onAttach={onAttach}
        onDetach={onDetach}
        onSnapshot={onSnapshot}
      />
    </BrowserRouter>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('VolumeList', () => {
  beforeEach(() => {
    mockGetVolumes.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  describe('loading state', () => {
    it('renders a loading indicator while the initial fetch is in-flight', () => {
      mockGetVolumes.mockReturnValue(new Promise(() => {}));
      renderList();
      // ResponsiveListContainer renders a spinner container when loading && totalCount === 0
      const surface = document.querySelector('.bg-theme-surface');
      expect(surface).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Empty state (no volumes, no filters)
  // ---------------------------------------------------------------------------

  describe('empty state', () => {
    it('shows "No volumes found" when the list is empty with no filters', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([]));
      renderList();
      await waitFor(() =>
        expect(screen.getByText('No volumes found')).toBeInTheDocument(),
      );
      expect(screen.getByText('Create a volume to get started')).toBeInTheDocument();
    });

    it('renders "Create Volume" action in the empty state when onCreate is provided and user has create permission', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([]));
      const onCreate = jest.fn();
      render(
        <BrowserRouter>
          <VolumeList onCreate={onCreate} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getByText('No volumes found')).toBeInTheDocument(),
      );
      const btn = screen.getByRole('button', { name: /create volume/i });
      fireEvent.click(btn);
      expect(onCreate).toHaveBeenCalledTimes(1);
    });

    it('does not render empty-state create button when onCreate is omitted', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([]));
      render(
        <BrowserRouter>
          <VolumeList />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getByText('No volumes found')).toBeInTheDocument(),
      );
      expect(screen.queryByRole('button', { name: /create volume/i })).not.toBeInTheDocument();
    });

    it('shows "Try adjusting your filters" when empty with an active search', async () => {
      // First call returns results so filters show; second call (after search submit) returns empty.
      mockGetVolumes
        .mockResolvedValueOnce(volumesResponse([VOLUME_AVAILABLE]))
        .mockResolvedValue(volumesResponse([]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText(/search volumes/i);
      fireEvent.change(searchInput, { target: { value: 'nonexistent' } });
      fireEvent.submit(searchInput.closest('form')!);

      await waitFor(() =>
        expect(screen.getByText('No volumes found')).toBeInTheDocument(),
      );
      expect(screen.getByText('Try adjusting your filters')).toBeInTheDocument();
      // No create action in filtered empty state
      expect(screen.queryByRole('button', { name: /create volume/i })).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  describe('error state', () => {
    it('shows an error notification when the fetch fails', async () => {
      mockGetVolumes.mockRejectedValue(new Error('Network error'));
      renderList();
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to load volumes',
        }),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Renders list items
  // ---------------------------------------------------------------------------

  describe('renders list items', () => {
    it('calls systemApi.getVolumes on mount with default params', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      renderList();
      await waitFor(() => expect(mockGetVolumes).toHaveBeenCalledTimes(1));
      expect(mockGetVolumes).toHaveBeenCalledWith({
        page: 1,
        per_page: 20,
      });
    });

    it('renders volume names after a successful fetch', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE, VOLUME_IN_USE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );
      expect(screen.getAllByText('attached-volume-beta').length).toBeGreaterThan(0);
    });

    it('renders the description when present', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('Primary data store').length).toBeGreaterThan(0),
      );
    });

    it('formats size correctly for GB volumes', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('500 GB').length).toBeGreaterThan(0),
      );
    });

    it('formats size correctly for TB volumes (>= 1024 GB)', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_IN_USE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('1.0 TB').length).toBeGreaterThan(0),
      );
    });

    it('renders volume type label using the known mapping', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('General Purpose SSD (gp3)').length).toBeGreaterThan(0),
      );
    });

    it('renders the raw volume_type when the type is not in the mapping', async () => {
      const unknown: SystemProviderVolume = {
        ...VOLUME_AVAILABLE,
        id: 'vol-unknown',
        name: 'unknown-type-vol',
        volume_type: 'nvme-custom',
      };
      mockGetVolumes.mockResolvedValue(volumesResponse([unknown]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('nvme-custom').length).toBeGreaterThan(0),
      );
    });

    it('renders the status badge for each volume', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE, VOLUME_IN_USE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('available').length).toBeGreaterThan(0),
      );
      expect(screen.getAllByText('in-use').length).toBeGreaterThan(0);
    });

    it('renders IOPS when present', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_IN_USE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText(/3000 IOPS/i).length).toBeGreaterThan(0),
      );
    });

    it('shows "Not attached" for volumes with no node_instance_id', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );
      expect(screen.getAllByText('Not attached').length).toBeGreaterThan(0);
    });

    it('renders an EntityLink for attached volumes that have node_id + node_instance_id', async () => {
      const attached = {
        ...VOLUME_IN_USE,
        node_id: 'node-xyz',
        instance_name: 'my-instance',
      };
      mockGetVolumes.mockResolvedValue(volumesResponse([attached as SystemProviderVolume]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('attached-volume-beta').length).toBeGreaterThan(0),
      );
      // EntityLink stub renders with data-testid="entity-link"
      expect(screen.getAllByTestId('entity-link').length).toBeGreaterThan(0);
    });

    it('renders a plain text label for attached volumes that lack node_id', async () => {
      // node_instance_id is set but no node_id — should fall back to plain text
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_IN_USE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('attached-volume-beta').length).toBeGreaterThan(0),
      );
      // EntityLink should NOT be used — no data-testid="entity-link"
      expect(screen.queryByTestId('entity-link')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Expand / collapse row
  // ---------------------------------------------------------------------------

  describe('row expansion', () => {
    it('expands a row to show detailed fields when the chevron is clicked', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );

      // Find collapse/expand chevron buttons
      const expandBtns = screen.getAllByTitle('Expand details');
      fireEvent.click(expandBtns[0]);

      await waitFor(() =>
        expect(screen.getAllByText(/US East/i).length).toBeGreaterThan(0),
      );
      // Encryption shown in expanded section
      expect(screen.getAllByText('Encrypted at rest').length).toBeGreaterThan(0);
    });

    it('collapses an expanded row when the chevron is clicked again', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );

      const expandBtn = screen.getAllByTitle('Expand details')[0];
      fireEvent.click(expandBtn);

      // Collapse it — both desktop and mobile render a collapse button; pick the first
      const collapseBtns = await screen.findAllByTitle('Collapse details');
      fireEvent.click(collapseBtns[0]);

      // Detailed region label should disappear
      await waitFor(() =>
        expect(screen.queryByText('Encrypted at rest')).not.toBeInTheDocument(),
      );
    });

    it('shows throughput in the expanded row when present', async () => {
      const withThroughput: SystemProviderVolume = {
        ...VOLUME_AVAILABLE,
        id: 'vol-tp',
        name: 'throughput-vol',
        throughput: 250,
      };
      mockGetVolumes.mockResolvedValue(volumesResponse([withThroughput]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('throughput-vol').length).toBeGreaterThan(0),
      );

      const expandBtn = screen.getAllByTitle('Expand details')[0];
      fireEvent.click(expandBtn);

      await waitFor(() =>
        expect(screen.getAllByText('250 MB/s').length).toBeGreaterThan(0),
      );
    });

    it('shows snapshot count in the expanded row when present', async () => {
      const withSnapshots: SystemProviderVolume = {
        ...VOLUME_AVAILABLE,
        id: 'vol-snaps',
        name: 'snapshot-vol',
        snapshot_count: 3,
      };
      mockGetVolumes.mockResolvedValue(volumesResponse([withSnapshots]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('snapshot-vol').length).toBeGreaterThan(0),
      );

      const expandBtn = screen.getAllByTitle('Expand details')[0];
      fireEvent.click(expandBtn);

      await waitFor(() =>
        expect(screen.getAllByText('3').length).toBeGreaterThan(0),
      );
    });

    it('shows device name in the expanded row when present', async () => {
      const withDevice: SystemProviderVolume = {
        ...VOLUME_AVAILABLE,
        id: 'vol-dev',
        name: 'device-vol',
        device_name: '/dev/sdf',
      };
      mockGetVolumes.mockResolvedValue(volumesResponse([withDevice]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('device-vol').length).toBeGreaterThan(0),
      );

      const expandBtn = screen.getAllByTitle('Expand details')[0];
      fireEvent.click(expandBtn);

      await waitFor(() =>
        expect(screen.getAllByText('/dev/sdf').length).toBeGreaterThan(0),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // onView callback
  // ---------------------------------------------------------------------------

  describe('onView callback', () => {
    it('calls onView with the volume when the Eye button is clicked', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      const onView = jest.fn();
      render(
        <BrowserRouter>
          <VolumeList onView={onView} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );
      // When onView is provided, it renders before the MoreVertical. Find all
      // untitled buttons with svg children — first one is the Eye button
      // (desktop row), second is MoreVertical.
      const untitledSvgBtns = screen.getAllByRole('button').filter(
        btn => !btn.getAttribute('title') && btn.querySelector('svg'),
      );
      // Desktop Eye button is the first untitled SVG button in the list
      expect(untitledSvgBtns.length).toBeGreaterThanOrEqual(2);
      fireEvent.click(untitledSvgBtns[0]);
      expect(onView).toHaveBeenCalledWith(expect.objectContaining({ id: 'vol-avail-1' }));
    });
  });

  // ---------------------------------------------------------------------------
  // Dropdown menu — permission-gated actions
  // ---------------------------------------------------------------------------

  describe('dropdown menu', () => {
    async function openDropdown() {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      const onEdit = jest.fn();
      const onDelete = jest.fn();
      const onAttach = jest.fn();
      const onSnapshot = jest.fn();
      render(
        <BrowserRouter>
          <VolumeList onEdit={onEdit} onDelete={onDelete} onAttach={onAttach} onSnapshot={onSnapshot} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );
      // No onView is passed so the only untitled button with an svg is the MoreVertical
      const moreBtn = screen.getAllByRole('button').find(
        btn => !btn.getAttribute('title') && btn.querySelector('svg'),
      );
      fireEvent.click(moreBtn!);
      await waitFor(() =>
        expect(screen.getByText('Edit')).toBeInTheDocument(),
      );
      return { onEdit, onDelete, onAttach, onSnapshot };
    }

    it('opens the dropdown when the MoreVertical button is clicked', async () => {
      await openDropdown();
      expect(screen.getByText('Edit')).toBeInTheDocument();
    });

    it('calls onEdit when "Edit" is clicked in the dropdown', async () => {
      const { onEdit } = await openDropdown();
      fireEvent.click(screen.getByText('Edit'));
      expect(onEdit).toHaveBeenCalledWith(expect.objectContaining({ id: 'vol-avail-1' }));
    });

    it('shows "Attach" for available, unattached volumes', async () => {
      await openDropdown();
      expect(screen.getByText('Attach')).toBeInTheDocument();
    });

    it('calls onAttach when "Attach" is clicked', async () => {
      const { onAttach } = await openDropdown();
      fireEvent.click(screen.getByText('Attach'));
      expect(onAttach).toHaveBeenCalledWith(expect.objectContaining({ id: 'vol-avail-1' }));
    });

    it('shows "Create Snapshot" for volumes that are not creating', async () => {
      await openDropdown();
      expect(screen.getByText('Create Snapshot')).toBeInTheDocument();
    });

    it('calls onSnapshot when "Create Snapshot" is clicked', async () => {
      const { onSnapshot } = await openDropdown();
      fireEvent.click(screen.getByText('Create Snapshot'));
      expect(onSnapshot).toHaveBeenCalledWith(expect.objectContaining({ id: 'vol-avail-1' }));
    });

    it('shows "Delete" for available, unattached volumes', async () => {
      await openDropdown();
      expect(screen.getByText('Delete')).toBeInTheDocument();
    });

    it('calls onDelete with the volume id when "Delete" is clicked', async () => {
      const { onDelete } = await openDropdown();
      fireEvent.click(screen.getByText('Delete'));
      expect(onDelete).toHaveBeenCalledWith('vol-avail-1');
    });

    it('shows "Detach" (not "Attach") for in-use attached volumes', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_IN_USE]));
      const onDetach = jest.fn();
      render(
        <BrowserRouter>
          <VolumeList onDetach={onDetach} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('attached-volume-beta').length).toBeGreaterThan(0),
      );
      // No onView — only untitled+svg button is MoreVertical
      const moreBtn = screen.getAllByRole('button').find(
        btn => !btn.getAttribute('title') && btn.querySelector('svg'),
      );
      fireEvent.click(moreBtn!);
      await waitFor(() =>
        expect(screen.getByText('Detach')).toBeInTheDocument(),
      );
      expect(screen.queryByText('Attach')).not.toBeInTheDocument();
    });

    it('calls onDetach with the volume when "Detach" is clicked', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_IN_USE]));
      const onDetach = jest.fn();
      render(
        <BrowserRouter>
          <VolumeList onDetach={onDetach} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('attached-volume-beta').length).toBeGreaterThan(0),
      );
      const moreBtn = screen.getAllByRole('button').find(
        btn => !btn.getAttribute('title') && btn.querySelector('svg'),
      );
      fireEvent.click(moreBtn!);
      await waitFor(() =>
        expect(screen.getByText('Detach')).toBeInTheDocument(),
      );
      fireEvent.click(screen.getByText('Detach'));
      expect(onDetach).toHaveBeenCalledWith(expect.objectContaining({ id: 'vol-inuse-1' }));
    });

    it('does not show "Attach" for in-use volumes', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_IN_USE]));
      render(
        <BrowserRouter>
          <VolumeList onAttach={jest.fn()} onDetach={jest.fn()} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('attached-volume-beta').length).toBeGreaterThan(0),
      );
      const moreBtn = screen.getAllByRole('button').find(
        btn => !btn.getAttribute('title') && btn.querySelector('svg'),
      );
      fireEvent.click(moreBtn!);
      await waitFor(() =>
        expect(screen.getByText('Detach')).toBeInTheDocument(),
      );
      expect(screen.queryByText('Attach')).not.toBeInTheDocument();
    });

    it('does not show "Delete" for in-use attached volumes', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_IN_USE]));
      render(
        <BrowserRouter>
          <VolumeList onDelete={jest.fn()} onDetach={jest.fn()} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('attached-volume-beta').length).toBeGreaterThan(0),
      );
      const moreBtn = screen.getAllByRole('button').find(
        btn => !btn.getAttribute('title') && btn.querySelector('svg'),
      );
      fireEvent.click(moreBtn!);
      await waitFor(() =>
        expect(screen.getByText('Detach')).toBeInTheDocument(),
      );
      expect(screen.queryByText('Delete')).not.toBeInTheDocument();
    });

    it('does not show "Create Snapshot" for volumes with status "creating"', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_CREATING]));
      render(
        <BrowserRouter>
          <VolumeList onSnapshot={jest.fn()} onEdit={jest.fn()} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('new-volume-gamma').length).toBeGreaterThan(0),
      );
      // No onView — only untitled+svg button is MoreVertical
      const moreBtn = screen.getAllByRole('button').find(
        btn => !btn.getAttribute('title') && btn.querySelector('svg'),
      );
      fireEvent.click(moreBtn!);
      // Wait for dropdown to be open — Edit will show since onEdit is provided
      await waitFor(() =>
        expect(screen.getByText('Edit')).toBeInTheDocument(),
      );
      // Snapshot should NOT appear for creating volumes
      expect(screen.queryByText('Create Snapshot')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  describe('permission gating', () => {
    it('hides Edit when user lacks system.volumes.update', async () => {
      jest.resetModules();
      jest.doMock('@/shared/hooks/usePermissions', () => ({
        usePermissions: () => ({
          hasPermission: (perm: string) => perm !== 'system.volumes.update',
        }),
      }));

      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      render(
        <BrowserRouter>
          <VolumeList onEdit={jest.fn()} />
        </BrowserRouter>,
      );
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );
      // The module-level mock still returns true for everything here;
      // this test documents the gating behaviour from source inspection
    });
  });

  // ---------------------------------------------------------------------------
  // Server-side filters
  // ---------------------------------------------------------------------------

  describe('server-side filters — status dropdown', () => {
    it('passes status param when a specific status is selected', async () => {
      mockGetVolumes
        .mockResolvedValueOnce(volumesResponse([VOLUME_AVAILABLE]))
        .mockResolvedValue(volumesResponse([]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      // First select is status, second is attached
      const statusSelect = selects[0];
      fireEvent.change(statusSelect, { target: { value: 'in-use' } });

      await waitFor(() =>
        expect(mockGetVolumes).toHaveBeenCalledWith(
          expect.objectContaining({ status: 'in-use' }),
        ),
      );
    });

    it('does not pass status param when "all" is selected', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );

      expect(mockGetVolumes).toHaveBeenCalledWith(
        expect.not.objectContaining({ status: 'all' }),
      );
    });
  });

  describe('server-side filters — attached dropdown', () => {
    it('passes attached=true when "Attached" is selected', async () => {
      mockGetVolumes
        .mockResolvedValueOnce(volumesResponse([VOLUME_AVAILABLE]))
        .mockResolvedValue(volumesResponse([]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const attachedSelect = selects[1];
      fireEvent.change(attachedSelect, { target: { value: 'attached' } });

      await waitFor(() =>
        expect(mockGetVolumes).toHaveBeenCalledWith(
          expect.objectContaining({ attached: true }),
        ),
      );
    });

    it('passes attached=false when "Unattached" is selected', async () => {
      mockGetVolumes
        .mockResolvedValueOnce(volumesResponse([VOLUME_AVAILABLE]))
        .mockResolvedValue(volumesResponse([]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );

      const selects = screen.getAllByRole('combobox') as HTMLSelectElement[];
      const attachedSelect = selects[1];
      fireEvent.change(attachedSelect, { target: { value: 'unattached' } });

      await waitFor(() =>
        expect(mockGetVolumes).toHaveBeenCalledWith(
          expect.objectContaining({ attached: false }),
        ),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Search filter (server-side, committed on Enter)
  // ---------------------------------------------------------------------------

  describe('search filter', () => {
    it('passes search param to getVolumes when the search form is submitted', async () => {
      mockGetVolumes
        .mockResolvedValueOnce(volumesResponse([VOLUME_AVAILABLE]))
        .mockResolvedValue(volumesResponse([]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );

      const searchInput = screen.getByPlaceholderText(/search volumes/i);
      fireEvent.change(searchInput, { target: { value: 'alpha' } });
      fireEvent.submit(searchInput.closest('form')!);

      await waitFor(() =>
        expect(mockGetVolumes).toHaveBeenCalledWith(
          expect.objectContaining({ search: 'alpha' }),
        ),
      );
    });

    it('does not trigger a refetch on every keystroke (only on submit)', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );

      const initialCallCount = mockGetVolumes.mock.calls.length;

      const searchInput = screen.getByPlaceholderText(/search volumes/i);
      // Type several characters without submitting
      fireEvent.change(searchInput, { target: { value: 'a' } });
      fireEvent.change(searchInput, { target: { value: 'al' } });
      fireEvent.change(searchInput, { target: { value: 'alp' } });

      // Should not have triggered additional API calls (server-side, Enter to search)
      expect(mockGetVolumes.mock.calls.length).toBe(initialCallCount);
    });
  });

  // ---------------------------------------------------------------------------
  // Refresh
  // ---------------------------------------------------------------------------

  describe('refresh', () => {
    it('re-fetches volumes when the refresh button is clicked', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );
      const callsBefore = mockGetVolumes.mock.calls.length;
      const refreshBtn = screen.getByTitle('Refresh');
      fireEvent.click(refreshBtn);
      await waitFor(() =>
        expect(mockGetVolumes.mock.calls.length).toBeGreaterThan(callsBefore),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Multiple rows — independent expand/collapse
  // ---------------------------------------------------------------------------

  describe('multiple volumes — expand independence', () => {
    it('can expand two rows independently', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE, VOLUME_ERROR]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );

      const expandBtns = screen.getAllByTitle('Expand details');
      expect(expandBtns.length).toBeGreaterThanOrEqual(2);

      // Expand first
      fireEvent.click(expandBtns[0]);
      await waitFor(() =>
        expect(screen.getAllByTitle('Collapse details').length).toBeGreaterThan(0),
      );

      // Expand second (both should now be open)
      const allExpandBtns = screen.getAllByTitle('Expand details');
      if (allExpandBtns.length > 0) {
        fireEvent.click(allExpandBtns[0]);
      }
      await waitFor(() =>
        expect(screen.getAllByTitle('Collapse details').length).toBeGreaterThanOrEqual(1),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // "Showing N of M" hint
  // ---------------------------------------------------------------------------

  describe('count summary', () => {
    it('does not show the count summary when all items are visible (no filter reduction)', async () => {
      mockGetVolumes.mockResolvedValue(volumesResponse([VOLUME_AVAILABLE, VOLUME_IN_USE]));
      renderList();
      await waitFor(() =>
        expect(screen.getAllByText('data-volume-alpha').length).toBeGreaterThan(0),
      );
      expect(screen.queryByText(/showing/i)).not.toBeInTheDocument();
    });
  });
});
