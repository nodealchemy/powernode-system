import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ConciergePanel } from './ConciergePanel';

// =============================================================================
// Mocks
//
// ConciergePanel delegates all API access through useConcierge → conciergeApi.
// We mock the whole conciergeApi module so tests control what start() and
// sendMessage() resolve/reject to, then assert against the rendered UI.
// ConciergeMessage is a presentational child; ConciergeActionCard (shared)
// is also mocked to keep the test surface focused on ConciergePanel's own
// logic.
// =============================================================================

const mockPost = jest.fn();
const mockGet  = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get:    (...a: unknown[]) => mockGet(...a),
    post:   (...a: unknown[]) => mockPost(...a),
    put:    jest.fn(),
    delete: jest.fn(),
  },
}));

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: () => true }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
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

// Mock the shared ConciergeActionCard to keep approval-card behaviour out of
// ConciergePanel's own test surface (it is covered by ConciergeMessage tests).
jest.mock('@/shared/components/concierge/ConciergeActionCard', () => ({
  ConciergeActionCard: ({
    onConfirm,
    actionContext,
  }: {
    onConfirm: (t: string, p: Record<string, unknown>) => void;
    actionContext: { action_type: string };
  }) => (
    <div data-testid="mock-action-card">
      <button
        data-testid="approve-btn"
        onClick={() => onConfirm(actionContext.action_type, { decision: 'approved' })}
      >
        Approve
      </button>
    </div>
  ),
}));

// Silence logger in tests.
jest.mock('@/shared/utils/logger', () => ({
  logger: { error: jest.fn(), warn: jest.fn(), info: jest.fn() },
}));

// =============================================================================
// Fixtures
// =============================================================================

/** API double-envelope helper (mirrors InstancePoolsPage.test convention). */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const START_RESPONSE = {
  conversation_id: 'conv-1',
  agent_id:        'agent-1',
  agent_name:      'Infrastructure Generalist',
  snapshot:        'nodes: 3, healthy: 3',
};

const MSG_USER: import('./../../services/api/conciergeApi').ConciergeMessage = {
  id:         'msg-u-1',
  role:       'user',
  content:    'Hello concierge',
  created_at: '2026-01-01T12:00:00Z',
};

const MSG_ASSISTANT: import('./../../services/api/conciergeApi').ConciergeMessage = {
  id:         'msg-a-1',
  role:       'assistant',
  content:    'Hello! How can I help you today?',
  created_at: '2026-01-01T12:00:01Z',
};

const MSG_WITH_CVE: import('./../../services/api/conciergeApi').ConciergeMessage = {
  id:         'msg-cve-1',
  role:       'assistant',
  content:    'You should remediate CVE-2024-12345 immediately.',
  created_at: '2026-01-01T12:01:00Z',
};

const MSG_APPROVAL: import('./../../services/api/conciergeApi').ConciergeMessage = {
  id:         'msg-approval-1',
  role:       'assistant',
  content:    'Please approve the infrastructure plan.',
  created_at: '2026-01-01T12:02:00Z',
  content_metadata: {
    concierge_action: true,
    action_type:      'create_mission',
    action_context:   { type: 'concierge', action_type: 'create_mission', status: 'pending' },
    action_params:    { plan_id: 'plan-42' },
    actions: [
      { type: 'confirm', label: 'Approve', style: 'primary' },
      { type: 'reject',  label: 'Reject',  style: 'danger'  },
    ],
  },
};

// =============================================================================
// Render helpers
// =============================================================================

interface RenderOptions {
  open?: boolean;
  onClose?: () => void;
}

function renderPanel({ open = true, onClose = jest.fn() }: RenderOptions = {}) {
  return render(
    <BrowserRouter>
      <ConciergePanel open={open} onClose={onClose} />
    </BrowserRouter>,
  );
}

/**
 * Set up the default happy-path mocks: start resolves, no prior messages.
 */
function setupHappyPath(existingMessages: unknown[] = []) {
  mockPost.mockImplementation((url: string) => {
    if (url === '/system/concierge/start') {
      return Promise.resolve(envelope(START_RESPONSE));
    }
    return Promise.reject(new Error(`Unexpected POST ${url}`));
  });
  mockGet.mockImplementation((url: string) => {
    if (url === `/ai/conversations/${START_RESPONSE.conversation_id}/messages`) {
      return Promise.resolve(envelope({ messages: existingMessages }));
    }
    return Promise.reject(new Error(`Unexpected GET ${url}`));
  });
}

// =============================================================================
// Tests
// =============================================================================

describe('ConciergePanel', () => {
  beforeEach(() => {
    mockPost.mockReset();
    mockGet.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Visibility / mount behaviour
  // ---------------------------------------------------------------------------

  it('renders nothing when open=false', () => {
    const { container } = renderPanel({ open: false });
    expect(container.firstChild).toBeNull();
  });

  it('renders the panel when open=true', () => {
    setupHappyPath();
    renderPanel();
    expect(screen.getByText('Infrastructure Generalist')).toBeInTheDocument();
  });

  it('calls onClose when the × button is clicked', async () => {
    setupHappyPath();
    const onClose = jest.fn();
    renderPanel({ onClose });

    fireEvent.click(screen.getByLabelText('Close concierge'));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  // ---------------------------------------------------------------------------
  // Bootstrap — start + listMessages
  // ---------------------------------------------------------------------------

  it('calls POST /system/concierge/start on mount when open=true', async () => {
    setupHappyPath();
    renderPanel();

    await waitFor(() => {
      expect(mockPost).toHaveBeenCalledWith('/system/concierge/start', {});
    });
  });

  it('calls GET /ai/conversations/:id/messages after start', async () => {
    setupHappyPath();
    renderPanel();

    await waitFor(() => {
      expect(mockGet).toHaveBeenCalledWith(
        `/ai/conversations/${START_RESPONSE.conversation_id}/messages`,
      );
    });
  });

  it('does not call start when open=false', () => {
    renderPanel({ open: false });
    expect(mockPost).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Agent name + subtitle
  // ---------------------------------------------------------------------------

  it('shows the agent name in the subtitle after bootstrap', async () => {
    setupHappyPath();
    renderPanel();

    await waitFor(() => {
      expect(screen.getByText(`Connected to ${START_RESPONSE.agent_name}`)).toBeInTheDocument();
    });
  });

  it('shows "Ask, plan, dispatch" subtitle before bootstrap completes', () => {
    // Never resolve — stay in pending
    mockPost.mockReturnValue(new Promise(() => {}));
    renderPanel();
    expect(screen.getByText('Ask, plan, dispatch')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Fleet snapshot
  // ---------------------------------------------------------------------------

  it('renders the fleet snapshot details element after bootstrap', async () => {
    setupHappyPath();
    renderPanel();

    await waitFor(() => {
      expect(screen.getByText('Current fleet snapshot')).toBeInTheDocument();
    });
    expect(screen.getByText(START_RESPONSE.snapshot)).toBeInTheDocument();
  });

  it('does not render snapshot section when snapshot is null', async () => {
    const noSnapshot = { ...START_RESPONSE, snapshot: null as unknown as string };
    mockPost.mockResolvedValueOnce(envelope(noSnapshot));
    mockGet.mockResolvedValueOnce(envelope({ messages: [] }));
    renderPanel();

    // Give enough time for bootstrap to complete
    await waitFor(() => expect(mockPost).toHaveBeenCalled());
    // summary element must not appear
    expect(screen.queryByText('Current fleet snapshot')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Welcome message
  // ---------------------------------------------------------------------------

  it('shows the welcome message when there are no prior messages', async () => {
    setupHappyPath([]);
    renderPanel();

    // Wait for bootstrap to complete (panel receives conversationId)
    await waitFor(() => {
      expect(mockPost).toHaveBeenCalledWith('/system/concierge/start', {});
    });

    await waitFor(() => {
      expect(
        screen.getByText(/Hi! I'm the Infrastructure Generalist/),
      ).toBeInTheDocument();
    });
  });

  it('does not show the welcome message when prior messages exist', async () => {
    setupHappyPath([MSG_USER, MSG_ASSISTANT]);
    renderPanel();

    await waitFor(() => {
      expect(screen.getByText(MSG_USER.content)).toBeInTheDocument();
    });
    expect(screen.queryByText(/Hi! I'm the Infrastructure Generalist/)).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Error state
  // ---------------------------------------------------------------------------

  it('shows an error banner when start fails', async () => {
    mockPost.mockRejectedValueOnce(new Error('Network error'));
    renderPanel();

    await waitFor(() => {
      expect(screen.getByText('Network error')).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Pending state
  // ---------------------------------------------------------------------------

  it('shows "Concierge is thinking..." while pending', () => {
    // Keep start pending forever
    mockPost.mockReturnValue(new Promise(() => {}));
    renderPanel();
    expect(screen.getByText('Concierge is thinking...')).toBeInTheDocument();
  });

  it('hides the thinking indicator once start resolves', async () => {
    setupHappyPath();
    renderPanel();

    await waitFor(() => {
      expect(screen.queryByText('Concierge is thinking...')).not.toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Textarea / Send button disabled states
  // ---------------------------------------------------------------------------

  it('disables textarea and Send button while pending (no conversationId yet)', () => {
    mockPost.mockReturnValue(new Promise(() => {}));
    renderPanel();

    const textarea = screen.getByPlaceholderText('Ask the concierge...');
    const sendBtn  = screen.getByRole('button', { name: /send/i });

    expect(textarea).toBeDisabled();
    expect(sendBtn).toBeDisabled();
  });

  it('enables textarea once conversationId is set', async () => {
    setupHappyPath();
    renderPanel();

    await waitFor(() => {
      expect(screen.getByPlaceholderText('Ask the concierge...')).not.toBeDisabled();
    });
  });

  it('keeps Send button disabled while draft is empty', async () => {
    setupHappyPath();
    renderPanel();

    await waitFor(() => {
      expect(screen.getByPlaceholderText('Ask the concierge...')).not.toBeDisabled();
    });

    const sendBtn = screen.getByRole('button', { name: /send/i });
    expect(sendBtn).toBeDisabled();
  });

  it('enables Send button once draft has non-whitespace content', async () => {
    setupHappyPath();
    renderPanel();

    const textarea = await screen.findByPlaceholderText('Ask the concierge...');
    fireEvent.change(textarea, { target: { value: 'Hello' } });

    const sendBtn = screen.getByRole('button', { name: /send/i });
    expect(sendBtn).not.toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Sending a message via button click
  // ---------------------------------------------------------------------------

  it('POSTs to messages with correct payload when Send is clicked', async () => {
    setupHappyPath();
    // Resolve sendMessage
    mockPost.mockImplementation((url: string, body: unknown) => {
      if (url === '/system/concierge/start') {
        return Promise.resolve(envelope(START_RESPONSE));
      }
      if (url === `/ai/conversations/${START_RESPONSE.conversation_id}/messages`) {
        return Promise.resolve(
          envelope({ user_message: MSG_USER, assistant_message: MSG_ASSISTANT }),
        );
      }
      return Promise.reject(new Error(`Unexpected POST ${url} ${JSON.stringify(body)}`));
    });

    renderPanel();

    const textarea = await screen.findByPlaceholderText('Ask the concierge...');
    fireEvent.change(textarea, { target: { value: 'Hello concierge' } });
    fireEvent.click(screen.getByRole('button', { name: /send/i }));

    await waitFor(() => {
      expect(mockPost).toHaveBeenCalledWith(
        `/ai/conversations/${START_RESPONSE.conversation_id}/messages`,
        { message: { content: 'Hello concierge' } },
      );
    });
  });

  it('clears the draft after sending', async () => {
    setupHappyPath();
    mockPost.mockImplementation((url: string) => {
      if (url === '/system/concierge/start') return Promise.resolve(envelope(START_RESPONSE));
      if (url === `/ai/conversations/${START_RESPONSE.conversation_id}/messages`)
        return Promise.resolve(envelope({ user_message: MSG_USER, assistant_message: MSG_ASSISTANT }));
      return Promise.reject(new Error(`Unexpected POST ${url}`));
    });

    renderPanel();

    const textarea = await screen.findByPlaceholderText('Ask the concierge...');
    fireEvent.change(textarea, { target: { value: 'My message' } });
    fireEvent.click(screen.getByRole('button', { name: /send/i }));

    await waitFor(() => {
      expect((textarea as HTMLTextAreaElement).value).toBe('');
    });
  });

  it('appends the assistant reply after send resolves', async () => {
    setupHappyPath();
    mockPost.mockImplementation((url: string) => {
      if (url === '/system/concierge/start') return Promise.resolve(envelope(START_RESPONSE));
      if (url === `/ai/conversations/${START_RESPONSE.conversation_id}/messages`)
        return Promise.resolve(envelope({ user_message: MSG_USER, assistant_message: MSG_ASSISTANT }));
      return Promise.reject(new Error(`Unexpected POST ${url}`));
    });

    renderPanel();

    const textarea = await screen.findByPlaceholderText('Ask the concierge...');
    fireEvent.change(textarea, { target: { value: 'Hello concierge' } });
    fireEvent.click(screen.getByRole('button', { name: /send/i }));

    await waitFor(() => {
      expect(screen.getByText(MSG_ASSISTANT.content)).toBeInTheDocument();
    });
  });

  it('does not send when draft is only whitespace', async () => {
    setupHappyPath();
    renderPanel();

    const textarea = await screen.findByPlaceholderText('Ask the concierge...');
    fireEvent.change(textarea, { target: { value: '   ' } });

    const sendBtn = screen.getByRole('button', { name: /send/i });
    // Button stays disabled for whitespace-only
    expect(sendBtn).toBeDisabled();
  });

  // ---------------------------------------------------------------------------
  // Sending via Enter key
  // ---------------------------------------------------------------------------

  it('sends on Enter (no shift)', async () => {
    setupHappyPath();
    mockPost.mockImplementation((url: string) => {
      if (url === '/system/concierge/start') return Promise.resolve(envelope(START_RESPONSE));
      if (url === `/ai/conversations/${START_RESPONSE.conversation_id}/messages`)
        return Promise.resolve(envelope({ user_message: MSG_USER, assistant_message: MSG_ASSISTANT }));
      return Promise.reject(new Error(`Unexpected POST ${url}`));
    });

    renderPanel();

    const textarea = await screen.findByPlaceholderText('Ask the concierge...');
    fireEvent.change(textarea, { target: { value: 'Enter test' } });
    fireEvent.keyDown(textarea, { key: 'Enter', shiftKey: false });

    await waitFor(() => {
      expect(mockPost).toHaveBeenCalledWith(
        `/ai/conversations/${START_RESPONSE.conversation_id}/messages`,
        { message: { content: 'Enter test' } },
      );
    });
  });

  it('does NOT send on Shift+Enter', async () => {
    setupHappyPath();
    renderPanel();

    const textarea = await screen.findByPlaceholderText('Ask the concierge...');
    fireEvent.change(textarea, { target: { value: 'Shift enter test' } });
    fireEvent.keyDown(textarea, { key: 'Enter', shiftKey: true });

    // Only the initial start POST — no messages call
    await waitFor(() => expect(mockPost).toHaveBeenCalledTimes(1));
    expect(mockPost).not.toHaveBeenCalledWith(
      `/ai/conversations/${START_RESPONSE.conversation_id}/messages`,
      expect.anything(),
    );
  });

  // ---------------------------------------------------------------------------
  // CVE runbook chips
  // ---------------------------------------------------------------------------

  it('renders runbook chip for CVE IDs found in assistant messages', async () => {
    setupHappyPath([MSG_WITH_CVE]);
    renderPanel();

    await waitFor(() => {
      expect(screen.getByTestId('cve-runbook-actions')).toBeInTheDocument();
    });
    expect(screen.getByText('Runbook: CVE-2024-12345')).toBeInTheDocument();
  });

  it('clicking a CVE runbook chip sends the correct natural-language message', async () => {
    setupHappyPath([MSG_WITH_CVE]);
    mockPost.mockImplementation((url: string) => {
      if (url === '/system/concierge/start') return Promise.resolve(envelope(START_RESPONSE));
      if (url === `/ai/conversations/${START_RESPONSE.conversation_id}/messages`)
        return Promise.resolve(envelope({ user_message: MSG_USER }));
      return Promise.reject(new Error(`Unexpected POST ${url}`));
    });

    renderPanel();

    const chip = await screen.findByText('Runbook: CVE-2024-12345');
    fireEvent.click(chip);

    await waitFor(() => {
      expect(mockPost).toHaveBeenCalledWith(
        `/ai/conversations/${START_RESPONSE.conversation_id}/messages`,
        {
          message: {
            content:
              'Generate a remediation runbook for CVE-2024-12345 and persist it as a Page so I can share it with the team.',
          },
        },
      );
    });
  });

  it('does not render runbook chips on user messages', async () => {
    const userCveMsg = { ...MSG_USER, content: 'Tell me about CVE-2024-99999' };
    setupHappyPath([userCveMsg]);
    renderPanel();

    await waitFor(() => {
      expect(screen.getByText(userCveMsg.content)).toBeInTheDocument();
    });
    expect(screen.queryByTestId('cve-runbook-actions')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Inline approval card (confirmAction)
  // ---------------------------------------------------------------------------

  it('renders the mocked action card for messages with concierge_action metadata', async () => {
    setupHappyPath([MSG_APPROVAL]);
    renderPanel();

    await waitFor(() => {
      expect(screen.getByTestId('mock-action-card')).toBeInTheDocument();
    });
  });

  it('calls confirmAction then re-fetches messages when Approve is clicked', async () => {
    setupHappyPath([MSG_APPROVAL]);

    const resolvedMsg = {
      ...MSG_APPROVAL,
      content_metadata: {
        ...MSG_APPROVAL.content_metadata,
        action_context: {
          type:        'concierge',
          action_type: 'create_mission',
          status:      'confirmed',
          resolved_at: '2026-01-01T12:05:00Z',
        },
      },
    };

    mockPost.mockImplementation((url: string) => {
      if (url === '/system/concierge/start')
        return Promise.resolve(envelope(START_RESPONSE));
      if (url.endsWith('/confirm_action'))
        return Promise.resolve({ data: { success: true } });
      return Promise.reject(new Error(`Unexpected POST ${url}`));
    });

    // After confirmAction the hook re-fetches messages
    let getCallCount = 0;
    mockGet.mockImplementation((url: string) => {
      getCallCount += 1;
      if (url === `/ai/conversations/${START_RESPONSE.conversation_id}/messages`) {
        if (getCallCount === 1) return Promise.resolve(envelope({ messages: [MSG_APPROVAL] }));
        // second call — refreshed list with resolved card
        return Promise.resolve(envelope({ messages: [resolvedMsg] }));
      }
      return Promise.reject(new Error(`Unexpected GET ${url}`));
    });

    renderPanel();

    await waitFor(() => expect(screen.getByTestId('approve-btn')).toBeInTheDocument());
    fireEvent.click(screen.getByTestId('approve-btn'));

    await waitFor(() => {
      expect(mockPost).toHaveBeenCalledWith(
        `/ai/conversations/${START_RESPONSE.conversation_id}/confirm_action`,
        { action_type: 'create_mission', action_params: { decision: 'approved' } },
      );
    });

    // After confirm the hook re-lists messages
    await waitFor(() => {
      expect(mockGet).toHaveBeenCalledTimes(2);
    });
  });

  // ---------------------------------------------------------------------------
  // Prior messages from server
  // ---------------------------------------------------------------------------

  it('renders prior messages fetched from the API (not the welcome message)', async () => {
    setupHappyPath([MSG_USER, MSG_ASSISTANT]);
    renderPanel();

    await waitFor(() => {
      expect(screen.getByText(MSG_USER.content)).toBeInTheDocument();
      expect(screen.getByText(MSG_ASSISTANT.content)).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Role mapping — 'system' role falls back to 'assistant' in display
  // ---------------------------------------------------------------------------

  it('maps unknown roles to assistant style', async () => {
    const systemMsg = {
      id:         'msg-sys-1',
      role:       'system' as const,
      content:    'System notice: fleet is healthy.',
      created_at: '2026-01-01T12:03:00Z',
    };
    setupHappyPath([systemMsg]);
    renderPanel();

    await waitFor(() => {
      expect(screen.getByText(systemMsg.content)).toBeInTheDocument();
    });
  });
});
