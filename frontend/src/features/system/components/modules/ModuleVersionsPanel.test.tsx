import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { ModuleVersionsPanel } from './ModuleVersionsPanel';
import type { SystemNodeModuleVersion } from '@system/features/system/types/system.types';

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

const mockGetModuleVersions = jest.fn();
const mockPromoteModuleVersion = jest.fn();
const mockRollbackModule = jest.fn();

jest.mock('@system/features/system/services/api/modulesApi', () => ({
  modulesApi: {
    getModuleVersions: (...args: unknown[]) => mockGetModuleVersions(...args),
    promoteModuleVersion: (...args: unknown[]) => mockPromoteModuleVersion(...args),
    rollbackModule: (...args: unknown[]) => mockRollbackModule(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const VERSION_LIVE: SystemNodeModuleVersion = {
  id: 'ver-1',
  node_module_id: 'mod-a',
  version_number: 1,
  promotion_state: 'live',
  changelog: 'initial',
  oci_digest: 'sha256:aaa',
  staging_baked_at: '2026-06-01T00:00:00Z',
  blessed_at: '2026-06-02T00:00:00Z',
  live_at: '2026-06-03T00:00:00Z',
  retired_at: null,
  created_at: '2026-06-01T00:00:00Z',
};

const VERSION_BUILT: SystemNodeModuleVersion = {
  id: 'ver-2',
  node_module_id: 'mod-a',
  version_number: 2,
  promotion_state: 'built',
  changelog: 'second cut',
  oci_digest: 'sha256:bbb',
  staging_baked_at: null,
  blessed_at: null,
  live_at: null,
  retired_at: null,
  created_at: '2026-07-01T00:00:00Z',
};

beforeEach(() => {
  jest.clearAllMocks();
  mockGetModuleVersions.mockResolvedValue({
    versions: [VERSION_BUILT, VERSION_LIVE],
    current_version_id: 'ver-1',
    current_version_number: 1,
  });
});

// =============================================================================
// Rendering
// =============================================================================

describe('ModuleVersionsPanel rendering', () => {
  it('lists versions with promotion state and marks the current version', async () => {
    render(<ModuleVersionsPanel moduleId="mod-a" canUpdate />);

    expect(await screen.findByText('v2')).toBeInTheDocument();
    expect(screen.getByText('v1')).toBeInTheDocument();
    expect(screen.getByText('built')).toBeInTheDocument();
    expect(screen.getByText('live')).toBeInTheDocument();
    expect(screen.getByText('current')).toBeInTheDocument();
    expect(mockGetModuleVersions).toHaveBeenCalledWith('mod-a');
  });

  it('shows an empty state when there are no versions', async () => {
    mockGetModuleVersions.mockResolvedValue({
      versions: [],
      current_version_id: null,
      current_version_number: null,
    });

    render(<ModuleVersionsPanel moduleId="mod-a" canUpdate />);

    expect(await screen.findByText(/No versions yet/i)).toBeInTheDocument();
  });
});

// =============================================================================
// Promote
// =============================================================================

describe('ModuleVersionsPanel promote', () => {
  it('promotes a built version to staging and refreshes', async () => {
    mockPromoteModuleVersion.mockResolvedValue({
      node_module_version: { ...VERSION_BUILT, promotion_state: 'staging' },
    });

    render(<ModuleVersionsPanel moduleId="mod-a" canUpdate />);
    await screen.findByText('v2');

    fireEvent.click(screen.getByTitle('Promote to staging'));

    await waitFor(() =>
      expect(mockPromoteModuleVersion).toHaveBeenCalledWith('ver-2', 'staging')
    );
    await waitFor(() => expect(mockGetModuleVersions).toHaveBeenCalledTimes(2));
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' })
    );
    // An ungated promote carries no verdict, so nothing to warn about.
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'warning' })
    );
  });

  // IMP-bdb650b82c65 — consult-and-WARN (operator ruling D17). The backend
  // never refuses a manual promote; what it does is return
  // `promotion_criteria_warning` when the fleet has not earned the rung. The
  // panel must SHOW that, beside the success — otherwise the operator's only
  // record of the override is a FleetEvent they did not know to look for.
  it('shows the promotion-criteria warning when a gated promote outruns the evidence', async () => {
    const VERSION_STAGING: SystemNodeModuleVersion = {
      ...VERSION_BUILT,
      id: 'ver-4',
      version_number: 4,
      promotion_state: 'staging',
      staging_baked_at: '2026-07-02T00:00:00Z',
    };
    mockGetModuleVersions.mockResolvedValue({
      versions: [VERSION_STAGING, VERSION_LIVE],
      current_version_id: 'ver-1',
      current_version_number: 1,
    });
    const warning =
      'promoted to blessed despite unmet promotion criteria: running_count 0 < required 3';
    mockPromoteModuleVersion.mockResolvedValue({
      node_module_version: { ...VERSION_STAGING, promotion_state: 'blessed' },
      promotion_criteria: {
        eligible: false,
        reason: 'running_count 0 < required 3',
        running_count: 0,
        required_count: 3,
      },
      promotion_criteria_warning: warning,
    });

    render(<ModuleVersionsPanel moduleId="mod-a" canUpdate />);
    await screen.findByText('v4');

    fireEvent.click(screen.getByTitle('Promote to blessed'));

    await waitFor(() =>
      expect(mockPromoteModuleVersion).toHaveBeenCalledWith('ver-4', 'blessed')
    );
    // The promotion still went through (never refuse) ...
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' })
    );
    // ... and the override is surfaced, carrying the criteria's own reason.
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({
        type: 'warning',
        message: expect.stringContaining('running_count 0 < required 3'),
      })
    );
    await waitFor(() => expect(mockGetModuleVersions).toHaveBeenCalledTimes(2));
  });

  it('surfaces a rejected transition as an error notification', async () => {
    mockPromoteModuleVersion.mockRejectedValue(new Error('cannot transition from built to live'));

    render(<ModuleVersionsPanel moduleId="mod-a" canUpdate />);
    await screen.findByText('v2');

    fireEvent.click(screen.getByTitle('Promote to staging'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' })
      )
    );
  });

  it('offers no promote controls without canUpdate', async () => {
    render(<ModuleVersionsPanel moduleId="mod-a" canUpdate={false} />);
    await screen.findByText('v2');

    expect(screen.queryByTitle('Promote to staging')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Roll back to this version')).not.toBeInTheDocument();
  });
});

// =============================================================================
// Rollback
// =============================================================================

describe('ModuleVersionsPanel rollback', () => {
  it('rolls the module spec back to a prior version after confirm', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockRollbackModule.mockResolvedValue({
      node_module: { id: 'mod-a' },
      new_version: { id: 'ver-3', version_number: 3, changelog: null },
    });
    const onModuleChanged = jest.fn();

    render(<ModuleVersionsPanel moduleId="mod-a" canUpdate onModuleChanged={onModuleChanged} />);
    await screen.findByText('v2');

    // Rollback targets a NON-current version — v2 here (v1 is current).
    fireEvent.click(screen.getByTitle('Roll back to this version'));

    await waitFor(() =>
      expect(mockRollbackModule).toHaveBeenCalledWith('mod-a', { targetVersionId: 'ver-2' })
    );
    await waitFor(() => expect(onModuleChanged).toHaveBeenCalled());
    await waitFor(() => expect(mockGetModuleVersions).toHaveBeenCalledTimes(2));
  });

  it('does not roll back when the confirm is dismissed', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(false);

    render(<ModuleVersionsPanel moduleId="mod-a" canUpdate />);
    await screen.findByText('v2');

    fireEvent.click(screen.getByTitle('Roll back to this version'));

    expect(mockRollbackModule).not.toHaveBeenCalled();
  });
});
