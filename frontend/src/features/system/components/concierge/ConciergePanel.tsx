import { FC, useState } from 'react';
import { ConciergeMessage, type ConciergeChatMessage } from './ConciergeMessage';
import { useConcierge } from '../../hooks/useConcierge';
import type { ConciergeMessage as BackendMessage } from '../../services/api/conciergeApi';

interface Props {
  open: boolean;
  onClose: () => void;
}

const WELCOME_MESSAGE: ConciergeChatMessage = {
  id: 'welcome',
  role: 'assistant',
  content:
    "Hi! I'm the System Concierge. Ask me about your fleet, modules, SDWAN networks, or operations — I can also dispatch system skills (provision_cluster, module_compose, runbook_generate, etc.) on your behalf, with confirmation for any destructive action.",
  timestamp: new Date().toISOString(),
};

function toDisplayMessage(msg: BackendMessage): ConciergeChatMessage {
  const role: ConciergeChatMessage['role'] =
    msg.role === 'tool' || msg.role === 'user' || msg.role === 'assistant' ? msg.role : 'assistant';
  return {
    id: msg.id,
    role,
    content: msg.content,
    timestamp: msg.created_at,
  };
}

export const ConciergePanel: FC<Props> = ({ open, onClose }) => {
  const concierge = useConcierge(open);
  const [draft, setDraft] = useState<string>('');

  if (!open) return null;

  const handleSend = async () => {
    const trimmed = draft.trim();
    if (!trimmed || concierge.pending) return;
    setDraft('');
    await concierge.send(trimmed);
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  const displayMessages: ConciergeChatMessage[] =
    concierge.messages.length === 0
      ? [WELCOME_MESSAGE]
      : concierge.messages.map(toDisplayMessage);

  return (
    <div className="fixed inset-y-0 right-0 z-40 w-full sm:w-96 bg-theme-bg-card border-l border-theme-border-default flex flex-col shadow-xl">
      <div className="p-4 border-b border-theme-border-default flex justify-between items-center">
        <div>
          <h3 className="font-semibold">System Concierge</h3>
          <p className="text-xs text-theme-text-muted">
            {concierge.agentName ? `Connected to ${concierge.agentName}` : 'Ask, plan, dispatch'}
          </p>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="text-theme-text-muted hover:text-theme-text-primary"
          aria-label="Close concierge"
        >
          ×
        </button>
      </div>

      {concierge.snapshot && (
        <div className="px-4 py-2 border-b border-theme-border-default bg-theme-bg-hover">
          <details className="text-xs">
            <summary className="cursor-pointer font-semibold text-theme-text-muted">
              Current fleet snapshot
            </summary>
            <pre className="mt-2 whitespace-pre-wrap text-theme-text-primary">
              {concierge.snapshot}
            </pre>
          </details>
        </div>
      )}

      {concierge.error && (
        <div className="px-4 py-2 bg-theme-error text-theme-error text-xs border-b border-theme-border-default">
          {concierge.error}
        </div>
      )}

      <div className="flex-1 overflow-auto p-4 space-y-3">
        {displayMessages.map((msg) => (
          <ConciergeMessage key={msg.id} message={msg} />
        ))}
        {concierge.pending && (
          <div className="text-xs text-theme-text-muted italic">Concierge is thinking...</div>
        )}
      </div>

      <div className="p-3 border-t border-theme-border-default">
        <textarea
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Ask the concierge..."
          rows={2}
          className="w-full px-3 py-2 rounded border border-theme-border-default bg-theme-bg-input text-sm resize-none"
          disabled={concierge.pending || !concierge.conversationId}
        />
        <div className="flex justify-end mt-2">
          <button
            type="button"
            onClick={handleSend}
            disabled={concierge.pending || !draft.trim() || !concierge.conversationId}
            className="px-4 py-1.5 text-sm rounded bg-theme-primary text-theme-primary-text hover:bg-theme-primary-hover disabled:opacity-50"
          >
            Send
          </button>
        </div>
      </div>
    </div>
  );
};
