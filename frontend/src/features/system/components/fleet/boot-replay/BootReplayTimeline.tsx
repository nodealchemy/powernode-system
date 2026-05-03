import { FC, useMemo, useState } from 'react';
import { useBootReplay } from './useBootReplay';
import { BootEventDetailPanel } from './BootEventDetailPanel';
import type { BootEvent } from '../../../services/api/bootReplayApi';

interface Props {
  instanceId: string | null;
  correlationId?: string;
}

const PHASE_ORDER = [
  'firmware',
  'bootloader',
  'kernel',
  'initramfs',
  'systemd',
  'enrollment',
  'heartbeat',
];

export const BootReplayTimeline: FC<Props> = ({ instanceId, correlationId }) => {
  const { loading, data, error, refresh } = useBootReplay(instanceId, correlationId);
  const [selected, setSelected] = useState<BootEvent | null>(null);

  const phases = useMemo(() => {
    if (!data) return [];
    return PHASE_ORDER.map((phase) => ({
      phase,
      summary: data.phase_summary?.[phase],
    }));
  }, [data]);

  if (!instanceId) {
    return (
      <div className="p-6 text-sm text-theme-text-muted">
        Select a node instance to replay its boot timeline.
      </div>
    );
  }

  if (loading && !data) {
    return <div className="p-6 text-sm text-theme-text-muted">Loading boot replay...</div>;
  }

  if (error) {
    return (
      <div className="p-6 text-sm text-theme-error">
        {error}
        <button
          type="button"
          onClick={refresh}
          className="ml-3 underline text-theme-link hover:text-theme-link-hover"
        >
          retry
        </button>
      </div>
    );
  }

  if (!data || data.events.length === 0) {
    return (
      <div className="p-6 text-sm text-theme-text-muted">
        No boot events recorded for this instance yet.
      </div>
    );
  }

  return (
    <div className="flex gap-6 p-4">
      {/* Timeline column */}
      <div className="w-1/2 space-y-4">
        <div className="text-xs uppercase tracking-wider text-theme-text-muted mb-3">
          Boot phases — {data.events.length} events
        </div>
        {phases.map(({ phase, summary }) => (
          <div key={phase} className="border-l-2 border-theme-border-default pl-4">
            <div className="font-medium text-theme-text-primary capitalize">{phase}</div>
            {summary ? (
              <div className="text-xs text-theme-text-muted">
                {new Date(summary.first_at).toLocaleTimeString()} – {new Date(summary.last_at).toLocaleTimeString()} · {summary.count} event(s)
              </div>
            ) : (
              <div className="text-xs text-theme-text-muted italic">no events</div>
            )}
          </div>
        ))}

        <div className="mt-6 space-y-2">
          <div className="text-xs uppercase tracking-wider text-theme-text-muted">All events</div>
          {data.events.map((evt) => (
            <button
              key={evt.id}
              type="button"
              onClick={() => setSelected(evt)}
              className={`w-full text-left p-2 rounded text-sm hover:bg-theme-bg-hover ${
                selected?.id === evt.id ? 'bg-theme-bg-selected' : ''
              }`}
            >
              <span className="font-mono text-xs text-theme-text-muted mr-2">
                {new Date(evt.emitted_at).toLocaleTimeString()}
              </span>
              <span className="font-medium">{evt.kind}</span>
              {evt.severity !== 'low' && (
                <span className="ml-2 text-xs text-theme-warning">{evt.severity}</span>
              )}
            </button>
          ))}
        </div>
      </div>

      {/* Detail column */}
      <div className="w-1/2">
        <BootEventDetailPanel event={selected} />
      </div>
    </div>
  );
};
