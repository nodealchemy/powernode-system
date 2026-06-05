import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { CreateModuleFromPackageModal } from './CreateModuleFromPackageModal';
import type {
  ResolveDependenciesPreview,
  SuggestArchitecturesResult,
  CreateModuleResult,
  SystemPackageRepository,
} from '@system/features/system/services/api/packageRepositoriesApi';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: jest.fn(),
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
// Fixtures
// =============================================================================

const REPO: SystemPackageRepository = {
  id: 'repo-1',
  name: 'ubuntu-noble',
  kind: 'apt',
  visibility: 'account',
  base_url: 'http://archive.ubuntu.com/ubuntu',
  architectures: ['amd64', 'arm64'],
  priority: 100,
  enabled: true,
  sync_status: 'idle',
  package_count: 4000,
  shared: false,
  node_platform_ids: [],
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PREVIEW_EMPTY: ResolveDependenciesPreview = {
  required_packages: [],
  required_edges: [],
  recommends_candidates: [],
  suggests_candidates: [],
  alternatives_chosen: {},
  warnings: [],
  errors: [],
};

const PREVIEW_WITH_DEPS: ResolveDependenciesPreview = {
  required_packages: [
    { name: 'libssl3', version: '3.0.0', architecture: 'amd64', installed_size_bytes: 512000 },
    { name: 'libc6', version: '2.38', architecture: 'amd64', installed_size_bytes: 1024000 },
  ],
  required_edges: [{ from: 'nginx', to: 'libssl3', type: 'depends' }],
  recommends_candidates: [
    {
      from: 'nginx',
      to: 'nginx-extras',
      summary: 'Extended nginx modules',
      installed_size_bytes: 204800,
      transitive_required_if_chosen: ['libgd3'],
    },
    {
      from: 'nginx',
      to: 'nginx-doc',
      summary: 'Documentation for nginx',
      installed_size_bytes: 102400,
      transitive_required_if_chosen: [],
    },
  ],
  suggests_candidates: [
    { from: 'nginx', to: 'apache2', summary: 'Alternative web server' },
  ],
  alternatives_chosen: {},
  warnings: [],
  errors: [],
};

const PREVIEW_WITH_ERRORS: ResolveDependenciesPreview = {
  ...PREVIEW_WITH_DEPS,
  errors: ['Conflicting package: libssl3 vs libssl-dev'],
};

const SUGGESTION_ACTIVE: SuggestArchitecturesResult = {
  repository_id: 'repo-1',
  suggested: ['amd64'],
  rationale: [
    { arch: 'amd64', node_platforms: 5, packages: 3000, reason: 'Most fleet nodes use amd64' },
  ],
  fallback: false,
  confidence: 'high',
};

const SUGGESTION_FALLBACK: SuggestArchitecturesResult = {
  repository_id: 'repo-1',
  suggested: [],
  rationale: [],
  fallback: true,
  confidence: 'low',
};

const CREATE_RESULT: CreateModuleResult = {
  top_level_module: { id: 'mod-42', name: 'nginx', auto_generated: true, public: false },
  dependency_modules: [{ id: 'mod-43', name: 'libssl3' }],
  recommends_modules: [],
  dependencies_created: 1,
  build_dispatches: [{ dispatch_id: 'disp-1', architecture: 'amd64', ok: true }],
  warnings: [],
};

// =============================================================================
// Envelope helper — matches the AxiosResponse<{success,data}> shape that
// extractData() expects: { data: { success: true, data: <payload> } }
// =============================================================================

function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

// =============================================================================
// Default props / render helper
// =============================================================================

const defaultProps = {
  repository: REPO,
  packageName: 'nginx',
  architectures: ['amd64', 'arm64'],
  open: true,
  onClose: jest.fn(),
  onCreated: jest.fn(),
};

function renderModal(overrides: Partial<typeof defaultProps> = {}) {
  const props = { ...defaultProps, ...overrides };
  return render(<CreateModuleFromPackageModal {...props} />);
}

// =============================================================================
// Tests
// =============================================================================

describe('CreateModuleFromPackageModal', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockAddNotification.mockReset();
    defaultProps.onClose = jest.fn();
    defaultProps.onCreated = jest.fn();
  });

  // ---------------------------------------------------------------------------
  // Visibility gate
  // ---------------------------------------------------------------------------

  it('renders nothing when open=false', () => {
    renderModal({ open: false });
    expect(screen.queryByText('Create Module from Package')).not.toBeInTheDocument();
  });

  it('renders the modal heading when open=true', () => {
    // Fire both API calls but don't resolve yet — we just check that the
    // heading is present while loading.
    mockPost.mockReturnValue(new Promise(() => {})); // never resolves
    renderModal();
    expect(screen.getByText('Create Module from Package')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Loading state
  // ---------------------------------------------------------------------------

  it('shows a loading indicator while resolving dependencies', () => {
    mockPost.mockReturnValue(new Promise(() => {})); // never resolves
    renderModal();
    expect(screen.getByText(/resolving dependency closure/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Header subtitle — package name, repo name, and architectures
  // ---------------------------------------------------------------------------

  it('shows package name and repository name in the subtitle', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.queryByText(/resolving dependency closure/i)).not.toBeInTheDocument());

    expect(screen.getByText(/nginx/)).toBeInTheDocument();
    expect(screen.getByText(/ubuntu-noble/)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // API calls — exact URLs and payloads
  // ---------------------------------------------------------------------------

  it('calls resolveDependencies with correct URL and payload on open', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(mockPost).toHaveBeenCalledWith(
      '/system/packages/resolve_dependencies',
      {
        repository_id: 'repo-1',
        package_name: 'nginx',
        architecture: 'amd64',
      },
    ));
  });

  it('calls suggestArchitectures with correct URL and payload on open', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(mockPost).toHaveBeenCalledWith(
      '/system/packages/suggest_architectures',
      { repository_id: 'repo-1' },
    ));
  });

  it('does not fire API calls when modal is closed', () => {
    renderModal({ open: false });
    expect(mockPost).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Error state — resolveDependencies fails
  // ---------------------------------------------------------------------------

  it('shows an error message when resolveDependencies rejects', async () => {
    mockPost
      .mockRejectedValueOnce(new Error('Network timeout'))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText('Network timeout')).toBeInTheDocument());
    expect(screen.queryByText(/resolving dependency closure/i)).not.toBeInTheDocument();
  });

  it('shows a generic error when the rejection value is not an Error instance', async () => {
    mockPost
      .mockRejectedValueOnce('oops')
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText('Failed to resolve dependencies')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Required dependencies section
  // ---------------------------------------------------------------------------

  it('renders required packages in the left pane', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText('libssl3')).toBeInTheDocument());
    expect(screen.getByText('libc6')).toBeInTheDocument();
    // Size formatting: 512000 bytes → 500 KB (512000 / 1024 = 500)
    expect(screen.getByText('500 KB')).toBeInTheDocument();
    // 1024000 bytes: 1024000 < 1048576 (1024*1024), so → 1000 KB
    expect(screen.getByText('1000 KB')).toBeInTheDocument();
  });

  it('shows "no transitive requires" when required list is empty', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText(/no transitive requires/i)).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Recommends section — opt-in checkboxes
  // ---------------------------------------------------------------------------

  it('renders recommends candidates as checkboxes', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText('nginx-extras')).toBeInTheDocument());
    expect(screen.getByText('nginx-doc')).toBeInTheDocument();

    const checkboxes = screen.getAllByRole('checkbox');
    expect(checkboxes).toHaveLength(2);
    checkboxes.forEach((cb) => expect(cb).not.toBeChecked());
  });

  it('shows "no recommends offered" when list is empty', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText(/no recommends offered/i)).toBeInTheDocument());
  });

  it('shows summary and size for a recommends candidate', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText('Extended nginx modules')).toBeInTheDocument());
    // 204800 bytes → 200 KB
    expect(screen.getByText('200 KB')).toBeInTheDocument();
  });

  it('shows transitive deps count when non-zero', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText('+1 transitive deps')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Toggle recommends — checkbox selection and totals update
  // ---------------------------------------------------------------------------

  it('checks a recommend checkbox when clicked and updates selection counter', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => screen.getAllByRole('checkbox'));

    const checkboxes = screen.getAllByRole('checkbox');
    // Initially 0 / 2
    expect(screen.getByText('0 / 2 selected')).toBeInTheDocument();

    fireEvent.click(checkboxes[0]);
    await waitFor(() => expect(checkboxes[0]).toBeChecked());
    expect(screen.getByText('1 / 2 selected')).toBeInTheDocument();

    // Toggle off again
    fireEvent.click(checkboxes[0]);
    await waitFor(() => expect(checkboxes[0]).not.toBeChecked());
    expect(screen.getByText('0 / 2 selected')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Total size / module count footer
  // ---------------------------------------------------------------------------

  it('shows correct module count and size in the footer', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    // 2 required packages, 0 recommends selected
    await waitFor(() => expect(screen.getByText('2 NodeModules')).toBeInTheDocument());
    // 512000 + 1024000 = 1536000 → 1.5 MB
    expect(screen.getByText('~1.5 MB installed')).toBeInTheDocument();
  });

  it('updates total when a recommend is selected', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => screen.getAllByRole('checkbox'));

    // Select nginx-extras (1 package + 1 transitive = 2 extra modules)
    const checkboxes = screen.getAllByRole('checkbox');
    fireEvent.click(checkboxes[0]); // nginx-extras

    // 2 required + 1 (nginx-extras) + 1 (libgd3 transitive) = 4 modules
    await waitFor(() => expect(screen.getByText('4 NodeModules')).toBeInTheDocument());
    // Extra size: 204800 bytes = 200 KB. Total: 1536000 + 204800 = 1740800 → 1.7 MB
    expect(screen.getByText('~1.7 MB installed')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Errors in preview — disables Create button
  // ---------------------------------------------------------------------------

  it('disables the Create button and shows error text when preview has errors', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_ERRORS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText(/cannot proceed/i)).toBeInTheDocument());
    // The error text is rendered inside the same div as "Cannot proceed: "
    expect(screen.getByText(/Conflicting package: libssl3 vs libssl-dev/)).toBeInTheDocument();

    const createBtn = screen.getByRole('button', { name: /create .* modules/i });
    expect(createBtn).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Suggests section (informational only)
  // ---------------------------------------------------------------------------

  it('shows suggests in a collapsed details element', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText(/suggests \(1\)/i)).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Architecture suggestion — AI badge
  // ---------------------------------------------------------------------------

  it('shows AI badge and highlights architecture when suggestion is non-fallback', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_ACTIVE));

    renderModal();

    await waitFor(() => expect(screen.getByText(/AI · high/)).toBeInTheDocument());
    // Effective arch is the suggested one (amd64 only, not arm64)
    // amd64 appears in the subtitle; arm64 should NOT appear there since suggestion overrides
    expect(screen.queryByText(/amd64, arm64/)).not.toBeInTheDocument();
  });

  it('shows rationale in a details element when suggestion is applied', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_ACTIVE));

    renderModal();

    await waitFor(() => expect(screen.getByText('Why these architectures?')).toBeInTheDocument());
    // The rationale reason text is a text node inside a <li> that also contains
    // an arch span and a platforms span — use regex to match it as a substring.
    expect(screen.getByText(/Most fleet nodes use amd64/)).toBeInTheDocument();
    // node_platforms count rendered inside its own <span>
    expect(screen.getByText(/5 platforms/)).toBeInTheDocument();
  });

  it('uses prop architectures when suggestion is fallback', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.queryByText(/resolving dependency closure/i)).not.toBeInTheDocument());
    // Should show prop architectures in the subtitle
    expect(screen.getByText(/amd64, arm64/)).toBeInTheDocument();
    expect(screen.queryByText(/AI ·/)).not.toBeInTheDocument();
  });

  it('uses prop architectures when suggestArchitectures call fails', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockRejectedValueOnce(new Error('suggestion service down'));

    renderModal();

    await waitFor(() => expect(screen.queryByText(/resolving dependency closure/i)).not.toBeInTheDocument());
    expect(screen.getByText(/amd64, arm64/)).toBeInTheDocument();
    expect(screen.queryByText(/AI ·/)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Architecture count in footer
  // ---------------------------------------------------------------------------

  it('shows singular "architecture" for a single-arch result', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_ACTIVE)); // suggests only amd64

    renderModal();

    await waitFor(() => expect(screen.getByText('1 architecture')).toBeInTheDocument());
  });

  it('shows plural "architectures" for multi-arch result', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK)); // falls back to props (2 arches)

    renderModal();

    await waitFor(() => expect(screen.getByText('2 architectures')).toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  it('calls onClose when the × button is clicked', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    const onClose = jest.fn();
    renderModal({ onClose });

    // × button is always rendered
    fireEvent.click(screen.getByText('×'));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when the Cancel button is clicked after preview loads', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    const onClose = jest.fn();
    renderModal({ onClose });

    await waitFor(() => expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // handleCreate — success path
  // ---------------------------------------------------------------------------

  it('calls createModuleFromPackage with correct URL and payload on submit', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK))
      .mockResolvedValueOnce(envelope(CREATE_RESULT));

    const onCreated = jest.fn();
    const onClose = jest.fn();
    renderModal({ onCreated, onClose });

    await waitFor(() => screen.getByRole('button', { name: /create .* modules/i }));
    fireEvent.click(screen.getByRole('button', { name: /create .* modules/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/packages/create_module', {
        repository_id: 'repo-1',
        package_name: 'nginx',
        architectures: ['amd64', 'arm64'], // fallback → prop arches
        recommends_selected: [],
      }),
    );
  });

  it('uses suggested architectures (not prop) in createModuleFromPackage when suggestion is applied', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_ACTIVE)) // suggests ['amd64']
      .mockResolvedValueOnce(envelope(CREATE_RESULT));

    renderModal();

    await waitFor(() => screen.getByRole('button', { name: /create .* modules/i }));
    fireEvent.click(screen.getByRole('button', { name: /create .* modules/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/packages/create_module', {
        repository_id: 'repo-1',
        package_name: 'nginx',
        architectures: ['amd64'], // AI-suggested, not ['amd64', 'arm64']
        recommends_selected: [],
      }),
    );
  });

  it('includes selected recommends in the createModuleFromPackage payload', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_WITH_DEPS))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK))
      .mockResolvedValueOnce(envelope(CREATE_RESULT));

    renderModal();

    await waitFor(() => screen.getAllByRole('checkbox'));

    // Select nginx-doc (second checkbox)
    const checkboxes = screen.getAllByRole('checkbox');
    fireEvent.click(checkboxes[1]); // nginx-doc

    await waitFor(() => expect(checkboxes[1]).toBeChecked());

    fireEvent.click(screen.getByRole('button', { name: /create .* modules/i }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/packages/create_module', expect.objectContaining({
        recommends_selected: ['nginx-doc'],
      })),
    );
  });

  it('calls onCreated with top_level_module.id and then onClose on success', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK))
      .mockResolvedValueOnce(envelope(CREATE_RESULT));

    const onCreated = jest.fn();
    const onClose = jest.fn();
    renderModal({ onCreated, onClose });

    await waitFor(() => screen.getByRole('button', { name: /create .* modules/i }));
    fireEvent.click(screen.getByRole('button', { name: /create .* modules/i }));

    await waitFor(() => expect(onCreated).toHaveBeenCalledWith('mod-42'));
    expect(onClose).toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // handleCreate — submitting state
  // ---------------------------------------------------------------------------

  it('shows "Creating…" and disables button while submitting', async () => {
    let resolveCreate!: (v: unknown) => void;
    const createPromise = new Promise((res) => { resolveCreate = res; });

    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK))
      .mockReturnValueOnce(createPromise);

    renderModal();

    await waitFor(() => screen.getByRole('button', { name: /create .* modules/i }));
    fireEvent.click(screen.getByRole('button', { name: /create .* modules/i }));

    await waitFor(() => expect(screen.getByRole('button', { name: /creating…/i })).toBeDisabled());

    // Clean up — resolve the pending promise
    resolveCreate(envelope(CREATE_RESULT));
  });

  // ---------------------------------------------------------------------------
  // handleCreate — error path
  // ---------------------------------------------------------------------------

  it('shows an error notification when createModuleFromPackage fails', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK))
      .mockRejectedValueOnce(new Error('Build queue unavailable'));

    renderModal();

    await waitFor(() => screen.getByRole('button', { name: /create .* modules/i }));
    fireEvent.click(screen.getByRole('button', { name: /create .* modules/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Build queue unavailable',
      }),
    );
  });

  it('shows generic notification message when create failure is not an Error instance', async () => {
    mockPost
      .mockResolvedValueOnce(envelope(PREVIEW_EMPTY))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK))
      .mockRejectedValueOnce('raw string rejection');

    renderModal();

    await waitFor(() => screen.getByRole('button', { name: /create .* modules/i }));
    fireEvent.click(screen.getByRole('button', { name: /create .* modules/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Materialization failed',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Size formatting helper (tested via rendered output)
  // ---------------------------------------------------------------------------

  it('formats bytes < 1024 as "B"', async () => {
    const preview: ResolveDependenciesPreview = {
      ...PREVIEW_EMPTY,
      required_packages: [
        { name: 'tiny', version: '1.0', architecture: 'amd64', installed_size_bytes: 512 },
      ],
    };
    mockPost
      .mockResolvedValueOnce(envelope(preview))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText('512 B')).toBeInTheDocument());
  });

  it('formats bytes in KB range', async () => {
    const preview: ResolveDependenciesPreview = {
      ...PREVIEW_EMPTY,
      required_packages: [
        { name: 'small', version: '1.0', architecture: 'amd64', installed_size_bytes: 2048 },
      ],
    };
    mockPost
      .mockResolvedValueOnce(envelope(preview))
      .mockResolvedValueOnce(envelope(SUGGESTION_FALLBACK));

    renderModal();

    await waitFor(() => expect(screen.getByText('2 KB')).toBeInTheDocument());
  });
});
