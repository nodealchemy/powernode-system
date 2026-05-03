import { FC, useState } from 'react';
import { ConciergeMessage, type ConciergeChatMessage } from './ConciergeMessage';

interface Props {
  open: boolean;
  onClose: () => void;
}

export const ConciergePanel: FC<Props> = ({ open, onClose }) => {
  const [messages, setMessages] = useState<ConciergeChatMessage[]>([
    {
      id: 'welcome',
      role: 'assistant',
      content:
        "Hi! I'm the System Concierge. Ask me about your fleet, modules, or operations — I can also dispatch system skills (provision_cluster, module_compose, runbook_generate, etc.) on your behalf.",
      timestamp: new Date().toISOString(),
    },
  ]);
  const [draft, setDraft] = useState<string>('');
  const [pending, setPending] = useState<boolean>(false);

  if (!open) return null;

  const handleSend = async () => {
    const trimmed = draft.trim();
    if (!trimmed || pending) return;

    const userMsg: ConciergeChatMessage = {
      id: `u-${Date.now()}`,
      role: 'user',
      content: trimmed,
      timestamp: new Date().toISOString(),
    };
    setMessages((prev) => [...prev, userMsg]);
    setDraft('');
    setPending(true);

    // v1: passthrough to platform's existing conversation/AI flow.
    // Wire to a system-context conversation here once the chat extension's
    // mention picker exposes node-instance peers (Phase 6 follow-up).
    setTimeout(() => {
      setMessages((prev) => [
        ...prev,
        {
          id: `a-${Date.now()}`,
          role: 'assistant',
          content:
            'Concierge is in skeleton mode for v1 — backend conversation routing pending. Type a question and I will echo it; production version dispatches via the platform AI flow.',
          timestamp: new Date().toISOString(),
        },
        {
          id: `e-${Date.now()}`,
          role: 'assistant',
          content: `(echo) ${trimmed}`,
          timestamp: new Date().toISOString(),
        },
      ]);
      setPending(false);
    }, 500);
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  return (
    <div className="fixed inset-y-0 right-0 z-40 w-full sm:w-96 bg-theme-bg-card border-l border-theme-border-default flex flex-col shadow-xl">
      <div className="p-4 border-b border-theme-border-default flex justify-between items-center">
        <div>
          <h3 className="font-semibold">System Concierge</h3>
          <p className="text-xs text-theme-text-muted">Ask, plan, dispatch</p>
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

      <div className="flex-1 overflow-auto p-4 space-y-3">
        {messages.map((msg) => (
          <ConciergeMessage key={msg.id} message={msg} />
        ))}
        {pending && (
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
          disabled={pending}
        />
        <div className="flex justify-end mt-2">
          <button
            type="button"
            onClick={handleSend}
            disabled={pending || !draft.trim()}
            className="px-4 py-1.5 text-sm rounded bg-theme-primary text-theme-primary-text hover:bg-theme-primary-hover disabled:opacity-50"
          >
            Send
          </button>
        </div>
      </div>
    </div>
  );
};
