import { renderHook, act, waitFor } from '@testing-library/react';
import { useConcierge } from './useConcierge';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();
const mockGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
  },
}));

jest.mock('@/shared/utils/logger', () => ({
  logger: {
    error: jest.fn(),
    warn: jest.fn(),
    info: jest.fn(),
    debug: jest.fn(),
  },
}));

// =============================================================================
// Fixtures & Helpers
// =============================================================================

/** Wrap any payload in the backend's double-envelope. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const START_RESPONSE = {
  conversation_id: 'conv-abc123',
  agent_id: 'agent-xyz',
  agent_name: 'Infrastructure Generalist',
  snapshot: 'Ready to assist with fleet operations.',
};

const MSG_USER: { id: string; role: 'user' | 'assistant' | 'system' | 'tool'; content: string; created_at: string } = {
  id: 'msg-1',
  role: 'user',
  content: 'Hello concierge',
  created_at: '2026-06-05T10:00:00Z',
};

const MSG_ASSISTANT: { id: string; role: 'user' | 'assistant' | 'system' | 'tool'; content: string; created_at: string } = {
  id: 'msg-2',
  role: 'assistant',
  content: 'How can I help you today?',
  created_at: '2026-06-05T10:00:01Z',
};

// =============================================================================
// Tests
// =============================================================================

describe('useConcierge', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockGet.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Inactive state (active = false)
  // ---------------------------------------------------------------------------

  describe('when active is false', () => {
    it('returns initial state and does not call any API', () => {
      const { result } = renderHook(() => useConcierge(false));

      expect(result.current.conversationId).toBeNull();
      expect(result.current.agentName).toBeNull();
      expect(result.current.snapshot).toBeNull();
      expect(result.current.messages).toEqual([]);
      expect(result.current.pending).toBe(false);
      expect(result.current.error).toBeNull();
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockGet).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Successful bootstrap (active = true)
  // ---------------------------------------------------------------------------

  describe('bootstrap on mount (active = true)', () => {
    it('calls POST /system/concierge/start then GET messages and populates state', async () => {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));
      mockGet.mockResolvedValueOnce(
        envelope({ messages: [MSG_USER, MSG_ASSISTANT] })
      );

      const { result } = renderHook(() => useConcierge(true));

      // pending goes true while fetching
      expect(result.current.pending).toBe(true);

      await waitFor(() => {
        expect(result.current.conversationId).toBe('conv-abc123');
      });

      expect(result.current.agentName).toBe('Infrastructure Generalist');
      expect(result.current.snapshot).toBe('Ready to assist with fleet operations.');
      expect(result.current.messages).toEqual([MSG_USER, MSG_ASSISTANT]);
      expect(result.current.pending).toBe(false);
      expect(result.current.error).toBeNull();

      // Exact API calls
      expect(mockPost).toHaveBeenCalledWith('/system/concierge/start', {});
      expect(mockGet).toHaveBeenCalledWith('/ai/conversations/conv-abc123/messages');
    });

    it('starts with pending=true then resolves to pending=false', async () => {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));
      mockGet.mockResolvedValueOnce(envelope({ messages: [] }));

      const { result } = renderHook(() => useConcierge(true));

      expect(result.current.pending).toBe(true);

      await waitFor(() => expect(result.current.pending).toBe(false));
    });

    it('does not re-bootstrap when conversationId is already set', async () => {
      // First bootstrap
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));
      mockGet.mockResolvedValueOnce(envelope({ messages: [] }));

      const { result, rerender } = renderHook(({ active }) => useConcierge(active), {
        initialProps: { active: true },
      });

      await waitFor(() => expect(result.current.conversationId).toBe('conv-abc123'));

      const callCount = mockPost.mock.calls.length;

      // Rerender — should NOT bootstrap again
      rerender({ active: true });

      expect(mockPost.mock.calls.length).toBe(callCount);
    });
  });

  // ---------------------------------------------------------------------------
  // Bootstrap error handling
  // ---------------------------------------------------------------------------

  describe('bootstrap error', () => {
    it('sets error when start POST fails', async () => {
      mockPost.mockRejectedValueOnce(new Error('Network failure'));

      const { result } = renderHook(() => useConcierge(true));

      await waitFor(() => expect(result.current.error).toBe('Network failure'));

      expect(result.current.pending).toBe(false);
      expect(result.current.conversationId).toBeNull();
    });

    it('uses fallback error message when thrown value is not an Error', async () => {
      mockPost.mockRejectedValueOnce('something went wrong');

      const { result } = renderHook(() => useConcierge(true));

      await waitFor(() =>
        expect(result.current.error).toBe('Failed to start Concierge')
      );
    });

    it('does not call listMessages when start fails', async () => {
      mockPost.mockRejectedValueOnce(new Error('Timeout'));

      const { result } = renderHook(() => useConcierge(true));

      await waitFor(() => expect(result.current.error).not.toBeNull());

      expect(mockGet).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // send()
  // ---------------------------------------------------------------------------

  describe('send()', () => {
    async function bootstrappedHook() {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));
      mockGet.mockResolvedValueOnce(envelope({ messages: [] }));

      const hook = renderHook(() => useConcierge(true));
      await waitFor(() => expect(hook.result.current.conversationId).toBe('conv-abc123'));
      return hook;
    }

    it('posts to the correct messages URL with the right payload', async () => {
      const { result } = await bootstrappedHook();

      mockPost.mockResolvedValueOnce(
        envelope({
          user_message: MSG_USER,
          assistant_message: MSG_ASSISTANT,
        })
      );

      await act(async () => {
        await result.current.send('Hello concierge');
      });

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/conv-abc123/messages',
        { message: { content: 'Hello concierge' } }
      );
    });

    it('appends an optimistic user message immediately, then replaces with server response', async () => {
      const { result } = await bootstrappedHook();

      let resolveSend!: (v: unknown) => void;
      const sendPromise = new Promise((resolve) => { resolveSend = resolve; });
      mockPost.mockReturnValueOnce(sendPromise);

      // Kick off send without awaiting
      act(() => {
        void result.current.send('Hello concierge');
      });

      // Optimistic message should be in the list immediately
      await waitFor(() => {
        const msgs = result.current.messages;
        expect(msgs.some((m) => m.role === 'user' && m.content === 'Hello concierge')).toBe(true);
      });

      // Resolve the API call
      await act(async () => {
        resolveSend(
          envelope({
            user_message: MSG_USER,
            assistant_message: MSG_ASSISTANT,
          })
        );
        await Promise.resolve();
      });

      await waitFor(() => {
        const msgs = result.current.messages;
        // Server-confirmed user message replaces optimistic; assistant message appended
        expect(msgs.find((m) => m.id === 'msg-1')).toBeDefined();
        expect(msgs.find((m) => m.id === 'msg-2')).toBeDefined();
        // No orphaned optimistic messages with u- prefix remaining
        expect(msgs.filter((m) => m.id.startsWith('u-'))).toHaveLength(0);
      });
    });

    it('appends only the user message when assistant_message is absent', async () => {
      const { result } = await bootstrappedHook();

      mockPost.mockResolvedValueOnce(
        envelope({ user_message: MSG_USER })
      );

      await act(async () => {
        await result.current.send('Hello');
      });

      const msgs = result.current.messages;
      expect(msgs).toHaveLength(1);
      expect(msgs[0].id).toBe('msg-1');
    });

    it('trims whitespace from the message content', async () => {
      const { result } = await bootstrappedHook();

      mockPost.mockResolvedValueOnce(
        envelope({ user_message: MSG_USER })
      );

      await act(async () => {
        await result.current.send('  trimmed  ');
      });

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/conv-abc123/messages',
        { message: { content: 'trimmed' } }
      );
    });

    it('does nothing when the content is blank after trimming', async () => {
      const { result } = await bootstrappedHook();

      const callsBefore = mockPost.mock.calls.length;

      await act(async () => {
        await result.current.send('   ');
      });

      expect(mockPost.mock.calls.length).toBe(callsBefore);
    });

    it('sets error and does not call API when conversationId is null', async () => {
      const { result } = renderHook(() => useConcierge(false));

      await act(async () => {
        await result.current.send('Hi');
      });

      expect(result.current.error).toBe('Concierge not ready');
      expect(mockPost).not.toHaveBeenCalled();
    });

    it('sets error when the send POST fails', async () => {
      const { result } = await bootstrappedHook();

      mockPost.mockRejectedValueOnce(new Error('Send failed'));

      await act(async () => {
        await result.current.send('Hello');
      });

      expect(result.current.error).toBe('Send failed');
      expect(result.current.pending).toBe(false);
    });

    it('uses fallback error message for non-Error rejections during send', async () => {
      const { result } = await bootstrappedHook();

      mockPost.mockRejectedValueOnce('oops');

      await act(async () => {
        await result.current.send('Hello');
      });

      expect(result.current.error).toBe('Send failed');
    });

    it('sets pending=true while sending and resets to false after', async () => {
      const { result } = await bootstrappedHook();

      let resolveSend!: (v: unknown) => void;
      const sendPromise = new Promise((resolve) => { resolveSend = resolve; });
      mockPost.mockReturnValueOnce(sendPromise);

      act(() => { void result.current.send('Hi'); });

      await waitFor(() => expect(result.current.pending).toBe(true));

      await act(async () => {
        resolveSend(envelope({ user_message: MSG_USER }));
        await Promise.resolve();
      });

      await waitFor(() => expect(result.current.pending).toBe(false));
    });
  });

  // ---------------------------------------------------------------------------
  // confirmAction()
  // ---------------------------------------------------------------------------

  describe('confirmAction()', () => {
    async function bootstrappedHook() {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));
      mockGet.mockResolvedValueOnce(envelope({ messages: [MSG_USER] }));

      const hook = renderHook(() => useConcierge(true));
      await waitFor(() => expect(hook.result.current.conversationId).toBe('conv-abc123'));
      return hook;
    }

    it('POSTs to confirm_action with the correct URL and payload', async () => {
      const { result } = await bootstrappedHook();

      const refreshedMessages = [MSG_USER, MSG_ASSISTANT];
      // confirmAction calls post then GET
      mockPost.mockResolvedValueOnce({ data: { success: true } });
      mockGet.mockResolvedValueOnce(envelope({ messages: refreshedMessages }));

      await act(async () => {
        await result.current.confirmAction('approve_plan', { plan_id: 'plan-42' });
      });

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/conv-abc123/confirm_action',
        { action_type: 'approve_plan', action_params: { plan_id: 'plan-42' } }
      );
    });

    it('refreshes messages by calling listMessages after confirming', async () => {
      const { result } = await bootstrappedHook();

      const refreshedMessages = [MSG_USER, MSG_ASSISTANT];
      mockPost.mockResolvedValueOnce({ data: { success: true } });
      mockGet.mockResolvedValueOnce(envelope({ messages: refreshedMessages }));

      await act(async () => {
        await result.current.confirmAction('approve_plan', {});
      });

      expect(mockGet).toHaveBeenCalledWith('/ai/conversations/conv-abc123/messages');
      expect(result.current.messages).toEqual(refreshedMessages);
    });

    it('sets error when conversationId is null', async () => {
      const { result } = renderHook(() => useConcierge(false));

      await act(async () => {
        await result.current.confirmAction('approve_plan', {});
      });

      expect(result.current.error).toBe('Concierge not ready');
      expect(mockPost).not.toHaveBeenCalled();
    });

    it('sets error when confirm POST fails', async () => {
      const { result } = await bootstrappedHook();

      mockPost.mockRejectedValueOnce(new Error('Approval failed'));

      await act(async () => {
        await result.current.confirmAction('approve_plan', {});
      });

      expect(result.current.error).toBe('Approval failed');
      expect(result.current.pending).toBe(false);
    });

    it('uses fallback error message for non-Error rejections', async () => {
      const { result } = await bootstrappedHook();

      mockPost.mockRejectedValueOnce(42);

      await act(async () => {
        await result.current.confirmAction('approve_plan', {});
      });

      expect(result.current.error).toBe('Action failed');
    });

    it('sets pending=true while confirming and resets to false after', async () => {
      const { result } = await bootstrappedHook();

      let resolveSend!: (v: unknown) => void;
      const confirmPromise = new Promise((resolve) => { resolveSend = resolve; });
      mockPost.mockReturnValueOnce(confirmPromise);
      mockGet.mockResolvedValueOnce(envelope({ messages: [] }));

      act(() => { void result.current.confirmAction('approve_plan', {}); });

      await waitFor(() => expect(result.current.pending).toBe(true));

      await act(async () => {
        resolveSend({ data: { success: true } });
        await Promise.resolve();
      });

      await waitFor(() => expect(result.current.pending).toBe(false));
    });
  });

  // ---------------------------------------------------------------------------
  // reset()
  // ---------------------------------------------------------------------------

  describe('reset()', () => {
    it('clears all state back to initial values', async () => {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));
      mockGet.mockResolvedValueOnce(envelope({ messages: [MSG_USER] }));

      const { result } = renderHook(() => useConcierge(true));

      await waitFor(() => expect(result.current.conversationId).toBe('conv-abc123'));

      act(() => {
        result.current.reset();
      });

      expect(result.current.conversationId).toBeNull();
      expect(result.current.agentName).toBeNull();
      expect(result.current.snapshot).toBeNull();
      expect(result.current.messages).toEqual([]);
      expect(result.current.error).toBeNull();
    });

    it('also clears error state', async () => {
      mockPost.mockRejectedValueOnce(new Error('Boot error'));

      const { result } = renderHook(() => useConcierge(true));

      await waitFor(() => expect(result.current.error).toBe('Boot error'));

      act(() => {
        result.current.reset();
      });

      expect(result.current.error).toBeNull();
    });
  });

  // ---------------------------------------------------------------------------
  // Deactivation / cleanup (active flips false → true)
  // ---------------------------------------------------------------------------

  describe('active flag transitions', () => {
    it('bootstraps when active flips from false to true', async () => {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));
      mockGet.mockResolvedValueOnce(envelope({ messages: [] }));

      const { result, rerender } = renderHook(({ active }) => useConcierge(active), {
        initialProps: { active: false },
      });

      // Still inactive — no calls
      expect(mockPost).not.toHaveBeenCalled();

      rerender({ active: true });

      await waitFor(() => expect(result.current.conversationId).toBe('conv-abc123'));
      expect(mockPost).toHaveBeenCalledWith('/system/concierge/start', {});
    });
  });

  // ---------------------------------------------------------------------------
  // listMessages with empty response
  // ---------------------------------------------------------------------------

  describe('edge cases', () => {
    it('handles a listMessages response with no messages array', async () => {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));
      // conciergeApi.listMessages handles missing messages with `|| []`
      mockGet.mockResolvedValueOnce(envelope({}));

      const { result } = renderHook(() => useConcierge(true));

      await waitFor(() => expect(result.current.conversationId).toBe('conv-abc123'));

      expect(result.current.messages).toEqual([]);
    });
  });
});
