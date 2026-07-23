import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { AgentPeersTab } from './AgentPeersTab';
import type { SystemNodeInstancePeer } from '@system/features/system/types/system.types';

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

const mockPeersList = jest.fn();
const mockPeersActivate = jest.fn();
const mockPeersDeactivate = jest.fn();
const mockPeersExecute = jest.fn();

jest.mock('@system/features/system/services/api/nodeInstancePeersApi', () => ({
  nodeInstancePeersApi: {
    list: (...args: unknown[]) => mockPeersList(...args),
    get: jest.fn(),
    searchable: jest.fn(),
    activate: (...args: unknown[]) => mockPeersActivate(...args),
    deactivate: (...args: unknown[]) => mockPeersDeactivate(...args),
    execute: (...args: unknown[]) => mockPeersExecute(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const PEER_ACTIVE: SystemNodeInstancePeer = {
  id: 'peer-aaa',
  handle: 'relay-echo',
  node_instance_id: 'inst-001',
  enabled: true,
  status: 'active',
  capabilities: { transports: ['sdwan'] },
  declared_skills: [{ name: 'echo' }, { name: 'deploy' }],
  addresses: ['10.10.0.5'],
  trust_score: 0.8,
  daily_decision_budget: 50,
  daily_decision_used: 3,
  execution_count: 12,
  execution_failure_count: 1,
  first_announced_at: '2026-06-01T00:00:00Z',
  last_announced_at: '2026-07-20T10:00:00Z',
  last_executed_at: '2026-07-19T09:00:00Z',
};

const PEER_REGISTERED: SystemNodeInstancePeer = {
  ...PEER_ACTIVE,
  id: 'peer-bbb',
  handle: 'builder-arm',
  node_instance_id: 'inst-002',
  enabled: false,
  status: 'registered',
  declared_skills: [],
};

const META = {
  current_page: 1,
  per_page: 25,
  total_count: 2,
  total_pages: 1,
  next_page: null,
  prev_page: null,
};

beforeEach(() => {
  jest.clearAllMocks();
  mockHasPermission.mockReturnValue(true);
  mockPeersList.mockResolvedValue({ peers: [PEER_ACTIVE, PEER_REGISTERED], meta: META });
});

// =============================================================================
// Rendering
// =============================================================================

describe('AgentPeersTab rendering', () => {
  it('lists peers with handle and status after load', async () => {
    render(<AgentPeersTab />);

    expect(await screen.findByText('@relay-echo')).toBeInTheDocument();
    expect(screen.getByText('@builder-arm')).toBeInTheDocument();
    expect(screen.getByText('active')).toBeInTheDocument();
    expect(screen.getByText('registered')).toBeInTheDocument();
    expect(mockPeersList).toHaveBeenCalled();
  });

  it('shows an empty state when there are no peers', async () => {
    mockPeersList.mockResolvedValue({ peers: [], meta: { ...META, total_count: 0 } });

    render(<AgentPeersTab />);

    expect(await screen.findByText(/No agent peers/i)).toBeInTheDocument();
  });

  it('shows an error notification when the list fails', async () => {
    mockPeersList.mockRejectedValue(new Error('boom'));

    render(<AgentPeersTab />);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error' })
      )
    );
  });
});

// =============================================================================
// Activate / deactivate
// =============================================================================

describe('AgentPeersTab activate/deactivate', () => {
  it('activates a registered peer and refreshes', async () => {
    mockPeersActivate.mockResolvedValue({ ...PEER_REGISTERED, enabled: true, status: 'active' });

    render(<AgentPeersTab />);
    await screen.findByText('@builder-arm');

    fireEvent.click(screen.getByTitle('Activate peer'));

    await waitFor(() => expect(mockPeersActivate).toHaveBeenCalledWith('peer-bbb'));
    await waitFor(() => expect(mockPeersList).toHaveBeenCalledTimes(2));
  });

  it('deactivates an enabled peer', async () => {
    mockPeersDeactivate.mockResolvedValue({ ...PEER_ACTIVE, enabled: false, status: 'registered' });

    render(<AgentPeersTab />);
    await screen.findByText('@relay-echo');

    fireEvent.click(screen.getByTitle('Deactivate peer'));

    await waitFor(() => expect(mockPeersDeactivate).toHaveBeenCalledWith('peer-aaa'));
  });

  it('hides activate/deactivate without system.peers.activate', async () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.peers.activate');

    render(<AgentPeersTab />);
    await screen.findByText('@relay-echo');

    expect(screen.queryByTitle('Activate peer')).not.toBeInTheDocument();
    expect(screen.queryByTitle('Deactivate peer')).not.toBeInTheDocument();
  });
});

// =============================================================================
// Delegate (execute)
// =============================================================================

describe('AgentPeersTab delegate', () => {
  it('dispatches a task with the chosen skill and JSON input', async () => {
    mockPeersExecute.mockResolvedValue({
      peer: PEER_ACTIVE,
      task_id: 'task-123',
      dispatched_task: { skill: 'echo', input: { msg: 'hi' } },
      message: 'Task dispatched',
    });

    render(<AgentPeersTab />);
    await screen.findByText('@relay-echo');

    fireEvent.click(screen.getByTitle('Delegate task'));

    // Modal: skill select defaults to first declared skill; provide input.
    const input = await screen.findByLabelText(/Input/i);
    fireEvent.change(input, { target: { value: '{"msg":"hi"}' } });
    fireEvent.click(screen.getByRole('button', { name: /Dispatch/i }));

    await waitFor(() =>
      expect(mockPeersExecute).toHaveBeenCalledWith('peer-aaa', {
        skill: 'echo',
        input: { msg: 'hi' },
      })
    );
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'success',
          message: expect.stringContaining('task-123'),
        })
      )
    );
  });

  it('sends non-object JSON input as the raw string (strong-params scalar)', async () => {
    mockPeersExecute.mockResolvedValue({
      peer: PEER_ACTIVE,
      task_id: 'task-789',
      dispatched_task: { skill: 'echo', input: '[1,2,3]' },
      message: 'Task dispatched',
    });

    render(<AgentPeersTab />);
    await screen.findByText('@relay-echo');

    fireEvent.click(screen.getByTitle('Delegate task'));
    const input = await screen.findByLabelText(/Input/i);
    fireEvent.change(input, { target: { value: '[1,2,3]' } });
    fireEvent.click(screen.getByRole('button', { name: /Dispatch/i }));

    await waitFor(() =>
      expect(mockPeersExecute).toHaveBeenCalledWith('peer-aaa', {
        skill: 'echo',
        input: '[1,2,3]',
      })
    );
  });

  it('only offers delegate on enabled peers with system.peers.execute', async () => {
    render(<AgentPeersTab />);
    await screen.findByText('@relay-echo');

    // Exactly one delegate button — the registered peer gets none.
    expect(screen.getAllByTitle('Delegate task')).toHaveLength(1);
  });

  it('hides delegate without system.peers.execute', async () => {
    mockHasPermission.mockImplementation((perm: string) => perm !== 'system.peers.execute');

    render(<AgentPeersTab />);
    await screen.findByText('@relay-echo');

    expect(screen.queryByTitle('Delegate task')).not.toBeInTheDocument();
  });
});
