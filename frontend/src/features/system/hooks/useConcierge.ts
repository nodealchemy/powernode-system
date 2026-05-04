import { useCallback, useEffect, useState } from 'react';
import { conciergeApi, type ConciergeMessage } from '../services/api/conciergeApi';
import { logger } from '@/shared/utils/logger';

export interface UseConciergeResult {
  conversationId: string | null;
  agentName: string | null;
  snapshot: string | null;
  messages: ConciergeMessage[];
  pending: boolean;
  error: string | null;
  send: (content: string) => Promise<void>;
  reset: () => void;
}

/**
 * Wires the System Concierge UI to the platform's AI conversation API.
 *
 * On mount: bootstraps (or reuses) the operator's active System Concierge
 * conversation via POST /api/v1/system/concierge/start, then fetches any
 * existing messages for that conversation.
 *
 * On send: posts to the standard /api/v1/ai/conversations/:id/send_message
 * endpoint. The platform's ConciergeService handles tool dispatch +
 * confirmation gating; we just append messages as they arrive in the
 * response.
 */
export function useConcierge(active: boolean): UseConciergeResult {
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [agentName, setAgentName] = useState<string | null>(null);
  const [snapshot, setSnapshot] = useState<string | null>(null);
  const [messages, setMessages] = useState<ConciergeMessage[]>([]);
  const [pending, setPending] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);

  const reset = useCallback(() => {
    setConversationId(null);
    setAgentName(null);
    setSnapshot(null);
    setMessages([]);
    setError(null);
  }, []);

  useEffect(() => {
    if (!active || conversationId) return;
    let cancelled = false;

    (async () => {
      try {
        setPending(true);
        const started = await conciergeApi.start();
        if (cancelled) return;
        setConversationId(started.conversation_id);
        setAgentName(started.agent_name);
        setSnapshot(started.snapshot);

        const existing = await conciergeApi.listMessages(started.conversation_id);
        if (!cancelled) setMessages(existing);
      } catch (err) {
        if (cancelled) return;
        const msg = err instanceof Error ? err.message : 'Failed to start Concierge';
        logger.error('[useConcierge] start failed', err);
        setError(msg);
      } finally {
        if (!cancelled) setPending(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [active, conversationId]);

  const send = useCallback(
    async (content: string) => {
      if (!conversationId) {
        setError('Concierge not ready');
        return;
      }
      const trimmed = content.trim();
      if (!trimmed) return;

      const optimistic: ConciergeMessage = {
        id: `u-${Date.now()}`,
        role: 'user',
        content: trimmed,
        created_at: new Date().toISOString(),
      };
      setMessages((prev) => [...prev, optimistic]);

      try {
        setPending(true);
        const response = await conciergeApi.sendMessage(conversationId, trimmed);
        // Replace optimistic with server-confirmed and append assistant reply
        setMessages((prev) => {
          const filtered = prev.filter((m) => m.id !== optimistic.id);
          const next: ConciergeMessage[] = [...filtered, response.user_message];
          if (response.assistant_message) next.push(response.assistant_message);
          return next;
        });
      } catch (err) {
        const msg = err instanceof Error ? err.message : 'Send failed';
        logger.error('[useConcierge] send failed', err);
        setError(msg);
      } finally {
        setPending(false);
      }
    },
    [conversationId]
  );

  return {
    conversationId,
    agentName,
    snapshot,
    messages,
    pending,
    error,
    send,
    reset,
  };
}
