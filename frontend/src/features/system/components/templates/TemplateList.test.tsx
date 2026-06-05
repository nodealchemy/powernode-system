import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter, MemoryRouter } from 'react-router-dom';
import { TemplateList } from './TemplateList';
import type { SystemNodeTemplate } from '@system/features/system/types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: jest.fn(),
    put: jest.fn(),
    delete: jest.fn(),
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

// EntityLink has dependencies on entityRegistry + useEntityModal.
// Stub it to just render the label text so our assertions stay portable.
jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label?: React.ReactNode }) => <span>{label}</span>,
}));

// =============================================================================
// Fixtures
// =============================================================================

function makeTemplate(overrides: Partial<SystemNodeTemplate> = {}): SystemNodeTemplate {
  return {
    id: 'tpl-001',
    name: 'ubuntu-base',
    description: 'Ubuntu LTS base image',
    enabled: true,
    public: true,
    admin_user: 'ubuntu',
    config: {},
    node_platform_id: 'plat-001',
    node_platform_name: 'x86 Bare Metal',
    node_count: 3,
    module_count: 2,
    modules: [
      { id: 'mod-1', name: 'core-config', variety: 'config', priority: 10, template_module_id: 'tm-1' },
      { id: 'mod-2', name: 'ssh-access', variety: 'config', priority: 20, template_module_id: 'tm-2' },
    ],
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-02-01T00:00:00Z',
    ...overrides,
  };
}

const META = {
  current_page: 1,
  per_page: 20,
  total_count: 1,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

/**
 * Double-envelope wrapper.
 * apiClient.get resolves to { data: { success: true, data: <payload>, meta? } }
 */
function envelope<T>(payload: T, meta?: typeof META) {
  return {
    data: {
      success: true,
      data: payload,
      ...(meta ? { meta } : {}),
    },
  };
}

/**
 * The templates list endpoint returns
 *   GET /system/node_templates → body: { node_templates: [...], meta: {...} }
 * wrapped in the double-envelope.
 */
function listEnvelope(templates: SystemNodeTemplate[]) {
  const meta = { ...META, total_count: templates.length };
  return envelope({ node_templates: templates }, meta);
}

// =============================================================================
// Render helpers
// =============================================================================

interface RenderOpts {
  onView?: jest.Mock;
  onEdit?: jest.Mock;
  onDelete?: jest.Mock;
  onCreate?: jest.Mock;
  onDuplicate?: jest.Mock;
  searchParams?: string;
}

function renderList(opts: RenderOpts = {}) {
  const onView = opts.onView ?? jest.fn();
  const onEdit = opts.onEdit ?? jest.fn();
  const onDelete = opts.onDelete ?? jest.fn();
  const onCreate = opts.onCreate ?? jest.fn();
  const onDuplicate = opts.onDuplicate ?? jest.fn();

  const url = opts.searchParams ? `/?${opts.searchParams}` : '/';

  // Use MemoryRouter with initialEntries so useSearchParams can read the
  // ?platform= param in the deep-link filter tests.
  const Router = opts.searchParams
    ? ({ children }: { children: React.ReactNode }) => (
        <MemoryRouter initialEntries={[url]}>{children}</MemoryRouter>
      )
    : ({ children }: { children: React.ReactNode }) => (
        <BrowserRouter>{children}</BrowserRouter>
      );

  return render(
    <Router>
      <TemplateList
        onView={onView}
        onEdit={onEdit}
        onDelete={onDelete}
        onCreate={onCreate}
        onDuplicate={onDuplicate}
      />
    </Router>,
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('TemplateList', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------
  it('shows a loading spinner while the first page is in flight', () => {
    // Never resolves during this test
    mockGet.mockReturnValue(new Promise(() => {}));
    renderList();
    // ResponsiveListContainer renders a LoadingSpinner (div.animate-spin) when
    // loading && totalCount === 0
    expect(document.querySelector('.animate-spin')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------
  it('renders the empty state when the API returns no templates', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderList();

    await waitFor(() =>
      expect(screen.getByText('No templates configured')).toBeInTheDocument(),
    );
    expect(screen.getByText(/create your first node template/i)).toBeInTheDocument();
  });

  it('calls onCreate from the empty-state CTA', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    const onCreate = jest.fn();

    renderList({ onCreate });

    await waitFor(() =>
      expect(screen.getByText('No templates configured')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: /create template/i }));
    expect(onCreate).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Data rendering
  // ---------------------------------------------------------------------------
  it('fetches from GET /system/node_templates and renders rows', async () => {
    const tpl = makeTemplate();
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    expect(mockGet).toHaveBeenCalledWith(
      '/system/node_templates',
      expect.objectContaining({ params: expect.objectContaining({ page: 1, per_page: 20 }) }),
    );
  });

  it('renders the template name, platform, module badges, and status', async () => {
    const tpl = makeTemplate();
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    // Platform via EntityLink stub
    expect(screen.getAllByText('x86 Bare Metal').length).toBeGreaterThan(0);
    // Module badges (desktop table slices to 4)
    expect(screen.getAllByText('core-config').length).toBeGreaterThan(0);
    expect(screen.getAllByText('ssh-access').length).toBeGreaterThan(0);
    // Visibility badge
    expect(screen.getAllByText(/public/i).length).toBeGreaterThan(0);
    // Status badge
    expect(screen.getAllByText(/enabled/i).length).toBeGreaterThan(0);
  });

  it('shows a "+" overflow badge when a template has more than 4 modules', async () => {
    const tpl = makeTemplate({
      modules: [
        { id: 'm1', name: 'mod-1', variety: 'config', priority: 1, template_module_id: 'tm1' },
        { id: 'm2', name: 'mod-2', variety: 'config', priority: 2, template_module_id: 'tm2' },
        { id: 'm3', name: 'mod-3', variety: 'config', priority: 3, template_module_id: 'tm3' },
        { id: 'm4', name: 'mod-4', variety: 'config', priority: 4, template_module_id: 'tm4' },
        { id: 'm5', name: 'mod-5', variety: 'config', priority: 5, template_module_id: 'tm5' },
      ],
    });
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('mod-1').length).toBeGreaterThan(0));
    // Desktop table shows ≤4 then "+N"
    expect(screen.getByText('+1')).toBeInTheDocument();
  });

  it('renders a Private badge for non-public templates', async () => {
    const tpl = makeTemplate({ public: false });
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));
    expect(screen.getAllByText(/private/i).length).toBeGreaterThan(0);
  });

  it('renders a Disabled badge for disabled templates', async () => {
    const tpl = makeTemplate({ enabled: false });
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));
    expect(screen.getAllByText(/disabled/i).length).toBeGreaterThan(0);
  });

  it('shows a clickable node count when node_count > 0', async () => {
    const tpl = makeTemplate({ node_count: 5 });
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));
    // The count appears as a button with title "View nodes using this template"
    const nodeCountBtns = screen.getAllByTitle('View nodes using this template');
    expect(nodeCountBtns.length).toBeGreaterThan(0);
    expect(nodeCountBtns[0]).toHaveTextContent('5');
  });

  it('shows "0" text (not a button) when node_count is 0', async () => {
    const tpl = makeTemplate({ node_count: 0 });
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));
    expect(screen.queryAllByTitle('View nodes using this template')).toHaveLength(0);
    // The count "0" should appear as plain text in the desktop table
    const zeros = screen.queryAllByText('0');
    expect(zeros.length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Row actions
  // ---------------------------------------------------------------------------
  it('calls onView when the template name is clicked', async () => {
    const tpl = makeTemplate();
    mockGet.mockResolvedValue(listEnvelope([tpl]));
    const onView = jest.fn();

    renderList({ onView });

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    // Click the first occurrence of the template name (desktop table)
    fireEvent.click(screen.getAllByText('ubuntu-base')[0]);
    expect(onView).toHaveBeenCalledWith(tpl);
  });

  it('calls onView when the View Details button is clicked', async () => {
    const tpl = makeTemplate();
    mockGet.mockResolvedValue(listEnvelope([tpl]));
    const onView = jest.fn();

    renderList({ onView });

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    const viewBtn = screen.getByTitle('View Details');
    fireEvent.click(viewBtn);
    expect(onView).toHaveBeenCalledWith(tpl);
  });

  it('calls onEdit when the Edit button is clicked', async () => {
    const tpl = makeTemplate();
    mockGet.mockResolvedValue(listEnvelope([tpl]));
    const onEdit = jest.fn();

    renderList({ onEdit });

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    fireEvent.click(screen.getByTitle('Edit Template'));
    expect(onEdit).toHaveBeenCalledWith(tpl);
  });

  it('calls onDelete with the template id when the Delete button is clicked', async () => {
    const tpl = makeTemplate();
    mockGet.mockResolvedValue(listEnvelope([tpl]));
    const onDelete = jest.fn();

    renderList({ onDelete });

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    fireEvent.click(screen.getByTitle('Delete Template'));
    expect(onDelete).toHaveBeenCalledWith(tpl.id);
  });

  it('calls onDuplicate when the Duplicate button is clicked', async () => {
    const tpl = makeTemplate();
    mockGet.mockResolvedValue(listEnvelope([tpl]));
    const onDuplicate = jest.fn();

    renderList({ onDuplicate });

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    fireEvent.click(screen.getByTitle('Duplicate Template'));
    expect(onDuplicate).toHaveBeenCalledWith(tpl);
  });

  // ---------------------------------------------------------------------------
  // Export action
  // ---------------------------------------------------------------------------
  it('calls systemApi.exportTemplate and shows success notification on export', async () => {
    const tpl = makeTemplate();
    // exportTemplate calls apiClient.get with responseType: 'blob'
    mockGet
      .mockResolvedValueOnce(listEnvelope([tpl]))  // list fetch
      .mockResolvedValueOnce({                      // export fetch
        data: new Blob(['{}'], { type: 'application/json' }),
        headers: { 'content-disposition': 'attachment; filename="template.json"' },
      });

    // jsdom does not implement URL.createObjectURL; stub it.
    const createObjectURL = jest.fn(() => 'blob:mock');
    const revokeObjectURL = jest.fn();
    Object.defineProperty(global.URL, 'createObjectURL', { value: createObjectURL, configurable: true });
    Object.defineProperty(global.URL, 'revokeObjectURL', { value: revokeObjectURL, configurable: true });

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    fireEvent.click(screen.getByTitle('Export Template (JSON bundle)'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: `Exported ${tpl.name}` }),
      ),
    );
  });

  it('shows an error notification when export fails', async () => {
    const tpl = makeTemplate();
    mockGet
      .mockResolvedValueOnce(listEnvelope([tpl]))
      .mockRejectedValueOnce(new Error('network error'));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    fireEvent.click(screen.getByTitle('Export Template (JSON bundle)'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: `Failed to export ${tpl.name}` }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------
  it('expands a row to show detailed fields when the chevron is clicked', async () => {
    const tpl = makeTemplate();
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    // The chevron expand button has title "Expand details"
    const expandBtn = screen.getByTitle('Expand details');
    fireEvent.click(expandBtn);

    // Expanded row shows the Admin User label
    await waitFor(() => expect(screen.getByText(/admin user/i)).toBeInTheDocument());
    expect(screen.getByText('ubuntu')).toBeInTheDocument(); // admin_user value
    // Template ID label
    expect(screen.getByText(/template id/i)).toBeInTheDocument();
    // Collapse title should now be visible
    expect(screen.getByTitle('Collapse details')).toBeInTheDocument();
  });

  it('collapses a row when the chevron is clicked again', async () => {
    const tpl = makeTemplate();
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    const expandBtn = screen.getByTitle('Expand details');
    fireEvent.click(expandBtn);
    await waitFor(() => expect(screen.getByTitle('Collapse details')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() => expect(screen.getByTitle('Expand details')).toBeInTheDocument());
    // Admin User label gone after collapse
    expect(screen.queryByText(/admin user/i)).not.toBeInTheDocument();
  });

  it('renders a configuration block in the expanded row when config is non-empty', async () => {
    const tpl = makeTemplate({ config: { disk_size: 20, cpu: 4 } });
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() => expect(screen.getByText(/configuration/i)).toBeInTheDocument());
    // config rendered as JSON in a <pre>
    const pre = document.querySelector('pre');
    expect(pre).toBeInTheDocument();
    expect(pre!.textContent).toContain('disk_size');
  });

  // ---------------------------------------------------------------------------
  // Search filter (client-side)
  // ---------------------------------------------------------------------------
  it('filters templates by search text (name match)', async () => {
    const tpl1 = makeTemplate({ id: 'tpl-001', name: 'ubuntu-base' });
    const tpl2 = makeTemplate({ id: 'tpl-002', name: 'debian-slim', description: 'Slim Debian' });
    mockGet.mockResolvedValue(listEnvelope([tpl1, tpl2]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));
    expect(screen.getAllByText('debian-slim').length).toBeGreaterThan(0);

    fireEvent.change(screen.getByPlaceholderText('Search templates...'), {
      target: { value: 'ubuntu' },
    });

    await waitFor(() =>
      expect(screen.queryAllByText('debian-slim')).toHaveLength(0),
    );
    expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0);
  });

  it('filters by description text', async () => {
    const tpl1 = makeTemplate({ id: 'tpl-001', name: 'ubuntu-base', description: 'Ubuntu LTS' });
    const tpl2 = makeTemplate({ id: 'tpl-002', name: 'debian-slim', description: 'Slim Debian' });
    mockGet.mockResolvedValue(listEnvelope([tpl1, tpl2]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    fireEvent.change(screen.getByPlaceholderText('Search templates...'), {
      target: { value: 'slim' },
    });

    await waitFor(() =>
      expect(screen.queryAllByText('ubuntu-base')).toHaveLength(0),
    );
    expect(screen.getAllByText('debian-slim').length).toBeGreaterThan(0);
  });

  it('filters by node_platform_name text', async () => {
    const tpl1 = makeTemplate({ id: 'tpl-001', name: 'ubuntu-base', node_platform_name: 'x86 Bare Metal' });
    const tpl2 = makeTemplate({ id: 'tpl-002', name: 'arm-base', node_platform_name: 'ARM Platform' });
    mockGet.mockResolvedValue(listEnvelope([tpl1, tpl2]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));

    fireEvent.change(screen.getByPlaceholderText('Search templates...'), {
      target: { value: 'arm' },
    });

    await waitFor(() =>
      expect(screen.queryAllByText('ubuntu-base')).toHaveLength(0),
    );
    expect(screen.getAllByText('arm-base').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Visibility filter (client-side)
  // ---------------------------------------------------------------------------
  it('filters to only public templates when visibility=public is selected', async () => {
    const pub = makeTemplate({ id: 'tpl-pub', name: 'pub-tpl', public: true });
    const priv = makeTemplate({ id: 'tpl-priv', name: 'priv-tpl', public: false });
    mockGet.mockResolvedValue(listEnvelope([pub, priv]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('pub-tpl').length).toBeGreaterThan(0));

    // The visibility select has options "All Visibility", "Public", "Private"
    const visibilitySelect = screen.getByDisplayValue('All Visibility');
    fireEvent.change(visibilitySelect, { target: { value: 'public' } });

    await waitFor(() => expect(screen.queryAllByText('priv-tpl')).toHaveLength(0));
    expect(screen.getAllByText('pub-tpl').length).toBeGreaterThan(0);
  });

  it('filters to only private templates when visibility=private is selected', async () => {
    const pub = makeTemplate({ id: 'tpl-pub', name: 'pub-tpl', public: true });
    const priv = makeTemplate({ id: 'tpl-priv', name: 'priv-tpl', public: false });
    mockGet.mockResolvedValue(listEnvelope([pub, priv]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('pub-tpl').length).toBeGreaterThan(0));

    const visibilitySelect = screen.getByDisplayValue('All Visibility');
    fireEvent.change(visibilitySelect, { target: { value: 'private' } });

    await waitFor(() => expect(screen.queryAllByText('pub-tpl')).toHaveLength(0));
    expect(screen.getAllByText('priv-tpl').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Status / enabled filter (client-side)
  // ---------------------------------------------------------------------------
  it('filters to only enabled templates when enabled filter is selected', async () => {
    const enabled = makeTemplate({ id: 'tpl-e', name: 'enabled-tpl', enabled: true });
    const disabled = makeTemplate({ id: 'tpl-d', name: 'disabled-tpl', enabled: false });
    mockGet.mockResolvedValue(listEnvelope([enabled, disabled]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('enabled-tpl').length).toBeGreaterThan(0));

    const statusSelect = screen.getByDisplayValue('All Status');
    fireEvent.change(statusSelect, { target: { value: 'enabled' } });

    await waitFor(() => expect(screen.queryAllByText('disabled-tpl')).toHaveLength(0));
    expect(screen.getAllByText('enabled-tpl').length).toBeGreaterThan(0);
  });

  it('filters to only disabled templates when disabled filter is selected', async () => {
    const enabled = makeTemplate({ id: 'tpl-e', name: 'enabled-tpl', enabled: true });
    const disabled = makeTemplate({ id: 'tpl-d', name: 'disabled-tpl', enabled: false });
    mockGet.mockResolvedValue(listEnvelope([enabled, disabled]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('enabled-tpl').length).toBeGreaterThan(0));

    const statusSelect = screen.getByDisplayValue('All Status');
    fireEvent.change(statusSelect, { target: { value: 'disabled' } });

    await waitFor(() => expect(screen.queryAllByText('enabled-tpl')).toHaveLength(0));
    expect(screen.getAllByText('disabled-tpl').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Platform deep-link filter (?platform=<id>)
  // ---------------------------------------------------------------------------
  it('pre-filters by platformId from ?platform query param and shows the clear chip', async () => {
    const match = makeTemplate({ id: 'tpl-1', name: 'matching', node_platform_id: 'plat-abc' });
    const other = makeTemplate({ id: 'tpl-2', name: 'other-platform', node_platform_id: 'plat-xyz' });
    mockGet.mockResolvedValue(listEnvelope([match, other]));

    renderList({ searchParams: 'platform=plat-abc' });

    await waitFor(() => expect(screen.getAllByText('matching').length).toBeGreaterThan(0));
    // other-platform row should be filtered out
    expect(screen.queryAllByText('other-platform')).toHaveLength(0);
    // Clear chip is rendered
    expect(screen.getByText('Filtered by platform')).toBeInTheDocument();
  });

  it('clears the platform filter chip and shows all templates', async () => {
    const match = makeTemplate({ id: 'tpl-1', name: 'matching', node_platform_id: 'plat-abc' });
    const other = makeTemplate({ id: 'tpl-2', name: 'other-platform', node_platform_id: 'plat-xyz' });
    mockGet.mockResolvedValue(listEnvelope([match, other]));

    renderList({ searchParams: 'platform=plat-abc' });

    await waitFor(() => expect(screen.getByText('Filtered by platform')).toBeInTheDocument());

    // Click the X on the chip
    fireEvent.click(screen.getByTitle('Clear platform filter'));

    await waitFor(() =>
      expect(screen.queryByText('Filtered by platform')).not.toBeInTheDocument(),
    );
    // Both templates should now appear
    expect(screen.getAllByText('matching').length).toBeGreaterThan(0);
    expect(screen.getAllByText('other-platform').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------
  it('shows an error notification when the API call fails', async () => {
    mockGet.mockRejectedValue(new Error('network error'));

    renderList();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Failed to load templates' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Multiple rows
  // ---------------------------------------------------------------------------
  it('renders multiple template rows', async () => {
    const templates = [
      makeTemplate({ id: 'tpl-a', name: 'alpha' }),
      makeTemplate({ id: 'tpl-b', name: 'beta' }),
      makeTemplate({ id: 'tpl-c', name: 'gamma' }),
    ];
    mockGet.mockResolvedValue(listEnvelope(templates));

    renderList();

    await waitFor(() => expect(screen.getAllByText('alpha').length).toBeGreaterThan(0));
    expect(screen.getAllByText('beta').length).toBeGreaterThan(0);
    expect(screen.getAllByText('gamma').length).toBeGreaterThan(0);
  });

  // ---------------------------------------------------------------------------
  // "none" modules label
  // ---------------------------------------------------------------------------
  it('shows "none" when a template has no modules', async () => {
    const tpl = makeTemplate({ modules: [], module_count: 0 });
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));
    expect(screen.getByText('none')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Platform column — no platform_id
  // ---------------------------------------------------------------------------
  it('renders platform name as plain text when no node_platform_id is set', async () => {
    const tpl = makeTemplate({ node_platform_id: undefined, node_platform_name: 'standalone' });
    mockGet.mockResolvedValue(listEnvelope([tpl]));

    renderList();

    await waitFor(() => expect(screen.getAllByText('ubuntu-base').length).toBeGreaterThan(0));
    expect(screen.getAllByText('standalone').length).toBeGreaterThan(0);
  });
});
