import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { NodeDetailModal } from './NodeDetailModal';

/**
 * Nested-modal stacking guard for the core-`Modal` migration (IMP-a354b985dbf3).
 *
 * `NodeDetailModal` was already a core `Modal`, but it still hand-rolled the
 * Delete Instance confirmation inside itself and its Escape guard named only
 * `showApplyTemplateModal` — so the edit, create-instance, edit-instance and
 * delete paths each closed the whole node dialog along with the child.
 *
 * Scope: the Delete Instance confirmation, which is the dialog this migration
 * introduced. It is declared inline in `NodeDetailModal`, so it is a real core
 * `Modal` here regardless of the child-modal stubs below — the stubs exist only
 * to keep their own data fetching out of this file.
 *
 * The other four arms of the guard (`showApplyTemplateModal`, `showEditModal`,
 * `showCreateInstanceModal`, `editInstance`) are named in the component but are
 * NOT exercised here, because each stubbed child registers no Escape listener.
 * They are covered by construction, not by this spec.
 */

// Child modals are stubbed: each fetches on mount, and the confirmation under
// test is rendered by NodeDetailModal itself.
jest.mock('./EditNodeModal', () => ({ EditNodeModal: () => null }));
jest.mock('./CreateInstanceModal', () => ({ CreateInstanceModal: () => null }));
jest.mock('./ApplyTemplateModal', () => ({ ApplyTemplateModal: () => null }));
jest.mock('./EditInstanceModal', () => ({ EditInstanceModal: () => null }));
jest.mock('./ClaudeCodeCredentialPanel', () => ({ ClaudeCodeCredentialPanel: () => null }));

const mockGetNode = jest.fn();
const mockGetNodeInstances = jest.fn();
const mockGetNodeModules = jest.fn();
const mockGetTasks = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getNode: (...args: unknown[]) => mockGetNode(...args),
    getNodeInstances: (...args: unknown[]) => mockGetNodeInstances(...args),
    getNodeModules: (...args: unknown[]) => mockGetNodeModules(...args),
    getTasks: (...args: unknown[]) => mockGetTasks(...args),
    deleteNodeInstance: jest.fn(),
    associatePublicIp: jest.fn(),
    disassociatePublicIp: jest.fn(),
    downloadInstanceBootConfig: jest.fn(),
    getClaudeCodeCredential: jest.fn().mockResolvedValue(null),
    enableModuleAssignment: jest.fn(),
    disableModuleAssignment: jest.fn(),
    getNodeTemplates: jest.fn().mockResolvedValue([]),
    updateNode: jest.fn(),
    createNodeInstance: jest.fn(),
    updateNodeInstance: jest.fn(),
  },
}));

const mockPermissionsApi = { hasPermission: () => true };
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => mockPermissionsApi,
}));

// The returned object must be STABLE across renders: `fetchNodeData` is a
// useCallback that lists `addNotification` in its deps, so a fresh function per
// render re-fires the load effect forever and `loading` never clears.
const mockAddNotification = jest.fn();
const mockShowNotification = jest.fn();
const mockNotificationsApi = {
  addNotification: mockAddNotification,
  showNotification: mockShowNotification,
};
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => mockNotificationsApi,
}));

const mockWsApi = {
  isConnected: false,
  error: null,
  refreshOperations: jest.fn(),
  getTask: jest.fn(),
  refreshStats: jest.fn(),
  ping: jest.fn(),
};
jest.mock('@system/features/system/hooks/useSystemWebSocket', () => ({
  useSystemWebSocket: () => mockWsApi,
}));

const NODE = {
  id: 'node-1',
  name: 'prod-cluster',
  description: 'Production cluster',
  enabled: true,
  status: 'running',
  public_address: '1.2.3.4',
  allocate_public_ip: true,
  config: { datacenter: 'us-east' },
  node_template_id: 'tpl-1',
  node_template_name: 'base-template',
  instance_count: 1,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const INSTANCE = {
  id: 'inst-1',
  name: 'web-01',
  variety: 'cloud' as const,
  status: 'running',
  private_ip_address: '10.0.0.1',
  public_ip_address: '5.5.5.5',
  config: {},
  node_id: 'node-1',
  created_at: '2026-01-02T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
};

const dialogs = () => Array.from(document.querySelectorAll('[role="dialog"]'));

async function openDeleteInstanceConfirm(onClose: jest.Mock) {
  render(
    <BrowserRouter>
      <NodeDetailModal nodeId="node-1" isOpen onClose={onClose} />
    </BrowserRouter>,
  );
  await screen.findByRole('heading', { name: 'prod-cluster' });

  const instancesTab = screen
    .getAllByRole('tab')
    .find((t) => t.textContent?.includes('Instances'));
  if (!instancesTab) throw new Error('Instances tab not found');
  fireEvent.click(instancesTab);

  fireEvent.click((await screen.findAllByTitle('Delete Instance'))[0]);
  await waitFor(() => expect(dialogs()).toHaveLength(2));
}

describe('NodeDetailModal nested dialog stacking', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockGetNode.mockResolvedValue(NODE);
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE] });
    mockGetNodeModules.mockResolvedValue({ node_modules: [] });
    mockGetTasks.mockResolvedValue({
      tasks: [],
      meta: { current_page: 1, per_page: 50, total_count: 0, total_pages: 1, next_page: null, prev_page: null },
    });
  });

  it('renders the delete confirmation after the node dialog, so it paints on top', async () => {
    await openDeleteInstanceConfirm(jest.fn());

    const open = dialogs();
    const confirm = screen
      .getByRole('heading', { name: /delete instance/i })
      .closest('[role="dialog"]');
    expect(open[open.length - 1]).toBe(confirm);
  });

  it('closes only the delete confirmation on a single Escape', async () => {
    const onClose = jest.fn();
    await openDeleteInstanceConfirm(onClose);

    fireEvent.keyDown(document, { key: 'Escape' });

    await waitFor(() => expect(dialogs()).toHaveLength(1));
    expect(onClose).not.toHaveBeenCalled();
  });

  it('closes the node dialog on Escape once the confirmation is gone', async () => {
    const onClose = jest.fn();
    await openDeleteInstanceConfirm(onClose);

    fireEvent.keyDown(document, { key: 'Escape' });
    await waitFor(() => expect(dialogs()).toHaveLength(1));

    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
