import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

export interface ConciergeStartResponse {
  conversation_id: string;
  agent_id: string;
  agent_name: string;
  snapshot: string;
}

export interface ConciergeMessage {
  id: string;
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  created_at: string;
  content_metadata?: Record<string, unknown>;
}

export interface ConciergeMessagesResponse {
  messages: ConciergeMessage[];
}

export interface ConciergeSendResponse {
  user_message: ConciergeMessage;
  assistant_message?: ConciergeMessage;
}

export const conciergeApi = {
  async start(): Promise<ConciergeStartResponse> {
    const response = await apiClient.post<ApiEnvelope<ConciergeStartResponse>>(
      '/system/concierge/start',
      {}
    );
    return extractData(response);
  },

  async listMessages(conversationId: string): Promise<ConciergeMessage[]> {
    const response = await apiClient.get<ApiEnvelope<ConciergeMessagesResponse>>(
      `/ai/conversations/${conversationId}/messages`
    );
    const data = extractData(response);
    return data.messages || [];
  },

  async sendMessage(conversationId: string, content: string): Promise<ConciergeSendResponse> {
    // Core routes.rb maps POST /ai/conversations/:id/messages to the
    // send_message action — there is no separate /send_message URL.
    const response = await apiClient.post<ApiEnvelope<ConciergeSendResponse>>(
      `/ai/conversations/${conversationId}/messages`,
      { message: { content } }
    );
    return extractData(response);
  },

  // Resolves an inline concierge action gate (e.g. an infrastructure mission
  // approval) surfaced via assistant content_metadata.concierge_action. Routes
  // to the same platform endpoint the core chat uses
  // (ConciergeService#handle_confirmed_action).
  async confirmAction(
    conversationId: string,
    actionType: string,
    actionParams: Record<string, unknown> = {}
  ): Promise<void> {
    await apiClient.post(`/ai/conversations/${conversationId}/confirm_action`, {
      action_type: actionType,
      action_params: actionParams,
    });
  },
};
