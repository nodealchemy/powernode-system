import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { ModulePuppetAssignmentsPanel } from './ModulePuppetAssignmentsPanel';
import type { PuppetAssignment } from '@system/features/system/services/api/puppetApi';

// =============================================================================
// Mocks
// =============================================================================

const mockHasPermission = jest.fn((_perm: string) => true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (perm: string) => mockHasPermission(perm),
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

const mockGetAssignments = jest.fn();
const mockGetPuppetModules = jest.fn();
const mockCreateAssignment = jest.fn();
const mockUpdateAssignment = jest.fn();
const mockDeleteAssignment = jest.fn();

jest.mock('@system/features/system/services/api/puppetApi', () => ({
  puppetApi: {
    getPuppetModuleAssignments: (...args: unknown[]) => mockGetAssignments(...args),
    getPuppetModules: (...args: unknown[]) => mockGetPuppetModules(...args),
    createPuppetAssignment: (...args: unknown[]) => mockCreateAssignment(...args),
    updatePuppetAssignment: (...args: unknown[]) => mockUpdateAssignment(...args),
    deletePuppetAssignment: (...args: unknown[]) => mockDeleteAssignment(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const ASSIGNMENT: PuppetAssignment = {
  id: 'mpa-1',
  node_module_id: 'mod-1',
  puppet_module_id: 'pm-1',
  puppet_module_name: 'profile_base',
  enabled: true,
  priority: 5,
  config: {},
  parameters: {},
};

const META = {
  current_page: 1, per_page: 25, total_count: 1, total_pages: 1, next_page: null, prev_page: null,
};

beforeEach(() => {
  jest.clearAllMocks();
  mockHasPermission.mockReturnValue(true);
  mockGetAssignments.mockResolvedValue([ASSIGNMENT]);
  mockGetPuppetModules.mockResolvedValue({
    puppetModules: [
      { id: 'pm-1', name: 'profile_base' },
      { id: 'pm-2', name: 'profile_extra' },
    ],
    meta: META,
  });
});

// =============================================================================
// Tests
// =============================================================================

describe('ModulePuppetAssignmentsPanel', () => {
  it('lists puppet assignments with name, priority and enabled state', async () => {
    render(<ModulePuppetAssignmentsPanel moduleId="mod-1" />);

    expect(await screen.findByText('profile_base')).toBeInTheDocument();
    expect(screen.getByText('enabled')).toBeInTheDocument();
    expect(mockGetAssignments).toHaveBeenCalledWith('mod-1');
  });

  it('shows an empty state when no puppet modules are assigned', async () => {
    mockGetAssignments.mockResolvedValue([]);

    render(<ModulePuppetAssignmentsPanel moduleId="mod-1" />);

    expect(await screen.findByText(/No puppet modules assigned/i)).toBeInTheDocument();
  });

  it('creates an assignment from the add form', async () => {
    mockCreateAssignment.mockResolvedValue({ ...ASSIGNMENT, id: 'mpa-2', puppet_module_id: 'pm-2' });

    render(<ModulePuppetAssignmentsPanel moduleId="mod-1" />);
    await screen.findByText('profile_base');

    fireEvent.click(screen.getByRole('button', { name: /Assign puppet module/i }));
    const select = await screen.findByLabelText(/Puppet module/i);
    fireEvent.change(select, { target: { value: 'pm-2' } });
    fireEvent.click(screen.getByRole('button', { name: /^Assign$/i }));

    await waitFor(() =>
      expect(mockCreateAssignment).toHaveBeenCalledWith('mod-1', expect.objectContaining({
        puppet_module_id: 'pm-2',
      }))
    );
    await waitFor(() => expect(mockGetAssignments).toHaveBeenCalledTimes(2));
  });

  it('toggles enabled via update', async () => {
    mockUpdateAssignment.mockResolvedValue({ ...ASSIGNMENT, enabled: false });

    render(<ModulePuppetAssignmentsPanel moduleId="mod-1" />);
    await screen.findByText('profile_base');

    fireEvent.click(screen.getByTitle('Disable assignment'));

    await waitFor(() =>
      expect(mockUpdateAssignment).toHaveBeenCalledWith('mod-1', 'mpa-1', { enabled: false })
    );
  });

  it('removes an assignment after confirm', async () => {
    jest.spyOn(window, 'confirm').mockReturnValue(true);
    mockDeleteAssignment.mockResolvedValue(undefined);

    render(<ModulePuppetAssignmentsPanel moduleId="mod-1" />);
    await screen.findByText('profile_base');

    fireEvent.click(screen.getByTitle('Remove assignment'));

    await waitFor(() =>
      expect(mockDeleteAssignment).toHaveBeenCalledWith('mod-1', 'mpa-1')
    );
    await waitFor(() => expect(mockGetAssignments).toHaveBeenCalledTimes(2));
  });

  it('hides write controls without puppet write permissions', async () => {
    mockHasPermission.mockImplementation((perm: string) => perm === 'system.puppet.read');

    render(<ModulePuppetAssignmentsPanel moduleId="mod-1" />);
    await screen.findByText('profile_base');

    expect(screen.queryByRole('button', { name: /Assign puppet module/i })).not.toBeInTheDocument();
    expect(screen.queryByTitle('Disable assignment')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Remove assignment')).not.toBeInTheDocument();
  });
});
