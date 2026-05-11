import { FC } from 'react';
import type { BootEvent } from '../../../services/api/bootReplayApi';

interface Props {
  event: BootEvent | null;
}

export const BootEventDetailPanel: FC<Props> = ({ event }) => {
  if (!event) {
    return (
      <div className="p-4 text-sm text-theme-tertiary">
        Select an event to view its payload.
      </div>
    );
  }

  return (
    <div className="p-4 space-y-3">
      <div>
        <div className="text-xs uppercase tracking-wider text-theme-tertiary">Kind</div>
        <div className="font-mono text-sm">{event.kind}</div>
      </div>

      <div className="grid grid-cols-2 gap-3 text-sm">
        <div>
          <div className="text-xs uppercase tracking-wider text-theme-tertiary">Severity</div>
          <div className="font-mono">{event.severity}</div>
        </div>
        <div>
          <div className="text-xs uppercase tracking-wider text-theme-tertiary">Source</div>
          <div className="font-mono">{event.source || '—'}</div>
        </div>
        <div>
          <div className="text-xs uppercase tracking-wider text-theme-tertiary">Emitted</div>
          <div className="font-mono text-xs">{new Date(event.emitted_at).toISOString()}</div>
        </div>
        <div>
          <div className="text-xs uppercase tracking-wider text-theme-tertiary">Correlation</div>
          <div className="font-mono text-xs break-all">{event.correlation_id || '—'}</div>
        </div>
      </div>

      <div>
        <div className="text-xs uppercase tracking-wider text-theme-tertiary mb-1">Payload</div>
        <pre className="text-xs bg-theme-surface rounded p-3 overflow-auto max-h-96 font-mono">
          {JSON.stringify(event.payload, null, 2)}
        </pre>
      </div>
    </div>
  );
};
