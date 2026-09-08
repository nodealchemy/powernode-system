import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { PlatformFormModal } from './PlatformFormModal';
import type { SystemNodePlatform } from '@system/features/system/types/system.types';

/**
 * Nested-modal stacking guard for the core-`Modal` migration (IMP-a354b985dbf3).
 *
 * In edit mode `PlatformFormModal` renders `DiskImageHistoryTab`, which raises
 * its own rollback-confirmation dialog. Both are now core `Modal`s and the core
 * `Modal` registers its Escape listener on `document`, so one keypress would
 * close the confirm AND the platform form underneath it. `DiskImageHistoryTab`
 * reports the confirm's open state upward and the form stands its handler down.
 *
 * The confirm is two components deep, so the seam being exercised here is a
 * callback prop, not local state — which is exactly the part a reviewer reading
 * only `PlatformFormModal` would not see.
 */

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({ addNotification: jest.fn(), showNotification: jest.fn() }),
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => true }),
}));

jest.mock('@/shared/hooks/useAuth', () => ({
  useAuth: () => ({ currentUser: { account: { id: 'acct-test' } } }),
}));

jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label }: { label: string }) => <a href="#mock">{label}</a>,
}));

// A stable wrapper, because `jest.clearAllMocks()` in beforeEach would strip a
// factory-supplied implementation and leave `subscribe` returning undefined —
// which DiskImageHistoryTab then calls as its effect cleanup.
const mockWsSubscribe = jest.fn();
jest.mock('@/shared/services/WebSocketManager', () => ({
  wsManager: {
    subscribe: (...args: unknown[]) => mockWsSubscribe(...args),
  },
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

const mockGetArchitectures = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getArchitectures: (...args: unknown[]) => mockGetArchitectures(...args),
    createPlatform: jest.fn(),
    updatePlatform: jest.fn(),
  },
}));

const mockListPublications = jest.fn();
jest.mock('@system/features/system/services/api/diskImagePublicationsApi', () => ({
  diskImagePublicationsApi: {
    list: (...args: unknown[]) => mockListPublications(...args),
    rollback: jest.fn(),
  },
}));

const PLATFORM: SystemNodePlatform = {
  id: 'plat-1',
  name: 'Ubuntu 22.04 LTS',
  description: 'Main platform',
  enabled: true,
  public: false,
  build_script: '#!/bin/bash\n# build',
  init_script: '#!/bin/bash\n# init',
  sync_script: '#!/bin/bash\n# sync',
  node_architecture_id: 'arch-1',
  cosign_identity_regexp: 'https://example.com/.+',
  cosign_issuer_regexp: 'https://example.com',
  disk_image_retention_count: 5,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const PUB_RETIRED = {
  id: 'pub-retired',
  platform_id: 'plat-1',
  account_id: 'acct-test',
  status: 'retired',
  active: false,
  git_sha: 'deadbeef1234567890deadbeef1234567890dead',
  git_sha_short: 'deadbee',
  sha256: 'sha256fullhashretiredpub00000000000000000000000000000000000000000',
  sha256_short: 'sha256re',
  arch: 'arm64',
  size_bytes: 512 * 1024,
  attempt_count: 2,
  attestation_present: false,
  cosign_bundle_present: false,
  retired_at: '2026-05-10T12:00:00Z',
  published_at: '2026-04-20T08:00:00Z',
  created_at: '2026-04-20T07:00:00Z',
  updated_at: '2026-05-10T12:00:00Z',
};

async function openRollbackConfirm(onClose: jest.Mock) {
  render(
    <BrowserRouter>
      <PlatformFormModal isOpen onClose={onClose} editPlatform={PLATFORM} />
    </BrowserRouter>,
  );

  await screen.findByRole('heading', { name: /edit platform/i });

  // Only the publication row offers an Activate button until the confirm opens.
  const activate = await screen.findByRole('button', { name: /^activate$/i });
  fireEvent.click(activate);
  await screen.findByRole('heading', { name: /activate publication\?/i });
}

describe('PlatformFormModal + rollback confirm stacking', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockWsSubscribe.mockImplementation(() => () => undefined);
    mockGetArchitectures.mockResolvedValue([]);
    mockListPublications.mockResolvedValue({ publications: [PUB_RETIRED] });
  });

  it('renders the confirm dialog after the form, so it paints on top', async () => {
    await openRollbackConfirm(jest.fn());

    const dialogs = Array.from(document.querySelectorAll('[role="dialog"]'));
    expect(dialogs).toHaveLength(2);

    const confirm = screen
      .getByRole('heading', { name: /activate publication\?/i })
      .closest('[role="dialog"]');
    expect(dialogs[dialogs.length - 1]).toBe(confirm);
  });

  it('closes only the confirm dialog on a single Escape', async () => {
    const onClose = jest.fn();
    await openRollbackConfirm(onClose);

    fireEvent.keyDown(document, { key: 'Escape' });

    await waitFor(() =>
      expect(
        screen.queryByRole('heading', { name: /activate publication\?/i }),
      ).not.toBeInTheDocument(),
    );
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByRole('heading', { name: /edit platform/i })).toBeInTheDocument();
  });

  it('closes the form on Escape once the confirm is gone', async () => {
    const onClose = jest.fn();
    await openRollbackConfirm(onClose);

    fireEvent.keyDown(document, { key: 'Escape' });
    await waitFor(() =>
      expect(
        screen.queryByRole('heading', { name: /activate publication\?/i }),
      ).not.toBeInTheDocument(),
    );

    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
