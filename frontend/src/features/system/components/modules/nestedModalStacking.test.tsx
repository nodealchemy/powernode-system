import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ModuleDetailModal } from './ModuleDetailModal';

/**
 * Nested-modal stacking guard for the core-`Modal` migration (IMP-a354b985dbf3).
 *
 * `ModuleDetailModal` can have three different dialogs sitting on top of it:
 * its own Add Dependency form, the shared delete confirmation, and — on the
 * Puppet tab — the assign form that `ModulePuppetAssignmentsPanel` raises. All
 * are core `Modal`s registering Escape on `document`, so a single keypress
 * would close the child AND the detail modal underneath unless the parent
 * stands its own handler down.
 *
 * The puppet arm is the one worth writing down: that dialog's state lives two
 * components away and reaches the parent only through a callback prop, so a
 * reviewer reading `ModuleDetailModal` alone cannot see whether it is covered.
 */

const mockGetModule = jest.fn();
const mockGetModuleDependencies = jest.fn();
const mockGetModules = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getModule: (...args: unknown[]) => mockGetModule(...args),
    getModuleDependencies: (...args: unknown[]) => mockGetModuleDependencies(...args),
    getModules: (...args: unknown[]) => mockGetModules(...args),
    addModuleDependency: jest.fn(),
    removeModuleDependency: jest.fn(),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => true }),
}));

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({ addNotification: jest.fn(), showNotification: jest.fn() }),
}));

jest.mock('@/shared/components/entity', () => ({
  EntityLink: ({ label, id }: { label?: React.ReactNode; id?: string | null }) => (
    <span>{label ?? id}</span>
  ),
}));

// The versions panel does its own fetching and is irrelevant here.
jest.mock('./ModuleVersionsPanel', () => ({
  ModuleVersionsPanel: () => <div data-testid="versions-panel" />,
}));

// The puppet panel is deliberately NOT mocked: its assign dialog is the arm of
// the parent's Escape guard that travels through a callback prop, and a mocked
// panel would open no dialog at all.
const mockGetPuppetAssignments = jest.fn();
const mockGetPuppetModules = jest.fn();
jest.mock('@system/features/system/services/api/puppetApi', () => ({
  puppetApi: {
    getPuppetModuleAssignments: (...args: unknown[]) => mockGetPuppetAssignments(...args),
    getPuppetModules: (...args: unknown[]) => mockGetPuppetModules(...args),
    createPuppetAssignment: jest.fn(),
    updatePuppetAssignment: jest.fn(),
    deletePuppetAssignment: jest.fn(),
  },
}));

const BASE_MODULE = {
  id: 'mod-1',
  name: 'ssh-base',
  description: 'SSH baseline',
  variety: 'base',
  enabled: true,
  public: false,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const DEP_MODULE = {
  ...BASE_MODULE,
  id: 'mod-2',
  name: 'ssl-certs',
};

const dialogs = () => Array.from(document.querySelectorAll('[role="dialog"]'));

function renderModal(onClose: jest.Mock) {
  render(
    <BrowserRouter>
      <ModuleDetailModal moduleId="mod-1" isOpen onClose={onClose} />
    </BrowserRouter>,
  );
}

async function openAddDependency(onClose: jest.Mock) {
  renderModal(onClose);
  await screen.findByRole('heading', { name: 'ssh-base' });

  fireEvent.click(screen.getByRole('tab', { name: /dependencies/i }));
  fireEvent.click(await screen.findByRole('button', { name: /add dependency/i }));
  await waitFor(() => expect(dialogs()).toHaveLength(2));
}

async function openRemoveConfirmation(onClose: jest.Mock) {
  mockGetModuleDependencies.mockResolvedValue([DEP_MODULE]);
  renderModal(onClose);
  await screen.findByRole('heading', { name: 'ssh-base' });

  fireEvent.click(screen.getByRole('tab', { name: /dependencies/i }));
  await screen.findByText('ssl-certs');
  fireEvent.click(screen.getByTitle('Remove dependency'));
  await waitFor(() => expect(dialogs()).toHaveLength(2));
}

async function openPuppetAssignForm(onClose: jest.Mock) {
  renderModal(onClose);
  await screen.findByRole('heading', { name: 'ssh-base' });

  fireEvent.click(screen.getByRole('tab', { name: /puppet/i }));
  fireEvent.click(await screen.findByRole('button', { name: /assign puppet module/i }));
  await waitFor(() => expect(dialogs()).toHaveLength(2));
}

describe('ModuleDetailModal nested dialog stacking', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetModule.mockResolvedValue(BASE_MODULE);
    mockGetModuleDependencies.mockResolvedValue([]);
    mockGetModules.mockResolvedValue([DEP_MODULE]);
    mockGetPuppetAssignments.mockResolvedValue([]);
    mockGetPuppetModules.mockResolvedValue([]);
  });

  describe('Add Dependency form', () => {
    it('renders after the detail dialog, so it paints on top', async () => {
      await openAddDependency(jest.fn());

      const open = dialogs();
      const inner = screen
        .getByRole('heading', { name: /^add dependency$/i })
        .closest('[role="dialog"]');
      expect(open[open.length - 1]).toBe(inner);
    });

    it('closes only the Add Dependency form on a single Escape', async () => {
      const onClose = jest.fn();
      await openAddDependency(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });

      await waitFor(() => expect(dialogs()).toHaveLength(1));
      expect(onClose).not.toHaveBeenCalled();
    });

    it('closes the detail dialog on Escape once the form is gone', async () => {
      const onClose = jest.fn();
      await openAddDependency(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });
      await waitFor(() => expect(dialogs()).toHaveLength(1));

      fireEvent.keyDown(document, { key: 'Escape' });
      expect(onClose).toHaveBeenCalledTimes(1);
    });
  });

  describe("the puppet tab's assign form", () => {
    it('closes only the assign form on a single Escape', async () => {
      const onClose = jest.fn();
      await openPuppetAssignForm(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });

      await waitFor(() => expect(dialogs()).toHaveLength(1));
      expect(onClose).not.toHaveBeenCalled();
    });

    it('closes the detail dialog on Escape once the assign form is gone', async () => {
      const onClose = jest.fn();
      await openPuppetAssignForm(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });
      await waitFor(() => expect(dialogs()).toHaveLength(1));

      fireEvent.keyDown(document, { key: 'Escape' });
      expect(onClose).toHaveBeenCalledTimes(1);
    });
  });

  describe('remove-dependency confirmation', () => {
    it('closes only the confirmation on a single Escape', async () => {
      const onClose = jest.fn();
      await openRemoveConfirmation(onClose);

      fireEvent.keyDown(document, { key: 'Escape' });

      await waitFor(() => expect(dialogs()).toHaveLength(1));
      expect(onClose).not.toHaveBeenCalled();
    });
  });
});
