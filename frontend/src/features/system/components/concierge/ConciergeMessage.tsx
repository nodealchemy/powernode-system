import { FC } from 'react';
import { FileText } from 'lucide-react';
import { ConciergeActionCard } from '@/shared/components/concierge/ConciergeActionCard';

/**
 * Inline approval-card metadata emitted by the backend on system messages for
 * infrastructure-mission gates (see Ai::Mission#post_milestone_to_conversation).
 * Carried through from BackendMessage.content_metadata.
 */
interface ConciergeActionMetadata {
  concierge_action?: boolean;
  actions?: Array<{ type: string; label: string; style: string; params?: Record<string, unknown> }>;
  action_params?: Record<string, unknown>;
  action_context?: { type?: string; action_type?: string; status?: string; resolved_at?: string };
  action_type?: string;
  [key: string]: unknown;
}

export interface ConciergeChatMessage {
  id: string;
  role: 'user' | 'assistant' | 'tool';
  content: string;
  timestamp: string;
  toolCall?: {
    name: string;
    arguments: Record<string, unknown>;
    result?: Record<string, unknown>;
  };
  metadata?: ConciergeActionMetadata;
}

interface Props {
  message: ConciergeChatMessage;
  onCveRunbookRequest?: (cveId: string) => void;
  onConfirmAction?: (actionType: string, actionParams: Record<string, unknown>) => Promise<void> | void;
}

const CVE_PATTERN = /CVE-\d{4}-\d{4,}/g;

function extractCveIds(content: string): string[] {
  const matches = content.match(CVE_PATTERN);
  if (!matches) return [];
  return Array.from(new Set(matches));
}

export const ConciergeMessage: FC<Props> = ({ message, onCveRunbookRequest, onConfirmAction }) => {
  const isUser = message.role === 'user';
  const isTool = message.role === 'tool';

  // Inline approval card — surfaced on infrastructure-mission gate messages
  // via content_metadata.concierge_action (see Ai::Mission). Rendered with the
  // shared presentational ConciergeActionCard; the hook owns the transport.
  const meta = message.metadata;
  const isConciergeAction = meta?.concierge_action === true && !!onConfirmAction;

  // Detect CVE references only on assistant messages — operator's own
  // typing isn't a useful action affordance.
  const cveIds = !isUser && !isTool && !message.toolCall && onCveRunbookRequest
    ? extractCveIds(message.content)
    : [];

  return (
    <div className={`flex ${isUser ? 'justify-end' : 'justify-start'}`}>
      <div
        className={`max-w-[85%] rounded-lg px-3 py-2 text-sm ${
          isUser
            ? 'bg-theme-primary text-theme-primary-text'
            : isTool
              ? 'bg-theme-info-bg text-theme-info-fg border border-theme-info-border'
              : 'bg-theme-surface-hover text-theme-text-primary'
        }`}
      >
        {message.toolCall ? (
          <div>
            <div className="font-mono text-xs uppercase tracking-wider opacity-75 mb-1">
              tool: {message.toolCall.name}
            </div>
            <pre className="text-xs overflow-auto">
              {JSON.stringify(message.toolCall.arguments, null, 2)}
            </pre>
            {message.toolCall.result && (
              <>
                <div className="font-mono text-xs uppercase tracking-wider opacity-75 mt-2 mb-1">
                  result
                </div>
                <pre className="text-xs overflow-auto">
                  {JSON.stringify(message.toolCall.result, null, 2)}
                </pre>
              </>
            )}
          </div>
        ) : (
          <div className="whitespace-pre-wrap">{message.content}</div>
        )}

        {isConciergeAction && meta && (
          <ConciergeActionCard
            actions={
              meta.actions ?? [
                { type: 'confirm', label: 'Approve', style: 'primary' },
                { type: 'reject', label: 'Reject', style: 'danger' },
              ]
            }
            actionContext={{
              type: meta.action_context?.type ?? 'concierge',
              action_type: meta.action_context?.action_type ?? meta.action_type ?? '',
              status: meta.action_context?.status ?? 'pending',
              resolved_at: meta.action_context?.resolved_at,
            }}
            actionParams={meta.action_params ?? {}}
            onConfirm={onConfirmAction!}
          />
        )}

        {cveIds.length > 0 && (
          <div className="mt-2 flex flex-wrap gap-1.5" data-testid="cve-runbook-actions">
            {cveIds.map((cveId) => (
              <button
                key={cveId}
                type="button"
                onClick={() => onCveRunbookRequest?.(cveId)}
                className="inline-flex items-center gap-1 text-xs px-2 py-1 rounded-md bg-theme-surface border border-theme hover:border-theme-primary"
              >
                <FileText className="h-3 w-3" />
                <span>Runbook: {cveId}</span>
              </button>
            ))}
          </div>
        )}

        <div className="text-xs opacity-60 mt-1 text-right">
          {new Date(message.timestamp).toLocaleTimeString()}
        </div>
      </div>
    </div>
  );
};
