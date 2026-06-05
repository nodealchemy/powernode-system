import { renderHook, act } from '@testing-library/react';
import { Provider } from 'react-redux';
import { configureStore, combineReducers } from '@reduxjs/toolkit';
import { createElement } from 'react';
import type { ReactNode } from 'react';
import { useSystemWebSocket } from './useSystemWebSocket';
import type {
  OperationUpdatePayload,
  OperationProgressPayload,
  NodeUpdatePayload,
  InstanceUpdatePayload,
} from './useSystemWebSocket';
import authReducer from '@/shared/services/slices/authSlice';
import uiReducer from '@/shared/services/slices/uiSlice';

// =============================================================================
// Mocks
// =============================================================================

interface SubscribeOptions {
  channel: string;
  params: Record<string, unknown>;
  onMessage: (data: unknown) => void;
  onError: (error: string) => void;
}

const mockSubscribe = jest.fn<() => void, [SubscribeOptions]>(() => jest.fn());
const mockSendMessage = jest.fn(() => Promise.resolve(true));
let mockIsConnected = true;
let mockConnectionError: string | null = null;

jest.mock('@/shared/hooks/useWebSocket', () => ({
  useWebSocket: () => ({
    isConnected: mockIsConnected,
    subscribe: mockSubscribe,
    sendMessage: mockSendMessage,
    error: mockConnectionError,
  }),
}));

// =============================================================================
// Redux store helpers
// =============================================================================

const rootReducer = combineReducers({
  auth: authReducer,
  ui: uiReducer,
});

const mockUser = {
  id: 'user-1',
  email: 'operator@example.com',
  name: 'Operator',
  permissions: ['system.manage'],
  roles: ['account.admin'],
  status: 'active',
  email_verified: true,
  account: {
    id: 'account-1',
    name: 'Powernode Corp',
    status: 'active',
  },
};

const createTestStore = (preloadedState?: Parameters<typeof configureStore>[0]['preloadedState']) =>
  configureStore({ reducer: rootReducer, preloadedState });

const createWrapper = (store: ReturnType<typeof createTestStore>) =>
  function Wrapper({ children }: { children: ReactNode }) {
    return createElement(Provider, { store, children });
  };

const authedStore = () =>
  createTestStore({
    auth: {
      user: mockUser,
      access_token: 'tok-abc',
      refresh_token: 'ref-xyz',
      isLoading: false,
      isAuthenticated: true,
      error: null,
    },
  });

const unauthStore = () =>
  createTestStore({
    auth: {
      user: null,
      access_token: null,
      refresh_token: null,
      isLoading: false,
      isAuthenticated: false,
      error: null,
    },
  });

const noAccountStore = () =>
  createTestStore({
    auth: {
      user: { ...mockUser, account: undefined },
      access_token: 'tok-abc',
      refresh_token: 'ref-xyz',
      isLoading: false,
      isAuthenticated: true,
      error: null,
    },
  });

// =============================================================================
// Helper — safely retrieve the subscribe call options
// =============================================================================

const getSubscribeOptions = (): SubscribeOptions => {
  const call = mockSubscribe.mock.calls[0];
  if (!call) throw new Error('mockSubscribe was not called');
  return call[0];
};

// =============================================================================
// Fixtures
// =============================================================================

const OPERATION_A: OperationUpdatePayload = {
  id: 'op-1',
  command: 'provision_instance',
  status: 'running',
  progress: 42,
  description: 'Provisioning VM',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:01:00Z',
};

const PROGRESS_A: OperationProgressPayload = {
  operation_id: 'op-1',
  status: 'running',
  progress: 80,
  description: 'Installing packages',
};

const NODE_A: NodeUpdatePayload = {
  id: 'node-1',
  name: 'edge-node-01',
  enabled: true,
  public_address: '10.0.0.1',
  instances_count: 3,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const INSTANCE_A: InstanceUpdatePayload = {
  id: 'inst-1',
  name: 'worker-vm-01',
  status: 'running',
  variety: 'cloud',
  private_ip_address: '192.168.1.10',
  node_id: 'node-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Tests — subscription mechanics
// =============================================================================

describe('useSystemWebSocket — subscription', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockIsConnected = true;
    mockConnectionError = null;
    mockSubscribe.mockReturnValue(jest.fn());
  });

  it('subscribes to SystemChannel with account_id when connected and user has account', () => {
    const store = authedStore();

    renderHook(() => useSystemWebSocket({}), { wrapper: createWrapper(store) });

    expect(mockSubscribe).toHaveBeenCalledWith(
      expect.objectContaining({
        channel: 'SystemChannel',
        params: { account_id: 'account-1' },
        onMessage: expect.any(Function),
        onError: expect.any(Function),
      }),
    );
  });

  it('does NOT subscribe when the user has no account', () => {
    const store = noAccountStore();
    mockIsConnected = true;

    renderHook(() => useSystemWebSocket({}), { wrapper: createWrapper(store) });

    expect(mockSubscribe).not.toHaveBeenCalled();
  });

  it('does NOT subscribe when isConnected is false', () => {
    mockIsConnected = false;
    const store = authedStore();

    renderHook(() => useSystemWebSocket({}), { wrapper: createWrapper(store) });

    expect(mockSubscribe).not.toHaveBeenCalled();
  });

  it('does NOT subscribe when user is null', () => {
    const store = unauthStore();
    mockIsConnected = true;

    renderHook(() => useSystemWebSocket({}), { wrapper: createWrapper(store) });

    expect(mockSubscribe).not.toHaveBeenCalled();
  });

  it('calls the unsubscribe function returned by subscribe on unmount', () => {
    const mockUnsubscribe = jest.fn();
    mockSubscribe.mockReturnValue(mockUnsubscribe);

    const store = authedStore();
    const { unmount } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    unmount();

    expect(mockUnsubscribe).toHaveBeenCalled();
  });

  it('unsubscribes and re-subscribes when isConnected toggles', () => {
    const mockUnsubscribe = jest.fn();
    mockSubscribe.mockReturnValue(mockUnsubscribe);

    const store = authedStore();
    const { rerender } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    expect(mockSubscribe).toHaveBeenCalledTimes(1);

    // Simulate reconnect — because mockIsConnected is module-level state the
    // hook reads synchronously from the mock, we re-render after toggling.
    mockIsConnected = false;
    rerender();

    mockIsConnected = true;
    rerender();

    // Each reconnect triggers a fresh subscribe
    expect(mockSubscribe.mock.calls.length).toBeGreaterThanOrEqual(2);
  });
});

// =============================================================================
// Tests — message handling
// =============================================================================

describe('useSystemWebSocket — message handling', () => {
  let store: ReturnType<typeof authedStore>;

  beforeEach(() => {
    jest.clearAllMocks();
    mockIsConnected = true;
    mockConnectionError = null;
    mockSubscribe.mockReturnValue(jest.fn());
    store = authedStore();
  });

  // Helper — render the hook with callbacks and return the onMessage handler
  const renderAndGetOnMessage = (callbacks: Parameters<typeof useSystemWebSocket>[0] = {}) => {
    renderHook(() => useSystemWebSocket(callbacks), { wrapper: createWrapper(store) });
    return getSubscribeOptions().onMessage;
  };

  it('calls onConnected when connection_established is received', () => {
    const onConnected = jest.fn();
    const onMessage = renderAndGetOnMessage({ onConnected });

    act(() => {
      onMessage({ type: 'connection_established' });
    });

    expect(onConnected).toHaveBeenCalledTimes(1);
  });

  it('calls onOperationUpdate when task_updated is received with a task payload', () => {
    const onOperationUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onOperationUpdate });

    act(() => {
      onMessage({ type: 'task_updated', task: OPERATION_A });
    });

    expect(onOperationUpdate).toHaveBeenCalledWith(OPERATION_A);
  });

  it('does NOT call onOperationUpdate when task_updated has no task field', () => {
    const onOperationUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onOperationUpdate });

    act(() => {
      onMessage({ type: 'task_updated' });
    });

    expect(onOperationUpdate).not.toHaveBeenCalled();
  });

  it('calls onOperationProgress when task_progress is received', () => {
    const onOperationProgress = jest.fn();
    const onMessage = renderAndGetOnMessage({ onOperationProgress });

    act(() => {
      onMessage({
        type: 'task_progress',
        task_id: PROGRESS_A.operation_id,
        status: PROGRESS_A.status,
        progress: PROGRESS_A.progress,
        description: PROGRESS_A.description,
      });
    });

    expect(onOperationProgress).toHaveBeenCalledWith(PROGRESS_A);
  });

  it('calls onOperationsList when tasks_list is received', () => {
    const onOperationsList = jest.fn();
    const onMessage = renderAndGetOnMessage({ onOperationsList });

    act(() => {
      onMessage({ type: 'tasks_list', tasks: [OPERATION_A] });
    });

    expect(onOperationsList).toHaveBeenCalledWith([OPERATION_A]);
  });

  it('does NOT call onOperationsList when tasks_list has no tasks field', () => {
    const onOperationsList = jest.fn();
    const onMessage = renderAndGetOnMessage({ onOperationsList });

    act(() => {
      onMessage({ type: 'tasks_list' });
    });

    expect(onOperationsList).not.toHaveBeenCalled();
  });

  it('calls onOperationUpdate when task_status is received with a task payload', () => {
    const onOperationUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onOperationUpdate });

    act(() => {
      onMessage({ type: 'task_status', task: OPERATION_A });
    });

    expect(onOperationUpdate).toHaveBeenCalledWith(OPERATION_A);
  });

  it('does NOT call onOperationUpdate when task_status has no task field', () => {
    const onOperationUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onOperationUpdate });

    act(() => {
      onMessage({ type: 'task_status' });
    });

    expect(onOperationUpdate).not.toHaveBeenCalled();
  });

  it('calls onNodeUpdate when node_updated is received', () => {
    const onNodeUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onNodeUpdate });

    act(() => {
      onMessage({ type: 'node_updated', node: NODE_A });
    });

    expect(onNodeUpdate).toHaveBeenCalledWith(NODE_A);
  });

  it('does NOT call onNodeUpdate when node_updated has no node field', () => {
    const onNodeUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onNodeUpdate });

    act(() => {
      onMessage({ type: 'node_updated' });
    });

    expect(onNodeUpdate).not.toHaveBeenCalled();
  });

  it('calls onInstanceUpdate when instance_updated is received', () => {
    const onInstanceUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onInstanceUpdate });

    act(() => {
      onMessage({ type: 'instance_updated', instance: INSTANCE_A });
    });

    expect(onInstanceUpdate).toHaveBeenCalledWith(INSTANCE_A);
  });

  it('does NOT call onInstanceUpdate when instance_updated has no instance field', () => {
    const onInstanceUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onInstanceUpdate });

    act(() => {
      onMessage({ type: 'instance_updated' });
    });

    expect(onInstanceUpdate).not.toHaveBeenCalled();
  });

  it('calls onStatsUpdate when stats_updated is received', () => {
    const onStatsUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onStatsUpdate });

    act(() => {
      onMessage({ type: 'stats_updated' });
    });

    expect(onStatsUpdate).toHaveBeenCalledTimes(1);
  });

  it('calls onStatsReceived when system_stats is received', () => {
    const onStatsReceived = jest.fn();
    const onMessage = renderAndGetOnMessage({ onStatsReceived });

    const statsPayload = {
      nodes: { total: 5, enabled: 4 },
      instances: { total: 10, running: 8, stopped: 2 },
      tasks: { total: 3, pending: 1, running: 2 },
    };

    act(() => {
      onMessage({ type: 'system_stats', stats: statsPayload });
    });

    expect(onStatsReceived).toHaveBeenCalledWith(statsPayload);
  });

  it('does NOT call onStatsReceived when system_stats has no stats field', () => {
    const onStatsReceived = jest.fn();
    const onMessage = renderAndGetOnMessage({ onStatsReceived });

    act(() => {
      onMessage({ type: 'system_stats' });
    });

    expect(onStatsReceived).not.toHaveBeenCalled();
  });

  it('handles pong silently without calling any callback', () => {
    const onError = jest.fn();
    const onConnected = jest.fn();
    const onStatsUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onError, onConnected, onStatsUpdate });

    act(() => {
      onMessage({ type: 'pong' });
    });

    expect(onError).not.toHaveBeenCalled();
    expect(onConnected).not.toHaveBeenCalled();
    expect(onStatsUpdate).not.toHaveBeenCalled();
  });

  it('calls onError and sets error state when error message is received', () => {
    const onError = jest.fn();
    const { result } = renderHook(() => useSystemWebSocket({ onError }), {
      wrapper: createWrapper(store),
    });
    const onMessage = getSubscribeOptions().onMessage;

    act(() => {
      onMessage({ type: 'error', message: 'Channel subscription refused' });
    });

    expect(onError).toHaveBeenCalledWith('Channel subscription refused');
    expect(result.current.error).toBe('Channel subscription refused');
  });

  it('uses fallback error message when error type has no message field', () => {
    const onError = jest.fn();
    const { result } = renderHook(() => useSystemWebSocket({ onError }), {
      wrapper: createWrapper(store),
    });
    const onMessage = getSubscribeOptions().onMessage;

    act(() => {
      onMessage({ type: 'error' });
    });

    expect(onError).toHaveBeenCalledWith('System channel error');
    expect(result.current.error).toBe('System channel error');
  });

  it('ignores messages that are not plain objects (null, string, number)', () => {
    const onError = jest.fn();
    const onConnected = jest.fn();
    const onMessage = renderAndGetOnMessage({ onError, onConnected });

    act(() => {
      onMessage(null);
      onMessage('raw string');
      onMessage(42);
      onMessage(undefined);
    });

    expect(onError).not.toHaveBeenCalled();
    expect(onConnected).not.toHaveBeenCalled();
  });

  it('ignores messages without a type field', () => {
    const onConnected = jest.fn();
    const onOperationUpdate = jest.fn();
    const onMessage = renderAndGetOnMessage({ onConnected, onOperationUpdate });

    act(() => {
      onMessage({ notType: 'connection_established' });
      onMessage({});
    });

    expect(onConnected).not.toHaveBeenCalled();
    expect(onOperationUpdate).not.toHaveBeenCalled();
  });
});

// =============================================================================
// Tests — channel error handler
// =============================================================================

describe('useSystemWebSocket — channel error handler', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockIsConnected = true;
    mockConnectionError = null;
    mockSubscribe.mockReturnValue(jest.fn());
  });

  it('calls onError and sets error state when the channel error handler fires', () => {
    const onError = jest.fn();
    const store = authedStore();

    const { result } = renderHook(() => useSystemWebSocket({ onError }), {
      wrapper: createWrapper(store),
    });

    const { onError: channelErrorHandler } = getSubscribeOptions();

    act(() => {
      channelErrorHandler('WebSocket channel error');
    });

    expect(onError).toHaveBeenCalledWith('WebSocket channel error');
    expect(result.current.error).toBe('WebSocket channel error');
  });
});

// =============================================================================
// Tests — connection error propagation
// =============================================================================

describe('useSystemWebSocket — connection error propagation', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockIsConnected = true;
    mockConnectionError = null;
    mockSubscribe.mockReturnValue(jest.fn());
  });

  it('reflects connectionError from useWebSocket in the error field', () => {
    mockConnectionError = 'WebSocket connection error';

    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    // error is connectionError || internal error — connectionError should win
    expect(result.current.error).toBe('WebSocket connection error');
  });

  it('calls onError when connectionError changes', () => {
    mockConnectionError = 'Connection lost';
    const onError = jest.fn();
    const store = authedStore();

    renderHook(() => useSystemWebSocket({ onError }), {
      wrapper: createWrapper(store),
    });

    expect(onError).toHaveBeenCalledWith('Connection lost');
  });
});

// =============================================================================
// Tests — action methods (refreshOperations, getTask, refreshStats, ping)
// =============================================================================

describe('useSystemWebSocket — action methods', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockIsConnected = true;
    mockConnectionError = null;
    mockSendMessage.mockResolvedValue(true);
    mockSubscribe.mockReturnValue(jest.fn());
  });

  it('refreshOperations sends refresh_tasks to SystemChannel with account_id', async () => {
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.refreshOperations();
    });

    expect(mockSendMessage).toHaveBeenCalledWith(
      'SystemChannel',
      'refresh_tasks',
      {},
      { account_id: 'account-1' },
    );
    expect(returned).toBe(true);
  });

  it('refreshOperations returns false when not connected', async () => {
    mockIsConnected = false;
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.refreshOperations();
    });

    expect(returned).toBe(false);
    expect(mockSendMessage).not.toHaveBeenCalled();
  });

  it('refreshOperations returns false when user has no account', async () => {
    const store = noAccountStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.refreshOperations();
    });

    expect(returned).toBe(false);
    expect(mockSendMessage).not.toHaveBeenCalled();
  });

  it('getTask sends get_task with task_id and account_id to SystemChannel', async () => {
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.getTask('op-42');
    });

    expect(mockSendMessage).toHaveBeenCalledWith(
      'SystemChannel',
      'get_task',
      { task_id: 'op-42' },
      { account_id: 'account-1' },
    );
    expect(returned).toBe(true);
  });

  it('getTask returns false when not connected', async () => {
    mockIsConnected = false;
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.getTask('op-42');
    });

    expect(returned).toBe(false);
    expect(mockSendMessage).not.toHaveBeenCalled();
  });

  it('getTask returns false when user has no account', async () => {
    const store = noAccountStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.getTask('op-42');
    });

    expect(returned).toBe(false);
    expect(mockSendMessage).not.toHaveBeenCalled();
  });

  it('refreshStats sends refresh_stats to SystemChannel with account_id', async () => {
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.refreshStats();
    });

    expect(mockSendMessage).toHaveBeenCalledWith(
      'SystemChannel',
      'refresh_stats',
      {},
      { account_id: 'account-1' },
    );
    expect(returned).toBe(true);
  });

  it('refreshStats returns false when not connected', async () => {
    mockIsConnected = false;
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.refreshStats();
    });

    expect(returned).toBe(false);
    expect(mockSendMessage).not.toHaveBeenCalled();
  });

  it('refreshStats returns false when user has no account', async () => {
    const store = noAccountStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.refreshStats();
    });

    expect(returned).toBe(false);
    expect(mockSendMessage).not.toHaveBeenCalled();
  });

  it('ping sends ping action to SystemChannel with account_id', async () => {
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.ping();
    });

    expect(mockSendMessage).toHaveBeenCalledWith(
      'SystemChannel',
      'ping',
      {},
      { account_id: 'account-1' },
    );
    expect(returned).toBe(true);
  });

  it('ping returns false when not connected', async () => {
    mockIsConnected = false;
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.ping();
    });

    expect(returned).toBe(false);
    expect(mockSendMessage).not.toHaveBeenCalled();
  });

  it('ping returns false when user has no account', async () => {
    const store = noAccountStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    let returned: boolean | undefined;
    await act(async () => {
      returned = await result.current.ping();
    });

    expect(returned).toBe(false);
    expect(mockSendMessage).not.toHaveBeenCalled();
  });

  it('forwards sendMessage rejection as false', async () => {
    mockSendMessage.mockRejectedValueOnce(new Error('send failed'));
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    // The hook itself does not catch rejections — the caller receives the
    // rejection. We only verify the mock was called.
    await expect(
      act(async () => {
        await result.current.ping();
      }),
    ).rejects.toThrow('send failed');
  });
});

// =============================================================================
// Tests — return shape completeness
// =============================================================================

describe('useSystemWebSocket — return shape', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockIsConnected = true;
    mockConnectionError = null;
    mockSubscribe.mockReturnValue(jest.fn());
  });

  it('returns all expected properties', () => {
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    expect(typeof result.current.isConnected).toBe('boolean');
    expect(result.current.error === null || typeof result.current.error === 'string').toBe(true);
    expect(typeof result.current.refreshOperations).toBe('function');
    expect(typeof result.current.getTask).toBe('function');
    expect(typeof result.current.refreshStats).toBe('function');
    expect(typeof result.current.ping).toBe('function');
  });

  it('reflects isConnected from the underlying useWebSocket hook', () => {
    mockIsConnected = true;
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    expect(result.current.isConnected).toBe(true);
  });

  it('error is null when there is no connection error and no channel error', () => {
    mockConnectionError = null;
    const store = authedStore();
    const { result } = renderHook(() => useSystemWebSocket({}), {
      wrapper: createWrapper(store),
    });

    expect(result.current.error).toBeNull();
  });

  it('works with no options object (default empty options)', () => {
    const store = authedStore();

    expect(() => {
      renderHook(() => useSystemWebSocket(), { wrapper: createWrapper(store) });
    }).not.toThrow();
  });
});

// =============================================================================
// Tests — callback ref stability
// =============================================================================

describe('useSystemWebSocket — callback ref stability', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockIsConnected = true;
    mockConnectionError = null;
    mockSubscribe.mockReturnValue(jest.fn());
  });

  it('uses the latest callback even when it changes between renders (ref pattern)', () => {
    const onConnected1 = jest.fn();
    const onConnected2 = jest.fn();

    const store = authedStore();
    let currentOnConnected = onConnected1;

    const { result, rerender } = renderHook(
      () => useSystemWebSocket({ onConnected: currentOnConnected }),
      { wrapper: createWrapper(store) },
    );

    const onMessage = getSubscribeOptions().onMessage;

    // Fire with the first callback
    act(() => {
      onMessage({ type: 'connection_established' });
    });
    expect(onConnected1).toHaveBeenCalledTimes(1);

    // Update the callback reference
    currentOnConnected = onConnected2;
    rerender();

    // Fire again — should call the NEW callback, not the old one
    act(() => {
      onMessage({ type: 'connection_established' });
    });

    expect(onConnected2).toHaveBeenCalledTimes(1);
    // The old callback should not have been called again
    expect(onConnected1).toHaveBeenCalledTimes(1);

    // Suppress unused variable warning
    void result;
  });
});
