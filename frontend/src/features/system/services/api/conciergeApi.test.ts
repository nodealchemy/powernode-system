import { conciergeApi } from './conciergeApi';

// =============================================================================
// Mocks
//
// conciergeApi imports only apiClient and the local helpers/types — mock
// exactly those surfaces so tests are isolated from the real HTTP layer.
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Helpers
//
// The backend wraps payloads as { success: true, data: <payload> }.
// AxiosResponse exposes the body via `.data`, so a mocked resolve must be:
//   { data: { success: true, data: <payload> } }
// =============================================================================

function envelope<T>(payload: T) {
  return { data: { success: true as const, data: payload } };
}

// =============================================================================
// Fixtures
// =============================================================================

const START_RESPONSE = {
  conversation_id: 'conv-123',
  agent_id: 'agent-abc',
  agent_name: 'System Concierge',
  snapshot: 'snapshot-xyz',
};

const USER_MSG = {
  id: 'msg-1',
  role: 'user' as const,
  content: 'Hello',
  created_at: '2026-01-01T00:00:00Z',
};

const ASSISTANT_MSG = {
  id: 'msg-2',
  role: 'assistant' as const,
  content: 'Hi there!',
  created_at: '2026-01-01T00:00:01Z',
};

const SYSTEM_MSG = {
  id: 'msg-3',
  role: 'system' as const,
  content: 'System context',
  created_at: '2026-01-01T00:00:00Z',
  content_metadata: { key: 'value' },
};

const TOOL_MSG = {
  id: 'msg-4',
  role: 'tool' as const,
  content: 'Tool result',
  created_at: '2026-01-01T00:00:03Z',
};

// =============================================================================
// Tests
// =============================================================================

describe('conciergeApi', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
  });

  // ---------------------------------------------------------------------------
  // start()
  // ---------------------------------------------------------------------------

  describe('start()', () => {
    it('posts to /system/concierge/start with an empty body', async () => {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));

      await conciergeApi.start();

      expect(mockPost).toHaveBeenCalledTimes(1);
      expect(mockPost).toHaveBeenCalledWith('/system/concierge/start', {});
    });

    it('returns the unwrapped ConciergeStartResponse', async () => {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));

      const result = await conciergeApi.start();

      expect(result).toEqual(START_RESPONSE);
      expect(result.conversation_id).toBe('conv-123');
      expect(result.agent_id).toBe('agent-abc');
      expect(result.agent_name).toBe('System Concierge');
      expect(result.snapshot).toBe('snapshot-xyz');
    });

    it('propagates network errors thrown by apiClient', async () => {
      mockPost.mockRejectedValueOnce(new Error('Network error'));

      await expect(conciergeApi.start()).rejects.toThrow('Network error');
    });

    it('does NOT call get, put, or delete', async () => {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));

      await conciergeApi.start();

      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // listMessages()
  // ---------------------------------------------------------------------------

  describe('listMessages()', () => {
    it('GETs /ai/conversations/:id/messages with the correct conversationId', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ messages: [USER_MSG, ASSISTANT_MSG] })
      );

      await conciergeApi.listMessages('conv-123');

      expect(mockGet).toHaveBeenCalledTimes(1);
      expect(mockGet).toHaveBeenCalledWith('/ai/conversations/conv-123/messages');
    });

    it('uses the conversationId parameter in the URL', async () => {
      mockGet.mockResolvedValueOnce(envelope({ messages: [] }));

      await conciergeApi.listMessages('different-conv-id');

      expect(mockGet).toHaveBeenCalledWith(
        '/ai/conversations/different-conv-id/messages'
      );
    });

    it('returns the unwrapped messages array', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ messages: [USER_MSG, ASSISTANT_MSG] })
      );

      const result = await conciergeApi.listMessages('conv-123');

      expect(result).toEqual([USER_MSG, ASSISTANT_MSG]);
      expect(result).toHaveLength(2);
    });

    it('returns an empty array when messages is absent from response', async () => {
      mockGet.mockResolvedValueOnce(envelope({}));

      const result = await conciergeApi.listMessages('conv-123');

      expect(result).toEqual([]);
    });

    it('returns an empty array when messages is explicitly empty', async () => {
      mockGet.mockResolvedValueOnce(envelope({ messages: [] }));

      const result = await conciergeApi.listMessages('conv-123');

      expect(result).toEqual([]);
    });

    it('handles all message role types correctly', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ messages: [USER_MSG, ASSISTANT_MSG, SYSTEM_MSG, TOOL_MSG] })
      );

      const result = await conciergeApi.listMessages('conv-123');

      expect(result).toHaveLength(4);
      expect(result[0].role).toBe('user');
      expect(result[1].role).toBe('assistant');
      expect(result[2].role).toBe('system');
      expect(result[3].role).toBe('tool');
    });

    it('returns messages with content_metadata when present', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ messages: [SYSTEM_MSG] })
      );

      const result = await conciergeApi.listMessages('conv-123');

      expect(result[0].content_metadata).toEqual({ key: 'value' });
    });

    it('propagates errors thrown by apiClient', async () => {
      mockGet.mockRejectedValueOnce(new Error('Unauthorized'));

      await expect(conciergeApi.listMessages('conv-123')).rejects.toThrow(
        'Unauthorized'
      );
    });
  });

  // ---------------------------------------------------------------------------
  // sendMessage()
  // ---------------------------------------------------------------------------

  describe('sendMessage()', () => {
    it('POSTs to /ai/conversations/:id/messages with the correct URL', async () => {
      mockPost.mockResolvedValueOnce(
        envelope({
          user_message: USER_MSG,
          assistant_message: ASSISTANT_MSG,
        })
      );

      await conciergeApi.sendMessage('conv-123', 'Hello');

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/conv-123/messages',
        expect.anything()
      );
    });

    it('wraps the content in the expected payload shape { message: { content } }', async () => {
      mockPost.mockResolvedValueOnce(
        envelope({ user_message: USER_MSG })
      );

      await conciergeApi.sendMessage('conv-123', 'Hello, concierge!');

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/conv-123/messages',
        { message: { content: 'Hello, concierge!' } }
      );
    });

    it('uses the conversationId parameter in the URL', async () => {
      mockPost.mockResolvedValueOnce(
        envelope({ user_message: USER_MSG })
      );

      await conciergeApi.sendMessage('other-conv', 'Test');

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/other-conv/messages',
        expect.anything()
      );
    });

    it('returns the unwrapped ConciergeSendResponse with both messages', async () => {
      const sendResponse = {
        user_message: USER_MSG,
        assistant_message: ASSISTANT_MSG,
      };
      mockPost.mockResolvedValueOnce(envelope(sendResponse));

      const result = await conciergeApi.sendMessage('conv-123', 'Hello');

      expect(result).toEqual(sendResponse);
      expect(result.user_message).toEqual(USER_MSG);
      expect(result.assistant_message).toEqual(ASSISTANT_MSG);
    });

    it('returns the response when assistant_message is absent', async () => {
      const sendResponse = { user_message: USER_MSG };
      mockPost.mockResolvedValueOnce(envelope(sendResponse));

      const result = await conciergeApi.sendMessage('conv-123', 'Hello');

      expect(result.user_message).toEqual(USER_MSG);
      expect(result.assistant_message).toBeUndefined();
    });

    it('sends empty string content when content is blank', async () => {
      mockPost.mockResolvedValueOnce(envelope({ user_message: USER_MSG }));

      await conciergeApi.sendMessage('conv-123', '');

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/conv-123/messages',
        { message: { content: '' } }
      );
    });

    it('propagates errors thrown by apiClient', async () => {
      mockPost.mockRejectedValueOnce(new Error('Forbidden'));

      await expect(
        conciergeApi.sendMessage('conv-123', 'Hello')
      ).rejects.toThrow('Forbidden');
    });
  });

  // ---------------------------------------------------------------------------
  // confirmAction()
  // ---------------------------------------------------------------------------

  describe('confirmAction()', () => {
    it('POSTs to /ai/conversations/:id/confirm_action', async () => {
      mockPost.mockResolvedValueOnce({ data: { success: true } });

      await conciergeApi.confirmAction('conv-123', 'approve_plan', {});

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/conv-123/confirm_action',
        expect.anything()
      );
    });

    it('sends action_type and action_params in the request body', async () => {
      mockPost.mockResolvedValueOnce({ data: { success: true } });

      await conciergeApi.confirmAction('conv-123', 'approve_plan', {
        plan_id: 'plan-xyz',
        approved: true,
      });

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/conv-123/confirm_action',
        {
          action_type: 'approve_plan',
          action_params: { plan_id: 'plan-xyz', approved: true },
        }
      );
    });

    it('defaults action_params to an empty object when omitted', async () => {
      mockPost.mockResolvedValueOnce({ data: { success: true } });

      await conciergeApi.confirmAction('conv-123', 'approve_plan');

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/conv-123/confirm_action',
        {
          action_type: 'approve_plan',
          action_params: {},
        }
      );
    });

    it('uses the conversationId parameter in the URL', async () => {
      mockPost.mockResolvedValueOnce({ data: { success: true } });

      await conciergeApi.confirmAction('another-conv', 'reject_plan');

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/another-conv/confirm_action',
        expect.anything()
      );
    });

    it('resolves to void (returns undefined)', async () => {
      mockPost.mockResolvedValueOnce({ data: { success: true } });

      const result = await conciergeApi.confirmAction(
        'conv-123',
        'approve_plan'
      );

      expect(result).toBeUndefined();
    });

    it('sends action_params with deeply-nested values', async () => {
      mockPost.mockResolvedValueOnce({ data: { success: true } });

      const complexParams = {
        resources: ['node-1', 'node-2'],
        config: { replicas: 3, region: 'us-east' },
      };

      await conciergeApi.confirmAction('conv-123', 'provision', complexParams);

      expect(mockPost).toHaveBeenCalledWith(
        '/ai/conversations/conv-123/confirm_action',
        {
          action_type: 'provision',
          action_params: complexParams,
        }
      );
    });

    it('propagates errors thrown by apiClient', async () => {
      mockPost.mockRejectedValueOnce(new Error('Gateway timeout'));

      await expect(
        conciergeApi.confirmAction('conv-123', 'approve_plan')
      ).rejects.toThrow('Gateway timeout');
    });

    it('does not call get, put, or delete', async () => {
      mockPost.mockResolvedValueOnce({ data: { success: true } });

      await conciergeApi.confirmAction('conv-123', 'approve_plan');

      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Cross-function isolation — each method only calls the expected HTTP verb
  // ---------------------------------------------------------------------------

  describe('HTTP verb isolation', () => {
    it('start() does not call get, put, or delete', async () => {
      mockPost.mockResolvedValueOnce(envelope(START_RESPONSE));

      await conciergeApi.start();

      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });

    it('listMessages() does not call post, put, or delete', async () => {
      mockGet.mockResolvedValueOnce(envelope({ messages: [] }));

      await conciergeApi.listMessages('conv-123');

      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });

    it('sendMessage() does not call get, put, or delete', async () => {
      mockPost.mockResolvedValueOnce(envelope({ user_message: USER_MSG }));

      await conciergeApi.sendMessage('conv-123', 'hello');

      expect(mockGet).not.toHaveBeenCalled();
      expect(mockPut).not.toHaveBeenCalled();
      expect(mockDelete).not.toHaveBeenCalled();
    });
  });
});
