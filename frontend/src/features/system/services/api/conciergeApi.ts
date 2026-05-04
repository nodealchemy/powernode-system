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
      '/api/v1/system/concierge/start',
      {}
    );
    return extractData(response);
  },

  async listMessages(conversationId: string): Promise<ConciergeMessage[]> {
    const response = await apiClient.get<ApiEnvelope<ConciergeMessagesResponse>>(
      `/api/v1/ai/conversations/${conversationId}/messages`
    );
    const data = extractData(response);
    return data.messages || [];
  },

  async sendMessage(conversationId: string, content: string): Promise<ConciergeSendResponse> {
    const response = await apiClient.post<ApiEnvelope<ConciergeSendResponse>>(
      `/api/v1/ai/conversations/${conversationId}/send_message`,
      { message: { content } }
    );
    return extractData(response);
  },
};
